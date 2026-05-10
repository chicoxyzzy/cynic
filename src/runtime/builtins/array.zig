//! §23.1 Array.prototype methods + Array statics — extracted
//! from `intrinsics.zig`. Cynic's Arrays are plain JSObjects
//! with `[[Prototype]] === %Array.prototype%` and a numeric
//! `length` slot — no dedicated `JSArray` heap kind. The methods
//! here all accept array-likes via `toObjectThis` and use
//! `toLengthOf` for the bound + `getPropertyChain` for indexed
//! reads, so accessor-defined `length` and indexed properties
//! work per spec.

const std = @import("std");

const Realm = @import("../realm.zig").Realm;
const Value = @import("../value.zig").Value;
const JSString = @import("../string.zig").JSString;
const JSObject = @import("../object.zig").JSObject;
const JSFunction = @import("../function.zig").JSFunction;
const NativeError = @import("../function.zig").NativeError;
const heap_mod = @import("../heap.zig");
const intrinsics = @import("../intrinsics.zig");
const interpreter = @import("../interpreter.zig");

const installNativeMethod = intrinsics.installNativeMethod;
const installNativeMethodOnProto = intrinsics.installNativeMethodOnProto;
const argOr = intrinsics.argOr;
const coerceToNumber = intrinsics.coerceToNumber;
const throwTypeError = intrinsics.throwTypeError;
const throwRangeError = intrinsics.throwRangeError;
const stringifyArg = intrinsics.stringifyArg;
const sameValueZero = intrinsics.sameValueZero;
const strictEqualsLite = intrinsics.strictEqualsLite;
const getPropertyChain = intrinsics.getPropertyChain;
const toLengthOf = intrinsics.toLengthOf;
const toObjectThis = intrinsics.toObjectThis;
const toInt = intrinsics.toInt;
const lengthOfArray = intrinsics.lengthOfArray;
const clampArrayLength = intrinsics.clampArrayLength;
const max_iter_length = intrinsics.max_iter_length;
const callJSFunction = interpreter.callJSFunction;
const collections = @import("collections.zig");
const objectFromThis = intrinsics.objectFromThis;

/// Install `Array.prototype.*` instance methods + the
/// `Array.{isArray, of, from}` statics. Caller arranges that
/// `realm.intrinsics.array_prototype` and the `Array` global
/// stub already exist (they're set up early in
/// `intrinsics.install` since stub constructors land before
/// the per-method wiring).
pub fn install(realm: *Realm) !void {
    if (realm.intrinsics.array_prototype) |arr_proto| {
        // §23.1.3 — %Array.prototype% is an Array exotic with an
        // own `length` property, value 0, descriptor `{writable:
        // true, enumerable: false, configurable: false}`. Without
        // it `Array.prototype.length` reads as `undefined` and
        // `Object.getOwnPropertyDescriptor(Array.prototype,
        // "length")` returns null.
        try arr_proto.setWithFlags(realm.allocator, "length", Value.fromInt32(0), .{
            .writable = true,
            .enumerable = false,
            .configurable = false,
        });
        try installNativeMethodOnProto(realm, arr_proto, "push", arrayPush, 1);
        try installNativeMethodOnProto(realm, arr_proto, "pop", arrayPop, 0);
        try installNativeMethodOnProto(realm, arr_proto, "indexOf", arrayIndexOf, 1);
        try installNativeMethodOnProto(realm, arr_proto, "includes", arrayIncludes, 1);
        try installNativeMethodOnProto(realm, arr_proto, "join", arrayJoin, 1);
        try installNativeMethodOnProto(realm, arr_proto, "slice", arraySlice, 2);
        try installNativeMethodOnProto(realm, arr_proto, "concat", arrayConcat, 1);
        try installNativeMethodOnProto(realm, arr_proto, "forEach", arrayForEach, 1);
        try installNativeMethodOnProto(realm, arr_proto, "map", arrayMap, 1);
        try installNativeMethodOnProto(realm, arr_proto, "filter", arrayFilter, 1);
        try installNativeMethodOnProto(realm, arr_proto, "every", arrayEvery, 1);
        try installNativeMethodOnProto(realm, arr_proto, "some", arraySome, 1);
        try installNativeMethodOnProto(realm, arr_proto, "find", arrayFind, 1);
        try installNativeMethodOnProto(realm, arr_proto, "findIndex", arrayFindIndex, 1);
        try installNativeMethodOnProto(realm, arr_proto, "reduce", arrayReduce, 1);
        try installNativeMethodOnProto(realm, arr_proto, "toString", arrayJoin, 0);
        try installNativeMethodOnProto(realm, arr_proto, "reverse", arrayReverse, 0);
        try installNativeMethodOnProto(realm, arr_proto, "shift", arrayShift, 0);
        try installNativeMethodOnProto(realm, arr_proto, "unshift", arrayUnshift, 1);
        try installNativeMethodOnProto(realm, arr_proto, "at", arrayAt, 1);
        try installNativeMethodOnProto(realm, arr_proto, "fill", arrayFill, 1);
        try installNativeMethodOnProto(realm, arr_proto, "lastIndexOf", arrayLastIndexOf, 1);
        try installNativeMethodOnProto(realm, arr_proto, "findLast", arrayFindLast, 1);
        try installNativeMethodOnProto(realm, arr_proto, "findLastIndex", arrayFindLastIndex, 1);
        try installNativeMethodOnProto(realm, arr_proto, "reduceRight", arrayReduceRight, 1);
        try installNativeMethodOnProto(realm, arr_proto, "flat", arrayFlat, 0);
        try installNativeMethodOnProto(realm, arr_proto, "flatMap", arrayFlatMap, 1);
        try installNativeMethodOnProto(realm, arr_proto, "splice", arraySplice, 2);
        try installNativeMethodOnProto(realm, arr_proto, "copyWithin", arrayCopyWithin, 2);
        try installNativeMethodOnProto(realm, arr_proto, "sort", arraySort, 1);
        // §23.1.3 — Array iterators. Implementations live in
        // `builtins/collections.zig` (shared with Map/Set).
        try installNativeMethodOnProto(realm, arr_proto, "values", collections.arrayLikeValuesMethod, 0);
        try installNativeMethodOnProto(realm, arr_proto, "keys", collections.arrayLikeKeysMethod, 0);
        try installNativeMethodOnProto(realm, arr_proto, "entries", collections.arrayLikeEntriesMethod, 0);
        try installNativeMethodOnProto(realm, arr_proto, "@@iterator", collections.arrayLikeValuesMethod, 0);
    }
    if (heap_mod.valueAsFunction(realm.globals.get("Array").?)) |arr_ctor| {
        // Replace the stub-constructor body with the real
        // §22.1.1 semantics now that array_prototype is wired.
        arr_ctor.native_callback = arrayConstructor;
        try installNativeMethod(realm, arr_ctor, "isArray", arrayIsArray, 1);
        try installNativeMethod(realm, arr_ctor, "of", arrayOf, 0);
        try installNativeMethod(realm, arr_ctor, "from", arrayFrom, 1);
    }
}

/// §22.1.1 Array(...) — both `new` and plain-call.
/// • `Array()` → `[]`
/// • `Array(N)` where N is a Number → array of length N (must
///   be a uint32; non-integer or negative throws RangeError).
/// • `Array(item0, item1, …)` → `[item0, item1, …]`. The
///   single-arg form gates on `typeof arg === "number"`, so
///   `Array("x")` is `["x"]` not a 1-element array.
/// `new Array(...)` arrives with `this_value` = the freshly
/// allocated `this`; we hand it back populated. Plain-call
/// allocates a fresh array.
fn arrayConstructor(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const out = if (heap_mod.valueAsPlainObject(this_value)) |obj| obj else blk: {
        const fresh = realm.heap.allocateObject() catch return error.OutOfMemory;
        fresh.prototype = realm.intrinsics.array_prototype;
        break :blk fresh;
    };

    if (args.len == 1 and (args[0].isInt32() or args[0].isDouble())) {
        // §22.1.1.2 Array(len) — single Number arg sets length.
        const n_d: f64 = if (args[0].isInt32()) @floatFromInt(args[0].asInt32()) else args[0].asDouble();
        if (std.math.isNan(n_d) or std.math.isInf(n_d) or n_d < 0 or n_d > @as(f64, @floatFromInt(@as(u32, std.math.maxInt(u32))))) {
            return throwRangeError(realm, "Array length out of range");
        }
        const trunc_n = @trunc(n_d);
        if (trunc_n != n_d) {
            return throwRangeError(realm, "Array length must be a non-negative integer");
        }
        const len: u32 = @intFromFloat(trunc_n);
        out.set(realm.allocator, "length", Value.fromInt32(@intCast(len))) catch return error.OutOfMemory;
        return heap_mod.taggedObject(out);
    }

    // §22.1.1.3 Array(...items) — every arg becomes an element.
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        var ibuf: [24]u8 = undefined;
        const islice = std.fmt.bufPrint(&ibuf, "{d}", .{i}) catch unreachable;
        const owned = realm.heap.allocateString(islice) catch return error.OutOfMemory;
        out.set(realm.allocator, owned.bytes, args[i]) catch return error.OutOfMemory;
    }
    out.set(realm.allocator, "length", Value.fromInt32(@intCast(args.len))) catch return error.OutOfMemory;
    return heap_mod.taggedObject(out);
}

// ── Array.prototype methods ─────────────────────────────────────────────────

fn arrayPush(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const obj = try toObjectThis(realm, this_value);
    var len = try clampArrayLength(try toLengthOf(realm, obj));
    for (args) |v| {
        if (len >= max_iter_length) return throwRangeError(realm, "Array length exceeds maximum supported");
        var ibuf: [24]u8 = undefined;
        const islice = std.fmt.bufPrint(&ibuf, "{d}", .{len}) catch unreachable;
        const owned = realm.heap.allocateString(islice) catch return error.OutOfMemory;
        obj.set(realm.allocator, owned.bytes, v) catch return error.OutOfMemory;
        len += 1;
    }
    setLength(realm, obj, len) catch return error.OutOfMemory;
    return numberFromI64(len);
}

fn arrayPop(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = args;
    const obj = try toObjectThis(realm, this_value);
    var len = try toLengthOf(realm, obj);
    if (len <= 0) {
        setLength(realm, obj, 0) catch return error.OutOfMemory;
        return Value.undefined_;
    }
    len -= 1;
    var ibuf: [24]u8 = undefined;
    const islice = std.fmt.bufPrint(&ibuf, "{d}", .{len}) catch unreachable;
    const v = try getPropertyChain(realm, obj, islice);
    _ = obj.properties.swapRemove(islice);
    setLength(realm, obj, len) catch return error.OutOfMemory;
    return v;
}

/// Store a length on an array-shaped object. Length values that
/// overflow `i32` get stored as a `Value.fromDouble` instead —
/// matches §6.1.6.1 NumberValue (length is a Number, not int32).
pub fn setLength(realm: *Realm, obj: *JSObject, len: i64) !void {
    try obj.set(realm.allocator, "length", numberFromI64(len));
}

pub fn numberFromI64(n: i64) Value {
    if (n >= std.math.minInt(i32) and n <= std.math.maxInt(i32)) {
        return Value.fromInt32(@intCast(n));
    }
    return Value.fromDouble(@floatFromInt(n));
}

fn arrayIndexOf(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const obj = try toObjectThis(realm, this_value);
    const target = argOr(args, 0, Value.undefined_);
    // §23.1.3.16 step 1-7 — handle fromIndex BEFORE clamping
    // length so a fromIndex of +∞ short-circuits to -1 even when
    // the array's length exceeds our 16M iteration cap.
    const raw_len = try toLengthOf(realm, obj);
    if (raw_len <= 0) return Value.fromInt32(-1);
    const start = startIndexFrom(args, raw_len) orelse return Value.fromInt32(-1);
    const len = try clampArrayLength(raw_len);
    var i: i64 = start;
    while (i < len) : (i += 1) {
        var ibuf: [24]u8 = undefined;
        const islice = std.fmt.bufPrint(&ibuf, "{d}", .{i}) catch unreachable;
        if (!obj.hasProperty(islice)) continue;
        const v = try getPropertyChain(realm, obj, islice);
        if (strictEqualsLite(v, target)) return numberFromI64(i);
    }
    return Value.fromInt32(-1);
}

/// §23.1.3.16 step 5-7 — clamp the optional `fromIndex` arg
/// against the (uncapped) array length. Returns the start index
/// to iterate from, or `null` when fromIndex is past the end
/// (caller short-circuits to -1). Negative fromIndex is offset
/// from the end (`len + fromIndex`), clamped to 0.
fn startIndexFrom(args: []const Value, len: i64) ?i64 {
    if (args.len < 2) return 0;
    const v = args[1];
    // §7.1.5 ToIntegerOrInfinity coercion. We accept Number
    // primitives directly; for String go through `coerceToNumber`
    // (which handles "Infinity", "-Infinity", numeric strings,
    // and the empty/all-whitespace cases per §7.1.4).
    const nv = if (v.isString()) intrinsics.coerceToNumber(v) else v;
    const n: f64 = if (nv.isUndefined()) 0 else if (nv.isInt32()) @floatFromInt(nv.asInt32()) else if (nv.isDouble()) nv.asDouble() else if (nv.isBool()) (if (nv.asBool()) @as(f64, 1) else @as(f64, 0)) else if (nv.isNull()) @as(f64, 0) else 0;
    if (std.math.isNan(n)) return 0;
    if (n == std.math.inf(f64)) return null;
    if (n == -std.math.inf(f64)) return 0;
    const trunc_n = @trunc(n);
    if (trunc_n >= 0) {
        // i64::MAX exceeds f64's exactly-representable integer
        // range — `len` is already a real array length so any
        // `trunc_n` ≥ `len` short-circuits below.
        const flen: f64 = @floatFromInt(len);
        if (trunc_n >= flen) return null;
        return @intFromFloat(trunc_n);
    }
    // Negative — count from the end.
    const flen: f64 = @floatFromInt(len);
    const adjusted = flen + trunc_n;
    if (adjusted < 0) return 0;
    return @intFromFloat(adjusted);
}

fn arrayIncludes(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const obj = try toObjectThis(realm, this_value);
    const target = argOr(args, 0, Value.undefined_);
    const len = try clampArrayLength(try toLengthOf(realm, obj));
    var i: i64 = 0;
    while (i < len) : (i += 1) {
        var ibuf: [24]u8 = undefined;
        const islice = std.fmt.bufPrint(&ibuf, "{d}", .{i}) catch unreachable;
        const v = try getPropertyChain(realm, obj, islice);
        if (sameValueZero(v, target)) return Value.true_;
    }
    return Value.false_;
}

fn arrayJoin(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const obj = try toObjectThis(realm, this_value);
    const sep_v = argOr(args, 0, Value.undefined_);
    const sep_slice: []const u8 = if (sep_v.isUndefined())
        ","
    else if (sep_v.isString()) blk: {
        const s: *JSString = @ptrCast(@alignCast(sep_v.asString()));
        break :blk s.bytes;
    } else ",";
    const len = try clampArrayLength(try toLengthOf(realm, obj));
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(realm.allocator);
    var i: i64 = 0;
    while (i < len) : (i += 1) {
        if (i != 0) buf.appendSlice(realm.allocator, sep_slice) catch return error.OutOfMemory;
        var ibuf: [24]u8 = undefined;
        const islice = std.fmt.bufPrint(&ibuf, "{d}", .{i}) catch unreachable;
        const v = try getPropertyChain(realm, obj, islice);
        if (v.isUndefined() or v.isNull()) continue; // §23.1.3.18 — undefined / null become empty
        const s = stringifyArg(realm, v) catch return error.OutOfMemory;
        buf.appendSlice(realm.allocator, s.bytes) catch return error.OutOfMemory;
    }
    const out = realm.heap.allocateString(buf.items) catch return error.OutOfMemory;
    return Value.fromString(out);
}

fn arraySlice(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const obj = try toObjectThis(realm, this_value);
    const raw_len = try toLengthOf(realm, obj);
    const len = try clampArrayLength(raw_len);
    var start: i64 = if (args.len > 0) toInt(args[0]) else 0;
    var end: i64 = if (args.len > 1 and !args[1].isUndefined()) toInt(args[1]) else len;
    if (start < 0) start = @max(len + start, 0);
    if (end < 0) end = @max(len + end, 0);
    start = @min(start, len);
    end = @min(end, len);

    const out = realm.heap.allocateObject() catch return error.OutOfMemory;
    out.prototype = realm.intrinsics.array_prototype;
    var write_idx: i64 = 0;
    var read_idx = start;
    while (read_idx < end) : (read_idx += 1) {
        var rbuf: [24]u8 = undefined;
        const rslice = std.fmt.bufPrint(&rbuf, "{d}", .{read_idx}) catch unreachable;
        if (!obj.hasProperty(rslice)) {
            write_idx += 1;
            continue;
        }
        const v = try getPropertyChain(realm, obj, rslice);
        var wbuf: [24]u8 = undefined;
        const wslice = std.fmt.bufPrint(&wbuf, "{d}", .{write_idx}) catch unreachable;
        const owned = realm.heap.allocateString(wslice) catch return error.OutOfMemory;
        out.set(realm.allocator, owned.bytes, v) catch return error.OutOfMemory;
        write_idx += 1;
    }
    setLength(realm, out, write_idx) catch return error.OutOfMemory;
    return heap_mod.taggedObject(out);
}

fn arrayConcat(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const obj = try toObjectThis(realm, this_value);
    const out = realm.heap.allocateObject() catch return error.OutOfMemory;
    out.prototype = realm.intrinsics.array_prototype;
    var write_idx: i64 = 0;
    // Copy own array first.
    {
        const len = try clampArrayLength(lengthOfArray(obj));
        var i: i64 = 0;
        while (i < len) : (i += 1) {
            var rbuf: [24]u8 = undefined;
            const rslice = std.fmt.bufPrint(&rbuf, "{d}", .{i}) catch unreachable;
            const v = obj.get(rslice);
            var wbuf: [24]u8 = undefined;
            const wslice = std.fmt.bufPrint(&wbuf, "{d}", .{write_idx}) catch unreachable;
            const owned = realm.heap.allocateString(wslice) catch return error.OutOfMemory;
            out.set(realm.allocator, owned.bytes, v) catch return error.OutOfMemory;
            write_idx += 1;
        }
    }
    // Then each argument: spreadable arrays expand, others append.
    for (args) |arg| {
        if (heap_mod.valueAsPlainObject(arg)) |arr| {
            // Treat any object with a numeric `length` as
            // spreadable — close enough to §23.1.3.2's
            // IsConcatSpreadable for our later floor.
            const len = try clampArrayLength(lengthOfArray(arr));
            var i: i64 = 0;
            while (i < len) : (i += 1) {
                var rbuf: [24]u8 = undefined;
                const rslice = std.fmt.bufPrint(&rbuf, "{d}", .{i}) catch unreachable;
                const v = arr.get(rslice);
                var wbuf: [24]u8 = undefined;
                const wslice = std.fmt.bufPrint(&wbuf, "{d}", .{write_idx}) catch unreachable;
                const owned = realm.heap.allocateString(wslice) catch return error.OutOfMemory;
                out.set(realm.allocator, owned.bytes, v) catch return error.OutOfMemory;
                write_idx += 1;
            }
        } else {
            var wbuf: [24]u8 = undefined;
            const wslice = std.fmt.bufPrint(&wbuf, "{d}", .{write_idx}) catch unreachable;
            const owned = realm.heap.allocateString(wslice) catch return error.OutOfMemory;
            out.set(realm.allocator, owned.bytes, arg) catch return error.OutOfMemory;
            write_idx += 1;
        }
    }
    setLength(realm, out, write_idx) catch return error.OutOfMemory;
    return heap_mod.taggedObject(out);
}

// ── Additional Array methods ────────────────────────────────────────────────

fn arrayIsArray(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = realm;
    _ = this_value;
    const v = argOr(args, 0, Value.undefined_);
    const obj = heap_mod.valueAsPlainObject(v) orelse return Value.false_;
    // Heuristic: an "array" is an object whose [[Prototype]] is
    // %Array.prototype% (or chains to it). Real engines check
    // an internal slot; ours uses prototype identity. Good
    // enough for later — `Array.isArray([1,2])` is true,
    // `Array.isArray({})` is false.
    if (obj.prototype) |p| {
        var c: ?*JSObject = p;
        while (c) |x| : (c = x.prototype) {
            const ctor_v = x.get("constructor");
            if (heap_mod.valueAsFunction(ctor_v)) |fn_obj| {
                if (fn_obj.name) |nm| {
                    if (std.mem.eql(u8, nm, "Array")) return Value.true_;
                }
            }
        }
    }
    return Value.false_;
}

fn arrayOf(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = this_value;
    const out = realm.heap.allocateObject() catch return error.OutOfMemory;
    out.prototype = realm.intrinsics.array_prototype;
    for (args, 0..) |v, idx| {
        var ibuf: [24]u8 = undefined;
        const islice = std.fmt.bufPrint(&ibuf, "{d}", .{idx}) catch unreachable;
        const owned = realm.heap.allocateString(islice) catch return error.OutOfMemory;
        out.set(realm.allocator, owned.bytes, v) catch return error.OutOfMemory;
    }
    setLength(realm, out, @intCast(args.len)) catch return error.OutOfMemory;
    return heap_mod.taggedObject(out);
}

/// §23.1.2.1 Array.from( items [, mapfn [, thisArg ] ] ).
/// Three paths: string (iterate code points), iterable
/// (walks `@@iterator` — Sets, Maps, generators, custom
/// iterables), and array-like fallback (`length` + indexed get,
/// for `{length: n}` and DOM-style nodelists).
fn arrayFrom(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = this_value;
    const items = argOr(args, 0, Value.undefined_);
    const mapfn_v = argOr(args, 1, Value.undefined_);
    const this_arg = argOr(args, 2, Value.undefined_);
    const mapfn: ?*JSFunction = if (mapfn_v.isUndefined()) null else heap_mod.valueAsFunction(mapfn_v) orelse return throwTypeError(realm, "Array.from: mapfn is not a function");

    const out = realm.heap.allocateObject() catch return error.OutOfMemory;
    out.prototype = realm.intrinsics.array_prototype;

    // String fast path — iterate characters.
    if (items.isString()) {
        const s: *JSString = @ptrCast(@alignCast(items.asString()));
        var i: usize = 0;
        while (i < s.bytes.len) : (i += 1) {
            const ch = realm.heap.allocateString(s.bytes[i .. i + 1]) catch return error.OutOfMemory;
            const elem: Value = blk: {
                if (mapfn) |mf| {
                    const cb_args = [_]Value{ Value.fromString(ch), numberFromI64(@intCast(i)) };

                    const outcome = interpreter.callJSFunction(realm.allocator, realm, mf, this_arg, &cb_args) catch return error.NativeThrew;
                    switch (outcome) {
                        .value, .yielded => |v| break :blk v,
                        .thrown => return error.NativeThrew,
                    }
                } else break :blk Value.fromString(ch);
            };
            var ibuf: [24]u8 = undefined;
            const islice = std.fmt.bufPrint(&ibuf, "{d}", .{i}) catch unreachable;
            const idx_owned = realm.heap.allocateString(islice) catch return error.OutOfMemory;
            out.set(realm.allocator, idx_owned.bytes, elem) catch return error.OutOfMemory;
        }
        setLength(realm, out, @intCast(s.bytes.len)) catch return error.OutOfMemory;
        return heap_mod.taggedObject(out);
    }

    const src = heap_mod.valueAsPlainObject(items) orelse return throwTypeError(realm, "Array.from: items is not iterable");

    // Iterable path — preferred when present per §23.1.2.1 step 4.
    // GetMethod(items, @@iterator) walks the prototype chain; if
    // it resolves to a callable, take the iterator-protocol path.
    const iter_method_v = try getPropertyChain(realm, src, "@@iterator");
    if (heap_mod.valueAsFunction(iter_method_v)) |iter_method| {
        const iter_outcome = interpreter.callJSFunction(realm.allocator, realm, iter_method, items, &.{}) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.NativeThrew,
        };
        const iter = switch (iter_outcome) {
            .value, .yielded => |v| v,
            .thrown => return error.NativeThrew,
        };
        const iter_obj = heap_mod.valueAsPlainObject(iter) orelse return throwTypeError(realm, "Array.from: @@iterator did not return an iterator object");
        const next_v = try getPropertyChain(realm, iter_obj, "next");
        const next_fn = heap_mod.valueAsFunction(next_v) orelse return throwTypeError(realm, "Array.from: iterator missing callable 'next'");

        var k: i64 = 0;
        const max_iter: usize = 1 << 24;
        var step: usize = 0;
        while (step < max_iter) : (step += 1) {
            const result_outcome = interpreter.callJSFunction(realm.allocator, realm, next_fn, iter, &.{}) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return error.NativeThrew,
            };
            const result = switch (result_outcome) {
                .value, .yielded => |v| v,
                .thrown => return error.NativeThrew,
            };
            const result_obj = heap_mod.valueAsPlainObject(result) orelse return throwTypeError(realm, "Array.from: iterator next() did not return an object");
            // §7.4.7 IteratorComplete / IteratorValue go through
            // ordinary [[Get]] — accessor descriptors on `done` /
            // `value` (poisoned-iterator fixtures) must invoke the
            // getter and propagate any throw. Plain `obj.get` is
            // accessor-blind and would silently keep iterating.
            if (intrinsics.toBoolean(try getPropertyChain(realm, result_obj, "done"))) break;
            const raw_v = try getPropertyChain(realm, result_obj, "value");
            const elem: Value = blk: {
                if (mapfn) |mf| {
                    const cb_args = [_]Value{ raw_v, numberFromI64(k) };
                    const outcome = interpreter.callJSFunction(realm.allocator, realm, mf, this_arg, &cb_args) catch |err| switch (err) {
                        error.OutOfMemory => return error.OutOfMemory,
                        else => return error.NativeThrew,
                    };
                    switch (outcome) {
                        .value, .yielded => |v| break :blk v,
                        .thrown => return error.NativeThrew,
                    }
                } else break :blk raw_v;
            };
            var ibuf: [24]u8 = undefined;
            const islice = std.fmt.bufPrint(&ibuf, "{d}", .{k}) catch unreachable;
            const idx_owned = realm.heap.allocateString(islice) catch return error.OutOfMemory;
            out.set(realm.allocator, idx_owned.bytes, elem) catch return error.OutOfMemory;
            k += 1;
        }
        setLength(realm, out, k) catch return error.OutOfMemory;
        return heap_mod.taggedObject(out);
    }

    // Array-like fallback (`length` + indexed get).
    const len = try clampArrayLength(lengthOfArray(src));
    var i: i64 = 0;
    while (i < len) : (i += 1) {
        var ibuf: [24]u8 = undefined;
        const islice = std.fmt.bufPrint(&ibuf, "{d}", .{i}) catch unreachable;
        const raw_v = src.get(islice);
        const elem: Value = blk: {
            if (mapfn) |mf| {
                const cb_args = [_]Value{ raw_v, numberFromI64(i) };

                const outcome = interpreter.callJSFunction(realm.allocator, realm, mf, this_arg, &cb_args) catch return error.NativeThrew;
                switch (outcome) {
                    .value, .yielded => |v| break :blk v,
                    .thrown => return error.NativeThrew,
                }
            } else break :blk raw_v;
        };
        const idx_owned = realm.heap.allocateString(islice) catch return error.OutOfMemory;
        out.set(realm.allocator, idx_owned.bytes, elem) catch return error.OutOfMemory;
    }
    setLength(realm, out, len) catch return error.OutOfMemory;
    return heap_mod.taggedObject(out);
}

fn arrayAt(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const obj = try toObjectThis(realm, this_value);
    const len = try clampArrayLength(try toLengthOf(realm, obj));
    var idx = if (args.len > 0) toInt(args[0]) else 0;
    if (idx < 0) idx += len;
    if (idx < 0 or idx >= len) return Value.undefined_;
    var ibuf: [24]u8 = undefined;
    const islice = std.fmt.bufPrint(&ibuf, "{d}", .{idx}) catch unreachable;
    return try getPropertyChain(realm, obj, islice);
}

fn arrayFill(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const obj = objectFromThis(this_value) orelse return error.NativeThrew;
    const value = argOr(args, 0, Value.undefined_);
    const len = try clampArrayLength(lengthOfArray(obj));
    var start: i64 = if (args.len > 1) toInt(args[1]) else 0;
    var end: i64 = if (args.len > 2 and !args[2].isUndefined()) toInt(args[2]) else len;
    if (start < 0) start = @max(len + start, 0);
    if (end < 0) end = @max(len + end, 0);
    start = @min(start, len);
    end = @min(end, len);
    var i = start;
    while (i < end) : (i += 1) {
        var ibuf: [24]u8 = undefined;
        const islice = std.fmt.bufPrint(&ibuf, "{d}", .{i}) catch unreachable;
        const owned = realm.heap.allocateString(islice) catch return error.OutOfMemory;
        obj.set(realm.allocator, owned.bytes, value) catch return error.OutOfMemory;
    }
    return this_value;
}

fn arrayLastIndexOf(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const obj = try toObjectThis(realm, this_value);
    const target = argOr(args, 0, Value.undefined_);
    const len = try clampArrayLength(try toLengthOf(realm, obj));
    if (len == 0) return Value.fromInt32(-1);
    var i: i64 = len - 1;
    while (i >= 0) : (i -= 1) {
        var ibuf: [24]u8 = undefined;
        const islice = std.fmt.bufPrint(&ibuf, "{d}", .{i}) catch unreachable;
        if (!obj.hasProperty(islice)) continue;
        const v = try getPropertyChain(realm, obj, islice);
        if (strictEqualsLite(v, target)) return numberFromI64(i);
    }
    return Value.fromInt32(-1);
}

fn arrayFindLast(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const obj = try toObjectThis(realm, this_value);
    const callback = heap_mod.valueAsFunction(argOr(args, 0, Value.undefined_)) orelse return throwTypeError(realm, "Array.prototype.findLast callback must be a function");
    const this_arg = argOr(args, 1, Value.undefined_);
    const len = try clampArrayLength(try toLengthOf(realm, obj));
    var i: i64 = len - 1;
    while (i >= 0) : (i -= 1) {
        var ibuf: [24]u8 = undefined;
        const islice = std.fmt.bufPrint(&ibuf, "{d}", .{i}) catch unreachable;
        const elem = try getPropertyChain(realm, obj, islice);
        const v = try invokeCallback(realm, callback, this_arg, elem, i, obj);
        if (toBoolean(v)) return elem;
    }
    return Value.undefined_;
}

fn arrayFindLastIndex(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const obj = try toObjectThis(realm, this_value);
    const callback = heap_mod.valueAsFunction(argOr(args, 0, Value.undefined_)) orelse return error.NativeThrew;
    const this_arg = argOr(args, 1, Value.undefined_);
    const len = try clampArrayLength(lengthOfArray(obj));
    var i: i64 = len - 1;
    while (i >= 0) : (i -= 1) {
        var ibuf: [24]u8 = undefined;
        const islice = std.fmt.bufPrint(&ibuf, "{d}", .{i}) catch unreachable;
        const elem = obj.get(islice);
        const v = try invokeCallback(realm, callback, this_arg, elem, i, obj);
        if (toBoolean(v)) return numberFromI64(i);
    }
    return Value.fromInt32(-1);
}

fn arrayReduceRight(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const obj = try toObjectThis(realm, this_value);
    const callback = heap_mod.valueAsFunction(argOr(args, 0, Value.undefined_)) orelse return error.NativeThrew;
    const len = try clampArrayLength(lengthOfArray(obj));
    var acc: Value = Value.undefined_;
    var have_acc = args.len >= 2;
    if (have_acc) acc = args[1];

    var i: i64 = len - 1;
    if (!have_acc) {
        while (i >= 0) : (i -= 1) {
            var ibuf: [24]u8 = undefined;
            const islice = std.fmt.bufPrint(&ibuf, "{d}", .{i}) catch unreachable;
            if (obj.hasOwn(islice)) {
                acc = obj.get(islice);
                have_acc = true;
                i -= 1;
                break;
            }
        }
        if (!have_acc) return error.NativeThrew;
    }

    while (i >= 0) : (i -= 1) {
        var ibuf: [24]u8 = undefined;
        const islice = std.fmt.bufPrint(&ibuf, "{d}", .{i}) catch unreachable;
        if (!obj.hasOwn(islice)) continue;
        const elem = obj.get(islice);

        const cb_args = [_]Value{ acc, elem, numberFromI64(i), heap_mod.taggedObject(obj) };
        const outcome = interpreter.callJSFunction(realm.allocator, realm, callback, Value.undefined_, &cb_args) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.NativeThrew,
        };
        switch (outcome) {
            .value, .yielded => |v| acc = v,
            .thrown => return error.NativeThrew,
        }
    }
    return acc;
}

fn arrayFlat(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const obj = try toObjectThis(realm, this_value);
    const depth_v = argOr(args, 0, Value.fromInt32(1));
    // Infinity / very-large depth → effectively-unbounded; we cap
    // with a recursion sentinel inside `flattenInto`.
    const depth: i64 = if (depth_v.isInt32()) depth_v.asInt32() else if (depth_v.isDouble()) blk: {
        const d = depth_v.asDouble();
        if (std.math.isNan(d) or d < 0) break :blk 0;
        if (std.math.isInf(d)) break :blk std.math.maxInt(i32);
        break :blk @intFromFloat(@trunc(d));
    } else 1;
    const out = realm.heap.allocateObject() catch return error.OutOfMemory;
    out.prototype = realm.intrinsics.array_prototype;
    var write_idx: i64 = 0;
    try flattenInto(realm, obj, depth, out, &write_idx);
    setLength(realm, out, write_idx) catch return error.OutOfMemory;
    return heap_mod.taggedObject(out);
}

fn flattenInto(realm: *Realm, source: *JSObject, depth: i64, target: *JSObject, write_idx: *i64) NativeError!void {
    const len = try clampArrayLength(lengthOfArray(source));
    var i: i64 = 0;
    while (i < len) : (i += 1) {
        var ibuf: [24]u8 = undefined;
        const islice = std.fmt.bufPrint(&ibuf, "{d}", .{i}) catch unreachable;
        if (!source.hasOwn(islice)) continue;
        const elem = source.get(islice);
        const should_flatten = depth > 0 and isArrayLike(elem);
        if (should_flatten) {
            const inner = heap_mod.valueAsPlainObject(elem).?;
            try flattenInto(realm, inner, depth - 1, target, write_idx);
        } else {
            var wbuf: [24]u8 = undefined;
            const wslice = std.fmt.bufPrint(&wbuf, "{d}", .{write_idx.*}) catch unreachable;
            const owned = realm.heap.allocateString(wslice) catch return error.OutOfMemory;
            target.set(realm.allocator, owned.bytes, elem) catch return error.OutOfMemory;
            write_idx.* += 1;
        }
    }
}

pub fn isArrayLike(v: Value) bool {
    const obj = heap_mod.valueAsPlainObject(v) orelse return false;
    // Heuristic: prototype contains "constructor" === Array or
    // walks to array_prototype. Same shape as arrayIsArray.
    var c: ?*JSObject = obj.prototype;
    while (c) |x| : (c = x.prototype) {
        const ctor = x.get("constructor");
        if (heap_mod.valueAsFunction(ctor)) |fn_obj| {
            if (fn_obj.name) |nm| {
                if (std.mem.eql(u8, nm, "Array")) return true;
            }
        }
    }
    return false;
}

fn arrayFlatMap(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const obj = try toObjectThis(realm, this_value);
    const callback = heap_mod.valueAsFunction(argOr(args, 0, Value.undefined_)) orelse return error.NativeThrew;
    const this_arg = argOr(args, 1, Value.undefined_);
    const len = try clampArrayLength(lengthOfArray(obj));

    const out = realm.heap.allocateObject() catch return error.OutOfMemory;
    out.prototype = realm.intrinsics.array_prototype;
    var write_idx: i64 = 0;
    var i: i64 = 0;
    while (i < len) : (i += 1) {
        var ibuf: [24]u8 = undefined;
        const islice = std.fmt.bufPrint(&ibuf, "{d}", .{i}) catch unreachable;
        if (!obj.hasOwn(islice)) continue;
        const elem = obj.get(islice);
        const mapped = try invokeCallback(realm, callback, this_arg, elem, i, obj);
        if (isArrayLike(mapped)) {
            const inner = heap_mod.valueAsPlainObject(mapped).?;
            const inner_len = try clampArrayLength(lengthOfArray(inner));
            var j: i64 = 0;
            while (j < inner_len) : (j += 1) {
                var jbuf: [24]u8 = undefined;
                const jslice = std.fmt.bufPrint(&jbuf, "{d}", .{j}) catch unreachable;
                const v = inner.get(jslice);
                var wbuf: [24]u8 = undefined;
                const wslice = std.fmt.bufPrint(&wbuf, "{d}", .{write_idx}) catch unreachable;
                const owned = realm.heap.allocateString(wslice) catch return error.OutOfMemory;
                out.set(realm.allocator, owned.bytes, v) catch return error.OutOfMemory;
                write_idx += 1;
            }
        } else {
            var wbuf: [24]u8 = undefined;
            const wslice = std.fmt.bufPrint(&wbuf, "{d}", .{write_idx}) catch unreachable;
            const owned = realm.heap.allocateString(wslice) catch return error.OutOfMemory;
            out.set(realm.allocator, owned.bytes, mapped) catch return error.OutOfMemory;
            write_idx += 1;
        }
    }
    setLength(realm, out, write_idx) catch return error.OutOfMemory;
    return heap_mod.taggedObject(out);
}

fn arraySplice(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const obj = objectFromThis(this_value) orelse return error.NativeThrew;
    const len = try clampArrayLength(lengthOfArray(obj));
    var start: i64 = if (args.len > 0) toInt(args[0]) else 0;
    if (start < 0) start = @max(len + start, 0);
    start = @min(start, len);
    var delete_count: i64 = if (args.len < 2)
        len - start
    else
        toInt(args[1]);
    if (delete_count < 0) delete_count = 0;
    if (delete_count > len - start) delete_count = len - start;

    // Removed array.
    const removed = realm.heap.allocateObject() catch return error.OutOfMemory;
    removed.prototype = realm.intrinsics.array_prototype;
    var i: i64 = 0;
    while (i < delete_count) : (i += 1) {
        var rbuf: [24]u8 = undefined;
        const rslice = std.fmt.bufPrint(&rbuf, "{d}", .{start + i}) catch unreachable;
        const v = obj.get(rslice);
        var wbuf: [24]u8 = undefined;
        const wslice = std.fmt.bufPrint(&wbuf, "{d}", .{i}) catch unreachable;
        const owned = realm.heap.allocateString(wslice) catch return error.OutOfMemory;
        removed.set(realm.allocator, owned.bytes, v) catch return error.OutOfMemory;
    }
    setLength(realm, removed, delete_count) catch return error.OutOfMemory;

    // Insert items.
    const insert_count: i64 = if (args.len > 2) @as(i64, @intCast(args.len - 2)) else 0;
    const new_len = len - delete_count + insert_count;

    if (insert_count < delete_count) {
        // Shift left.
        var k: i64 = start + delete_count;
        while (k < len) : (k += 1) {
            var sb: [24]u8 = undefined;
            var db: [24]u8 = undefined;
            const sslice = std.fmt.bufPrint(&sb, "{d}", .{k}) catch unreachable;
            const dslice = std.fmt.bufPrint(&db, "{d}", .{k - delete_count + insert_count}) catch unreachable;
            const v = obj.get(sslice);
            const owned = realm.heap.allocateString(dslice) catch return error.OutOfMemory;
            obj.set(realm.allocator, owned.bytes, v) catch return error.OutOfMemory;
        }
        // Trim.
        var trim: i64 = new_len;
        while (trim < len) : (trim += 1) {
            var tb: [24]u8 = undefined;
            const tslice = std.fmt.bufPrint(&tb, "{d}", .{trim}) catch unreachable;
            _ = obj.properties.swapRemove(tslice);
        }
    } else if (insert_count > delete_count) {
        // Shift right (from the end so we don't overwrite).
        var k: i64 = len - 1;
        while (k >= start + delete_count) : (k -= 1) {
            var sb: [24]u8 = undefined;
            var db: [24]u8 = undefined;
            const sslice = std.fmt.bufPrint(&sb, "{d}", .{k}) catch unreachable;
            const dslice = std.fmt.bufPrint(&db, "{d}", .{k - delete_count + insert_count}) catch unreachable;
            const v = obj.get(sslice);
            const owned = realm.heap.allocateString(dslice) catch return error.OutOfMemory;
            obj.set(realm.allocator, owned.bytes, v) catch return error.OutOfMemory;
        }
    }

    // Insert.
    var ins: i64 = 0;
    while (ins < insert_count) : (ins += 1) {
        var b: [24]u8 = undefined;
        const slc = std.fmt.bufPrint(&b, "{d}", .{start + ins}) catch unreachable;
        const owned = realm.heap.allocateString(slc) catch return error.OutOfMemory;
        obj.set(realm.allocator, owned.bytes, args[2 + @as(usize, @intCast(ins))]) catch return error.OutOfMemory;
    }

    setLength(realm, obj, new_len) catch return error.OutOfMemory;
    return heap_mod.taggedObject(removed);
}

fn arrayCopyWithin(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const obj = objectFromThis(this_value) orelse return error.NativeThrew;
    const len = try clampArrayLength(lengthOfArray(obj));
    var target: i64 = if (args.len > 0) toInt(args[0]) else 0;
    var start: i64 = if (args.len > 1) toInt(args[1]) else 0;
    var end: i64 = if (args.len > 2 and !args[2].isUndefined()) toInt(args[2]) else len;
    if (target < 0) target = @max(len + target, 0);
    if (start < 0) start = @max(len + start, 0);
    if (end < 0) end = @max(len + end, 0);
    target = @min(target, len);
    start = @min(start, len);
    end = @min(end, len);
    const count: i64 = @min(end - start, len - target);
    if (count <= 0) return this_value;

    // Direction matters when ranges overlap.
    if (start < target and target < start + count) {
        // Copy backwards.
        var k: i64 = count - 1;
        while (k >= 0) : (k -= 1) {
            var sb: [24]u8 = undefined;
            var db: [24]u8 = undefined;
            const sslice = std.fmt.bufPrint(&sb, "{d}", .{start + k}) catch unreachable;
            const dslice = std.fmt.bufPrint(&db, "{d}", .{target + k}) catch unreachable;
            const v = obj.get(sslice);
            obj.properties.put(realm.allocator, dslice, v) catch return error.OutOfMemory;
        }
    } else {
        var k: i64 = 0;
        while (k < count) : (k += 1) {
            var sb: [24]u8 = undefined;
            var db: [24]u8 = undefined;
            const sslice = std.fmt.bufPrint(&sb, "{d}", .{start + k}) catch unreachable;
            const dslice = std.fmt.bufPrint(&db, "{d}", .{target + k}) catch unreachable;
            const v = obj.get(sslice);
            obj.properties.put(realm.allocator, dslice, v) catch return error.OutOfMemory;
        }
    }
    return this_value;
}

fn arraySort(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const obj = objectFromThis(this_value) orelse return error.NativeThrew;
    const len = try clampArrayLength(lengthOfArray(obj));
    if (len <= 1) return this_value;

    // Materialise into a Zig slice, sort, write back. With a JS
    // comparator we need to invoke it via callJSFunction.
    const cmp_v = argOr(args, 0, Value.undefined_);
    const cmp_fn: ?*JSFunction = heap_mod.valueAsFunction(cmp_v);

    const buf = realm.allocator.alloc(Value, @intCast(len)) catch return error.OutOfMemory;
    defer realm.allocator.free(buf);
    var i: i64 = 0;
    while (i < len) : (i += 1) {
        var ibuf: [24]u8 = undefined;
        const islice = std.fmt.bufPrint(&ibuf, "{d}", .{i}) catch unreachable;
        buf[@intCast(i)] = obj.get(islice);
    }

    // Insertion sort — stable and adequate for our later floor
    // (test262 fixtures rarely exceed a few hundred elements). The
    // comparator may throw; we surface that via NativeThrew.
    var n: usize = 1;
    while (n < buf.len) : (n += 1) {
        const key = buf[n];
        var j: isize = @as(isize, @intCast(n)) - 1;
        while (j >= 0) : (j -= 1) {
            const should_swap = if (cmp_fn) |c| blk: {

                const cb_args = [_]Value{ buf[@intCast(j)], key };
                const outcome = interpreter.callJSFunction(realm.allocator, realm, c, Value.undefined_, &cb_args) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    else => return error.NativeThrew,
                };
                switch (outcome) {
                    .value, .yielded => |v| {
                        const num = coerceToNumber(v);
                        const d = if (num.isInt32()) @as(f64, @floatFromInt(num.asInt32())) else num.asDouble();
                        break :blk d > 0;
                    },
                    .thrown => return error.NativeThrew,
                }
            } else blk: {
                // Default comparator: ToString on both, lexical order.
                var ab: [64]u8 = undefined;
                var bb: [64]u8 = undefined;
                const a_s = computedKeyForSort(buf[@intCast(j)], &ab);
                const b_s = computedKeyForSort(key, &bb);
                break :blk std.mem.order(u8, a_s, b_s) == .gt;
            };
            if (!should_swap) break;
            buf[@intCast(j + 1)] = buf[@intCast(j)];
        }
        buf[@intCast(j + 1)] = key;
    }

    // Write back.
    var w: i64 = 0;
    while (w < len) : (w += 1) {
        var wbuf: [24]u8 = undefined;
        const wslice = std.fmt.bufPrint(&wbuf, "{d}", .{w}) catch unreachable;
        obj.properties.put(realm.allocator, wslice, buf[@intCast(w)]) catch return error.OutOfMemory;
    }
    return this_value;
}

fn computedKeyForSort(v: Value, scratch: *[64]u8) []const u8 {
    if (v.isString()) {
        const s: *JSString = @ptrCast(@alignCast(v.asString()));
        return s.bytes;
    }
    if (v.isInt32()) {
        return std.fmt.bufPrint(scratch, "{d}", .{v.asInt32()}) catch unreachable;
    }
    if (v.isDouble()) {
        const d = v.asDouble();
        if (std.math.isNan(d)) return "NaN";
        if (std.math.isInf(d)) return if (d > 0) "Infinity" else "-Infinity";
        const a = @abs(d);
        if (a != 0 and (a < 1e-6 or a >= 1e21)) {
            return std.fmt.bufPrint(scratch, "{e}", .{d}) catch unreachable;
        }
        return std.fmt.bufPrint(scratch, "{d}", .{d}) catch unreachable;
    }
    if (v.isUndefined()) return "undefined";
    if (v.isNull()) return "null";
    if (v.isBool()) return if (v.asBool()) "true" else "false";
    return "[object]";
}

// ── Array.prototype.{reverse, shift, unshift} ───────────────────────────────

fn arrayReverse(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = args;
    const obj = objectFromThis(this_value) orelse return error.NativeThrew;
    const len = try clampArrayLength(lengthOfArray(obj));
    var i: i64 = 0;
    const half = @divFloor(len, 2);
    while (i < half) : (i += 1) {
        var ibuf: [24]u8 = undefined;
        var jbuf: [24]u8 = undefined;
        const islice = std.fmt.bufPrint(&ibuf, "{d}", .{i}) catch unreachable;
        const j = len - 1 - i;
        const jslice = std.fmt.bufPrint(&jbuf, "{d}", .{j}) catch unreachable;
        const a = obj.get(islice);
        const b = obj.get(jslice);
        const owned_i = realm.heap.allocateString(islice) catch return error.OutOfMemory;
        const owned_j = realm.heap.allocateString(jslice) catch return error.OutOfMemory;
        obj.set(realm.allocator, owned_i.bytes, b) catch return error.OutOfMemory;
        obj.set(realm.allocator, owned_j.bytes, a) catch return error.OutOfMemory;
    }
    return this_value;
}

fn arrayShift(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = args;
    const obj = objectFromThis(this_value) orelse return error.NativeThrew;
    const len = try clampArrayLength(lengthOfArray(obj));
    if (len == 0) {
        setLength(realm, obj, 0) catch return error.OutOfMemory;
        return Value.undefined_;
    }
    const head = obj.get("0");
    var i: i64 = 1;
    while (i < len) : (i += 1) {
        var ibuf: [24]u8 = undefined;
        var pbuf: [24]u8 = undefined;
        const islice = std.fmt.bufPrint(&ibuf, "{d}", .{i}) catch unreachable;
        const pslice = std.fmt.bufPrint(&pbuf, "{d}", .{i - 1}) catch unreachable;
        const v = obj.get(islice);
        const owned = realm.heap.allocateString(pslice) catch return error.OutOfMemory;
        obj.set(realm.allocator, owned.bytes, v) catch return error.OutOfMemory;
    }
    {
        var lbuf: [24]u8 = undefined;
        const lslice = std.fmt.bufPrint(&lbuf, "{d}", .{len - 1}) catch unreachable;
        _ = obj.properties.swapRemove(lslice);
    }
    setLength(realm, obj, len - 1) catch return error.OutOfMemory;
    return head;
}

fn arrayUnshift(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const obj = objectFromThis(this_value) orelse return error.NativeThrew;
    const len = try clampArrayLength(lengthOfArray(obj));
    const argc: i64 = @intCast(args.len);
    // Shift existing elements right by argc.
    var i: i64 = len - 1;
    while (i >= 0) : (i -= 1) {
        var sb: [24]u8 = undefined;
        var db: [24]u8 = undefined;
        const sslice = std.fmt.bufPrint(&sb, "{d}", .{i}) catch unreachable;
        const dslice = std.fmt.bufPrint(&db, "{d}", .{i + argc}) catch unreachable;
        const v = obj.get(sslice);
        const owned = realm.heap.allocateString(dslice) catch return error.OutOfMemory;
        obj.set(realm.allocator, owned.bytes, v) catch return error.OutOfMemory;
    }
    // Insert new args at the start.
    for (args, 0..) |a, idx| {
        var b: [24]u8 = undefined;
        const slc = std.fmt.bufPrint(&b, "{d}", .{idx}) catch unreachable;
        const owned = realm.heap.allocateString(slc) catch return error.OutOfMemory;
        obj.set(realm.allocator, owned.bytes, a) catch return error.OutOfMemory;
    }
    const new_len = len + argc;
    setLength(realm, obj, new_len) catch return error.OutOfMemory;
    return numberFromI64(new_len);
}

// ── Array.prototype callback-driven methods ────────────────────────────────
//
// These all share the same shape: walk own indices [0, length),
// for each element invoke `callback(element, index, array)` with
// the supplied `thisArg`, and combine the results per the
// method's contract. They use `interpreter.callJSFunction` to
// recurse into JS — the reentrant entry point opens its own
// frame stack so the outer dispatch loop is unaffected.

pub fn invokeCallback(
    realm: *Realm,
    callback: *JSFunction,
    this_arg: Value,
    elem: Value,
    index: i64,
    array: *JSObject,
) NativeError!Value {

    const cb_args = [_]Value{ elem, numberFromI64(index), heap_mod.taggedObject(array) };
    const outcome = interpreter.callJSFunction(realm.allocator, realm, callback, this_arg, &cb_args) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.NativeThrew,
    };
    switch (outcome) {
        .value, .yielded => |v| return v,
        .thrown => return error.NativeThrew,
    }
}

fn arrayForEach(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const obj = try toObjectThis(realm, this_value);
    const callback = heap_mod.valueAsFunction(argOr(args, 0, Value.undefined_)) orelse return throwTypeError(realm, "Array.prototype.forEach callback must be a function");
    const this_arg = argOr(args, 1, Value.undefined_);
    const len = try clampArrayLength(try toLengthOf(realm, obj));
    var i: i64 = 0;
    while (i < len) : (i += 1) {
        var ibuf: [24]u8 = undefined;
        const islice = std.fmt.bufPrint(&ibuf, "{d}", .{i}) catch unreachable;
        if (!obj.hasProperty(islice)) continue;
        const elem = try getPropertyChain(realm, obj, islice);
        _ = try invokeCallback(realm, callback, this_arg, elem, i, obj);
    }
    return Value.undefined_;
}

fn arrayMap(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const obj = try toObjectThis(realm, this_value);
    const callback = heap_mod.valueAsFunction(argOr(args, 0, Value.undefined_)) orelse return throwTypeError(realm, "Array.prototype.map callback must be a function");
    const this_arg = argOr(args, 1, Value.undefined_);
    const len = try clampArrayLength(try toLengthOf(realm, obj));

    const out = realm.heap.allocateObject() catch return error.OutOfMemory;
    out.prototype = realm.intrinsics.array_prototype;
    var i: i64 = 0;
    while (i < len) : (i += 1) {
        var ibuf: [24]u8 = undefined;
        const islice = std.fmt.bufPrint(&ibuf, "{d}", .{i}) catch unreachable;
        if (!obj.hasProperty(islice)) continue;
        const elem = try getPropertyChain(realm, obj, islice);
        const v = try invokeCallback(realm, callback, this_arg, elem, i, obj);
        const owned = realm.heap.allocateString(islice) catch return error.OutOfMemory;
        out.set(realm.allocator, owned.bytes, v) catch return error.OutOfMemory;
    }
    setLength(realm, out, len) catch return error.OutOfMemory;
    return heap_mod.taggedObject(out);
}

fn arrayFilter(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const obj = try toObjectThis(realm, this_value);
    const callback = heap_mod.valueAsFunction(argOr(args, 0, Value.undefined_)) orelse return throwTypeError(realm, "Array.prototype.filter callback must be a function");
    const this_arg = argOr(args, 1, Value.undefined_);
    const len = try clampArrayLength(try toLengthOf(realm, obj));

    const out = realm.heap.allocateObject() catch return error.OutOfMemory;
    out.prototype = realm.intrinsics.array_prototype;
    var i: i64 = 0;
    var write_idx: i64 = 0;
    while (i < len) : (i += 1) {
        var ibuf: [24]u8 = undefined;
        const islice = std.fmt.bufPrint(&ibuf, "{d}", .{i}) catch unreachable;
        if (!obj.hasProperty(islice)) continue;
        const elem = try getPropertyChain(realm, obj, islice);
        const keep = try invokeCallback(realm, callback, this_arg, elem, i, obj);
        if (toBoolean(keep)) {
            var wbuf: [24]u8 = undefined;
            const wslice = std.fmt.bufPrint(&wbuf, "{d}", .{write_idx}) catch unreachable;
            const owned = realm.heap.allocateString(wslice) catch return error.OutOfMemory;
            out.set(realm.allocator, owned.bytes, elem) catch return error.OutOfMemory;
            write_idx += 1;
        }
    }
    setLength(realm, out, write_idx) catch return error.OutOfMemory;
    return heap_mod.taggedObject(out);
}

fn arrayEvery(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const obj = try toObjectThis(realm, this_value);
    const callback = heap_mod.valueAsFunction(argOr(args, 0, Value.undefined_)) orelse return throwTypeError(realm, "Array.prototype.every callback must be a function");
    const this_arg = argOr(args, 1, Value.undefined_);
    const len = try clampArrayLength(try toLengthOf(realm, obj));
    var i: i64 = 0;
    while (i < len) : (i += 1) {
        var ibuf: [24]u8 = undefined;
        const islice = std.fmt.bufPrint(&ibuf, "{d}", .{i}) catch unreachable;
        if (!obj.hasProperty(islice)) continue;
        const elem = try getPropertyChain(realm, obj, islice);
        const v = try invokeCallback(realm, callback, this_arg, elem, i, obj);
        if (!toBoolean(v)) return Value.false_;
    }
    return Value.true_;
}

fn arraySome(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const obj = try toObjectThis(realm, this_value);
    const callback = heap_mod.valueAsFunction(argOr(args, 0, Value.undefined_)) orelse return throwTypeError(realm, "Array.prototype.some callback must be a function");
    const this_arg = argOr(args, 1, Value.undefined_);
    const len = try clampArrayLength(try toLengthOf(realm, obj));
    var i: i64 = 0;
    while (i < len) : (i += 1) {
        var ibuf: [24]u8 = undefined;
        const islice = std.fmt.bufPrint(&ibuf, "{d}", .{i}) catch unreachable;
        if (!obj.hasProperty(islice)) continue;
        const elem = try getPropertyChain(realm, obj, islice);
        const v = try invokeCallback(realm, callback, this_arg, elem, i, obj);
        if (toBoolean(v)) return Value.true_;
    }
    return Value.false_;
}

fn arrayFind(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const obj = try toObjectThis(realm, this_value);
    const callback = heap_mod.valueAsFunction(argOr(args, 0, Value.undefined_)) orelse return throwTypeError(realm, "Array.prototype.find callback must be a function");
    const this_arg = argOr(args, 1, Value.undefined_);
    const len = try clampArrayLength(try toLengthOf(realm, obj));
    var i: i64 = 0;
    while (i < len) : (i += 1) {
        var ibuf: [24]u8 = undefined;
        const islice = std.fmt.bufPrint(&ibuf, "{d}", .{i}) catch unreachable;
        const elem = try getPropertyChain(realm, obj, islice);
        const v = try invokeCallback(realm, callback, this_arg, elem, i, obj);
        if (toBoolean(v)) return elem;
    }
    return Value.undefined_;
}

fn arrayFindIndex(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const obj = try toObjectThis(realm, this_value);
    const callback = heap_mod.valueAsFunction(argOr(args, 0, Value.undefined_)) orelse return throwTypeError(realm, "Array.prototype.findIndex callback must be a function");
    const this_arg = argOr(args, 1, Value.undefined_);
    const len = try clampArrayLength(try toLengthOf(realm, obj));
    var i: i64 = 0;
    while (i < len) : (i += 1) {
        var ibuf: [24]u8 = undefined;
        const islice = std.fmt.bufPrint(&ibuf, "{d}", .{i}) catch unreachable;
        const elem = try getPropertyChain(realm, obj, islice);
        const v = try invokeCallback(realm, callback, this_arg, elem, i, obj);
        if (toBoolean(v)) return numberFromI64(i);
    }
    return Value.fromInt32(-1);
}

fn arrayReduce(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const obj = try toObjectThis(realm, this_value);
    const callback = heap_mod.valueAsFunction(argOr(args, 0, Value.undefined_)) orelse return throwTypeError(realm, "Array.prototype.reduce callback must be a function");
    const len = try clampArrayLength(try toLengthOf(realm, obj));
    var acc: Value = Value.undefined_;
    var have_acc = args.len >= 2;
    if (have_acc) acc = args[1];

    var i: i64 = 0;
    if (!have_acc) {
        // §23.1.3.24 step 5 — find the first present index.
        while (i < len) : (i += 1) {
            var ibuf: [24]u8 = undefined;
            const islice = std.fmt.bufPrint(&ibuf, "{d}", .{i}) catch unreachable;
            if (obj.hasProperty(islice)) {
                acc = try getPropertyChain(realm, obj, islice);
                have_acc = true;
                i += 1;
                break;
            }
        }
        if (!have_acc) return throwTypeError(realm, "Reduce of empty array with no initial value");
    }

    while (i < len) : (i += 1) {
        var ibuf: [24]u8 = undefined;
        const islice = std.fmt.bufPrint(&ibuf, "{d}", .{i}) catch unreachable;
        if (!obj.hasProperty(islice)) continue;
        const elem = try getPropertyChain(realm, obj, islice);

        const cb_args = [_]Value{ acc, elem, numberFromI64(i), heap_mod.taggedObject(obj) };
        const outcome = interpreter.callJSFunction(realm.allocator, realm, callback, Value.undefined_, &cb_args) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.NativeThrew,
        };
        switch (outcome) {
            .value, .yielded => |v| acc = v,
            .thrown => |ex| {
                realm.pending_exception = ex;
                return error.NativeThrew;
            },
        }
    }
    return acc;
}

/// Local ToBoolean (§7.1.2) helper for callback-driven methods —
/// non-empty-string truthiness needed for filter / every / some.
pub fn toBoolean(v: Value) bool {
    if (v.isString()) {
        const s: *JSString = @ptrCast(@alignCast(v.asString()));
        return s.bytes.len > 0;
    }
    if (v.isInt32()) return v.asInt32() != 0;
    if (v.isDouble()) {
        const d = v.asDouble();
        return d != 0 and !std.math.isNan(d);
    }
    if (v.isBool()) return v.asBool();
    if (v.isNull() or v.isUndefined()) return false;
    return true; // objects / functions are truthy
}

