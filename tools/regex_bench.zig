//! In-process regex-matcher benchmark: Perlex vs the vendored
//! QuickJS-NG libregexp, on identical (pattern, UTF-16 input) pairs.
//!
//! Both engines are linked into one ReleaseFast binary and driven
//! directly — no process spawn, no JS wrapper — so the numbers are a
//! pure constant-factor contest between the two matchers. This is the
//! decision gate for retiring libregexp: Perlex must be at least
//! competitive (ideally faster) on the patterns it will own.
//!
//! The calling conventions mirror `src/runtime/builtins/regexp.zig`
//! exactly: Perlex through `compileWithHooks` + `exec(u16, …, start)`
//! with the production `\p{…}` resolver and `/iu` case folder, and
//! libregexp through `lre_compile` / `lre_exec` with `cbuf_type = 1`
//! (2-byte units). Inputs are transcoded to native-endian UTF-16 — the
//! common ground the RegExp bridge already feeds both engines.
//!
//! Two metrics, measured separately because a compiled RegExp is
//! reused across many matches: compile cost (one-time) and exec
//! throughput (the figure that dominates). Two pattern families:
//! `common` (real-world web / JS regexes) and `worst` (catastrophic
//! backtracking + large-input scans).
//!
//! `zig build bench-regex` builds and runs it; forward `--filter=…`,
//! `--batches=N`, `--target-us=N`, or `--quick` after `--`.

const std = @import("std");

// `src/regex_engines.zig` bundles Perlex and its `\p{…}` / case-fold
// resolver from ONE module instance — so `perlex_props.resolve` lines
// up with `compileWithHooks`'s `Hooks` type. (A bench module rooted in
// tools/ can't relative-import ../src, so the bundle is wired as a
// named `engine` module in build.zig.)
const engine = @import("engine");
const perlex = engine.perlex;
const perlex_props = engine.perlex_props;

// translate-c view of libregexp.h (the build wires the `c` import).
const c = @import("c");

// ── libregexp flag bits (mirror regexp.zig) ────────────────────────────────
const LRE_FLAG_GLOBAL: c_int = 1 << 0;
const LRE_FLAG_IGNORECASE: c_int = 1 << 1;
const LRE_FLAG_MULTILINE: c_int = 1 << 2;
const LRE_FLAG_DOTALL: c_int = 1 << 3;
const LRE_FLAG_UNICODE: c_int = 1 << 4;
const LRE_FLAG_STICKY: c_int = 1 << 5;
const LRE_FLAG_INDICES: c_int = 1 << 6;
const LRE_FLAG_NAMED_GROUPS: c_int = 1 << 7;
const LRE_FLAG_UNICODE_SETS: c_int = 1 << 8;

// ── Host hooks libregexp links against ──────────────────────────────────────
// Defined here (not pulled from the engine) so the bench binary doesn't
// drag in the whole runtime and there's no duplicate-symbol clash. The
// realloc contract matches `runtime/c_alloc.reallocHook`: size 0 frees.

export fn lre_realloc(opaque_ptr: ?*anyopaque, ptr: ?*anyopaque, size: usize) ?*anyopaque {
    _ = opaque_ptr;
    if (size == 0) {
        if (ptr) |p| std.c.free(p);
        return null;
    }
    if (ptr) |p| return std.c.realloc(p, size);
    return std.c.malloc(size);
}

export fn lre_check_stack_overflow(opaque_ptr: ?*anyopaque, alloca_size: usize) bool {
    _ = opaque_ptr;
    _ = alloca_size;
    return false;
}

export fn lre_check_timeout(opaque_ptr: ?*anyopaque) c_int {
    _ = opaque_ptr;
    return 0;
}

// Production wires both Unicode hooks; the bench does too so a `\p{…}`
// or `/iu` pattern is owned by Perlex rather than deferred.
const perlex_hooks = perlex.Hooks{
    .resolver = perlex_props.resolve,
    .case_folder = perlex_props.caseFold,
};

// ── Corpus ──────────────────────────────────────────────────────────────────

const Category = enum { common, worst };

const Case = struct {
    cat: Category,
    name: []const u8,
    pattern: []const u8,
    flags: []const u8 = "",
    /// Input seed; repeated `repeat` times to form the match subject.
    input: []const u8,
    repeat: usize = 1,
};

const corpus = [_]Case{
    // ── common: real-world patterns, matched once ──────────────────────────
    .{ .cat = .common, .name = "literal-hit", .pattern = "needle", .input = "haystack with a needle somewhere near the end of the line" },
    .{ .cat = .common, .name = "literal-miss", .pattern = "zzqzzq", .input = "haystack with no such token anywhere along this ordinary line" },
    .{ .cat = .common, .name = "email", .pattern = "[\\w.+-]+@[\\w-]+\\.[\\w.-]+", .input = "contact: jane.doe+tag@sub.example.co.uk for details" },
    .{ .cat = .common, .name = "url", .pattern = "https?://[^\\s]+", .input = "see https://example.com/path?q=1#frag for the writeup" },
    .{ .cat = .common, .name = "iso-date", .pattern = "(\\d{4})-(\\d{2})-(\\d{2})", .input = "log entry dated 2026-05-30 at midnight UTC" },
    .{ .cat = .common, .name = "first-word", .pattern = "\\w+", .input = "   leading spaces then words follow here" },
    .{ .cat = .common, .name = "integers", .pattern = "\\d+", .input = "order #4815162342 shipped" },
    .{ .cat = .common, .name = "lower-run", .pattern = "[a-z]+", .input = "MixedCaseTextWithSomelowerruns" },
    .{ .cat = .common, .name = "anchored-num", .pattern = "^\\d+$", .input = "0123456789012345" },
    .{ .cat = .common, .name = "alternation", .pattern = "cat|dog|bird|fish", .input = "the quick brown fish jumped" },
    .{ .cat = .common, .name = "ci-word", .pattern = "hello", .flags = "i", .input = "well HELLO there, general" },
    .{ .cat = .common, .name = "multiline-anchor", .pattern = "^foo", .flags = "m", .input = "bar\nbaz\nqux\nfoobar\n" },
    .{ .cat = .common, .name = "backref-dup", .pattern = "(\\w+)\\s+\\1", .input = "the the doubled word trap" },
    .{ .cat = .common, .name = "lookahead-px", .pattern = "\\d+(?=px)", .input = "margin: 12px; padding: 4px;" },
    .{ .cat = .common, .name = "prop-letter", .pattern = "\\p{L}+", .flags = "u", .input = "café-déjà-vΩ naïve" },
    .{ .cat = .common, .name = "emoji-class", .pattern = "[\\u{1F600}-\\u{1F64F}]+", .flags = "u", .input = "reaction 😀😁😂 incoming" },

    // ── worst: catastrophic backtracking + large-input scans ───────────────
    // Exponential patterns are bounded (n≈20 → ~1M backtrack steps) so the
    // slower engine still finishes in single-digit ms.
    .{ .cat = .worst, .name = "nested-quant", .pattern = "(a+)+$", .input = "aaaaaaaaaaaaaaa!" },
    .{ .cat = .worst, .name = "alt-overlap", .pattern = "(a|a)*$", .input = "aaaaaaaaaaaaaaa!" },
    // Large-input linear scans: pattern never matches, forcing a full sweep.
    .{ .cat = .worst, .name = "scan-miss-64k", .pattern = "needle", .input = "abcdefghij ", .repeat = 6000 },
    .{ .cat = .worst, .name = "class-scan-64k", .pattern = "[0-9]{4}", .input = "abcdefghij ", .repeat = 6000 },
    .{ .cat = .worst, .name = "restart-heavy", .pattern = "abcdefgh", .input = "abcdefgX ", .repeat = 7000 },
    // Large bounded quantifiers — counted-loop lowering (body emitted once,
    // wrapped in a runtime counter) instead of inlining one copy per
    // iteration. Bounds exceed max_repeat_expand=1024, so these exercise the
    // mandatory ({n}) and optional ({n,m}) counter paths respectively.
    .{ .cat = .worst, .name = "big-bound-exact", .pattern = "[a-z]{2000}", .input = "abcdefghij", .repeat = 600 },
    .{ .cat = .worst, .name = "big-bound-range", .pattern = "[a-z]{2,5000}", .input = "abcdefghij", .repeat = 600 },
};

// ── flag builders (mirror regexp.zig) ───────────────────────────────────────

fn perlexFlags(s: []const u8) perlex.Flags {
    var f: perlex.Flags = .{};
    for (s) |ch| switch (ch) {
        'g' => f.global = true,
        'i' => f.ignore_case = true,
        'm' => f.multiline = true,
        's' => f.dot_all = true,
        'u' => f.unicode = true,
        'y' => f.sticky = true,
        'd' => f.has_indices = true,
        'v' => f.unicode_sets = true,
        else => {},
    };
    return f;
}

fn lreFlags(s: []const u8) c_int {
    var f: c_int = 0;
    for (s) |ch| switch (ch) {
        'g' => f |= LRE_FLAG_GLOBAL,
        'i' => f |= LRE_FLAG_IGNORECASE,
        'm' => f |= LRE_FLAG_MULTILINE,
        's' => f |= LRE_FLAG_DOTALL,
        'u' => f |= LRE_FLAG_UNICODE,
        'y' => f |= LRE_FLAG_STICKY,
        'd' => f |= LRE_FLAG_INDICES,
        'v' => f |= LRE_FLAG_UNICODE_SETS,
        else => {},
    };
    // §22.2.1.5 — `/v` is a Unicode mode; libregexp gates that on its
    // internal is_unicode, so pair it with `/u` (as parseFlags does).
    if ((f & LRE_FLAG_UNICODE_SETS) != 0) f |= LRE_FLAG_UNICODE;
    return f;
}

/// Transcode well-formed UTF-8 to native-endian UTF-16 code units —
/// the shared input width the RegExp bridge feeds both engines.
fn utf8ToUtf16(gpa: std.mem.Allocator, s: []const u8) ![]u16 {
    var out: std.ArrayListUnmanaged(u16) = .empty;
    errdefer out.deinit(gpa);
    var it = (std.unicode.Utf8View.init(s) catch unreachable).iterator();
    while (it.nextCodepoint()) |cp| {
        if (cp < 0x10000) {
            try out.append(gpa, @intCast(cp));
        } else {
            const v = cp - 0x10000;
            try out.append(gpa, @intCast(0xD800 + (v >> 10)));
            try out.append(gpa, @intCast(0xDC00 + (v & 0x3FF)));
        }
    }
    return out.toOwnedSlice(gpa);
}

/// Build the effective subject by repeating the seed `repeat` times.
fn buildInput(gpa: std.mem.Allocator, seed: []const u8, repeat: usize) ![]u8 {
    const buf = try gpa.alloc(u8, seed.len * repeat);
    var i: usize = 0;
    while (i < repeat) : (i += 1) @memcpy(buf[i * seed.len ..][0..seed.len], seed);
    return buf;
}

/// NUL-terminated pattern copy for libregexp's trailing-junk check.
fn nulTerminate(gpa: std.mem.Allocator, s: []const u8) ![]u8 {
    const buf = try gpa.alloc(u8, s.len + 1);
    @memcpy(buf[0..s.len], s);
    buf[s.len] = 0;
    return buf;
}

// ── timing ──────────────────────────────────────────────────────────────────

const Measure = struct { ns_per_iter: f64, inner: usize };

/// Calibrate an inner-loop count so one batch spans ~`target_ns`, then
/// take the median ns/iter over `batches` timed batches. `ctx` is any
/// struct with an `inline fn step(self) void` that runs one iteration
/// (including its own cleanup); the inline call keeps the hot loop free
/// of an indirect branch.
fn measure(io: std.Io, target_ns: u64, batches: usize, ctx: anytype) Measure {
    var inner: usize = 1;
    while (inner < (1 << 26)) : (inner *= 4) {
        const t0 = std.Io.Clock.now(.awake, io);
        var i: usize = 0;
        while (i < inner) : (i += 1) ctx.step();
        if (durNs(io, t0) >= target_ns) break;
    }

    var buf: [512]f64 = undefined;
    const nb = @min(batches, buf.len);
    for (0..nb) |b| {
        const t0 = std.Io.Clock.now(.awake, io);
        var i: usize = 0;
        while (i < inner) : (i += 1) ctx.step();
        buf[b] = @as(f64, @floatFromInt(durNs(io, t0))) / @as(f64, @floatFromInt(inner));
    }
    return .{ .ns_per_iter = median(buf[0..nb]), .inner = inner };
}

/// Nanoseconds elapsed since `t0` on the monotonic `.awake` clock.
fn durNs(io: std.Io, t0: anytype) u64 {
    return @intCast(t0.untilNow(io, .awake).toNanoseconds());
}

fn median(vals: []f64) f64 {
    if (vals.len == 0) return 0;
    std.sort.heap(f64, vals, {}, comptime std.sort.asc(f64));
    const n = vals.len;
    return if (n % 2 == 1) vals[n / 2] else (vals[n / 2 - 1] + vals[n / 2]) / 2.0;
}

fn geomean(vals: []const f64) f64 {
    if (vals.len == 0) return 0;
    var s: f64 = 0;
    for (vals) |v| s += @log(v);
    return @exp(s / @as(f64, @floatFromInt(vals.len)));
}

// ── per-engine iteration contexts ───────────────────────────────────────────

const PerlexExecCtx = struct {
    gpa: std.mem.Allocator,
    prog: *const perlex.Program,
    units: []const u16,
    sink: *u64,
    inline fn step(self: @This()) void {
        var maybe = perlex.exec(u16, self.gpa, self.prog, self.units, 0) catch unreachable;
        if (maybe) |*m| {
            self.sink.* +%= m.slots[1];
            m.deinit(self.gpa);
        } else self.sink.* +%= 1;
    }
};

const LreExecCtx = struct {
    bc: [*c]u8,
    captures: []?[*]const u8,
    cbuf: [*]const u8,
    clen: usize,
    sink: *u64,
    inline fn step(self: @This()) void {
        @memset(self.captures, null);
        const ret = c.lre_exec(@ptrCast(self.captures.ptr), self.bc, self.cbuf, 0, @intCast(self.clen), 1, null);
        if (ret > 0) {
            const base = @intFromPtr(self.cbuf);
            const e: usize = if (self.captures[1]) |p| (@intFromPtr(p) - base) / 2 else 0;
            self.sink.* +%= e;
        } else self.sink.* +%= 1;
    }
};

const PerlexCompileCtx = struct {
    gpa: std.mem.Allocator,
    pattern: []const u8,
    flags: perlex.Flags,
    sink: *u64,
    inline fn step(self: @This()) void {
        var r = perlex.compileWithHooks(self.gpa, self.pattern, self.flags, perlex_hooks) catch unreachable;
        switch (r) {
            .ok => |*p| {
                self.sink.* +%= p.group_count;
                p.deinit();
            },
            else => self.sink.* +%= 1,
        }
    }
};

const LreCompileCtx = struct {
    pattern_z: [*c]const u8,
    pattern_len: usize,
    flags: c_int,
    sink: *u64,
    inline fn step(self: @This()) void {
        var len: c_int = 0;
        var err: [128]u8 = undefined;
        const bc = c.lre_compile(&len, &err[0], err.len, self.pattern_z, self.pattern_len, self.flags, null);
        if (bc != null) {
            self.sink.* +%= @as(u64, @intCast(len));
            std.c.free(bc);
        } else self.sink.* +%= 1;
    }
};

// ── driver ──────────────────────────────────────────────────────────────────

const Opts = struct {
    target_ns: u64 = 200_000, // ~200µs/batch
    batches: usize = 32,
    filter: ?[]const u8 = null,
};

/// Thin stdout printer over the new `std.Io` model: format into a stack
/// buffer, then `writeStreamingAll`. Keeps the call sites reading like
/// `try out.print("…", .{…})`.
const Out = struct {
    io: std.Io,
    fn print(self: Out, comptime fmt: []const u8, args: anytype) !void {
        var buf: [4096]u8 = undefined;
        const s = try std.fmt.bufPrint(&buf, fmt, args);
        try std.Io.File.stdout().writeStreamingAll(self.io, s);
    }
};

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = std.heap.c_allocator; // same libc malloc both engines use

    var opts = Opts{};
    var args_iter = init.minimal.args.iterate();
    _ = args_iter.next(); // skip the binary path
    while (args_iter.next()) |arg| {
        if (std.mem.eql(u8, arg, "--quick")) {
            opts.target_ns = 50_000;
            opts.batches = 9;
        } else if (std.mem.startsWith(u8, arg, "--target-us=")) {
            opts.target_ns = (std.fmt.parseInt(u64, arg["--target-us=".len..], 10) catch 200) * 1000;
        } else if (std.mem.startsWith(u8, arg, "--batches=")) {
            opts.batches = std.fmt.parseInt(usize, arg["--batches=".len..], 10) catch 32;
        } else if (std.mem.startsWith(u8, arg, "--filter=")) {
            opts.filter = arg["--filter=".len..];
        }
    }

    const out = Out{ .io = io };
    try out.print("# Perlex vs libregexp — in-process matcher benchmark\n\n", .{});
    try out.print("Build: ReleaseFast. Timer: monotonic. Metric: median ns/iter over {d} batches (~{d}µs each).\n", .{ opts.batches, opts.target_ns / 1000 });
    try out.print("exec ratio = libregexp_ns / perlex_ns  (>1.0 → Perlex faster).\n\n", .{});

    try out.print("{s:<16} {s:<16} {s:>11} {s:>11} {s:>7}  {s:>11} {s:>11} {s:>7}  {s:>5}\n", .{
        "category", "case", "px-compile", "lre-compile", "c-ratio", "px-exec", "lre-exec", "x-ratio", "agree",
    });
    var sep: [110]u8 = undefined;
    @memset(&sep, '-');
    try out.print("{s}\n", .{&sep});

    var common_exec_ratios: std.ArrayListUnmanaged(f64) = .empty;
    defer common_exec_ratios.deinit(gpa);
    var worst_exec_ratios: std.ArrayListUnmanaged(f64) = .empty;
    defer worst_exec_ratios.deinit(gpa);
    var all_compile_ratios: std.ArrayListUnmanaged(f64) = .empty;
    defer all_compile_ratios.deinit(gpa);

    var sink: u64 = 0;

    for (corpus) |case| {
        if (opts.filter) |f| {
            if (std.mem.indexOf(u8, case.name, f) == null and
                std.mem.indexOf(u8, @tagName(case.cat), f) == null) continue;
        }

        const input_u8 = try buildInput(gpa, case.input, case.repeat);
        defer gpa.free(input_u8);
        const units = try utf8ToUtf16(gpa, input_u8);
        defer gpa.free(units);
        const pattern_z = try nulTerminate(gpa, case.pattern);
        defer gpa.free(pattern_z);

        // ── compile both engines once (for exec timing + agreement) ──
        const px_result = try perlex.compileWithHooks(gpa, case.pattern, perlexFlags(case.flags), perlex_hooks);
        const px_supported = px_result == .ok;
        var px_prog: ?perlex.Program = if (px_supported) px_result.ok else null;
        defer if (px_prog) |*p| p.deinit();

        var lre_len: c_int = 0;
        var lre_err: [128]u8 = undefined;
        const lre_bc = c.lre_compile(&lre_len, &lre_err[0], lre_err.len, @ptrCast(pattern_z.ptr), case.pattern.len, lreFlags(case.flags), null);
        defer if (lre_bc != null) std.c.free(lre_bc);
        if (lre_bc == null) {
            try out.print("{s:<16} {s:<16}  libregexp failed to compile (skipped)\n", .{ @tagName(case.cat), case.name });
            continue;
        }
        const lre_cap_count: usize = @intCast(c.lre_get_capture_count(lre_bc));
        const lre_captures = try gpa.alloc(?[*]const u8, 2 * lre_cap_count);
        defer gpa.free(lre_captures);

        // ── agreement / correctness check (one shot each) ──
        const ag = checkAgreement(gpa, px_prog, lre_bc, lre_captures, units);
        const agree = ag.agree;

        // ── compile timing ──
        const px_compile = if (px_supported) measure(io, opts.target_ns, opts.batches, PerlexCompileCtx{
            .gpa = gpa,
            .pattern = case.pattern,
            .flags = perlexFlags(case.flags),
            .sink = &sink,
        }) else Measure{ .ns_per_iter = 0, .inner = 0 };

        const lre_compile = measure(io, opts.target_ns, opts.batches, LreCompileCtx{
            .pattern_z = @ptrCast(pattern_z.ptr),
            .pattern_len = case.pattern.len,
            .flags = lreFlags(case.flags),
            .sink = &sink,
        });

        // ── exec timing ──
        const px_exec = if (px_supported) measure(io, opts.target_ns, opts.batches, PerlexExecCtx{
            .gpa = gpa,
            .prog = &px_prog.?,
            .units = units,
            .sink = &sink,
        }) else Measure{ .ns_per_iter = 0, .inner = 0 };

        const lre_exec = measure(io, opts.target_ns, opts.batches, LreExecCtx{
            .bc = lre_bc,
            .captures = lre_captures,
            .cbuf = @ptrCast(units.ptr),
            .clen = units.len,
            .sink = &sink,
        });

        // ── ratios ──
        const c_ratio: f64 = if (px_supported and px_compile.ns_per_iter > 0) lre_compile.ns_per_iter / px_compile.ns_per_iter else 0;
        const x_ratio: f64 = if (px_supported and px_exec.ns_per_iter > 0) lre_exec.ns_per_iter / px_exec.ns_per_iter else 0;
        if (px_supported) {
            try all_compile_ratios.append(gpa, c_ratio);
            switch (case.cat) {
                .common => try common_exec_ratios.append(gpa, x_ratio),
                .worst => try worst_exec_ratios.append(gpa, x_ratio),
            }
        }

        const agree_str: []const u8 = if (!px_supported) "fb" else if (agree) "yes" else "NO!";
        try out.print("{s:<16} {s:<16} {s:>11} {s:>11} {s:>7}  {s:>11} {s:>11} {s:>7}  {s:>5}\n", .{
            @tagName(case.cat),
            case.name,
            try fmtNs(gpa, px_compile.ns_per_iter, px_supported),
            try fmtNs(gpa, lre_compile.ns_per_iter, true),
            try fmtRatio(gpa, c_ratio, px_supported),
            try fmtNs(gpa, px_exec.ns_per_iter, px_supported),
            try fmtNs(gpa, lre_exec.ns_per_iter, true),
            try fmtRatio(gpa, x_ratio, px_supported),
            agree_str,
        });
        if (ag.px_owns and !ag.agree) {
            try out.print("    ↳ divergence: perlex matched={} [{d},{d})  libregexp matched={} [{d},{d})\n", .{
                ag.px_matched,  ag.px_start,  ag.px_end,
                ag.lre_matched, ag.lre_start, ag.lre_end,
            });
        }
    }

    try out.print("\n## Summary (geomean, Perlex-owned cases only)\n\n", .{});
    try out.print("  common exec speedup : {d:.2}×\n", .{geomean(common_exec_ratios.items)});
    try out.print("  worst  exec speedup : {d:.2}×\n", .{geomean(worst_exec_ratios.items)});
    try out.print("  all    compile ratio: {d:.2}×\n", .{geomean(all_compile_ratios.items)});
    try out.print("\n  (>1.0 → Perlex faster; <1.0 → libregexp faster)\n", .{});

    // Print the checksum so neither match loop is dead-code-eliminated.
    try out.print("\nchecksum: {d}\n", .{sink});
}

/// Run one match on each engine; return whether they agree on
/// match/no-match and the whole-match span. Doubles as a correctness
/// sanity check — a `NO!` means the timing comparison is apples-to-
/// oranges and the corpus entry needs review.
const Agreement = struct {
    agree: bool,
    px_owns: bool,
    px_matched: bool = false,
    px_start: usize = 0,
    px_end: usize = 0,
    lre_matched: bool = false,
    lre_start: usize = 0,
    lre_end: usize = 0,
};

fn checkAgreement(
    gpa: std.mem.Allocator,
    px_prog: ?perlex.Program,
    lre_bc: [*c]u8,
    lre_captures: []?[*]const u8,
    units: []const u16,
) Agreement {
    // libregexp side.
    @memset(lre_captures, null);
    const cbuf: [*]const u8 = @ptrCast(units.ptr);
    const lre_ret = c.lre_exec(@ptrCast(lre_captures.ptr), lre_bc, cbuf, 0, @intCast(units.len), 1, null);
    const lre_matched = lre_ret > 0;
    const base = @intFromPtr(cbuf);
    const lre_start: usize = if (lre_matched and lre_captures[0] != null) (@intFromPtr(lre_captures[0].?) - base) / 2 else 0;
    const lre_end: usize = if (lre_matched and lre_captures[1] != null) (@intFromPtr(lre_captures[1].?) - base) / 2 else 0;

    // Perlex side (only when it owns the pattern).
    if (px_prog) |prog| {
        var maybe = perlex.exec(u16, gpa, &prog, units, 0) catch {
            return .{ .agree = false, .px_owns = true, .lre_matched = lre_matched, .lre_start = lre_start, .lre_end = lre_end };
        };
        const px_matched = maybe != null;
        var px_start: usize = 0;
        var px_end: usize = 0;
        if (maybe) |*m| {
            px_start = m.slots[0];
            px_end = m.slots[1];
            m.deinit(gpa);
        }
        const agree = (px_matched == lre_matched) and (!px_matched or (px_start == lre_start and px_end == lre_end));
        return .{
            .agree = agree,
            .px_owns = true,
            .px_matched = px_matched,
            .px_start = px_start,
            .px_end = px_end,
            .lre_matched = lre_matched,
            .lre_start = lre_start,
            .lre_end = lre_end,
        };
    }
    return .{ .agree = true, .px_owns = false }; // perlex fell back — nothing to compare
}

// ── formatting (tiny fixed buffers, leaked into the c_allocator arena) ───────

fn fmtNs(gpa: std.mem.Allocator, ns: f64, present: bool) ![]const u8 {
    if (!present) return "—";
    if (ns >= 1_000_000.0) return std.fmt.allocPrint(gpa, "{d:.2}ms", .{ns / 1_000_000.0});
    if (ns >= 1_000.0) return std.fmt.allocPrint(gpa, "{d:.2}µs", .{ns / 1_000.0});
    return std.fmt.allocPrint(gpa, "{d:.1}ns", .{ns});
}

fn fmtRatio(gpa: std.mem.Allocator, r: f64, present: bool) ![]const u8 {
    if (!present or r == 0) return "—";
    return std.fmt.allocPrint(gpa, "{d:.2}x", .{r});
}
