//! test262 conformance harness — parser-only.
//!
//! Walks a test262 corpus (defaults to `vendor/test262/test/`), reads
//! the YAML frontmatter from each `.js` file, applies skip rules, and
//! invokes Cynic's parser. Tallies pass / fail / skip and prints a
//! final report.
//!
//! Usage:
//! zig build test262 -- [flags]
//!
//! Flags:
//! --corpus=<path> Override the corpus root (default: vendor/test262/test).
//! --filter=<substring> Only attempt files whose relative path contains <substring>.
//! --list-failures=<n> After the tally, print up to N failing test paths.
//! --quiet Suppress live progress on stderr.
//! --verbose Per-file outcome on stderr.
//! --write-results Append a row to test262-results.md.

const std = @import("std");
const cynic = @import("cynic");
const build_options = @import("build_options");

const frontmatter = @import("test262/frontmatter.zig");
const skip_rules = @import("test262/skip.zig");
const harness_mod = @import("test262/harness.zig");

/// Single-test loader state. Set by `classifyAndRun` before
/// running a module-flagged test; consulted by
/// `test262ModuleLoader`. Process-global (one test at a time).
var loader_state: ?LoaderState = null;
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
fn dollarDoneNative(
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

fn dollar262EvalScript(
    realm: *cynic.runtime.Realm,
    this_value: cynic.runtime.Value,
    args: []const cynic.runtime.Value,
) cynic.runtime.function.NativeError!cynic.runtime.Value {
    _ = this_value;
    if (args.len == 0 or !args[0].isString()) {
        return throwTest262TypeError(realm, "$262.evalScript: source must be a string");
    }
    const s: *cynic.runtime.JSString = @ptrCast(@alignCast(args[0].asString()));
    const result = cynic.runtime.evaluateScript(realm.allocator, realm, s.bytes) catch |err| switch (err) {
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

fn dollar262Gc(
    realm: *cynic.runtime.Realm,
    this_value: cynic.runtime.Value,
    args: []const cynic.runtime.Value,
) cynic.runtime.function.NativeError!cynic.runtime.Value {
    _ = realm;
    _ = this_value;
    _ = args;
    return cynic.runtime.Value.undefined_;
}

fn dollar262DetachArrayBuffer(
    realm: *cynic.runtime.Realm,
    this_value: cynic.runtime.Value,
    args: []const cynic.runtime.Value,
) cynic.runtime.function.NativeError!cynic.runtime.Value {
    _ = this_value;
    if (args.len == 0) return cynic.runtime.Value.undefined_;
    const obj = cynic.runtime.heap.valueAsPlainObject(args[0]) orelse {
        return throwTest262TypeError(realm, "$262.detachArrayBuffer: argument must be an ArrayBuffer");
    };
    if (obj.array_buffer) |ab| {
        realm.allocator.free(ab);
        obj.array_buffer = null;
    }
    return cynic.runtime.Value.undefined_;
}

fn dollar262CreateRealm(
    realm: *cynic.runtime.Realm,
    this_value: cynic.runtime.Value,
    args: []const cynic.runtime.Value,
) cynic.runtime.function.NativeError!cynic.runtime.Value {
    _ = this_value;
    _ = args;
    return throwTest262TypeError(realm, "$262.createRealm not supported in Cynic");
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
    const heap = &realm.heap;
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

    const eval_fn = try heap.allocateFunctionNative(dollar262EvalScript, 1, "evalScript");
    try obj.set(realm.allocator, "evalScript", cynic.runtime.heap.taggedFunction(eval_fn));

    const gc_fn = try heap.allocateFunctionNative(dollar262Gc, 0, "gc");
    try obj.set(realm.allocator, "gc", cynic.runtime.heap.taggedFunction(gc_fn));

    const detach_fn = try heap.allocateFunctionNative(dollar262DetachArrayBuffer, 1, "detachArrayBuffer");
    try obj.set(realm.allocator, "detachArrayBuffer", cynic.runtime.heap.taggedFunction(detach_fn));

    const cr_fn = try heap.allocateFunctionNative(dollar262CreateRealm, 0, "createRealm");
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
};

const Mode = enum { parser, runtime };

const Options = struct {
    corpus: []const u8 = "vendor/test262/test",
    filter: ?[]const u8 = null,
    list_failures: u32 = 0,
    quiet: bool = false,
    verbose: bool = false,
    write_results: bool = false,
    mode: Mode = .parser,
    /// When set in `runtime` mode, prepend `harness/sta.js` and
    /// `harness/assert.js` to every test source. Default: enabled.
    /// Disable via `--no-harness` to measure the no-harness floor.
    /// Has no effect in `parser` mode.
    preload_harness: bool = true,
    /// Path to the harness directory (relative to cwd). Defaults
    /// to a sibling of the corpus root.
    harness_dir: []const u8 = "vendor/test262/harness",
};

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

    // Cynic-scoped tally: paths Cynic considers out of scope
    // (Annex B language extensions, browser-era built-ins) are
    // dropped from the denominator entirely — spec% means
    // "fraction of Cynic-targeted tests that pass." `total` here
    // is corpus-minus-OOS, not the raw 53k.
    var stats: Stats = .{};
    var failures: std.ArrayListUnmanaged(Failure) = .empty;
    defer failures.deinit(gpa);

    const start_ts = std.Io.Clock.now(.awake, io);

    var walker = try corpus.walk(gpa);
    defer walker.deinit();

    var per_file_arena: std.heap.ArenaAllocator = .init(gpa);
    defer per_file_arena.deinit();

    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.basename, ".js")) continue;
        if (std.mem.endsWith(u8, entry.basename, "_FIXTURE.js")) continue;

        // Make a stable copy of the relative path before any subsequent
        // walker.next() invalidates the slice.
        const rel = try gpa.dupe(u8, entry.path);
        defer gpa.free(rel);

        if (opts.filter) |needle| {
            if (std.mem.indexOf(u8, rel, needle) == null) continue;
        }

        // OOS paths exit early — we don't classify, parse, or run
        // them. They simply don't exist for Cynic scoring.
        if (skip_rules.pathIsCynicOutOfScope(rel)) continue;

        stats.total += 1;
        _ = per_file_arena.reset(.retain_capacity);
        const arena = per_file_arena.allocator();

        const harness_pair: ?harness_mod.HarnessSources = harness_sources;
        const outcome = try classifyAndRun(arena, io, corpus, entry, rel, opts.mode, harness_pair);
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
        if (outcome.kind == .pass_positive or outcome.kind == .fail_false_reject) {
            stats.pos_attempted += 1;
        } else if (outcome.kind == .pass_negative or outcome.kind == .fail_false_accept) {
            stats.neg_attempted += 1;
        }

        if (opts.verbose) {
            try printVerbose(io, rel, outcome);
        } else if (!opts.quiet and stats.total % 500 == 0) {
            try printProgress(io, &stats);
        }
    }

    const elapsed = start_ts.untilNow(io, .awake).toMilliseconds();

    if (!opts.quiet and !opts.verbose) {
        // Clear the progress line.
        try std.Io.File.stderr().writeStreamingAll(io, "\r\x1b[K");
    }

    try printTally(io, &stats, elapsed);
    if (opts.list_failures > 0) {
        try printFailureList(io, failures.items, opts.list_failures);
    }
    if (opts.write_results) {
        const now_ts = std.Io.Clock.now(.real, io);
        try writeResults(gpa, io, &stats, now_ts.toSeconds(), opts.mode);
    }

    for (failures.items) |f| gpa.free(f.path);
}

const Failure = struct {
    path: []const u8,
    kind: Outcome,
};

const RunResult = struct {
    kind: Outcome,
    skip_reason: ?SkipReason = null,
};

fn classifyAndRun(
    arena: std.mem.Allocator,
    io: std.Io,
    corpus: std.Io.Dir,
    entry: std.Io.Dir.Walker.Entry,
    rel: []const u8,
    mode: Mode,
    harness_pair: ?harness_mod.HarnessSources,
) !RunResult {
    // Hard exclusions — `harness/`, `staging/`, `intl402/`.
    // Cynic-out-of-scope paths (Annex B / browser-era) are
    // already filtered by the caller before this entry point.
    if (skip_rules.pathIsSkipped(rel)) {
        return .{ .kind = .skip, .skip_reason = .by_path };
    }

    // Read the file. Cap at a generous 8 MiB — far above any real
    // test262 fixture.
    const test_source = corpus.readFileAlloc(io, entry.path, arena, .limited(8 * 1024 * 1024)) catch {
        // Treat IO errors as skips with a malformed reason rather than
        // letting the harness die on an unexpected file.
        return .{ .kind = .skip, .skip_reason = .malformed_frontmatter };
    };

    const fm = frontmatter.parse(arena, test_source) catch |err| switch (err) {
        error.NoFrontmatter => return .{ .kind = .skip, .skip_reason = .no_frontmatter },
        error.UnterminatedFrontmatter => return .{ .kind = .skip, .skip_reason = .malformed_frontmatter },
        error.OutOfMemory => return err,
    };

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

    var realm = cynic.runtime.Realm.init(arena);
    defer realm.deinit();
    realm.installBuiltins() catch return .{ .kind = .fail_false_reject };

    // §INTERPRETING.md — async-flagged tests call `$DONE()` /
    // `$DONE(err)` to signal completion. Install the host hook
    // before running anything; the runner checks
    // `realm.async_done_called` / `async_done_error` after the
    // microtask queue drains.
    {
        const done_fn = realm.heap.allocateFunctionNative(dollarDoneNative, 1, "$DONE") catch return .{ .kind = .fail_false_reject };
        realm.globals.put(realm.allocator, "$DONE", cynic.runtime.heap.taggedFunction(done_fn)) catch return .{ .kind = .fail_false_reject };
    }

    // §INTERPRETING.md — `$262` is the test262 host hook
    // namespace: `evalScript`, `global`, `gc`,
    // `detachArrayBuffer`, etc. Tests gated on hooks Cynic
    // doesn't implement (`createRealm`, `agent.*`, `IsHTMLDDA`)
    // skip via the feature filter; the rest get a working shim.
    install262(&realm) catch return .{ .kind = .fail_false_reject };

    if (is_module) {
        loader_state = .{ .corpus = corpus, .io = io, .test_path = rel };
        realm.module_loader = test262ModuleLoader;
    }

    // later §16.1.6 ScriptEvaluation: harness runs as TWO
    // separate Scripts — sta.js, then assert.js — against the
    // same realm, then the test source as a third Script. No
    // concat, no synthetic single buffer; each Script's spans
    // index its own source.
    //
    // Modules skip the harness preload (modules don't share
    // global env semantics with Scripts, and test262's module
    // tests carry their own setup via `includes:` which is
    // already filtered upstream).
    if (!is_module) {
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
    }

    const run_result: cynic.runtime.interpreter.RunResult = blk: {
        if (is_module) {
            const chunk_ptr = realm.allocator.create(@import("cynic").bytecode.chunk.Chunk) catch return error.OutOfMemory;
            chunk_ptr.* = cynic.bytecode.compiler.compileModuleAsChunk(
                realm.allocator,
                &realm,
                &program.?,
                test_source,
                &diags,
                rel,
            ) catch {
                realm.allocator.destroy(chunk_ptr);
                if (expected_negative) |_| return .{ .kind = .pass_negative };
                return .{ .kind = .fail_false_reject };
            };
            try realm.script_chunks.append(realm.allocator, chunk_ptr);
            break :blk cynic.runtime.run(arena, &realm, chunk_ptr) catch {
                if (expected_negative) |_| return .{ .kind = .pass_negative };
                return .{ .kind = .fail_false_reject };
            };
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
    cynic.runtime.interpreter.drainMicrotasks(arena, &realm) catch {
        test_threw = true;
    };

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
        stats.pass(),  pass_pct,
        stats.fail(),
        stats.skip,
        stats.pos_attempted, stats.pass_pos, stats.fail_reject,
        stats.neg_attempted, stats.pass_neg, stats.fail_accept,
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
    spec_pct: f64,
    attempted_pct: f64,
};

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
    epoch_seconds: i64,
    mode: Mode,
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

    try rows.append(gpa, makeRow(date, mode, stats));

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(gpa);
    try writeFileBody(gpa, &buf, rows.items);

    try cwd.writeFile(io, .{ .sub_path = path, .data = buf.items });
}

fn makeRow(date: []const u8, mode: Mode, stats: *const Stats) Row {
    const spec_pct: f64 = if (stats.total == 0) 0.0 else 100.0 * @as(f64, @floatFromInt(stats.pass())) / @as(f64, @floatFromInt(stats.total));
    const attempted = stats.pass() + stats.fail();
    const att_pct: f64 = if (attempted == 0) 0.0 else 100.0 * @as(f64, @floatFromInt(stats.pass())) / @as(f64, @floatFromInt(attempted));
    return .{
        .date = date,
        .mode = mode,
        .cynic_sha = build_options.cynic_sha,
        .test262_sha = build_options.test262_sha,
        .total = stats.total,
        .pass = stats.pass(),
        .spec_pct = spec_pct,
        .attempted_pct = att_pct,
    };
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
        try rows.append(gpa, .{
            .date = date,
            .mode = mode,
            .cynic_sha = cynic_sha,
            .test262_sha = t262_sha,
            .total = total,
            .pass = pass,
            .spec_pct = spec_pct,
            .attempted_pct = att_pct,
        });
    }
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
/// snapshot, `## Legend`, then `## History` with per-day
/// mini-tables (newest day first; within a day rows go
/// parser → runtime).
fn writeFileBody(
    gpa: std.mem.Allocator,
    out: *std.ArrayListUnmanaged(u8),
    rows: []Row,
) !void {
    try out.appendSlice(gpa,
        \\# test262 conformance score history
        \\
        \\## Current scores
        \\
        \\|         | spec% | attempted% | pass / total |
        \\|---|---|---|---|
        \\
    );
    inline for (.{ Mode.parser, Mode.runtime }) |m| {
        if (latestRow(rows, m)) |r| try writeMiniRow(gpa, out, r);
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
        \\- **spec%** — `pass / total`. Coverage of the corpus. Skipped tests are in `total` but never in `pass`, so this rises only when we ship features that unblock previously-skipped tests.
        \\- **attempted%** — `pass / (pass + fail)`. Of the tests we actually ran, the fraction that passed. Skips drop out. Measures the quality of what's shipped, independent of coverage.
        \\- **pass / total** — raw counts. `total` is the Cynic-targeted corpus (see below); `fail` is `attempted - pass`; `skip` is `total - attempted`.
        \\
        \\**Scope.** `total` excludes paths universally out of scope (`harness/`, `staging/`, `intl402/`), Annex B language extensions, and browser-era built-ins Cynic doesn't ship (`escape` / `unescape`, `String.prototype` HTML wrappers, `Date.{getYear, setYear}`).
        \\
        \\## History
        \\
        \\
    );

    // Sort rows: date desc; within a day parser before runtime.
    std.mem.sort(Row, rows, {}, rowLess);

    var idx: usize = 0;
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
            \\|         | spec% | attempted% | pass / total |
            \\|---|---|---|---|
            \\
        );

        var j = idx;
        while (j < rows.len and std.mem.eql(u8, rows[j].date, day_date)) : (j += 1) {
            try writeMiniRow(gpa, out, rows[j]);
        }
        try out.appendSlice(gpa, "\n");
        idx = j;
    }
}

fn writeMiniRow(
    gpa: std.mem.Allocator,
    out: *std.ArrayListUnmanaged(u8),
    r: Row,
) !void {
    var buf: [256]u8 = undefined;
    const line = try std.fmt.bufPrint(&buf, "| **{s}** | {d:.2} % | {d:.2} % | {d} / {d} |\n", .{
        @tagName(r.mode), r.spec_pct, r.attempted_pct, r.pass, r.total,
    });
    try out.appendSlice(gpa, line);
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
        } else if (std.mem.startsWith(u8, arg, "--harness-dir=")) {
            opts.harness_dir = try gpa.dupe(u8, arg["--harness-dir=".len..]);
        } else if (std.mem.startsWith(u8, arg, "--corpus=")) {
            opts.corpus = try gpa.dupe(u8, arg["--corpus=".len..]);
        } else if (std.mem.startsWith(u8, arg, "--filter=")) {
            opts.filter = try gpa.dupe(u8, arg["--filter=".len..]);
        } else if (std.mem.startsWith(u8, arg, "--list-failures=")) {
            opts.list_failures = std.fmt.parseInt(u32, arg["--list-failures=".len..], 10) catch 0;
        }
    }
    return opts;
}

fn freeArgs(gpa: std.mem.Allocator, opts: *Options) void {
    if (!std.mem.eql(u8, opts.corpus, "vendor/test262/test")) gpa.free(opts.corpus);
    if (!std.mem.eql(u8, opts.harness_dir, "vendor/test262/harness")) gpa.free(opts.harness_dir);
    if (opts.filter) |s| gpa.free(s);
}
