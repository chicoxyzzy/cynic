//! `cynic-fuzz` REPRL (Read-Eval-Print-Reset Loop) host. Implements
//! the protocol Fuzzilli expects from a target engine: a 4-FD pipe
//! pair (control + data) inherited from the parent, a `HELO`
//! handshake, then a length-prefixed exec loop with a 4-byte status
//! word per sample.
//!
//! The runner is invoked by Fuzzilli with the FDs preset, not by
//! the user directly. Outside that context the FDs are unopened
//! and the first `posix.read` returns `error.NotOpenForReading`
//! — the runner surfaces that as a focused error rather than
//! crashing.
//!
//! Base posture is fixed: `--unhardened` + `--allow=eval` +
//! `installTestGlobals` (so the `fuzzilli(op, arg)` host hook is
//! reachable). Hardened fuzzing — frozen primordials confining
//! mutation — can get its own host entry later if it's worth the
//! reduced reachable behavior.
//!
//! Three argv flags layer on top for native differential fuzzing
//! (docs/fuzz-differential.md), parsed in `fuzz_main`: `--jit` tiers
//! the run up to Bistromath, `--diff` writes a completion-value
//! digest to fd 103 after each sample, and `--diff-self-test`
//! perturbs that digest to validate the parent's oracle. The plain
//! crash-finding profile passes none of them and is unaffected.
//!
//! Protocol summary (V8 / JSC / SpiderMonkey converge on this):
//!   - fd 100 (CRFD): engine reads control commands from Fuzzilli
//!   - fd 101 (CWFD): engine writes status words back
//!   - fd 102 (DRFD): engine reads script source from Fuzzilli
//!   - fd 103 (DWFD): engine writes `FUZZILLI_PRINT` output
//!     (consumed by Fuzzilli's differential mode)
//!   Handshake: both sides exchange the 4-byte literal "HELO".
//!   Per-iteration: engine reads 4-byte action (only `"exec"`
//!   defined), 8-byte little-endian source length, then that many
//!   bytes from DRFD. After execution it writes a 4-byte little-
//!   endian status: 0 ⇒ clean completion, `(1 << 8)` ⇒ uncaught
//!   JS exception. A crash skips status — Fuzzilli's parent
//!   detects the signal via `waitpid`.

const std = @import("std");
const builtin = @import("builtin");
const cynic = @import("cynic");

const Realm = cynic.runtime.Realm;
const Value = cynic.runtime.Value;
const JSString = cynic.runtime.JSString;
const RunResult = cynic.runtime.lantern.RunResult;

/// Per-run knobs parsed from `cynic-fuzz`'s argv (see `fuzz_main`).
/// `processEnv` is shared between Fuzzilli's target and reference
/// runners, so the only way to give the two halves of a differential
/// pair different postures is via `processArgs` vs
/// `processArgsReference` — i.e. these come from the command line,
/// not the environment.
pub const Options = struct {
    /// Per-fixture allocation-pressure GC threshold (the
    /// `FUZZ_GC_THRESHOLD` env-var knob; see `fuzz_main`). `null`
    /// leaves the engine default.
    gc_threshold: ?u32 = null,
    /// `--jit`: tier hot chunks up to Bistromath and force-compile
    /// every eligible chunk on its first call (`jit_threshold_override
    /// = 1`). The differential target sets this; the reference runs
    /// the interpreter, so the pair is an interpreter-vs-JIT
    /// correctness diff (docs/fuzz-differential.md). A comptime no-op
    /// on hosts without codegen support (docs/jit.md §8).
    jit: bool = false,
    /// `--diff`: after each sample, write a canonical digest of the
    /// completion outcome to fd 103 (Fuzzilli's differential sink) so
    /// the parent's fuzzout oracle can compare the two runs. Off for
    /// the plain crash-finding profile, on for both halves of a
    /// differential pair.
    emit_digest: bool = false,
    /// `--diff-self-test`: perturb the emitted digest with a sentinel
    /// so the two halves of a differential pair disagree on every
    /// sample. Pure harness validation — it proves the oracle fires
    /// end-to-end without needing a real JIT miscompile. Never set in
    /// a real fuzzing run.
    self_test: bool = false,
};

/// Control / data file descriptor numbers Fuzzilli pre-opens
/// before exec'ing the engine. Hard-coded constants on both sides
/// — no env-var override.
pub const CRFD: std.posix.fd_t = 100;
pub const CWFD: std.posix.fd_t = 101;
pub const DRFD: std.posix.fd_t = 102;
pub const DWFD: std.posix.fd_t = 103;

/// Sole action code defined today; Fuzzilli will extend the protocol
/// later (`"cphr"` for checkpoint, etc.) — anything else is rejected
/// so a protocol drift doesn't silently mis-execute one sample as
/// another.
pub const ACTION_EXEC: [4]u8 = .{ 'e', 'x', 'e', 'c' };

/// The 4-byte literal both sides exchange to confirm the FDs are
/// wired correctly.
pub const HELO: [4]u8 = .{ 'H', 'E', 'L', 'O' };

/// Upper bound on a single sample's source length. Fuzzilli rarely
/// produces samples this large, but a corrupt control channel could
/// hand us an arbitrary `size_t` and we'd otherwise try to allocate
/// it. 16 MiB is well above any real Fuzzilli sample.
pub const MAX_SCRIPT_BYTES: u64 = 16 * 1024 * 1024;

pub const ProtocolError = error{
    HandshakeFailed,
    UnknownAction,
    ScriptTooLarge,
    ShortRead,
};

/// Error set surfaced by `run`. Declared explicitly so the
/// `UnsupportedPlatform` branch — which compiles to a dead `if`
/// on every host Cynic actually builds for — stays in the type
/// even when the comptime check is elided. Without the
/// declaration, a POSIX build's inferred set drops it and the
/// CLI's `error.UnsupportedPlatform =>` arm fails to type-check.
pub const RunError = ProtocolError ||
    std.posix.ReadError ||
    std.mem.Allocator.Error ||
    error{ WriteFailed, UnsupportedPlatform };

/// Decode the 8-byte little-endian script-size header Fuzzilli
/// sends after the action word.
pub fn decodeScriptSize(bytes: [8]u8) u64 {
    return std.mem.readInt(u64, &bytes, .little);
}

/// Encode a `wait`-style status word for the parent's `WIFEXITED`
/// path. Bit layout: low 8 bits = signal (always 0 here — a crash
/// doesn't go through this path), high 8 bits of the low 16 =
/// exit code. So `encodeStatus(0)` ⇒ clean exit, `encodeStatus(1)`
/// ⇒ exited with code 1 (the convention Fuzzilli reads as "this
/// sample threw an uncaught exception").
pub fn encodeStatus(exit_code: u8) [4]u8 {
    const status: u32 = @as(u32, exit_code) << 8;
    var out: [4]u8 = undefined;
    std.mem.writeInt(u32, &out, status, .little);
    return out;
}

/// Map a `RunResult` (or a hard parse / compile / interpreter
/// error) to the exit code Fuzzilli reads. `0` ⇒ everything ran
/// to completion; `1` ⇒ uncaught JS exception or a host-side
/// parse / compile failure (Fuzzilli treats both as "this sample
/// is uninteresting"). Hard engine bugs (use-after-free, GC
/// invariant violation) panic before they reach this function.
pub fn outcomeToExitCode(outcome: anyerror!cynic.runtime.lantern.RunResult) u8 {
    const r = outcome catch return 1;
    return switch (r) {
        .value, .yielded => 0,
        .thrown => 1,
    };
}

/// Read exactly `buf.len` bytes from `fd` or return
/// `error.ShortRead`. The control / data channels are pipes;
/// short reads happen on EOF (Fuzzilli closed the pipe — we're
/// done).
fn readExact(fd: std.posix.fd_t, buf: []u8) !void {
    var read: usize = 0;
    while (read < buf.len) {
        const n = try std.posix.read(fd, buf[read..]);
        if (n == 0) return error.ShortRead;
        read += n;
    }
}

fn writeAll(fd: std.posix.fd_t, buf: []const u8) !void {
    // `std.posix.write` was retired in 0.17-dev; the C function is
    // the stable path on libc-linked builds (cynic always links
    // libc). A -1 / 0 return collapses to `error.WriteFailed` — the
    // wrapper is one-shot per chunk, EINTR retries are unlikely on
    // a Fuzzilli pipe pair, and a write error there means the
    // parent's dead so there's nothing to recover.
    var written: usize = 0;
    while (written < buf.len) {
        const n = std.c.write(fd, buf[written..].ptr, buf.len - written);
        if (n <= 0) return error.WriteFailed;
        written += @intCast(n);
    }
}

/// Exchange the `HELO` handshake. Engine writes first (so a
/// misconfigured parent learns quickly that the FDs aren't wired);
/// then reads Fuzzilli's reply and verifies the literal.
fn handshake() !void {
    try writeAll(CWFD, &HELO);
    var buf: [4]u8 = undefined;
    try readExact(CRFD, &buf);
    if (!std.mem.eql(u8, &buf, &HELO)) return error.HandshakeFailed;
}

/// Pull one iteration's command + source off the control + data
/// pipes. Returns `null` on EOF (Fuzzilli is shutting down).
fn readIteration(allocator: std.mem.Allocator) !?[]u8 {
    var action: [4]u8 = undefined;
    // First-byte read separately so a clean EOF here returns null
    // (Fuzzilli's shutdown path) instead of `error.ShortRead`. Once
    // we've seen one byte we know an iteration is in flight; any
    // EOF beyond that is a real protocol error.
    const first = std.posix.read(CRFD, action[0..1]) catch |err| switch (err) {
        error.NotOpenForReading => return err,
        else => return err,
    };
    if (first == 0) return null;
    try readExact(CRFD, action[1..]);
    if (!std.mem.eql(u8, &action, &ACTION_EXEC)) return error.UnknownAction;

    var size_buf: [8]u8 = undefined;
    try readExact(CRFD, &size_buf);
    const size = decodeScriptSize(size_buf);
    if (size > MAX_SCRIPT_BYTES) return error.ScriptTooLarge;

    const buf = try allocator.alloc(u8, @intCast(size));
    errdefer allocator.free(buf);
    try readExact(DRFD, buf);
    return buf;
}

/// Build a fresh realm, run one source through it, tear it down.
/// Fresh-realm-per-iteration is the simplest semantics — no cross-
/// sample contamination — and the only one that's obviously correct
/// while the engine's snapshot / fast-reset machinery is still in
/// design. Iteration rate optimization lands with the coverage
/// commit when there's actual perf signal to chase.
fn executeOne(allocator: std.mem.Allocator, source: []const u8, options: Options) u8 {
    var realm = Realm.init(allocator);
    defer realm.deinit();
    // Fuzzilli mutates prototypes and constructs runtime code; the
    // hardened SES posture would reject most generated samples
    // before they reach interesting engine paths. Allow eval too —
    // §19.2.1.2 HostEnsureCanCompileStrings would otherwise refuse
    // every `Function(string)` / direct `eval(...)` Fuzzilli emits.
    realm.hardened = false;
    realm.allow_eval = true;
    if (options.jit) {
        // docs/fuzz-differential.md — the differential target tiers up
        // to Bistromath and force-compiles every eligible chunk on its
        // first call so even a sample that runs each function once
        // exercises the JIT path. The reference half leaves this off.
        realm.jit_enabled = true;
        realm.jit_threshold_override = 1;
    }
    if (options.gc_threshold) |n| realm.heap.setGcThreshold(n);
    realm.installBuiltins() catch return 1;
    // `fuzzilli(op, arg)` lives here — same install path as the
    // other host-only debug hooks. See `installTestGlobals`.
    realm.installTestGlobals() catch return 1;

    const outcome = cynic.runtime.evaluateScript(allocator, &realm, source);
    // §9.4 — drain microtasks before reporting completion so a
    // `Promise.resolve().then(() => fuzzilli("FUZZILLI_CRASH", 0))`
    // at the top level still reaches the crash on the iteration
    // that scheduled it.
    cynic.runtime.lantern.drainMicrotasks(allocator, &realm) catch {};
    // Differential sink: emit the completion-value digest before the
    // `defer realm.deinit()` runs, while the heap that backs the
    // `Value` is still alive. Computed without re-entering JS — no
    // user `toString`, so it can't perturb GC state or leak the
    // non-determinism a user callback would.
    if (options.emit_digest) emitDigest(outcome, options.self_test);
    return outcomeToExitCode(outcome);
}

/// Tiny fixed-capacity formatter. The digest is short and bounded
/// (a tag byte + at most a u64 in hex + a length), so a stack buffer
/// with manual length tracking avoids any allocation and any reliance
/// on the churning 0.17-dev stream/writer surface — it builds on the
/// one formatting primitive the rest of this host already uses
/// (`std.fmt.bufPrint`). An overrun silently truncates: a digest can
/// only collide *more* on truncation, never produce a false
/// divergence between two identical-content runs (both truncate the
/// same way).
const DigestBuf = struct {
    bytes: [96]u8 = undefined,
    len: usize = 0,

    fn append(self: *DigestBuf, comptime fmt: []const u8, args: anytype) void {
        const slice = std.fmt.bufPrint(self.bytes[self.len..], fmt, args) catch return;
        self.len += slice.len;
    }

    fn written(self: *const DigestBuf) []const u8 {
        return self.bytes[0..self.len];
    }
};

/// Write a one-line canonical digest of the sample's completion
/// outcome to fd 103 (Fuzzilli's `FUZZILLI_PRINT` / fuzzout channel).
/// Fuzzilli's fuzzout differential oracle (docs/fuzz-differential.md)
/// compares this line across the JIT and interpreter runs of the same
/// sample; a mismatch is a candidate miscompile.
///
/// Silent no-op when fd 103 isn't open (running outside REPRL) — the
/// same contract as the `fuzzilli('FUZZILLI_PRINT', …)` host hook.
fn emitDigest(outcome: anyerror!RunResult, self_test: bool) void {
    var buf = DigestBuf{};
    if (outcome) |r| {
        switch (r) {
            // Tag byte distinguishes returned / thrown / yielded so a
            // thrown `5` can't read identical to a returned `5`.
            .value => |v| {
                buf.append("V", .{});
                appendValueDigest(&buf, v);
            },
            .thrown => |v| {
                buf.append("T", .{});
                appendValueDigest(&buf, v);
            },
            // A top-level script can't end mid-yield, but tag it rather
            // than assert — a fuzz host never trusts its own invariants.
            .yielded => |v| {
                buf.append("Y", .{});
                appendValueDigest(&buf, v);
            },
        }
    } else |_| {
        // A host-side parse / compile failure — no Value to digest.
        buf.append("E", .{});
    }
    // `--diff-self-test`: append a sentinel so the perturbed half of a
    // differential pair disagrees with the unperturbed half on every
    // sample, proving the oracle fires without a real miscompile.
    if (self_test) buf.append("#ST", .{});
    buf.append("\n", .{});
    writeAll(DWFD, buf.written()) catch {};
}

/// FNV-1a over a byte slice. A digest hash — collision-resistant
/// enough that two different strings of equal length are
/// overwhelmingly likely to differ, and stable across runs so the
/// JIT and interpreter halves agree on identical content.
fn fnv1a(bytes: []const u8) u64 {
    var h: u64 = 0xcbf2_9ce4_8422_2325;
    for (bytes) |b| {
        h ^= b;
        h *%= 0x0000_0100_0000_01b3;
    }
    return h;
}

/// Append a canonical, allocation-free, no-re-entry digest of `v`.
/// Primitives serialize exactly (the high-value case: a JIT
/// arithmetic / comparison / string-length miscompile surfaces as a
/// differing primitive digest). Heap objects collapse to a type tag
/// — their identity is a non-deterministic heap address, and deep
/// structural compare is out of scope for this differential.
fn appendValueDigest(buf: *DigestBuf, v: Value) void {
    if (v.isUndefined()) {
        buf.append("u", .{});
    } else if (v.isNull()) {
        buf.append("n", .{});
    } else if (v.isBool()) {
        buf.append("b{d}", .{@intFromBool(v.asBool())});
    } else if (v.isInt32()) {
        buf.append("i{d}", .{v.asInt32()});
    } else if (v.isDouble()) {
        // Raw IEEE-754 bits: exact, deterministic, and distinguishes
        // +0 from -0. NaN is already canonical (`Value.fromDouble`),
        // so every NaN hashes identically across the two runs.
        const bits: u64 = @bitCast(v.asDouble());
        buf.append("d{x}", .{bits});
    } else if (v.isString()) {
        const s: *JSString = @ptrCast(@alignCast(v.asString()));
        if (s.flatBytesIfFlat()) |bytes| {
            buf.append("s{d}:{x}", .{ bytes.len, fnv1a(bytes) });
        } else {
            // Rope — skip the flatten allocation (a fuzz host must not
            // add an OOM path here); the code-unit length is enough
            // signal for a digest.
            buf.append("s{d}~", .{s.length_cu});
        }
    } else {
        // Object / function / symbol / bigint — all heap-tagged.
        buf.append("o", .{});
    }
}

/// Entry point: handshake, then loop until EOF on the control
/// pipe. POSIX-only; Fuzzilli has no Windows host today.
///
/// `on_iteration_start`, when non-null, fires at the top of every
/// iteration — before the sample executes. The `cynic-fuzz`
/// binary passes `fuzz_coverage.reset` here to clear Fuzzilli's
/// bitmap and re-arm the sancov guards between samples; an
/// uninstrumented host (e.g. a protocol smoke test) passes null.
pub fn run(
    allocator: std.mem.Allocator,
    options: Options,
    on_iteration_start: ?*const fn () void,
) RunError!void {
    if (comptime builtin.os.tag == .windows) {
        return error.UnsupportedPlatform;
    }
    try handshake();
    while (try readIteration(allocator)) |source| {
        defer allocator.free(source);
        if (on_iteration_start) |cb| cb();
        const exit_code = executeOne(allocator, source, options);
        const status = encodeStatus(exit_code);
        try writeAll(CWFD, &status);
    }
}

// ---------------------------------------------------------------------------
// Tests — pure protocol decoding / encoding. The fd-bound runner can't be
// driven from `zig test` without a parent process; those paths are
// exercised by real Fuzzilli runs (the smoke test is `FUZZILLI_CRASH(0)`
// reaching the parent as a SIGABRT, which a REPRL harness sees on the
// first iteration).
// ---------------------------------------------------------------------------

const testing = std.testing;

test "fuzz_reprl: decodeScriptSize parses little-endian u64" {
    const bytes: [8]u8 = .{ 0x37, 0x13, 0, 0, 0, 0, 0, 0 };
    try testing.expectEqual(@as(u64, 0x1337), decodeScriptSize(bytes));
}

/// Digest `v` into a caller-owned `DigestBuf`. The buffer must
/// outlive the returned slice — each assertion below uses its own so
/// two digests can be compared without aliasing a shared buffer.
fn digestInto(out: *DigestBuf, v: Value) []const u8 {
    out.* = DigestBuf{};
    appendValueDigest(out, v);
    return out.written();
}

test "fuzz_reprl: appendValueDigest serializes primitives canonically" {
    var b: DigestBuf = undefined;
    try testing.expectEqualStrings("u", digestInto(&b, Value.undefined_));
    try testing.expectEqualStrings("n", digestInto(&b, Value.null_));
    try testing.expectEqualStrings("b1", digestInto(&b, Value.true_));
    try testing.expectEqualStrings("b0", digestInto(&b, Value.false_));
    try testing.expectEqualStrings("i42", digestInto(&b, Value.fromInt32(42)));
    try testing.expectEqualStrings("i-7", digestInto(&b, Value.fromInt32(-7)));
    // Object-tagged values collapse to a single type tag.
    try testing.expectEqualStrings("o", digestInto(&b, Value.fromObject(@ptrFromInt(0x1000))));
}

test "fuzz_reprl: appendValueDigest distinguishes +0, -0, and NaN doubles" {
    // The int32 fast-path owns small integers, so use non-fast-path
    // doubles for the value tests. ±0 must differ (observable via
    // `Object.is`); NaN must be stable (canonicalized in Value).
    // Each digest gets its own buffer so the slices don't alias.
    var z0: DigestBuf = undefined;
    var z1: DigestBuf = undefined;
    try testing.expect(!std.mem.eql(
        u8,
        digestInto(&z0, Value.fromDouble(0.0)),
        digestInto(&z1, Value.fromDouble(-0.0)),
    ));

    var na: DigestBuf = undefined;
    var nb: DigestBuf = undefined;
    try testing.expectEqualStrings(
        digestInto(&na, Value.fromDouble(std.math.nan(f64))),
        digestInto(&nb, Value.fromDouble(-std.math.nan(f64))),
    );

    // A genuine double value is exact and reproducible across calls,
    // and two distinct values produce distinct digests.
    var da: DigestBuf = undefined;
    var db: DigestBuf = undefined;
    try testing.expectEqualStrings(
        digestInto(&da, Value.fromDouble(1.5)),
        digestInto(&db, Value.fromDouble(1.5)),
    );
    try testing.expect(!std.mem.eql(
        u8,
        digestInto(&da, Value.fromDouble(1.5)),
        digestInto(&db, Value.fromDouble(2.5)),
    ));
}

test "fuzz_reprl: executeOne agrees under JIT and interpreter on benign scripts" {
    // The differential PoC's premise: for a correct engine the JIT and
    // interpreter halves return the same per-sample exit code. Exercise
    // the exact fuzz JIT posture (`jit_enabled` + `jit_threshold_override
    // = 1`) on a handful of benign samples and confirm neither hangs nor
    // diverges from the interpreter.
    const cases = [_][]const u8{
        "1 + 1;",
        "var x = 0; for (var i = 0; i < 64; i++) { x += i; } x;",
        "function f(n) { return n * 2; } var s = 0; for (var i = 0; i < 64; i++) s += f(i); s;",
        "'a' + 'b' + 'c';",
        "throw new Error('boom');",
    };
    for (cases) |src| {
        const interp = executeOne(testing.allocator, src, .{});
        const jit = executeOne(testing.allocator, src, .{ .jit = true });
        try testing.expectEqual(interp, jit);
    }
}

test "fuzz_reprl: fnv1a is stable and content-sensitive" {
    try testing.expectEqual(fnv1a("hello"), fnv1a("hello"));
    try testing.expect(fnv1a("hello") != fnv1a("hellp"));
    // The published FNV-1a 64-bit seed digests the empty string to
    // the offset basis unchanged.
    try testing.expectEqual(@as(u64, 0xcbf2_9ce4_8422_2325), fnv1a(""));
}

test "fuzz_reprl: decodeScriptSize handles a full 64-bit value" {
    const bytes: [8]u8 = .{ 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff };
    try testing.expectEqual(@as(u64, std.math.maxInt(u64)), decodeScriptSize(bytes));
}

test "fuzz_reprl: encodeStatus(0) is a clean-exit wait-status" {
    const bytes = encodeStatus(0);
    // Low byte 0 = "WIFEXITED true"; the rest also zero ⇒ exit code 0.
    try testing.expectEqual(@as(u8, 0), bytes[0]);
    try testing.expectEqual(@as(u8, 0), bytes[1]);
}

test "fuzz_reprl: encodeStatus(1) writes exit code into the high byte" {
    const bytes = encodeStatus(1);
    // `(1 << 8)` little-endian ⇒ {0, 1, 0, 0}.
    try testing.expectEqual(@as(u8, 0), bytes[0]);
    try testing.expectEqual(@as(u8, 1), bytes[1]);
    try testing.expectEqual(@as(u8, 0), bytes[2]);
    try testing.expectEqual(@as(u8, 0), bytes[3]);
}

test "fuzz_reprl: ACTION_EXEC literal is the 4 ASCII bytes" {
    try testing.expectEqualSlices(u8, "exec", &ACTION_EXEC);
}

test "fuzz_reprl: HELO literal is the 4 ASCII bytes" {
    try testing.expectEqualSlices(u8, "HELO", &HELO);
}

test "fuzz_reprl: MAX_SCRIPT_BYTES leaves room for real Fuzzilli samples" {
    // Fuzzilli samples top out around 64 KiB in practice; 16 MiB
    // is generous. The guard exists to keep a corrupt control word
    // from triggering a giant allocation.
    try testing.expect(MAX_SCRIPT_BYTES >= 1024 * 1024);
}
