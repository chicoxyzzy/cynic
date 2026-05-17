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

/// §24.1.2.2 / §24.2.2.2 / §22.1.2.5 / §22.2.5.2 — `get
/// <Map|Set|Array|RegExp> [ @@species ]` returns `this`. Spec
/// flags `{ enumerable: false, configurable: true }`.
fn speciesReturnsThis(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = realm;
    _ = args;
    return this_value;
}

fn installSpeciesGetter(realm: *Realm, ctor: *@import("../function.zig").JSFunction) !void {
    // §24.1.2.2 get Map [ @@species ] — the getter's `.name` is
    // `"get [Symbol.species]"` per §15.7.4 (well-known-symbol
    // accessor formatting). Matches what `Symbol.species/symbol-
    // species-name.js` reads via `Object.getOwnPropertyDescriptor`.
    const getter = try realm.heap.allocateFunctionNative(speciesReturnsThis, 0, "get [Symbol.species]");
    getter.proto = realm.intrinsics.function_prototype;
    const entry = try ctor.accessors.getOrPut(realm.allocator, "@@species");
    entry.value_ptr.* = .{ .getter = getter };
    try ctor.property_flags.put(realm.allocator, "@@species", .{
        .writable = false, .enumerable = false, .configurable = true,
    });
}

pub fn installMap(realm: *Realm) !void {
    _ = ObjMod;
    // §24.1.1 — `Map.length` is 0. The `iterable` parameter is
    // optional, so it doesn't count toward the [[Construct]]
    // arity per §15.1.3 ("the value of the length property of a
    // built-in function is the number of REQUIRED parameters").
    const r = try installConstructor(realm, .{
        .name = "Map", .ctor = mapConstructor, .arity = 0,
        .to_string_tag = "Map",
    });
    const ctor = r.ctor;
    const proto = r.proto;

    try intrinsics.installNativeMethod(realm, ctor, "groupBy", mapGroupBy, 2);
    // §24.1.2.2 get Map [ @@species ] returns this.
    try installSpeciesGetter(realm, ctor);

    try installNativeMethodOnProto(realm, proto, "set", mapSet, 2);
    try installNativeMethodOnProto(realm, proto, "get", mapGet, 1);
    try installNativeMethodOnProto(realm, proto, "has", mapHas, 1);
    try installNativeMethodOnProto(realm, proto, "delete", mapDelete, 1);
    try installNativeMethodOnProto(realm, proto, "clear", mapClear, 0);
    try installNativeMethodOnProto(realm, proto, "forEach", mapForEach, 1);
    // PRE-STAGE-4 PROPOSAL — `upsert` (Stage 3 as of 2026-05).
    // Atomic "get the value at this key, or insert a default if absent."
    // `getOrInsert` takes a fixed default; `getOrInsertComputed` takes
    // a callback invoked only on absence whose return is stored.
    // Same shape ships on WeakMap.prototype below. Gated on the per-
    // realm feature flag so embedders / the `cynic` CLI need
    // `--enable=upsert` (or `--enable-experimental`) to see it.
    // Documented in `docs/ROADMAP.md` under "Pre-Stage-4 proposals
    // shipped".
    if (realm.feature_flags.contains(.upsert)) {
        try installNativeMethodOnProto(realm, proto, "getOrInsert", mapGetOrInsert, 2);
        try installNativeMethodOnProto(realm, proto, "getOrInsertComputed", mapGetOrInsertComputed, 2);
    }
    // §24.1.3 Map iterators — `entries()` is the default
    // (`@@iterator` aliases it), `keys()` and `values()` produce
    // single-element views. Each returns an iterator object
    // backed by the map's `[[MapData]]` and an index.
    try installNativeMethodOnProto(realm, proto, "entries", mapEntries, 0);
    try installNativeMethodOnProto(realm, proto, "keys", mapKeys, 0);
    try installNativeMethodOnProto(realm, proto, "values", mapValues, 0);
    // §24.1.3.12 — `Map.prototype[Symbol.iterator]` is the SAME
    // function object as `Map.prototype.entries` (the spec text:
    // "The initial value of the @@iterator property is the same
    // function object as the initial value of the entries
    // property"). Install both keys against one allocation
    // instead of two — `prototype/Symbol.iterator.js` reads
    // `Map.prototype[Symbol.iterator] === Map.prototype.entries`.
    const entries_fn_v = proto.properties.get("entries") orelse Value.undefined_;
    try proto.setWithFlags(realm.allocator, "@@iterator", entries_fn_v, .{
        .writable = true,
        .enumerable = false,
        .configurable = true,
    });

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
    const state = try realm.allocator.create(@import("../object.zig").ArrayLikeIterState);
    state.* = .{ .target = src };
    it.array_like_iter = state;
    // Pin `it` for the rest of construction — `allocateFunctionNative`
    // can trigger GC and `it` is only alive through this local var.
    // `src` rides along via `state.target` once the GC walker
    // reaches `it`.
    const scope = try realm.heap.openScope();
    defer scope.close();
    try scope.push(heap_mod.taggedObject(it));
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

/// §10.4.5 ValidateTypedArray check shared by the
/// TypedArray.prototype { keys, values, entries } variants of
/// the array-like iterator factory.
///
/// Spec §23.2.4.4 ValidateTypedArray(O, order):
///   1. If Type(O) is not Object → TypeError
///   2. If O does not have a [[TypedArrayName]] internal slot
///      → TypeError
///   3. (subsequent steps test buffer state)
///
/// Cynic's TA-method entry point — `%TypedArray%.prototype.
/// {keys,values,entries}` — therefore must throw TypeError for
/// any non-TA receiver (undefined, Array, DataView, plain
/// object, primitive). Only after the slot check do we test for
/// detached / OOB.
fn validateTypedArrayIfPresent(realm: *Realm, this_value: Value) NativeError!void {
    // §23.2.4.4 step 1 — Type(O) not Object → TypeError.
    const obj = heap_mod.valueAsPlainObject(this_value) orelse
        return throwTypeError(realm, "TypedArray iterator requires a TypedArray receiver");
    // §23.2.4.4 step 2 — missing [[TypedArrayName]] → TypeError.
    // `typed_view` is the Zig-side carrier for the [[TypedArrayName]] /
    // [[ViewedArrayBuffer]] / [[ByteOffset]] / [[ArrayLength]] slot
    // family; `null` means this object is plain / Array / DataView /
    // ArrayBuffer / %TypedArray%.prototype itself.
    const tv = obj.typed_view orelse
        return throwTypeError(realm, "TypedArray iterator requires a TypedArray receiver");
    // §23.2.4.4 ValidateTypedArray (called by entries / keys /
    // values) — throws TypeError when the buffer is detached
    // (IsTypedArrayOutOfBounds is `true` per ES2024 §25.1.3.x
    // for a detached buffer).
    const buf = tv.viewed.array_buffer orelse
        return throwTypeError(realm, "TypedArray iterator on detached buffer");
    // §10.4.5 IsTypedArrayOutOfBounds — for a length-tracking view,
    // OOB means `byte_offset > buf.len`; for a fixed-length view it
    // means `byte_offset + length*elem_size > buf.len`. The snapshot
    // `tv.length` is meaningless on length-tracking views (it's 0
    // at construction time and never updated).
    if (tv.length_tracking) {
        if (tv.byte_offset > buf.len) {
            return throwTypeError(realm, "TypedArray iterator on out-of-bounds TypedArray");
        }
    } else {
        const elem_size = tv.kind.elementSize();
        if (tv.byte_offset + tv.length * elem_size > buf.len) {
            return throwTypeError(realm, "TypedArray iterator on out-of-bounds TypedArray");
        }
    }
}

/// Array.prototype.{values, keys, entries} — no ValidateTypedArray
/// here even when the receiver is a TA. Per §23.1.3, the iterator
/// is created successfully; OOB-on-resizable-buffer surfaces at
/// `.next()` calls (live length re-resolution in `arrayLikeIterStep`).
pub fn arrayLikeValuesMethod(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = args;
    // §23.1.3.34 step 1 — Let O be ? ToObject(this value);
    // ReturnIfAbrupt(O). Throws TypeError on null / undefined.
    _ = try intrinsics.toObjectThis(realm, this_value);
    return makeArrayLikeIterator(realm, this_value, .values) catch return error.OutOfMemory;
}
pub fn arrayLikeKeysMethod(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = args;
    // §23.1.3.16 step 1 — ToObject(this value); throws on
    // null / undefined before iterator construction.
    _ = try intrinsics.toObjectThis(realm, this_value);
    return makeArrayLikeIterator(realm, this_value, .keys) catch return error.OutOfMemory;
}
pub fn arrayLikeEntriesMethod(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = args;
    // §23.1.3.5 step 1 — ToObject(this value).
    _ = try intrinsics.toObjectThis(realm, this_value);
    return makeArrayLikeIterator(realm, this_value, .entries) catch return error.OutOfMemory;
}
/// TypedArray.prototype.{values, keys, entries} — §23.2.3.30 et al
/// run ValidateTypedArray *before* the iterator is constructed.
pub fn typedArrayValuesMethod(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = args;
    try validateTypedArrayIfPresent(realm, this_value);
    return makeArrayLikeIterator(realm, this_value, .values) catch return error.OutOfMemory;
}
pub fn typedArrayKeysMethod(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = args;
    try validateTypedArrayIfPresent(realm, this_value);
    return makeArrayLikeIterator(realm, this_value, .keys) catch return error.OutOfMemory;
}
pub fn typedArrayEntriesMethod(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = args;
    try validateTypedArrayIfPresent(realm, this_value);
    return makeArrayLikeIterator(realm, this_value, .entries) catch return error.OutOfMemory;
}

pub fn stringIteratorMethod(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = args;
    return makeArrayLikeIterator(realm, this_value, .values) catch return error.OutOfMemory;
}

const StepOutcome = union(enum) {
    step: struct { idx: i32, value: Value, length: i64 },
    done,
    /// §23.1.5.1 — Array iterator over a TA whose underlying
    /// resizable buffer has gone out-of-bounds; `next()` throws
    /// TypeError per the ES2024 ValidateTypedArray re-check.
    typed_array_oob,
    /// §23.1.5.2.1 step 6.d.iii — \`Get(O, Pk)\` (or the prior
    /// \`Get(O, \"length\")\`) ran a user getter that threw. The
    /// exception is already deposited in \`realm.pending_exception\`;
    /// the per-kind next() wrappers surface it via \`error.NativeThrew\`.
    propagated,
};

fn arrayLikeIterStep(realm: *Realm, this_value: Value) StepOutcome {
    const it = heap_mod.valueAsPlainObject(this_value) orelse return .done;
    const state = it.array_like_iter orelse return .done;
    if (state.done) return .done;
    const target = state.target;
    const idx: i32 = @intCast(state.idx);

    var length: i64 = 0;
    var elem: Value = Value.undefined_;
    if (heap_mod.valueAsPlainObject(target)) |obj| {
        // TypedArrays expose `length` via an accessor on
        // %TypedArray%.prototype and indexed access via
        // typed-view dispatch; iterate them directly off the
        // typed_view to avoid the per-step accessor call.
        if (obj.typed_view) |tv| {
            // §23.2.5.1 / §10.4.5 — recompute the live length on
            // every step. A length-tracking view's backing buffer
            // may have been grown or shrunk between iterations;
            // a fixed-length view's buffer may have shrunk so the
            // view is now OOB — throw TypeError per §23.1.5.1
            // step 3.e.iii (the Array iterator's per-step
            // ValidateTypedArray re-check, ES2024).
            const buf = tv.viewed.array_buffer orelse {
                state.done = true;
                return .typed_array_oob;
            };
            const elem_size = tv.kind.elementSize();
            const is_oob = if (tv.length_tracking)
                tv.byte_offset > buf.len
            else
                tv.byte_offset + tv.length * elem_size > buf.len;
            if (is_oob) {
                state.done = true;
                return .typed_array_oob;
            }
            const live_len: usize = if (tv.length_tracking)
                (buf.len - tv.byte_offset) / elem_size
            else
                tv.length;
            length = @intCast(live_len);
            if (idx >= 0 and @as(usize, @intCast(idx)) < live_len) {
                const off = tv.byte_offset + @as(usize, @intCast(idx)) * elem_size;
                if (off + elem_size <= buf.len) {
                    elem = readTypedElement(realm, buf, tv.kind, off);
                }
            }
        } else {
            // §23.1.5.2.1 step 6 — \`length = LengthOfArrayLike(O)\`,
            // which routes through \`[[Get]]\` and therefore accessors.
            const len_v = intrinsics.getPropertyChain(realm, obj, "length") catch {
                state.done = true;
                return .propagated;
            };
            if (len_v.isInt32()) length = len_v.asInt32() else if (len_v.isDouble()) length = @intFromFloat(len_v.asDouble());
            if (idx < length) {
                var ibuf: [16]u8 = undefined;
                const islice = std.fmt.bufPrint(&ibuf, "{d}", .{idx}) catch unreachable;
                // §23.1.5.2.1 step 6.d.iii — \`Get(O, Pk)\` walks
                // accessors. A throw from the getter propagates
                // through the surrounding for-of as a user-visible
                // exception.
                elem = intrinsics.getPropertyChain(realm, obj, islice) catch {
                    state.done = true;
                    return .propagated;
                };
            }
        }
    } else if (target.isString()) {
        const s: *@import("../string.zig").JSString = @ptrCast(@alignCast(target.asString()));
        length = @intCast(@min(s.bytes.len, std.math.maxInt(i32)));
        // §22.1.5.2.1 StringIterator.next — advance by encoded
        // codepoint length, not by byte. Cynic stores strings as
        // WTF-8; a leading byte of \`0xxxxxxx\` is 1 byte,
        // \`110xxxxx\` 2, \`1110xxxx\` 3, \`11110xxx\` 4.
        // Yielding a multi-byte slice keeps astral codepoints
        // intact (4-byte WTF-8 sequences). Invalid leading byte
        // falls back to a single-byte step so we don't loop.
        const start: usize = @intCast(idx);
        if (start < s.bytes.len) {
            const lead = s.bytes[start];
            const cp_len: usize = if (lead & 0x80 == 0) 1 else if (lead & 0xE0 == 0xC0) 2 else if (lead & 0xF0 == 0xE0) 3 else if (lead & 0xF8 == 0xF0) 4 else 1;
            const end = @min(start + cp_len, s.bytes.len);
            const sub = realm.heap.allocateString(s.bytes[start..end]) catch return .done;
            elem = Value.fromString(sub);
            // Bump state.idx by codepoint length now; the
            // tail of arrayLikeIterStep would otherwise bump by 1
            // and yield the trailing bytes of the same codepoint
            // on the next step.
            state.idx = @intCast(end);
            if (idx >= length) {
                state.done = true;
                return .done;
            }
            return .{ .step = .{ .idx = idx, .value = elem, .length = length } };
        }
    } else {
        return .done;
    }
    if (idx >= length) {
        state.done = true;
        return .done;
    }
    state.idx = @intCast(idx + 1);
    return .{ .step = .{ .idx = idx, .value = elem, .length = length } };
}

fn arrayLikeIterValuesNext(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = args;
    switch (arrayLikeIterStep(realm, this_value)) {
        .step => |s| return iterResult(realm, s.value, false) catch return error.OutOfMemory,
        .typed_array_oob => return throwTypeError(realm, "TypedArray iterator: backing buffer is out-of-bounds"),
        .propagated => return error.NativeThrew,
        .done => return iterResult(realm, Value.undefined_, true) catch return error.OutOfMemory,
    }
}
fn arrayLikeIterKeysNext(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = args;
    switch (arrayLikeIterStep(realm, this_value)) {
        .step => |s| return iterResult(realm, Value.fromInt32(s.idx), false) catch return error.OutOfMemory,
        .typed_array_oob => return throwTypeError(realm, "TypedArray iterator: backing buffer is out-of-bounds"),
        .propagated => return error.NativeThrew,
        .done => return iterResult(realm, Value.undefined_, true) catch return error.OutOfMemory,
    }
}
fn arrayLikeIterEntriesNext(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = args;
    switch (arrayLikeIterStep(realm, this_value)) {
        .step => |s| {
            const arr = realm.heap.allocateObject() catch return error.OutOfMemory;
            arr.prototype = realm.intrinsics.array_prototype;
            arr.markAsArrayExotic(realm.allocator) catch return error.OutOfMemory;
            arr.set(realm.allocator, "0", Value.fromInt32(s.idx)) catch return error.OutOfMemory;
            arr.set(realm.allocator, "1", s.value) catch return error.OutOfMemory;
            arr.set(realm.allocator, "length", Value.fromInt32(2)) catch return error.OutOfMemory;
            return iterResult(realm, heap_mod.taggedObject(arr), false) catch return error.OutOfMemory;
        },
        .typed_array_oob => return throwTypeError(realm, "TypedArray iterator: backing buffer is out-of-bounds"),
        .propagated => return error.NativeThrew,
        .done => return iterResult(realm, Value.undefined_, true) catch return error.OutOfMemory,
    }
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
            .thrown => |ex| {
                realm.pending_exception = ex;
                return error.NativeThrew;
            },
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
            .thrown => |ex| {
                realm.pending_exception = ex;
                return error.NativeThrew;
            },
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
    // §24.1.1.1 Map constructor steps 5-7:
    //
    //   5. If iterable is undefined or null, return map.
    //   6. Else: Let adder be ? Get(map, "set").
    //              If IsCallable(adder) is false, throw TypeError.
    //              Return ? AddEntriesFromIterable(map, iterable, adder).
    //
    // The `Get(map, "set")` MUST NOT fire when iterable is
    // absent — `Map/get-set-method-failure.js` poisons the
    // accessor and asserts `new Map()` does not throw.
    if (args.len == 0 or args[0].isUndefined() or args[0].isNull()) {
        return this_value;
    }
    const adder_v = intrinsics.getPropertyChain(realm, inst, "set") catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.NativeThrew,
    };
    const adder = heap_mod.valueAsFunction(adder_v) orelse {
        // §24.1.1.1 step 7.b — non-callable adder is TypeError.
        return throwTypeError(realm, "Map: 'set' is not callable");
    };
    // §24.1.1.2 AddEntriesFromIterable. Wraps the iteration in
    // an IteratorClose for every abrupt path:
    //   - `next()` throws → propagate (no close; the iterator
    //     itself is the source of the throw and is already
    //     considered done per §7.4.6 step 6.b).
    //   - `next` result isn't an Object → TypeError + close.
    //   - `nextItem` is not Object → TypeError + close.
    //   - `Get(nextItem, "0")` or `"1"` throws → close + propagate.
    //   - `adder.call(map, k, v)` throws → close + propagate.
    const iter_v = interpreter.openIterator(realm.allocator, realm, args[0]) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.NotIterable => return throwTypeError(realm, "Map constructor: argument is not iterable"),
        error.Propagated => return error.NativeThrew,
        else => return error.NativeThrew,
    };
    return mapAddEntriesFromIterable(realm, this_value, iter_v, adder);
}

/// §24.1.1.2 AddEntriesFromIterable — shared by Map / WeakMap
/// constructors. Drives the iterator protocol, fetching `[0]`
/// / `[1]` from each entry and invoking `adder.call(target,
/// k, v)`. Every abrupt path runs §7.4.6 IteratorClose, which
/// invokes `iter.return()` if present. A throwing `return`
/// is suppressed in favor of the original abrupt (spec step
/// 7 of IteratorClose — "If completion is throw … return
/// completion (NormalCompletion(result) is discarded)").
fn mapAddEntriesFromIterable(
    realm: *Realm,
    target_v: Value,
    iter_v: Value,
    adder: *JSFunction,
) NativeError!Value {
    const iter_obj = heap_mod.valueAsPlainObject(iter_v) orelse return throwTypeError(realm, "Map iterator did not return an object");
    const max_iter: usize = 1 << 24;
    var step: usize = 0;
    while (step < max_iter) : (step += 1) {
        const next_v = iter_obj.get("next");
        const next_fn = heap_mod.valueAsFunction(next_v) orelse return throwTypeError(realm, "Map iterator missing next");
        const outcome = interpreter.callJSFunction(realm.allocator, realm, next_fn, iter_v, &.{}) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.NativeThrew,
        };
        const result_v = switch (outcome) {
            .value, .yielded => |v| v,
            .thrown => |ex| {
                // `next()` throw — the iterator is already
                // considered "done" per §7.4.6 step 6.b, so we
                // don't invoke IteratorClose.
                realm.pending_exception = ex;
                return error.NativeThrew;
            },
        };
        const result = heap_mod.valueAsPlainObject(result_v) orelse {
            return throwTypeError(realm, "Map iterator next did not return an object");
        };
        // §7.4.5 IteratorComplete uses `Get(iterResult, "done")`
        // — fires accessor getters. Routes through
        // `getPropertyChain` so a throwing `get done()` propagates.
        const done_v = intrinsics.getPropertyChain(realm, result, "done") catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.NativeThrew,
        };
        if (done_v.toBooleanPrimitive()) break;
        // §7.4.4 IteratorValue uses `Get(iterResult, "value")`,
        // which must fire user accessors so
        // `{ get value() { throw } }` propagates
        // (`iterator-value-failure.js`).
        const entry_v_raw = intrinsics.getPropertyChain(realm, result, "value") catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.NativeThrew,
        };
        // §24.1.1.2 step 1.c — IteratorValue result must be an
        // Object; otherwise throw TypeError and IteratorClose
        // (`iterator-items-are-not-object-close-iterator.js`).
        const entry = heap_mod.valueAsPlainObject(entry_v_raw) orelse {
            invokeIteratorReturn(realm, iter_obj, iter_v);
            return throwTypeError(realm, "Map iterator value must be an object");
        };
        // §7.3.5 Get — fires accessor getters. A throwing
        // `get item[0]` / `get item[1]` must close the iterator
        // (`iterator-item-first-entry-returns-abrupt.js`,
        //  `iterator-item-second-entry-returns-abrupt.js`).
        const key = intrinsics.getPropertyChain(realm, entry, "0") catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                invokeIteratorReturn(realm, iter_obj, iter_v);
                return error.NativeThrew;
            },
        };
        const val = intrinsics.getPropertyChain(realm, entry, "1") catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                invokeIteratorReturn(realm, iter_obj, iter_v);
                return error.NativeThrew;
            },
        };
        // §24.1.1.2 step 1.h — `Call(adder, map, « key, value »)`.
        // Routes through the user-installed `Map.prototype.set`
        // so an overridden `set` (`iterable-calls-set.js`) sees
        // every entry; a throwing `set` is closed
        // (`iterator-close-after-set-failure.js`).
        const adder_args = [_]Value{ key, val };
        const set_outcome = interpreter.callJSFunction(realm.allocator, realm, adder, target_v, &adder_args) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                invokeIteratorReturn(realm, iter_obj, iter_v);
                return error.NativeThrew;
            },
        };
        switch (set_outcome) {
            .value, .yielded => {},
            .thrown => |ex| {
                realm.pending_exception = ex;
                invokeIteratorReturn(realm, iter_obj, iter_v);
                return error.NativeThrew;
            },
        }
    }
    return target_v;
}

/// §7.4.6 IteratorClose — when called with an abrupt completion,
/// invoke `iter.return()` if present; a throwing `return` is
/// SUPPRESSED (step 7 of IteratorClose: "If completion is throw,
/// return completion"). The pre-existing pending exception is
/// what propagates.
fn invokeIteratorReturn(realm: *Realm, iter_obj: *@import("../object.zig").JSObject, iter_v: Value) void {
    const ret_v = intrinsics.getPropertyChain(realm, iter_obj, "return") catch return;
    if (ret_v.isUndefined() or ret_v.isNull()) return;
    const ret_fn = heap_mod.valueAsFunction(ret_v) orelse return;
    // Preserve the abrupt that brought us here; `callJSFunction`
    // can flip `pending_exception` if `return` itself throws, and
    // we must drop that throw to keep the original surfacing.
    const saved_ex = realm.pending_exception;
    const outcome = interpreter.callJSFunction(realm.allocator, realm, ret_fn, iter_v, &.{}) catch {
        realm.pending_exception = saved_ex;
        return;
    };
    realm.pending_exception = saved_ex;
    _ = outcome;
}

fn mapDataOf(this_value: Value) ?*@import("../object.zig").MapData {
    const obj = heap_mod.valueAsPlainObject(this_value) orelse return null;
    const d = obj.map_data orelse return null;
    // §24.1.3 RequireInternalSlot([[MapData]]) — a WeakMap shares
    // the same Zig slot but is tagged `is_weak`. The check rejects
    // `Map.prototype.get.call(new WeakMap(), …)` per spec.
    if (d.is_weak) return null;
    return d;
}

/// §24.1.1.{8,12} CanonicalizeKeyedCollectionKey — Map / Set
/// store -0 as +0. The conversion happens before the key is
/// observed by user code (e.g. the callback to
/// `getOrInsertComputed` sees +0, not -0) and before equality
/// is checked against existing entries.
fn canonicalizeKey(v: Value) Value {
    if (v.isDouble() and v.asDouble() == 0.0) return Value.fromInt32(0);
    return v;
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
    // §24.1.3.9 step 3 — `RequireInternalSlot(M, [[MapData]])`
    // rejects a WeakMap (which has [[WeakMapData]] instead).
    // Cynic stores both under `map_data`, distinguished by
    // `is_weak`; route through `mapDataOf` so the
    // `Map.prototype.set.call(new WeakMap(), …)` fixture throws.
    if (mapDataOf(this_value) == null) return throwTypeError(realm, "Map.prototype.set called on non-Map");
    const inst = heap_mod.valueAsPlainObject(this_value).?;
    mapSetInternal(realm, inst, canonicalizeKey(argOr(args, 0, Value.undefined_)), argOr(args, 1, Value.undefined_)) catch return error.OutOfMemory;
    return this_value;
}

fn mapGet(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const d = mapDataOf(this_value) orelse return throwTypeError(realm, "Map.prototype.get called on non-Map");
    if (mapEntryIndex(d, canonicalizeKey(argOr(args, 0, Value.undefined_)))) |i| return d.entries.items[i].value;
    return Value.undefined_;
}

/// Stage-3 upsert — `Map.prototype.getOrInsert(key, value)`.
/// Returns the existing value if `key` is present, otherwise
/// inserts `value` and returns it. The default is materialised
/// eagerly; for a callback-based version use
/// `getOrInsertComputed`.
fn mapGetOrInsert(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const inst = heap_mod.valueAsPlainObject(this_value) orelse return throwTypeError(realm, "Map.prototype.getOrInsert called on non-Map");
    if (inst.map_data == null) return throwTypeError(realm, "Map.prototype.getOrInsert called on non-Map");
    const d = inst.map_data.?;
    // §24.1.5 step 2 — `RequireInternalSlot(M, [[MapData]])` rejects
    // a WeakMap (which has [[WeakMapData]] instead). Cynic stores
    // both under `map_data`, distinguished by `is_weak`; reject the
    // weak path explicitly so `Map.prototype.getOrInsert.call(weakMap, …)`
    // throws TypeError per spec.
    if (d.is_weak) return throwTypeError(realm, "Map.prototype.getOrInsert called on a WeakMap");
    // §24.1.4.{N} upsert — CanonicalizeKeyedCollectionKey on
    // the lookup key, so -0 finds the +0 entry and a fresh
    // insert stores +0.
    const key = canonicalizeKey(argOr(args, 0, Value.undefined_));
    const default_v = argOr(args, 1, Value.undefined_);
    if (mapEntryIndex(d, key)) |i| return d.entries.items[i].value;
    mapSetInternal(realm, inst, key, default_v) catch return error.OutOfMemory;
    return default_v;
}

/// Stage-3 upsert — `Map.prototype.getOrInsertComputed(key, callbackfn)`.
/// Like `getOrInsert` but the default value comes from
/// `callbackfn(key)`, invoked only on absence. `callbackfn` must
/// be callable per the proposal.
fn mapGetOrInsertComputed(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const inst = heap_mod.valueAsPlainObject(this_value) orelse return throwTypeError(realm, "Map.prototype.getOrInsertComputed called on non-Map");
    if (inst.map_data == null) return throwTypeError(realm, "Map.prototype.getOrInsertComputed called on non-Map");
    const d = inst.map_data.?;
    // §24.1.5 step 2 — RequireInternalSlot rejects WeakMap. See
    // `mapGetOrInsert` above for the same gate.
    if (d.is_weak) return throwTypeError(realm, "Map.prototype.getOrInsertComputed called on a WeakMap");
    const raw_key = argOr(args, 0, Value.undefined_);
    // Stage-3 upsert: per CanonicalizeKeyedCollectionKey, -0
    // canonicalizes to +0 before any further use. The callback
    // and the stored entry both see the canonical form.
    const key = canonicalizeKey(raw_key);
    const cb_v = argOr(args, 1, Value.undefined_);
    const cb = heap_mod.valueAsFunction(cb_v) orelse return throwTypeError(realm, "callbackfn must be a function");
    if (mapEntryIndex(d, key)) |i| return d.entries.items[i].value;
    // Spec: invoke `cb(key)` BEFORE we re-check membership. The
    // callback can mutate the Map; the proposal says "use the
    // newly-computed value regardless" (overwrites any concurrent
    // insert).
    // §24.1.5 / §24.3.5 (proposal) step 6 — `Call(callbackfn, undefined, « key »)`.
    // The `this` argument is `undefined`, NOT the Map instance.
    const cb_args = [_]Value{key};
    const outcome = interpreter.callJSFunction(realm.allocator, realm, cb, Value.undefined_, &cb_args) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.NativeThrew,
    };
    const value = switch (outcome) {
        .value, .yielded => |v| v,
        // §27.5.4 (proposal) — propagate the callback's exception.
        // The runtime returns `.thrown` with the thrown value; we
        // must pin it on `realm.pending_exception` before raising
        // `NativeThrew`, otherwise the dispatcher sees a generic
        // "native error" instead of the user's `Error`.
        .thrown => |ex| {
            realm.pending_exception = ex;
            return error.NativeThrew;
        },
    };
    mapSetInternal(realm, inst, key, value) catch return error.OutOfMemory;
    return value;
}

fn mapHas(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const d = mapDataOf(this_value) orelse return throwTypeError(realm, "Map.prototype.has called on non-Map");
    return Value.fromBool(mapEntryIndex(d, canonicalizeKey(argOr(args, 0, Value.undefined_))) != null);
}

fn mapDelete(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const d = mapDataOf(this_value) orelse return throwTypeError(realm, "Map.prototype.delete called on non-Map");
    if (mapEntryIndex(d, canonicalizeKey(argOr(args, 0, Value.undefined_)))) |i| {
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
            .thrown => |ex| {
                realm.pending_exception = ex;
                return error.NativeThrew;
            },
        }
    }
    return Value.undefined_;
}

// ── §24.3 WeakMap (strong-ref impl — observable behaviour matches; no GC weakness yet) ──

pub fn installWeakMap(realm: *Realm) !void {
    // §24.3.1 — `WeakMap.length` is 0 (the iterable arg is
    // optional and so is excluded from the [[Construct]] arity
    // per §15.1.3). Matches `WeakMap/length.js`.
    const r = try installConstructor(realm, .{
        .name = "WeakMap", .ctor = weakMapConstructor, .arity = 0,
        .to_string_tag = "WeakMap",
    });
    _ = r.ctor;
    const proto = r.proto;

    try installNativeMethodOnProto(realm, proto, "set", weakMapSet, 2);
    try installNativeMethodOnProto(realm, proto, "get", weakMapGet, 1);
    try installNativeMethodOnProto(realm, proto, "has", weakMapHas, 1);
    try installNativeMethodOnProto(realm, proto, "delete", weakMapDelete, 1);
    // PRE-STAGE-4 PROPOSAL — `upsert` (Stage 3 as of 2026-05).
    // Gated on the per-realm feature flag — see the Map proto
    // installer above for the design notes.
    if (realm.feature_flags.contains(.upsert)) {
        try installNativeMethodOnProto(realm, proto, "getOrInsert", weakMapGetOrInsert, 2);
        try installNativeMethodOnProto(realm, proto, "getOrInsertComputed", weakMapGetOrInsertComputed, 2);
    }
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

/// §6.1.5 CanBeHeldWeakly — the gate that WeakMap / WeakSet keys
/// must pass. Objects qualify unconditionally; for Symbols, only
/// non-registered ones (i.e. `Symbol(desc)`, not `Symbol.for(k)`)
/// can be held weakly — registered symbols are interned globally
/// and would prevent GC of the WeakMap's hidden table.
fn canBeHeldWeakly(key: Value) bool {
    // `Value.isObject()` is true for every heap-kind value (plain
    // objects, functions, symbols, bigints) — so we have to pick
    // the kinds apart explicitly. Symbols need the registered-vs-
    // not check; everything else falls back to "is it an Object?"
    // which for §6.1.5 means plain Object or callable (Function).
    if (heap_mod.valueAsSymbol(key)) |sym| return !sym.is_registered;
    if (heap_mod.valueAsPlainObject(key) != null) return true;
    if (heap_mod.valueAsFunction(key) != null) return true;
    return false;
}

fn weakMapGetOrInsert(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const inst = heap_mod.valueAsPlainObject(this_value) orelse return throwTypeError(realm, "WeakMap.prototype.getOrInsert called on non-WeakMap");
    const d = inst.map_data orelse return throwTypeError(realm, "WeakMap.prototype.getOrInsert called on non-WeakMap");
    if (!d.is_weak) return throwTypeError(realm, "WeakMap.prototype.getOrInsert called on non-WeakMap");
    const key = argOr(args, 0, Value.undefined_);
    if (!canBeHeldWeakly(key)) return throwTypeError(realm, "WeakMap key cannot be held weakly");
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
    if (!canBeHeldWeakly(key)) return throwTypeError(realm, "WeakMap key cannot be held weakly");
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
    // §24.3.1.1 WeakMap constructor steps 5-7 — same shape as
    // Map: `Get(map, "set")` MUST NOT fire when iterable is
    // absent. `WeakMap/get-set-method-failure.js` poisons the
    // accessor and asserts `new WeakMap()` / `new WeakMap(null)`
    // don't throw.
    if (args.len == 0 or args[0].isUndefined() or args[0].isNull()) {
        return this_value;
    }
    const adder_v = intrinsics.getPropertyChain(realm, inst, "set") catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.NativeThrew,
    };
    const adder = heap_mod.valueAsFunction(adder_v) orelse {
        // §24.3.1.1 step 7.b — non-callable adder is TypeError.
        return throwTypeError(realm, "WeakMap: 'set' is not callable");
    };
    const iter_v = interpreter.openIterator(realm.allocator, realm, args[0]) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.NotIterable => return throwTypeError(realm, "WeakMap constructor: argument is not iterable"),
        error.Propagated => return error.NativeThrew,
        else => return error.NativeThrew,
    };
    return mapAddEntriesFromIterable(realm, this_value, iter_v, adder);
}

fn weakMapSet(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    // §24.3.3.5 WeakMap.prototype.set step 3 — RequireInternalSlot
    // rejects a Map (whose `map_data.is_weak` is false). Route
    // through `weakMapDataOf` so `WeakMap.prototype.set.call(
    // new Map(), …)` throws TypeError per spec.
    if (weakMapDataOf(this_value) == null) return throwTypeError(realm, "WeakMap.prototype.set called on non-WeakMap");
    const inst = heap_mod.valueAsPlainObject(this_value).?;
    const key = argOr(args, 0, Value.undefined_);
    // §24.3.3.5 step 4 — `If CanBeHeldWeakly(key) is false,
    // throw a TypeError`. §6.1.5 — Objects pass unconditionally;
    // non-registered Symbols pass; primitives and registered
    // Symbols throw.
    if (!canBeHeldWeakly(key)) return throwTypeError(realm, "WeakMap key cannot be held weakly");
    mapSetInternal(realm, inst, key, argOr(args, 1, Value.undefined_)) catch return error.OutOfMemory;
    return this_value;
}

// ── §24.4 WeakSet ───────────────────────────────────────────────────────────

pub fn installWeakSet(realm: *Realm) !void {
    // §24.4.1 — `WeakSet.length` is 0 (the iterable arg is
    // optional and so is excluded from the [[Construct]] arity
    // per §15.1.3). Matches `WeakSet/length.js`.
    const r = try installConstructor(realm, .{
        .name = "WeakSet", .ctor = weakSetConstructor, .arity = 0,
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
    // §24.4.1.1 WeakSet constructor steps 5-7 — same shape as
    // Map / WeakMap: `Get(set, "add")` MUST NOT fire when iterable
    // is absent. `WeakSet/get-add-method-failure.js` poisons the
    // accessor and asserts `new WeakSet()` / `new WeakSet(null)`
    // don't throw.
    if (args.len == 0 or args[0].isUndefined() or args[0].isNull()) {
        return this_value;
    }
    const adder_v = intrinsics.getPropertyChain(realm, inst, "add") catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.NativeThrew,
    };
    const adder = heap_mod.valueAsFunction(adder_v) orelse {
        // §24.4.1.1 step 7.b — non-callable adder is TypeError.
        return throwTypeError(realm, "WeakSet: 'add' is not callable");
    };
    const iter_v = interpreter.openIterator(realm.allocator, realm, args[0]) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.NotIterable => return throwTypeError(realm, "WeakSet constructor: argument is not iterable"),
        error.Propagated => return error.NativeThrew,
        else => return error.NativeThrew,
    };
    return weakSetAddValuesFromIterable(realm, this_value, iter_v, adder);
}

/// §24.4.1.1 AddValuesFromIterable (the WeakSet analogue of
/// §24.1.1.2 AddEntriesFromIterable). Drives the iterator
/// protocol and invokes `adder.call(target, value)` per item,
/// closing the iterator on every abrupt path. Same shape as
/// `mapAddEntriesFromIterable` but each item is a bare value
/// rather than a [key, value] entry — there's no `Get(item, "0")`.
fn weakSetAddValuesFromIterable(
    realm: *Realm,
    target_v: Value,
    iter_v: Value,
    adder: *JSFunction,
) NativeError!Value {
    const iter_obj = heap_mod.valueAsPlainObject(iter_v) orelse return throwTypeError(realm, "WeakSet iterator did not return an object");
    const max_iter: usize = 1 << 24;
    var step: usize = 0;
    while (step < max_iter) : (step += 1) {
        const next_v = iter_obj.get("next");
        const next_fn = heap_mod.valueAsFunction(next_v) orelse return throwTypeError(realm, "WeakSet iterator missing next");
        const outcome = interpreter.callJSFunction(realm.allocator, realm, next_fn, iter_v, &.{}) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.NativeThrew,
        };
        const result_v = switch (outcome) {
            .value, .yielded => |v| v,
            .thrown => |ex| {
                // §7.4.6 step 6.b — a throwing `next()` leaves
                // the iterator already "done", so we don't
                // invoke IteratorClose.
                realm.pending_exception = ex;
                return error.NativeThrew;
            },
        };
        const result = heap_mod.valueAsPlainObject(result_v) orelse {
            return throwTypeError(realm, "WeakSet iterator next did not return an object");
        };
        const done_v = intrinsics.getPropertyChain(realm, result, "done") catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.NativeThrew,
        };
        if (done_v.toBooleanPrimitive()) break;
        // §7.4.4 IteratorValue — `Get(iterResult, "value")` fires
        // user accessors, so `{ get value() { throw } }`
        // propagates (`iterator-value-failure.js`).
        const value_v = intrinsics.getPropertyChain(realm, result, "value") catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.NativeThrew,
        };
        // §24.4.1.1 step 8.d — `Call(adder, set, « nextValue »)`.
        // Routes through the user-installed `WeakSet.prototype.add`
        // so an overridden `add` sees every value, and a throwing
        // `add` closes the iterator
        // (`iterator-close-after-add-failure.js`).
        const adder_args = [_]Value{value_v};
        const add_outcome = interpreter.callJSFunction(realm.allocator, realm, adder, target_v, &adder_args) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                invokeIteratorReturn(realm, iter_obj, iter_v);
                return error.NativeThrew;
            },
        };
        switch (add_outcome) {
            .value, .yielded => {},
            .thrown => |ex| {
                realm.pending_exception = ex;
                invokeIteratorReturn(realm, iter_obj, iter_v);
                return error.NativeThrew;
            },
        }
    }
    return target_v;
}

fn weakSetAdd(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const inst = heap_mod.valueAsPlainObject(this_value) orelse return throwTypeError(realm, "WeakSet.prototype.add called on non-WeakSet");
    const d = inst.set_data orelse return throwTypeError(realm, "WeakSet.prototype.add called on non-WeakSet");
    if (!d.is_weak) return throwTypeError(realm, "WeakSet.prototype.add called on non-WeakSet");
    const v = argOr(args, 0, Value.undefined_);
    // §24.4.3.1 step 3 — `If CanBeHeldWeakly(value) is false,
    // throw a TypeError`. §6.1.5 — Objects pass unconditionally;
    // non-registered Symbols pass; primitives and registered
    // Symbols throw.
    if (!canBeHeldWeakly(v)) return throwTypeError(realm, "WeakSet value cannot be held weakly");
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
    const ctor = r.ctor;
    const proto = r.proto;
    // §24.2.2.2 get Set [ @@species ] returns this.
    try installSpeciesGetter(realm, ctor);

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
        const iter_v = interpreter.openIterator(realm.allocator, realm, args[0]) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.NotIterable => return throwTypeError(realm, "Set constructor: argument is not iterable"),
            error.Propagated => return error.NativeThrew,
            else => return error.NativeThrew,
        };
        const iter_obj = heap_mod.valueAsPlainObject(iter_v) orelse return throwTypeError(realm, "Set iterator did not return an object");
        const max_iter: usize = 1 << 24;
        var step: usize = 0;
        while (step < max_iter) : (step += 1) {
            const next_v = iter_obj.get("next");
            const next_fn = heap_mod.valueAsFunction(next_v) orelse return throwTypeError(realm, "Set iterator missing next");
            const outcome = interpreter.callJSFunction(realm.allocator, realm, next_fn, iter_v, &.{}) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return error.NativeThrew,
            };
            const result_v = switch (outcome) {
                .value, .yielded => |v| v,
                .thrown => |ex| {
                    realm.pending_exception = ex;
                    return error.NativeThrew;
                },
            };
            const result = heap_mod.valueAsPlainObject(result_v) orelse return throwTypeError(realm, "Set iterator next did not return an object");
            if (result.get("done").toBooleanPrimitive()) break;
            try setAddInternal(realm, inst, result.get("value"));
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
    setAddInternal(realm, inst, canonicalizeKey(argOr(args, 0, Value.undefined_))) catch return error.OutOfMemory;
    return this_value;
}

fn setHas(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const d = setDataOf(this_value) orelse return throwTypeError(realm, "Set.prototype.has called on non-Set");
    return Value.fromBool(setIndex(d, canonicalizeKey(argOr(args, 0, Value.undefined_))) != null);
}

fn setDelete(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const d = setDataOf(this_value) orelse return throwTypeError(realm, "Set.prototype.delete called on non-Set");
    if (setIndex(d, canonicalizeKey(argOr(args, 0, Value.undefined_)))) |i| {
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
    /// The set-like's reported `.size` (ToIntegerOrInfinity).
    /// Used by §24.2.4.5 step 5 to branch on which side to
    /// iterate during intersection / difference / etc.
    size: usize,
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
    // §24.2.1.2 GetSetRecord step 6 — ToIntegerOrInfinity(size).
    // Used by the spec to branch on which side to iterate
    // during intersection / difference / etc. Route through
    // the accessor chain so `get size() { return 2; }` getters
    // fire instead of the bare data-slot lookup returning
    // undefined → 0. ToNumber must propagate throws (Symbol etc.)
    // AND NaN must surface as a TypeError per §24.2.1.2 step 5.
    const size_v = try intrinsics.getPropertyChain(realm, obj, "size");
    const size_n = try intrinsics.toNumber(realm, size_v);
    const size_d: f64 = if (size_n.isInt32())
        @floatFromInt(size_n.asInt32())
    else if (size_n.isDouble())
        size_n.asDouble()
    else
        0;
    if (std.math.isNan(size_d)) {
        var buf: [128]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "Set.prototype.{s}: argument is not set-like (size is NaN)", .{op}) catch op;
        return throwTypeError(realm, msg);
    }
    const size_usize: usize = if (size_d < 0)
        0
    else if (std.math.isInf(size_d))
        std.math.maxInt(usize)
    else
        @intFromFloat(@trunc(size_d));
    return .{ .has = has_fn, .keys = keys_fn, .obj = value, .size = size_usize };
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
    // §24.2.4.5 step 5 — branch on size. When `this` is smaller
    // (or equal), iterate `this` and probe `other.has(value)`.
    // Otherwise iterate `other`'s keys() and probe `this.has`.
    // The second path avoids needlessly invoking a possibly-
    // poisoned `has` on `other` when the receiver is larger.
    const this_size = activeSetSize(this_d);
    if (this_size <= sl.size) {
        var i: usize = 0;
        while (i < this_d.entries.items.len) : (i += 1) {
            const e = this_d.entries.items[i];
            if (e.deleted) continue;
            if (try setLikeHas(realm, sl, e.value)) {
                setAddInternal(realm, out, e.value) catch return error.OutOfMemory;
            }
        }
    } else {
        // Iterate other.keys() and check whether each is in this.
        const Ctx = struct {
            this_d: *@import("../object.zig").SetData,
            out: *@import("../object.zig").JSObject,
            realm: *Realm,
        };
        var ctx = Ctx{ .this_d = this_d, .out = out, .realm = realm };
        try setLikeForEachKey(realm, sl, &ctx, struct {
            fn cb(c: *Ctx, key: Value) NativeError!void {
                const k = canonicalizeKey(key);
                if (setIndex(c.this_d, k) != null) {
                    setAddInternal(c.realm, c.out, k) catch return error.OutOfMemory;
                }
            }
        }.cb);
    }
    return heap_mod.taggedObject(out);
}

/// Count live (non-deleted) entries in a Set's data.
fn activeSetSize(d: *@import("../object.zig").SetData) usize {
    var n: usize = 0;
    for (d.entries.items) |e| {
        if (!e.deleted) n += 1;
    }
    return n;
}

/// Iterate the keys of a set-like by calling its `keys()` and
/// stepping the resulting iterator.
fn setLikeForEachKey(
    realm: *Realm,
    sl: SetLike,
    ctx: anytype,
    callback: fn (@TypeOf(ctx), Value) NativeError!void,
) NativeError!void {
    // sl.keys is a JSFunction; call it with `this = sl.obj` to
    // get the iterator. Then step via `.next()` until done.
    const iter_v = blk: {
        const cb_args = [_]Value{};
        const outcome = interpreter.callJSFunction(
            realm.allocator,
            realm,
            sl.keys,
            sl.obj,
            &cb_args,
        ) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.NativeThrew,
        };
        break :blk switch (outcome) {
            .value, .yielded => |v| v,
            .thrown => return error.NativeThrew,
        };
    };
    const iter_obj = heap_mod.valueAsPlainObject(iter_v) orelse return throwTypeError(realm, "set-like keys() did not return an Object");
    const next_v = iter_obj.get("next");
    const next_fn = heap_mod.valueAsFunction(next_v) orelse return throwTypeError(realm, "set-like iterator has no next");
    while (true) {
        const outcome = interpreter.callJSFunction(
            realm.allocator,
            realm,
            next_fn,
            iter_v,
            &.{},
        ) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.NativeThrew,
        };
        const step_v = switch (outcome) {
            .value, .yielded => |v| v,
            .thrown => return error.NativeThrew,
        };
        const step_obj = heap_mod.valueAsPlainObject(step_v) orelse return throwTypeError(realm, "iterator step did not return an Object");
        if (intrinsics.toBoolean(step_obj.get("done"))) break;
        try callback(ctx, step_obj.get("value"));
    }
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
    // §24.2.4.7 step 4 — fast-reject: a larger set can't be a
    // subset of a smaller one.
    if (activeSetSize(this_d) > sl.size) return Value.false_;

    var i: usize = 0;
    while (i < this_d.entries.items.len) : (i += 1) {
        const e = this_d.entries.items[i];
        if (e.deleted) continue;
        if (!try setLikeHas(realm, sl, e.value)) return Value.false_;
    }
    return Value.true_;
}

fn setIsSupersetOf(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const this_d = setDataOf(this_value) orelse return throwTypeError(realm, "Set.prototype.isSupersetOf called on non-Set");
    const sl = try validateSetLike(realm, "isSupersetOf", argOr(args, 0, Value.undefined_));
    // §24.2.4.9 step 4 — fast-reject: a smaller set can't be a
    // superset of a larger one. Avoids invoking the set-like's
    // `keys()` iterator unnecessarily.
    if (activeSetSize(this_d) < sl.size) return Value.false_;

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

    // §24.2.4.4 step 5 — pick the smaller side to iterate.
    // When `this` is smaller (or equal), iterate `this` + probe
    // `other.has`. Otherwise iterate `other.keys()` + check
    // membership in `this`. Avoids calling `other.has` for
    // every element of a much-larger receiver.
    if (activeSetSize(this_d) <= sl.size) {
        var i: usize = 0;
        while (i < this_d.entries.items.len) : (i += 1) {
            const e = this_d.entries.items[i];
            if (e.deleted) continue;
            if (try setLikeHas(realm, sl, e.value)) return Value.false_;
        }
        return Value.true_;
    }
    // Larger receiver: iterate the set-like and check each
    // key against this. We carry the result via a stack-side
    // boolean to keep the callback free of captures.
    const Ctx = struct { this_d: *@import("../object.zig").SetData, found: *bool };
    var found = false;
    var ctx = Ctx{ .this_d = this_d, .found = &found };
    try setLikeForEachKey(realm, sl, &ctx, struct {
        fn cb(c: *Ctx, key: Value) NativeError!void {
            if (setIndex(c.this_d, canonicalizeKey(key)) != null) c.found.* = true;
        }
    }.cb);
    return Value.fromBool(!found);
}

