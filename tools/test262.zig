//! test262 conformance harness.
//!
//! Walks a test262 corpus (defaults to `vendor/test262/test/`), reads
//! the YAML frontmatter from each `.js` file, applies skip rules, and
//! either parses or executes each fixture against a fresh Realm.
//! Tallies pass / fail / skip and prints a final report.
//!
//! Pre-Stage-4 TC39 proposals Cynic ships (joint-iteration, upsert)
//! are scored as their own dedicated phase sweeps — see `--phase`.
//!
//! Usage:
//!   zig build test262 -- [flags]
//!
//! Corpus & filters:
//!   --corpus=<path>         Corpus root. Default `vendor/test262/test`.
//!   --harness-dir=<path>    Harness root with sta.js / assert.js. Default
//!                           `vendor/test262/harness`.
//!   --filter=<substring>    Only attempt fixtures whose relative path contains
//!                           <substring>. Forwarded to every phase.
//!   --no-harness            Skip the sta.js + assert.js preamble. Runtime mode
//!                           only; measures the no-harness floor.
//!
//! Mode & phasing:
//!   --mode=runtime|parser   `runtime` (default) parses, compiles, executes each
//!                           fixture and matches the result against the spec
//!                           expectation. `parser` runs the parser only and
//!                           classifies on accept / reject vs negative frontmatter.
//!   --phase=<spec>          Pin the harness to one sweep instead of the default.
//!                           `--phase=main` runs only the main ECMA-262 sweep
//!                           (pre-Stage-4 fixtures excluded). `--phase=feature:<name>`
//!                           runs only that proposal's dedicated sweep (only its
//!                           realm flag on, only its tagged fixtures included).
//!                           Default: just main, unless `--write-results` is set —
//!                           then main + every tracked feature in sequence.
//!
//! Output:
//!   --quiet                 Suppress live progress on stderr.
//!   --verbose               Per-file outcome on stderr.
//!   --write-results         Replace today's row (per `mode`) in
//!                           `test262-results.md` with this run's stats.
//!                           Implies running every phase.
//!   --list-failures=<n>     After the tally, print up to N failing test paths
//!                           (main phase only).
//!
//! Iteration / parallelism:
//!   --only-failing          Skip-as-pass any fixture listed in
//!                           `.test262-pass-cache.txt`. Iterative-dev shortcut:
//!                           previously-failing tests re-run in seconds. Cache is
//!                           (re)written only on full runs (no `--filter`, no
//!                           `--only-failing`) and only by the main phase.
//!   --threads=<n>           Worker-thread count. `0` (default) = auto-detect via
//!                           `std.Thread.getCpuCount`. `1` keeps the sequential
//!                           code path. Live in-place progress is suppressed when
//!                           threads>1. Diagnostic flags below pin this to 1
//!                           after arg parsing (order-independent).
//!
//! Memory & GC tuning:
//!   --gc-threshold=<n>      Per-fixture allocation-pressure GC threshold. Default
//!                           32768. `0` falls through to the engine default.
//!   --gc-stats              Per-realm one-line stderr report after every GC cycle.
//!
//! Diagnostics (each pins --threads=1):
//!   --leak-check            Route per-fixture bytes through `std.heap.DebugAllocator`;
//!                           every unfreed allocation prints a stack trace at exit.
//!                           Pair with `--filter` — full corpus under leak-check is
//!                           10-20× slower than ReleaseFast.
//!   --max-rss=<mb>          Abort the run with exit code 2 if process RSS crosses
//!                           <mb> MiB after a fixture; print the offending path.
//!   --mem-summary           End-of-sweep one-pager: cumulative bytes allocated,
//!                           max charged peak, total GC cycles + pause.
//!   --top-alloc=<n>         Top-N fixtures by cumulative bytes allocated (≥64 KiB).
//!                           Catches allocate-and-discard thrash that `--top-rss` misses.
//!   --top-gc-time=<n>       Top-N fixtures by accumulated GC pause time (≥1 ms).
//!                           Catches GC-time-dominant fixtures even when total
//!                           bytes is moderate.
//!
//! Performance reporting (work alongside the worker pool):
//!   --top-slow=<n>          Top-N slowest fixtures (≥50 ms wall-clock).
//!   --top-rss=<n>           Top-N memory-heaviest fixtures (≥8 MiB RSS delta).
//!                           Pair with `--threads=1` for clean readings.

const std = @import("std");
const cynic = @import("cynic");

const frontmatter = @import("test262/frontmatter.zig");
const skip_rules = @import("test262/skip.zig");
const harness_mod = @import("test262/harness.zig");

/// Per-worker loader state. Set by `classifyAndRun` before
/// running a module-flagged test; consulted by
/// `test262ModuleLoader` (a process-global function pointer
/// installed on the Realm, which dispatches into whichever
/// worker is currently driving that realm). Must be
/// `threadlocal` — with the parallel pool (`--threads>1`) two
/// workers can be evaluating different module-flagged fixtures
/// at the same time; a process-global would race so the loader
/// callback resolves sibling specifiers against the wrong
/// fixture's directory, surfacing as flaky `language/module-code`
/// + `language/expressions/dynamic-import` fails that disappear
/// under `--threads=1` or a single-fixture `--filter`.
threadlocal var loader_state: ?LoaderState = null;
const LoaderState = struct {
    corpus: std.Io.Dir,
    io: std.Io,
    /// Path of the importing test, relative to the corpus root
    /// (e.g. `language/module-code/foo.js`). Used to resolve
    /// `./bar.js` to the correct sibling file.
    test_path: []const u8,
};

/// Resolve `./foo.js` against the importing module's directory
/// (extracted from `loader_state.test_path`) and read the
/// matching file from the corpus dir.
fn test262ModuleLoader(
    realm: *cynic.runtime.Realm,
    specifier: []const u8,
    base_url: ?[]const u8,
) cynic.runtime.realm.ModuleLoaderError!cynic.runtime.realm.ModuleLoadResult {
    _ = base_url; // we always resolve against `loader_state.test_path`
    const state = loader_state orelse return error.ModuleNotFound;
    const slash = std.mem.lastIndexOfScalar(u8, state.test_path, '/');
    const dir = if (slash) |i| state.test_path[0 .. i + 1] else "";

    var trimmed = specifier;
    if (std.mem.startsWith(u8, trimmed, "./")) trimmed = trimmed[2..];

    const resolved = std.fmt.allocPrint(realm.allocator, "{s}{s}", .{ dir, trimmed }) catch return error.OutOfMemory;
    const source = state.corpus.readFileAlloc(state.io, resolved, realm.allocator, .limited(8 * 1024 * 1024)) catch {
        return error.ModuleNotFound;
    };
    return .{ .url = resolved, .source = source };
}

/// `$DONE([err])` — test262 host hook for async-flagged tests.
/// Async tests call this to signal completion; if `err` is
/// supplied (not undefined), the test failed. Cynic stashes
/// the result on the realm so the runner can read it after
/// draining microtasks.
fn test262Done(
    realm: *cynic.runtime.Realm,
    this_value: cynic.runtime.Value,
    args: []const cynic.runtime.Value,
) cynic.runtime.function.NativeError!cynic.runtime.Value {
    _ = this_value;
    realm.async_done_called = true;
    if (args.len > 0) {
        realm.async_done_error = args[0];
    } else {
        realm.async_done_error = cynic.runtime.Value.undefined_;
    }
    return cynic.runtime.Value.undefined_;
}

// ── §INTERPRETING.md `$262` host shim ────────────────────────────────────────
//
// test262 fixtures access certain host capabilities through a
// global `$262` object. Cynic implements the subset that doesn't
// require fundamentally different engine architecture:
//
// • `$262.global` — reference to the global object.
// • `$262.evalScript(source)` — evaluates `source` as a Script
// in the current realm. Returns the completion value or
// throws on parse / runtime error.
// • `$262.gc()` — hint to run GC. No-op stub: Cynic doesn't
// trigger collection from inside native callbacks (the
// register/accumulator roots aren't visible to the heap from
// here), but tests that use this as a hint still pass.
// • `$262.detachArrayBuffer(buf)` — frees the underlying byte
// storage of an ArrayBuffer; subsequent typed-array reads
// throw "TypedArray detached" via the existing path.
// • `$262.createRealm()` — throws TypeError. Real cross-realm
// evaluation needs a fresh-intrinsics-shared-heap rebuild
// that's out of scope for this shim; tests gated on it skip
// via the `cross-realm` feature filter.

fn test262EvalScript(
    realm: *cynic.runtime.Realm,
    this_value: cynic.runtime.Value,
    args: []const cynic.runtime.Value,
) cynic.runtime.function.NativeError!cynic.runtime.Value {
    _ = this_value;
    if (args.len == 0 or !args[0].isString()) {
        return throwTest262TypeError(realm, "$262.evalScript: source must be a string");
    }
    const s: *cynic.runtime.JSString = @ptrCast(@alignCast(args[0].asString()));
    const result = cynic.runtime.evaluateScript(realm.allocator, realm, s.flatBytes()) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        // Parse / compile errors surface to user code as a thrown
        // SyntaxError. The exact message text isn't observable in
        // most tests; what matters is that something throws.
        else => return throwTest262SyntaxError(realm, "$262.evalScript: parse or compile error"),
    };
    switch (result) {
        .value, .yielded => |v| return v,
        .thrown => |ex| {
            realm.pending_exception = ex;
            return error.NativeThrew;
        },
    }
}

fn test262Gc(
    realm: *cynic.runtime.Realm,
    this_value: cynic.runtime.Value,
    args: []const cynic.runtime.Value,
) cynic.runtime.function.NativeError!cynic.runtime.Value {
    _ = realm;
    _ = this_value;
    _ = args;
    return cynic.runtime.Value.undefined_;
}

fn test262DetachArrayBuffer(
    realm: *cynic.runtime.Realm,
    this_value: cynic.runtime.Value,
    args: []const cynic.runtime.Value,
) cynic.runtime.function.NativeError!cynic.runtime.Value {
    _ = this_value;
    if (args.len == 0) return cynic.runtime.Value.undefined_;
    const obj = cynic.runtime.heap.valueAsPlainObject(args[0]) orelse {
        return throwTest262TypeError(realm, "$262.detachArrayBuffer: argument must be an ArrayBuffer");
    };
    if (obj.getArrayBuffer()) |ab| {
        realm.allocator.free(ab);
        obj.setArrayBuffer(realm.allocator, null) catch {};
    }
    return cynic.runtime.Value.undefined_;
}

/// `$262.createRealm()` — INTERPRETING.md. Allocates a fresh
/// `Realm` (own intrinsics + globals) sharing the parent's heap
/// so cross-realm values stay GC-safe. Returns an object shaped
/// like the parent's `$262`: `.global`, `.evalScript`, the
/// nested `.createRealm`, plus the `Function` / `Symbol` / etc.
/// constructors hoisted onto the new realm's global for tests
/// that do `other.Function`, `other.Symbol`, …
///
/// Lifetime: the child Realm is heap-allocated and registered
/// on the parent's `child_realms` list so it lives as long as
/// the parent and gets torn down with it.
fn test262CreateRealm(
    realm: *cynic.runtime.Realm,
    this_value: cynic.runtime.Value,
    args: []const cynic.runtime.Value,
) cynic.runtime.function.NativeError!cynic.runtime.Value {
    _ = this_value;
    _ = args;
    const child_ptr = realm.allocator.create(cynic.runtime.Realm) catch return error.OutOfMemory;
    child_ptr.* = cynic.runtime.Realm.initChild(realm);
    // installBuiltins wires every intrinsic constructor onto the
    // child's globals and stashes them in `child.intrinsics`.
    // The child shares the parent's heap so the allocations made
    // here outlive only the child's globals map.
    child_ptr.installBuiltins() catch return error.OutOfMemory;
    // §6.1.5.1 — well-known symbols are agent-wide. Replace the
    // child's freshly-allocated `Symbol.iterator` / etc. with
    // the parent's pointers so identity holds across realms.
    child_ptr.shareWellKnownSymbolsWith(realm) catch return error.OutOfMemory;
    realm.child_realms.append(realm.allocator, child_ptr) catch return error.OutOfMemory;

    // Build the `$262`-shaped wrapper that user JS sees.
    const wrapper = realm.heap.allocateObject() catch return error.OutOfMemory;
    wrapper.prototype = realm.intrinsics.object_prototype;

    // `.global` — the child realm's globalThis. Tests use this
    // to reach `other.global.X` for constructors and globals.
    if (child_ptr.globals.get("globalThis")) |gt| {
        wrapper.set(realm.allocator, "global", gt) catch return error.OutOfMemory;
    } else {
        wrapper.set(realm.allocator, "global", cynic.runtime.Value.undefined_) catch return error.OutOfMemory;
    }

    // Stash the child realm pointer on the wrapper. The
    // `evalScript` trampoline reads it from `this_value` and
    // dispatches into the child.
    wrapper.setHostData(realm.allocator, @ptrCast(child_ptr)) catch return error.OutOfMemory;

    // `.evalScript(source)` — evaluates `source` IN THE CHILD
    // REALM. Receiver is the wrapper, which carries the child
    // pointer in `host_data`.
    const eval_trampoline = realm.heap.allocateFunctionNative(test262ChildEvalScript, 1, "evalScript") catch return error.OutOfMemory;
    wrapper.set(realm.allocator, "evalScript", cynic.runtime.heap.taggedFunction(eval_trampoline)) catch return error.OutOfMemory;

    // Pass-through hooks — operate on the parent's heap state
    // because the relevant objects (ArrayBuffer storage etc.)
    // live there too.
    const gc_fn = realm.heap.allocateFunctionNative(test262Gc, 0, "gc") catch return error.OutOfMemory;
    wrapper.set(realm.allocator, "gc", cynic.runtime.heap.taggedFunction(gc_fn)) catch return error.OutOfMemory;

    return cynic.runtime.heap.taggedObject(wrapper);
}

/// Trampoline for `child262.evalScript(source)`. The receiver
/// is the wrapper returned by `createRealm`; its `host_data`
/// slot points at the child `Realm`.
fn test262ChildEvalScript(
    realm: *cynic.runtime.Realm,
    this_value: cynic.runtime.Value,
    args: []const cynic.runtime.Value,
) cynic.runtime.function.NativeError!cynic.runtime.Value {
    const this_obj = cynic.runtime.heap.valueAsPlainObject(this_value) orelse
        return throwTest262TypeError(realm, "$262.evalScript: bad receiver");
    const child_raw = this_obj.getHostData() orelse
        return throwTest262TypeError(realm, "$262.evalScript: missing host realm");
    const child: *cynic.runtime.Realm = @ptrCast(@alignCast(child_raw));
    if (args.len == 0 or !args[0].isString()) {
        return throwTest262TypeError(realm, "$262.evalScript: source must be a string");
    }
    const s: *cynic.runtime.JSString = @ptrCast(@alignCast(args[0].asString()));
    const result = cynic.runtime.evaluateScript(child.allocator, child, s.flatBytes()) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return throwTest262SyntaxError(realm, "$262.evalScript: parse or compile error"),
    };
    switch (result) {
        .value, .yielded => |v| return v,
        .thrown => |ex| {
            realm.pending_exception = ex;
            return error.NativeThrew;
        },
    }
}

/// Wrap `intrinsics.newTypeError` for the harness — installs
/// the value into `pending_exception` and signals via the
/// native-throw error code that the interpreter dispatcher
/// reads.
fn throwTest262TypeError(realm: *cynic.runtime.Realm, msg: []const u8) cynic.runtime.function.NativeError {
    const ex = cynic.runtime.intrinsics.newTypeError(realm, msg) catch return error.OutOfMemory;
    realm.pending_exception = ex;
    return error.NativeThrew;
}

fn throwTest262SyntaxError(realm: *cynic.runtime.Realm, msg: []const u8) cynic.runtime.function.NativeError {
    const ex = cynic.runtime.intrinsics.newSyntaxError(realm, msg) catch return error.OutOfMemory;
    realm.pending_exception = ex;
    return error.NativeThrew;
}

/// Install the `$262` host object on `realm.globals`. Idempotent
/// per realm (caller invokes once, before evaluating user code).
fn install262(realm: *cynic.runtime.Realm) !void {
    const heap = realm.heap;
    const obj = try heap.allocateObject();
    obj.prototype = realm.intrinsics.object_prototype;

    // `$262.global` — reference the existing globalThis snapshot.
    // Tests that expect `$262.global === globalThis` get the same
    // object identity here.
    if (realm.globals.get("globalThis")) |gt| {
        try obj.set(realm.allocator, "global", gt);
    } else {
        try obj.set(realm.allocator, "global", cynic.runtime.Value.undefined_);
    }

    const eval_fn = try heap.allocateFunctionNative(test262EvalScript, 1, "evalScript");
    try obj.set(realm.allocator, "evalScript", cynic.runtime.heap.taggedFunction(eval_fn));

    const gc_fn = try heap.allocateFunctionNative(test262Gc, 0, "gc");
    try obj.set(realm.allocator, "gc", cynic.runtime.heap.taggedFunction(gc_fn));

    const detach_fn = try heap.allocateFunctionNative(test262DetachArrayBuffer, 1, "detachArrayBuffer");
    try obj.set(realm.allocator, "detachArrayBuffer", cynic.runtime.heap.taggedFunction(detach_fn));

    const cr_fn = try heap.allocateFunctionNative(test262CreateRealm, 0, "createRealm");
    try obj.set(realm.allocator, "createRealm", cynic.runtime.heap.taggedFunction(cr_fn));

    // Cynic doesn't have `IsHTMLDDA` — that feature is on our
    // skip list. We install nothing for it; tests that need it
    // skip out via `features:`.

    try realm.globals.put(realm.allocator, "$262", cynic.runtime.heap.taggedObject(obj));
}

test {
    // Force the test runner to walk the helper modules so their inline
    // `test` blocks are picked up under `zig build test`.
    _ = frontmatter;
    _ = skip_rules;
    _ = harness_mod;
}

const Outcome = enum {
    pass_positive,
    pass_negative,
    fail_false_reject, // we rejected legal code
    fail_false_accept, // we accepted code that should be a parse error
    skip,
};

const SkipReason = enum {
    by_path,
    no_strict,
    raw_flag,
    has_includes,
    runtime_phase,
    unsupported_feature,
    no_frontmatter,
    malformed_frontmatter,
    /// Fixture is filtered out of the current sweep's `Phase`.
    /// The main phase excludes any fixture tagged with a tracked
    /// pre-Stage-4 proposal; each `feature:<flag>` phase only
    /// admits fixtures tagged with exactly that flag. Out-of-phase
    /// fixtures are ignored entirely — they don't bump `stats`,
    /// don't enter buckets, and don't enter the pass cache. The
    /// per-feature scoreboard is sourced from dedicated phase
    /// sweeps, each with only its one flag enabled.
    out_of_phase,
};

const Mode = enum { parser, runtime };

const Options = struct {
    corpus: []const u8 = "vendor/test262/test",
    filter: ?[]const u8 = null,
    list_failures: u32 = 0,
    quiet: bool = false,
    verbose: bool = false,
    write_results: bool = false,
    /// `runtime` is the headline mode — parses, compiles, executes
    /// each fixture and compares the result to the spec expectation.
    /// `parser` runs the parser only and is useful when iterating on
    /// parser changes in isolation; opt into it with `--mode=parser`.
    mode: Mode = .runtime,
    /// When set in `runtime` mode, prepend `harness/sta.js` and
    /// `harness/assert.js` to every test source. Default: enabled.
    /// Disable via `--no-harness` to measure the no-harness floor.
    /// Has no effect in `parser` mode.
    preload_harness: bool = true,
    /// Path to the harness directory (relative to cwd). Defaults
    /// to a sibling of the corpus root.
    harness_dir: []const u8 = "vendor/test262/harness",
    /// Iterative-dev shortcut. When true, load
    /// `.test262-pass-cache.txt` and skip-as-pass any test path
    /// listed in it; only previously-failing or previously-skipped
    /// tests actually run. The cache is populated only on full
    /// runs (no `--filter`, no `--only-failing`).
    only_failing: bool = false,
    /// Worker-thread count. `0` (default) = auto-detect via
    /// `std.Thread.getCpuCount`. `1` keeps the original sequential
    /// code path (no spawn, no mutex, in-place progress line).
    /// Values >1 spawn that many workers off a shared atomic path
    /// index; each worker has its own arena + per-test bookkeeping
    /// and merges into the global `Stats` / `BucketMap` under a
    /// mutex at exit. Live in-place progress is suppressed when
    /// threads>1 because workers would otherwise interleave \r
    /// updates.
    threads: u32 = 0,
    /// Per-fixture wall-clock watchdog deadline, in seconds. The
    /// progress monitor names any worker stuck on one fixture
    /// longer than this — so a wedged sweep identifies its fixture
    /// instead of leaving you to bisect. `0` disables. Default 60:
    /// long enough that only a genuine hang trips it.
    timeout_s: u32 = 60,
    /// Per-test allocation-pressure GC threshold. Forwarded to
    /// each fresh realm's `heap.gc_threshold` before the body
    /// runs. Default 32,768 — sweet spot between memory bound
    /// and wall-time. The three closed root gaps (frame stacks,
    /// promise reactions, key anchors), chunk-pin, packed-array
    /// elements, and the iterator-accessor walks together mean
    /// the per-fixture mark cost is bounded and the pathological
    /// 16M-iter loops break early on the throw — so we don't
    /// need an aggressive 4K threshold to keep RSS in check.
    /// `0` falls through to the engine default.
    gc_threshold: u32 = 32768,
    /// When true, every per-fixture realm prints a one-line
    /// stderr report after every GC cycle. Diagnostic for
    /// finding leaks or oversized roots; pair with `--filter`
    /// to keep the output sane.
    gc_stats: bool = false,
    /// When >0, print the top-N slowest fixtures after the
    /// final tally. V8 (`--trace-test-runtime`) and JSC's
    /// run-jsc-tests both surface this — long-tail outliers
    /// dominate wall-time and are the first thing to debug
    /// when a sweep starts to feel slow. Captures wall-clock
    /// per fixture; only fixtures over `slow_threshold_ms`
    /// (50ms) are recorded to keep the per-worker buffer cheap.
    top_slow: u32 = 0,
    /// When >0, print the top-N memory-heaviest fixtures after
    /// the final tally. Captures the per-fixture RSS delta
    /// (process RSS after the fixture minus before). Use with
    /// `--threads=1` for clean readings — with multiple workers
    /// the deltas are racy because RSS is a process-wide watermark.
    /// Only fixtures over `heavy_threshold_mb` (8 MiB) are
    /// recorded to keep noise out.
    top_rss: u32 = 0,
    /// When true, the per-fixture `bytes_allocator` (used for
    /// large heap-owned byte payloads — `JSString.bytes`,
    /// ArrayBuffer slabs) is routed through `std.heap.DebugAllocator`
    /// instead of the default `gpa`. The DebugAllocator detects
    /// every unfreed allocation at process exit and prints a
    /// stack trace per leak — turning "RSS climbed by 200 MiB"
    /// into "this exact call site leaked N bytes." Forces
    /// `--threads=1` because DebugAllocator is not thread-safe.
    /// Pair with `--filter` — running the full corpus under
    /// leak-check is 10-20× slower than ReleaseFast.
    leak_check: bool = false,
    /// Process-RSS budget in MiB. When >0 and the post-fixture
    /// RSS exceeds the budget, the harness prints the offending
    /// fixture path + RSS reading and aborts the run with a
    /// non-zero exit code. Complements `--leak-check`:
    /// `--leak-check` reports unfreed allocations at exit;
    /// `--max-rss` traps the run at the fixture where growth
    /// crossed the budget, so a sweep that's about to hang the
    /// laptop fails fast with a pointer instead. Single-thread
    /// only (process RSS is racy with multiple workers); the
    /// flag parser pins `--threads=1`.
    max_rss_mb: u32 = 0,
    /// When true, print an end-of-sweep memory summary: cumulative
    /// bytes allocated, max charged peak, total GC cycles + pause.
    /// Different signal from `--top-rss` (per-fixture RSS peak)
    /// and `--top-alloc` (top-N cumulative). Forces `--threads=1`.
    mem_summary: bool = false,
    /// When >0, print the top-N fixtures by cumulative bytes
    /// allocated via `heap.bytes_alloc_total`. Captures allocate-
    /// and-discard workloads that `--top-rss` misses. Forces
    /// `--threads=1`.
    top_alloc: u32 = 0,
    /// When >0, print the top-N fixtures by accumulated GC pause
    /// time (via `heap.gc_time_ns_total`). Catches fixtures that
    /// burn wall-time in GC — different signal from `--top-alloc`
    /// (which counts bytes) and `--top-rss` (which captures peak
    /// live). Forces `--threads=1`.
    top_gc_time: u32 = 0,
    /// Explicit phase override. `null` (default) means: run only the
    /// main phase unless `--write-results` is set, in which case
    /// run main + every tracked pre-Stage-4 feature in dedicated
    /// per-feature sweeps. Setting this pins the harness to one
    /// phase regardless of `--write-results`. Accepted spellings:
    /// `--phase=main`, `--phase=feature:<flag>` (e.g. `feature:joint-iteration`).
    phase: ?Phase = null,
};

/// Path of the pass-cache, written at the repo root after every
/// full run and consumed by `--only-failing`.
const pass_cache_path = ".test262-pass-cache.txt";

const Stats = struct {
    total: u32 = 0,
    pass_pos: u32 = 0,
    pass_neg: u32 = 0,
    fail_reject: u32 = 0,
    fail_accept: u32 = 0,
    skip: u32 = 0,
    pos_attempted: u32 = 0,
    neg_attempted: u32 = 0,

    fn pass(self: *const Stats) u32 {
        return self.pass_pos + self.pass_neg;
    }
    fn fail(self: *const Stats) u32 {
        return self.fail_reject + self.fail_accept;
    }
};

/// What kind of outcome to record for a bucket. Mirrors the
/// three-way grouping the rolled-up `Stats` already uses.
const BucketKind = enum { pass, fail, skip };

/// Per-area counters. The `name` is the first two path
/// components of the test262 fixture (e.g. `built-ins/Set`,
/// `language/expressions`); single-component fixtures use that
/// component alone. `pass + fail + skip == total`.
const Bucket = struct {
    name: []const u8,
    pass: u32 = 0,
    fail: u32 = 0,
    skip: u32 = 0,
    total: u32 = 0,
};

/// Bucket the relative test path on its first two components
/// (or the first one if that's all there is). Returns a slice
/// borrowed from `rel`.
fn bucketName(rel: []const u8) []const u8 {
    const slash1 = std.mem.indexOfScalar(u8, rel, '/') orelse return rel;
    const slash2 = std.mem.indexOfScalarPos(u8, rel, slash1 + 1, '/') orelse return rel[0..slash1];
    return rel[0..slash2];
}

/// Map-keyed accumulator. Owns its `name` slices once a row is
/// written via `bump`, so callers can free the originals safely.
const BucketMap = struct {
    gpa: std.mem.Allocator,
    map: std.StringHashMapUnmanaged(Bucket) = .empty,

    fn init(gpa: std.mem.Allocator) BucketMap {
        return .{ .gpa = gpa };
    }
    fn deinit(self: *BucketMap) void {
        var it = self.map.iterator();
        while (it.next()) |entry| self.gpa.free(entry.key_ptr.*);
        self.map.deinit(self.gpa);
    }

    /// Record a single fixture's outcome for its bucket. `name`
    /// is borrowed; we dupe on insert.
    fn bump(self: *BucketMap, name: []const u8, kind: BucketKind) !void {
        const gop = try self.map.getOrPut(self.gpa, name);
        if (!gop.found_existing) {
            gop.key_ptr.* = try self.gpa.dupe(u8, name);
            gop.value_ptr.* = .{ .name = gop.key_ptr.* };
        }
        switch (kind) {
            .pass => gop.value_ptr.pass += 1,
            .fail => gop.value_ptr.fail += 1,
            .skip => gop.value_ptr.skip += 1,
        }
        gop.value_ptr.total += 1;
    }

    /// Materialise an owned slice of buckets sorted into
    /// fail-magnitude tiers, alphabetical within each tier.
    /// The tiers are:
    ///   • 1000+ fails  (whole-language buckets, the long tail)
    ///   • 100–999      (mid-volume — feature areas with real gaps)
    ///   • 10–99        (small areas / partial features)
    ///   • 1–9          (polish)
    ///   • 0            (fully passing OR fully OOS-skipped — bottom)
    /// Within a tier, sort by name so the table is scannable —
    /// readers usually want "where's `built-ins/Promise`?", not
    /// "what's at row 14?". A pure raw-fail-desc sort buried
    /// related areas (all the `built-ins/*` typed-array siblings,
    /// say) at random heights; tiering keeps them together while
    /// still surfacing the heavy-hitter tier at the top.
    fn sortedByFailTiered(self: *const BucketMap, gpa: std.mem.Allocator) ![]Bucket {
        var out = try gpa.alloc(Bucket, self.map.count());
        var it = self.map.iterator();
        var i: usize = 0;
        while (it.next()) |entry| : (i += 1) out[i] = entry.value_ptr.*;
        std.mem.sort(Bucket, out, {}, struct {
            fn tier(fail: u32) u8 {
                if (fail == 0) return 4;
                if (fail < 10) return 3;
                if (fail < 100) return 2;
                if (fail < 1000) return 1;
                return 0;
            }
            fn lt(_: void, a: Bucket, b: Bucket) bool {
                const ta = tier(a.fail);
                const tb = tier(b.fail);
                if (ta != tb) return ta < tb;
                return std.mem.order(u8, a.name, b.name) == .lt;
            }
        }.lt);
        return out;
    }
};

/// TC39 proposals at Stage 1–3 that Cynic ships ahead of the
/// published edition. The list of flags lives next to the engine
/// (`src/runtime/features.zig`); the harness binds the same set
/// here so adding a new proposal in one place picks up the
/// per-feature scoreboard automatically. Each name matches a
/// frontmatter `features:` tag in upstream test262.
const FeatureFlag = cynic.runtime.FeatureFlag;
const tracked_pre_stage4_features = blk: {
    const fields = @typeInfo(FeatureFlag).@"enum".fields;
    var arr: [fields.len][]const u8 = undefined;
    for (fields, 0..) |f, i| {
        const tag: FeatureFlag = @enumFromInt(f.value);
        arr[i] = tag.name();
    }
    break :blk arr;
};

/// Bitmask of which tracked features a single fixture's
/// frontmatter referenced. Sized to `u32` — comfortable headroom
/// for the handful of proposals we ever expect to track at once.
const PreStage4Mask = u32;

fn computePreStage4Mask(features: []const []const u8) PreStage4Mask {
    var mask: PreStage4Mask = 0;
    for (features) |feat| {
        for (tracked_pre_stage4_features, 0..) |name, idx| {
            if (std.mem.eql(u8, feat, name)) mask |= (@as(PreStage4Mask, 1) << @intCast(idx));
        }
    }
    return mask;
}

/// Per-feature outcome counters. `slots[i]` mirrors
/// `tracked_pre_stage4_features[i]`. Workers accumulate locally
/// and `merge` rolls up under `merge_mu` at worker exit — same
/// shape as `BucketMap` so the contention model is identical.
const PreStage4Stats = struct {
    slots: [tracked_pre_stage4_features.len]Bucket = @splat(.{ .name = "" }),

    fn bump(self: *PreStage4Stats, mask: PreStage4Mask, kind: BucketKind) void {
        if (mask == 0) return;
        var i: usize = 0;
        while (i < tracked_pre_stage4_features.len) : (i += 1) {
            if ((mask & (@as(PreStage4Mask, 1) << @intCast(i))) == 0) continue;
            const slot = &self.slots[i];
            switch (kind) {
                .pass => slot.pass += 1,
                .fail => slot.fail += 1,
                .skip => slot.skip += 1,
            }
            slot.total += 1;
        }
    }

    fn merge(dst: *PreStage4Stats, src: *const PreStage4Stats) void {
        for (&dst.slots, src.slots) |*d, s| {
            d.pass += s.pass;
            d.fail += s.fail;
            d.skip += s.skip;
            d.total += s.total;
        }
    }
};

/// One sweep's selector. The main phase scores stable ECMA-262
/// only — any fixture whose frontmatter references a tracked
/// pre-Stage-4 proposal is filtered out before it can land in
/// `stats`. Each `.feature` phase runs a dedicated sweep with
/// only its one flag enabled, so the per-feature scoreboard
/// reflects what each proposal looks like in isolation (a
/// `joint-iteration` fixture runs in a realm where
/// `Map.prototype.getOrInsert` is undefined, and vice versa).
const Phase = union(enum) {
    main,
    feature: cynic.runtime.FeatureFlag,

    /// FeatureSet to install on the per-fixture realm. Main
    /// returns empty (no proposals); a feature phase returns a
    /// singleton set with only its flag.
    fn realmFeatures(self: Phase) cynic.runtime.FeatureSet {
        return switch (self) {
            .main => cynic.runtime.FeatureSet.initEmpty(),
            .feature => |f| blk: {
                var s = cynic.runtime.FeatureSet.initEmpty();
                s.insert(f);
                break :blk s;
            },
        };
    }

    /// Phase membership predicate for a fixture, given its
    /// pre-Stage-4 frontmatter bitmask. Main admits only fixtures
    /// that reference no tracked proposal (mask == 0); a feature
    /// phase admits only fixtures whose mask has the matching bit.
    fn includesFixture(self: Phase, pre_stage4_mask: PreStage4Mask) bool {
        return switch (self) {
            .main => pre_stage4_mask == 0,
            .feature => |f| has: {
                const idx: usize = @intFromEnum(f);
                const bit = @as(PreStage4Mask, 1) << @intCast(idx);
                break :has (pre_stage4_mask & bit) != 0;
            },
        };
    }

    /// Short label for progress prefixes and the per-phase tally
    /// banner. `"main"` for the headline sweep; the feature's
    /// `name()` (kebab-case, same string as the test262
    /// frontmatter `features:` tag) for proposal sweeps.
    fn label(self: Phase) []const u8 {
        return switch (self) {
            .main => "main",
            .feature => |f| f.name(),
        };
    }
};

/// Set of relative test paths that passed in the previous full
/// run. Backed by `StringHashMapUnmanaged(void)` for set
/// semantics. Owns its keys (each is `gpa.dupe`'d on insert).
const PassCache = struct {
    map: std.StringHashMapUnmanaged(void) = .empty,

    const empty: PassCache = .{};

    fn deinit(self: *PassCache, gpa: std.mem.Allocator) void {
        var it = self.map.iterator();
        while (it.next()) |entry| gpa.free(entry.key_ptr.*);
        self.map.deinit(gpa);
    }

    fn contains(self: *const PassCache, rel: []const u8) bool {
        return self.map.contains(rel);
    }

    /// Insert a relative path, deduping. Dupes the slice into
    /// `gpa` so it outlives the caller's buffer.
    fn put(self: *PassCache, gpa: std.mem.Allocator, rel: []const u8) !void {
        const gop = try self.map.getOrPut(gpa, rel);
        if (!gop.found_existing) gop.key_ptr.* = try gpa.dupe(u8, rel);
    }
};

/// Load `.test262-pass-cache.txt` (one path per line) into
/// `out`. Missing file is treated as an empty set — the next run
/// will execute everything and rewrite the cache.
fn loadPassCache(
    gpa: std.mem.Allocator,
    io: std.Io,
    cwd: std.Io.Dir,
    out: *PassCache,
) !void {
    // Cap at 16 MiB — a corpus of ~50k paths × ~80 bytes is well
    // under that, and the cap protects against a corrupted file.
    const data = cwd.readFileAlloc(io, pass_cache_path, gpa, .limited(16 * 1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer gpa.free(data);

    var it = std.mem.tokenizeScalar(u8, data, '\n');
    while (it.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;
        try out.put(gpa, trimmed);
    }
}

/// Write `.test262-pass-cache.txt` (sorted, one path per line).
/// Sorting makes the file deterministic across runs so diffs
/// over time stay readable.
fn writePassCache(
    gpa: std.mem.Allocator,
    io: std.Io,
    cwd: std.Io.Dir,
    paths: []const []const u8,
) !void {
    const sorted = try gpa.alloc([]const u8, paths.len);
    defer gpa.free(sorted);
    @memcpy(sorted, paths);
    std.mem.sort([]const u8, sorted, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lt);

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(gpa);
    for (sorted) |p| {
        try buf.appendSlice(gpa, p);
        try buf.append(gpa, '\n');
    }
    try cwd.writeFile(io, .{ .sub_path = pass_cache_path, .data = buf.items });
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;

    var opts = try parseArgs(gpa, init.minimal.args);
    defer freeArgs(gpa, &opts);

    const cwd = std.Io.Dir.cwd();
    var corpus = cwd.openDir(io, opts.corpus, .{ .iterate = true }) catch |err| {
        var line: [512]u8 = undefined;
        const msg = try std.fmt.bufPrint(&line, "error: cannot open corpus '{s}': {t}\n", .{ opts.corpus, err });
        try std.Io.File.stderr().writeStreamingAll(io, msg);
        std.process.exit(1);
    };
    defer corpus.close(io);

    // Optionally read the harness sources once. Concatenated to
    // every test source in runtime mode unless `--no-harness`.
    var harness_sources: ?harness_mod.HarnessSources = null;
    defer if (harness_sources) |*h| h.deinit(gpa);
    if (opts.mode == .runtime and opts.preload_harness) {
        var harness_dir = cwd.openDir(io, opts.harness_dir, .{ .iterate = true }) catch |err| {
            var line: [512]u8 = undefined;
            const msg = try std.fmt.bufPrint(&line, "error: cannot open harness '{s}': {t}\n", .{ opts.harness_dir, err });
            try std.Io.File.stderr().writeStreamingAll(io, msg);
            std.process.exit(1);
        };
        defer harness_dir.close(io);
        harness_sources = harness_mod.load(gpa, io, harness_dir) catch |err| {
            var line: [512]u8 = undefined;
            const msg = try std.fmt.bufPrint(&line, "error: cannot load harness: {t}\n", .{err});
            try std.Io.File.stderr().writeStreamingAll(io, msg);
            std.process.exit(1);
        };
    }

    // Phase plan. Default: just main. With `--write-results` (and
    // no explicit `--phase`), populate every row of the per-feature
    // scoreboard by running main + every tracked feature in its
    // own sweep. An explicit `--phase` pins us to that one.
    const tracked_count = @typeInfo(cynic.runtime.FeatureFlag).@"enum".fields.len;
    var phases_buf: [tracked_count + 1]Phase = undefined;
    var phases_len: usize = 0;
    if (opts.phase) |p| {
        phases_buf[0] = p;
        phases_len = 1;
    } else if (opts.write_results) {
        phases_buf[0] = .main;
        phases_len = 1;
        inline for (@typeInfo(cynic.runtime.FeatureFlag).@"enum".fields) |f| {
            phases_buf[phases_len] = .{ .feature = @enumFromInt(f.value) };
            phases_len += 1;
        }
    } else {
        phases_buf[0] = .main;
        phases_len = 1;
    }

    var main_result: ?PhaseResult = null;
    defer if (main_result) |*r| r.deinit(gpa);
    var feature_results: [tracked_count]?PhaseResult = @splat(null);
    defer for (&feature_results) |*slot| if (slot.*) |*pr| pr.deinit(gpa);

    for (phases_buf[0..phases_len]) |phase| {
        const res = try runSweep(gpa, io, cwd, corpus, harness_sources, &opts, phase);
        switch (phase) {
            .main => {
                if (main_result) |*old| old.deinit(gpa);
                main_result = res;
            },
            .feature => |f| {
                const idx: usize = @intFromEnum(f);
                if (feature_results[idx]) |*old| old.deinit(gpa);
                feature_results[idx] = res;
            },
        }
    }

    // Score-row write: only off the main phase. Pre-Stage-4 per-feature
    // rows come from the dedicated phase sweeps we just ran (each in a
    // realm with only its one flag enabled), folded into a
    // `PreStage4Stats` for `writeResults`.
    if (opts.write_results) {
        var pre_stage4: PreStage4Stats = .{};
        for (feature_results, 0..) |maybe_r, i| {
            if (maybe_r) |r| {
                pre_stage4.slots[i] = .{
                    .name = tracked_pre_stage4_features[i],
                    .pass = r.stats.pass(),
                    .fail = r.stats.fail(),
                    .skip = r.stats.skip,
                    .total = r.stats.total,
                };
            }
        }
        if (main_result) |*mr| {
            const is_full = opts.filter == null and !opts.only_failing;
            const elapsed_for_row: ?u64 = if (is_full and mr.elapsed_ms > 0) @intCast(mr.elapsed_ms) else null;
            const now_ts = std.Io.Clock.now(.real, io);
            try writeResults(gpa, io, &mr.stats, &mr.buckets, &pre_stage4, now_ts.toSeconds(), opts.mode, elapsed_for_row);
        }
    }

    // Refresh the pass cache from the main phase only. Per-feature
    // phases never contribute to the cache — `--only-failing` always
    // re-runs them (they're tiny and their pass set is realm-flag-
    // dependent, so caching across flag configurations would lie).
    if (main_result) |*mr| {
        const is_full = opts.filter == null and !opts.only_failing;
        if (is_full) try writePassCache(gpa, io, cwd, mr.pass_paths.items);
    }
}

/// Execute one phase's sweep — main or a single pre-Stage-4
/// feature. Walks the corpus, dispatches `classifyAndRun` per
/// fixture, captures per-fixture diagnostics (slow / heavy / alloc
/// / gc-time / mem), prints the per-phase tally, and returns the
/// rolled-up `PhaseResult` so the caller can compose the score
/// row across phases. Per-phase diagnostic captures (`--top-slow`,
/// `--top-rss`, …) only print for the main phase — they're tied
/// to the headline ECMA-262 sweep, not the proposal-only mini-runs.
fn runSweep(
    gpa: std.mem.Allocator,
    io: std.Io,
    cwd: std.Io.Dir,
    corpus: std.Io.Dir,
    harness_sources: ?harness_mod.HarnessSources,
    opts: *const Options,
    phase: Phase,
) !PhaseResult {
    // Cynic-scoped tally. Paths Cynic considers out of scope
    // (Annex B language extensions, browser-era built-ins) are
    // dropped from the denominator entirely — spec% means
    // "fraction of Cynic-targeted tests that pass."
    var stats: Stats = .{};
    var failures: std.ArrayListUnmanaged(Failure) = .empty;
    errdefer {
        for (failures.items) |f| gpa.free(f.path);
        failures.deinit(gpa);
    }
    var buckets: BucketMap = .init(gpa);
    errdefer buckets.deinit();
    var pass_paths: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer {
        for (pass_paths.items) |p| gpa.free(p);
        pass_paths.deinit(gpa);
    }
    var slow: std.ArrayListUnmanaged(SlowEntry) = .empty;
    defer {
        for (slow.items) |e| gpa.free(e.path);
        slow.deinit(gpa);
    }
    var heavy: std.ArrayListUnmanaged(HeavyEntry) = .empty;
    defer {
        for (heavy.items) |e| gpa.free(e.path);
        heavy.deinit(gpa);
    }
    var alloc_list: std.ArrayListUnmanaged(AllocEntry) = .empty;
    defer {
        for (alloc_list.items) |e| gpa.free(e.path);
        alloc_list.deinit(gpa);
    }
    var gc_time_list: std.ArrayListUnmanaged(GcTimeEntry) = .empty;
    defer {
        for (gc_time_list.items) |e| gpa.free(e.path);
        gc_time_list.deinit(gpa);
    }
    var mem_agg: MemAggregate = .{};

    // `--only-failing` shortcut: only the main phase consults the
    // pass cache. Per-feature phases run the (tiny) tagged-fixture
    // set every time — the pass cache is by-path and doesn't
    // distinguish realms with different proposals installed.
    var pass_cache: PassCache = .empty;
    defer pass_cache.deinit(gpa);
    const load_pass_cache = phase == .main and opts.only_failing;
    if (load_pass_cache) {
        try loadPassCache(gpa, io, cwd, &pass_cache);
    }

    // A "full run" is the only time the main phase (re)writes the
    // cache. Per-feature phases never contribute to the cache so
    // their `is_full_run` value is moot (their `pass_paths` stays
    // empty downstream).
    const is_full_run = opts.filter == null and !opts.only_failing and phase == .main;

    const start_ts = std.Io.Clock.now(.awake, io);

    // Walk the corpus once, materialising every test path into an
    // owned `[]const u8`. Cheap filters (extension, `_FIXTURE`,
    // `--filter` substring, OOS path table, universal-skip path
    // table) are applied here so workers never see paths they
    // would just discard. Frontmatter-driven skips and the
    // phase-membership filter still happen inside `classifyAndRun`
    // because they require reading the file.
    var paths: std.ArrayListUnmanaged([]const u8) = .empty;
    defer {
        for (paths.items) |p| gpa.free(p);
        paths.deinit(gpa);
    }
    {
        var walker = try corpus.walk(gpa);
        defer walker.deinit();
        while (try walker.next(io)) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, entry.basename, ".js")) continue;
            if (std.mem.endsWith(u8, entry.basename, "_FIXTURE.js")) continue;
            if (opts.filter) |needle| {
                if (std.mem.indexOf(u8, entry.path, needle) == null) continue;
            }
            if (skip_rules.pathIsSkipped(entry.path)) continue;
            if (skip_rules.pathIsCynicOutOfScope(entry.path)) continue;
            try paths.append(gpa, try gpa.dupe(u8, entry.path));
        }
    }

    // Decide thread count. `0` (default) → auto-detect; `1` keeps
    // the original sequential code path. `getCpuCount` clamps to ≥1.
    const auto_threads: u32 = blk: {
        if (opts.threads != 0) break :blk opts.threads;
        const n = std.Thread.getCpuCount() catch 1;
        break :blk @intCast(@min(n, std.math.maxInt(u32)));
    };
    const thread_count: u32 = @max(auto_threads, 1);

    if (thread_count <= 1) {
        // Sequential path. `--leak-check` swaps the per-fixture
        // bytes allocator for a `DebugAllocator` (single-threaded
        // only — the flag parser already pins threads=1).
        var per_file_arena: std.heap.ArenaAllocator = .init(gpa);
        defer per_file_arena.deinit();

        var leak_check_alloc: std.heap.DebugAllocator(.{}) = .init;
        defer if (opts.leak_check) {
            const status = leak_check_alloc.deinit();
            if (status == .leak) {
                std.Io.File.stderr().writeStreamingAll(
                    io,
                    "test262 --leak-check: DebugAllocator reported leaks (see trace above)\n",
                ) catch {};
            } else {
                std.Io.File.stderr().writeStreamingAll(
                    io,
                    "test262 --leak-check: clean — no leaked allocations\n",
                ) catch {};
            }
        };
        const bytes_allocator: std.mem.Allocator =
            if (opts.leak_check) leak_check_alloc.allocator() else gpa;

        for (paths.items) |rel| {
            if (opts.only_failing and pass_cache.contains(rel)) {
                stats.total += 1;
                stats.pass_pos += 1;
                stats.pos_attempted += 1;
                try buckets.bump(bucketName(rel), .pass);
                if (opts.verbose) {
                    try printVerbose(io, rel, .{ .kind = .pass_positive });
                } else if (!opts.quiet and stats.total % 500 == 0) {
                    try printProgress(io, &stats);
                }
                continue;
            }

            _ = per_file_arena.reset(.free_all);
            const arena = per_file_arena.allocator();

            const harness_pair: ?harness_mod.HarnessSources = harness_sources;
            const fx_start = if (opts.top_slow > 0) std.Io.Clock.now(.awake, io) else undefined;
            const fx_rss_pre: u64 = if (opts.top_rss > 0) (currentRssMb() orelse 0) else 0;
            const need_mem = opts.mem_summary or opts.top_alloc > 0 or opts.top_gc_time > 0;
            var fx_mem: FixtureMem = .{};
            const outcome = try classifyAndRun(arena, bytes_allocator, io, corpus, rel, opts.mode, harness_pair, opts.gc_threshold, opts.gc_stats, if (need_mem) &fx_mem else null, phase);
            if (need_mem) {
                mem_agg.add(fx_mem);
                if (opts.top_alloc > 0) {
                    const kb = fx_mem.bytes_alloc_total / 1024;
                    if (kb >= alloc_threshold_kb) {
                        try alloc_list.append(gpa, .{ .path = try gpa.dupe(u8, rel), .kb = kb });
                    }
                }
                if (opts.top_gc_time > 0) {
                    const us = fx_mem.gc_time_ns / 1000;
                    if (us >= gc_time_threshold_us) {
                        try gc_time_list.append(gpa, .{ .path = try gpa.dupe(u8, rel), .us = us });
                    }
                }
            }
            if (opts.top_slow > 0) {
                const ms_i = fx_start.untilNow(io, .awake).toMilliseconds();
                const ms_u: u64 = if (ms_i > 0) @intCast(ms_i) else 0;
                if (ms_u >= slow_threshold_ms) {
                    try slow.append(gpa, .{ .path = try gpa.dupe(u8, rel), .ms = ms_u });
                }
            }
            if (opts.top_rss > 0) {
                const rss_post: u64 = currentRssMb() orelse fx_rss_pre;
                const delta: u64 = if (rss_post > fx_rss_pre) rss_post - fx_rss_pre else 0;
                if (delta >= heavy_threshold_mb) {
                    try heavy.append(gpa, .{ .path = try gpa.dupe(u8, rel), .mb = delta });
                }
            }
            if (opts.max_rss_mb > 0) {
                const rss_now: u64 = currentRssMb() orelse 0;
                if (rss_now >= opts.max_rss_mb) {
                    var line: [512]u8 = undefined;
                    const msg = try std.fmt.bufPrint(
                        &line,
                        "\ntest262 --max-rss tripped at fixture: {s}\n  RSS now: {d} MiB, budget: {d} MiB\n",
                        .{ rel, rss_now, opts.max_rss_mb },
                    );
                    try std.Io.File.stderr().writeStreamingAll(io, msg);
                    std.process.exit(2);
                }
            }
            try recordOutcome(gpa, &stats, &buckets, &failures, &pass_paths, rel, outcome, is_full_run);

            if (opts.verbose) {
                try printVerbose(io, rel, outcome);
            } else if (!opts.quiet and stats.total > 0 and stats.total % 500 == 0) {
                try printProgress(io, &stats);
            }
        }
    } else {
        // Parallel path.
        var index: std.atomic.Value(usize) = .init(0);
        var merge_mu: std.Io.Mutex = .init;

        const current_paths = try gpa.alloc(std.atomic.Value(usize), thread_count);
        defer gpa.free(current_paths);
        for (current_paths) |*slot| slot.* = .init(idle_slot);

        // Per-worker host-interrupt flags — the watchdog flips one to
        // abort a wedged fixture (see `monitorLoop`).
        const abort_flags = try gpa.alloc(std.atomic.Value(bool), thread_count);
        defer gpa.free(abort_flags);
        for (abort_flags) |*slot| slot.* = .init(false);

        const threads = try gpa.alloc(std.Thread, thread_count);
        defer gpa.free(threads);
        var spawned: usize = 0;
        errdefer {
            for (threads[0..spawned]) |t| t.join();
        }
        for (threads, 0..) |*t, wid| {
            const ctx = WorkerCtx{
                .gpa = gpa,
                .io = io,
                .corpus = corpus,
                .paths = paths.items,
                .index = &index,
                .opts = opts,
                .pass_cache = &pass_cache,
                .harness_sources = harness_sources,
                .merge_mu = &merge_mu,
                .global_stats = &stats,
                .global_buckets = &buckets,
                .global_failures = &failures,
                .global_pass_paths = &pass_paths,
                .global_slow = &slow,
                .global_heavy = &heavy,
                .is_full_run = is_full_run,
                .phase = phase,
                .worker_id = wid,
                .current_paths = current_paths,
                .abort_flags = abort_flags,
            };
            t.* = try std.Thread.spawn(.{}, worker, .{ctx});
            spawned += 1;
        }

        // The monitor always runs — even under --quiet / --verbose —
        // so the per-fixture watchdog can name a wedged fixture. Only
        // the live progress line is gated on those modes.
        var monitor_done: std.atomic.Value(bool) = .init(false);
        const monitor_thread: std.Thread = try std.Thread.spawn(.{}, monitorLoop, .{
            io,
            &index,
            &monitor_done,
            @as(usize, paths.items.len),
            paths.items,
            current_paths,
            abort_flags,
            opts.timeout_s,
            !opts.quiet and !opts.verbose,
        });

        for (threads) |t| t.join();

        monitor_done.store(true, .release);
        monitor_thread.join();
    }

    const elapsed = start_ts.untilNow(io, .awake).toMilliseconds();

    if (!opts.quiet and !opts.verbose and thread_count <= 1) {
        // Clear the progress line. (Threads>1 path doesn't draw one.)
        try std.Io.File.stderr().writeStreamingAll(io, "\r\x1b[K");
    }

    // Per-phase tally banner, prefixed with the phase label so a
    // multi-phase `--write-results` invocation surfaces each sweep
    // distinctly in the log.
    if (!opts.quiet) {
        var label_buf: [64]u8 = undefined;
        const banner = try std.fmt.bufPrint(&label_buf, "\n[{s}] ", .{phase.label()});
        try std.Io.File.stdout().writeStreamingAll(io, banner);
    }
    try printTally(io, &stats, elapsed);
    // Diagnostic-flag output is only meaningful for the main phase
    // — pre-Stage-4 sweeps walk a handful of tagged fixtures so
    // slow / heavy / alloc rankings would be noise.
    if (phase == .main) {
        if (opts.list_failures > 0) {
            try printFailureList(io, failures.items, opts.list_failures);
        }
        if (opts.top_slow > 0 and slow.items.len > 0) {
            try printTopSlow(io, slow.items, opts.top_slow);
        }
        if (opts.top_rss > 0 and heavy.items.len > 0) {
            try printTopHeavy(io, heavy.items, opts.top_rss);
        }
        if (opts.top_alloc > 0 and alloc_list.items.len > 0) {
            try printTopAlloc(io, alloc_list.items, opts.top_alloc);
        }
        if (opts.top_gc_time > 0 and gc_time_list.items.len > 0) {
            try printTopGcTime(io, gc_time_list.items, opts.top_gc_time);
        }
        if (opts.mem_summary) {
            try printMemSummary(io, &mem_agg, &stats);
        }
    }

    return .{
        .phase = phase,
        .stats = stats,
        .buckets = buckets,
        .failures = failures,
        .pass_paths = pass_paths,
        .elapsed_ms = elapsed,
    };
}

const Failure = struct {
    path: []const u8,
    kind: Outcome,
};

/// `--top-slow=N` capture. Each entry pairs a per-fixture wall-clock
/// duration with the test path. Workers buffer locally; the spine
/// is merged into `global_slow` under `merge_mu` at exit, then
/// sorted descending and printed after the final tally. Owns its
/// `path` (gpa-duped) so we can free it after the report.
const SlowEntry = struct {
    path: []const u8,
    ms: u64,
};

/// Don't bother recording fixtures that finish faster than this.
/// Keeps per-worker buffers cheap on a 46k-fixture sweep —
/// fixtures interesting enough to debug almost always run at
/// least this long under the runtime mode.
const slow_threshold_ms: u64 = 50;

/// `--top-rss=N` capture. Pairs the per-fixture RSS delta with
/// the test path. Same merge / print shape as `SlowEntry`.
const HeavyEntry = struct {
    path: []const u8,
    mb: u64,
};

/// Filter out trivial fixtures from the heavy report. With 4
/// workers most fixtures churn allocations under 8 MiB; the
/// interesting tail is what actually pushed RSS up.
const heavy_threshold_mb: u64 = 8;

/// `--top-alloc=N` capture. Pairs the per-fixture cumulative
/// `heap.bytes_alloc_total` (in KiB) with the test path. Different
/// signal from `HeavyEntry` (process-RSS peak delta) — this is
/// total bytes charged inside the engine, catching GC-cleaned
/// allocate-and-discard thrash that RSS hides.
const AllocEntry = struct {
    path: []const u8,
    kb: u64,
};

/// Threshold to keep the alloc report focused on interesting
/// fixtures. 64 KiB ≈ a single string-concat result; below that
/// is allocator noise.
const alloc_threshold_kb: u64 = 64;

/// `--top-gc-time=N` capture. Pairs the per-fixture summed GC
/// pause time (microseconds) with the test path. Different signal
/// from `--top-alloc` (cumulative bytes) and `--top-rss` (peak RSS
/// delta): some fixtures burn most of their wall-time in GC because
/// they allocate-and-discard so much that the byte trigger fires
/// repeatedly — those show up here.
const GcTimeEntry = struct {
    path: []const u8,
    us: u64,
};

/// Threshold to filter the GC-time report. 1 ms ≈ a single GC
/// cycle of typical size; below that is uninteresting.
const gc_time_threshold_us: u64 = 1000;

/// Per-fixture summary of heap counters that the sequential path
/// captures before tearing down the realm. Fed into the harness-
/// level `MemAggregate` for `--mem-summary` and the top-N report
/// for `--top-alloc`.
const FixtureMem = struct {
    bytes_alloc_total: u64 = 0,
    bytes_live_peak: u64 = 0,
    gc_cycles: u32 = 0,
    gc_time_ns: u64 = 0,
};

/// Sweep-level aggregate. Accumulated across every fixture (each
/// fixture has its own realm; we sum per-fixture `FixtureMem`).
/// Surfaces in the `--mem-summary` end-of-sweep one-pager.
const MemAggregate = struct {
    bytes_alloc_total: u64 = 0,
    /// Max of per-fixture `bytes_live_peak`. Tells you the
    /// engine-charged ceiling reached during the sweep.
    max_fixture_live_peak: u64 = 0,
    gc_cycles_total: u32 = 0,
    gc_time_ns_total: u64 = 0,
    fixtures_with_alloc: u32 = 0,

    fn add(self: *MemAggregate, m: FixtureMem) void {
        self.bytes_alloc_total +|= m.bytes_alloc_total;
        if (m.bytes_live_peak > self.max_fixture_live_peak) {
            self.max_fixture_live_peak = m.bytes_live_peak;
        }
        self.gc_cycles_total +|= m.gc_cycles;
        self.gc_time_ns_total +|= m.gc_time_ns;
        if (m.bytes_alloc_total > 0) self.fixtures_with_alloc +|= 1;
    }
};

const RunResult = struct {
    kind: Outcome,
    skip_reason: ?SkipReason = null,
};

/// One sweep's rolled-up state — what `runSweep` returns and
/// `main` consumes. Owns its `buckets`, `failures` (path slices),
/// and `pass_paths` (path slices); the orchestrator calls
/// `deinit` once it has fed them into `writeResults` /
/// `writePassCache`. Per-fixture diagnostic captures (`slow`,
/// `heavy`, `alloc_list`, `gc_time_list`, `mem_agg`) live and die
/// inside `runSweep`; only the persistent score state survives
/// here.
const PhaseResult = struct {
    phase: Phase,
    stats: Stats,
    buckets: BucketMap,
    failures: std.ArrayListUnmanaged(Failure),
    pass_paths: std.ArrayListUnmanaged([]const u8),
    /// Sweep wall-clock duration in milliseconds. Only meaningful
    /// for the main phase on a full run — fed into the score row's
    /// `elapsed` column. Always captured for symmetry.
    elapsed_ms: i64,

    fn deinit(self: *PhaseResult, gpa: std.mem.Allocator) void {
        self.buckets.deinit();
        for (self.failures.items) |f| gpa.free(f.path);
        self.failures.deinit(gpa);
        for (self.pass_paths.items) |p| gpa.free(p);
        self.pass_paths.deinit(gpa);
    }
};

/// Update `stats` / `buckets` / `failures` / `pass_paths` for one
/// test outcome. Pulled out so the sequential and per-worker code
/// paths share the bookkeeping logic instead of drifting. Worker
/// version operates on its private structs and merges under
/// `merge_mu` at exit; sequential version passes the globals.
///
/// `stats.total` is bumped *here* (not at dispatch). Out-of-phase
/// fixtures — those filtered to a different phase, with
/// `outcome.skip_reason == .out_of_phase` — return immediately
/// without touching anything: no stats bump, no bucket bump, no
/// failures, no pass_paths.
fn recordOutcome(
    gpa: std.mem.Allocator,
    stats: *Stats,
    buckets: *BucketMap,
    failures: *std.ArrayListUnmanaged(Failure),
    pass_paths: *std.ArrayListUnmanaged([]const u8),
    rel: []const u8,
    outcome: RunResult,
    is_full_run: bool,
) !void {
    if (outcome.kind == .skip and outcome.skip_reason != null and outcome.skip_reason.? == .out_of_phase) {
        return;
    }
    stats.total += 1;

    const bucket_kind: ?BucketKind = switch (outcome.kind) {
        .pass_positive, .pass_negative => .pass,
        .fail_false_reject, .fail_false_accept => .fail,
        .skip => .skip,
    };
    switch (outcome.kind) {
        .pass_positive => stats.pass_pos += 1,
        .pass_negative => stats.pass_neg += 1,
        .fail_false_reject => {
            stats.fail_reject += 1;
            try failures.append(gpa, .{
                .path = try gpa.dupe(u8, rel),
                .kind = .fail_false_reject,
            });
        },
        .fail_false_accept => {
            stats.fail_accept += 1;
            try failures.append(gpa, .{
                .path = try gpa.dupe(u8, rel),
                .kind = .fail_false_accept,
            });
        },
        .skip => stats.skip += 1,
    }
    if (bucket_kind) |bk| try buckets.bump(bucketName(rel), bk);
    if (outcome.kind == .pass_positive or outcome.kind == .fail_false_reject) {
        stats.pos_attempted += 1;
    } else if (outcome.kind == .pass_negative or outcome.kind == .fail_false_accept) {
        stats.neg_attempted += 1;
    }
    if (is_full_run) {
        if (outcome.kind == .pass_positive or outcome.kind == .pass_negative) {
            try pass_paths.append(gpa, try gpa.dupe(u8, rel));
        }
    }
}

/// Shared worker context. The merge-side fields (`global_*`,
/// `merge_mu`) are mutated after each worker rolls up its own
/// per-thread structs at exit. Workers pull paths off `index`
/// (atomic; the only hot synchronisation point in the steady
/// state — `fetchAdd` is wait-free on every platform we ship to).
const WorkerCtx = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    corpus: std.Io.Dir,
    paths: []const []const u8,
    index: *std.atomic.Value(usize),
    opts: *const Options,
    pass_cache: *const PassCache,
    harness_sources: ?harness_mod.HarnessSources,
    merge_mu: *std.Io.Mutex,
    global_stats: *Stats,
    global_buckets: *BucketMap,
    global_failures: *std.ArrayListUnmanaged(Failure),
    global_pass_paths: *std.ArrayListUnmanaged([]const u8),
    global_slow: *std.ArrayListUnmanaged(SlowEntry),
    global_heavy: *std.ArrayListUnmanaged(HeavyEntry),
    is_full_run: bool,
    /// Sweep phase selector. Forwarded to `classifyAndRun` so each
    /// worker filters fixtures the same way the orchestrator picked.
    phase: Phase,
    /// Worker's identity (0..thread_count-1). Used to claim a
    /// slot in `current_paths` so the progress monitor can name
    /// the path each worker is currently chewing on.
    worker_id: usize,
    /// Per-worker "currently running path index" slots — one
    /// slot per worker, written at the top of each test, read
    /// by `monitorLoop`. `idle_slot` (= maxInt) means the
    /// worker isn't on any test (between iterations or done).
    /// Lets a wedged sweep tell you exactly which fixture
    /// stalled instead of leaving you to bisect by filter.
    current_paths: []std.atomic.Value(usize),
    /// Per-worker host-interrupt flags. The watchdog in `monitorLoop`
    /// flips `abort_flags[worker_id]` to abort a wedged fixture; the
    /// worker clears its own slot before each fixture.
    abort_flags: []std.atomic.Value(bool),
};

const idle_slot: usize = std.math.maxInt(usize);

/// Per-worker host-interrupt flag pointer, set once at `workerLoop`
/// entry. `classifyAndRun` (running on the worker thread) wires each
/// fresh realm's `host_interrupt` to it, so the watchdog in
/// `monitorLoop` can abort a wedged fixture from another thread.
/// Null on the sequential path (which has no monitor).
threadlocal var worker_abort_flag: ?*std.atomic.Value(bool) = null;

/// Worker entry point. Pulls paths off the shared atomic index
/// until drained, classifies + runs each test in its own arena,
/// and merges its private results into the globals under
/// `merge_mu` at exit.
fn worker(ctx: WorkerCtx) void {
    var local_arena: std.heap.ArenaAllocator = .init(ctx.gpa);
    defer local_arena.deinit();

    var local_stats: Stats = .{};
    var local_failures: std.ArrayListUnmanaged(Failure) = .empty;
    var local_buckets: BucketMap = .init(ctx.gpa);
    var local_pass_paths: std.ArrayListUnmanaged([]const u8) = .empty;
    var local_slow: std.ArrayListUnmanaged(SlowEntry) = .empty;
    var local_heavy: std.ArrayListUnmanaged(HeavyEntry) = .empty;

    workerLoop(ctx, &local_arena, &local_stats, &local_buckets, &local_failures, &local_pass_paths, &local_slow, &local_heavy) catch {
        // Best-effort: skip merging silently on OOM / IO blow-up.
        // The rolled-up totals will be slightly low, but the run
        // doesn't deadlock and the surviving workers still merge.
    };

    ctx.merge_mu.lockUncancelable(ctx.io);
    defer ctx.merge_mu.unlock(ctx.io);
    mergeStats(ctx.global_stats, &local_stats);
    mergeBuckets(ctx.global_buckets, &local_buckets) catch {};
    ctx.global_failures.appendSlice(ctx.gpa, local_failures.items) catch {};
    ctx.global_pass_paths.appendSlice(ctx.gpa, local_pass_paths.items) catch {};
    ctx.global_slow.appendSlice(ctx.gpa, local_slow.items) catch {};
    ctx.global_heavy.appendSlice(ctx.gpa, local_heavy.items) catch {};

    // The merged-out arrays own their inner strings; we transferred
    // those via `appendSlice`. Free the spine arrays only.
    local_failures.deinit(ctx.gpa);
    local_pass_paths.deinit(ctx.gpa);
    local_slow.deinit(ctx.gpa);
    local_heavy.deinit(ctx.gpa);
    local_buckets.deinit();
}

fn workerLoop(
    ctx: WorkerCtx,
    arena_state: *std.heap.ArenaAllocator,
    stats: *Stats,
    buckets: *BucketMap,
    failures: *std.ArrayListUnmanaged(Failure),
    pass_paths: *std.ArrayListUnmanaged([]const u8),
    slow: *std.ArrayListUnmanaged(SlowEntry),
    heavy: *std.ArrayListUnmanaged(HeavyEntry),
) !void {
    defer ctx.current_paths[ctx.worker_id].store(idle_slot, .release);
    // Publish this worker's host-interrupt flag so `classifyAndRun`
    // (same thread) wires it into every realm it creates.
    worker_abort_flag = &ctx.abort_flags[ctx.worker_id];
    while (true) {
        const i = ctx.index.fetchAdd(1, .monotonic);
        if (i >= ctx.paths.len) return;
        // Claim this path in our slot before any allocation /
        // dispatch can hang. The progress monitor reads this on
        // its next tick — when a worker wedges, the next dump
        // names the exact fixture.
        // Clear any stale abort request from a prior fixture before
        // claiming this one — the watchdog must only ever abort the
        // fixture it actually flagged.
        ctx.abort_flags[ctx.worker_id].store(false, .release);
        ctx.current_paths[ctx.worker_id].store(i, .release);
        const rel = ctx.paths[i];

        // `--only-failing` short-circuit. The cache is loaded only
        // for the main phase (per-feature phases skip cache loading
        // upstream, so this never fires there). A cached pass
        // counts as a positive pass and bumps `stats.total`
        // directly — no frontmatter read, no `classifyAndRun`.
        if (ctx.opts.only_failing and ctx.pass_cache.contains(rel)) {
            stats.total += 1;
            stats.pass_pos += 1;
            stats.pos_attempted += 1;
            try buckets.bump(bucketName(rel), .pass);
            continue;
        }

        _ = arena_state.reset(.free_all);
        const arena = arena_state.allocator();

        const fx_start = if (ctx.opts.top_slow > 0) std.Io.Clock.now(.awake, ctx.io) else undefined;
        const fx_rss_pre: u64 = if (ctx.opts.top_rss > 0) (currentRssMb() orelse 0) else 0;
        // Workers don't participate in `--mem-summary` / `--top-alloc`
        // (single-thread only — those flags pin `--threads=1` upstream).
        const outcome = classifyAndRun(arena, ctx.gpa, ctx.io, ctx.corpus, rel, ctx.opts.mode, ctx.harness_sources, ctx.opts.gc_threshold, ctx.opts.gc_stats, null, ctx.phase) catch |err| {
            if (err == error.OutOfMemory) return err;
            try recordOutcome(ctx.gpa, stats, buckets, failures, pass_paths, rel, .{ .kind = .fail_false_reject }, ctx.is_full_run);
            continue;
        };
        if (ctx.opts.top_slow > 0) {
            const ms_i = fx_start.untilNow(ctx.io, .awake).toMilliseconds();
            const ms_u: u64 = if (ms_i > 0) @intCast(ms_i) else 0;
            if (ms_u >= slow_threshold_ms) {
                try slow.append(ctx.gpa, .{ .path = try ctx.gpa.dupe(u8, rel), .ms = ms_u });
            }
        }
        if (ctx.opts.top_rss > 0) {
            const rss_post: u64 = currentRssMb() orelse fx_rss_pre;
            const delta: u64 = if (rss_post > fx_rss_pre) rss_post - fx_rss_pre else 0;
            if (delta >= heavy_threshold_mb) {
                try heavy.append(ctx.gpa, .{ .path = try ctx.gpa.dupe(u8, rel), .mb = delta });
            }
        }
        try recordOutcome(ctx.gpa, stats, buckets, failures, pass_paths, rel, outcome, ctx.is_full_run);
    }
}

fn mergeStats(dst: *Stats, src: *const Stats) void {
    dst.total += src.total;
    dst.pass_pos += src.pass_pos;
    dst.pass_neg += src.pass_neg;
    dst.fail_reject += src.fail_reject;
    dst.fail_accept += src.fail_accept;
    dst.skip += src.skip;
    dst.pos_attempted += src.pos_attempted;
    dst.neg_attempted += src.neg_attempted;
}

fn mergeBuckets(dst: *BucketMap, src: *const BucketMap) !void {
    var it = src.map.iterator();
    while (it.next()) |entry| {
        const v = entry.value_ptr.*;
        const gop = try dst.map.getOrPut(dst.gpa, entry.key_ptr.*);
        if (!gop.found_existing) {
            gop.key_ptr.* = try dst.gpa.dupe(u8, entry.key_ptr.*);
            gop.value_ptr.* = .{ .name = gop.key_ptr.* };
        }
        gop.value_ptr.pass += v.pass;
        gop.value_ptr.fail += v.fail;
        gop.value_ptr.skip += v.skip;
        gop.value_ptr.total += v.total;
    }
}

fn classifyAndRun(
    arena: std.mem.Allocator,
    /// Page-returning allocator for large heap-owned byte payloads
    /// (`JSString.bytes`, ArrayBuffer slabs). The per-fixture arena
    /// retains capacity, so GC-freed string bytes would otherwise
    /// pin every fixture's peak inside the worker. Pass `gpa` here.
    bytes_allocator: std.mem.Allocator,
    io: std.Io,
    corpus: std.Io.Dir,
    rel: []const u8,
    mode: Mode,
    harness_pair: ?harness_mod.HarnessSources,
    gc_threshold: u32,
    gc_stats: bool,
    /// Optional out-param. When non-null, the runtime path writes
    /// the fixture's heap counters here via a `defer` so every
    /// return point is covered. Parser path leaves it at zero.
    mem_out: ?*FixtureMem,
    /// Sweep phase selector. Drives both the per-fixture skip
    /// decision (does this fixture belong in *this* sweep?) and
    /// the realm's `feature_flags` install set. Main excludes every
    /// pre-Stage-4-tagged fixture; each feature phase admits only
    /// fixtures tagged with that one flag and runs them in a realm
    /// where only that flag is enabled.
    phase: Phase,
) !RunResult {
    // Hard exclusions — `harness/`, `staging/`, `intl402/`.
    // Cynic-out-of-scope paths (Annex B / browser-era) are
    // already filtered by the caller before this entry point.
    if (skip_rules.pathIsSkipped(rel)) {
        return .{ .kind = .skip, .skip_reason = .by_path };
    }

    // Read the file. Cap at a generous 8 MiB — far above any real
    // test262 fixture.
    const test_source = corpus.readFileAlloc(io, rel, arena, .limited(8 * 1024 * 1024)) catch {
        // Treat IO errors as skips with a malformed reason rather than
        // letting the harness die on an unexpected file.
        return .{ .kind = .skip, .skip_reason = .malformed_frontmatter };
    };

    const fm = frontmatter.parse(arena, test_source) catch |err| switch (err) {
        error.NoFrontmatter => return .{ .kind = .skip, .skip_reason = .no_frontmatter },
        error.UnterminatedFrontmatter => return .{ .kind = .skip, .skip_reason = .malformed_frontmatter },
        error.OutOfMemory => return err,
    };

    // Snapshot the tracked-feature bitmask now that frontmatter has
    // parsed, then gate fixture admission on the current sweep's
    // phase. Main rejects anything tagged with a pre-Stage-4 proposal;
    // each `feature:<flag>` phase admits only its own fixtures. An
    // out-of-phase return is the harness's signal to `recordOutcome`
    // to drop this fixture entirely (no stats, no buckets, no cache).
    const pre_stage4_mask = computePreStage4Mask(fm.features);
    if (!phase.includesFixture(pre_stage4_mask)) {
        return .{ .kind = .skip, .skip_reason = .out_of_phase };
    }

    if (fm.flags.no_strict) return .{ .kind = .skip, .skip_reason = .no_strict };
    if (fm.flags.raw) return .{ .kind = .skip, .skip_reason = .raw_flag };
    // Includes are loaded from the harness directory and
    // evaluated as additional Scripts before the test (see the
    // runtime branch below). Parser mode doesn't need them, but
    // tests that depend on harness helpers usually exercise
    // runtime semantics anyway. If the test names an include
    // we don't have on disk, that's the fallback skip.
    if (mode == .parser and fm.includes.len > 0) return .{ .kind = .skip, .skip_reason = .has_includes };
    for (fm.features) |feat| {
        if (skip_rules.featureIsUnsupported(feat)) {
            return .{ .kind = .skip, .skip_reason = .unsupported_feature };
        }
    }
    const expected_negative: ?frontmatter.Negative = blk: {
        if (fm.negative) |n| {
            switch (n.phase) {
                .resolution, .runtime => {
                    if (mode == .parser) {
                        return .{ .kind = .skip, .skip_reason = .runtime_phase };
                    }
                    break :blk n;
                },
                .parse, .early => break :blk n,
            }
        }
        break :blk null;
    };

    var diags: cynic.diagnostic.Diagnostics = .empty;
    var arena_state: std.heap.ArenaAllocator = .init(arena);
    defer arena_state.deinit();
    const parse_arena = arena_state.allocator();

    var program: ?cynic.ast.Program = null;
    const is_module = fm.flags.module;
    if (is_module) {
        program = cynic.parser.parseModule(parse_arena, test_source, &diags) catch |err| switch (err) {
            error.ParseError => null,
            else => return err,
        };
    } else {
        program = cynic.parser.parseScript(parse_arena, test_source, &diags) catch |err| switch (err) {
            error.ParseError => null,
            else => return err,
        };
    }
    const parse_failed = program == null or hasErrorSeverity(diags.items);

    if (mode == .parser) {
        if (expected_negative) |neg| {
            if (!parse_failed) return .{ .kind = .fail_false_accept };
            if (neg.type_name.len > 0 and !diagnosticsMatchClass(diags.items, neg.type_name)) {
                return .{ .kind = .fail_false_accept };
            }
            return .{ .kind = .pass_negative };
        }
        return .{ .kind = if (parse_failed) .fail_false_reject else .pass_positive };
    }

    // Runtime mode. Parse failure → compile-time / parse-time
    // negative match for negatives, false-reject for positives.
    if (parse_failed) {
        if (expected_negative) |neg| {
            if (neg.type_name.len > 0 and !diagnosticsMatchClass(diags.items, neg.type_name)) {
                return .{ .kind = .fail_false_accept };
            }
            return .{ .kind = .pass_negative };
        }
        return .{ .kind = .fail_false_reject };
    }

    var realm = cynic.runtime.Realm.initWithBytesAllocator(arena, bytes_allocator);
    defer realm.deinit();
    // Wire the watchdog: on a worker thread, a wedged fixture can be
    // aborted from `monitorLoop` via this worker's host-interrupt
    // flag. Null on the sequential path — harmless.
    realm.host_interrupt = worker_abort_flag;
    // LIFO `defer`: runs BEFORE `realm.deinit()` above, so the heap
    // counters are still readable. One spot covers all 20+ returns
    // inside this block.
    defer if (mem_out) |out| {
        out.* = .{
            .bytes_alloc_total = realm.heap.bytes_alloc_total,
            .bytes_live_peak = realm.heap.bytes_live_peak,
            .gc_cycles = realm.heap.gc_cycles_total,
            .gc_time_ns = realm.heap.gc_time_ns_total,
        };
    };
    // Install only the proposal flag(s) the current phase
    // demands. The main phase installs none — pre-Stage-4 fixtures
    // are filtered out above, and we don't want a stable-spec
    // fixture's behaviour to depend on whether a hidden proposal
    // accessor exists. Each `feature:<flag>` phase installs only
    // that one flag, so the per-feature scoreboard reflects each
    // proposal honestly in isolation.
    realm.feature_flags = phase.realmFeatures();
    realm.installBuiltins() catch return .{ .kind = .fail_false_reject };
    // Cap each test at a generous opcode budget so an
    // infinite-loop fixture (`while(true){}`, recursive yield,
    // a `for(;;)` waiting on an awaitable that never settles)
    // can't hang a worker forever. 50M opcodes is far above any
    // legitimate test — typical fixtures are well under 1M, and
    // the deepest recursion / generator tests in the corpus top
    // out around 10M. On exhaustion the interpreter throws a
    // synthetic `RangeError`; the test then either passes (if
    // it expected a throw of that shape) or fails as a
    // false-reject — the worker keeps moving.
    realm.step_budget = 50_000_000;
    // Forward the harness-level GC threshold (default 4,096
    // tests/fixture, tunable via `--gc-threshold=N`) so a
    // misbehaving allocating fixture can't balloon a worker's
    // RSS while still inside its step budget. `0` falls through
    // to the engine default.
    if (gc_threshold != 0) realm.heap.setGcThreshold(gc_threshold);
    realm.heap.gc_stats = gc_stats;

    // §INTERPRETING.md — async-flagged tests call `$DONE()` /
    // `$DONE(err)` to signal completion. Install the host hook
    // before running anything; the runner checks
    // `realm.async_done_called` / `async_done_error` after the
    // microtask queue drains. `realm.globals` is a live view over
    // the globalThis object's properties, so `globalThis.$DONE`
    // sees the binding without a hand-mirror.
    {
        const done_fn = realm.heap.allocateFunctionNative(test262Done, 1, "$DONE") catch return .{ .kind = .fail_false_reject };
        const done_v = cynic.runtime.heap.taggedFunction(done_fn);
        realm.globals.put(realm.allocator, "$DONE", done_v) catch return .{ .kind = .fail_false_reject };
    }

    // §INTERPRETING.md — `$262` is the test262 host hook
    // namespace: `evalScript`, `global`, `gc`,
    // `detachArrayBuffer`, etc. Tests gated on hooks Cynic
    // doesn't implement (`createRealm`, `agent.*`, `IsHTMLDDA`)
    // skip via the feature filter; the rest get a working shim.
    install262(&realm) catch return .{ .kind = .fail_false_reject };

    // Install the module loader for both `is_module` tests AND
    // script tests that use dynamic `import()` (the `dynamic-import`
    // feature tag). Without a loader the dynamic import opcode
    // rejects with TypeError, and the `await import(...)` family
    // of script-mode fixtures would all false-reject.
    var needs_loader = is_module;
    if (!needs_loader) {
        for (fm.features) |feat| {
            if (std.mem.eql(u8, feat, "dynamic-import")) {
                needs_loader = true;
                break;
            }
        }
    }
    if (needs_loader) {
        loader_state = .{ .corpus = corpus, .io = io, .test_path = rel };
        realm.module_loader = test262ModuleLoader;
    }

    // §16.1.6 ScriptEvaluation: harness runs as TWO separate
    // Scripts — sta.js, then assert.js — against the same realm,
    // then the test source. The script-vs-module split below is
    // about how the *test source itself* gets evaluated; the
    // preload happens for both, because modules and scripts share
    // a global env and module bodies reference `assert.*` / $DONE
    // globally.
    if (harness_pair) |hp| {
        const r1 = cynic.runtime.evaluateScript(arena, &realm, hp.sta) catch {
            return .{ .kind = .fail_false_reject };
        };
        if (r1 == .thrown) return .{ .kind = .fail_false_reject };
        const r2 = cynic.runtime.evaluateScript(arena, &realm, hp.assert_js) catch {
            return .{ .kind = .fail_false_reject };
        };
        if (r2 == .thrown) return .{ .kind = .fail_false_reject };

        // Each `includes:` name resolves to a `vendor/test262/harness/<name>`
        // file, evaluated as another Script in the same realm.
        // Per spec, includes load AFTER sta + assert and BEFORE
        // the test source. An include we don't have on disk
        // turns the test into `has_includes` skip (early-return
        // signalled by `error.NativeThrew` is treated as a
        // genuine harness failure, not a missing-file skip).
        for (fm.includes) |inc_name| {
            const inc_source = hp.lookupInclude(inc_name) orelse {
                return .{ .kind = .skip, .skip_reason = .has_includes };
            };
            const r_inc = cynic.runtime.evaluateScript(arena, &realm, inc_source) catch {
                return .{ .kind = .fail_false_reject };
            };
            if (r_inc == .thrown) return .{ .kind = .fail_false_reject };
        }
    }

    var entry_chunk_async = false;
    const run_result: cynic.runtime.lantern.RunResult = blk: {
        if (is_module) {
            const chunk_ptr = realm.allocator.create(@import("cynic").bytecode.chunk.Chunk) catch return error.OutOfMemory;
            chunk_ptr.* = cynic.bytecode.compiler.compileModuleAsChunk(
                realm.allocator,
                &realm,
                &program.?,
                test_source,
                &diags,
                rel,
            ) catch |err| {
                std.debug.print("\nCOMPILE-FAIL {s}: {t}\n", .{ rel, err });
                realm.allocator.destroy(chunk_ptr);
                if (expected_negative) |_| return .{ .kind = .pass_negative };
                return .{ .kind = .fail_false_reject };
            };
            entry_chunk_async = chunk_ptr.is_async_module;
            try realm.script_chunks.append(realm.allocator, chunk_ptr);
            // sec-moduledeclarationinstantiation -- register the entry
            // module under its own URL so a self-import (or a sibling
            // fixture cycling back via `./entry.js`) finds the
            // in-progress namespace instead of fetching+compiling a
            // duplicate ModuleRecord. Mirrors the setup that
            // `interpreter.loadModule` does for every other module.
            const ModuleRecord = @import("cynic").runtime.module.ModuleRecord;
            const entry_ns = realm.heap.allocateObject() catch return error.OutOfMemory;
            // §9.4.6 Module Namespace exotic — brand-on-allocation
            // so re-imports through `import()` / `import * as ns`
            // see the right shape even during a cycle through the
            // entry module.
            entry_ns.prototype = null;
            entry_ns.is_module_namespace = true;
            const entry_mod = ModuleRecord.init(realm.allocator, rel, entry_ns) catch return error.OutOfMemory;
            entry_mod.state = .evaluating;
            realm.modules.put(realm.allocator, rel, entry_mod) catch return error.OutOfMemory;
            const saved_current_mod = realm.current_module;
            realm.current_module = entry_mod;
            defer realm.current_module = saved_current_mod;
            const mod_outcome = cynic.runtime.run(arena, &realm, chunk_ptr) catch {
                entry_mod.state = .errored;
                if (expected_negative) |_| return .{ .kind = .pass_negative };
                return .{ .kind = .fail_false_reject };
            };
            entry_mod.state = switch (mod_outcome) {
                .value, .yielded => .evaluated,
                .thrown => .errored,
            };
            // §9.4.6 — finalise the namespace exotic on the entry
            // module so subsequent `import()`s targeting the entry
            // path see the spec-shaped namespace.
            if (entry_mod.state == .evaluated) {
                _ = @import("cynic").runtime.module.getModuleNamespace(&realm, entry_mod) catch return error.OutOfMemory;
            }
            break :blk mod_outcome;
        }
        // Plain script — go through evaluateScript so chunk
        // ownership lands on the realm and any function declared
        // here outlives this call.
        break :blk cynic.runtime.evaluateScript(arena, &realm, test_source) catch {
            if (expected_negative) |_| return .{ .kind = .pass_negative };
            return .{ .kind = .fail_false_reject };
        };
    };

    var test_threw = run_result == .thrown;

    // Drain any microtasks queued during the test body. This
    // matches §9.4 — every host completes the current Job before
    // returning to the runner. Microtask exceptions go to the
    // `$DONE` slot (via asyncHelpers' chained `.then(..., e =>
    // $DONE(e))`); standalone microtask throws are discarded
    // (real hosts dispatch HostPromiseRejectionTracker, which
    // Cynic doesn't model).
    cynic.runtime.lantern.drainMicrotasks(arena, &realm) catch {
        test_threw = true;
    };

    // §16.2.1.5.1 [[IsAsync]] entry-module variant — a module
    // body with top-level `await` is wrapped in
    // `startAsyncCall`, so `run` returns a pending result
    // Promise rather than the body's completion. After the
    // microtask drain, that Promise has settled (or stayed
    // pending if the body is waiting on a never-settled
    // source); a rejected result is the module's spec-level
    // abrupt completion. Only consult this for chunks whose
    // compiler flagged top-level await — otherwise we'd
    // surface unrelated Promise values that happen to be left
    // in the accumulator.
    if (is_module and !test_threw and run_result == .value) {
        if (entry_chunk_async) {
            if (cynic.runtime.heap.valueAsPlainObject(run_result.value)) |p_obj| {
                if (p_obj.isPromise() and p_obj.promise_state == .rejected) {
                    test_threw = true;
                }
            }
        }
    }

    if (expected_negative) |_| {
        return .{ .kind = if (test_threw) .pass_negative else .fail_false_accept };
    }

    // §INTERPRETING.md async-flagged tests pass iff `$DONE()`
    // was called with no arguments. Any argument signals
    // failure. If `$DONE` was never called, fall back to the
    // synchronous-throw check — a body that completes without
    // throwing AND without calling `$DONE` is a buggy fixture
    // but we score it like a regular test, since strict-$DONE
    // enforcement loses tests where the body is implicitly
    // synchronous and just relies on assert() inside it.
    if (fm.flags.async_flag) {
        if (test_threw) return .{ .kind = .fail_false_reject };
        if (realm.async_done_called) {
            if (!realm.async_done_error.isUndefined()) return .{ .kind = .fail_false_reject };
            return .{ .kind = .pass_positive };
        }
        // No $DONE called. Treat as pass — many fixtures rely on
        // implicit success.
        return .{ .kind = .pass_positive };
    }

    if (test_threw) {
        const ex = if (run_result == .thrown) run_result.thrown else (realm.pending_exception orelse cynic.runtime.Value.undefined_);
        if (cynic.runtime.heap.valueAsPlainObject(ex)) |o| {
            if (o.properties.get("message")) |m| {
                if (m.isString()) {
                    const s: *cynic.runtime.JSString = @ptrCast(@alignCast(m.asString()));
                    std.debug.print("\nFAIL {s}: {s}\n", .{ rel, s.flatBytes() });
                }
            } else {
                std.debug.print("\nFAIL {s}: object (no message)\n", .{rel});
            }
        } else if (ex.isString()) {
            const s: *cynic.runtime.JSString = @ptrCast(@alignCast(ex.asString()));
            std.debug.print("\nFAIL {s}: str: {s}\n", .{ rel, s.flatBytes() });
        } else {
            std.debug.print("\nFAIL {s}: non-object\n", .{rel});
        }
    }
    return .{ .kind = if (test_threw) .fail_false_reject else .pass_positive };
}

/// True if any error-severity diagnostic in `items` has an
/// `errorClass()` whose name equals `expected_type` (a test262
/// `negative.type` string like "SyntaxError"). An unknown / unparseable
/// type name returns false — better to score the test as a fail than
/// to silently accept anything.
fn diagnosticsMatchClass(
    items: []const cynic.diagnostic.Diagnostic,
    expected_type: []const u8,
) bool {
    for (items) |d| {
        if (d.severity != .err) continue;
        if (std.mem.eql(u8, d.code.errorClass().name(), expected_type)) return true;
    }
    return false;
}

/// Wrap parseScript / parseModule so we can hand the same callsite
/// either function. Returns `null` on success, the error on failure.
fn runOne(
    comptime f: fn (std.mem.Allocator, []const u8, ?*cynic.diagnostic.Diagnostics) cynic.parser.ParseError!cynic.ast.Program,
    arena: std.mem.Allocator,
    source: []const u8,
    diags: *cynic.diagnostic.Diagnostics,
) ?anyerror {
    _ = f(arena, source, diags) catch |err| return err;
    return null;
}

fn hasErrorSeverity(items: []const cynic.diagnostic.Diagnostic) bool {
    for (items) |d| if (d.severity == .err) return true;
    return false;
}

fn printProgress(io: std.Io, stats: *const Stats) !void {
    var buf: [256]u8 = undefined;
    const msg = try std.fmt.bufPrint(&buf, "\rparsed {d} (pass={d} fail={d} skip={d})", .{
        stats.total, stats.pass(), stats.fail(), stats.skip,
    });
    try std.Io.File.stderr().writeStreamingAll(io, msg);
}

/// Background monitor thread for the parallel runner — peeks at
/// the shared atomic path index every 5 s and emits a
/// `\n`-terminated status line so CI logs surface progress before
/// the workers finish. The line carries no pass/fail breakdown
/// (the workers' Stats are merged at exit, not midway), only the
/// "k of N tests dispatched" counter — but that's enough to tell
/// "still running" from "wedged" at a glance. Stops as soon as
/// `done` flips to true.
/// Snapshot the process resident-set size in MB for the
/// progress-line `rss=NNNMB` field. We want *current* RSS, not
/// the max-watermark `getrusage` returns — the watermark is
/// useless once it spikes once and stays high for the rest of
/// the run. Returns null if the syscall fails. Used by
/// `monitorLoop` to surface allocation pressure as it builds —
/// catches "where did 5 GB come from" patterns at the progress
/// tick instead of after the run.
///
/// macOS: Mach `task_info(MACH_TASK_BASIC_INFO).resident_size`
/// returns *current* bytes. (Zig 0.17 std binding for
/// `mach_task_basic_info` is missing the `resident_size_max`
/// field, which matters for the kernel's count check, so we
/// redeclare the struct to match XNU's layout exactly.)
///
/// Linux: `/proc/self/statm` resident pages × page size — also
/// current. `getrusage` on Linux returns max-watermark in KB
/// which is the same trap.
fn currentRssMb() ?usize {
    const builtin = @import("builtin");
    if (builtin.os.tag == .macos) {
        const TimeValue = extern struct { seconds: i32, microseconds: i32 };
        const TaskBasicInfo = extern struct {
            virtual_size: u64,
            resident_size: u64,
            resident_size_max: u64,
            user_time: TimeValue,
            system_time: TimeValue,
            policy: i32,
            suspend_count: i32,
        };
        const flavor: u32 = 20; // MACH_TASK_BASIC_INFO
        var info: TaskBasicInfo = undefined;
        var count: u32 = @sizeOf(TaskBasicInfo) / @sizeOf(u32);
        const rc = std.c.task_info(
            std.c.mach_task_self(),
            flavor,
            @ptrCast(&info),
            &count,
        );
        if (rc != 0) return null;
        return @intCast(info.resident_size / (1024 * 1024));
    }
    if (builtin.os.tag == .linux) {
        // statm: <size> <resident> <shared> <text> <lib> <data> <dt>
        // — values in pages.
        var buf: [128]u8 = undefined;
        const file = std.fs.cwd().openFile("/proc/self/statm", .{}) catch return null;
        defer file.close();
        const n = file.read(&buf) catch return null;
        const slice = buf[0..n];
        var it = std.mem.tokenizeAny(u8, slice, " \t\n");
        _ = it.next() orelse return null;
        const rss_pages = std.fmt.parseInt(usize, it.next() orelse return null, 10) catch return null;
        const page_size = std.heap.pageSize();
        return (rss_pages * page_size) / (1024 * 1024);
    }
    var ru: std.c.rusage = undefined;
    if (std.c.getrusage(0, &ru) != 0) return null; // 0 = RUSAGE_SELF
    const raw_kb: usize = @intCast(ru.maxrss);
    return raw_kb / 1024;
}

fn monitorLoop(
    io: std.Io,
    index: *std.atomic.Value(usize),
    done: *std.atomic.Value(bool),
    total: usize,
    paths: []const []const u8,
    current_paths: []std.atomic.Value(usize),
    abort_flags: []std.atomic.Value(bool),
    timeout_s: u32,
    draw_progress: bool,
) void {
    const tick_s: u32 = 5;
    var elapsed_s: u32 = 0;
    var prev_dispatched: usize = 0;
    var stuck_ticks: u32 = 0;
    // Per-worker watchdog state: consecutive ticks each worker has
    // sat on the same fixture, and whether it's been named already.
    // Capped at 64 workers — no bench box has more.
    const wd_cap = @min(current_paths.len, 64);
    var wd_last: [64]usize = @splat(idle_slot);
    var wd_ticks: [64]u32 = @splat(0);
    var wd_warned: [64]bool = @splat(false);
    while (!done.load(.acquire)) {
        std.Io.sleep(io, .fromSeconds(tick_s), .awake) catch break;
        elapsed_s += tick_s;
        if (done.load(.acquire)) break;
        const dispatched = index.load(.acquire);
        const display = if (dispatched > total) total else dispatched;

        // ── Per-fixture watchdog ─────────────────────────────────
        // A single wedged worker doesn't stall the dispatched
        // counter — the others keep pulling work — so the
        // quiescence check below misses it. Track each worker's
        // fixture across ticks; once one has held the same fixture
        // past `timeout_s`, name it on stderr. Runs even under
        // --quiet / --verbose, so a wedge is never silent.
        if (timeout_s != 0) {
            var wid: usize = 0;
            while (wid < wd_cap) : (wid += 1) {
                const cur = current_paths[wid].load(.acquire);
                if (cur != idle_slot and cur == wd_last[wid]) {
                    wd_ticks[wid] += 1;
                } else {
                    wd_last[wid] = cur;
                    wd_ticks[wid] = 0;
                    wd_warned[wid] = false;
                }
                if (!wd_warned[wid] and cur < paths.len and
                    wd_ticks[wid] * tick_s >= timeout_s)
                {
                    wd_warned[wid] = true;
                    // Abort the wedged fixture: the worker's engine
                    // polls this flag and unwinds with a RangeError,
                    // so the sweep continues instead of hanging.
                    if (wid < abort_flags.len)
                        abort_flags[wid].store(true, .release);
                    var wb: [1024]u8 = undefined;
                    const wm = std.fmt.bufPrint(
                        &wb,
                        "test262 watchdog: worker {d} stuck >{d}s on {s} - aborting\n",
                        .{ wid, wd_ticks[wid] * tick_s, paths[cur] },
                    ) catch continue;
                    std.Io.File.stderr().writeStreamingAll(io, wm) catch {};
                }
            }
        }

        if (!draw_progress) continue;

        // Quiescence detection: if the dispatched counter hasn't
        // advanced between ticks, every worker is busy on a single
        // long-running test. Two ticks (10 s) of no movement is
        // the signal to dump per-worker paths so a wedge names
        // its fixture even before the run is killed.
        if (dispatched == prev_dispatched) {
            stuck_ticks += 1;
        } else {
            stuck_ticks = 0;
            prev_dispatched = dispatched;
        }

        var buf: [4096]u8 = undefined;
        var pos: usize = 0;
        const rss_mb = currentRssMb();
        const head = if (rss_mb) |mb|
            std.fmt.bufPrint(buf[pos..], "[{d}s] dispatched {d}/{d} rss={d}MB", .{ elapsed_s, display, total, mb }) catch continue
        else
            std.fmt.bufPrint(buf[pos..], "[{d}s] dispatched {d}/{d}", .{ elapsed_s, display, total }) catch continue;
        pos += head.len;
        // Once stuck OR every minute as a heartbeat, append the
        // currently-running path for each worker so the log
        // names the wedge candidate.
        const dump_workers = stuck_ticks >= 2 or (elapsed_s % 60 == 0 and elapsed_s > 0);
        if (dump_workers) {
            for (current_paths, 0..) |*slot, wid| {
                const i = slot.load(.acquire);
                if (pos + 256 >= buf.len) break;
                const part = if (i == idle_slot)
                    std.fmt.bufPrint(buf[pos..], " w{d}=idle", .{wid}) catch break
                else if (i < paths.len)
                    std.fmt.bufPrint(buf[pos..], " w{d}={s}", .{ wid, paths[i] }) catch break
                else
                    continue;
                pos += part.len;
            }
        }
        if (pos < buf.len) {
            buf[pos] = '\n';
            pos += 1;
        }
        std.Io.File.stderr().writeStreamingAll(io, buf[0..pos]) catch {};
    }
}

fn printVerbose(io: std.Io, rel: []const u8, r: RunResult) !void {
    var buf: [512]u8 = undefined;
    const tag: []const u8 = switch (r.kind) {
        .pass_positive => "PASS+",
        .pass_negative => "PASS-",
        .fail_false_reject => "FAIL(reject)",
        .fail_false_accept => "FAIL(accept)",
        .skip => "SKIP",
    };
    const msg = try std.fmt.bufPrint(&buf, "{s} {s}\n", .{ tag, rel });
    try std.Io.File.stderr().writeStreamingAll(io, msg);
}

fn printTally(io: std.Io, stats: *const Stats, elapsed_ms: i64) !void {
    var buf: [1024]u8 = undefined;
    const pass_pct: f64 = if (stats.total == 0) 0.0 else 100.0 * @as(f64, @floatFromInt(stats.pass())) / @as(f64, @floatFromInt(stats.total));
    const msg = try std.fmt.bufPrint(&buf,
        \\total:    {d}
        \\pass:     {d}   ({d:.2}%)
        \\fail:     {d}
        \\skip:     {d}
        \\  parse-positive: {d} attempted, {d} pass, {d} fail (false-reject)
        \\  parse-negative: {d} attempted, {d} pass, {d} fail (false-accept)
        \\elapsed:  {d}ms
        \\
    , .{
        stats.total,
        stats.pass(),
        pass_pct,
        stats.fail(),
        stats.skip,
        stats.pos_attempted,
        stats.pass_pos,
        stats.fail_reject,
        stats.neg_attempted,
        stats.pass_neg,
        stats.fail_accept,
        elapsed_ms,
    });
    try std.Io.File.stdout().writeStreamingAll(io, msg);
}

fn printFailureList(io: std.Io, failures: []const Failure, n: u32) !void {
    var buf: [1024]u8 = undefined;
    try std.Io.File.stdout().writeStreamingAll(io, "\nfailures:\n");
    var shown: u32 = 0;
    for (failures) |f| {
        if (shown >= n) break;
        const tag: []const u8 = switch (f.kind) {
            .fail_false_reject => "false-reject",
            .fail_false_accept => "false-accept",
            else => "?",
        };
        const msg = try std.fmt.bufPrint(&buf, "  [{s}] {s}\n", .{ tag, f.path });
        try std.Io.File.stdout().writeStreamingAll(io, msg);
        shown += 1;
    }
    if (failures.len > shown) {
        const more = try std.fmt.bufPrint(&buf, "  … {d} more\n", .{failures.len - shown});
        try std.Io.File.stdout().writeStreamingAll(io, more);
    }
}

/// Sort the captured slow-fixture entries descending and print
/// the top N. Long-tail outliers dominate harness wall-time —
/// surfacing them post-tally is the cheapest way to focus
/// optimisation. Inspired by V8's `--trace-test-runtime` and
/// JSC's `run-jsc-tests` slow-test summary.
fn printTopSlow(io: std.Io, slow: []SlowEntry, n: u32) !void {
    std.mem.sort(SlowEntry, slow, {}, struct {
        fn lt(_: void, a: SlowEntry, b: SlowEntry) bool {
            return a.ms > b.ms;
        }
    }.lt);
    var buf: [1024]u8 = undefined;
    const limit = @min(@as(usize, n), slow.len);
    const head = try std.fmt.bufPrint(&buf, "\ntop {d} slowest fixtures (≥{d}ms):\n", .{ limit, slow_threshold_ms });
    try std.Io.File.stdout().writeStreamingAll(io, head);
    for (slow[0..limit]) |e| {
        const line = try std.fmt.bufPrint(&buf, "  {d:>6}ms  {s}\n", .{ e.ms, e.path });
        try std.Io.File.stdout().writeStreamingAll(io, line);
    }
}

/// Sort the captured heavy-fixture entries descending and print
/// the top N. Use `--threads=1` to keep RSS deltas sane;
/// concurrent allocation makes the per-fixture watermark racy.
fn printTopHeavy(io: std.Io, heavy: []HeavyEntry, n: u32) !void {
    std.mem.sort(HeavyEntry, heavy, {}, struct {
        fn lt(_: void, a: HeavyEntry, b: HeavyEntry) bool {
            return a.mb > b.mb;
        }
    }.lt);
    var buf: [1024]u8 = undefined;
    const limit = @min(@as(usize, n), heavy.len);
    const head = try std.fmt.bufPrint(&buf, "\ntop {d} heaviest fixtures by RSS delta (≥{d}MB):\n", .{ limit, heavy_threshold_mb });
    try std.Io.File.stdout().writeStreamingAll(io, head);
    for (heavy[0..limit]) |e| {
        const line = try std.fmt.bufPrint(&buf, "  {d:>6}MB  {s}\n", .{ e.mb, e.path });
        try std.Io.File.stdout().writeStreamingAll(io, line);
    }
}

/// Sort the captured alloc-fixture entries descending and print
/// the top N. Catches allocate-and-discard workloads that
/// `--top-rss` misses (RSS is peak live; this is cumulative).
/// `--threads=1` only; the alloc counter lives on each per-realm
/// heap so the ordering is unstable across workers.
fn printTopAlloc(io: std.Io, alloc_list: []AllocEntry, n: u32) !void {
    std.mem.sort(AllocEntry, alloc_list, {}, struct {
        fn lt(_: void, a: AllocEntry, b: AllocEntry) bool {
            return a.kb > b.kb;
        }
    }.lt);
    var buf: [1024]u8 = undefined;
    const limit = @min(@as(usize, n), alloc_list.len);
    const head = try std.fmt.bufPrint(&buf, "\ntop {d} fixtures by cumulative bytes allocated (≥{d}KB):\n", .{ limit, alloc_threshold_kb });
    try std.Io.File.stdout().writeStreamingAll(io, head);
    for (alloc_list[0..limit]) |e| {
        // Print MiB when the value is large enough to warrant it;
        // otherwise KiB. Keeps the column readable.
        if (e.kb >= 1024) {
            const line = try std.fmt.bufPrint(&buf, "  {d:>6}MB  {s}\n", .{ e.kb / 1024, e.path });
            try std.Io.File.stdout().writeStreamingAll(io, line);
        } else {
            const line = try std.fmt.bufPrint(&buf, "  {d:>6}KB  {s}\n", .{ e.kb, e.path });
            try std.Io.File.stdout().writeStreamingAll(io, line);
        }
    }
}

/// Sort the captured GC-time entries descending and print the
/// top N. Catches fixtures that burn wall-time in GC because
/// they allocate-and-discard so much the byte trigger fires
/// repeatedly. `--threads=1` only; per-fixture counter lives
/// on each per-realm heap.
fn printTopGcTime(io: std.Io, gc_time_list: []GcTimeEntry, n: u32) !void {
    std.mem.sort(GcTimeEntry, gc_time_list, {}, struct {
        fn lt(_: void, a: GcTimeEntry, b: GcTimeEntry) bool {
            return a.us > b.us;
        }
    }.lt);
    var buf: [1024]u8 = undefined;
    const limit = @min(@as(usize, n), gc_time_list.len);
    const head = try std.fmt.bufPrint(&buf, "\ntop {d} fixtures by GC pause time (≥{d}\u{00B5}s):\n", .{ limit, gc_time_threshold_us });
    try std.Io.File.stdout().writeStreamingAll(io, head);
    for (gc_time_list[0..limit]) |e| {
        // Print ms when the value is large enough; otherwise µs.
        if (e.us >= 1000) {
            const line = try std.fmt.bufPrint(&buf, "  {d:>6}ms  {s}\n", .{ e.us / 1000, e.path });
            try std.Io.File.stdout().writeStreamingAll(io, line);
        } else {
            const line = try std.fmt.bufPrint(&buf, "  {d:>6}\u{00B5}s  {s}\n", .{ e.us, e.path });
            try std.Io.File.stdout().writeStreamingAll(io, line);
        }
    }
}

/// End-of-sweep one-pager. Sums per-fixture heap counters into a
/// single view: cumulative allocator pressure, max charged peak
/// across fixtures, total GC cycles + pause time, average bytes
/// allocated per fixture. Complement to `--top-alloc` (which
/// names individual outliers).
fn printMemSummary(io: std.Io, agg: *const MemAggregate, stats: *const Stats) !void {
    var buf: [1024]u8 = undefined;
    const fixtures = agg.fixtures_with_alloc;
    const avg_kb: u64 = if (fixtures > 0)
        (agg.bytes_alloc_total / fixtures) / 1024
    else
        0;
    const avg_gc_us: u64 = if (agg.gc_cycles_total > 0)
        (agg.gc_time_ns_total / agg.gc_cycles_total) / 1000
    else
        0;
    const head = try std.fmt.bufPrint(
        &buf,
        "\nmemory summary (across {d} fixtures with engine activity, of {d} total):\n" ++
            "  cumulative bytes allocated:    {d} MiB\n" ++
            "  max per-fixture charged peak:  {d} MiB\n" ++
            "  avg bytes / fixture:           {d} KiB\n" ++
            "  GC cycles:                     {d} (total pause {d} ms, avg {d} \u{00B5}s)\n",
        .{
            fixtures,
            stats.total,
            agg.bytes_alloc_total / (1024 * 1024),
            agg.max_fixture_live_peak / (1024 * 1024),
            avg_kb,
            agg.gc_cycles_total,
            agg.gc_time_ns_total / (1000 * 1000),
            avg_gc_us,
        },
    );
    try std.Io.File.stdout().writeStreamingAll(io, head);
}

/// One score-row in memory. The on-disk format groups these by
/// `date` into per-day "Current scores"-style mini-tables; the
/// reader supports the legacy linear table and the older
/// per-day-with-scope format too so existing files migrate
/// transparently on the next write.
const Row = struct {
    date: []const u8, // borrowed from the input history
    mode: Mode,
    cynic_sha: []const u8,
    test262_sha: []const u8,
    total: u32,
    pass: u32,
    /// `pass + fail`. Stored alongside `total` so the table can
    /// surface raw counts for both `spec%` (pass/total) and
    /// `attempted%` (pass/attempted). For rows imported from
    /// pre-attempted-column history, derived from `attempted_pct`
    /// (rounded; matches the original integer division to within 1).
    attempted: u32,
    spec_pct: f64,
    attempted_pct: f64,
    /// Wall-clock duration of the run that produced this row, in
    /// milliseconds. `null` on rows imported from history files
    /// that predate the `elapsed` column and on partial runs
    /// (filtered / `--only-failing`) where the number wouldn't be
    /// comparable to a full sweep.
    elapsed_ms: ?u64 = null,
};

/// Derive `attempted` from `pass` and `attempted_pct` for rows
/// imported from history files that didn't carry the column.
/// `attempted_pct = 100 * pass / attempted` → solve for attempted.
/// Falls back to `pass` (≡ 100% attempted ≡ 0 fail) when the
/// percent is zero or rounding would underflow.
fn deriveAttempted(pass: u32, attempted_pct: f64) u32 {
    if (attempted_pct <= 0.0 or pass == 0) return pass;
    const a = @as(f64, @floatFromInt(pass)) * 100.0 / attempted_pct;
    const rounded: u32 = @intFromFloat(@round(a));
    return if (rounded < pass) pass else rounded;
}

/// Update test262-results.md with today's row for the run that
/// just finished.
///
/// Layout: a `## Current scores` snapshot at the top (latest
/// value per `mode`), a `## Legend` explaining the rows and
/// columns, then a `## History` section with one mini-table per
/// date — newest day first. One row per `(date, mode)`:
/// re-running the same mode on the same date replaces that day's
/// row.
fn writeResults(
    gpa: std.mem.Allocator,
    io: std.Io,
    stats: *const Stats,
    buckets: *const BucketMap,
    pre_stage4: *const PreStage4Stats,
    epoch_seconds: i64,
    mode: Mode,
    elapsed_ms: ?u64,
) !void {
    const cwd = std.Io.Dir.cwd();
    const path = "test262-results.md";

    const existing = cwd.readFileAlloc(io, path, gpa, .limited(1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => "",
        else => return err,
    };
    defer if (existing.len > 0) gpa.free(existing);

    var rows: std.ArrayListUnmanaged(Row) = .empty;
    defer rows.deinit(gpa);

    // Read every prior format we've shipped: the original
    // linear table, the per-day-with-scope intermediate, and the
    // current per-day-mode-only format. Each reader filters to
    // cynic-scope rows only — historical full-scope rows fall
    // off the table since we no longer report against the full
    // corpus.
    try parseLinearRows(gpa, &rows, existing);
    try parsePerDayRows(gpa, &rows, existing);

    // Previous run's bucket pass counts — used to compute the
    // "biggest movers" callout on the freshly-written latest row.
    // Only the previous run is parsed (older runs lose bucket
    // data when their row scrolls out of the snapshot).
    var prev_bucket_pass: std.StringHashMapUnmanaged(u32) = .empty;
    defer {
        var it = prev_bucket_pass.iterator();
        while (it.next()) |e| gpa.free(e.key_ptr.*);
        prev_bucket_pass.deinit(gpa);
    }
    try parsePrevBucketPass(gpa, &prev_bucket_pass, existing);

    // Capture the SHAs at write time (not build time): Zig's build
    // cache reuses the previous configure when nothing in the build
    // graph changes, so a build-time `git rev-parse` would happily
    // bake in a stale SHA across new commits. Shelling out here keeps
    // the row honest.
    const cynic_sha_owned = currentShortSha(gpa, io, ".");
    defer if (cynic_sha_owned) |s| gpa.free(s);
    const test262_sha_owned = currentShortSha(gpa, io, "vendor/test262");
    defer if (test262_sha_owned) |s| gpa.free(s);
    const cynic_sha: []const u8 = cynic_sha_owned orelse "unknown";
    const test262_sha: []const u8 = test262_sha_owned orelse "unknown";

    var line_buf: [32]u8 = undefined;
    const date = formatDateUtc(epoch_seconds, &line_buf);

    // Drop any existing row for today's `mode` — the fresh
    // stats below replace it. Other modes for today are kept
    // intact (e.g. parser-run today shouldn't clobber a runtime
    // row written earlier).
    var i: usize = 0;
    while (i < rows.items.len) {
        const r = rows.items[i];
        if (std.mem.eql(u8, r.date, date) and r.mode == mode) {
            _ = rows.orderedRemove(i);
        } else {
            i += 1;
        }
    }

    try rows.append(gpa, makeRow(date, mode, stats, cynic_sha, test262_sha, elapsed_ms));

    // When this run was parser mode, we don't have a fresh
    // runtime per-area scoreboard. Preserve the one already in
    // the file by extracting its raw text so a parser refresh
    // doesn't wipe the per-bucket signal.
    const preserved_scoreboard: ?[]const u8 = if (mode == .runtime)
        null
    else
        extractScoreboardSection(existing);
    // Same parser-refresh dance as `preserved_scoreboard`: when we
    // didn't just run the runtime mode the per-feature table needs
    // to come from the file's previous contents, not the empty
    // `pre_stage4` we just initialised.
    const preserved_pre_stage4: ?[]const u8 = if (mode == .runtime)
        null
    else
        extractPreStage4Section(existing);

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(gpa);
    try writeFileBody(gpa, &buf, rows.items, buckets, pre_stage4, &prev_bucket_pass, mode, preserved_scoreboard, preserved_pre_stage4);

    try cwd.writeFile(io, .{ .sub_path = path, .data = buf.items });
}

fn makeRow(
    date: []const u8,
    mode: Mode,
    stats: *const Stats,
    cynic_sha: []const u8,
    test262_sha: []const u8,
    elapsed_ms: ?u64,
) Row {
    const spec_pct: f64 = if (stats.total == 0) 0.0 else 100.0 * @as(f64, @floatFromInt(stats.pass())) / @as(f64, @floatFromInt(stats.total));
    const attempted = stats.pass() + stats.fail();
    const att_pct: f64 = if (attempted == 0) 0.0 else 100.0 * @as(f64, @floatFromInt(stats.pass())) / @as(f64, @floatFromInt(attempted));
    return .{
        .date = date,
        .mode = mode,
        .cynic_sha = cynic_sha,
        .test262_sha = test262_sha,
        .total = stats.total,
        .pass = stats.pass(),
        .attempted = attempted,
        .spec_pct = spec_pct,
        .attempted_pct = att_pct,
        .elapsed_ms = elapsed_ms,
    };
}

/// Best-effort short git SHA for the working tree (or submodule)
/// at `dir`. Returns null if git isn't available, the path isn't
/// a working tree, or the lookup otherwise fails — callers fall
/// back to "unknown". Captured at write time, not build time, so
/// new commits between two `zig build test262` invocations don't
/// land in the row with a cached, stale SHA.
fn currentShortSha(gpa: std.mem.Allocator, io: std.Io, dir: []const u8) ?[]u8 {
    const result = std.process.run(gpa, io, .{
        .argv = &.{ "git", "-C", dir, "rev-parse", "--short", "HEAD" },
        .stdout_limit = .limited(64),
        .stderr_limit = .limited(256),
    }) catch return null;
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);
    switch (result.term) {
        .exited => |code| if (code != 0) return null,
        else => return null,
    }
    const trimmed = std.mem.trim(u8, result.stdout, " \r\n\t");
    if (trimmed.len == 0) return null;
    return gpa.dupe(u8, trimmed) catch null;
}

/// Read rows from the legacy linear table (`| date | mode |
/// scope | cynic_sha | test262_sha | total | pass | fail | skip
/// | spec% | attempted% |`). Only rows with `scope == cynic`
/// are kept; the old `full`-scope numbers used the entire
/// corpus as the denominator and are no longer comparable.
fn parseLinearRows(
    gpa: std.mem.Allocator,
    rows: *std.ArrayListUnmanaged(Row),
    existing: []const u8,
) !void {
    var i: usize = 0;
    while (i < existing.len) {
        const end = std.mem.indexOfScalarPos(u8, existing, i, '\n') orelse existing.len;
        defer i = if (end < existing.len) end + 1 else end;
        if (!std.mem.startsWith(u8, existing[i..], "| 20")) continue;
        const line = existing[i..end];

        var it = std.mem.tokenizeAny(u8, line, "|");
        const date = std.mem.trim(u8, it.next() orelse continue, " ");
        const mode_s = std.mem.trim(u8, it.next() orelse continue, " ");
        const scope_s = std.mem.trim(u8, it.next() orelse continue, " ");
        const mode = std.meta.stringToEnum(Mode, mode_s) orelse continue;
        if (!std.mem.eql(u8, scope_s, "cynic")) continue;
        const cynic_sha = std.mem.trim(u8, it.next() orelse continue, " ");
        const t262_sha = std.mem.trim(u8, it.next() orelse continue, " ");
        const total_s = std.mem.trim(u8, it.next() orelse continue, " ");
        const pass_s = std.mem.trim(u8, it.next() orelse continue, " ");
        _ = it.next() orelse continue; // fail
        _ = it.next() orelse continue; // skip
        const spec_s = std.mem.trim(u8, it.next() orelse continue, " ");
        const att_s = std.mem.trim(u8, it.next() orelse continue, " ");
        const total = std.fmt.parseInt(u32, total_s, 10) catch continue;
        const pass = std.fmt.parseInt(u32, pass_s, 10) catch continue;
        const spec_pct = std.fmt.parseFloat(f64, spec_s) catch continue;
        const att_pct = std.fmt.parseFloat(f64, att_s) catch continue;
        try rows.append(gpa, .{
            .date = date,
            .mode = mode,
            .cynic_sha = cynic_sha,
            .test262_sha = t262_sha,
            .total = total,
            .pass = pass,
            .attempted = deriveAttempted(pass, att_pct),
            .spec_pct = spec_pct,
            .attempted_pct = att_pct,
        });
    }
}

/// Read rows from the per-day format. Day blocks are introduced
/// by `### YYYY-MM-DD — cynic <sha>, test262 <sha>` and contain
/// lines that look like one of:
/// `| **mode** | spec% | attempted% | pass / total |`
/// `| **mode, scope** | spec% | attempted% | pass / total |`
/// (the second form is from the previous schema; only `cynic`
/// scope is retained).
fn parsePerDayRows(
    gpa: std.mem.Allocator,
    rows: *std.ArrayListUnmanaged(Row),
    existing: []const u8,
) !void {
    var date: []const u8 = "";
    var cynic_sha: []const u8 = "";
    var t262_sha: []const u8 = "";
    var i: usize = 0;
    while (i < existing.len) {
        const end = std.mem.indexOfScalarPos(u8, existing, i, '\n') orelse existing.len;
        defer i = if (end < existing.len) end + 1 else end;
        const line = existing[i..end];
        if (std.mem.startsWith(u8, line, "### ") and line.len > 4 and line[4] == '2') {
            // `### 2026-05-07 — cynic <sha>, test262 <sha>`
            const after = line[4..];
            const date_end = std.mem.indexOfScalar(u8, after, ' ') orelse after.len;
            date = after[0..date_end];
            cynic_sha = "";
            t262_sha = "";
            if (std.mem.indexOf(u8, line, "cynic ")) |c_off| {
                const c_after = line[c_off + 6 ..];
                const c_end = std.mem.indexOfAny(u8, c_after, ",—\t\n ") orelse c_after.len;
                cynic_sha = stripBackticks(c_after[0..c_end]);
            }
            if (std.mem.indexOf(u8, line, "test262 ")) |t_off| {
                const t_after = line[t_off + 8 ..];
                const t_end = std.mem.indexOfAny(u8, t_after, ",—\t\n ") orelse t_after.len;
                t262_sha = stripBackticks(t_after[0..t_end]);
            }
            continue;
        }
        if (date.len == 0) continue;
        if (!std.mem.startsWith(u8, line, "| **")) continue;

        var it = std.mem.tokenizeAny(u8, line, "|");
        const label_raw = std.mem.trim(u8, it.next() orelse continue, " ");
        // Strip ** … ** wrapping.
        if (!(std.mem.startsWith(u8, label_raw, "**") and std.mem.endsWith(u8, label_raw, "**"))) continue;
        const label = label_raw[2 .. label_raw.len - 2];

        // Accept either `mode` or `mode, scope`. For the latter,
        // keep only `scope == cynic`.
        var mode_part: []const u8 = label;
        if (std.mem.indexOfScalar(u8, label, ',')) |comma| {
            mode_part = std.mem.trim(u8, label[0..comma], " ");
            const scope_part = std.mem.trim(u8, label[comma + 1 ..], " ");
            if (!std.mem.eql(u8, scope_part, "cynic")) continue;
        }
        const mode = std.meta.stringToEnum(Mode, mode_part) orelse continue;

        const spec_cell = std.mem.trim(u8, it.next() orelse continue, " ");
        const att_cell = std.mem.trim(u8, it.next() orelse continue, " ");
        const pt_cell = std.mem.trim(u8, it.next() orelse continue, " ");

        const spec_pct = std.fmt.parseFloat(f64, trimSuffix(spec_cell, "%")) catch continue;
        const att_pct = std.fmt.parseFloat(f64, trimSuffix(att_cell, "%")) catch continue;
        const slash = std.mem.indexOf(u8, pt_cell, "/") orelse continue;
        const pass = std.fmt.parseInt(u32, std.mem.trim(u8, pt_cell[0..slash], " "), 10) catch continue;
        const total = std.fmt.parseInt(u32, std.mem.trim(u8, pt_cell[slash + 1 ..], " "), 10) catch continue;
        // The Δ-pass cell is computed fresh per render — skip it.
        // The next cell, if present, is the `elapsed` column added
        // 2026-05-12. Rows from older history files don't have it;
        // either tokenizer.next() returns null (no `|` tail) or
        // returns an empty cell. Either case leaves elapsed_ms null.
        _ = it.next();
        const elapsed_ms: ?u64 = blk: {
            const cell_raw = it.next() orelse break :blk null;
            const cell = std.mem.trim(u8, cell_raw, " ");
            if (cell.len == 0) break :blk null;
            break :blk parseElapsedCell(cell);
        };
        try rows.append(gpa, .{
            .date = date,
            .mode = mode,
            .cynic_sha = cynic_sha,
            .test262_sha = t262_sha,
            .total = total,
            .pass = pass,
            .attempted = deriveAttempted(pass, att_pct),
            .spec_pct = spec_pct,
            .attempted_pct = att_pct,
            .elapsed_ms = elapsed_ms,
        });
    }
}

/// Parse the `elapsed` cell back to milliseconds. Accepts both
/// `12.3 s` (sub-minute) and `2m 40s` (minute+ runs). Anything
/// unrecognized returns null so we don't fail a re-write because
/// of a future format extension.
fn parseElapsedCell(cell: []const u8) ?u64 {
    if (std.mem.indexOfScalar(u8, cell, 'm')) |m_off| {
        // `Xm YYs` form.
        const mins_part = std.mem.trim(u8, cell[0..m_off], " ");
        const mins = std.fmt.parseInt(u64, mins_part, 10) catch return null;
        const rest = std.mem.trim(u8, cell[m_off + 1 ..], " ");
        const s_off = std.mem.indexOfScalar(u8, rest, 's') orelse return null;
        const secs = std.fmt.parseInt(u64, rest[0..s_off], 10) catch return null;
        return (mins * 60 + secs) * 1000;
    }
    // `12.3 s` form.
    const s_off = std.mem.indexOfScalar(u8, cell, 's') orelse return null;
    const num_part = std.mem.trim(u8, cell[0..s_off], " ");
    const secs = std.fmt.parseFloat(f64, num_part) catch return null;
    return @intFromFloat(secs * 1000.0);
}

fn stripBackticks(s: []const u8) []const u8 {
    var out = s;
    if (std.mem.startsWith(u8, out, "`")) out = out[1..];
    if (std.mem.endsWith(u8, out, "`")) out = out[0 .. out.len - 1];
    return out;
}

fn trimSuffix(s: []const u8, suffix: []const u8) []const u8 {
    const t = std.mem.trim(u8, s, " ");
    if (std.mem.endsWith(u8, t, suffix)) return std.mem.trim(u8, t[0 .. t.len - suffix.len], " ");
    return t;
}

/// Compose the full file body: header, `## Current scores`
/// snapshot, the `## Where the runtime stands, by area`
/// scoreboard (runtime mode only), `## Legend`, then `## History`
/// with per-day mini-tables (newest day first). The latest row
/// in `## History` carries a `Δ pass` column and a "Biggest
/// movers" sub-list computed against `prev_bucket_pass`.
fn writeFileBody(
    gpa: std.mem.Allocator,
    out: *std.ArrayListUnmanaged(u8),
    rows: []Row,
    buckets: *const BucketMap,
    pre_stage4: *const PreStage4Stats,
    prev_bucket_pass: *const std.StringHashMapUnmanaged(u32),
    mode_just_run: Mode,
    /// Verbatim text of the previous `## Where the runtime …`
    /// section, used when `mode_just_run != .runtime` so a
    /// parser refresh doesn't drop the scoreboard from the last
    /// runtime sweep. `null` when no scoreboard exists yet (the
    /// scoreboard appears for the first time only after a
    /// runtime run).
    preserved_scoreboard: ?[]const u8,
    /// Same preservation contract as `preserved_scoreboard`, but
    /// for the per-feature table that tracks Cynic's shipped
    /// pre-Stage-4 proposals.
    preserved_pre_stage4: ?[]const u8,
) !void {
    try out.appendSlice(gpa,
        \\# test262 conformance score history
        \\
        \\## Current scores
        \\
        \\|         | spec% | attempted% | pass / total | pass / attempted |
        \\|---|---|---|---|---|
        \\
    );
    inline for (.{ Mode.parser, Mode.runtime }) |m| {
        if (latestRow(rows, m)) |r| try writeMiniRow(gpa, out, r);
    }
    try out.append(gpa, '\n');

    // Per-area scoreboard. When THIS run was a runtime run,
    // generate fresh from `buckets`. Otherwise (parser run)
    // re-emit the verbatim scoreboard from the previous file
    // contents so the per-bucket signal survives parser
    // refreshes. Either way it's "as of the most recent
    // runtime run."
    if (mode_just_run == .runtime and buckets.map.count() > 0) {
        try writeScoreboard(gpa, out, buckets);
    } else if (preserved_scoreboard) |s| {
        try out.appendSlice(gpa, s);
    }

    // Per-feature scoreboard for the pre-Stage-4 proposals Cynic
    // ships ahead of the published edition. Same preservation
    // contract as the per-area scoreboard.
    if (mode_just_run == .runtime and preStage4HasData(pre_stage4)) {
        try writePreStage4Scoreboard(gpa, out, pre_stage4);
    } else if (preserved_pre_stage4) |s| {
        try out.appendSlice(gpa, s);
    }

    try out.appendSlice(gpa,
        \\
        \\## Legend
        \\
        \\**Rows**
        \\
        \\- **parser** — parses the source only. A pass means Cynic's parser accepts or rejects the test as the spec requires. The runtime is never invoked.
        \\- **runtime** — parses, compiles, and executes. A pass means the result matches the test's expectation (no error for positive tests, the right error class for negatives).
        \\
        \\**Columns**
        \\
        \\- **spec%** — `pass / total`. Coverage of the corpus. Skipped tests are in `total` but never in `pass`, so this rises only when we ship features that unblock previously-skipped tests. Same definition in the rolled-up rows and in the by-area scoreboard.
        \\- **attempted%** — `pass / (pass + fail)`. Of the tests we actually ran, the fraction that passed. Skips drop out. Measures the quality of what's shipped, independent of coverage. Same definition in the rolled-up rows and in the by-area scoreboard; skip-only buckets render as `0 %`.
        \\- **pass / total** — raw counts for `spec%`. `total` is the Cynic-targeted corpus (see below); `skip` is `total - attempted`.
        \\- **pass / attempted** — raw counts for `attempted%`. `attempted = pass + fail`; `fail` is `attempted - pass`. Side-by-side with `pass / total` so a row's two percentages have visible numerators and denominators.
        \\- **Δ pass** (history) — change in `pass` versus the row immediately above (chronologically previous run of the same `mode`).
        \\- **elapsed** (history) — wall-clock time of the run that produced the row. Recorded only for full sweeps (no `--filter`, no `--only-failing`); partial runs leave it blank to keep the regression signal clean. Sub-minute as `12.3 s`, minute+ as `2m 40s`.
        \\
        \\**Scope.** `total` excludes paths universally out of scope (`harness/`, `staging/`, `intl402/`), Annex B language extensions, and browser-era built-ins Cynic doesn't ship (`escape` / `unescape`, `String.prototype` HTML wrappers, `Date.{getYear, setYear}`). Fixtures referencing a pre-Stage-4 proposal (see the per-feature table) are *also* excluded from `total` — they don't appear in the rolled-up rows or the per-area scoreboard at all. Each proposal's row in `## Pre-Stage-4 proposals shipped` is sourced from a dedicated phase sweep that runs only the matching fixtures, in a realm where only that one proposal's flag is enabled.
        \\
        \\## History
        \\
        \\
    );

    // Sort rows: date desc; within a day parser before runtime.
    std.mem.sort(Row, rows, {}, rowLess);

    var idx: usize = 0;
    var first_day = true;
    while (idx < rows.len) {
        const day_date = rows[idx].date;
        try out.appendSlice(gpa, "### ");
        try out.appendSlice(gpa, day_date);
        // SHAs from this day's first row; realistically uniform
        // across a day. Skipped if both blank.
        const sha_cynic = rows[idx].cynic_sha;
        const sha_t262 = rows[idx].test262_sha;
        if (sha_cynic.len > 0 or sha_t262.len > 0) {
            try out.appendSlice(gpa, " — cynic `");
            try out.appendSlice(gpa, if (sha_cynic.len > 0) sha_cynic else "unknown");
            try out.appendSlice(gpa, "`, test262 `");
            try out.appendSlice(gpa, if (sha_t262.len > 0) sha_t262 else "unknown");
            try out.appendSlice(gpa, "`");
        }
        try out.appendSlice(gpa, "\n\n");
        try out.appendSlice(gpa,
            \\|         | spec% | attempted% | pass / total | pass / attempted | Δ pass | elapsed |
            \\|---|---|---|---|---|---:|---:|
            \\
        );

        var j = idx;
        while (j < rows.len and std.mem.eql(u8, rows[j].date, day_date)) : (j += 1) {
            const prev_pass: ?u32 = priorRowPass(rows, j);
            try writeHistoryRow(gpa, out, rows[j], prev_pass);
        }
        try out.appendSlice(gpa, "\n");

        // Biggest movers callout — only on the topmost (most
        // recent) day, AND only when the run that just finished
        // was runtime mode. Parser-mode buckets aren't
        // comparable to the stored runtime baseline (they count
        // parse-positive/negative only) so the deltas would be
        // misleading. Parser refreshes preserve the previous
        // runtime scoreboard verbatim; the callout stays with it.
        if (first_day and mode_just_run == .runtime and prev_bucket_pass.count() > 0) {
            try writeBiggestMovers(gpa, out, buckets, prev_bucket_pass);
        }

        idx = j;
        first_day = false;
    }
}

fn writeMiniRow(
    gpa: std.mem.Allocator,
    out: *std.ArrayListUnmanaged(u8),
    r: Row,
) !void {
    var buf: [320]u8 = undefined;
    const line = try std.fmt.bufPrint(&buf, "| **{s}** | {d:.2} % | {d:.2} % | {d} / {d} | {d} / {d} |\n", .{
        @tagName(r.mode), r.spec_pct, r.attempted_pct, r.pass, r.total, r.pass, r.attempted,
    });
    try out.appendSlice(gpa, line);
}

/// Render an elapsed-cell. Empty for rows imported from history
/// files that predate the column. Sub-minute runs print as
/// `12.3 s`; longer runs use `2m 40s` so the regression-glance
/// scale is intuitive.
fn formatElapsedCell(buf: []u8, elapsed_ms: ?u64) ![]const u8 {
    const ms = elapsed_ms orelse return "";
    if (ms < 60_000) {
        const secs: f64 = @as(f64, @floatFromInt(ms)) / 1000.0;
        return try std.fmt.bufPrint(buf, "{d:.1} s", .{secs});
    }
    const total_s: u64 = ms / 1000;
    const minutes: u64 = total_s / 60;
    const seconds: u64 = total_s % 60;
    return try std.fmt.bufPrint(buf, "{d}m {d:0>2}s", .{ minutes, seconds });
}

fn writeHistoryRow(
    gpa: std.mem.Allocator,
    out: *std.ArrayListUnmanaged(u8),
    r: Row,
    prev_pass: ?u32,
) !void {
    var buf: [384]u8 = undefined;
    var elapsed_buf: [32]u8 = undefined;
    const elapsed_cell = try formatElapsedCell(&elapsed_buf, r.elapsed_ms);
    if (prev_pass) |p| {
        const delta: i64 = @as(i64, r.pass) - @as(i64, p);
        const sign: u8 = if (delta > 0) '+' else if (delta < 0) '-' else 0;
        const mag: u64 = @abs(delta);
        const line = if (sign == 0)
            try std.fmt.bufPrint(&buf, "| **{s}** | {d:.2} % | {d:.2} % | {d} / {d} | {d} / {d} | ±0 | {s} |\n", .{
                @tagName(r.mode), r.spec_pct, r.attempted_pct, r.pass, r.total, r.pass, r.attempted, elapsed_cell,
            })
        else
            try std.fmt.bufPrint(&buf, "| **{s}** | {d:.2} % | {d:.2} % | {d} / {d} | {d} / {d} | {c}{d} | {s} |\n", .{
                @tagName(r.mode), r.spec_pct, r.attempted_pct, r.pass, r.total, r.pass, r.attempted, sign, mag, elapsed_cell,
            });
        try out.appendSlice(gpa, line);
    } else {
        const line = try std.fmt.bufPrint(&buf, "| **{s}** | {d:.2} % | {d:.2} % | {d} / {d} | {d} / {d} | n/a | {s} |\n", .{
            @tagName(r.mode), r.spec_pct, r.attempted_pct, r.pass, r.total, r.pass, r.attempted, elapsed_cell,
        });
        try out.appendSlice(gpa, line);
    }
}

/// Find the chronologically-previous row of the same mode for
/// `rows[idx]`. `rows` is assumed pre-sorted by `rowLess`
/// (date desc, parser-before-runtime within a day).
fn priorRowPass(rows: []const Row, idx: usize) ?u32 {
    const cur = rows[idx];
    var k = idx + 1;
    while (k < rows.len) : (k += 1) {
        if (rows[k].mode == cur.mode) return rows[k].pass;
    }
    return null;
}

fn writeScoreboard(
    gpa: std.mem.Allocator,
    out: *std.ArrayListUnmanaged(u8),
    buckets: *const BucketMap,
) !void {
    const sorted = try buckets.sortedByFailTiered(gpa);
    defer gpa.free(sorted);

    try out.appendSlice(gpa,
        \\
        \\## Where the runtime stands, by area
        \\
        \\Bucketed on the first two path components (`built-ins/Set`,
        \\`language/expressions`, …). Grouped into fail-magnitude
        \\tiers (1000+, 100–999, 10–99, 1–9, 0), alphabetical
        \\within each tier — heavy-hitter areas surface at the top,
        \\related siblings stay neighbours so the table is scannable.
        \\Skipped tests are excluded from `pass` and `fail`. Rows
        \\in ~~strikethrough~~ are buckets we skip wholesale (out
        \\of scope per the Cynic-targeted skiplist — Annex B
        \\language extensions, intl402, staging, Temporal,
        \\browser-era built-ins …).
        \\
        \\| area | pass | fail | skip | spec% | attempted% |
        \\|---|---:|---:|---:|---:|---:|
        \\
    );

    var buf: [320]u8 = undefined;
    var prev_tier: u8 = 255;
    for (sorted) |b| {
        const tier: u8 = if (b.fail == 0) 4 else if (b.fail < 10) 3 else if (b.fail < 100) 2 else if (b.fail < 1000) 1 else 0;
        if (tier != prev_tier) {
            // Insert a tier label as a single-cell row spanning
            // the table — keeps the header visible at the
            // boundary instead of relying on the reader to spot
            // the magnitude shift on their own. GitHub renders
            // colspan via leading bold cell + filler dashes
            // poorly, so we use a plain italic row.
            const label: []const u8 = switch (tier) {
                0 => "1000+ fails",
                1 => "100–999 fails",
                2 => "10–99 fails",
                3 => "1–9 fails",
                else => "0 fails (passing or wholly OOS)",
            };
            const hdr = try std.fmt.bufPrint(&buf, "| **_{s}_** | | | | | |\n", .{label});
            try out.appendSlice(gpa, hdr);
            prev_tier = tier;
        }
        const pct: f64 = if (b.total == 0) 0.0 else 100.0 * @as(f64, @floatFromInt(b.pass)) / @as(f64, @floatFromInt(b.total));
        const attempted: u32 = b.pass + b.fail;
        const att_pct: f64 = if (attempted == 0) 0.0 else 100.0 * @as(f64, @floatFromInt(b.pass)) / @as(f64, @floatFromInt(attempted));
        // Strikethrough buckets we skip wholesale (every test
        // filtered out as out-of-scope per the Cynic-targeted
        // skiplist). They're kept in the table for visibility —
        // crossing them out makes the rows we actually run easy
        // to spot.
        const strike: bool = (b.pass == 0 and b.fail == 0);
        const line = if (strike)
            try std.fmt.bufPrint(&buf, "| ~~`{s}`~~ | ~~{d}~~ | ~~{d}~~ | ~~{d}~~ | ~~{d:.0} %~~ | ~~{d:.0} %~~ |\n", .{
                b.name, b.pass, b.fail, b.skip, pct, att_pct,
            })
        else
            try std.fmt.bufPrint(&buf, "| `{s}` | {d} | {d} | {d} | {d:.0} % | {d:.0} % |\n", .{
                b.name, b.pass, b.fail, b.skip, pct, att_pct,
            });
        try out.appendSlice(gpa, line);
    }
    try out.appendSlice(gpa, "\n");
}

fn preStage4HasData(pre_stage4: *const PreStage4Stats) bool {
    for (pre_stage4.slots) |s| {
        if (s.total > 0) return true;
    }
    return false;
}

/// Render the per-feature scoreboard for the pre-Stage-4 proposals
/// Cynic ships ahead of the published edition. Mirrors
/// `writeScoreboard` in column layout so the two tables read the
/// same; the heading is distinct so the section can be located /
/// preserved verbatim across parser-mode refreshes via
/// `extractPreStage4Section`.
fn writePreStage4Scoreboard(
    gpa: std.mem.Allocator,
    out: *std.ArrayListUnmanaged(u8),
    pre_stage4: *const PreStage4Stats,
) !void {
    try out.appendSlice(gpa,
        \\
        \\## Pre-Stage-4 proposals shipped
        \\
        \\Per-feature scores for the TC39 proposals Cynic ships at
        \\Stage 1–3, ahead of their inclusion in the published
        \\edition. **Each row is sourced from a dedicated phase
        \\sweep** that runs only the fixtures whose frontmatter
        \\`features:` list names the proposal, in a realm where only
        \\that proposal's flag is enabled — a `joint-iteration`
        \\fixture is scored here against a realm where
        \\`Map.prototype.getOrInsert` is undefined, and vice versa,
        \\so each row reflects the proposal in honest isolation.
        \\**These fixtures are excluded entirely from the top-line
        \\`## Current scores` and the per-area scoreboard** — they
        \\are not in `total` and not in any bucket, so the headline
        \\number tracks stable ECMA-262 conformance only. When a
        \\proposal advances to Stage 4 the row stays here until its
        \\features ship in mainline ECMA-262.
        \\
        \\| feature | pass | fail | skip | spec% | attempted% |
        \\|---|---:|---:|---:|---:|---:|
        \\
    );

    var buf: [320]u8 = undefined;
    for (pre_stage4.slots, 0..) |b, i| {
        const name = tracked_pre_stage4_features[i];
        const pct: f64 = if (b.total == 0) 0.0 else 100.0 * @as(f64, @floatFromInt(b.pass)) / @as(f64, @floatFromInt(b.total));
        const attempted: u32 = b.pass + b.fail;
        const att_pct: f64 = if (attempted == 0) 0.0 else 100.0 * @as(f64, @floatFromInt(b.pass)) / @as(f64, @floatFromInt(attempted));
        const line = try std.fmt.bufPrint(&buf, "| `{s}` | {d} | {d} | {d} | {d:.0} % | {d:.0} % |\n", .{
            name, b.pass, b.fail, b.skip, pct, att_pct,
        });
        try out.appendSlice(gpa, line);
    }
    try out.appendSlice(gpa, "\n");
}

/// Return the raw text of the `## Pre-Stage-4 proposals shipped`
/// section so a parser-mode refresh can re-emit it verbatim
/// instead of dropping the table.
fn extractPreStage4Section(existing: []const u8) ?[]const u8 {
    const heading = "## Pre-Stage-4 proposals shipped";
    const start = std.mem.indexOf(u8, existing, heading) orelse return null;
    const stop_marker = "\n## ";
    const stop = std.mem.indexOfPos(u8, existing, start + heading.len, stop_marker) orelse return null;
    var end = stop;
    while (end > start and existing[end - 1] == '\n') end -= 1;
    end += 1;
    return existing[start..end];
}

fn writeBiggestMovers(
    gpa: std.mem.Allocator,
    out: *std.ArrayListUnmanaged(u8),
    buckets: *const BucketMap,
    prev_bucket_pass: *const std.StringHashMapUnmanaged(u32),
) !void {
    const Mover = struct { name: []const u8, delta: i64 };
    var movers: std.ArrayListUnmanaged(Mover) = .empty;
    defer movers.deinit(gpa);

    // Current buckets: any with a delta vs prev (positive or
    // negative). New buckets count as full delta from 0.
    var it = buckets.map.iterator();
    while (it.next()) |entry| {
        const cur = entry.value_ptr.*;
        const prev: u32 = prev_bucket_pass.get(entry.key_ptr.*) orelse 0;
        const d: i64 = @as(i64, cur.pass) - @as(i64, prev);
        if (d == 0) continue;
        try movers.append(gpa, .{ .name = entry.key_ptr.*, .delta = d });
    }
    // Buckets that vanished from this run but had pass>0 last
    // time — record as negative deltas.
    var pit = prev_bucket_pass.iterator();
    while (pit.next()) |entry| {
        if (buckets.map.contains(entry.key_ptr.*)) continue;
        if (entry.value_ptr.* == 0) continue;
        try movers.append(gpa, .{ .name = entry.key_ptr.*, .delta = -@as(i64, entry.value_ptr.*) });
    }

    if (movers.items.len == 0) return;

    std.mem.sort(Mover, movers.items, {}, struct {
        fn lt(_: void, a: Mover, b: Mover) bool {
            const aa: u64 = @abs(a.delta);
            const bb: u64 = @abs(b.delta);
            if (aa != bb) return aa > bb;
            return std.mem.order(u8, a.name, b.name) == .lt;
        }
    }.lt);

    const top_n = @min(movers.items.len, 5);
    try out.appendSlice(gpa, "Biggest movers (runtime):\n\n");
    var buf: [256]u8 = undefined;
    for (movers.items[0..top_n]) |m| {
        const sign: u8 = if (m.delta > 0) '+' else '-';
        const mag: u64 = @abs(m.delta);
        const line = try std.fmt.bufPrint(&buf, "- `{s}` {c}{d}\n", .{ m.name, sign, mag });
        try out.appendSlice(gpa, line);
    }
    try out.appendSlice(gpa, "\n");
}

/// Return the raw text of the `## Where the runtime stands,
/// by area` section (heading + blurb + table), including the
/// trailing blank line. Used to preserve the scoreboard
/// verbatim across parser-mode refreshes that don't regenerate
/// per-bucket data. Returns `null` when the file doesn't have
/// the section yet.
fn extractScoreboardSection(existing: []const u8) ?[]const u8 {
    const heading = "## Where the runtime stands, by area";
    const start = std.mem.indexOf(u8, existing, heading) orelse return null;
    const stop_marker = "\n## ";
    const stop = std.mem.indexOfPos(u8, existing, start + heading.len, stop_marker) orelse return null;
    // Trim trailing blank line(s) before the next `## `.
    var end = stop;
    while (end > start and existing[end - 1] == '\n') end -= 1;
    end += 1; // keep exactly one trailing newline
    return existing[start..end];
}

/// Read pass counts from the most recent `## Where the runtime
/// stands, by area` section, keyed by area name. Earlier
/// versions of the file (without this section) yield an empty
/// map, which makes "biggest movers" a no-op.
fn parsePrevBucketPass(
    gpa: std.mem.Allocator,
    out: *std.StringHashMapUnmanaged(u32),
    existing: []const u8,
) !void {
    const heading = "## Where the runtime stands, by area";
    const start = std.mem.indexOf(u8, existing, heading) orelse return;
    var cursor = start + heading.len;
    // Stop at the next `## ` heading.
    const stop_marker = "\n## ";
    const stop = std.mem.indexOfPos(u8, existing, cursor, stop_marker) orelse existing.len;

    while (cursor < stop) {
        const end = std.mem.indexOfScalarPos(u8, existing, cursor, '\n') orelse stop;
        defer cursor = if (end < stop) end + 1 else stop;
        const line = existing[cursor..end];
        if (!std.mem.startsWith(u8, line, "| `")) continue;

        // Parse `| `name` | pass | fail | skip | pct % |`.
        var it = std.mem.tokenizeAny(u8, line, "|");
        const name_raw = std.mem.trim(u8, it.next() orelse continue, " ");
        if (!(std.mem.startsWith(u8, name_raw, "`") and std.mem.endsWith(u8, name_raw, "`"))) continue;
        const name = name_raw[1 .. name_raw.len - 1];
        const pass_s = std.mem.trim(u8, it.next() orelse continue, " ");
        const pass = std.fmt.parseInt(u32, pass_s, 10) catch continue;

        const gop = try out.getOrPut(gpa, name);
        if (!gop.found_existing) {
            gop.key_ptr.* = try gpa.dupe(u8, name);
        }
        gop.value_ptr.* = pass;
    }
}

/// Find the row with the latest date for the given mode.
fn latestRow(rows: []const Row, mode: Mode) ?Row {
    var best: ?Row = null;
    for (rows) |r| {
        if (r.mode != mode) continue;
        if (best) |b| {
            if (std.mem.order(u8, r.date, b.date) == .gt) best = r;
        } else best = r;
    }
    return best;
}

fn rowLess(_: void, a: Row, b: Row) bool {
    // Date desc.
    const cmp = std.mem.order(u8, a.date, b.date);
    if (cmp == .gt) return true;
    if (cmp == .lt) return false;
    // Same date: parser before runtime.
    return @intFromEnum(a.mode) < @intFromEnum(b.mode);
}

fn formatDateUtc(epoch_seconds: i64, buf: []u8) []const u8 {
    const days = @divFloor(epoch_seconds, 86400);
    const ymd = ymdFromEpochDays(days);
    // Year is signed only because pre-1970 is technically representable;
    // in practice it's always >= 1970, so cast to unsigned for clean
    // zero-padded formatting (Zig prefixes signed values with "+").
    const year_u: u64 = @intCast(ymd.year);
    const written = std.fmt.bufPrint(buf, "{d:0>4}-{d:0>2}-{d:0>2}", .{
        year_u, ymd.month, ymd.day,
    }) catch unreachable;
    return written;
}

const YMD = struct { year: i64, month: u8, day: u8 };

/// Convert UNIX-epoch days (since 1970-01-01) into Y/M/D. Adapted from
/// the standard "civil_from_days" algorithm (Howard Hinnant).
fn ymdFromEpochDays(epoch_days: i64) YMD {
    const z = epoch_days + 719468;
    const era = if (z >= 0) @divFloor(z, 146097) else @divFloor(z - 146096, 146097);
    const doe: u32 = @intCast(z - era * 146097);
    const yoe: u32 = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
    const y: i64 = @as(i64, yoe) + era * 400;
    const doy: u32 = doe - (365 * yoe + yoe / 4 - yoe / 100);
    const mp: u32 = (5 * doy + 2) / 153;
    const d: u8 = @intCast(doy - (153 * mp + 2) / 5 + 1);
    const m: u8 = @intCast(if (mp < 10) mp + 3 else mp - 9);
    const year: i64 = if (m <= 2) y + 1 else y;
    return .{ .year = year, .month = m, .day = d };
}

fn parseArgs(gpa: std.mem.Allocator, args: std.process.Args) !Options {
    var opts: Options = .{};
    var iter = args.iterate();
    _ = iter.next(); // skip binary path
    while (iter.next()) |arg| {
        if (std.mem.eql(u8, arg, "--quiet")) {
            opts.quiet = true;
        } else if (std.mem.eql(u8, arg, "--verbose")) {
            opts.verbose = true;
        } else if (std.mem.eql(u8, arg, "--write-results")) {
            opts.write_results = true;
        } else if (std.mem.eql(u8, arg, "--mode=parser")) {
            opts.mode = .parser;
        } else if (std.mem.eql(u8, arg, "--mode=runtime")) {
            opts.mode = .runtime;
        } else if (std.mem.eql(u8, arg, "--no-harness")) {
            opts.preload_harness = false;
        } else if (std.mem.eql(u8, arg, "--only-failing")) {
            opts.only_failing = true;
        } else if (std.mem.startsWith(u8, arg, "--harness-dir=")) {
            opts.harness_dir = try gpa.dupe(u8, arg["--harness-dir=".len..]);
        } else if (std.mem.startsWith(u8, arg, "--corpus=")) {
            opts.corpus = try gpa.dupe(u8, arg["--corpus=".len..]);
        } else if (std.mem.startsWith(u8, arg, "--filter=")) {
            opts.filter = try gpa.dupe(u8, arg["--filter=".len..]);
        } else if (std.mem.startsWith(u8, arg, "--list-failures=")) {
            opts.list_failures = std.fmt.parseInt(u32, arg["--list-failures=".len..], 10) catch 0;
        } else if (std.mem.startsWith(u8, arg, "--threads=")) {
            opts.threads = std.fmt.parseInt(u32, arg["--threads=".len..], 10) catch 0;
        } else if (std.mem.startsWith(u8, arg, "--timeout=")) {
            opts.timeout_s = std.fmt.parseInt(u32, arg["--timeout=".len..], 10) catch 60;
        } else if (std.mem.startsWith(u8, arg, "--gc-threshold=")) {
            opts.gc_threshold = std.fmt.parseInt(u32, arg["--gc-threshold=".len..], 10) catch 32768;
        } else if (std.mem.eql(u8, arg, "--gc-stats")) {
            opts.gc_stats = true;
        } else if (std.mem.startsWith(u8, arg, "--top-slow=")) {
            opts.top_slow = std.fmt.parseInt(u32, arg["--top-slow=".len..], 10) catch 0;
        } else if (std.mem.startsWith(u8, arg, "--top-rss=")) {
            opts.top_rss = std.fmt.parseInt(u32, arg["--top-rss=".len..], 10) catch 0;
        } else if (std.mem.eql(u8, arg, "--leak-check")) {
            opts.leak_check = true;
        } else if (std.mem.startsWith(u8, arg, "--max-rss=")) {
            opts.max_rss_mb = std.fmt.parseInt(u32, arg["--max-rss=".len..], 10) catch 0;
        } else if (std.mem.eql(u8, arg, "--mem-summary")) {
            opts.mem_summary = true;
        } else if (std.mem.startsWith(u8, arg, "--top-alloc=")) {
            opts.top_alloc = std.fmt.parseInt(u32, arg["--top-alloc=".len..], 10) catch 0;
        } else if (std.mem.startsWith(u8, arg, "--top-gc-time=")) {
            opts.top_gc_time = std.fmt.parseInt(u32, arg["--top-gc-time=".len..], 10) catch 0;
        } else if (std.mem.startsWith(u8, arg, "--phase=")) {
            const spec = arg["--phase=".len..];
            if (std.mem.eql(u8, spec, "main")) {
                opts.phase = .main;
            } else if (std.mem.startsWith(u8, spec, "feature:")) {
                const fname = spec["feature:".len..];
                const flag = cynic.runtime.FeatureFlag.fromName(fname) orelse {
                    std.debug.print("error: unknown --phase feature: '{s}'\n", .{fname});
                    std.process.exit(1);
                };
                opts.phase = .{ .feature = flag };
            } else {
                std.debug.print("error: --phase expects 'main' or 'feature:<name>', got '{s}'\n", .{spec});
                std.process.exit(1);
            }
        }
    }

    // Single-threaded pin for flags that need it. The diagnostic
    // flags below all require single-process state — DebugAllocator
    // isn't thread-safe (`--leak-check`), process RSS is a process-
    // wide watermark (`--max-rss`), and the per-fixture heap
    // counters + cumulative-bytes / GC-pause accumulators are
    // single-threaded today (`--mem-summary`, `--top-alloc`,
    // `--top-gc-time`). Apply the pin AFTER arg parsing so the
    // result is independent of flag order — `--threads=4 --leak-check`
    // and `--leak-check --threads=4` both end up at 1.
    const force_single_thread =
        opts.leak_check or
        opts.mem_summary or
        opts.max_rss_mb > 0 or
        opts.top_alloc > 0 or
        opts.top_gc_time > 0;
    if (force_single_thread) opts.threads = 1;

    return opts;
}

fn freeArgs(gpa: std.mem.Allocator, opts: *Options) void {
    if (!std.mem.eql(u8, opts.corpus, "vendor/test262/test")) gpa.free(opts.corpus);
    if (!std.mem.eql(u8, opts.harness_dir, "vendor/test262/harness")) gpa.free(opts.harness_dir);
    if (opts.filter) |s| gpa.free(s);
}
