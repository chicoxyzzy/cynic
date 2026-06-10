//! `cynic run <file>...` — read, parse, compile, and execute one
//! or more script files against a single Realm. Multiple files
//! evaluate in order, left to right; top-level `var` / `let` /
//! `function` declarations from earlier files are visible to
//! later ones (later §16.1.6 ScriptEvaluation semantics, the
//! same shape every production engine uses for `d8 a.js b.js`,
//! `jsc a.js b.js`, etc.).
//!
//! The CLI prints the script's *final completion value* —
//! whatever the last expression statement of the final file left
//! in the accumulator. Matches V8 `d8` REPL behaviour. If any
//! file throws an uncaught exception, evaluation stops and we
//! exit 1 with the thrown value on stderr.

const std = @import("std");
const cynic = @import("cynic");

const Realm = cynic.runtime.Realm;
const Value = cynic.runtime.Value;
const JSString = cynic.runtime.JSString;
const FeatureSet = cynic.runtime.FeatureSet;

/// `std.Io` handle for `cliModuleLoader` — the `ModuleLoader`
/// signature is context-free (realm + specifier only), so the CLI
/// stashes its Io here before wiring the loader. Single-threaded
/// CLI; set once per `run` invocation.
var cli_loader_io: ?std.Io = null;
/// Source-lifetime allocator for loaded module files — the run
/// command's `source_arena`, which outlives the realm (module
/// chunks borrow name/identifier slices into their sources).
var cli_loader_arena: ?std.mem.Allocator = null;

/// Resolve a module specifier against the importing module's URL
/// (§16.2.1.8 HostLoadImportedModule, file-system flavour). Only
/// relative ("./", "../") and absolute ("/") specifiers resolve —
/// bare specifiers have no registry to consult and fail as
/// not-found. The result is the canonical cache key, so two
/// specifiers naming the same file must produce the same string;
/// `std.fs.path.resolve` normalises `..` / `.` segments for that.
fn resolveModulePath(
    allocator: std.mem.Allocator,
    base_url: ?[]const u8,
    specifier: []const u8,
) error{ OutOfMemory, ModuleNotFound }![]const u8 {
    if (std.mem.startsWith(u8, specifier, "/")) {
        return allocator.dupe(u8, specifier) catch return error.OutOfMemory;
    }
    const is_relative = std.mem.startsWith(u8, specifier, "./") or
        std.mem.startsWith(u8, specifier, "../");
    if (!is_relative) return error.ModuleNotFound;
    const dir = if (base_url) |b| std.fs.path.dirname(b) orelse "." else ".";
    return std.fs.path.resolve(allocator, &.{ dir, specifier }) catch return error.OutOfMemory;
}

/// File-system module loader for `cynic run` — serves static
/// `import` declarations in `.mjs` entry files and dynamic
/// `import()` from any file. Sources are allocated from the
/// realm's allocator (module chunks borrow into them for the
/// realm's lifetime).
fn cliModuleLoader(
    realm: *Realm,
    specifier: []const u8,
    base_url: ?[]const u8,
    attribute_type: ?[]const u8,
) cynic.runtime.realm.ModuleLoaderError!cynic.runtime.realm.ModuleLoadResult {
    _ = realm;
    const io = cli_loader_io orelse return error.ModuleNotFound;
    const sa = cli_loader_arena orelse return error.ModuleNotFound;
    const resolved = try resolveModulePath(sa, base_url, specifier);
    const source = std.Io.Dir.cwd().readFileAlloc(io, resolved, sa, .limited(64 * 1024 * 1024)) catch {
        return error.ModuleNotFound;
    };
    const module_type: cynic.runtime.realm.ModuleType = blk: {
        const t = attribute_type orelse break :blk .javascript;
        if (std.mem.eql(u8, t, "json")) break :blk .json;
        if (std.mem.eql(u8, t, "text")) break :blk .text;
        // Unknown attribute type — host-defined error (§16.2.1.4).
        return error.ModuleLoadError;
    };
    return .{ .url = resolved, .source = source, .module_type = module_type };
}

test "resolveModulePath: relative against the importer's directory" {
    const a = std.testing.allocator;
    const r = try resolveModulePath(a, "/proj/src/main.mjs", "./util/helper.mjs");
    defer a.free(r);
    try std.testing.expectEqualStrings("/proj/src/util/helper.mjs", r);
}

test "resolveModulePath: parent traversal normalises" {
    const a = std.testing.allocator;
    const r = try resolveModulePath(a, "/proj/src/main.mjs", "../lib/x.mjs");
    defer a.free(r);
    try std.testing.expectEqualStrings("/proj/lib/x.mjs", r);
}

test "resolveModulePath: bare specifiers are not found" {
    try std.testing.expectError(error.ModuleNotFound, resolveModulePath(std.testing.allocator, "/proj/main.mjs", "lodash"));
}

pub fn run(
    allocator: std.mem.Allocator,
    io: std.Io,
    paths: []const []const u8,
    feature_flags: FeatureSet,
    gc_threshold: ?u32,
    dump_bytecode: bool,
    debug_globals: bool,
    unhardened: bool,
    allow_eval: bool,
    allow_wasm: bool,
) !void {
    std.debug.assert(paths.len > 0);

    // Each chunk holds borrowed slices into its source buffer
    // (function names, identifier spans, …). Functions declared
    // by an earlier file may be called by a later one, so all
    // source buffers must outlive every chunk in the realm.
    // One arena scoped to the whole `cynic run` invocation
    // satisfies that — torn down only after the realm.
    var source_arena: std.heap.ArenaAllocator = .init(allocator);
    defer source_arena.deinit();
    const sa = source_arena.allocator();

    var realm = Realm.init(allocator);
    defer realm.deinit();
    realm.feature_flags = feature_flags;
    // `--unhardened` — drop the SES posture (frozen primordials,
    // frozen globalThis) atomically. Must be set BEFORE
    // `installBuiltins` so the Phase 1 freeze pass at the tail
    // of intrinsic install sees the relaxed flag.
    if (unhardened) realm.hardened = false;
    // `--allow=eval` — open the runtime-code-construction gate
    // before `installBuiltins`. See `Realm.allow_eval`.
    if (allow_eval) realm.allow_eval = true;
    if (allow_wasm) realm.allow_wasm = true;
    // Apply the `--gc-threshold` knob before `installBuiltins`
    // so the builtin-install allocations themselves run at the
    // requested cadence (matters at `--gc-threshold=1` where every
    // alloc collects — exposes a missing root in builtin init).
    if (gc_threshold) |n| realm.heap.setGcThreshold(n);
    try realm.installBuiltins();
    // `--debug-globals` — install the test-only host hooks
    // (`__collectGarbage` / `__clearKeptObjects` / `__drainMicrotasks`).
    // Off by default to keep production-style `cynic run`
    // invocations debug-clean (each hook is a real attack surface
    // for an untrusted script — see Realm.installTestGlobals).
    if (debug_globals) try realm.installTestGlobals();

    // Wire the file-system module loader so `.mjs` entries (and
    // dynamic `import()` from any file) can load relative modules.
    cli_loader_io = io;
    cli_loader_arena = sa;
    realm.module_loader = cliModuleLoader;

    // `--dump-bytecode` — parse + compile each file and print the
    // disassembly; don't execute. Matches V8's `d8 --print-bytecode`
    // shape for "what did the compiler emit?" inspection. Side
    // effects: realm builtins installed (chunks reference them),
    // but no script body runs.
    if (dump_bytecode) {
        for (paths) |path| {
            const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, sa, .limited(64 * 1024 * 1024));
            const program = cynic.parser.parseScript(sa, bytes, null) catch |err| {
                var line_buf: [256]u8 = undefined;
                const msg = try std.fmt.bufPrint(&line_buf, "{s}: parse error: {t}\n", .{ path, err });
                try std.Io.File.stderr().writeStreamingAll(io, msg);
                std.process.exit(1);
            };
            var chunk = cynic.bytecode.compiler.compileScriptAsChunk(allocator, &realm, &program, bytes, null) catch |err| {
                var line_buf: [256]u8 = undefined;
                const msg = try std.fmt.bufPrint(&line_buf, "{s}: compile error: {t}\n", .{ path, err });
                try std.Io.File.stderr().writeStreamingAll(io, msg);
                std.process.exit(1);
            };
            defer chunk.deinit(allocator);
            const dis = try cynic.bytecode.disasm.dump(allocator, &chunk);
            defer allocator.free(dis);
            var header: [256]u8 = undefined;
            const h = try std.fmt.bufPrint(&header, "; {s}\n", .{path});
            try std.Io.File.stdout().writeStreamingAll(io, h);
            try std.Io.File.stdout().writeStreamingAll(io, dis);
            try std.Io.File.stdout().writeStreamingAll(io, "\n\n");
        }
        return;
    }

    var last_outcome: cynic.runtime.lantern.RunResult = .{ .value = Value.undefined_ };

    for (paths) |path| {
        const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, sa, .limited(64 * 1024 * 1024));

        // `.mjs` runs as a module (matching `cynic parse`'s
        // auto-detection): load through the module pipeline —
        // static imports resolve via the file-system loader, and
        // the namespace machinery applies. Modules have no
        // completion value; an uncaught throw surfaces like the
        // script path's.
        if (std.mem.endsWith(u8, path, ".mjs")) {
            var m_arena: std.heap.ArenaAllocator = .init(allocator);
            defer m_arena.deinit();
            var m_diags: cynic.diagnostic.Diagnostics = .empty;
            const m_parse = cynic.parser.parseModule(m_arena.allocator(), bytes, &m_diags);
            const m_hard_err: ?anyerror = if (m_parse) |_| null else |err| err;
            var m_had_err = false;
            for (m_diags.items) |d| if (d.severity == .err) {
                m_had_err = true;
                break;
            };
            if (m_hard_err != null or m_had_err) {
                try printParseDiagnostics(io, path, bytes, m_diags.items);
                if (m_hard_err) |err| {
                    var line_buf: [256]u8 = undefined;
                    const msg = try std.fmt.bufPrint(&line_buf, "{s}: parse error: {t}\n", .{ path, err });
                    try std.Io.File.stderr().writeStreamingAll(io, msg);
                }
                std.process.exit(1);
            }
            const out = cynic.runtime.lantern.loadModule(allocator, &realm, path, null, null) catch |err| {
                var line_buf: [256]u8 = undefined;
                const msg = try std.fmt.bufPrint(&line_buf, "{s}: {t}\n", .{ path, err });
                try std.Io.File.stderr().writeStreamingAll(io, msg);
                std.process.exit(1);
            };
            if (out.threw) {
                last_outcome = .{ .thrown = out.value };
                break;
            }
            last_outcome = .{ .value = Value.undefined_ };
            continue;
        }

        // Surface parser diagnostics. `cynic.runtime.evaluateScript`
        // collects them internally then drops the arena, so the CLI
        // would otherwise show just `error.ParseError` with no
        // location or message. Pre-parse here with our own arena +
        // diagnostic sink; if anything error-severity surfaced, render
        // it and exit before the second parse+run pass runs. The
        // double-parse cost is negligible vs. the run cost and keeps
        // every other evaluateScript caller unchanged.
        var pre_arena: std.heap.ArenaAllocator = .init(allocator);
        defer pre_arena.deinit();
        var diags: cynic.diagnostic.Diagnostics = .empty;
        const parse_outcome = cynic.parser.parseScript(pre_arena.allocator(), bytes, &diags);
        const hard_parse_err: ?anyerror = if (parse_outcome) |_| null else |err| err;
        var had_err_severity = false;
        for (diags.items) |d| if (d.severity == .err) {
            had_err_severity = true;
            break;
        };
        if (hard_parse_err != null or had_err_severity) {
            try printParseDiagnostics(io, path, bytes, diags.items);
            if (hard_parse_err) |err| {
                var line_buf: [256]u8 = undefined;
                const msg = try std.fmt.bufPrint(&line_buf, "{s}: parse error: {t}\n", .{ path, err });
                try std.Io.File.stderr().writeStreamingAll(io, msg);
            }
            std.process.exit(1);
        }

        last_outcome = cynic.runtime.evaluateScript(allocator, &realm, bytes) catch |err| {
            var line_buf: [256]u8 = undefined;
            const msg = try std.fmt.bufPrint(&line_buf, "{s}: {t}\n", .{ path, err });
            try std.Io.File.stderr().writeStreamingAll(io, msg);
            std.process.exit(1);
        };

        // Throw stops the chain — later files don't run.
        if (last_outcome == .thrown) break;
    }

    // §9.4 — every host must finish the current Job (drain
    // pending microtasks) before returning to the caller. Without
    // this, `Promise.resolve(v).then(cb)` at the top of a script
    // never runs `cb` and the user sees the unresolved Promise as
    // the script's final value.
    cynic.runtime.lantern.drainMicrotasks(allocator, &realm) catch {};

    // Flush anything `print` / `console.log` buffered.
    if (realm.output.items.len > 0) {
        try std.Io.File.stdout().writeStreamingAll(io, realm.output.items);
    }

    switch (last_outcome) {
        .value, .yielded => |v| {
            // Suppress trailing `undefined` / unsettled-Promise
            // prints — they're noise for a `run`-style invocation
            // (the script chose what to log). Real values (a
            // computed number, an explicit `42` at the end of the
            // file) still print so an `eval`-style use stays
            // useful. Matches `node script.js` semantics.
            if (!v.isUndefined() and !isPlainObject(v)) try printValue(io, v);
        },
        .thrown => |v| {
            try std.Io.File.stderr().writeStreamingAll(io, "Uncaught ");
            try printThrownStream(io, std.Io.File.stderr(), v);
            try std.Io.File.stderr().writeStreamingAll(io, "\n");
            std.process.exit(1);
        },
    }
}

/// Render the parser diagnostics list (severity, location, code,
/// message) as one line each, gutter-style. `bytes` is the original
/// source slice so we can compute line / column from each diagnostic
/// span. Output goes to stderr; the caller handles process exit.
fn printParseDiagnostics(
    io: std.Io,
    path: []const u8,
    bytes: []const u8,
    diags: []const cynic.diagnostic.Diagnostic,
) !void {
    var line_buf: [512]u8 = undefined;
    // `Source.init` walks the file once to build a line-start table.
    // Allocating that table is cheap relative to a parse; the table
    // lets `lineColAt` do an O(log n) lookup per diagnostic.
    var src = try cynic.source.Source.init(std.heap.page_allocator, path, bytes);
    defer src.deinit(std.heap.page_allocator);
    for (diags) |d| {
        const lc = src.lineColAt(d.span.start);
        const sev: []const u8 = switch (d.severity) {
            .err => "error",
            .warning => "warning",
            .note => "note",
        };
        const code_name = @tagName(d.code);
        if (d.message.len > 0) {
            const msg = try std.fmt.bufPrint(&line_buf, "{s}:{d}:{d}: {s}: {s}: {s}\n", .{ path, lc.line, lc.col, sev, code_name, d.message });
            try std.Io.File.stderr().writeStreamingAll(io, msg);
        } else {
            const msg = try std.fmt.bufPrint(&line_buf, "{s}:{d}:{d}: {s}: {s}\n", .{ path, lc.line, lc.col, sev, code_name });
            try std.Io.File.stderr().writeStreamingAll(io, msg);
        }
    }
}

/// Render a thrown value for the `Uncaught:` log. Mostly the same
/// shape as `printValueStream` but treats Error objects (objects
/// with [[ErrorData]] = true per §20.5.1.1) specially, rendering
/// them as `Name: message` instead of the opaque `[object]` —
/// otherwise a `ReferenceError: foo is not defined` shows up as
/// `[object]` and the user has to wrap their script in try/catch
/// to see what actually went wrong.
fn printThrownStream(io: std.Io, out: std.Io.File, v: Value) !void {
    if (v.isObject()) {
        if (cynic.runtime.heap.valueAsPlainObject(v)) |obj| {
            if (obj.has_error_data) {
                const name_v = obj.get("name");
                const message_v = obj.get("message");
                if (name_v.isString()) {
                    const name_s: *JSString = @ptrCast(@alignCast(name_v.asString()));
                    try out.writeStreamingAll(io, name_s.flatBytes());
                    if (message_v.isString()) {
                        const msg_s: *JSString = @ptrCast(@alignCast(message_v.asString()));
                        if (msg_s.flatBytes().len > 0) {
                            try out.writeStreamingAll(io, ": ");
                            try out.writeStreamingAll(io, msg_s.flatBytes());
                        }
                    }
                    return;
                }
            }
        }
    }
    try printValueStream(io, out, v);
}

fn isPlainObject(v: Value) bool {
    return cynic.runtime.heap.valueAsPlainObject(v) != null;
}

fn printValue(io: std.Io, v: Value) !void {
    try printValueStream(io, std.Io.File.stdout(), v);
    try std.Io.File.stdout().writeStreamingAll(io, "\n");
}

fn printValueStream(io: std.Io, out: std.Io.File, v: Value) !void {
    var buf: [512]u8 = undefined;
    if (v.isInt32()) {
        const m = try std.fmt.bufPrint(&buf, "{d}", .{v.asInt32()});
        try out.writeStreamingAll(io, m);
    } else if (v.isDouble()) {
        const d = v.asDouble();
        if (std.math.isNan(d)) {
            try out.writeStreamingAll(io, "NaN");
        } else if (std.math.isInf(d)) {
            try out.writeStreamingAll(io, if (d > 0) "Infinity" else "-Infinity");
        } else {
            const m = try std.fmt.bufPrint(&buf, "{d}", .{d});
            try out.writeStreamingAll(io, m);
        }
    } else if (v.isBool()) {
        try out.writeStreamingAll(io, if (v.asBool()) "true" else "false");
    } else if (v.isNull()) {
        try out.writeStreamingAll(io, "null");
    } else if (v.isUndefined()) {
        try out.writeStreamingAll(io, "undefined");
    } else if (v.isString()) {
        const s: *JSString = @ptrCast(@alignCast(v.asString()));
        try out.writeStreamingAll(io, s.flatBytes());
    } else if (v.isObject()) {
        try out.writeStreamingAll(io, "[object]");
    }
}
