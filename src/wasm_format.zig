//! Value → display-string formatter for the playground panel.
//!
//! Not a spec-faithful `Object.prototype.toString` — the playground
//! shows the completion value as a *hint*. Arrays get a
//! JSON-flavoured elementwise dump clamped by depth and length;
//! plain objects and functions get a coarse tag; primitives get
//! their natural form. Lives in `src/` (not `src/runtime/`) because
//! it is a display concern — the engine itself does not need it.
//!
//! Lifted out of `playground/playground_wasm.zig` so `zig build test` can
//! exercise it. The playground entry only compiles for
//! `wasm32-freestanding`, but the formatter has no wasm-specific
//! dependencies — it just walks
//! Cynic's host-portable `Value` / `JSObject`. The allocator is
//! parameterised so production passes the WASM allocator and tests
//! pass `testing.allocator`.

const std = @import("std");
const Value = @import("runtime/value.zig").Value;
const heap = @import("runtime/heap.zig");
const JSString = @import("runtime/string.zig").JSString;
const JSObject = @import("runtime/object.zig").JSObject;
const bigint = @import("runtime/bigint.zig");

/// Cap on nested-array recursion. Past this we print `Array(N)`
/// instead of descending. The completion-value hint is one line in
/// the playground panel; deep recursion makes it unreadable and
/// (more importantly) risks a stack blow on cycles.
pub const max_depth: u8 = 4;

/// Max array elements rendered before the truncation tail kicks in.
/// 50 keeps `Array.from({length: 100}, …)` glanceable while still
/// surfacing the leading values.
pub const max_array_show: usize = 50;

/// Explicit error set shared between `appendValueAt` and
/// `appendArray`. Zig refuses to infer a return-type error set
/// across a recursive pair (here: value→array→value for nested
/// arrays), so we name the union both helpers emit: allocation
/// failures plus `bufPrint`'s `NoSpaceLeft`.
pub const FormatError = std.mem.Allocator.Error || error{NoSpaceLeft};

/// Top-level entry. Appends a human-readable rendering of `v` to
/// `buf`. Strings render bare at the top level (`"hello"` → `hello`)
/// — matches how a REPL would show a completion value — but quoted
/// inside arrays so `[a, b]` reads as strings, not identifiers.
pub fn appendValue(
    allocator: std.mem.Allocator,
    buf: *std.ArrayListUnmanaged(u8),
    v: Value,
) FormatError!void {
    return appendValueAt(allocator, buf, v, 0);
}

fn appendValueAt(
    allocator: std.mem.Allocator,
    buf: *std.ArrayListUnmanaged(u8),
    v: Value,
    depth: u8,
) FormatError!void {
    var scratch: [64]u8 = undefined;
    if (v.isInt32()) {
        try buf.appendSlice(allocator, try std.fmt.bufPrint(&scratch, "{d}", .{v.asInt32()}));
    } else if (v.isDouble()) {
        const d = v.asDouble();
        if (std.math.isNan(d)) {
            try buf.appendSlice(allocator, "NaN");
        } else if (std.math.isInf(d)) {
            try buf.appendSlice(allocator, if (d > 0) "Infinity" else "-Infinity");
        } else {
            try buf.appendSlice(allocator, try std.fmt.bufPrint(&scratch, "{d}", .{d}));
        }
    } else if (v.isBool()) {
        try buf.appendSlice(allocator, if (v.asBool()) "true" else "false");
    } else if (v.isNull()) {
        try buf.appendSlice(allocator, "null");
    } else if (v.isUndefined()) {
        try buf.appendSlice(allocator, "undefined");
    } else if (v.isHole()) {
        // Array exotics store dense holes as a distinct `Value.hole_`
        // sentinel — never reachable from user JS, but the array
        // printer below feeds them in when iterating `obj.elements`.
        try buf.appendSlice(allocator, "<empty>");
    } else if (v.isString()) {
        const s: *JSString = @ptrCast(@alignCast(v.asString()));
        if (depth == 0) {
            try buf.appendSlice(allocator, s.flatBytes());
        } else {
            try buf.append(allocator, '"');
            try buf.appendSlice(allocator, s.flatBytes());
            try buf.append(allocator, '"');
        }
    } else if (heap.valueAsBigInt(v)) |bi| {
        const digits = try bigint.toStringAlloc(allocator, bi, 10);
        defer allocator.free(digits);
        try buf.appendSlice(allocator, digits);
        try buf.append(allocator, 'n');
    } else if (heap.valueAsSymbol(v)) |sym| {
        // `String(Symbol("k"))` throws per §20.4.3.3, but the
        // playground's completion-value path needs *something* to
        // print — match the devtools convention of `Symbol(desc)`.
        try buf.appendSlice(allocator, "Symbol(");
        if (sym.description) |desc| try buf.appendSlice(allocator, desc);
        try buf.append(allocator, ')');
    } else if (heap.isFunction(v)) {
        try buf.appendSlice(allocator, "[Function]");
    } else if (heap.valueAsPlainObject(v)) |obj| {
        if (obj.is_array_exotic) {
            try appendArray(allocator, buf, obj, depth);
        } else {
            try buf.appendSlice(allocator, "[object Object]");
        }
    } else {
        try buf.appendSlice(allocator, "[unknown]");
    }
}

/// Render an Array exotic as `[e0, e1, …]`, clamped by
/// `max_array_show` and `max_depth`. Sparse holes (the
/// `is_sparse = true` storage where indices are absent from the
/// `sparse_elements` map) render as `<empty>`. Dense holes (the
/// `Value.hole_` sentinel in `elements`) route through
/// `appendValueAt`'s `isHole` branch, which prints the same string.
fn appendArray(
    allocator: std.mem.Allocator,
    buf: *std.ArrayListUnmanaged(u8),
    obj: *JSObject,
    depth: u8,
) FormatError!void {
    const len: usize = if (obj.is_sparse)
        @intCast(obj.sparse_length)
    else
        obj.elements.items.len;

    if (depth >= max_depth) {
        var scratch: [32]u8 = undefined;
        try buf.appendSlice(allocator, try std.fmt.bufPrint(&scratch, "Array({d})", .{len}));
        return;
    }

    try buf.append(allocator, '[');
    const show_n = @min(len, max_array_show);

    if (obj.is_sparse) {
        var i: u32 = 0;
        while (i < show_n) : (i += 1) {
            if (i > 0) try buf.appendSlice(allocator, ", ");
            if (obj.sparse_elements.get(i)) |elem| {
                try appendValueAt(allocator, buf, elem, depth + 1);
            } else {
                try buf.appendSlice(allocator, "<empty>");
            }
        }
    } else {
        for (obj.elements.items[0..show_n], 0..) |elem, idx| {
            if (idx > 0) try buf.appendSlice(allocator, ", ");
            try appendValueAt(allocator, buf, elem, depth + 1);
        }
    }

    if (len > show_n) {
        var scratch: [48]u8 = undefined;
        try buf.appendSlice(
            allocator,
            try std.fmt.bufPrint(&scratch, ", … ({d} more)", .{len - show_n}),
        );
    }
    try buf.append(allocator, ']');
}

// ---------------------------------------------------------------------------
// Tests — run the source through the real engine, then format the
// completion value. Mirrors how the playground reaches this code
// (eval → frame builder calls `appendValue` on the final
// accumulator). The script-eval helper is the same shape used in
// `src/runtime/lantern/tests.zig`.
// ---------------------------------------------------------------------------

const testing = std.testing;
const Realm = @import("runtime/realm.zig").Realm;
const features = @import("runtime/features.zig");
const parser_mod = @import("parser/parser.zig");
const compiler_mod = @import("bytecode/compiler.zig");
const lantern = @import("runtime/lantern/interpreter.zig");

fn evalScriptValue(realm: *Realm, src: []const u8) !Value {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const program = try parser_mod.parseScript(arena.allocator(), src, null);
    var chunk = try compiler_mod.compileScriptAsChunk(
        testing.allocator,
        realm,
        &program,
        src,
        null,
    );
    defer chunk.deinit(testing.allocator);
    const result = try lantern.run(testing.allocator, realm, &chunk);
    return switch (result) {
        .value, .yielded => |v| v,
        .thrown => error.UncaughtException,
    };
}

fn expectFormat(src: []const u8, expected: []const u8) !void {
    var realm = Realm.init(testing.allocator);
    defer realm.deinit();
    realm.feature_flags = features.FeatureSet.initFull();
    try realm.installBuiltins();

    const v = try evalScriptValue(&realm, src);

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(testing.allocator);
    try appendValue(testing.allocator, &buf, v);
    try testing.expectEqualStrings(expected, buf.items);
}

test "wasm_format: integer" {
    try expectFormat("42;", "42");
}

test "wasm_format: zero" {
    try expectFormat("0;", "0");
}

test "wasm_format: negative integer" {
    try expectFormat("(-7);", "-7");
}

test "wasm_format: double" {
    try expectFormat("1.5;", "1.5");
}

test "wasm_format: NaN" {
    try expectFormat("0/0;", "NaN");
}

test "wasm_format: positive infinity" {
    try expectFormat("1/0;", "Infinity");
}

test "wasm_format: negative infinity" {
    try expectFormat("-1/0;", "-Infinity");
}

test "wasm_format: boolean true" {
    try expectFormat("true;", "true");
}

test "wasm_format: boolean false" {
    try expectFormat("false;", "false");
}

test "wasm_format: null" {
    try expectFormat("null;", "null");
}

test "wasm_format: undefined" {
    try expectFormat("undefined;", "undefined");
}

test "wasm_format: top-level string renders bare" {
    try expectFormat("\"hello\";", "hello");
}

test "wasm_format: empty string" {
    try expectFormat("\"\";", "");
}

test "wasm_format: bigint with trailing n" {
    try expectFormat("42n;", "42n");
}

test "wasm_format: bigint zero" {
    try expectFormat("0n;", "0n");
}

test "wasm_format: bigint negative" {
    try expectFormat("(-7n);", "-7n");
}

test "wasm_format: bigint large" {
    // 2^64 + 1 — well past i64 range, exercises the multi-limb path.
    try expectFormat("(18446744073709551617n);", "18446744073709551617n");
}

test "wasm_format: symbol with description" {
    try expectFormat("Symbol(\"foo\");", "Symbol(foo)");
}

test "wasm_format: symbol without description" {
    try expectFormat("Symbol();", "Symbol()");
}

test "wasm_format: well-known symbol" {
    try expectFormat("Symbol.iterator;", "Symbol(Symbol.iterator)");
}

test "wasm_format: function" {
    try expectFormat("(() => {});", "[Function]");
}

test "wasm_format: plain object" {
    try expectFormat("({x: 1, y: 2});", "[object Object]");
}

test "wasm_format: empty array" {
    try expectFormat("[];", "[]");
}

test "wasm_format: single-element array" {
    try expectFormat("[42];", "[42]");
}

test "wasm_format: dense integer array" {
    try expectFormat("[1, 2, 3];", "[1, 2, 3]");
}

test "wasm_format: array with undefined element" {
    try expectFormat("[undefined];", "[undefined]");
}

test "wasm_format: array of bigints" {
    try expectFormat("[1n, 2n, 3n];", "[1n, 2n, 3n]");
}

test "wasm_format: array of functions" {
    try expectFormat("[() => 1, () => 2];", "[[Function], [Function]]");
}

test "wasm_format: array containing plain object" {
    try expectFormat("[{x: 1}];", "[[object Object]]");
}

test "wasm_format: array containing symbol" {
    try expectFormat("[Symbol(\"x\")];", "[Symbol(x)]");
}

test "wasm_format: mixed-depth nested array" {
    try expectFormat("[1, [2, 3], 4];", "[1, [2, 3], 4]");
}

test "wasm_format: mixed-primitive array" {
    try expectFormat(
        "[1, true, null, undefined, \"x\"];",
        "[1, true, null, undefined, \"x\"]",
    );
}

test "wasm_format: nested-array strings quoted" {
    try expectFormat("[\"a\", \"b\"];", "[\"a\", \"b\"]");
}

test "wasm_format: nested array within depth cap" {
    // 3 levels — well within max_depth = 4. Renders fully.
    try expectFormat("[[1, [2]]];", "[[1, [2]]]");
}

test "wasm_format: deep nest collapses past max_depth" {
    // 6 levels deep. The innermost reachable inside the cap renders
    // its child as `Array(1)`.
    try expectFormat("[[[[[[7]]]]]];", "[[[[Array(1)]]]]");
}

test "wasm_format: long array truncates with tail" {
    // 60 elements — first 50 inline, then `, … (10 more)`.
    var realm = Realm.init(testing.allocator);
    defer realm.deinit();
    realm.feature_flags = features.FeatureSet.initFull();
    try realm.installBuiltins();

    const v = try evalScriptValue(&realm, "Array.from({length: 60}, (_, i) => i);");

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(testing.allocator);
    try appendValue(testing.allocator, &buf, v);

    try testing.expect(std.mem.startsWith(u8, buf.items, "[0, 1, 2,"));
    try testing.expect(std.mem.endsWith(u8, buf.items, ", … (10 more)]"));
}

test "wasm_format: exactly at truncation boundary — no tail" {
    // 50 elements = `max_array_show`. Should render fully, no `, …`
    // suffix. Guards against off-by-one in the `len > show_n` check.
    var realm = Realm.init(testing.allocator);
    defer realm.deinit();
    realm.feature_flags = features.FeatureSet.initFull();
    try realm.installBuiltins();

    const v = try evalScriptValue(&realm, "Array.from({length: 50}, (_, i) => i);");

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(testing.allocator);
    try appendValue(testing.allocator, &buf, v);

    try testing.expect(std.mem.endsWith(u8, buf.items, ", 49]"));
    try testing.expect(std.mem.indexOf(u8, buf.items, "more") == null);
}

test "wasm_format: one past truncation boundary" {
    // 51 elements — one over. The tail says "1 more".
    var realm = Realm.init(testing.allocator);
    defer realm.deinit();
    realm.feature_flags = features.FeatureSet.initFull();
    try realm.installBuiltins();

    const v = try evalScriptValue(&realm, "Array.from({length: 51}, (_, i) => i);");

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(testing.allocator);
    try appendValue(testing.allocator, &buf, v);

    try testing.expect(std.mem.endsWith(u8, buf.items, ", … (1 more)]"));
}

test "wasm_format: dense hole renders <empty>" {
    // Assigning past length leaves the slots before as
    // `Value.hole_`. Below the sparse threshold, so the array stays
    // dense and the holes flow through `appendValueAt`'s `isHole`
    // branch.
    try expectFormat("const a = []; a[3] = 7; a;", "[<empty>, <empty>, <empty>, 7]");
}

test "wasm_format: iterator-helpers regression — toArray" {
    // The reported bug: this used to render `[object Object]`.
    try expectFormat(
        \\function* nats() { let n = 1; while (true) yield n++; }
        \\nats().map(n => n * n).filter(n => n % 2 === 1).take(5).toArray();
    ,
        "[1, 9, 25, 49, 81]",
    );
}
