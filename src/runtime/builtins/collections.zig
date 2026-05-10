//! §24.1 Map / §24.2 Set / §24.3 WeakMap / §24.4 WeakSet —
//! extracted from `intrinsics.zig`. The four collection types
//! share `[[MapData]]` / `[[SetData]]` storage (in
//! `runtime/object.zig`) and several helpers; co-locating
//! them avoids cross-file privacy thrash.
//!
//! Cynic's WeakMap / WeakSet are strong-ref impls with
//! identical observable behaviour to the spec — GC-weakness
//! is later.

const std = @import("std");

const Realm = @import("../realm.zig").Realm;
const Value = @import("../value.zig").Value;
const JSString = @import("../string.zig").JSString;
const JSObject = @import("../object.zig").JSObject;
const JSFunction = @import("../function.zig").JSFunction;
const NativeError = @import("../function.zig").NativeError;
const NativeFn = @import("../function.zig").NativeFn;
const heap_mod = @import("../heap.zig");
const ObjMod = @import("../object.zig");
const intrinsics = @import("../intrinsics.zig");
const interpreter = @import("../interpreter.zig");

const installConstructor = intrinsics.installConstructor;
const installNativeGetter = intrinsics.installNativeGetter;
const installNativeMethodOnProto = intrinsics.installNativeMethodOnProto;
const argOr = intrinsics.argOr;
const numberFromI64 = intrinsics.numberFromI64;
const throwTypeError = intrinsics.throwTypeError;
const sameValueZero = intrinsics.sameValueZero;
const lengthOfArray = intrinsics.lengthOfArray;
const callJSFunction = interpreter.callJSFunction;
const readTypedElement = intrinsics.readTypedElement;

// ── §24.1 Map ───────────────────────────────────────────────────────────────

pub fn installMap(realm: *Realm) !void {
    _ = ObjMod;
    const r = try installConstructor(realm, .{
        .name = "Map", .ctor = mapConstructor, .arity = 1,
        .to_string_tag = "Map",
    });
    const ctor = r.ctor;
    const proto = r.proto;

    try intrinsics.installNativeMethod(realm, ctor, "groupBy", mapGroupBy, 2);

    try installNativeMethodOnProto(realm, proto, "set", mapSet, 2);
    try installNativeMethodOnProto(realm, proto, "get", mapGet, 1);
    try installNativeMethodOnProto(realm, proto, "has", mapHas, 1);
    try installNativeMethodOnProto(realm, proto, "delete", mapDelete, 1);
    try installNativeMethodOnProto(realm, proto, "clear", mapClear, 0);
    try installNativeMethodOnProto(realm, proto, "forEach", mapForEach, 1);
    // §24.1.3 Map iterators — `entries()` is the default
    // (`@@iterator` aliases it), `keys()` and `values()` produce
    // single-element views. Each returns an iterator object
    // backed by the map's `[[MapData]]` and an index.
    try installNativeMethodOnProto(realm, proto, "entries", mapEntries, 0);
    try installNativeMethodOnProto(realm, proto, "keys", mapKeys, 0);
    try installNativeMethodOnProto(realm, proto, "values", mapValues, 0);
    try installNativeMethodOnProto(realm, proto, "@@iterator", mapEntries, 0);

    // `.size` is an accessor in spec; we expose as a getter so
    // `m.size` evaluates to the live count.
    try installNativeGetter(realm, proto, "size", mapSizeGetter);

    // §24.1.5.2 %MapIteratorPrototype% — one shared prototype per
    // realm; every Map-iterator instance chains to it. Carries
    // `next`, `@@iterator` (returns self), and the well-known
    // toStringTag.
    const it_proto = try realm.heap.allocateObject();
    it_proto.prototype = realm.intrinsics.object_prototype;
    try installNativeMethodOnProto(realm, it_proto, "next", mapIterNext, 0);
    try installNativeMethodOnProto(realm, it_proto, "@@iterator", iteratorReturnsSelf, 0);
    try intrinsics.installToStringTag(realm, it_proto, "Map Iterator");
    realm.intrinsics.map_iterator_prototype = it_proto;
}

/// Iterator factory for Map. `kind` selects entries / keys /
/// values. The returned object has a `next` method whose
/// `this`-borne state is `__cynic_map__` (the source map) and
/// `__cynic_idx__` (next entry index). later: switch to a
/// real iterator-prototype chain so users can swap in custom
/// `[Symbol.iterator]` implementations.
/// §24.1.5.1 CreateMapIterator — allocate an iterator instance
/// with `[[Map]]`, `[[MapNextIndex]]`, and `[[MapIterationKind]]`
/// internal slots, all chained to %MapIteratorPrototype% so
/// `next` / `@@iterator` / `@@toStringTag` come from the shared
/// proto (§24.1.5.2). The `__cynic_map__` own slot doubles as
/// the brand check inside `next` (its presence == "has the
/// internal slots of a Map Iterator Instance").
fn makeMapIterator(realm: *Realm, src: Value, kind: enum { entries, keys, values }) !Value {
    const it = try realm.heap.allocateObject();
    it.prototype = realm.intrinsics.map_iterator_prototype orelse realm.intrinsics.object_prototype;
    try it.set(realm.allocator, "__cynic_map__", src);
    try it.set(realm.allocator, "__cynic_idx__", Value.fromInt32(0));
    const kind_tag: i32 = switch (kind) {
        .entries => 0,
        .keys => 1,
        .values => 2,
    };
    try it.set(realm.allocator, "__cynic_kind__", Value.fromInt32(kind_tag));
    return heap_mod.taggedObject(it);
}

fn mapEntries(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = args;
    if (mapDataOf(this_value) == null) return throwTypeError(realm, "Map iterator on non-Map");
    return makeMapIterator(realm, this_value, .entries) catch return error.OutOfMemory;
}
fn mapKeys(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = args;
    if (mapDataOf(this_value) == null) return throwTypeError(realm, "Map iterator on non-Map");
    return makeMapIterator(realm, this_value, .keys) catch return error.OutOfMemory;
}
fn mapValues(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = args;
    if (mapDataOf(this_value) == null) return throwTypeError(realm, "Map iterator on non-Map");
    return makeMapIterator(realm, this_value, .values) catch return error.OutOfMemory;
}

fn iteratorReturnsSelf(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = realm;
    _ = args;
    return this_value;
}

/// Array.prototype iterator factory. Reads the `length` of the
/// receiver and walks numeric indices; works for plain arrays,
/// `arguments`, and any array-like object. `kind` selects which
/// of `entries` / `keys` / `values` to produce.
fn makeArrayLikeIterator(realm: *Realm, src: Value, kind: enum { entries, keys, values }) !Value {
    const it = try realm.heap.allocateObject();
    it.prototype = realm.intrinsics.object_prototype;
    try it.set(realm.allocator, "__cynic_iter_target__", src);
    try it.set(realm.allocator, "__cynic_iter_idx__", Value.fromInt32(0));
    const native: @import("../function.zig").NativeFn = switch (kind) {
        .entries => arrayLikeIterEntriesNext,
        .keys => arrayLikeIterKeysNext,
        .values => arrayLikeIterValuesNext,
    };
    const next_fn = try realm.heap.allocateFunctionNative(native, 0, "next");
    next_fn.proto = realm.intrinsics.function_prototype;
    try it.set(realm.allocator, "next", heap_mod.taggedFunction(next_fn));
    const self_fn = try realm.heap.allocateFunctionNative(iteratorReturnsSelf, 0, "[Symbol.iterator]");
    self_fn.proto = realm.intrinsics.function_prototype;
    try it.set(realm.allocator, "@@iterator", heap_mod.taggedFunction(self_fn));
    return heap_mod.taggedObject(it);
}

pub fn arrayLikeValuesMethod(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = args;
    return makeArrayLikeIterator(realm, this_value, .values) catch return error.OutOfMemory;
}
pub fn arrayLikeKeysMethod(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = args;
    return makeArrayLikeIterator(realm, this_value, .keys) catch return error.OutOfMemory;
}
pub fn arrayLikeEntriesMethod(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = args;
    return makeArrayLikeIterator(realm, this_value, .entries) catch return error.OutOfMemory;
}

pub fn stringIteratorMethod(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = args;
    return makeArrayLikeIterator(realm, this_value, .values) catch return error.OutOfMemory;
}

fn arrayLikeIterStep(realm: *Realm, this_value: Value) ?struct { idx: i32, value: Value, length: i64 } {
    const it = heap_mod.valueAsPlainObject(this_value) orelse return null;
    const target = it.get("__cynic_iter_target__");
    const idx_v = it.get("__cynic_iter_idx__");
    const idx: i32 = if (idx_v.isInt32()) idx_v.asInt32() else 0;

    var length: i64 = 0;
    var elem: Value = Value.undefined_;
    if (heap_mod.valueAsPlainObject(target)) |obj| {
        // TypedArrays expose `length` via an accessor on
        // %TypedArray%.prototype and indexed access via
        // typed-view dispatch; iterate them directly off the
        // typed_view to avoid the per-step accessor call.
        if (obj.typed_view) |tv| {
            length = @intCast(tv.length);
            if (idx >= 0 and @as(usize, @intCast(idx)) < tv.length) {
                if (tv.viewed.array_buffer) |buf| {
                    const elem_size = tv.kind.elementSize();
                    elem = readTypedElement(realm, buf, tv.kind, tv.byte_offset + @as(usize, @intCast(idx)) * elem_size);
                }
            }
        } else {
            const len_v = obj.get("length");
            if (len_v.isInt32()) length = len_v.asInt32() else if (len_v.isDouble()) length = @intFromFloat(len_v.asDouble());
            if (idx < length) {
                var ibuf: [16]u8 = undefined;
                const islice = std.fmt.bufPrint(&ibuf, "{d}", .{idx}) catch unreachable;
                elem = obj.get(islice);
            }
        }
    } else if (target.isString()) {
        const s: *@import("../string.zig").JSString = @ptrCast(@alignCast(target.asString()));
        length = @intCast(@min(s.bytes.len, std.math.maxInt(i32)));
        const start: usize = @intCast(idx);
        if (start < s.bytes.len) {
            const sub = realm.heap.allocateString(s.bytes[start .. start + 1]) catch return null;
            elem = Value.fromString(sub);
        }
    } else {
        return null;
    }
    if (idx >= length) return null;
    it.set(realm.allocator, "__cynic_iter_idx__", Value.fromInt32(idx + 1)) catch return null;
    return .{ .idx = idx, .value = elem, .length = length };
}

fn arrayLikeIterValuesNext(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = args;
    if (arrayLikeIterStep(realm, this_value)) |step| {
        return iterResult(realm, step.value, false) catch return error.OutOfMemory;
    }
    return iterResult(realm, Value.undefined_, true) catch return error.OutOfMemory;
}
fn arrayLikeIterKeysNext(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = args;
    if (arrayLikeIterStep(realm, this_value)) |step| {
        return iterResult(realm, Value.fromInt32(step.idx), false) catch return error.OutOfMemory;
    }
    return iterResult(realm, Value.undefined_, true) catch return error.OutOfMemory;
}
fn arrayLikeIterEntriesNext(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = args;
    if (arrayLikeIterStep(realm, this_value)) |step| {
        const arr = realm.heap.allocateObject() catch return error.OutOfMemory;
        arr.prototype = realm.intrinsics.array_prototype;
        arr.markAsArrayExotic(realm.allocator) catch return error.OutOfMemory;
        arr.set(realm.allocator, "0", Value.fromInt32(step.idx)) catch return error.OutOfMemory;
        arr.set(realm.allocator, "1", step.value) catch return error.OutOfMemory;
        arr.set(realm.allocator, "length", Value.fromInt32(2)) catch return error.OutOfMemory;
        return iterResult(realm, heap_mod.taggedObject(arr), false) catch return error.OutOfMemory;
    }
    return iterResult(realm, Value.undefined_, true) catch return error.OutOfMemory;
}

fn iterResult(realm: *Realm, value: Value, done: bool) !Value {
    const r = try realm.heap.allocateObject();
    r.prototype = realm.intrinsics.object_prototype;
    try r.set(realm.allocator, "value", value);
    try r.set(realm.allocator, "done", Value.fromBool(done));
    return heap_mod.taggedObject(r);
}

fn mapIterAdvance(realm: *Realm, this_value: Value) ?struct { key: Value, value: Value } {
    const it = heap_mod.valueAsPlainObject(this_value) orelse return null;
    const src = it.get("__cynic_map__");
    // §24.1.5.1 step 5 — once the iterator exhausts we set
    // O.[[Map]] to undefined so a later mutation of the source
    // can't revive iteration. We mirror that with a sentinel
    // undefined in the `__cynic_map__` slot.
    if (src.isUndefined()) return null;
    const idx_v = it.get("__cynic_idx__");
    var idx: usize = if (idx_v.isInt32()) @intCast(idx_v.asInt32()) else 0;
    const d = mapDataOf(src) orelse return null;
    while (idx < d.entries.items.len) : (idx += 1) {
        if (!d.entries.items[idx].deleted) {
            const next_idx_v = Value.fromInt32(@intCast(idx + 1));
            it.set(realm.allocator, "__cynic_idx__", next_idx_v) catch return null;
            return .{ .key = d.entries.items[idx].key, .value = d.entries.items[idx].value };
        }
    }
    // Exhausted — clear `[[Map]]` so subsequent next() calls
    // skip the data lookup and stay done even if entries grow.
    it.set(realm.allocator, "__cynic_map__", Value.undefined_) catch return null;
    return null;
}

/// §24.1.5.1 %MapIteratorPrototype%.next — single dispatch entry
/// shared by entries/keys/values. Steps:
///   1. RequireInternalSlot(O, [[Map]]) — `this` must be an
///      Object with the `__cynic_map__` own slot we install in
///      makeMapIterator. Anything else (primitive, plain `{}`,
///      a different iterator kind) is a TypeError.
///   2. Read `[[MapIterationKind]]` to decide value shape.
fn mapIterNext(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = args;
    const it = heap_mod.valueAsPlainObject(this_value) orelse
        return throwTypeError(realm, "MapIteratorPrototype.next called on non-object");
    if (!it.hasOwn("__cynic_map__"))
        return throwTypeError(realm, "MapIteratorPrototype.next called on incompatible receiver");
    const kind_v = it.get("__cynic_kind__");
    const kind: i32 = if (kind_v.isInt32()) kind_v.asInt32() else 0;
    if (mapIterAdvance(realm, this_value)) |kv| {
        switch (kind) {
            1 => return iterResult(realm, kv.key, false) catch return error.OutOfMemory,
            2 => return iterResult(realm, kv.value, false) catch return error.OutOfMemory,
            else => {
                const arr = realm.heap.allocateObject() catch return error.OutOfMemory;
                arr.prototype = realm.intrinsics.array_prototype;
                arr.markAsArrayExotic(realm.allocator) catch return error.OutOfMemory;
                arr.set(realm.allocator, "0", kv.key) catch return error.OutOfMemory;
                arr.set(realm.allocator, "1", kv.value) catch return error.OutOfMemory;
                arr.set(realm.allocator, "length", Value.fromInt32(2)) catch return error.OutOfMemory;
                return iterResult(realm, heap_mod.taggedObject(arr), false) catch return error.OutOfMemory;
            },
        }
    }
    return iterResult(realm, Value.undefined_, true) catch return error.OutOfMemory;
}

/// §24.1.2.2 Map.groupBy(items, callbackfn) — group `items` into
/// a Map keyed by `callbackfn(item, index)` (using SameValueZero
/// for key equality, matching Map's lookup semantics).
fn mapGroupBy(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = this_value;
    const items_v = argOr(args, 0, Value.undefined_);
    const cb_v = argOr(args, 1, Value.undefined_);
    const cb = heap_mod.valueAsFunction(cb_v) orelse return throwTypeError(realm, "Map.groupBy callback is not callable");

    // Allocate a fresh Map by reusing the constructor.
    const map_proto = if (heap_mod.valueAsFunction(realm.globals.get("Map") orelse Value.undefined_)) |mp| mp.prototype else null;
    const out = realm.heap.allocateObject() catch return error.OutOfMemory;
    out.prototype = map_proto;
    const data = realm.allocator.create(ObjMod.MapData) catch return error.OutOfMemory;
    data.* = .{};
    out.map_data = data;

    const iter = interpreter.openIterator(realm.allocator, realm, items_v) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return throwTypeError(realm, "Map.groupBy items is not iterable"),
    };
    const iter_obj = heap_mod.valueAsPlainObject(iter) orelse return throwTypeError(realm, "Map.groupBy items is not iterable");
    const next_v = iter_obj.get("next");
    const next_fn = heap_mod.valueAsFunction(next_v) orelse return throwTypeError(realm, "iterator.next is not callable");

    const max_iter: i64 = 1 << 24;
    var i: i64 = 0;
    while (i < max_iter) : (i += 1) {
        const step = interpreter.callJSFunction(realm.allocator, realm, next_fn, iter, &.{}) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.NativeThrew,
        };
        const result_v = switch (step) {
            .value, .yielded => |v| v,
            .thrown => return error.NativeThrew,
        };
        const result = heap_mod.valueAsPlainObject(result_v) orelse break;
        if (intrinsics.toBoolean(try intrinsics.getPropertyChain(realm, result, "done"))) break;
        const item = try intrinsics.getPropertyChain(realm, result, "value");
        const cb_args = [_]Value{ item, Value.fromInt32(@intCast(i)) };
        const key_outcome = interpreter.callJSFunction(realm.allocator, realm, cb, Value.undefined_, &cb_args) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.NativeThrew,
        };
        const key_v = switch (key_outcome) {
            .value, .yielded => |v| v,
            .thrown => return error.NativeThrew,
        };
        // Look up or create the bucket array (under the Map's
        // SameValueZero key equality).
        if (mapEntryIndex(data, key_v)) |existing_idx| {
            const bucket_obj = heap_mod.valueAsPlainObject(data.entries.items[existing_idx].value) orelse continue;
            const cur_len = bucket_obj.get("length");
            const len_i: i32 = if (cur_len.isInt32()) cur_len.asInt32() else 0;
            var idx_buf: [16]u8 = undefined;
            const idx_slice = std.fmt.bufPrint(&idx_buf, "{d}", .{len_i}) catch return error.OutOfMemory;
            const idx_owned = realm.heap.allocateString(idx_slice) catch return error.OutOfMemory;
            bucket_obj.set(realm.allocator, idx_owned.bytes, item) catch return error.OutOfMemory;
            bucket_obj.set(realm.allocator, "length", Value.fromInt32(len_i + 1)) catch return error.OutOfMemory;
        } else {
            const bucket = realm.heap.allocateObject() catch return error.OutOfMemory;
            bucket.prototype = realm.intrinsics.array_prototype;
            bucket.markAsArrayExotic(realm.allocator) catch return error.OutOfMemory;
            const idx_owned = realm.heap.allocateString("0") catch return error.OutOfMemory;
            bucket.set(realm.allocator, idx_owned.bytes, item) catch return error.OutOfMemory;
            bucket.set(realm.allocator, "length", Value.fromInt32(1)) catch return error.OutOfMemory;
            data.entries.append(realm.allocator, .{ .key = key_v, .value = heap_mod.taggedObject(bucket) }) catch return error.OutOfMemory;
        }
    }
    return heap_mod.taggedObject(out);
}

fn mapConstructor(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const inst = heap_mod.valueAsPlainObject(this_value) orelse return throwTypeError(realm, "Map constructor requires 'new'");
    const data = realm.allocator.create(ObjMod.MapData) catch return error.OutOfMemory;
    data.* = .{};
    inst.map_data = data;
    // §24.1.1.1 step 9 — if iterable was supplied, populate
    // pairs. later uses array-like iteration.
    if (args.len > 0 and !args[0].isUndefined() and !args[0].isNull()) {
        const src = heap_mod.valueAsPlainObject(args[0]) orelse return throwTypeError(realm, "Map iterable must be an object");
        const len = lengthOfArray(src);
        var i: i64 = 0;
        while (i < len) : (i += 1) {
            var ibuf: [24]u8 = undefined;
            const islice = std.fmt.bufPrint(&ibuf, "{d}", .{i}) catch unreachable;
            const pair_v = src.get(islice);
            const pair = heap_mod.valueAsPlainObject(pair_v) orelse return throwTypeError(realm, "Map entry must be a [key, value] pair");
            const key = pair.get("0");
            const val = pair.get("1");
            try mapSetInternal(realm, inst, key, val);
        }
    }
    return this_value;
}

fn mapDataOf(this_value: Value) ?*@import("../object.zig").MapData {
    const obj = heap_mod.valueAsPlainObject(this_value) orelse return null;
    return obj.map_data;
}

fn mapEntryIndex(d: *@import("../object.zig").MapData, key: Value) ?usize {
    for (d.entries.items, 0..) |e, i| {
        if (e.deleted) continue;
        if (sameValueZero(e.key, key)) return i;
    }
    return null;
}

fn mapSetInternal(realm: *Realm, inst: *@import("../object.zig").JSObject, key: Value, value: Value) !void {
    const d = inst.map_data orelse return error.NativeThrew;
    if (mapEntryIndex(d, key)) |idx| {
        d.entries.items[idx].value = value;
    } else {
        try d.entries.append(realm.allocator, .{ .key = key, .value = value });
    }
}

fn mapSet(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const inst = heap_mod.valueAsPlainObject(this_value) orelse return throwTypeError(realm, "Map.prototype.set called on non-Map");
    if (inst.map_data == null) return throwTypeError(realm, "Map.prototype.set called on non-Map");
    mapSetInternal(realm, inst, argOr(args, 0, Value.undefined_), argOr(args, 1, Value.undefined_)) catch return error.OutOfMemory;
    return this_value;
}

fn mapGet(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const d = mapDataOf(this_value) orelse return throwTypeError(realm, "Map.prototype.get called on non-Map");
    if (mapEntryIndex(d, argOr(args, 0, Value.undefined_))) |i| return d.entries.items[i].value;
    return Value.undefined_;
}

fn mapHas(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const d = mapDataOf(this_value) orelse return throwTypeError(realm, "Map.prototype.has called on non-Map");
    return Value.fromBool(mapEntryIndex(d, argOr(args, 0, Value.undefined_)) != null);
}

fn mapDelete(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const d = mapDataOf(this_value) orelse return throwTypeError(realm, "Map.prototype.delete called on non-Map");
    if (mapEntryIndex(d, argOr(args, 0, Value.undefined_))) |i| {
        d.entries.items[i].deleted = true;
        return Value.true_;
    }
    return Value.false_;
}

fn mapClear(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = args;
    const d = mapDataOf(this_value) orelse return throwTypeError(realm, "Map.prototype.clear called on non-Map");
    for (d.entries.items) |*e| e.deleted = true;
    return Value.undefined_;
}

fn mapSizeGetter(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = args;
    const d = mapDataOf(this_value) orelse return throwTypeError(realm, "Map.prototype.size called on non-Map");
    var n: i64 = 0;
    for (d.entries.items) |e| if (!e.deleted) {
        n += 1;
    };
    return numberFromI64(n);
}

fn mapForEach(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const d = mapDataOf(this_value) orelse return throwTypeError(realm, "Map.prototype.forEach called on non-Map");
    const callback = heap_mod.valueAsFunction(argOr(args, 0, Value.undefined_)) orelse return throwTypeError(realm, "callback is not a function");
    const this_arg = argOr(args, 1, Value.undefined_);

    var i: usize = 0;
    while (i < d.entries.items.len) : (i += 1) {
        const e = d.entries.items[i];
        if (e.deleted) continue;
        const cb_args = [_]Value{ e.value, e.key, this_value };
        const outcome = interpreter.callJSFunction(realm.allocator, realm, callback, this_arg, &cb_args) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.NativeThrew,
        };
        switch (outcome) {
            .value, .yielded => {},
            .thrown => return error.NativeThrew,
        }
    }
    return Value.undefined_;
}

// ── §24.3 WeakMap (strong-ref impl — observable behaviour matches; no GC weakness yet) ──

pub fn installWeakMap(realm: *Realm) !void {
    const r = try installConstructor(realm, .{
        .name = "WeakMap", .ctor = weakMapConstructor, .arity = 1,
        .to_string_tag = "WeakMap",
    });
    _ = r.ctor;
    const proto = r.proto;

    try installNativeMethodOnProto(realm, proto, "set", weakMapSet, 2);
    try installNativeMethodOnProto(realm, proto, "get", weakMapGet, 1);
    try installNativeMethodOnProto(realm, proto, "has", weakMapHas, 1);
    try installNativeMethodOnProto(realm, proto, "delete", weakMapDelete, 1);
    // §24.3 ES2024 additions.
    try installNativeMethodOnProto(realm, proto, "getOrInsert", weakMapGetOrInsert, 2);
    try installNativeMethodOnProto(realm, proto, "getOrInsertComputed", weakMapGetOrInsertComputed, 2);
}

fn weakMapDataOf(this_value: Value) ?*@import("../object.zig").MapData {
    const obj = heap_mod.valueAsPlainObject(this_value) orelse return null;
    const d = obj.map_data orelse return null;
    if (!d.is_weak) return null;
    return d;
}

fn weakMapGet(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const d = weakMapDataOf(this_value) orelse return throwTypeError(realm, "WeakMap.prototype.get called on non-WeakMap");
    if (mapEntryIndex(d, argOr(args, 0, Value.undefined_))) |i| return d.entries.items[i].value;
    return Value.undefined_;
}
fn weakMapHas(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const d = weakMapDataOf(this_value) orelse return throwTypeError(realm, "WeakMap.prototype.has called on non-WeakMap");
    return Value.fromBool(mapEntryIndex(d, argOr(args, 0, Value.undefined_)) != null);
}
fn weakMapDelete(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const d = weakMapDataOf(this_value) orelse return throwTypeError(realm, "WeakMap.prototype.delete called on non-WeakMap");
    if (mapEntryIndex(d, argOr(args, 0, Value.undefined_))) |i| {
        d.entries.items[i].deleted = true;
        return Value.true_;
    }
    return Value.false_;
}

fn weakMapGetOrInsert(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const inst = heap_mod.valueAsPlainObject(this_value) orelse return throwTypeError(realm, "WeakMap.prototype.getOrInsert called on non-WeakMap");
    const d = inst.map_data orelse return throwTypeError(realm, "WeakMap.prototype.getOrInsert called on non-WeakMap");
    if (!d.is_weak) return throwTypeError(realm, "WeakMap.prototype.getOrInsert called on non-WeakMap");
    const key = argOr(args, 0, Value.undefined_);
    if (!key.isObject() and !heap_mod.isSymbol(key)) return throwTypeError(realm, "WeakMap key must be an Object or Symbol");
    if (mapEntryIndex(d, key)) |i| return d.entries.items[i].value;
    const value = argOr(args, 1, Value.undefined_);
    mapSetInternal(realm, inst, key, value) catch return error.OutOfMemory;
    return value;
}

fn weakMapGetOrInsertComputed(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const inst = heap_mod.valueAsPlainObject(this_value) orelse return throwTypeError(realm, "WeakMap.prototype.getOrInsertComputed called on non-WeakMap");
    const d = inst.map_data orelse return throwTypeError(realm, "WeakMap.prototype.getOrInsertComputed called on non-WeakMap");
    if (!d.is_weak) return throwTypeError(realm, "WeakMap.prototype.getOrInsertComputed called on non-WeakMap");
    const key = argOr(args, 0, Value.undefined_);
    if (!key.isObject() and !heap_mod.isSymbol(key)) return throwTypeError(realm, "WeakMap key must be an Object or Symbol");
    const cb = heap_mod.valueAsFunction(argOr(args, 1, Value.undefined_)) orelse return throwTypeError(realm, "callbackfn must be a function");
    if (mapEntryIndex(d, key)) |i| return d.entries.items[i].value;

    const cb_args = [_]Value{key};
    const outcome = interpreter.callJSFunction(realm.allocator, realm, cb, Value.undefined_, &cb_args) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.NativeThrew,
    };
    const value = switch (outcome) {
        .value, .yielded => |v| v,
        .thrown => |ex| {
            realm.pending_exception = ex;
            return error.NativeThrew;
        },
    };
    mapSetInternal(realm, inst, key, value) catch return error.OutOfMemory;
    return value;
}

fn weakMapConstructor(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const inst = heap_mod.valueAsPlainObject(this_value) orelse return throwTypeError(realm, "WeakMap constructor requires 'new'");
    const data = realm.allocator.create(ObjMod.MapData) catch return error.OutOfMemory;
    data.* = .{ .is_weak = true };
    inst.map_data = data;
    if (args.len > 0 and !args[0].isUndefined() and !args[0].isNull()) {
        const src = heap_mod.valueAsPlainObject(args[0]) orelse return throwTypeError(realm, "WeakMap iterable must be an object");
        const len = lengthOfArray(src);
        var i: i64 = 0;
        while (i < len) : (i += 1) {
            var ibuf: [24]u8 = undefined;
            const islice = std.fmt.bufPrint(&ibuf, "{d}", .{i}) catch unreachable;
            const pair_v = src.get(islice);
            const pair = heap_mod.valueAsPlainObject(pair_v) orelse return throwTypeError(realm, "WeakMap entry must be a [key, value] pair");
            const key = pair.get("0");
            const val = pair.get("1");
            // §24.3 — keys must be Objects (or registered Symbols).
            if (!key.isObject()) return throwTypeError(realm, "WeakMap key must be an object");
            try mapSetInternal(realm, inst, key, val);
        }
    }
    return this_value;
}

fn weakMapSet(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const inst = heap_mod.valueAsPlainObject(this_value) orelse return throwTypeError(realm, "WeakMap.prototype.set called on non-WeakMap");
    if (inst.map_data == null) return throwTypeError(realm, "WeakMap.prototype.set called on non-WeakMap");
    const key = argOr(args, 0, Value.undefined_);
    if (!key.isObject()) return throwTypeError(realm, "WeakMap key must be an object");
    mapSetInternal(realm, inst, key, argOr(args, 1, Value.undefined_)) catch return error.OutOfMemory;
    return this_value;
}

// ── §24.4 WeakSet ───────────────────────────────────────────────────────────

pub fn installWeakSet(realm: *Realm) !void {
    const r = try installConstructor(realm, .{
        .name = "WeakSet", .ctor = weakSetConstructor, .arity = 1,
        .to_string_tag = "WeakSet",
    });
    _ = r.ctor;
    const proto = r.proto;

    try installNativeMethodOnProto(realm, proto, "add", weakSetAdd, 1);
    try installNativeMethodOnProto(realm, proto, "has", weakSetHas, 1);
    try installNativeMethodOnProto(realm, proto, "delete", weakSetDelete, 1);
}

fn weakSetDataOf(this_value: Value) ?*@import("../object.zig").SetData {
    const obj = heap_mod.valueAsPlainObject(this_value) orelse return null;
    const d = obj.set_data orelse return null;
    // Symmetric brand check: WeakSet methods reject Set receivers.
    if (!d.is_weak) return null;
    return d;
}

fn weakSetHas(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const d = weakSetDataOf(this_value) orelse return throwTypeError(realm, "WeakSet.prototype.has called on non-WeakSet");
    return Value.fromBool(setIndex(d, argOr(args, 0, Value.undefined_)) != null);
}

fn weakSetDelete(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const d = weakSetDataOf(this_value) orelse return throwTypeError(realm, "WeakSet.prototype.delete called on non-WeakSet");
    if (setIndex(d, argOr(args, 0, Value.undefined_))) |i| {
        d.entries.items[i].deleted = true;
        return Value.true_;
    }
    return Value.false_;
}

fn weakSetConstructor(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const inst = heap_mod.valueAsPlainObject(this_value) orelse return throwTypeError(realm, "WeakSet constructor requires 'new'");
    const data = realm.allocator.create(ObjMod.SetData) catch return error.OutOfMemory;
    data.* = .{ .is_weak = true };
    inst.set_data = data;
    if (args.len > 0 and !args[0].isUndefined() and !args[0].isNull()) {
        const src = heap_mod.valueAsPlainObject(args[0]) orelse return throwTypeError(realm, "WeakSet iterable must be an object");
        const len = lengthOfArray(src);
        var i: i64 = 0;
        while (i < len) : (i += 1) {
            var ibuf: [24]u8 = undefined;
            const islice = std.fmt.bufPrint(&ibuf, "{d}", .{i}) catch unreachable;
            const v = src.get(islice);
            if (!v.isObject()) return throwTypeError(realm, "WeakSet value must be an object");
            try setAddInternal(realm, inst, v);
        }
    }
    return this_value;
}

fn weakSetAdd(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const inst = heap_mod.valueAsPlainObject(this_value) orelse return throwTypeError(realm, "WeakSet.prototype.add called on non-WeakSet");
    const d = inst.set_data orelse return throwTypeError(realm, "WeakSet.prototype.add called on non-WeakSet");
    if (!d.is_weak) return throwTypeError(realm, "WeakSet.prototype.add called on non-WeakSet");
    const v = argOr(args, 0, Value.undefined_);
    if (!v.isObject()) return throwTypeError(realm, "WeakSet value must be an object");
    setAddInternal(realm, inst, v) catch return error.OutOfMemory;
    return this_value;
}

// ── §24.2 Set ───────────────────────────────────────────────────────────────

pub fn installSet(realm: *Realm) !void {
    // §24.2.1 — `Set.length` is 0 (`iterable` is optional, so the
    // [[Construct]] arity drops it from the count).
    const r = try installConstructor(realm, .{
        .name = "Set", .ctor = setConstructor, .arity = 0,
        .to_string_tag = "Set",
    });
    _ = r.ctor;
    const proto = r.proto;

    try installNativeMethodOnProto(realm, proto, "add", setAdd, 1);
    try installNativeMethodOnProto(realm, proto, "has", setHas, 1);
    try installNativeMethodOnProto(realm, proto, "delete", setDelete, 1);
    try installNativeMethodOnProto(realm, proto, "clear", setClear, 0);
    try installNativeMethodOnProto(realm, proto, "forEach", setForEach, 1);
    // §24.2.3 Set iterators — `values()` is the default; spec
    // also defines `entries()` (returns `[v, v]` pairs) and
    // `keys()` (alias of `values()`).
    // §24.2.3 — `Set.prototype.values`, `.keys`, and `@@iterator`
    // are required to be the *same* function object. Allocate
    // once and install it under all three names.
    const values_fn = try realm.heap.allocateFunctionNative(setValuesMethod, 0, "values");
    values_fn.has_construct = false;
    values_fn.proto = realm.intrinsics.function_prototype;
    const values_v = heap_mod.taggedFunction(values_fn);
    try proto.setWithFlags(realm.allocator, "values", values_v, .{ .writable = true, .enumerable = false, .configurable = true });
    try proto.setWithFlags(realm.allocator, "keys", values_v, .{ .writable = true, .enumerable = false, .configurable = true });
    try proto.setWithFlags(realm.allocator, "@@iterator", values_v, .{ .writable = true, .enumerable = false, .configurable = true });
    try installNativeMethodOnProto(realm, proto, "entries", setEntriesMethod, 0);

    // §24.2.4.x — ES2025 set composition methods. All accept any
    // "set-like" object satisfying {size, has, keys}.
    try installNativeMethodOnProto(realm, proto, "union", setUnion, 1);
    try installNativeMethodOnProto(realm, proto, "intersection", setIntersection, 1);
    try installNativeMethodOnProto(realm, proto, "difference", setDifference, 1);
    try installNativeMethodOnProto(realm, proto, "symmetricDifference", setSymmetricDifference, 1);
    try installNativeMethodOnProto(realm, proto, "isSubsetOf", setIsSubsetOf, 1);
    try installNativeMethodOnProto(realm, proto, "isSupersetOf", setIsSupersetOf, 1);
    try installNativeMethodOnProto(realm, proto, "isDisjointFrom", setIsDisjointFrom, 1);

    try installNativeGetter(realm, proto, "size", setSizeGetter);

    realm.intrinsics.set_prototype = proto;

    // §24.2.5.2 %SetIteratorPrototype% — shared prototype for
    // Set-iterator instances. Same shape as %MapIteratorPrototype%.
    const it_proto = try realm.heap.allocateObject();
    it_proto.prototype = realm.intrinsics.object_prototype;
    try installNativeMethodOnProto(realm, it_proto, "next", setIterNext, 0);
    try installNativeMethodOnProto(realm, it_proto, "@@iterator", iteratorReturnsSelf, 0);
    try intrinsics.installToStringTag(realm, it_proto, "Set Iterator");
    realm.intrinsics.set_iterator_prototype = it_proto;
}

/// §24.2.5.1 CreateSetIterator. Mirrors makeMapIterator — the
/// `__cynic_set__` own slot is the brand check; the kind tag
/// (0 = values, 1 = entries) lets a single shared next dispatch.
fn makeSetIterator(realm: *Realm, src: Value, kind: enum { values, entries }) !Value {
    const it = try realm.heap.allocateObject();
    it.prototype = realm.intrinsics.set_iterator_prototype orelse realm.intrinsics.object_prototype;
    try it.set(realm.allocator, "__cynic_set__", src);
    try it.set(realm.allocator, "__cynic_idx__", Value.fromInt32(0));
    const kind_tag: i32 = switch (kind) {
        .values => 0,
        .entries => 1,
    };
    try it.set(realm.allocator, "__cynic_kind__", Value.fromInt32(kind_tag));
    return heap_mod.taggedObject(it);
}

fn setValuesMethod(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = args;
    if (setDataOf(this_value) == null) return throwTypeError(realm, "Set iterator on non-Set");
    return makeSetIterator(realm, this_value, .values) catch return error.OutOfMemory;
}
fn setEntriesMethod(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = args;
    if (setDataOf(this_value) == null) return throwTypeError(realm, "Set iterator on non-Set");
    return makeSetIterator(realm, this_value, .entries) catch return error.OutOfMemory;
}

fn setIterAdvance(realm: *Realm, this_value: Value) ?Value {
    const it = heap_mod.valueAsPlainObject(this_value) orelse return null;
    const src = it.get("__cynic_set__");
    // §24.2.5.1 step 5 — once exhausted, [[IteratedSet]] is
    // cleared so post-exhaustion `add()` calls don't revive
    // iteration. Sentinel: undefined.
    if (src.isUndefined()) return null;
    const idx_v = it.get("__cynic_idx__");
    var idx: usize = if (idx_v.isInt32()) @intCast(idx_v.asInt32()) else 0;
    const d = setDataOf(src) orelse return null;
    while (idx < d.entries.items.len) : (idx += 1) {
        if (!d.entries.items[idx].deleted) {
            it.set(realm.allocator, "__cynic_idx__", Value.fromInt32(@intCast(idx + 1))) catch return null;
            return d.entries.items[idx].value;
        }
    }
    it.set(realm.allocator, "__cynic_set__", Value.undefined_) catch return null;
    return null;
}

/// §24.2.5.1 %SetIteratorPrototype%.next — RequireInternalSlot
/// on `[[IteratedSet]]` (presence of `__cynic_set__`), then
/// dispatch on the iteration kind.
fn setIterNext(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = args;
    const it = heap_mod.valueAsPlainObject(this_value) orelse
        return throwTypeError(realm, "SetIteratorPrototype.next called on non-object");
    if (!it.hasOwn("__cynic_set__"))
        return throwTypeError(realm, "SetIteratorPrototype.next called on incompatible receiver");
    const kind_v = it.get("__cynic_kind__");
    const kind: i32 = if (kind_v.isInt32()) kind_v.asInt32() else 0;
    if (setIterAdvance(realm, this_value)) |v| {
        if (kind == 1) {
            const arr = realm.heap.allocateObject() catch return error.OutOfMemory;
            arr.prototype = realm.intrinsics.array_prototype;
            arr.markAsArrayExotic(realm.allocator) catch return error.OutOfMemory;
            arr.set(realm.allocator, "0", v) catch return error.OutOfMemory;
            arr.set(realm.allocator, "1", v) catch return error.OutOfMemory;
            arr.set(realm.allocator, "length", Value.fromInt32(2)) catch return error.OutOfMemory;
            return iterResult(realm, heap_mod.taggedObject(arr), false) catch return error.OutOfMemory;
        }
        return iterResult(realm, v, false) catch return error.OutOfMemory;
    }
    return iterResult(realm, Value.undefined_, true) catch return error.OutOfMemory;
}

fn setConstructor(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const inst = heap_mod.valueAsPlainObject(this_value) orelse return throwTypeError(realm, "Set constructor requires 'new'");
    const data = realm.allocator.create(ObjMod.SetData) catch return error.OutOfMemory;
    data.* = .{};
    inst.set_data = data;
    if (args.len > 0 and !args[0].isUndefined() and !args[0].isNull()) {
        const src = heap_mod.valueAsPlainObject(args[0]) orelse return throwTypeError(realm, "Set iterable must be an object");
        const len = lengthOfArray(src);
        var i: i64 = 0;
        while (i < len) : (i += 1) {
            var ibuf: [24]u8 = undefined;
            const islice = std.fmt.bufPrint(&ibuf, "{d}", .{i}) catch unreachable;
            try setAddInternal(realm, inst, src.get(islice));
        }
    }
    return this_value;
}

fn setDataOf(this_value: Value) ?*@import("../object.zig").SetData {
    const obj = heap_mod.valueAsPlainObject(this_value) orelse return null;
    const d = obj.set_data orelse return null;
    // Set.prototype methods reject WeakSet receivers — §24.2.3
    // brand-checks the [[SetData]] internal slot, which is
    // distinct from WeakSet's [[WeakSetData]].
    if (d.is_weak) return null;
    return d;
}

fn setIndex(d: *@import("../object.zig").SetData, key: Value) ?usize {
    for (d.entries.items, 0..) |e, i| {
        if (e.deleted) continue;
        if (sameValueZero(e.value, key)) return i;
    }
    return null;
}

fn setAddInternal(realm: *Realm, inst: *@import("../object.zig").JSObject, value: Value) !void {
    const d = inst.set_data orelse return error.NativeThrew;
    if (setIndex(d, value) == null) {
        try d.entries.append(realm.allocator, .{ .value = value });
    }
}

fn setAdd(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const inst = heap_mod.valueAsPlainObject(this_value) orelse return throwTypeError(realm, "Set.prototype.add called on non-Set");
    const d = inst.set_data orelse return throwTypeError(realm, "Set.prototype.add called on non-Set");
    if (d.is_weak) return throwTypeError(realm, "Set.prototype.add called on non-Set");
    setAddInternal(realm, inst, argOr(args, 0, Value.undefined_)) catch return error.OutOfMemory;
    return this_value;
}

fn setHas(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const d = setDataOf(this_value) orelse return throwTypeError(realm, "Set.prototype.has called on non-Set");
    return Value.fromBool(setIndex(d, argOr(args, 0, Value.undefined_)) != null);
}

fn setDelete(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const d = setDataOf(this_value) orelse return throwTypeError(realm, "Set.prototype.delete called on non-Set");
    if (setIndex(d, argOr(args, 0, Value.undefined_))) |i| {
        d.entries.items[i].deleted = true;
        return Value.true_;
    }
    return Value.false_;
}

fn setClear(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = args;
    const d = setDataOf(this_value) orelse return throwTypeError(realm, "Set.prototype.clear called on non-Set");
    for (d.entries.items) |*e| e.deleted = true;
    return Value.undefined_;
}

fn setSizeGetter(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = args;
    const d = setDataOf(this_value) orelse return throwTypeError(realm, "Set.prototype.size called on non-Set");
    var n: i64 = 0;
    for (d.entries.items) |e| if (!e.deleted) {
        n += 1;
    };
    return numberFromI64(n);
}

fn setForEach(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const d = setDataOf(this_value) orelse return throwTypeError(realm, "Set.prototype.forEach called on non-Set");
    const callback = heap_mod.valueAsFunction(argOr(args, 0, Value.undefined_)) orelse return throwTypeError(realm, "callback is not a function");
    const this_arg = argOr(args, 1, Value.undefined_);

    var i: usize = 0;
    while (i < d.entries.items.len) : (i += 1) {
        const e = d.entries.items[i];
        if (e.deleted) continue;
        // Spec: callback(value, value, this_set) — yes, value
        // appears twice (Set has no key separate from value).
        const cb_args = [_]Value{ e.value, e.value, this_value };
        const outcome = interpreter.callJSFunction(realm.allocator, realm, callback, this_arg, &cb_args) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.NativeThrew,
        };
        switch (outcome) {
            .value, .yielded => {},
            .thrown => return error.NativeThrew,
        }
    }
    return Value.undefined_;
}

// ── §24.2.4.x ES2025 Set composition helpers ─────────────────────────────

/// §24.2.1.2 GetSetRecord — validate `other` is a usable
/// set-like. We don't cache the size (Cynic's helpers iterate
/// fresh each time anyway) so this function only validates the
/// shape and returns the (has, keys) pair.
const SetLike = struct {
    has: *JSFunction,
    keys: *JSFunction,
    /// The set-like object itself — receiver for has/keys calls.
    obj: Value,
};

fn validateSetLike(realm: *Realm, op: []const u8, value: Value) NativeError!SetLike {
    const obj = heap_mod.valueAsPlainObject(value) orelse {
        var buf: [128]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "Set.prototype.{s}: argument must be a set-like object", .{op}) catch op;
        return throwTypeError(realm, msg);
    };
    // Per spec we'd validate size, but Cynic skips that — has + keys are what
    // we actually use, and forcing a numeric size on real Sets isn't observable.
    const has_v = obj.get("has");
    const has_fn = heap_mod.valueAsFunction(has_v) orelse {
        var buf: [128]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "Set.prototype.{s}: argument is not set-like (no callable 'has')", .{op}) catch op;
        return throwTypeError(realm, msg);
    };
    const keys_v = obj.get("keys");
    const keys_fn = heap_mod.valueAsFunction(keys_v) orelse {
        var buf: [128]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "Set.prototype.{s}: argument is not set-like (no callable 'keys')", .{op}) catch op;
        return throwTypeError(realm, msg);
    };
    return .{ .has = has_fn, .keys = keys_fn, .obj = value };
}

fn setLikeHas(realm: *Realm, sl: SetLike, value: Value) NativeError!bool {
    const args1 = [_]Value{value};
    const outcome = callJSFunction(realm.allocator, realm, sl.has, sl.obj, &args1) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.NativeThrew,
    };
    return switch (outcome) {
        .value, .yielded => |v| intrinsics.toBoolean(v),
        .thrown => error.NativeThrew,
    };
}

/// Walk the set-like via its `keys()` iterator, invoking
/// `each(value)` for each yielded entry. Stops if `each` returns
/// `error.IterStop`.
const IterStop = error{IterStop};

fn forEachSetLikeKey(
    realm: *Realm,
    sl: SetLike,
    ctx: anytype,
    comptime each: fn (@TypeOf(ctx), Value) (NativeError || IterStop)!void,
) NativeError!void {
    // Real Set fast path — skip the iterator protocol entirely
    // when we can read entries directly. Behavior is identical
    // (insertion order, deleted skip), and avoids allocating an
    // iterator object on every call.
    if (setDataOf(sl.obj)) |d| {
        var i: usize = 0;
        while (i < d.entries.items.len) : (i += 1) {
            const e = d.entries.items[i];
            if (e.deleted) continue;
            each(ctx, e.value) catch |err| switch (err) {
                error.IterStop => return,
                else => |e2| return e2,
            };
        }
        return;
    }

    // General set-like path: call `keys()` to obtain an iterator,
    // then invoke its `next()` until `done: true`.
    const iter_outcome = callJSFunction(realm.allocator, realm, sl.keys, sl.obj, &.{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.NativeThrew,
    };
    const iter = switch (iter_outcome) {
        .value, .yielded => |v| v,
        .thrown => return error.NativeThrew,
    };
    const iter_obj = heap_mod.valueAsPlainObject(iter) orelse return throwTypeError(realm, "set-like keys() did not return an iterator");
    const next_v = iter_obj.get("next");
    const next_fn = heap_mod.valueAsFunction(next_v) orelse return throwTypeError(realm, "set-like keys() iterator missing callable 'next'");

    const max_iter: usize = 1 << 24;
    var step: usize = 0;
    while (step < max_iter) : (step += 1) {
        const out = callJSFunction(realm.allocator, realm, next_fn, iter, &.{}) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.NativeThrew,
        };
        const result = switch (out) {
            .value, .yielded => |v| v,
            .thrown => return error.NativeThrew,
        };
        const ro = heap_mod.valueAsPlainObject(result) orelse return throwTypeError(realm, "iterator next() did not return an object");
        if (intrinsics.toBoolean(try intrinsics.getPropertyChain(realm, ro, "done"))) return;
        const v = try intrinsics.getPropertyChain(realm, ro, "value");
        each(ctx, v) catch |err| switch (err) {
            error.IterStop => return,
            else => |e2| return e2,
        };
    }
    return throwTypeError(realm, "set-like iteration exceeded the safety budget");
}

fn allocateEmptySet(realm: *Realm) NativeError!*JSObject {
    const obj = realm.heap.allocateObject() catch return error.OutOfMemory;
    if (realm.intrinsics.set_prototype) |sp| obj.prototype = sp;
    const data = realm.allocator.create(ObjMod.SetData) catch return error.OutOfMemory;
    data.* = .{};
    obj.set_data = data;
    return obj;
}

fn setUnion(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    if (setDataOf(this_value) == null) return throwTypeError(realm, "Set.prototype.union called on non-Set");
    const sl = try validateSetLike(realm, "union", argOr(args, 0, Value.undefined_));

    const out = try allocateEmptySet(realm);
    // Copy this set first, then add other's keys (sameValueZero
    // dedup keeps duplicates out).
    {
        const d = setDataOf(this_value).?;
        for (d.entries.items) |e| if (!e.deleted) {
            setAddInternal(realm, out, e.value) catch return error.OutOfMemory;
        };
    }
    const Ctx = struct { realm: *Realm, out: *JSObject };
    const each = struct {
        fn fn_(c: Ctx, v: Value) (NativeError || IterStop)!void {
            setAddInternal(c.realm, c.out, v) catch return error.OutOfMemory;
        }
    }.fn_;
    try forEachSetLikeKey(realm, sl, Ctx{ .realm = realm, .out = out }, each);
    return heap_mod.taggedObject(out);
}

fn setIntersection(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const this_d = setDataOf(this_value) orelse return throwTypeError(realm, "Set.prototype.intersection called on non-Set");
    const sl = try validateSetLike(realm, "intersection", argOr(args, 0, Value.undefined_));

    const out = try allocateEmptySet(realm);
    var i: usize = 0;
    while (i < this_d.entries.items.len) : (i += 1) {
        const e = this_d.entries.items[i];
        if (e.deleted) continue;
        if (try setLikeHas(realm, sl, e.value)) {
            setAddInternal(realm, out, e.value) catch return error.OutOfMemory;
        }
    }
    return heap_mod.taggedObject(out);
}

fn setDifference(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const this_d = setDataOf(this_value) orelse return throwTypeError(realm, "Set.prototype.difference called on non-Set");
    const sl = try validateSetLike(realm, "difference", argOr(args, 0, Value.undefined_));

    const out = try allocateEmptySet(realm);
    var i: usize = 0;
    while (i < this_d.entries.items.len) : (i += 1) {
        const e = this_d.entries.items[i];
        if (e.deleted) continue;
        if (!try setLikeHas(realm, sl, e.value)) {
            setAddInternal(realm, out, e.value) catch return error.OutOfMemory;
        }
    }
    return heap_mod.taggedObject(out);
}

fn setSymmetricDifference(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const this_d = setDataOf(this_value) orelse return throwTypeError(realm, "Set.prototype.symmetricDifference called on non-Set");
    const sl = try validateSetLike(realm, "symmetricDifference", argOr(args, 0, Value.undefined_));

    const out = try allocateEmptySet(realm);
    // First pass: this \ other.
    var i: usize = 0;
    while (i < this_d.entries.items.len) : (i += 1) {
        const e = this_d.entries.items[i];
        if (e.deleted) continue;
        if (!try setLikeHas(realm, sl, e.value)) {
            setAddInternal(realm, out, e.value) catch return error.OutOfMemory;
        }
    }
    // Second pass: other \ this — iterate other's keys, add ones
    // missing from this.
    const Ctx = struct { realm: *Realm, this_set: Value, out: *JSObject };
    const each = struct {
        fn fn_(c: Ctx, v: Value) (NativeError || IterStop)!void {
            const td = setDataOf(c.this_set).?;
            if (setIndex(td, v) == null) {
                setAddInternal(c.realm, c.out, v) catch return error.OutOfMemory;
            }
        }
    }.fn_;
    try forEachSetLikeKey(realm, sl, Ctx{ .realm = realm, .this_set = this_value, .out = out }, each);
    return heap_mod.taggedObject(out);
}

fn setIsSubsetOf(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const this_d = setDataOf(this_value) orelse return throwTypeError(realm, "Set.prototype.isSubsetOf called on non-Set");
    const sl = try validateSetLike(realm, "isSubsetOf", argOr(args, 0, Value.undefined_));

    var i: usize = 0;
    while (i < this_d.entries.items.len) : (i += 1) {
        const e = this_d.entries.items[i];
        if (e.deleted) continue;
        if (!try setLikeHas(realm, sl, e.value)) return Value.false_;
    }
    return Value.true_;
}

fn setIsSupersetOf(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    if (setDataOf(this_value) == null) return throwTypeError(realm, "Set.prototype.isSupersetOf called on non-Set");
    const sl = try validateSetLike(realm, "isSupersetOf", argOr(args, 0, Value.undefined_));

    const Ctx = struct { realm: *Realm, this_set: Value, ok: *bool };
    const each = struct {
        fn fn_(c: Ctx, v: Value) (NativeError || IterStop)!void {
            const td = setDataOf(c.this_set).?;
            if (setIndex(td, v) == null) {
                c.ok.* = false;
                return error.IterStop;
            }
        }
    }.fn_;
    var ok = true;
    try forEachSetLikeKey(realm, sl, Ctx{ .realm = realm, .this_set = this_value, .ok = &ok }, each);
    return Value.fromBool(ok);
}

fn setIsDisjointFrom(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const this_d = setDataOf(this_value) orelse return throwTypeError(realm, "Set.prototype.isDisjointFrom called on non-Set");
    const sl = try validateSetLike(realm, "isDisjointFrom", argOr(args, 0, Value.undefined_));

    var i: usize = 0;
    while (i < this_d.entries.items.len) : (i += 1) {
        const e = this_d.entries.items[i];
        if (e.deleted) continue;
        if (try setLikeHas(realm, sl, e.value)) return Value.false_;
    }
    return Value.true_;
}

