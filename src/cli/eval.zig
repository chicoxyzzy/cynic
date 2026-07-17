//! `cynic eval <expr>` — parse, compile, and execute a single
//! ECMAScript expression, printing the result. The whole later
//! pipeline in one place.

const std = @import("std");
const cynic = @import("cynic");

const Realm = cynic.runtime.Realm;
const Value = cynic.runtime.Value;
const JSString = cynic.runtime.JSString;
const FeatureSet = cynic.runtime.FeatureSet;

pub fn run(
    allocator: std.mem.Allocator,
    io: std.Io,
    source: []const u8,
    feature_flags: FeatureSet,
    gc_threshold: ?u32,
    unhardened: bool,
    allow_eval: bool,
    allow_wasm: bool,
    jit: bool,
    ohaimark: bool,
) !void {
    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    var diags: cynic.diagnostic.Diagnostics = .empty;
    const program = cynic.parser.parseScript(arena_alloc, source, &diags) catch {
        try printDiagnostics(io, &diags);
        std.process.exit(1);
    };
    if (program.body.len == 0) {
        try std.Io.File.stderr().writeStreamingAll(io, "error: empty program\n");
        std.process.exit(1);
    }
    const stmt = program.body[0];
    if (stmt != .expression) {
        try std.Io.File.stderr().writeStreamingAll(io, "error: `cynic eval` accepts a single expression\n");
        std.process.exit(1);
    }
    const expr = stmt.expression.expression;

    var realm = Realm.init(allocator);
    defer realm.deinit();
    realm.feature_flags = feature_flags;
    // `--unhardened` — drop the SES posture before
    // `installBuiltins` so the Phase 1 freeze pass is skipped.
    if (unhardened) realm.hardened = false;
    // `--allow=eval` — open the runtime-code-construction gate. Without
    // it the eval / `Function(string)` paths refuse by SES policy
    // (§19.2.1.2 EvalError); with it the eval engine runs source in the
    // realm (§19.2.1 / §20.2.1.1.1). See `Realm.allow_eval`.
    if (allow_eval) realm.allow_eval = true;
    if (allow_wasm) realm.allow_wasm = true;
    // Top-level tier policy: production defaults both JS JITs on; embedders
    // constructing Realm directly retain explicit per-tier opt-in.
    if (jit) realm.jit_enabled = true;
    if (jit and ohaimark) realm.ohaimark_enabled = true;
    if (gc_threshold) |n| realm.heap.setGcThreshold(n);
    try realm.installBuiltins();

    var chunk = cynic.bytecode.compileExpressionAsChunk(allocator, &realm, &expr, source) catch |err| {
        var line_buf: [128]u8 = undefined;
        const msg = try std.fmt.bufPrint(&line_buf, "compile error: {t}\n", .{err});
        try std.Io.File.stderr().writeStreamingAll(io, msg);
        std.process.exit(1);
    };
    defer chunk.deinit(allocator);

    const outcome = cynic.runtime.run(allocator, &realm, &chunk) catch |err| {
        var line_buf: [128]u8 = undefined;
        const msg = try std.fmt.bufPrint(&line_buf, "runtime error: {t}\n", .{err});
        try std.Io.File.stderr().writeStreamingAll(io, msg);
        std.process.exit(1);
    };

    if (realm.output.items.len > 0) {
        try std.Io.File.stdout().writeStreamingAll(io, realm.output.items);
    }

    switch (outcome) {
        .value, .yielded => |v| try printValue(allocator, io, v),
        .thrown => |v| {
            try std.Io.File.stderr().writeStreamingAll(io, "Uncaught: ");
            try printValue(allocator, io, v);
            std.process.exit(1);
        },
    }
}

fn printDiagnostics(io: std.Io, diags: *const cynic.diagnostic.Diagnostics) !void {
    var line_buf: [256]u8 = undefined;
    for (diags.items) |d| {
        const msg = try std.fmt.bufPrint(&line_buf, "{s}: {t} [{d}..{d}]\n", .{
            @tagName(d.severity), d.code, d.span.start, d.span.end,
        });
        try std.Io.File.stderr().writeStreamingAll(io, msg);
    }
}

/// Format a `Value` for terminal display. Mirrors how `console.log`
/// will format primitives later (the "log a single value" path).
/// Object / Function rendering lands with later.
fn printValue(allocator: std.mem.Allocator, io: std.Io, v: Value) !void {
    var buf: [512]u8 = undefined;
    if (v.isInt32()) {
        const out = try std.fmt.bufPrint(&buf, "{d}\n", .{v.asInt32()});
        try std.Io.File.stdout().writeStreamingAll(io, out);
    } else if (v.isDouble()) {
        const d = v.asDouble();
        if (std.math.isNan(d)) {
            try std.Io.File.stdout().writeStreamingAll(io, "NaN\n");
        } else if (std.math.isInf(d)) {
            try std.Io.File.stdout().writeStreamingAll(io, if (d > 0) "Infinity\n" else "-Infinity\n");
        } else {
            const out = try std.fmt.bufPrint(&buf, "{d}\n", .{d});
            try std.Io.File.stdout().writeStreamingAll(io, out);
        }
    } else if (v.isBool()) {
        try std.Io.File.stdout().writeStreamingAll(io, if (v.asBool()) "true\n" else "false\n");
    } else if (v.isNull()) {
        try std.Io.File.stdout().writeStreamingAll(io, "null\n");
    } else if (v.isUndefined()) {
        try std.Io.File.stdout().writeStreamingAll(io, "undefined\n");
    } else if (v.isString()) {
        const s: *JSString = @ptrCast(@alignCast(v.asString()));
        // Unquoted at the top level — same convention V8's `d8` and
        // SpiderMonkey's `js` use when printing a final expression.
        try std.Io.File.stdout().writeStreamingAll(io, s.flatBytes());
        try std.Io.File.stdout().writeStreamingAll(io, "\n");
    } else if (v.isObject()) {
        try std.Io.File.stdout().writeStreamingAll(io, "[object]\n");
    }
    _ = allocator; // reserved for future heap-allocated formatting
}
