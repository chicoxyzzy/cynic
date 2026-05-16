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

pub fn run(allocator: std.mem.Allocator, io: std.Io, paths: []const []const u8, feature_flags: FeatureSet) !void {
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
    try realm.installBuiltins();

    var last_outcome: cynic.runtime.interpreter.RunResult = .{ .value = Value.undefined_ };

    for (paths) |path| {
        const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, sa, .limited(64 * 1024 * 1024));

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
    cynic.runtime.interpreter.drainMicrotasks(allocator, &realm) catch {};

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
            try std.Io.File.stderr().writeStreamingAll(io, "Uncaught: ");
            try printValueStream(io, std.Io.File.stderr(), v);
            try std.Io.File.stderr().writeStreamingAll(io, "\n");
            std.process.exit(1);
        },
    }
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
        try out.writeStreamingAll(io, s.bytes);
    } else if (v.isObject()) {
        try out.writeStreamingAll(io, "[object]");
    }
}
