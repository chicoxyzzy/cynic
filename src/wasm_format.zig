//! Value → display-string formatter for the playground panel.
//!
//! Not a spec-faithful `Object.prototype.toString` — the playground
//! shows the completion value as a *hint*. Arrays get a
//! JSON-flavoured elementwise dump clamped by depth and length;
//! plain objects and functions get a coarse tag; primitives get
//! their natural form. Lives in `src/` (not `src/runtime/`) because
//! it is a display concern — the engine itself does not need it.
//!
//! Lifted out of `playground/wasm.zig` so `zig build test` can
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
const date = @import("runtime/builtins/date.zig");

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
        } else if (try appendExoticObject(allocator, buf, obj, depth)) {
            // Rendered as a typed-slot builtin (Map / Set / Date /
            // RegExp / Promise / boxed primitive); nothing more to do.
        } else {
            try appendObject(allocator, buf, obj, depth);
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
            if (obj.sparseConst().get(i)) |elem| {
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

/// Render a plain (non-array) object as `{k0: v0, k1: v1, …}`,
/// clamped by `max_array_show` and `max_depth`. Walks own enumerable
/// string-keyed DATA properties in insertion / shape order — the same
/// set `Object.keys` yields — so a null-prototype object (e.g. an
/// `Object.groupBy` result) renders its buckets instead of the old
/// coarse `[object Object]` tag. Skips internal `__cynic_*` slots;
/// accessor-only keys never reach `iterOwnNamedKeys` (it walks data
/// storage), and getters are deliberately NOT invoked — this is a
/// display hint, not a spec `[[Get]]`.
fn appendObject(
    allocator: std.mem.Allocator,
    buf: *std.ArrayListUnmanaged(u8),
    obj: *JSObject,
    depth: u8,
) FormatError!void {
    if (depth >= max_depth) {
        try buf.appendSlice(allocator, "{…}");
        return;
    }

    // Count eligible keys first so the "(N more)" tail is exact and
    // matches the array path's truncation shape.
    var total: usize = 0;
    {
        var it = obj.iterOwnNamedKeys();
        while (it.next()) |e| {
            if (objKeyEligible(obj, e.key_ptr.*)) total += 1;
        }
    }

    try buf.append(allocator, '{');
    const show_n = @min(total, max_array_show);
    var shown: usize = 0;
    var it = obj.iterOwnNamedKeys();
    while (it.next()) |e| {
        const key = e.key_ptr.*;
        if (!objKeyEligible(obj, key)) continue;
        if (shown >= show_n) break;
        if (shown > 0) try buf.appendSlice(allocator, ", ");
        try buf.appendSlice(allocator, key);
        try buf.appendSlice(allocator, ": ");
        try appendValueAt(allocator, buf, e.value_ptr.*, depth + 1);
        shown += 1;
    }
    if (total > show_n) {
        var scratch: [48]u8 = undefined;
        try buf.appendSlice(
            allocator,
            try std.fmt.bufPrint(&scratch, ", … ({d} more)", .{total - show_n}),
        );
    }
    try buf.append(allocator, '}');
}

/// An own named key counts toward the object dump iff it is a
/// user-visible enumerable property: not an internal `__cynic_*`
/// slot, and `[[Enumerable]]` (the set `Object.keys` would return).
fn objKeyEligible(obj: *const JSObject, key: []const u8) bool {
    if (std.mem.startsWith(u8, key, "__cynic_")) return false;
    return obj.flagsFor(key).enumerable;
}

/// Render the typed-slot builtins whose state lives in dedicated
/// `JSObject` slots — not the enumerable property bag — so the
/// generic `appendObject` dump would show them as a misleading `{}`.
/// Returns `true` if `obj` was one of them (and already written),
/// `false` to fall through to the plain-object path.
///
/// Order matters only for objects that could plausibly carry two
/// slots at once; in practice each builtin owns exactly one, so the
/// checks are mutually exclusive.
fn appendExoticObject(
    allocator: std.mem.Allocator,
    buf: *std.ArrayListUnmanaged(u8),
    obj: *JSObject,
    depth: u8,
) FormatError!bool {
    // RegExp — `/source/flags`, read straight off the original-source
    // / original-flags slots (§22.2.4).
    if (obj.getRegexpSource()) |src| {
        try buf.append(allocator, '/');
        try buf.appendSlice(allocator, src.flatBytes());
        try buf.append(allocator, '/');
        if (obj.getRegexpFlags()) |fl| try buf.appendSlice(allocator, fl.flatBytes());
        return true;
    }

    // Map / WeakMap — §24.1 [[MapData]]. A WeakMap's entries can't be
    // enumerated (weak keys), so it shows just the tag.
    if (obj.getMapData()) |m| {
        if (m.is_weak) {
            try buf.appendSlice(allocator, "WeakMap {…}");
            return true;
        }
        try appendMap(allocator, buf, m, depth);
        return true;
    }

    // Set / WeakSet — §24.2 [[SetData]].
    if (obj.getSetData()) |s| {
        if (s.is_weak) {
            try buf.appendSlice(allocator, "WeakSet {…}");
            return true;
        }
        try appendSet(allocator, buf, s, depth);
        return true;
    }

    // Promise — §27.2. State only; the settled value isn't surfaced
    // here (reading it can race the reaction queue and isn't a
    // property anyway).
    if (obj.promise_state != .none) {
        try buf.appendSlice(allocator, switch (obj.promise_state) {
            .pending => "Promise {<pending>}",
            .fulfilled => "Promise {<fulfilled>}",
            .rejected => "Promise {<rejected>}",
            .none => unreachable,
        });
        return true;
    }

    // Date — the ISO string, reusing the builtin's pure civil-date
    // math (§21.4.4.36). Out-of-range / NaN shows `Invalid Date`.
    if (obj.getDateMs()) |ms| {
        try appendDate(allocator, buf, ms);
        return true;
    }

    // Boxed primitive — `new Number(5)` / `new String("x")` /
    // `new Boolean(true)`. Show the wrapped value with a tag.
    if (obj.getBoxedPrimitive()) |prim| {
        const tag = if (prim.isString()) "String" else if (prim.isBool()) "Boolean" else "Number";
        try buf.append(allocator, '[');
        try buf.appendSlice(allocator, tag);
        try buf.appendSlice(allocator, ": ");
        try appendValueAt(allocator, buf, prim, depth + 1);
        try buf.append(allocator, ']');
        return true;
    }

    return false;
}

/// `Map(N) {k0 => v0, k1 => v1, …}` — non-deleted entries in
/// insertion order, clamped by `max_array_show` / `max_depth`.
fn appendMap(
    allocator: std.mem.Allocator,
    buf: *std.ArrayListUnmanaged(u8),
    m: *const @import("runtime/object.zig").MapData,
    depth: u8,
) FormatError!void {
    var live: usize = 0;
    for (m.entries.items) |e| {
        if (!e.deleted) live += 1;
    }
    var scratch: [32]u8 = undefined;
    try buf.appendSlice(allocator, try std.fmt.bufPrint(&scratch, "Map({d})", .{live}));
    if (depth >= max_depth) {
        try buf.appendSlice(allocator, " {…}");
        return;
    }
    try buf.appendSlice(allocator, " {");
    const show_n = @min(live, max_array_show);
    var shown: usize = 0;
    for (m.entries.items) |e| {
        if (e.deleted) continue;
        if (shown >= show_n) break;
        if (shown > 0) try buf.appendSlice(allocator, ", ");
        try appendValueAt(allocator, buf, e.key, depth + 1);
        try buf.appendSlice(allocator, " => ");
        try appendValueAt(allocator, buf, e.value, depth + 1);
        shown += 1;
    }
    if (live > show_n) {
        try buf.appendSlice(allocator, try std.fmt.bufPrint(&scratch, ", … ({d} more)", .{live - show_n}));
    }
    try buf.append(allocator, '}');
}

/// `Set(N) {v0, v1, …}` — non-deleted members in insertion order.
fn appendSet(
    allocator: std.mem.Allocator,
    buf: *std.ArrayListUnmanaged(u8),
    s: *const @import("runtime/object.zig").SetData,
    depth: u8,
) FormatError!void {
    var live: usize = 0;
    for (s.entries.items) |e| {
        if (!e.deleted) live += 1;
    }
    var scratch: [32]u8 = undefined;
    try buf.appendSlice(allocator, try std.fmt.bufPrint(&scratch, "Set({d})", .{live}));
    if (depth >= max_depth) {
        try buf.appendSlice(allocator, " {…}");
        return;
    }
    try buf.appendSlice(allocator, " {");
    const show_n = @min(live, max_array_show);
    var shown: usize = 0;
    for (s.entries.items) |e| {
        if (e.deleted) continue;
        if (shown >= show_n) break;
        if (shown > 0) try buf.appendSlice(allocator, ", ");
        try appendValueAt(allocator, buf, e.value, depth + 1);
        shown += 1;
    }
    if (live > show_n) {
        try buf.appendSlice(allocator, try std.fmt.bufPrint(&scratch, ", … ({d} more)", .{live - show_n}));
    }
    try buf.append(allocator, '}');
}

/// A Date's `toISOString` form (§21.4.4.36), or `Invalid Date` for a
/// NaN / out-of-TimeClip-range value. Reuses `date.dateParts` so the
/// civil-calendar math has a single source of truth.
fn appendDate(
    allocator: std.mem.Allocator,
    buf: *std.ArrayListUnmanaged(u8),
    ms: f64,
) FormatError!void {
    if (!std.math.isFinite(ms) or @abs(ms) > 8.64e15) {
        try buf.appendSlice(allocator, "Invalid Date");
        return;
    }
    const p = date.dateParts(ms);
    const u = struct {
        fn cast(x: i64) u64 {
            return @intCast(x);
        }
    }.cast;
    var scratch: [40]u8 = undefined;
    const text = if (p.year >= 0 and p.year <= 9999)
        try std.fmt.bufPrint(&scratch, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}.{d:0>3}Z", .{
            u(p.year), u(p.month + 1), u(p.day), u(p.hours), u(p.minutes), u(p.seconds), u(p.ms),
        })
    else if (p.year < 0)
        try std.fmt.bufPrint(&scratch, "-{d:0>6}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}.{d:0>3}Z", .{
            u(-p.year), u(p.month + 1), u(p.day), u(p.hours), u(p.minutes), u(p.seconds), u(p.ms),
        })
    else
        try std.fmt.bufPrint(&scratch, "+{d:0>6}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}.{d:0>3}Z", .{
            u(p.year), u(p.month + 1), u(p.day), u(p.hours), u(p.minutes), u(p.seconds), u(p.ms),
        });
    try buf.appendSlice(allocator, text);
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
    realm.feature_flags = features.FeatureSet.full;
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
    try expectFormat("({x: 1, y: 2});", "{x: 1, y: 2}");
}

test "wasm_format: empty object" {
    try expectFormat("({});", "{}");
}

test "wasm_format: object with string + nested values" {
    try expectFormat(
        "({name: \"x\", n: 1, ok: true, list: [1, 2]});",
        "{name: \"x\", n: 1, ok: true, list: [1, 2]}",
    );
}

test "wasm_format: null-prototype object renders its keys" {
    // Object.create(null) has no toString in its (absent) chain; the
    // formatter must still dump own enumerable data props rather than
    // fall back to a coarse tag.
    try expectFormat(
        "Object.assign(Object.create(null), {a: 1, b: 2});",
        "{a: 1, b: 2}",
    );
}

test "wasm_format: Object.groupBy result" {
    // The reported case — a null-proto bucket object. Keys in
    // first-encounter order, values are the grouped arrays.
    try expectFormat(
        "Object.groupBy([1, 2, 3, 4], (n) => (n % 2 ? \"odd\" : \"even\"));",
        "{odd: [1, 3], even: [2, 4]}",
    );
}

test "wasm_format: non-enumerable own prop is hidden" {
    try expectFormat(
        \\const o = {a: 1};
        \\Object.defineProperty(o, "hidden", { value: 9, enumerable: false });
        \\o;
    ,
        "{a: 1}",
    );
}

test "wasm_format: object nested past depth cap collapses" {
    // {a:{b:{c:{d:{...}}}}} — the object at depth == max_depth prints
    // `{…}` instead of descending.
    try expectFormat(
        "({a: {b: {c: {d: {e: 1}}}}});",
        "{a: {b: {c: {d: {…}}}}}",
    );
}

test "wasm_format: Map renders entries" {
    try expectFormat(
        "new Map([[\"a\", 1], [\"b\", 2]]);",
        "Map(2) {\"a\" => 1, \"b\" => 2}",
    );
}

test "wasm_format: empty Map" {
    try expectFormat("new Map();", "Map(0) {}");
}

test "wasm_format: Set renders members" {
    try expectFormat("new Set([1, 2, 3]);", "Set(3) {1, 2, 3}");
}

test "wasm_format: WeakMap shows tag, not entries" {
    try expectFormat(
        "const k = {}; new WeakMap([[k, 1]]);",
        "WeakMap {…}",
    );
}

test "wasm_format: RegExp renders source and flags" {
    try expectFormat("/ab+c/gi;", "/ab+c/gi");
}

test "wasm_format: RegExp no flags" {
    try expectFormat("/x/;", "/x/");
}

test "wasm_format: resolved Promise shows state" {
    try expectFormat("Promise.resolve(1);", "Promise {<fulfilled>}");
}

test "wasm_format: Date renders ISO string" {
    try expectFormat(
        "new Date(0);",
        "1970-01-01T00:00:00.000Z",
    );
}

test "wasm_format: invalid Date" {
    try expectFormat("new Date(NaN);", "Invalid Date");
}

test "wasm_format: boxed Number" {
    try expectFormat("new Number(42);", "[Number: 42]");
}

test "wasm_format: boxed String" {
    try expectFormat("new String(\"hi\");", "[String: \"hi\"]");
}

test "wasm_format: Map nested in array" {
    try expectFormat(
        "[new Set([1, 2])];",
        "[Set(2) {1, 2}]",
    );
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
    try expectFormat("[{x: 1}];", "[{x: 1}]");
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
    realm.feature_flags = features.FeatureSet.full;
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
    realm.feature_flags = features.FeatureSet.full;
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
    realm.feature_flags = features.FeatureSet.full;
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
