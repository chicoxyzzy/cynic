//! §25 ArrayBuffer + §25.3 DataView + §23.2 TypedArray —
//! extracted from `intrinsics.zig` to keep that module focused
//! on cross-builtin orchestration. This file contains:
//! • The %TypedArray% abstract intrinsic + 10 concrete
//! constructors (Int8Array … BigUint64Array).
//! • ArrayBuffer constructor + prototype.
//! • DataView constructor + prototype.
//! • Shared helpers: `taViewOf`, `taBufOf`, `taResolveIndex`,
//! `taMakeNew`, `taSortInPlace`.
//! • `readTypedElement` / `writeTypedElement` re-exported from
//! intrinsics.zig for the interpreter's index-access path.

const std = @import("std");

const Realm = @import("../realm.zig").Realm;
const Value = @import("../value.zig").Value;
const JSString = @import("../string.zig").JSString;
const JSObject = @import("../object.zig").JSObject;
const JSFunction = @import("../function.zig").JSFunction;
const NativeError = @import("../function.zig").NativeError;
const NativeFn = @import("../function.zig").NativeFn;
const heap_mod = @import("../heap.zig");
const intrinsics = @import("../intrinsics.zig");

const installConstructor = intrinsics.installConstructor;
const installNativeMethodOnProto = intrinsics.installNativeMethodOnProto;
const getPropertyChain = intrinsics.getPropertyChain;
const installNativeGetter = intrinsics.installNativeGetter;
const installToStringTag = intrinsics.installToStringTag;
const setNonEnumerable = intrinsics.setNonEnumerable;
const argOr = intrinsics.argOr;
const numberFromI64 = intrinsics.numberFromI64;
const coerceToNumber = intrinsics.coerceToNumber;
const toNumber = intrinsics.toNumber;
const throwTypeError = intrinsics.throwTypeError;
const throwRangeError = intrinsics.throwRangeError;
const toBoolean = intrinsics.toBoolean;
const stringifyArg = intrinsics.stringifyArg;
const sameValueZero = intrinsics.sameValueZero;
const invokeCallback = intrinsics.invokeCallback;
const arrayLikeEntriesMethod = intrinsics.arrayLikeEntriesMethod;
const arrayLikeKeysMethod = intrinsics.arrayLikeKeysMethod;
const arrayLikeValuesMethod = intrinsics.arrayLikeValuesMethod;
const doubleToI64Saturating = intrinsics.doubleToI64Saturating;
const strictEqualsLite = intrinsics.strictEqualsLite;

// ── §25 ArrayBuffer + §23.2 TypedArray ──────────────────────────────

const ObjMod = @import("../object.zig");
const toBigIntValue = @import("bigint.zig").toBigIntValue;

pub fn install(realm: *Realm) !void {
    // ArrayBuffer constructor.
    {
        const r = try installConstructor(realm, .{
            .name = "ArrayBuffer", .ctor = arrayBufferConstructor, .arity = 1,
            .set_home_object = false,
            .to_string_tag = "ArrayBuffer",
        });
        const ctor = r.ctor;
        const proto = r.proto;
        try installNativeGetter(realm, proto, "byteLength", arrayBufferByteLength);
        try installNativeMethodOnProto(realm, proto, "slice", arrayBufferSlice, 2);
        // §25.1.5.{3,4} ArrayBuffer.prototype.{transfer, transferToFixedLength}
        // — ES2024. Both detach the source and return a fresh
        // ArrayBuffer holding the data. `transfer` preserves the
        // source's resizable bit (max_byte_length carries over);
        // `transferToFixedLength` always produces a fixed buffer.
        try installNativeMethodOnProto(realm, proto, "transfer", arrayBufferTransfer, 0);
        try installNativeMethodOnProto(realm, proto, "transferToFixedLength", arrayBufferTransferToFixedLength, 0);
        // §25.1.5.2 `get ArrayBuffer.prototype.detached` — ES2024
        // companion of `.transfer`. Reads `[[ArrayBufferData]]
        // === null`.
        try installNativeGetter(realm, proto, "detached", arrayBufferDetached);
        // §25.1.5 resizable-ArrayBuffer surface (ES2024). Three
        // accessors + one method, brand-checked off
        // `[[ArrayBufferMaxByteLength]]`.
        try installNativeGetter(realm, proto, "maxByteLength", arrayBufferMaxByteLength);
        try installNativeGetter(realm, proto, "resizable", arrayBufferResizable);
        try installNativeMethodOnProto(realm, proto, "resize", arrayBufferResize, 1);
        // §25.1.4.3 ArrayBuffer.isView(arg) — returns true iff
        // arg is an Object with a `[[ViewedArrayBuffer]]` slot
        // (TypedArray or DataView instance). Cynic tracks both
        // with `obj.typed_view`.
        try intrinsics.installNativeMethod(realm, ctor, "isView", arrayBufferIsView, 1);
    }

    // §25.3 DataView constructor + prototype.
    {
        const r = try installConstructor(realm, .{
            .name = "DataView", .ctor = dataViewConstructor, .arity = 1,
            .set_home_object = false,
            .to_string_tag = "DataView",
        });
        const proto = r.proto;
        try installNativeGetter(realm, proto, "byteLength", dataViewByteLength);
        try installNativeGetter(realm, proto, "byteOffset", dataViewByteOffset);
        try installNativeGetter(realm, proto, "buffer", dataViewBuffer);

        try installNativeMethodOnProto(realm, proto, "getInt8", dataViewGetInt8, 1);
        try installNativeMethodOnProto(realm, proto, "getUint8", dataViewGetUint8, 1);
        try installNativeMethodOnProto(realm, proto, "getInt16", dataViewGetInt16, 1);
        try installNativeMethodOnProto(realm, proto, "getUint16", dataViewGetUint16, 1);
        try installNativeMethodOnProto(realm, proto, "getInt32", dataViewGetInt32, 1);
        try installNativeMethodOnProto(realm, proto, "getUint32", dataViewGetUint32, 1);
        try installNativeMethodOnProto(realm, proto, "getFloat32", dataViewGetFloat32, 1);
        try installNativeMethodOnProto(realm, proto, "getFloat64", dataViewGetFloat64, 1);
        try installNativeMethodOnProto(realm, proto, "getBigInt64", dataViewGetBigInt64, 1);
        try installNativeMethodOnProto(realm, proto, "getBigUint64", dataViewGetBigUint64, 1);
        try installNativeMethodOnProto(realm, proto, "setInt8", dataViewSetInt8, 2);
        try installNativeMethodOnProto(realm, proto, "setUint8", dataViewSetUint8, 2);
        try installNativeMethodOnProto(realm, proto, "setInt16", dataViewSetInt16, 2);
        try installNativeMethodOnProto(realm, proto, "setUint16", dataViewSetUint16, 2);
        try installNativeMethodOnProto(realm, proto, "setInt32", dataViewSetInt32, 2);
        try installNativeMethodOnProto(realm, proto, "setUint32", dataViewSetUint32, 2);
        try installNativeMethodOnProto(realm, proto, "setFloat32", dataViewSetFloat32, 2);
        try installNativeMethodOnProto(realm, proto, "setFloat64", dataViewSetFloat64, 2);
        try installNativeMethodOnProto(realm, proto, "setBigInt64", dataViewSetBigInt64, 2);
        try installNativeMethodOnProto(realm, proto, "setBigUint64", dataViewSetBigUint64, 2);
    }

    // §23.2.1 %TypedArray% — the abstract intrinsic constructor
    // every concrete typed-array constructor inherits from. Per
    // §23.2.4.4 calling it directly is a TypeError. Methods live
    // here, NOT on the per-kind prototypes; concrete prototypes
    // (`Int8Array.prototype`, etc.) inherit from
    // `%TypedArray%.prototype` and pick up everything via the
    // proto chain. Tests that do
    // `var TypedArray = Object.getPrototypeOf(Int8Array)`
    // (test262's `testTypedArray.js` harness include) get the
    // intrinsic this way.
    const r_ta = try installConstructor(realm, .{
        .name = "TypedArray", .ctor = typedArrayAbstractCtor, .arity = 0,
        .set_home_object = false,
        .install_global = false, // not exposed as a global per spec
    });
    const ta_ctor = r_ta.ctor;
    const ta_proto = r_ta.proto;

    // §23.2.3.32 %TypedArray%.prototype[@@toStringTag] is
    // spec'd as a getter that reads `[[TypedArrayName]]`. Cynic
    // installs a string @@toStringTag on each *concrete*
    // prototype (Int8Array.prototype, etc.) below so the lookup
    // walk finds the right tag without needing the per-instance
    // accessor.

    // Accessors and methods on %TypedArray%.prototype.
    {
        try installNativeGetter(realm, ta_proto, "length", typedArrayLength);
        try installNativeGetter(realm, ta_proto, "byteLength", typedArrayByteLength);
        try installNativeGetter(realm, ta_proto, "byteOffset", typedArrayByteOffset);
        try installNativeGetter(realm, ta_proto, "buffer", typedArrayBuffer);

        try installNativeMethodOnProto(realm, ta_proto, "fill", typedArrayFill, 1);
        // §23.2.3.27 — `set` has `length` 1 (the `source` arg;
        // `offset` defaults to 0). Don't confuse "Cynic's native
        // implementation reads 2 args" with the spec arity.
        try installNativeMethodOnProto(realm, ta_proto, "set", typedArraySet, 1);
        try installNativeMethodOnProto(realm, ta_proto, "at", typedArrayAt, 1);
        try installNativeMethodOnProto(realm, ta_proto, "copyWithin", typedArrayCopyWithin, 2);
        try installNativeMethodOnProto(realm, ta_proto, "every", typedArrayEvery, 1);
        try installNativeMethodOnProto(realm, ta_proto, "find", typedArrayFind, 1);
        try installNativeMethodOnProto(realm, ta_proto, "findIndex", typedArrayFindIndex, 1);
        try installNativeMethodOnProto(realm, ta_proto, "findLast", typedArrayFindLast, 1);
        try installNativeMethodOnProto(realm, ta_proto, "findLastIndex", typedArrayFindLastIndex, 1);
        try installNativeMethodOnProto(realm, ta_proto, "forEach", typedArrayForEach, 1);
        try installNativeMethodOnProto(realm, ta_proto, "includes", typedArrayIncludes, 1);
        try installNativeMethodOnProto(realm, ta_proto, "indexOf", typedArrayIndexOf, 1);
        try installNativeMethodOnProto(realm, ta_proto, "join", typedArrayJoin, 1);
        try installNativeMethodOnProto(realm, ta_proto, "lastIndexOf", typedArrayLastIndexOf, 1);
        try installNativeMethodOnProto(realm, ta_proto, "reduce", typedArrayReduce, 1);
        try installNativeMethodOnProto(realm, ta_proto, "reduceRight", typedArrayReduceRight, 1);
        try installNativeMethodOnProto(realm, ta_proto, "reverse", typedArrayReverse, 0);
        try installNativeMethodOnProto(realm, ta_proto, "some", typedArraySome, 1);
        try installNativeMethodOnProto(realm, ta_proto, "toString", typedArrayToString, 0);
        try installNativeMethodOnProto(realm, ta_proto, "toLocaleString", typedArrayToLocaleString, 0);
        try installNativeMethodOnProto(realm, ta_proto, "filter", typedArrayFilter, 1);
        try installNativeMethodOnProto(realm, ta_proto, "map", typedArrayMap, 1);
        try installNativeMethodOnProto(realm, ta_proto, "slice", typedArraySlice, 2);
        try installNativeMethodOnProto(realm, ta_proto, "subarray", typedArraySubarray, 2);

        // §23.2.3 iterator methods. Reuse the array-like
        // iterator factory; arrayLikeIterStep handles typed
        // views directly off the buffer.
        try installNativeMethodOnProto(realm, ta_proto, "entries", arrayLikeEntriesMethod, 0);
        try installNativeMethodOnProto(realm, ta_proto, "keys", arrayLikeKeysMethod, 0);
        try installNativeMethodOnProto(realm, ta_proto, "values", arrayLikeValuesMethod, 0);
        try installNativeMethodOnProto(realm, ta_proto, "@@iterator", arrayLikeValuesMethod, 0);

        // §23.2.3 sort + ES2023 immutable variants.
        try installNativeMethodOnProto(realm, ta_proto, "sort", typedArraySort, 1);
        try installNativeMethodOnProto(realm, ta_proto, "toSorted", typedArrayToSorted, 1);
        try installNativeMethodOnProto(realm, ta_proto, "toReversed", typedArrayToReversed, 0);
        try installNativeMethodOnProto(realm, ta_proto, "with", typedArrayWith, 2);
    }

    // %TypedArray% itself isn't a global — `var TypedArray =
    // Object.getPrototypeOf(Int8Array)` fishes it out via the
    // proto chain instead. Pin it on intrinsics for our own use.
    realm.intrinsics.typed_array_constructor = ta_ctor;
    realm.intrinsics.typed_array_prototype = ta_proto;

    // Each typed-array concrete constructor inherits from
    // %TypedArray% / %TypedArray%.prototype.
    const Variant = struct { name: []const u8, kind: ObjMod.TypedKind };
    const variants = [_]Variant{
        .{ .name = "Int8Array", .kind = .int8 },
        .{ .name = "Uint8Array", .kind = .uint8 },
        .{ .name = "Uint8ClampedArray", .kind = .uint8 },
        .{ .name = "Int16Array", .kind = .int16 },
        .{ .name = "Uint16Array", .kind = .uint16 },
        .{ .name = "Int32Array", .kind = .int32 },
        .{ .name = "Uint32Array", .kind = .uint32 },
        .{ .name = "Float32Array", .kind = .float32 },
        .{ .name = "Float64Array", .kind = .float64 },
        .{ .name = "BigInt64Array", .kind = .bigint64 },
        .{ .name = "BigUint64Array", .kind = .biguint64 },
    };
    // §23.2.6 — each concrete typed-array constructor has
    // `[[Prototype]] = %TypedArray%`. `JSFunction.proto` is typed
    // `*JSObject`, so we record the constructor link on
    // `static_parent` (a `*JSFunction`); `objectGetPrototypeOf`
    // and `JSFunction.get` both honour this slot before walking
    // `proto`. `Int8Array.proto` itself stays `%Function.prototype%`
    // (the default for any function).

    // Frozen-style descriptor for the per-kind static data
    // properties spec'd in §23.2.6: `BYTES_PER_ELEMENT` on both
    // the constructor and the prototype, plus `prototype` on the
    // constructor itself, are all `{w:false, e:false, c:false}`.
    const frozen: @import("../object.zig").PropertyFlags = .{
        .writable = false,
        .enumerable = false,
        .configurable = false,
    };
    inline for (variants) |variant| {
        // §23.2.5 — "The length property of TypedArray is 3."
        // Each concrete constructor has the same arity as
        // %TypedArray% itself (signature is up to (buffer,
        // byteOffset, length) or one of the other 3-arg forms).
        const ctor = try realm.heap.allocateFunctionNative(typedArrayConstructorBuilder(variant.kind), 3, variant.name);
        ctor.is_class_constructor = true;
        ctor.static_parent = ta_ctor; // §23.2.6 — Int8Array.[[Prototype]] = %TypedArray%
        const proto = try realm.heap.allocateObject();
        proto.prototype = ta_proto; // §23.2.6 — concrete proto inherits from %TypedArray%.prototype.
        try setNonEnumerable(proto, realm.allocator, "constructor", heap_mod.taggedFunction(ctor));
        // §23.2.6.2 — `<TypedArray>.prototype.BYTES_PER_ELEMENT`
        // is `{w:false, e:false, c:false}`.
        try proto.setWithFlags(realm.allocator, "BYTES_PER_ELEMENT", Value.fromInt32(variant.kind.elementSize()), frozen);
        // §23.2.6 — concrete typed arrays don't get their own
        // @@toStringTag accessor in the spec; %TypedArray%.proto's
        // accessor reads `[[TypedArrayName]]`. With Cynic's
        // string-only @@toStringTag, install the per-kind tag
        // directly on each concrete proto. Object.toString sees
        // it through the prototype chain.
        try installToStringTag(realm, proto, variant.name);
        ctor.prototype = proto;
        // §23.2.5.2 — `<TypedArray>.prototype` is also frozen.
        try ctor.setWithFlags(realm.allocator, "prototype", heap_mod.taggedObject(proto), frozen);
        // §23.2.5.1 — `<TypedArray>.BYTES_PER_ELEMENT` is frozen
        // on the constructor too.
        try ctor.setWithFlags(realm.allocator, "BYTES_PER_ELEMENT", Value.fromInt32(variant.kind.elementSize()), frozen);

        try realm.globals.put(realm.allocator, variant.name, heap_mod.taggedFunction(ctor));
    }
}

fn typedArrayAbstractCtor(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = this_value;
    _ = args;
    return throwTypeError(realm, "TypedArray is an abstract constructor and cannot be invoked directly");
}

fn arrayBufferConstructor(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const inst = heap_mod.valueAsPlainObject(this_value) orelse return throwTypeError(realm, "ArrayBuffer constructor requires 'new'");
    // §25.1.3.1 step 2 — `Let byteLength be ? ToIndex(length)`.
    const len = try toIndex(realm, argOr(args, 0, Value.fromInt32(0)));

    // §25.1.3.1 step 3 — `Let requestedMaxByteLength be
    // ? GetArrayBufferMaxByteLengthOption(options)`. Order matters:
    // observe the `valueOf` / `toString` calls on `maxByteLength`
    // *after* the length coercion (fixtures assert the log order).
    const max_byte_length_opt = try getMaxByteLengthOption(realm, argOr(args, 1, Value.undefined_));
    if (max_byte_length_opt) |max_len| {
        if (len > max_len) {
            return throwRangeError(realm, "ArrayBuffer length exceeds maxByteLength");
        }
    }

    // §25.1.3.1 step 7 — `new ArrayBuffer(len)` allocates `len`
    // bytes (or `max_len` for resizable buffers so growing in
    // place doesn't reallocate). Charge against the heap ceiling
    // so a `new ArrayBuffer(2 ** 31)` call can't exhaust system
    // memory; overshoot surfaces as `RangeError`.
    const capacity = max_byte_length_opt orelse len;
    realm.heap.charge(capacity) catch
        return throwRangeError(realm, "ArrayBuffer length exceeds heap ceiling");
    const buf = realm.allocator.alloc(u8, len) catch return error.OutOfMemory;
    @memset(buf, 0);
    inst.array_buffer = buf;
    inst.has_array_buffer_data = true;
    inst.array_buffer_max_byte_length = max_byte_length_opt;
    return this_value;
}

/// §7.1.22 ToIndex — coerce `v` to an integer index in
/// `[0, 2^53 - 1]`. `RangeError` on negative / infinite /
/// out-of-range. Centralised so `new ArrayBuffer(N)`,
/// `.resize(N)`, and `maxByteLength` share the same edge cases.
fn toIndex(realm: *Realm, v: Value) NativeError!usize {
    const n = try intrinsics.toNumber(realm, v);
    const raw: f64 = if (n.isInt32()) @floatFromInt(n.asInt32()) else n.asDouble();
    const trunc: f64 = if (std.math.isNan(raw)) 0 else if (std.math.isInf(raw)) raw else @trunc(raw);
    if (std.math.isInf(trunc) and trunc > 0)
        return throwRangeError(realm, "value out of range");
    if (trunc < 0)
        return throwRangeError(realm, "value out of range");
    if (trunc > @as(f64, @floatFromInt(std.math.maxInt(u32))))
        return throwRangeError(realm, "value out of range");
    return @intFromFloat(trunc);
}

/// §25.1.3.7 GetArrayBufferMaxByteLengthOption(options).
/// Returns `null` if `options` is not an Object or its
/// `maxByteLength` property is `undefined`. Otherwise
/// `? ToIndex(maxByteLength)`.
fn getMaxByteLengthOption(realm: *Realm, options: Value) NativeError!?usize {
    const obj = heap_mod.valueAsPlainObject(options) orelse return null;
    const mbl = try intrinsics.getPropertyChain(realm, obj, "maxByteLength");
    if (mbl.isUndefined()) return null;
    return try toIndex(realm, mbl);
}

/// §25.1.4.3 ArrayBuffer.isView(arg) — true iff arg is an
/// Object with a `[[ViewedArrayBuffer]]` internal slot (i.e.
/// any TypedArray or DataView instance). Cynic tracks both via
/// `obj.typed_view`.
fn arrayBufferIsView(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = realm;
    _ = this_value;
    const arg = argOr(args, 0, Value.undefined_);
    const obj = heap_mod.valueAsPlainObject(arg) orelse return Value.false_;
    // §25.1.4.3 — true iff `[[ViewedArrayBuffer]]` is present.
    // Cynic stores TypedArrays under `typed_view` and DataViews
    // under `data_view`; either qualifies.
    return Value.fromBool(obj.typed_view != null or obj.data_view != null);
}

fn arrayBufferByteLength(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = args;
    // §25.1.5.1 `get ArrayBuffer.prototype.byteLength` step 2 —
    // RequireInternalSlot(O, [[ArrayBufferData]]) throws TypeError
    // when `this` is not an ArrayBuffer instance.
    const obj = heap_mod.valueAsPlainObject(this_value) orelse
        return throwTypeError(realm, "get ArrayBuffer.prototype.byteLength requires an ArrayBuffer receiver");
    if (!obj.has_array_buffer_data)
        return throwTypeError(realm, "get ArrayBuffer.prototype.byteLength requires an ArrayBuffer receiver");
    if (obj.array_buffer) |ab| return Value.fromInt32(@intCast(ab.len));
    // Detached buffer — §25.1.5.1 step 5 says return 0 (the
    // [[ArrayBufferByteLength]] field on a detached buffer is 0).
    return Value.fromInt32(0);
}

/// §25.1.5.2 `get ArrayBuffer.prototype.detached`. ES2024.
/// Returns true iff `[[ArrayBufferData]]` is null — which is
/// Cynic's representation of a transferred buffer.
fn arrayBufferDetached(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = args;
    const obj = heap_mod.valueAsPlainObject(this_value) orelse
        return throwTypeError(realm, "get ArrayBuffer.prototype.detached requires an ArrayBuffer receiver");
    if (!obj.has_array_buffer_data)
        return throwTypeError(realm, "get ArrayBuffer.prototype.detached requires an ArrayBuffer receiver");
    return Value.fromBool(obj.array_buffer == null);
}

/// §25.1.5.x `get ArrayBuffer.prototype.maxByteLength`. ES2024.
/// Non-resizable buffer → returns current byteLength. Resizable
/// buffer → returns the stored max. Detached → 0.
fn arrayBufferMaxByteLength(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = args;
    const obj = heap_mod.valueAsPlainObject(this_value) orelse
        return throwTypeError(realm, "get ArrayBuffer.prototype.maxByteLength requires an ArrayBuffer receiver");
    if (!obj.has_array_buffer_data)
        return throwTypeError(realm, "get ArrayBuffer.prototype.maxByteLength requires an ArrayBuffer receiver");
    if (obj.array_buffer == null) return Value.fromInt32(0);
    const max = obj.array_buffer_max_byte_length orelse obj.array_buffer.?.len;
    return numberFromUsize(max);
}

/// §25.1.5.x `get ArrayBuffer.prototype.resizable`. ES2024.
fn arrayBufferResizable(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = args;
    const obj = heap_mod.valueAsPlainObject(this_value) orelse
        return throwTypeError(realm, "get ArrayBuffer.prototype.resizable requires an ArrayBuffer receiver");
    if (!obj.has_array_buffer_data)
        return throwTypeError(realm, "get ArrayBuffer.prototype.resizable requires an ArrayBuffer receiver");
    return Value.fromBool(obj.array_buffer_max_byte_length != null);
}

/// §25.1.5.3 ArrayBuffer.prototype.resize(newLength). ES2024.
/// Only valid on a resizable (non-detached) ArrayBuffer.
fn arrayBufferResize(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    // Step 2 — RequireInternalSlot(O, [[ArrayBufferMaxByteLength]]).
    // A fixed buffer doesn't carry the slot at all.
    const obj = heap_mod.valueAsPlainObject(this_value) orelse
        return throwTypeError(realm, "ArrayBuffer.prototype.resize requires a resizable ArrayBuffer receiver");
    if (!obj.has_array_buffer_data or obj.array_buffer_max_byte_length == null)
        return throwTypeError(realm, "ArrayBuffer.prototype.resize requires a resizable ArrayBuffer receiver");
    // Step 5 — `Let newByteLength be ? ToIntegerOrInfinity(newLength)`.
    // The `coerced-new-length-detach.js` fixture asserts that
    // coercion runs BEFORE the detached check (step 4) — so we
    // ToNumber here first, then validate.
    const len_v = try intrinsics.toNumber(realm, argOr(args, 0, Value.undefined_));
    const raw: f64 = if (len_v.isInt32()) @floatFromInt(len_v.asInt32()) else len_v.asDouble();
    const trunc: f64 = if (std.math.isNan(raw)) 0 else if (std.math.isInf(raw)) raw else @trunc(raw);
    // Step 4 — IsDetachedBuffer(O) check happens *after* coercion.
    if (obj.array_buffer == null)
        return throwTypeError(realm, "ArrayBuffer.prototype.resize on detached buffer");
    // Step 6 — newByteLength < 0 or > max → RangeError.
    const max = obj.array_buffer_max_byte_length.?;
    const max_f: f64 = @floatFromInt(max);
    if (trunc < 0 or (std.math.isInf(trunc) and trunc > 0) or trunc > max_f)
        return throwRangeError(realm, "ArrayBuffer.prototype.resize newLength out of range");
    const new_len: usize = @intFromFloat(trunc);

    // Step 7 / 8 — HostResizeArrayBuffer. We're the host: realloc
    // the backing buffer and zero-fill any growth tail.
    const old = obj.array_buffer.?;
    if (new_len == old.len) return Value.undefined_;
    const new_bytes = realm.allocator.realloc(old, new_len) catch return error.OutOfMemory;
    if (new_len > old.len) @memset(new_bytes[old.len..], 0);
    obj.array_buffer = new_bytes;
    return Value.undefined_;
}

/// §6.1.6 — number return that fits any usize that survives ToIndex.
fn numberFromUsize(n: usize) Value {
    if (n <= @as(usize, std.math.maxInt(i32))) return Value.fromInt32(@intCast(n));
    return Value.fromDouble(@floatFromInt(n));
}

/// §25.1.5.3 ArrayBuffer.prototype.transfer(newLength).
/// `preserve_resizability=true` carries the source's resizable
/// bit (preserving `[[ArrayBufferMaxByteLength]]`);
/// `transferToFixedLength` always strips it.
fn arrayBufferTransferImpl(realm: *Realm, this_value: Value, args: []const Value, preserve_resizability: bool) NativeError!Value {
    const src = heap_mod.valueAsPlainObject(this_value) orelse
        return throwTypeError(realm, "ArrayBuffer.prototype.transfer requires an ArrayBuffer receiver");
    if (!src.has_array_buffer_data)
        return throwTypeError(realm, "ArrayBuffer.prototype.transfer requires an ArrayBuffer receiver");

    // newLength defaults to source byteLength (or maxByteLength
    // when preserving resizability and source is resizable —
    // matches V8's transfer-preserves-cap semantics).
    const src_buf = src.array_buffer orelse
        return throwTypeError(realm, "Cannot transfer a detached ArrayBuffer");
    const new_len: usize = blk: {
        if (args.len == 0 or args[0].isUndefined()) break :blk src_buf.len;
        break :blk try toIndex(realm, args[0]);
    };

    const max_byte_length: ?usize = if (preserve_resizability) src.array_buffer_max_byte_length else null;
    if (max_byte_length) |m| {
        if (new_len > m) return throwRangeError(realm, "ArrayBuffer.prototype.transfer: newLength exceeds maxByteLength");
    }

    const new_bytes = realm.allocator.alloc(u8, new_len) catch return error.OutOfMemory;
    // §25.1.3.1 CopyDataBlockBytes — copy min(src, new) bytes,
    // zero-fill any tail beyond src.
    const copy_n = @min(src_buf.len, new_len);
    @memcpy(new_bytes[0..copy_n], src_buf[0..copy_n]);
    if (new_len > copy_n) @memset(new_bytes[copy_n..], 0);

    // Detach the source — DetachArrayBuffer per §25.1.3.4.
    realm.allocator.free(src_buf);
    src.array_buffer = null;
    // Detaching clears the max-byte-length slot too; per spec a
    // detached buffer's `maxByteLength` reads 0.
    src.array_buffer_max_byte_length = null;

    const out = realm.heap.allocateObject() catch return error.OutOfMemory;
    if (heap_mod.valueAsFunction(realm.globals.get("ArrayBuffer") orelse Value.undefined_)) |ab_ctor| {
        out.prototype = ab_ctor.prototype;
    } else {
        out.prototype = realm.intrinsics.object_prototype;
    }
    out.array_buffer = new_bytes;
    out.has_array_buffer_data = true;
    out.array_buffer_max_byte_length = max_byte_length;
    return heap_mod.taggedObject(out);
}

fn arrayBufferTransfer(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    return arrayBufferTransferImpl(realm, this_value, args, true);
}

fn arrayBufferTransferToFixedLength(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    return arrayBufferTransferImpl(realm, this_value, args, false);
}

fn arrayBufferSlice(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const src = heap_mod.valueAsPlainObject(this_value) orelse return throwTypeError(realm, "slice on non-ArrayBuffer");
    const buf = src.array_buffer orelse return throwTypeError(realm, "slice on non-ArrayBuffer");
    const total: i64 = @intCast(buf.len);
    // §25.1.5.4 ArrayBuffer.prototype.slice — start / end go
    // through ToIntegerOrInfinity, which routes through
    // ToNumber and throws on Symbol / BigInt.
    var start_d: f64 = 0;
    if (args.len > 0) {
        const v = try intrinsics.toNumber(realm, args[0]);
        start_d = if (v.isInt32()) @floatFromInt(v.asInt32()) else v.asDouble();
    }
    var end_d: f64 = @floatFromInt(total);
    if (args.len > 1 and !args[1].isUndefined()) {
        const v = try intrinsics.toNumber(realm, args[1]);
        end_d = if (v.isInt32()) @floatFromInt(v.asInt32()) else v.asDouble();
    }
    const i64_max_f: f64 = @floatFromInt(std.math.maxInt(i64));
    const i64_min_f: f64 = @floatFromInt(std.math.minInt(i64));
    var start_i: i64 = if (std.math.isNan(start_d) or std.math.isInf(start_d)) 0 else if (start_d > i64_max_f) std.math.maxInt(i64) else if (start_d < i64_min_f) std.math.minInt(i64) else @intFromFloat(@trunc(start_d));
    var end_i: i64 = if (std.math.isNan(end_d) or std.math.isInf(end_d)) total else if (end_d > i64_max_f) std.math.maxInt(i64) else if (end_d < i64_min_f) std.math.minInt(i64) else @intFromFloat(@trunc(end_d));
    if (start_i < 0) start_i = @max(total + start_i, 0);
    if (end_i < 0) end_i = @max(total + end_i, 0);
    start_i = @min(start_i, total);
    end_i = @min(end_i, total);
    const new_len: usize = if (end_i > start_i) @intCast(end_i - start_i) else 0;

    const out = realm.heap.allocateObject() catch return error.OutOfMemory;
    if (heap_mod.valueAsFunction(realm.globals.get("ArrayBuffer") orelse Value.undefined_)) |ab| {
        out.prototype = ab.prototype;
    }
    const new_buf = realm.allocator.alloc(u8, new_len) catch return error.OutOfMemory;
    if (new_len > 0) @memcpy(new_buf, buf[@intCast(start_i)..@intCast(end_i)]);
    out.array_buffer = new_buf;
    out.has_array_buffer_data = true;
    return heap_mod.taggedObject(out);
}

fn typedArrayConstructorBuilder(comptime kind: ObjMod.TypedKind) NativeFn {
    return struct {
        fn ctor(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
            const inst = heap_mod.valueAsPlainObject(this_value) orelse return throwTypeError(realm, "TypedArray constructor requires 'new'");
            const arg = argOr(args, 0, Value.undefined_);
            const elem_size: usize = kind.elementSize();

            // Three constructor shapes:
            // 1. `new Uint8Array(N)` — allocate fresh buffer of N elements.
            // 2. `new Uint8Array(buffer, offset?, length?)` — view existing buffer.
            // 3. `new Uint8Array(arrayLikeOrIterable)` — copy elements from source.
            // Symbol / BigInt arg → ToIndex throws TypeError per
            // §23.2.5.1.1 step 4 (after the ToNumber inside ToIndex).
            if (heap_mod.valueAsSymbol(arg) != null) {
                return @import("../intrinsics.zig").throwTypeError(realm, "Cannot convert a Symbol to TypedArray length");
            }
            if (heap_mod.valueAsBigInt(arg) != null) {
                return @import("../intrinsics.zig").throwTypeError(realm, "Cannot convert a BigInt to TypedArray length");
            }
            if (arg.isInt32() or arg.isDouble() or arg.isUndefined() or arg.isBool() or arg.isNull() or arg.isString()) {
                // §23.2.5.1.1 — `new TypedArray()` allocates a
                // zero-length view. `coerceToNumber(undefined)`
                // would produce NaN and fall into the RangeError
                // branch; short-circuit here. Strings / booleans
                // ToNumber-coerce.
                const n_d: f64 = if (arg.isUndefined()) 0 else blk: {
                    const n_v = coerceToNumber(arg);
                    break :blk if (n_v.isInt32()) @floatFromInt(n_v.asInt32()) else n_v.asDouble();
                };
                if (std.math.isNan(n_d) or n_d < 0) return throwRangeError(realm, "TypedArray length out of range");
                // Catch overflow before the int cast — `Infinity`
                // and any finite value past `maxInt(u32) / elem_size`
                // would either trap `@intFromFloat` or roll past
                // the byte-length check below.
                const max_len: f64 = @floatFromInt(@as(usize, std.math.maxInt(u32)) / elem_size);
                if (n_d > max_len) return throwRangeError(realm, "TypedArray length out of range");
                const length: usize = @intFromFloat(@trunc(n_d));
                const byte_len = length * elem_size;
                if (byte_len > std.math.maxInt(u32)) return throwRangeError(realm, "TypedArray byte length out of range");

                const buf_obj = realm.heap.allocateObject() catch return error.OutOfMemory;
                if (heap_mod.valueAsFunction(realm.globals.get("ArrayBuffer") orelse Value.undefined_)) |ab| {
                    buf_obj.prototype = ab.prototype;
                }
                const buf_bytes = realm.allocator.alloc(u8, byte_len) catch return error.OutOfMemory;
                @memset(buf_bytes, 0);
                buf_obj.array_buffer = buf_bytes;
                buf_obj.has_array_buffer_data = true;

                inst.typed_view = .{ .kind = kind, .viewed = buf_obj, .byte_offset = 0, .length = length };
                return this_value;
            }

            // ArrayBuffer source.
            if (heap_mod.valueAsPlainObject(arg)) |src| {
                if (src.array_buffer) |ab| {
                    // §23.2.5.1.4 — byteOffset / length both go
                    // through ToIndex (ToNumber + bounds check),
                    // which throws TypeError on Symbol / BigInt.
                    var byte_offset: usize = 0;
                    if (args.len > 1 and !args[1].isUndefined()) {
                        const ov = try intrinsics.toNumber(realm, args[1]);
                        const od: f64 = if (ov.isInt32()) @floatFromInt(ov.asInt32()) else ov.asDouble();
                        if (std.math.isNan(od) or od < 0) return throwRangeError(realm, "byteOffset out of range");
                        byte_offset = @intFromFloat(od);
                    }
                    if (byte_offset > ab.len) return throwRangeError(realm, "byteOffset exceeds buffer");
                    if (byte_offset % elem_size != 0) return throwRangeError(realm, "byteOffset not aligned");

                    const remaining = ab.len - byte_offset;
                    var length: usize = remaining / elem_size;
                    if (args.len > 2 and !args[2].isUndefined()) {
                        const lv = try intrinsics.toNumber(realm, args[2]);
                        const ld: f64 = if (lv.isInt32()) @floatFromInt(lv.asInt32()) else lv.asDouble();
                        if (std.math.isNan(ld) or ld < 0) return throwRangeError(realm, "length out of range");
                        length = @intFromFloat(ld);
                        if (length * elem_size > remaining) return throwRangeError(realm, "view exceeds buffer");
                    }
                    inst.typed_view = .{ .kind = kind, .viewed = src, .byte_offset = byte_offset, .length = length };
                    return this_value;
                }

                // Iterable source — §23.2.5.1.5 IterableToList path.
                // Per spec, GetMethod(items, @@iterator) is checked
                // before the array-like fallback. If the source has a
                // callable `@@iterator`, drain it to a temporary list
                // before sizing the buffer.
                const iter_method_v = intrinsics.getPropertyChain(realm, src, "@@iterator") catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    else => return error.NativeThrew,
                };
                if (heap_mod.valueAsFunction(iter_method_v)) |iter_method| {
                    const interp = @import("../interpreter.zig");
                    const iter_outcome = interp.callJSFunction(realm.allocator, realm, iter_method, arg, &.{}) catch |err| switch (err) {
                        error.OutOfMemory => return error.OutOfMemory,
                        else => return error.NativeThrew,
                    };
                    const iter = switch (iter_outcome) {
                        .value, .yielded => |v| v,
                        .thrown => return error.NativeThrew,
                    };
                    const iter_obj = heap_mod.valueAsPlainObject(iter) orelse return throwTypeError(realm, "TypedArray: @@iterator did not return an iterator object");
                    const next_v = intrinsics.getPropertyChain(realm, iter_obj, "next") catch |err| switch (err) {
                        error.OutOfMemory => return error.OutOfMemory,
                        else => return error.NativeThrew,
                    };
                    const next_fn = heap_mod.valueAsFunction(next_v) orelse return throwTypeError(realm, "TypedArray: iterator missing callable 'next'");

                    var collected: std.ArrayListUnmanaged(Value) = .empty;
                    defer collected.deinit(realm.allocator);
                    // §23.2.5.1.5 — re-entering JS via `next()` can
                    // trigger a GC. Pin the iterator and the
                    // accumulated values through a HandleScope so the
                    // collected buffer survives every call.
                    const scope = realm.heap.openScope() catch return error.OutOfMemory;
                    defer scope.close();
                    scope.push(iter) catch return error.OutOfMemory;
                    const max_iter: usize = 1 << 24;
                    var step: usize = 0;
                    while (step < max_iter) : (step += 1) {
                        const result_outcome = interp.callJSFunction(realm.allocator, realm, next_fn, iter, &.{}) catch |err| switch (err) {
                            error.OutOfMemory => return error.OutOfMemory,
                            else => return error.NativeThrew,
                        };
                        const result = switch (result_outcome) {
                            .value, .yielded => |v| v,
                            .thrown => return error.NativeThrew,
                        };
                        const result_obj = heap_mod.valueAsPlainObject(result) orelse return throwTypeError(realm, "TypedArray: iterator next() did not return an object");
                        // §7.4.7 IteratorComplete / IteratorValue invoke
                        // accessors; bare `obj.get` is accessor-blind.
                        if (toBoolean(try getPropertyChain(realm, result_obj, "done"))) break;
                        const item = try getPropertyChain(realm, result_obj, "value");
                        scope.push(item) catch return error.OutOfMemory;
                        collected.append(realm.allocator, item) catch return error.OutOfMemory;
                    }
                    const length: usize = collected.items.len;
                    const byte_len = length * elem_size;
                    const buf_obj = realm.heap.allocateObject() catch return error.OutOfMemory;
                    if (heap_mod.valueAsFunction(realm.globals.get("ArrayBuffer") orelse Value.undefined_)) |ab| {
                        buf_obj.prototype = ab.prototype;
                    }
                    const buf_bytes = realm.allocator.alloc(u8, byte_len) catch return error.OutOfMemory;
                    @memset(buf_bytes, 0);
                    buf_obj.array_buffer = buf_bytes;
                buf_obj.has_array_buffer_data = true;
                    inst.typed_view = .{ .kind = kind, .viewed = buf_obj, .byte_offset = 0, .length = length };
                    var idx: usize = 0;
                    while (idx < length) : (idx += 1) {
                        writeTypedElement(buf_bytes, kind, idx * elem_size, collected.items[idx]);
                    }
                    return this_value;
                }

                // Array-like source — copy elements.
                const len_v = src.get("length");
                if (len_v.isInt32() or len_v.isDouble()) {
                    const ld: f64 = if (len_v.isInt32()) @floatFromInt(len_v.asInt32()) else len_v.asDouble();
                    if (!std.math.isNan(ld) and ld >= 0) {
                        const length: usize = @intFromFloat(ld);
                        const byte_len = length * elem_size;
                        const buf_obj = realm.heap.allocateObject() catch return error.OutOfMemory;
                        if (heap_mod.valueAsFunction(realm.globals.get("ArrayBuffer") orelse Value.undefined_)) |ab| {
                            buf_obj.prototype = ab.prototype;
                        }
                        const buf_bytes = realm.allocator.alloc(u8, byte_len) catch return error.OutOfMemory;
                        @memset(buf_bytes, 0);
                        buf_obj.array_buffer = buf_bytes;
                buf_obj.has_array_buffer_data = true;
                        inst.typed_view = .{ .kind = kind, .viewed = buf_obj, .byte_offset = 0, .length = length };
                        // Copy each element via the same write path.
                        var i: usize = 0;
                        while (i < length) : (i += 1) {
                            var ibuf: [16]u8 = undefined;
                            const s = std.fmt.bufPrint(&ibuf, "{d}", .{i}) catch unreachable;
                            const src_v = src.get(s);
                            writeTypedElement(buf_bytes, kind, i * elem_size, src_v);
                        }
                        return this_value;
                    }
                }
            }
            return throwTypeError(realm, "TypedArray: unsupported constructor argument");
        }
    }.ctor;
}

fn typedArrayLength(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = args;
    const obj = heap_mod.valueAsPlainObject(this_value) orelse return throwTypeError(realm, "TypedArray accessor on non-object");
    const tv = obj.typed_view orelse return throwTypeError(realm, "TypedArray.prototype.length called on a non-TypedArray");
    return Value.fromInt32(@intCast(tv.length));
}

fn typedArrayByteLength(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = args;
    const obj = heap_mod.valueAsPlainObject(this_value) orelse return throwTypeError(realm, "TypedArray accessor on non-object");
    const tv = obj.typed_view orelse return throwTypeError(realm, "TypedArray.prototype.byteLength called on a non-TypedArray");
    return Value.fromInt32(@intCast(tv.length * tv.kind.elementSize()));
}

fn typedArrayByteOffset(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = args;
    const obj = heap_mod.valueAsPlainObject(this_value) orelse return throwTypeError(realm, "TypedArray accessor on non-object");
    const tv = obj.typed_view orelse return throwTypeError(realm, "TypedArray.prototype.byteOffset called on a non-TypedArray");
    return Value.fromInt32(@intCast(tv.byte_offset));
}

fn typedArrayBuffer(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = args;
    const obj = heap_mod.valueAsPlainObject(this_value) orelse return throwTypeError(realm, "TypedArray accessor on non-object");
    const tv = obj.typed_view orelse return throwTypeError(realm, "TypedArray.prototype.buffer called on a non-TypedArray");
    return heap_mod.taggedObject(tv.viewed);
}


fn typedArrayFill(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const obj = heap_mod.valueAsPlainObject(this_value) orelse return throwTypeError(realm, "TypedArray.prototype.fill called on non-TypedArray");
    const tv = obj.typed_view orelse return throwTypeError(realm, "TypedArray.prototype.fill called on non-TypedArray");
    const buf = tv.viewed.array_buffer orelse return throwTypeError(realm, "Cannot perform 'fill' on a detached buffer");
    const elem_size = tv.kind.elementSize();
    const len_i: i64 = @intCast(tv.length);
    // §23.2.3.10 step 3 — `ToNumber(value)` (or ToBigInt for
    // BigInt typed arrays) runs ONCE up front, before the start/
    // end coercions. Test262 fixtures pass side-effecting
    // `valueOf`/`toString` to verify the once-only semantics.
    // Route through realm-aware `toNumber` so user valueOf
    // throws propagate; non-BigInt typed arrays accept the
    // returned Value as-is. BigInt typed arrays follow a
    // separate ToBigInt path that's handled inside
    // `writeTypedElement` for now.
    const value_arg = argOr(args, 0, Value.undefined_);
    const value_coerced = if (tv.kind.isBigInt())
        value_arg
    else
        try intrinsics.toNumber(realm, value_arg);

    // §23.2.3.10 step 4-9 — start / end via ToIntegerOrInfinity,
    // clamped to [0, len]. Route through `toNumber` for the
    // same ToPrimitive ordering / Symbol-throw semantics.
    var start: i64 = 0;
    if (args.len > 1 and !args[1].isUndefined()) {
        const sv = try intrinsics.toNumber(realm, args[1]);
        const sd: f64 = if (sv.isInt32()) @floatFromInt(sv.asInt32()) else if (sv.isDouble()) sv.asDouble() else 0;
        if (std.math.isNan(sd)) {
            start = 0;
        } else if (sd == -std.math.inf(f64)) {
            start = 0;
        } else if (sd == std.math.inf(f64)) {
            start = len_i;
        } else {
            const t = @trunc(sd);
            start = if (t < 0) @max(@as(i64, 0), len_i + @as(i64, @intFromFloat(t))) else @min(len_i, @as(i64, @intFromFloat(t)));
        }
    }
    var end: i64 = len_i;
    if (args.len > 2 and !args[2].isUndefined()) {
        const ev = try intrinsics.toNumber(realm, args[2]);
        const ed: f64 = if (ev.isInt32()) @floatFromInt(ev.asInt32()) else if (ev.isDouble()) ev.asDouble() else 0;
        if (std.math.isNan(ed)) {
            end = 0;
        } else if (ed == -std.math.inf(f64)) {
            end = 0;
        } else if (ed == std.math.inf(f64)) {
            end = len_i;
        } else {
            const t = @trunc(ed);
            end = if (t < 0) @max(@as(i64, 0), len_i + @as(i64, @intFromFloat(t))) else @min(len_i, @as(i64, @intFromFloat(t)));
        }
    }

    var i: i64 = start;
    while (i < end) : (i += 1) {
        writeTypedElement(buf, tv.kind, tv.byte_offset + @as(usize, @intCast(i)) * elem_size, value_coerced);
    }
    return this_value;
}

fn typedArraySet(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    // §23.2.3.27 %TypedArray%.prototype.set(source [, offset]).
    //
    // Step 1: brand check. .set.call({},…) → TypeError per spec.
    const obj = heap_mod.valueAsPlainObject(this_value) orelse
        return throwTypeError(realm, "TypedArray.prototype.set called on non-object");
    const tv = obj.typed_view orelse
        return throwTypeError(realm, "TypedArray.prototype.set called on non-TypedArray");

    // Step 5: targetOffset = ToIntegerOrInfinity(offset). Throwing
    // valueOf propagates via toNumber.
    var target_offset: f64 = 0.0;
    if (args.len > 1 and !args[1].isUndefined()) {
        target_offset = try taSetToIntegerOrInfinity(realm, args[1]);
    }
    // Step 6: targetOffset < 0 ⇒ RangeError. NaN already mapped to 0.
    if (target_offset < 0) {
        return throwRangeError(realm, "TypedArray.prototype.set: offset out of range");
    }

    const source_arg = argOr(args, 0, Value.undefined_);
    const src_obj = heap_mod.valueAsPlainObject(source_arg) orelse {
        return throwTypeError(realm, "TypedArray.prototype.set: source is not an object");
    };

    if (src_obj.typed_view != null) {
        return try taSetFromTypedArray(realm, obj, tv, src_obj, target_offset);
    }
    return try taSetFromArrayLike(realm, obj, tv, src_obj, target_offset);
}

/// §7.1.5 ToIntegerOrInfinity. Routes through ToNumber so a
/// throwing valueOf propagates instead of being silently coerced.
fn taSetToIntegerOrInfinity(realm: *Realm, v: Value) NativeError!f64 {
    const num = try intrinsics.toNumber(realm, v);
    const d: f64 = if (num.isInt32()) @floatFromInt(num.asInt32()) else num.asDouble();
    if (std.math.isNan(d)) return 0;
    if (std.math.isInf(d)) return d;
    if (d == 0) return 0;
    return @trunc(d);
}

/// §23.2.3.27.2 SetTypedArrayFromTypedArray. Snapshots overlapping
/// same-buffer reads into a temporary so writes don't trample data
/// we still need to copy. Bulk memcpy when both views are distinct
/// buffers of identical element kind.
fn taSetFromTypedArray(
    realm: *Realm,
    target: *JSObject,
    tv: ObjMod.TypedView,
    src: *JSObject,
    target_offset: f64,
) NativeError!Value {
    _ = target;
    const src_tv = src.typed_view orelse unreachable;
    const dst_buf = tv.viewed.array_buffer orelse
        return throwTypeError(realm, "TypedArray.prototype.set: target buffer is detached");
    const src_buf = src_tv.viewed.array_buffer orelse
        return throwTypeError(realm, "TypedArray.prototype.set: source buffer is detached");

    // §23.2.3.27.2 step 6 — disallow Big↔non-Big mixes (the
    // "ContentType(srcType) != ContentType(targetType)" check).
    {
        const src_big = src_tv.kind == .bigint64 or src_tv.kind == .biguint64;
        const dst_big = tv.kind == .bigint64 or tv.kind == .biguint64;
        if (src_big != dst_big) {
            return throwTypeError(realm, "TypedArray.prototype.set: cannot mix BigInt and Number typed arrays");
        }
    }
    const target_length: usize = taInBoundsLength(tv);
    const src_length: usize = taInBoundsLength(src_tv);

    if (target_offset == std.math.inf(f64)) {
        return throwRangeError(realm, "TypedArray.prototype.set: offset out of range");
    }
    const tl_f: f64 = @floatFromInt(target_length);
    const sl_f: f64 = @floatFromInt(src_length);
    if (target_offset + sl_f > tl_f) {
        return throwRangeError(realm, "TypedArray.prototype.set: source overflows destination");
    }

    const offset: usize = @intFromFloat(target_offset);
    const elem_size = tv.kind.elementSize();
    const src_size = src_tv.kind.elementSize();
    const dst_base = tv.byte_offset + offset * elem_size;
    const src_base = src_tv.byte_offset;
    const same_buffer = src_tv.viewed == tv.viewed;

    if (src_tv.kind == tv.kind and !same_buffer) {
        const byte_count = src_length * elem_size;
        if (dst_base + byte_count <= dst_buf.len and src_base + byte_count <= src_buf.len) {
            @memcpy(dst_buf[dst_base .. dst_base + byte_count], src_buf[src_base .. src_base + byte_count]);
        }
        return Value.undefined_;
    }
    if (same_buffer) {
        const byte_count = src_length * src_size;
        const tmp = realm.allocator.alloc(u8, byte_count) catch return error.OutOfMemory;
        defer realm.allocator.free(tmp);
        if (src_base + byte_count <= src_buf.len) {
            @memcpy(tmp, src_buf[src_base .. src_base + byte_count]);
        } else {
            @memset(tmp, 0);
        }
        var i: usize = 0;
        while (i < src_length) : (i += 1) {
            const v = readTypedElement(realm, tmp, src_tv.kind, i * src_size);
            writeTypedElement(dst_buf, tv.kind, dst_base + i * elem_size, v);
        }
        return Value.undefined_;
    }

    var i: usize = 0;
    while (i < src_length) : (i += 1) {
        const v = readTypedElement(realm, src_buf, src_tv.kind, src_base + i * src_size);
        writeTypedElement(dst_buf, tv.kind, dst_base + i * elem_size, v);
    }
    return Value.undefined_;
}

/// §23.2.3.27.1 SetTypedArrayFromArrayLike. ToLength on source.length,
/// then per-element ToNumber / ToBigInt. Throwing converters
/// propagate. After each conversion we re-check the target buffer
/// because a side-effecting valueOf can detach it; writes past a
/// shrunk buffer silently no-op (§10.4.5 IntegerIndexedElementSet).
fn taSetFromArrayLike(
    realm: *Realm,
    target: *JSObject,
    tv_in: ObjMod.TypedView,
    src: *JSObject,
    target_offset: f64,
) NativeError!Value {
    _ = tv_in;
    const src_len_i64 = try intrinsics.toLengthOf(realm, src);
    if (src_len_i64 < 0) return Value.undefined_;
    const src_length: usize = @intCast(src_len_i64);

    const tv = target.typed_view orelse
        return throwTypeError(realm, "TypedArray.prototype.set: target lost typed-view brand");
    const target_length: usize = taInBoundsLength(tv);
    if (tv.viewed.array_buffer == null) {
        return throwTypeError(realm, "TypedArray.prototype.set: target buffer is detached");
    }

    if (target_offset == std.math.inf(f64)) {
        return throwRangeError(realm, "TypedArray.prototype.set: offset out of range");
    }
    const tl_f: f64 = @floatFromInt(target_length);
    const sl_f: f64 = @floatFromInt(src_length);
    if (target_offset + sl_f > tl_f) {
        return throwRangeError(realm, "TypedArray.prototype.set: source overflows destination");
    }

    const offset: usize = @intFromFloat(target_offset);
    const elem_size = tv.kind.elementSize();
    const dst_base = tv.byte_offset + offset * elem_size;

    var k: usize = 0;
    while (k < src_length) : (k += 1) {
        var ibuf: [24]u8 = undefined;
        const key = std.fmt.bufPrint(&ibuf, "{d}", .{k}) catch unreachable;
        const raw = try getPropertyChain(realm, src, key);
        const converted: Value = switch (tv.kind) {
            .bigint64, .biguint64 => try toBigIntValue(realm, raw),
            else => try intrinsics.toNumber(realm, raw),
        };
        const cur_tv = target.typed_view orelse return Value.undefined_;
        const cur_buf = cur_tv.viewed.array_buffer orelse return Value.undefined_;
        const slot = dst_base + k * elem_size;
        if (slot + elem_size > cur_buf.len) continue;
        writeTypedElement(cur_buf, cur_tv.kind, slot, converted);
    }
    return Value.undefined_;
}

// ── TypedArray prototype: per-instance methods (§23.2.3) ─────────────────────
//
// Pattern: pull `obj` + `tv` + `buf`, walk a numeric-index range,
// read/write through `readTypedElement` / `writeTypedElement`.
// TypedArrays don't have holes — every index in `[0, length)` is
// initialised, so we never branch on `hasOwn`.

fn taViewOf(this_value: Value) ?ObjMod.TypedView {
    const obj = heap_mod.valueAsPlainObject(this_value) orelse return null;
    return obj.typed_view;
}

fn taBufOf(tv: ObjMod.TypedView) ?[]u8 {
    return tv.viewed.array_buffer;
}

/// §10.4.5.1 IntegerIndexedElementGet — reads `tv[i]` honoring the
/// "align-detached-buffer-semantics-with-web-reality" rule
/// (ES2024). If the buffer is detached or `i` is out of bounds,
/// return `undefined`; otherwise read the typed slot. Used by the
/// read-only TypedArray methods (`includes` / `indexOf` /
/// `lastIndexOf` / `find*` / `at`) whose spec was relaxed in
/// ES2024 to no longer throw on detached buffers.
fn taSafeRead(realm: *Realm, tv: ObjMod.TypedView, i: i64) Value {
    const buf = tv.viewed.array_buffer orelse return Value.undefined_;
    if (i < 0 or i >= @as(i64, @intCast(tv.length))) return Value.undefined_;
    const elem_size = tv.kind.elementSize();
    const off = tv.byte_offset + @as(usize, @intCast(i)) * elem_size;
    // §10.4.5 IntegerIndexedExoticObject — if the backing store
    // was shrunk below the stored length (resizable ArrayBuffer),
    // the element is out-of-bounds and the spec says return
    // `undefined`. Without this guard, `readTypedElement` reads
    // past `buf.len` and we segfault.
    if (off + elem_size > buf.len) return Value.undefined_;
    return readTypedElement(realm, buf, tv.kind, off);
}

/// §10.4.5 — "live" length. After detach, fixed-length typed
/// arrays keep their stored `[[ArrayLength]]` but their reads
/// return undefined; the loop length is the stored value.
fn taLiveLength(tv: ObjMod.TypedView) i64 {
    return @intCast(tv.length);
}

/// §10.4.5 GetArrayBufferViewByteOffset / MakeTypedArrayWithBufferWitnessRecord —
/// the in-bounds element count under the current backing buffer.
/// For fixed-length views this equals `tv.length` (or 0 if detached);
/// for views over a shrunk resizable buffer it can be less.
/// Returned as `usize` because callers iterate with it.
fn taInBoundsLength(tv: ObjMod.TypedView) usize {
    const buf = tv.viewed.array_buffer orelse return 0;
    if (tv.byte_offset >= buf.len) return 0;
    const elem_size = tv.kind.elementSize();
    const avail_elems = (buf.len - tv.byte_offset) / elem_size;
    return @min(tv.length, avail_elems);
}

/// Resolve a §7.1.5 ToIntegerOrInfinity-style index relative to
/// `length`, with the standard negative-from-end + clamp-to-bounds
/// rules. Used by `slice` / `subarray` / `copyWithin` / `fill`.
/// Routes through `intrinsics.toNumber` so a Symbol / BigInt arg
/// throws TypeError and `{valueOf: () => throw}` propagates.
fn taResolveIndex(realm: *Realm, arg: Value, length: i64, default_val: i64) NativeError!i64 {
    if (arg.isUndefined()) return default_val;
    const v = try intrinsics.toNumber(realm, arg);
    const d: f64 = if (v.isInt32()) @floatFromInt(v.asInt32()) else v.asDouble();
    if (std.math.isNan(d)) return 0;
    var i: i64 = if (std.math.isInf(d)) (if (d > 0) length else -length) else doubleToI64Saturating(@trunc(d));
    if (i < 0) i = @max(length + i, 0);
    return @min(i, length);
}

/// Allocate a fresh TypedArray of `kind` with `length` elements,
/// hooked up to a fresh ArrayBuffer. Used by the methods that
/// produce new typed arrays (`slice`, `map`, `filter`, `toReversed`,
/// `toSorted`, `with`).
fn taMakeNew(realm: *Realm, kind: ObjMod.TypedKind, length: usize) NativeError!*JSObject {
    const ctor_name = nameForTypedKind(kind);
    const ctor_v = realm.globals.get(ctor_name) orelse return throwTypeError(realm, "TypedArray constructor not found");
    const ctor = heap_mod.valueAsFunction(ctor_v) orelse return throwTypeError(realm, "TypedArray constructor not callable");
    const inst = realm.heap.allocateObject() catch return error.OutOfMemory;
    inst.prototype = ctor.prototype;
    const elem_size = kind.elementSize();
    const byte_len = length * elem_size;
    const buf_obj = realm.heap.allocateObject() catch return error.OutOfMemory;
    if (heap_mod.valueAsFunction(realm.globals.get("ArrayBuffer") orelse Value.undefined_)) |ab| {
        buf_obj.prototype = ab.prototype;
    }
    const buf_bytes = realm.allocator.alloc(u8, byte_len) catch return error.OutOfMemory;
    @memset(buf_bytes, 0);
    buf_obj.array_buffer = buf_bytes;
                buf_obj.has_array_buffer_data = true;
    inst.typed_view = .{ .kind = kind, .viewed = buf_obj, .byte_offset = 0, .length = length };
    return inst;
}

/// §23.2.4.7 TypedArraySpeciesCreate(exemplar, argumentList).
///
/// Reads `exemplar.constructor`, then `constructor[@@species]`,
/// falling back to the default constructor (`%Int8Array%` etc.)
/// when either step yields undefined/null. The resolved
/// constructor is invoked with `new ctor(length)` and the
/// result is type-checked: must be a TypedArray instance of
/// matching `kind` and at least `length` long.
///
/// Tests routinely subclass `Uint8Array` and override
/// `@@species` to return a stub constructor — this matters for
/// `slice` / `filter` / `map` whose spec text invokes
/// SpeciesCreate so user subclasses interpose.
fn taSpeciesCreate(realm: *Realm, exemplar: *JSObject, kind: ObjMod.TypedKind, length: usize) NativeError!*JSObject {
    // §7.3.22 SpeciesConstructor step 1 — Get(exemplar, "constructor").
    const ctor_prop = intrinsics.getPropertyChain(realm, exemplar, "constructor") catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.NativeThrew,
    };
    // §7.3.22 step 2 — undefined → default constructor.
    var species_v = Value.undefined_;
    if (!ctor_prop.isUndefined()) {
        // §7.3.22 step 3 — non-object → TypeError.
        const ctor_obj_or_fn = heap_mod.valueAsPlainObject(ctor_prop) orelse blk: {
            if (heap_mod.valueAsFunction(ctor_prop)) |fn_obj| {
                // Use the function's accessor lookup chain.
                species_v = fn_obj.get("@@species");
                break :blk @as(?*JSObject, null);
            }
            return throwTypeError(realm, "exemplar.constructor is not an object");
        };
        if (ctor_obj_or_fn) |obj| {
            species_v = intrinsics.getPropertyChain(realm, obj, "@@species") catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return error.NativeThrew,
            };
        }
        // If `species_v` is the constructor itself with no override,
        // it'll be the original ctor; we still go through the
        // construct path below for spec-correctness.
    }

    // §7.3.22 step 5 — undefined/null → default.
    if (species_v.isUndefined() or species_v.isNull()) {
        return taMakeNew(realm, kind, length);
    }
    // §7.3.22 step 6 — must be a constructor.
    const species_fn = heap_mod.valueAsFunction(species_v) orelse return throwTypeError(realm, "TypedArray @@species is not a constructor");

    // Construct: `new species(length)`. Pass `length` as Number.
    // Open a HandleScope: `constructValue` re-enters the
    // interpreter and may trigger GC, which would sweep
    // ephemeral pointers held in stack-locals here.
    const scope = realm.heap.openScope() catch return error.OutOfMemory;
    defer scope.close();
    const ctor_args = [_]Value{Value.fromInt32(@as(i32, @intCast(@min(length, std.math.maxInt(i32)))))};
    const interpreter = @import("../interpreter.zig");
    const callee_v = heap_mod.taggedFunction(species_fn);
    const outcome = interpreter.constructValue(realm.allocator, realm, callee_v, &ctor_args, callee_v) catch |err| switch (err) {
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
    // §23.2.4.7 step 4 — result must be a TypedArray with matching kind and >= length.
    const result_obj = heap_mod.valueAsPlainObject(result_v) orelse return throwTypeError(realm, "TypedArray species ctor returned non-object");
    const result_tv = result_obj.typed_view orelse return throwTypeError(realm, "TypedArray species ctor returned non-TypedArray");
    if (result_tv.kind != kind) return throwTypeError(realm, "TypedArray species ctor returned wrong content type");
    if (result_tv.length < length) return throwTypeError(realm, "TypedArray species ctor returned too-short TypedArray");
    return result_obj;
}

fn nameForTypedKind(kind: ObjMod.TypedKind) []const u8 {
    return switch (kind) {
        .int8 => "Int8Array",
        .uint8 => "Uint8Array",
        .int16 => "Int16Array",
        .uint16 => "Uint16Array",
        .int32 => "Int32Array",
        .uint32 => "Uint32Array",
        .float32 => "Float32Array",
        .float64 => "Float64Array",
        .bigint64 => "BigInt64Array",
        .biguint64 => "BigUint64Array",
    };
}

/// Common shape for callback-driven methods: pull tv + the
/// mandatory function callback + optional thisArg.
///
/// ES2024 "align-detached-buffer-semantics-with-web-reality" —
/// callback-driven iterators no longer throw on a detached
/// buffer; per-element reads go through `taSafeRead`, which
/// hands back `undefined` for detached / out-of-bounds slots.
fn taCallbackPreamble(realm: *Realm, this_value: Value, args: []const Value) NativeError!struct {
    tv: ObjMod.TypedView,
    buf: ?[]u8,
    callback: *JSFunction,
    this_arg: Value,
    self_obj: *JSObject,
} {
    const obj = heap_mod.valueAsPlainObject(this_value) orelse return throwTypeError(realm, "TypedArray method on non-object");
    const tv = obj.typed_view orelse return throwTypeError(realm, "TypedArray method on non-TypedArray");
    const callback = heap_mod.valueAsFunction(argOr(args, 0, Value.undefined_)) orelse return throwTypeError(realm, "callback is not a function");
    const this_arg = argOr(args, 1, Value.undefined_);
    return .{ .tv = tv, .buf = tv.viewed.array_buffer, .callback = callback, .this_arg = this_arg, .self_obj = obj };
}

fn typedArrayAt(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const tv = taViewOf(this_value) orelse return throwTypeError(realm, "at on non-TypedArray");
    const len: i64 = @intCast(tv.length);
    const i = try taResolveIndex(realm, argOr(args, 0, Value.fromInt32(0)), len, 0);
    // `at` returns undefined for out-of-range; resolveIndex clamps,
    // so we re-check using the raw arg to detect "explicitly out of
    // range" vs "negative index in range."
    const raw = argOr(args, 0, Value.fromInt32(0));
    const raw_n: f64 = if (raw.isInt32()) @floatFromInt(raw.asInt32()) else if (raw.isDouble()) raw.asDouble() else 0;
    const raw_i: i64 = if (std.math.isNan(raw_n)) 0 else @intFromFloat(@trunc(raw_n));
    const target_i: i64 = if (raw_i < 0) raw_i + len else raw_i;
    if (target_i < 0 or target_i >= len) return Value.undefined_;
    _ = i;
    // §23.2.3.1 — `at` reads through the IntegerIndexedElementGet
    // path; ES2024 detached buffers return undefined, not throw.
    return taSafeRead(realm, tv, target_i);
}

fn typedArrayCopyWithin(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const obj = heap_mod.valueAsPlainObject(this_value) orelse return error.NativeThrew;
    const tv = obj.typed_view orelse return error.NativeThrew;
    const buf = tv.viewed.array_buffer orelse return error.NativeThrew;
    const len: i64 = @intCast(tv.length);
    const target = try taResolveIndex(realm, argOr(args, 0, Value.fromInt32(0)), len, 0);
    const start = try taResolveIndex(realm, argOr(args, 1, Value.fromInt32(0)), len, 0);
    const end = try taResolveIndex(realm, argOr(args, 2, Value.undefined_), len, len);
    const count = @min(end - start, len - target);
    if (count <= 0) return this_value;
    const elem_size = tv.kind.elementSize();
    const byte_count: usize = @as(usize, @intCast(count)) * elem_size;
    const src_off = tv.byte_offset + @as(usize, @intCast(start)) * elem_size;
    const dst_off = tv.byte_offset + @as(usize, @intCast(target)) * elem_size;
    // §23.2.3.6 copyWithin uses memmove-style overlap-safe copy.
    // Zig's `@memcpy` panics on aliased ranges, so dispatch into
    // the std forward / backward variants based on the copy
    // direction. (Identical ranges short-circuit cleanly via
    // `copyForwards` either way.)
    if (dst_off > src_off) {
        std.mem.copyBackwards(u8, buf[dst_off .. dst_off + byte_count], buf[src_off .. src_off + byte_count]);
    } else {
        std.mem.copyForwards(u8, buf[dst_off .. dst_off + byte_count], buf[src_off .. src_off + byte_count]);
    }
    return this_value;
}

fn typedArrayForEach(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const ctx = try taCallbackPreamble(realm, this_value, args);
    var i: usize = 0;
    while (i < ctx.tv.length) : (i += 1) {
        const v = taSafeRead(realm, ctx.tv, @intCast(i));
        _ = try invokeCallback(realm, ctx.callback, ctx.this_arg, v, @intCast(i), ctx.self_obj);
    }
    return Value.undefined_;
}

fn typedArrayEvery(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const ctx = try taCallbackPreamble(realm, this_value, args);
    var i: usize = 0;
    while (i < ctx.tv.length) : (i += 1) {
        const v = taSafeRead(realm, ctx.tv, @intCast(i));
        const r = try invokeCallback(realm, ctx.callback, ctx.this_arg, v, @intCast(i), ctx.self_obj);
        if (!toBoolean(r)) return Value.false_;
    }
    return Value.true_;
}

fn typedArraySome(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const ctx = try taCallbackPreamble(realm, this_value, args);
    var i: usize = 0;
    while (i < ctx.tv.length) : (i += 1) {
        const v = taSafeRead(realm, ctx.tv, @intCast(i));
        const r = try invokeCallback(realm, ctx.callback, ctx.this_arg, v, @intCast(i), ctx.self_obj);
        if (toBoolean(r)) return Value.true_;
    }
    return Value.false_;
}

fn typedArrayFind(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const ctx = try taCallbackPreamble(realm, this_value, args);
    var i: usize = 0;
    while (i < ctx.tv.length) : (i += 1) {
        const v = taSafeRead(realm, ctx.tv, @intCast(i));
        const r = try invokeCallback(realm, ctx.callback, ctx.this_arg, v, @intCast(i), ctx.self_obj);
        if (toBoolean(r)) return v;
    }
    return Value.undefined_;
}

fn typedArrayFindIndex(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const ctx = try taCallbackPreamble(realm, this_value, args);
    var i: usize = 0;
    while (i < ctx.tv.length) : (i += 1) {
        const v = taSafeRead(realm, ctx.tv, @intCast(i));
        const r = try invokeCallback(realm, ctx.callback, ctx.this_arg, v, @intCast(i), ctx.self_obj);
        if (toBoolean(r)) return numberFromI64(@intCast(i));
    }
    return Value.fromInt32(-1);
}

fn typedArrayFindLast(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const ctx = try taCallbackPreamble(realm, this_value, args);
    var i: i64 = @as(i64, @intCast(ctx.tv.length)) - 1;
    while (i >= 0) : (i -= 1) {
        const v = taSafeRead(realm, ctx.tv, i);
        const r = try invokeCallback(realm, ctx.callback, ctx.this_arg, v, i, ctx.self_obj);
        if (toBoolean(r)) return v;
    }
    return Value.undefined_;
}

fn typedArrayFindLastIndex(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const ctx = try taCallbackPreamble(realm, this_value, args);
    var i: i64 = @as(i64, @intCast(ctx.tv.length)) - 1;
    while (i >= 0) : (i -= 1) {
        const v = taSafeRead(realm, ctx.tv, i);
        const r = try invokeCallback(realm, ctx.callback, ctx.this_arg, v, i, ctx.self_obj);
        if (toBoolean(r)) return numberFromI64(i);
    }
    return Value.fromInt32(-1);
}

fn typedArrayIncludes(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    // §23.2.3.14 — ES2024 "web reality": a detached buffer reads
    // as undefined per element; we don't throw. The length stays
    // at its stored value (fixed-length TAs aren't auto).
    const tv = taViewOf(this_value) orelse return throwTypeError(realm, "includes on non-TypedArray");
    const target = argOr(args, 0, Value.undefined_);
    const len: i64 = @intCast(tv.length);
    const from_arg = argOr(args, 1, Value.fromInt32(0));
    var from = try taResolveIndex(realm, from_arg, len, 0);
    if (from < 0) from = 0;
    var i: i64 = from;
    while (i < len) : (i += 1) {
        const v = taSafeRead(realm, tv, i);
        if (sameValueZero(v, target)) return Value.true_;
    }
    return Value.false_;
}

fn typedArrayIndexOf(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const tv = taViewOf(this_value) orelse return throwTypeError(realm, "indexOf on non-TypedArray");
    // §23.2.3.18 — when detached, no element strictly equals the
    // target (reads are `undefined`, strict-equality of two
    // undefineds is true *but* indexOf checks element-not-undefined
    // via SameValueZero — actually wait, indexOf uses IsStrictlyEqual,
    // not SameValueZero. `undefined === target` only when target is
    // undefined, but indexOf step 6 short-circuits the loop when
    // searchElement is undefined and len=0). To keep behavior
    // simple and matching V8/JSC: if detached, return -1.
    if (tv.viewed.array_buffer == null) return Value.fromInt32(-1);
    const target = argOr(args, 0, Value.undefined_);
    const len: i64 = @intCast(tv.length);
    var from = try taResolveIndex(realm, argOr(args, 1, Value.fromInt32(0)), len, 0);
    if (from < 0) from = 0;
    var i: i64 = from;
    while (i < len) : (i += 1) {
        const v = taSafeRead(realm, tv, i);
        if (strictEqualsLite(v, target)) return numberFromI64(i);
    }
    return Value.fromInt32(-1);
}

fn typedArrayLastIndexOf(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const tv = taViewOf(this_value) orelse return throwTypeError(realm, "lastIndexOf on non-TypedArray");
    if (tv.viewed.array_buffer == null) return Value.fromInt32(-1);
    const target = argOr(args, 0, Value.undefined_);
    const len: i64 = @intCast(tv.length);
    var from: i64 = len - 1;
    if (args.len > 1 and !args[1].isUndefined()) {
        from = try taResolveIndex(realm, args[1], len, len - 1);
        if (from >= len) from = len - 1;
    }
    var i: i64 = from;
    while (i >= 0) : (i -= 1) {
        const v = taSafeRead(realm, tv, i);
        if (strictEqualsLite(v, target)) return numberFromI64(i);
    }
    return Value.fromInt32(-1);
}

fn typedArrayJoin(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const tv = taViewOf(this_value) orelse return throwTypeError(realm, "join on non-TypedArray");
    const buf = taBufOf(tv) orelse return throwTypeError(realm, "TypedArray detached");
    const sep_v = argOr(args, 0, Value.undefined_);
    const sep_s: []const u8 = if (sep_v.isUndefined()) "," else blk: {
        const s = try stringifyArg(realm, sep_v);
        break :blk s.bytes;
    };
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(realm.allocator);
    const elem_size = tv.kind.elementSize();
    var i: usize = 0;
    while (i < tv.length) : (i += 1) {
        if (i > 0) out.appendSlice(realm.allocator, sep_s) catch return error.OutOfMemory;
        const v = readTypedElement(realm, buf, tv.kind, tv.byte_offset + i * elem_size);
        const s = try stringifyArg(realm, v);
        out.appendSlice(realm.allocator, s.bytes) catch return error.OutOfMemory;
    }
    const result = realm.heap.allocateString(out.items) catch return error.OutOfMemory;
    return Value.fromString(result);
}

fn typedArrayToString(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = args;
    return typedArrayJoin(realm, this_value, &.{});
}

/// §23.2.3.32 %TypedArray%.prototype.toLocaleString — same shape
/// as Array.prototype.toLocaleString (§23.1.3.32) but reads the
/// length / index slots from the typed view directly. For each
/// element, `Invoke(elt, "toLocaleString")` and join with ",".
/// Locale-aware separators / format options aren't surfaced —
/// Cynic doesn't ship Intl (out of scope per AGENTS.md).
fn typedArrayToLocaleString(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = args;
    const tv = taViewOf(this_value) orelse return throwTypeError(realm, "toLocaleString on non-TypedArray");
    const buf = taBufOf(tv) orelse return throwTypeError(realm, "TypedArray detached");
    const elem_size = tv.kind.elementSize();
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(realm.allocator);
    const interpreter = @import("../interpreter.zig");
    var i: usize = 0;
    while (i < tv.length) : (i += 1) {
        if (i > 0) out.appendSlice(realm.allocator, ",") catch return error.OutOfMemory;
        const v = readTypedElement(realm, buf, tv.kind, tv.byte_offset + i * elem_size);
        // §23.2.3.34 step 7 — `Invoke(elt, "toLocaleString")`
        // observes the user-installed
        // `Number.prototype.toLocaleString` (or BigInt's). Box the
        // primitive, look up the method through the prototype chain,
        // then call it with the boxed receiver. Cynic doesn't ship
        // Intl, so the engine-default `toLocaleString` reduces to
        // ToString — but user overrides need to fire.
        const boxed = try intrinsics.toObjectThis(realm, v);
        const method_v = boxed.get("toLocaleString");
        var str_v: Value = undefined;
        if (heap_mod.valueAsFunction(method_v)) |_| {
            const outcome = interpreter.callValue(realm.allocator, realm, method_v, heap_mod.taggedObject(boxed), &.{}) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return error.NativeThrew,
            };
            switch (outcome) {
                .value, .yielded => |x| str_v = x,
                .thrown => return error.NativeThrew,
            }
        } else {
            str_v = v;
        }
        const s = try stringifyArg(realm, str_v);
        out.appendSlice(realm.allocator, s.bytes) catch return error.OutOfMemory;
    }
    const result = realm.heap.allocateString(out.items) catch return error.OutOfMemory;
    return Value.fromString(result);
}

fn typedArrayReduce(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const obj = heap_mod.valueAsPlainObject(this_value) orelse return throwTypeError(realm, "reduce on non-TypedArray");
    const tv = obj.typed_view orelse return throwTypeError(realm, "reduce on non-TypedArray");
    const buf = tv.viewed.array_buffer orelse return throwTypeError(realm, "TypedArray detached");
    const callback = heap_mod.valueAsFunction(argOr(args, 0, Value.undefined_)) orelse return throwTypeError(realm, "callback is not a function");
    const elem_size = tv.kind.elementSize();
    const has_init = args.len >= 2;
    if (tv.length == 0 and !has_init) return throwTypeError(realm, "Reduce of empty TypedArray with no initial value");
    var acc: Value = if (has_init) args[1] else readTypedElement(realm, buf, tv.kind, tv.byte_offset);
    var i: usize = if (has_init) 0 else 1;
    while (i < tv.length) : (i += 1) {
        const v = readTypedElement(realm, buf, tv.kind, tv.byte_offset + i * elem_size);
        const interpreter = @import("../interpreter.zig");
        const cb_args = [_]Value{ acc, v, numberFromI64(@intCast(i)), heap_mod.taggedObject(obj) };
        const outcome = interpreter.callJSFunction(realm.allocator, realm, callback, Value.undefined_, &cb_args) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.NativeThrew,
        };
        switch (outcome) {
            .value, .yielded => |x| acc = x,
            .thrown => return error.NativeThrew,
        }
    }
    return acc;
}

fn typedArrayReduceRight(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const obj = heap_mod.valueAsPlainObject(this_value) orelse return throwTypeError(realm, "reduceRight on non-TypedArray");
    const tv = obj.typed_view orelse return throwTypeError(realm, "reduceRight on non-TypedArray");
    const buf = tv.viewed.array_buffer orelse return throwTypeError(realm, "TypedArray detached");
    const callback = heap_mod.valueAsFunction(argOr(args, 0, Value.undefined_)) orelse return throwTypeError(realm, "callback is not a function");
    const elem_size = tv.kind.elementSize();
    const has_init = args.len >= 2;
    if (tv.length == 0 and !has_init) return throwTypeError(realm, "Reduce of empty TypedArray with no initial value");
    var i: i64 = @as(i64, @intCast(tv.length)) - 1;
    var acc: Value = if (has_init) args[1] else blk: {
        const v = readTypedElement(realm, buf, tv.kind, tv.byte_offset + @as(usize, @intCast(i)) * elem_size);
        i -= 1;
        break :blk v;
    };
    while (i >= 0) : (i -= 1) {
        const v = readTypedElement(realm, buf, tv.kind, tv.byte_offset + @as(usize, @intCast(i)) * elem_size);
        const interpreter = @import("../interpreter.zig");
        const cb_args = [_]Value{ acc, v, numberFromI64(i), heap_mod.taggedObject(obj) };
        const outcome = interpreter.callJSFunction(realm.allocator, realm, callback, Value.undefined_, &cb_args) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.NativeThrew,
        };
        switch (outcome) {
            .value, .yielded => |x| acc = x,
            .thrown => return error.NativeThrew,
        }
    }
    return acc;
}

fn typedArrayReverse(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = realm;
    _ = args;
    const obj = heap_mod.valueAsPlainObject(this_value) orelse return error.NativeThrew;
    const tv = obj.typed_view orelse return error.NativeThrew;
    const buf = tv.viewed.array_buffer orelse return error.NativeThrew;
    const elem_size = tv.kind.elementSize();
    var lo: usize = 0;
    var hi: usize = tv.length;
    if (hi == 0) return this_value;
    hi -= 1;
    while (lo < hi) : ({
        lo += 1;
        hi -= 1;
    }) {
        const lo_off = tv.byte_offset + lo * elem_size;
        const hi_off = tv.byte_offset + hi * elem_size;
        var k: usize = 0;
        while (k < elem_size) : (k += 1) {
            const tmp = buf[lo_off + k];
            buf[lo_off + k] = buf[hi_off + k];
            buf[hi_off + k] = tmp;
        }
    }
    return this_value;
}

// ── TypedArray prototype: methods that allocate a new TA ─────────────────────

fn typedArraySlice(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const self = heap_mod.valueAsPlainObject(this_value) orelse return throwTypeError(realm, "slice on non-TypedArray");
    const tv_pre = self.typed_view orelse return throwTypeError(realm, "slice on non-TypedArray");
    const len: i64 = @intCast(tv_pre.length);
    const start = try taResolveIndex(realm, argOr(args, 0, Value.fromInt32(0)), len, 0);
    const end = try taResolveIndex(realm, argOr(args, 1, Value.undefined_), len, len);
    const new_len: usize = if (end > start) @intCast(end - start) else 0;
    const kind = tv_pre.kind;
    // §23.2.3.27 step 13 — TypedArraySpeciesCreate(O, « count »).
    // The construct call re-enters the interpreter; user
    // species ctors can detach the buffer mid-call. Re-read tv
    // and buf AFTER the construct so we don't dereference a
    // freed pointer.
    const out = try taSpeciesCreate(realm, self, kind, new_len);
    if (new_len > 0) {
        const tv = self.typed_view orelse return throwTypeError(realm, "TypedArray detached during slice");
        const buf = taBufOf(tv) orelse return throwTypeError(realm, "TypedArray detached during slice");
        const elem_size = kind.elementSize();
        const out_tv = out.typed_view orelse return throwTypeError(realm, "Species ctor returned non-TypedArray");
        const out_buf = out_tv.viewed.array_buffer orelse return throwTypeError(realm, "Species ctor returned detached buffer");
        const src_off = tv.byte_offset + @as(usize, @intCast(start)) * elem_size;
        // Clamp copy to what's actually available in source AND
        // destination. ES2024 resizable buffers can leave both
        // shrunk under the views captured here — copying a full
        // `new_len * elem_size` would slice past `buf.len` or
        // `out_buf.len` and panic.
        const want = new_len * elem_size;
        const src_avail: usize = if (src_off >= buf.len) 0 else @min(want, buf.len - src_off);
        const dst_off = out_tv.byte_offset;
        const dst_avail: usize = if (dst_off >= out_buf.len) 0 else @min(want, out_buf.len - dst_off);
        const avail = @min(src_avail, dst_avail);
        if (avail > 0) @memcpy(out_buf[dst_off .. dst_off + avail], buf[src_off .. src_off + avail]);
    }
    return heap_mod.taggedObject(out);
}

fn typedArraySubarray(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const self = heap_mod.valueAsPlainObject(this_value) orelse return throwTypeError(realm, "subarray on non-TypedArray");
    const tv = self.typed_view orelse return throwTypeError(realm, "subarray on non-TypedArray");
    const len: i64 = @intCast(tv.length);
    const begin = try taResolveIndex(realm, argOr(args, 0, Value.fromInt32(0)), len, 0);
    const end = try taResolveIndex(realm, argOr(args, 1, Value.undefined_), len, len);
    const new_len: usize = if (end > begin) @intCast(end - begin) else 0;
    const elem_size = tv.kind.elementSize();
    const new_offset = tv.byte_offset + @as(usize, @intCast(begin)) * elem_size;

    // §23.2.3.30 step 14 — `TypedArraySpeciesCreate(O, «
    // buffer, byteOffset, newLength »)`. Three-arg shape, unlike
    // `slice`/`map`/`filter` (one arg = length); use a dedicated
    // helper instead of `taSpeciesCreate`. Default case (no
    // override) builds a view directly on the shared buffer.
    const out_obj = try taSpeciesCreateSubarray(realm, self, tv.kind, tv.viewed, new_offset, new_len);
    return heap_mod.taggedObject(out_obj);
}

/// §23.2.3.30 — TypedArraySpeciesCreate for subarray. Distinct
/// from `taSpeciesCreate` because the constructor receives
/// `(buffer, byteOffset, length)`, not `(length)`. When there's
/// no user-installed `@@species`, we build the view inline
/// without going through the constructor (faster, no
/// re-entry).
fn taSpeciesCreateSubarray(
    realm: *Realm,
    exemplar: *JSObject,
    kind: ObjMod.TypedKind,
    buffer: *JSObject,
    byte_offset: usize,
    length: usize,
) NativeError!*JSObject {
    const ctor_prop = intrinsics.getPropertyChain(realm, exemplar, "constructor") catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.NativeThrew,
    };
    var species_v = Value.undefined_;
    if (!ctor_prop.isUndefined()) {
        const ctor_obj_or_fn = heap_mod.valueAsPlainObject(ctor_prop) orelse blk: {
            if (heap_mod.valueAsFunction(ctor_prop)) |fn_obj| {
                species_v = fn_obj.get("@@species");
                break :blk @as(?*JSObject, null);
            }
            return throwTypeError(realm, "exemplar.constructor is not an object");
        };
        if (ctor_obj_or_fn) |obj| {
            species_v = intrinsics.getPropertyChain(realm, obj, "@@species") catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return error.NativeThrew,
            };
        }
    }

    if (species_v.isUndefined() or species_v.isNull()) {
        // Default — build inline, reusing the shared buffer.
        const ctor = heap_mod.valueAsFunction(realm.globals.get(nameForTypedKind(kind)) orelse Value.undefined_) orelse return throwTypeError(realm, "TypedArray constructor not found");
        const inst = realm.heap.allocateObject() catch return error.OutOfMemory;
        inst.prototype = ctor.prototype;
        inst.typed_view = .{
            .kind = kind,
            .viewed = buffer,
            .byte_offset = byte_offset,
            .length = length,
        };
        return inst;
    }
    const species_fn = heap_mod.valueAsFunction(species_v) orelse return throwTypeError(realm, "TypedArray @@species is not a constructor");
    const scope = realm.heap.openScope() catch return error.OutOfMemory;
    defer scope.close();
    const ctor_args = [_]Value{
        heap_mod.taggedObject(buffer),
        Value.fromInt32(@as(i32, @intCast(@min(byte_offset, std.math.maxInt(i32))))),
        Value.fromInt32(@as(i32, @intCast(@min(length, std.math.maxInt(i32))))),
    };
    const interpreter = @import("../interpreter.zig");
    const callee_v = heap_mod.taggedFunction(species_fn);
    const outcome = interpreter.constructValue(realm.allocator, realm, callee_v, &ctor_args, callee_v) catch |err| switch (err) {
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
    const result_obj = heap_mod.valueAsPlainObject(result_v) orelse return throwTypeError(realm, "TypedArray species ctor returned non-object");
    const result_tv = result_obj.typed_view orelse return throwTypeError(realm, "TypedArray species ctor returned non-TypedArray");
    if (result_tv.kind != kind) return throwTypeError(realm, "TypedArray species ctor returned wrong content type");
    return result_obj;
}

fn typedArrayMap(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const ctx = try taCallbackPreamble(realm, this_value, args);
    // §23.2.3.19 step 6 — TypedArraySpeciesCreate(O, « len »).
    const out = try taSpeciesCreate(realm, ctx.self_obj, ctx.tv.kind, ctx.tv.length);
    const out_buf = out.typed_view.?.viewed.array_buffer.?;
    const elem_size = ctx.tv.kind.elementSize();
    var i: usize = 0;
    while (i < ctx.tv.length) : (i += 1) {
        const v = taSafeRead(realm, ctx.tv, @intCast(i));
        const mapped = try invokeCallback(realm, ctx.callback, ctx.this_arg, v, @intCast(i), ctx.self_obj);
        writeTypedElement(out_buf, ctx.tv.kind, i * elem_size, mapped);
    }
    return heap_mod.taggedObject(out);
}

fn typedArrayFilter(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const ctx = try taCallbackPreamble(realm, this_value, args);
    // Two-pass: first decide which elements are kept (record into
    // a temp byte array), then allocate the result with the exact
    // size and copy. Avoids two reallocations for the common case
    // where most pass.
    var kept: std.ArrayListUnmanaged(usize) = .empty;
    defer kept.deinit(realm.allocator);
    var i: usize = 0;
    while (i < ctx.tv.length) : (i += 1) {
        const v = taSafeRead(realm, ctx.tv, @intCast(i));
        const r = try invokeCallback(realm, ctx.callback, ctx.this_arg, v, @intCast(i), ctx.self_obj);
        if (toBoolean(r)) kept.append(realm.allocator, i) catch return error.OutOfMemory;
    }
    // §23.2.3.10 step 12 — TypedArraySpeciesCreate(O, « kept.length »).
    const out = try taSpeciesCreate(realm, ctx.self_obj, ctx.tv.kind, kept.items.len);
    const out_buf = out.typed_view.?.viewed.array_buffer.?;
    const elem_size = ctx.tv.kind.elementSize();
    // Length-tracking destinations whose backing buffer has been
    // resized below kept.len*elem_size after taSpeciesCreate
    // returned (e.g. species ctor handed us a TA over a shrunk
    // resizable buffer) — clamp so the memcpy stays in-bounds.
    // Per §23.2.4.1 the species result is also required to have
    // length ≥ count, but the check is `[[ArrayLength]]`, not
    // `byteLength`, and a length-tracking view of a resized-down
    // buffer reports the construction-time length while exposing
    // a smaller backing slice.
    const src_buf_opt = ctx.tv.viewed.array_buffer;
    const dst_cap = out_buf.len;
    for (kept.items, 0..) |src_i, dst_i| {
        const src_off = ctx.tv.byte_offset + src_i * elem_size;
        const dst_off = dst_i * elem_size;
        if (dst_off + elem_size > dst_cap) break;
        if (src_buf_opt) |src_buf| {
            if (src_off + elem_size > src_buf.len) break;
            @memcpy(out_buf[dst_off .. dst_off + elem_size], src_buf[src_off .. src_off + elem_size]);
        }
    }
    return heap_mod.taggedObject(out);
}

// ── §25.3 DataView ──────────────────────────────────────────────────────────

fn dataViewConstructor(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const inst = heap_mod.valueAsPlainObject(this_value) orelse return throwTypeError(realm, "DataView constructor requires 'new'");
    const buf_arg = argOr(args, 0, Value.undefined_);
    const buf_obj = heap_mod.valueAsPlainObject(buf_arg) orelse return throwTypeError(realm, "DataView: first argument must be an ArrayBuffer");
    // The first argument has to *be* an ArrayBuffer object, not
    // some random object — but checking `array_buffer != null`
    // also covers the detached case, which §25.3.2.1 step 6 says
    // throws TypeError ("If IsDetachedBuffer(buffer) is true").
    if (buf_obj.array_buffer == null) return throwTypeError(realm, "DataView: ArrayBuffer is detached");

    // §7.1.17 ToIndex — runs BEFORE the buffer-length read, since
    // the user's `valueOf` could detach the buffer mid-call.
    const byte_offset = try dvToIndex(realm, argOr(args, 1, Value.undefined_));

    // Re-check detachment / fetch buf after each user-observable
    // step (ToIndex can call into JS via `valueOf`).
    const buf1 = buf_obj.array_buffer orelse return throwTypeError(realm, "DataView: ArrayBuffer detached during construction");
    if (byte_offset > buf1.len) return throwRangeError(realm, "DataView: byteOffset exceeds buffer");

    const length_arg = argOr(args, 2, Value.undefined_);
    var byte_length: usize = undefined;
    if (length_arg.isUndefined()) {
        byte_length = buf1.len - byte_offset;
    } else {
        byte_length = try dvToIndex(realm, length_arg);
        const buf2 = buf_obj.array_buffer orelse return throwTypeError(realm, "DataView: ArrayBuffer detached during construction");
        if (byte_offset > buf2.len or byte_length > buf2.len - byte_offset) return throwRangeError(realm, "DataView: byteLength exceeds buffer");
    }
    inst.data_view = .{ .viewed = buf_obj, .byte_offset = byte_offset, .byte_length = byte_length };
    return this_value;
}

/// §7.1.17 ToIndex. Throws TypeError on Symbol/BigInt (via
/// `dvToNumber`), RangeError on non-integer / NaN / Infinity /
/// negative, and caps at 2^53 - 1. Result is a usize.
fn dvToIndex(realm: *Realm, v: Value) NativeError!usize {
    if (v.isUndefined()) return 0;
    const num = try dvToNumber(realm, v);
    const d: f64 = if (num.isInt32()) @floatFromInt(num.asInt32()) else num.asDouble();
    // §7.1.5 ToIntegerOrInfinity then §7.1.17 step 3 — NaN ⇒ 0,
    // but ToIndex step 4 requires integerIndex == ToIntegerOrInfinity
    // and rejects negative / >2^53-1. -0 collapses to 0 here
    // (truncation), which is what the spec mandates.
    if (std.math.isNan(d)) return 0;
    const truncd = @trunc(d);
    if (truncd < 0) return throwRangeError(realm, "ToIndex: value is negative");
    const cap_ix: f64 = 9007199254740992.0; // 2^53
    if (truncd >= cap_ix) return throwRangeError(realm, "ToIndex: value exceeds 2^53-1");
    return @intFromFloat(truncd);
}

/// §7.1.4 ToNumber wrapped to throw TypeError for Symbol and
/// BigInt, which the underlying `intrinsics.toNumber` doesn't
/// handle (it falls back to NaN for those tags). DataView paths
/// always need the throwing behaviour per spec §25.3.1.1 step 4.
/// We do ToPrimitive first so a `valueOf`/`@@toPrimitive` that
/// returns a Symbol/BigInt also lands in the TypeError branch
/// (the underlying `toNumber` would silently NaN those).
fn dvToNumber(realm: *Realm, v: Value) NativeError!Value {
    const prim = try intrinsics.toPrimitive(realm, v, .number);
    if (heap_mod.valueAsSymbol(prim) != null) return throwTypeError(realm, "Cannot convert a Symbol value to a Number");
    if (heap_mod.valueAsBigInt(prim) != null) return throwTypeError(realm, "Cannot convert a BigInt value to a Number");
    return coerceToNumber(prim);
}

/// §7.1.13 ToBigInt — DataView's BigInt setters need this. Inlined
/// here because `bigint.zig` keeps `toBigIntValue` private. Returns
/// the i64 value already truncated for storage.
fn dvToBigInt64(realm: *Realm, v: Value) NativeError!i64 {
    // ToPrimitive(value, hint Number) — the spec says "default" hint
    // for ToBigInt actually, but for our purposes (no Date/Symbol
    // detection), `.number` is fine since BigInt-flavoured `valueOf`
    // returns a BigInt directly.
    const prim = try intrinsics.toPrimitive(realm, v, .number);
    if (heap_mod.valueAsBigInt(prim)) |bi| return @as(i64, @truncate(bi.value));
    if (prim.isBool()) return if (prim.asBool()) 1 else 0;
    if (prim.isString()) {
        const s: *JSString = @ptrCast(@alignCast(prim.asString()));
        const trimmed = std.mem.trim(u8, s.bytes, " \t\n\r");
        if (trimmed.len == 0) return 0;
        var negate = false;
        var rest = trimmed;
        if (rest[0] == '-') { negate = true; rest = rest[1..]; } else if (rest[0] == '+') { rest = rest[1..]; }
        if (rest.len == 0) return throwTypeError(realm, "Cannot convert string to BigInt");
        const parsed = std.fmt.parseInt(i128, rest, 0) catch return throwTypeError(realm, "Cannot convert string to BigInt");
        const final: i128 = if (negate) -parsed else parsed;
        return @as(i64, @truncate(final));
    }
    // Numbers, null, undefined, Symbol → TypeError per §7.1.13.
    return throwTypeError(realm, "Cannot convert value to BigInt");
}

fn dvOf(this_value: Value) ?ObjMod.DataView {
    const obj = heap_mod.valueAsPlainObject(this_value) orelse return null;
    return obj.data_view;
}

fn dataViewByteLength(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = args;
    const dv = dvOf(this_value) orelse return throwTypeError(realm, "DataView accessor on non-DataView");
    // §25.3.4.1 step 6 — throw if buffer is detached.
    if (dv.viewed.array_buffer == null) return throwTypeError(realm, "DataView: buffer is detached");
    return Value.fromInt32(@intCast(dv.byte_length));
}

fn dataViewByteOffset(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = args;
    const dv = dvOf(this_value) orelse return throwTypeError(realm, "DataView accessor on non-DataView");
    // §25.3.4.2 step 6 — throw if buffer is detached.
    if (dv.viewed.array_buffer == null) return throwTypeError(realm, "DataView: buffer is detached");
    return Value.fromInt32(@intCast(dv.byte_offset));
}

fn dataViewBuffer(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = args;
    // §25.3.4.4 — `buffer` getter returns the [[ViewedArrayBuffer]]
    // even when detached (no detached check, unlike byteLength /
    // byteOffset). Detached state is observable as `byteLength === 0`.
    const dv = dvOf(this_value) orelse return throwTypeError(realm, "DataView accessor on non-DataView");
    return heap_mod.taggedObject(dv.viewed);
}

fn dvLittleEndian(args: []const Value, idx: usize) bool {
    return idx < args.len and toBoolean(args[idx]);
}

/// §25.3.1.1 GetViewValue prologue. Returns `(dv, buf, byteOffset)`
/// after running ToIndex(byteOffset) (which can call into JS via
/// `valueOf`), checking detachment, and verifying bounds — in
/// that exact order. The caller does the read on `buf[byte_offset]`.
const DvAccess = struct { dv: ObjMod.DataView, buf: []u8, abs_offset: usize };

fn dvGetPrologue(realm: *Realm, this_value: Value, args: []const Value, elem_size: usize) NativeError!DvAccess {
    const dv = dvOf(this_value) orelse return throwTypeError(realm, "DataView method on non-DataView");
    // §25.3.1.1 step 4 — ToIndex first (its valueOf could detach).
    const off = try dvToIndex(realm, argOr(args, 0, Value.undefined_));
    // step 8 — RequireInternalSlot already done; step 9 — IsDetachedBuffer.
    const buf = dv.viewed.array_buffer orelse return throwTypeError(realm, "DataView: buffer is detached");
    // step 12-13 — bounds (overflow-safe).
    if (elem_size > dv.byte_length or off > dv.byte_length - elem_size) {
        return throwRangeError(realm, "DataView: byte offset out of bounds");
    }
    return .{ .dv = dv, .buf = buf, .abs_offset = dv.byte_offset + off };
}

/// §25.3.1.2 SetViewValue prologue for numeric setters. Order is:
/// ToIndex(byteOffset) → ToNumber(value) → detached check →
/// bounds check. Both ToIndex and ToNumber can re-enter JS, so we
/// re-fetch the buffer slice afterwards.
const DvSetNum = struct { dv: ObjMod.DataView, buf: []u8, abs_offset: usize, value: f64 };

fn dvSetNumPrologue(realm: *Realm, this_value: Value, args: []const Value, elem_size: usize) NativeError!DvSetNum {
    const dv = dvOf(this_value) orelse return throwTypeError(realm, "DataView method on non-DataView");
    const off = try dvToIndex(realm, argOr(args, 0, Value.undefined_));
    const num_v = try dvToNumber(realm, argOr(args, 1, Value.undefined_));
    const buf = dv.viewed.array_buffer orelse return throwTypeError(realm, "DataView: buffer is detached");
    if (elem_size > dv.byte_length or off > dv.byte_length - elem_size) {
        return throwRangeError(realm, "DataView: byte offset out of bounds");
    }
    const d: f64 = if (num_v.isInt32()) @floatFromInt(num_v.asInt32()) else num_v.asDouble();
    return .{ .dv = dv, .buf = buf, .abs_offset = dv.byte_offset + off, .value = d };
}

/// §7.1.6 ToInt32 on an f64 — modular 2^32, sign-reinterpret. NaN /
/// ±Infinity collapse to 0 per spec. Branchless cast through u32
/// avoids `@intFromFloat` panics for huge inputs.
fn toInt32Mod(d: f64) i32 {
    if (std.math.isNan(d) or std.math.isInf(d)) return 0;
    const TWO32: f64 = 4294967296.0;
    const truncd = @trunc(d);
    const m = truncd - @floor(truncd / TWO32) * TWO32;
    const adjusted = if (m < 0) m + TWO32 else m;
    const u: u32 = @intFromFloat(adjusted);
    return @bitCast(u);
}

fn dvReadEndian(comptime T: type, buf: []const u8, off: usize, le: bool) T {
    const slice = buf[off..][0..@sizeOf(T)];
    return std.mem.readInt(T, slice, if (le) .little else .big);
}
fn dvWriteEndian(comptime T: type, buf: []u8, off: usize, value: T, le: bool) void {
    const slice = buf[off..][0..@sizeOf(T)];
    std.mem.writeInt(T, slice, value, if (le) .little else .big);
}

// Get* methods.
fn dataViewGetInt8(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const a = try dvGetPrologue(realm, this_value, args, 1);
    return Value.fromInt32(@as(i8, @bitCast(a.buf[a.abs_offset])));
}
fn dataViewGetUint8(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const a = try dvGetPrologue(realm, this_value, args, 1);
    return Value.fromInt32(a.buf[a.abs_offset]);
}
fn dataViewGetInt16(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const a = try dvGetPrologue(realm, this_value, args, 2);
    return Value.fromInt32(dvReadEndian(i16, a.buf, a.abs_offset, dvLittleEndian(args, 1)));
}
fn dataViewGetUint16(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const a = try dvGetPrologue(realm, this_value, args, 2);
    return Value.fromInt32(dvReadEndian(u16, a.buf, a.abs_offset, dvLittleEndian(args, 1)));
}
fn dataViewGetInt32(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const a = try dvGetPrologue(realm, this_value, args, 4);
    return Value.fromInt32(dvReadEndian(i32, a.buf, a.abs_offset, dvLittleEndian(args, 1)));
}
fn dataViewGetUint32(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const a = try dvGetPrologue(realm, this_value, args, 4);
    const v = dvReadEndian(u32, a.buf, a.abs_offset, dvLittleEndian(args, 1));
    if (v <= std.math.maxInt(i32)) return Value.fromInt32(@intCast(v));
    return Value.fromDouble(@floatFromInt(v));
}
fn dataViewGetFloat32(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const a = try dvGetPrologue(realm, this_value, args, 4);
    const u = dvReadEndian(u32, a.buf, a.abs_offset, dvLittleEndian(args, 1));
    const f: f32 = @bitCast(u);
    return Value.fromDouble(@floatCast(f));
}
fn dataViewGetFloat64(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const a = try dvGetPrologue(realm, this_value, args, 8);
    const u = dvReadEndian(u64, a.buf, a.abs_offset, dvLittleEndian(args, 1));
    return Value.fromDouble(@bitCast(u));
}
fn dataViewGetBigInt64(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const a = try dvGetPrologue(realm, this_value, args, 8);
    const u = dvReadEndian(i64, a.buf, a.abs_offset, dvLittleEndian(args, 1));
    const bi = realm.heap.allocateBigInt(@intCast(u)) catch return error.OutOfMemory;
    return heap_mod.taggedBigInt(bi);
}
fn dataViewGetBigUint64(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const a = try dvGetPrologue(realm, this_value, args, 8);
    const u = dvReadEndian(u64, a.buf, a.abs_offset, dvLittleEndian(args, 1));
    const bi = realm.heap.allocateBigInt(@as(i128, u)) catch return error.OutOfMemory;
    return heap_mod.taggedBigInt(bi);
}

// Set* methods.
fn dataViewSetInt8(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const a = try dvSetNumPrologue(realm, this_value, args, 1);
    a.buf[a.abs_offset] = @bitCast(@as(i8, @truncate(toInt32Mod(a.value))));
    return Value.undefined_;
}
fn dataViewSetUint8(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const a = try dvSetNumPrologue(realm, this_value, args, 1);
    a.buf[a.abs_offset] = @truncate(@as(u32, @bitCast(toInt32Mod(a.value))));
    return Value.undefined_;
}
fn dataViewSetInt16(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const a = try dvSetNumPrologue(realm, this_value, args, 2);
    dvWriteEndian(i16, a.buf, a.abs_offset, @truncate(toInt32Mod(a.value)), dvLittleEndian(args, 2));
    return Value.undefined_;
}
fn dataViewSetUint16(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const a = try dvSetNumPrologue(realm, this_value, args, 2);
    const u: u16 = @truncate(@as(u32, @bitCast(toInt32Mod(a.value))));
    dvWriteEndian(u16, a.buf, a.abs_offset, u, dvLittleEndian(args, 2));
    return Value.undefined_;
}
fn dataViewSetInt32(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const a = try dvSetNumPrologue(realm, this_value, args, 4);
    dvWriteEndian(i32, a.buf, a.abs_offset, toInt32Mod(a.value), dvLittleEndian(args, 2));
    return Value.undefined_;
}
fn dataViewSetUint32(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const a = try dvSetNumPrologue(realm, this_value, args, 4);
    const u: u32 = @bitCast(toInt32Mod(a.value));
    dvWriteEndian(u32, a.buf, a.abs_offset, u, dvLittleEndian(args, 2));
    return Value.undefined_;
}
fn dataViewSetFloat32(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const a = try dvSetNumPrologue(realm, this_value, args, 4);
    const f: f32 = @floatCast(a.value);
    const u: u32 = @bitCast(f);
    dvWriteEndian(u32, a.buf, a.abs_offset, u, dvLittleEndian(args, 2));
    return Value.undefined_;
}
fn dataViewSetFloat64(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const a = try dvSetNumPrologue(realm, this_value, args, 8);
    const u: u64 = @bitCast(a.value);
    dvWriteEndian(u64, a.buf, a.abs_offset, u, dvLittleEndian(args, 2));
    return Value.undefined_;
}
fn dataViewSetBigInt64(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    // §25.3.4.16 — index check (RangeError) before value
    // conversion (which can throw via poisoned valueOf), so the
    // index validity wins on negative-byteoffset + poisoned-value.
    // ToIndex throws RangeError; bounds check throws RangeError;
    // ToBigInt may throw TypeError. The spec ordering:
    // ToIndex → ToBigInt → detached → bounds, but the
    // BigInt-specific test262 (`index-check-before-value-conversion`)
    // also wants -1.5 / -Infinity to fail (RangeError) before
    // poisoned valueOf is read — those cases are caught in ToIndex.
    const dv = dvOf(this_value) orelse return throwTypeError(realm, "DataView method on non-DataView");
    const off = try dvToIndex(realm, argOr(args, 0, Value.undefined_));
    const i = try dvToBigInt64(realm, argOr(args, 1, Value.undefined_));
    const buf = dv.viewed.array_buffer orelse return throwTypeError(realm, "DataView: buffer is detached");
    if (8 > dv.byte_length or off > dv.byte_length - 8) return throwRangeError(realm, "DataView: byte offset out of bounds");
    dvWriteEndian(i64, buf, dv.byte_offset + off, i, dvLittleEndian(args, 2));
    return Value.undefined_;
}
fn dataViewSetBigUint64(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const dv = dvOf(this_value) orelse return throwTypeError(realm, "DataView method on non-DataView");
    const off = try dvToIndex(realm, argOr(args, 0, Value.undefined_));
    const i = try dvToBigInt64(realm, argOr(args, 1, Value.undefined_));
    const buf = dv.viewed.array_buffer orelse return throwTypeError(realm, "DataView: buffer is detached");
    if (8 > dv.byte_length or off > dv.byte_length - 8) return throwRangeError(realm, "DataView: byte offset out of bounds");
    const u: u64 = @bitCast(i);
    dvWriteEndian(u64, buf, dv.byte_offset + off, u, dvLittleEndian(args, 2));
    return Value.undefined_;
}

// ── TypedArray.prototype.sort + ES2023 immutable variants ────────────────────

/// §23.2.3.30 — default order is numeric (NOT stringified, unlike
/// Array.prototype.sort). Custom comparator is optional. NaN sorts
/// to the end.
fn taCompareNumeric(a: Value, b: Value) i32 {
    const av: f64 = if (a.isInt32()) @floatFromInt(a.asInt32()) else if (a.isDouble()) a.asDouble() else 0;
    const bv: f64 = if (b.isInt32()) @floatFromInt(b.asInt32()) else if (b.isDouble()) b.asDouble() else 0;
    if (std.math.isNan(av) and std.math.isNan(bv)) return 0;
    if (std.math.isNan(av)) return 1;
    if (std.math.isNan(bv)) return -1;
    if (av < bv) return -1;
    if (av > bv) return 1;
    return 0;
}

fn taSortInPlace(realm: *Realm, tv: ObjMod.TypedView, buf_in: []u8, comparator: ?*JSFunction) NativeError!void {
    const elem_size = tv.kind.elementSize();
    // §23.2.3.30 — a user comparator can detach (or resize) the
    // backing buffer mid-sort. The captured slice would dangle;
    // re-resolve from `tv.viewed.array_buffer` after every
    // comparator invocation and short-circuit out if detached.
    // Bounds-check every direct buf read/write so a shrunk
    // backing store doesn't slice past the live length.
    var buf = buf_in;
    var i: usize = 1;
    while (i < tv.length) : (i += 1) {
        const i_off = tv.byte_offset + i * elem_size;
        if (i_off + elem_size > buf.len) return;
        const cur = readTypedElement(realm, buf, tv.kind, i_off);
        var j: i64 = @as(i64, @intCast(i)) - 1;
        while (j >= 0) : (j -= 1) {
            const j_off = tv.byte_offset + @as(usize, @intCast(j)) * elem_size;
            if (j_off + elem_size > buf.len) break;
            const prev = readTypedElement(realm, buf, tv.kind, j_off);
            const cmp: i32 = blk: {
                if (comparator) |cf| {
                    const interpreter = @import("../interpreter.zig");
                    const cb_args = [_]Value{ prev, cur };
                    const outcome = interpreter.callJSFunction(realm.allocator, realm, cf, Value.undefined_, &cb_args) catch return error.NativeThrew;
                    // The comparator may have detached the buffer;
                    // re-resolve before the next direct access.
                    buf = tv.viewed.array_buffer orelse return;
                    switch (outcome) {
                        .value, .yielded => |v| {
                            const d: f64 = if (v.isInt32()) @floatFromInt(v.asInt32()) else if (v.isDouble()) v.asDouble() else 0;
                            if (std.math.isNan(d) or d == 0) break :blk 0;
                            break :blk if (d < 0) -1 else 1;
                        },
                        .thrown => return error.NativeThrew,
                    }
                }
                break :blk taCompareNumeric(prev, cur);
            };
            if (cmp <= 0) break;
            const a_off = tv.byte_offset + @as(usize, @intCast(j)) * elem_size;
            const b_off = tv.byte_offset + (@as(usize, @intCast(j)) + 1) * elem_size;
            if (b_off + elem_size > buf.len or a_off + elem_size > buf.len) break;
            @memcpy(buf[b_off .. b_off + elem_size], buf[a_off .. a_off + elem_size]);
        }
        const place: usize = @intCast(j + 1);
        const place_off = tv.byte_offset + place * elem_size;
        if (place_off + elem_size <= buf.len) writeTypedElement(buf, tv.kind, place_off, cur);
    }
}

fn typedArraySort(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const tv = taViewOf(this_value) orelse return throwTypeError(realm, "sort on non-TypedArray");
    const buf = taBufOf(tv) orelse return throwTypeError(realm, "TypedArray detached");
    const cmp_v = argOr(args, 0, Value.undefined_);
    const cmp_fn: ?*JSFunction = if (cmp_v.isUndefined()) null else heap_mod.valueAsFunction(cmp_v) orelse return throwTypeError(realm, "sort comparator must be a function");
    try taSortInPlace(realm, tv, buf, cmp_fn);
    return this_value;
}

fn typedArrayToSorted(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const tv = taViewOf(this_value) orelse return throwTypeError(realm, "toSorted on non-TypedArray");
    const buf = taBufOf(tv) orelse return throwTypeError(realm, "TypedArray detached");
    const cmp_v = argOr(args, 0, Value.undefined_);
    const cmp_fn: ?*JSFunction = if (cmp_v.isUndefined()) null else heap_mod.valueAsFunction(cmp_v) orelse return throwTypeError(realm, "toSorted comparator must be a function");
    const out = try taMakeNew(realm, tv.kind, tv.length);
    const out_buf = out.typed_view.?.viewed.array_buffer.?;
    const elem_size = tv.kind.elementSize();
    @memcpy(out_buf[0 .. tv.length * elem_size], buf[tv.byte_offset .. tv.byte_offset + tv.length * elem_size]);
    try taSortInPlace(realm, out.typed_view.?, out_buf, cmp_fn);
    return heap_mod.taggedObject(out);
}

fn typedArrayToReversed(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = args;
    const tv = taViewOf(this_value) orelse return throwTypeError(realm, "toReversed on non-TypedArray");
    const buf = taBufOf(tv) orelse return throwTypeError(realm, "TypedArray detached");
    const out = try taMakeNew(realm, tv.kind, tv.length);
    const out_buf = out.typed_view.?.viewed.array_buffer.?;
    const elem_size = tv.kind.elementSize();
    var i: usize = 0;
    while (i < tv.length) : (i += 1) {
        const src_off = tv.byte_offset + (tv.length - 1 - i) * elem_size;
        const dst_off = i * elem_size;
        @memcpy(out_buf[dst_off .. dst_off + elem_size], buf[src_off .. src_off + elem_size]);
    }
    return heap_mod.taggedObject(out);
}

fn typedArrayWith(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const tv = taViewOf(this_value) orelse return throwTypeError(realm, "with on non-TypedArray");
    const buf = taBufOf(tv) orelse return throwTypeError(realm, "TypedArray detached");
    const len: i64 = @intCast(tv.length);
    const idx_arg = argOr(args, 0, Value.fromInt32(0));
    const value = argOr(args, 1, Value.undefined_);
    // §23.2.3.39 step 2 — ToIntegerOrInfinity(relativeIndex)
    // applies ToNumber first, which fires ToPrimitive →
    // valueOf / toString on objects and throws on Symbol /
    // BigInt. Route through `toNumber` (realm-aware) so user
    // valueOf throws propagate before we touch `value`.
    const idx_num = try intrinsics.toNumber(realm, idx_arg);
    const idx_n: f64 = if (idx_num.isInt32())
        @floatFromInt(idx_num.asInt32())
    else if (idx_num.isDouble())
        idx_num.asDouble()
    else
        0;
    // §7.1.5 ToIntegerOrInfinity yields ±Infinity for an infinite
    // operand; the subsequent `actualIndex >= len` (or < 0) then
    // throws RangeError. Cynic's index path uses i64, so map
    // ±Infinity onto sentinel min/max BEFORE the int cast to
    // avoid an UB-trapping `@intFromFloat`. NaN already coerces
    // to 0 per spec.
    const trunc_n = if (std.math.isNan(idx_n)) 0.0 else @trunc(idx_n);
    const max_i: f64 = @floatFromInt(std.math.maxInt(i64));
    const min_i: f64 = @floatFromInt(std.math.minInt(i64));
    const idx_i: i64 = if (trunc_n >= max_i) std.math.maxInt(i64) else if (trunc_n <= min_i) std.math.minInt(i64) else @intFromFloat(trunc_n);
    const target_i: i64 = if (idx_i < 0) idx_i +| len else idx_i;
    if (target_i < 0 or target_i >= len) return throwRangeError(realm, "with: index out of range");

    const out = try taMakeNew(realm, tv.kind, tv.length);
    const out_buf = out.typed_view.?.viewed.array_buffer.?;
    const elem_size = tv.kind.elementSize();
    @memcpy(out_buf[0 .. tv.length * elem_size], buf[tv.byte_offset .. tv.byte_offset + tv.length * elem_size]);
    writeTypedElement(out_buf, tv.kind, @as(usize, @intCast(target_i)) * elem_size, value);
    return heap_mod.taggedObject(out);
}

/// §7.1.6 ToUint{8,16,32} — common modular reduction used by
/// the typed-array element writers. NaN / ±Infinity coerce to 0
/// (per spec). For finite `d`, computes `((trunc(d) mod m) + m) mod m`
/// in floating point so 1e30 doesn't trap an i64 cast.
fn toUintMod(d: f64, m: f64) u64 {
    if (std.math.isNan(d) or std.math.isInf(d)) return 0;
    const truncd = @trunc(d);
    const reduced = truncd - @floor(truncd / m) * m;
    const adjusted = if (reduced < 0) reduced + m else reduced;
    // `adjusted` is now in [0, m); m ≤ 2^32 here so the u64 cast is safe.
    return @intFromFloat(adjusted);
}

/// Write `value` (Number or BigInt) into `buf` at byte offset
/// `byte_pos` interpreted as `kind`. Does spec-compliant
/// truncation / clamping (mostly matching ToInt8 / ToUint8 etc).
pub fn writeTypedElement(buf: []u8, kind: ObjMod.TypedKind, byte_pos: usize, value: Value) void {
    // §10.4.5.x IntegerIndexedElementSet — out-of-bounds writes
    // on a shrunk resizable AB silently no-op (mirror the read
    // bounds check above).
    if (byte_pos + kind.elementSize() > buf.len) return;
    switch (kind) {
        .int8, .uint8 => {
            const v = coerceToNumber(value);
            const d: f64 = if (v.isInt32()) @floatFromInt(v.asInt32()) else v.asDouble();
            buf[byte_pos] = @truncate(toUintMod(d, 256.0));
        },
        .int16, .uint16 => {
            const v = coerceToNumber(value);
            const d: f64 = if (v.isInt32()) @floatFromInt(v.asInt32()) else v.asDouble();
            const u: u16 = @truncate(toUintMod(d, 65536.0));
            std.mem.writeInt(u16, buf[byte_pos..][0..2], u, .little);
        },
        .int32, .uint32 => {
            const v = coerceToNumber(value);
            const d: f64 = if (v.isInt32()) @floatFromInt(v.asInt32()) else v.asDouble();
            const u: u32 = @truncate(toUintMod(d, 4294967296.0));
            std.mem.writeInt(u32, buf[byte_pos..][0..4], u, .little);
        },
        .float32 => {
            const v = coerceToNumber(value);
            const d: f64 = if (v.isInt32()) @floatFromInt(v.asInt32()) else v.asDouble();
            const f: f32 = @floatCast(d);
            const u: u32 = @bitCast(f);
            std.mem.writeInt(u32, buf[byte_pos..][0..4], u, .little);
        },
        .float64 => {
            const v = coerceToNumber(value);
            const d: f64 = if (v.isInt32()) @floatFromInt(v.asInt32()) else v.asDouble();
            const u: u64 = @bitCast(d);
            std.mem.writeInt(u64, buf[byte_pos..][0..8], u, .little);
        },
        .bigint64, .biguint64 => {
            const bi = heap_mod.valueAsBigInt(value);
            const u: u64 = if (bi) |b| @bitCast(@as(i64, @truncate(b.value))) else 0;
            std.mem.writeInt(u64, buf[byte_pos..][0..8], u, .little);
        },
    }
}

/// §7.1.21 CanonicalNumericIndexString — returns the parsed
/// f64 for any string S such that ToString(ToNumber(S)) === S
/// (plus "-0"). Returns null for non-canonical numeric strings
/// AND non-numeric strings. Used by §10.4.5 Integer-Indexed
/// Exotic Object hooks ([[GetOwnProperty]] / [[DefineOwnProperty]])
/// to decide whether a key targets the typed-buffer slot or the
/// ordinary property bag.
pub fn canonicalNumericIndex(s: []const u8) ?f64 {
    if (s.len == 0) return null;
    if (std.mem.eql(u8, s, "-0")) return -0.0;
    if (std.mem.eql(u8, s, "Infinity")) return std.math.inf(f64);
    if (std.mem.eql(u8, s, "-Infinity")) return -std.math.inf(f64);
    if (std.mem.eql(u8, s, "NaN")) return std.math.nan(f64);
    var i: usize = 0;
    if (s[i] == '-') i += 1;
    if (i >= s.len) return null;
    if (s[i] == '0') {
        i += 1;
    } else if (s[i] >= '1' and s[i] <= '9') {
        i += 1;
        while (i < s.len and s[i] >= '0' and s[i] <= '9') : (i += 1) {}
    } else {
        return null;
    }
    if (i < s.len and s[i] == '.') {
        i += 1;
        if (i >= s.len or s[i] < '0' or s[i] > '9') return null;
        while (i < s.len and s[i] >= '0' and s[i] <= '9') : (i += 1) {}
        if (s[i - 1] == '0') return null;
    }
    if (i < s.len and (s[i] == 'e' or s[i] == 'E')) {
        i += 1;
        if (i < s.len and (s[i] == '+' or s[i] == '-')) i += 1;
        if (i >= s.len or s[i] < '0' or s[i] > '9') return null;
        while (i < s.len and s[i] >= '0' and s[i] <= '9') : (i += 1) {}
    }
    if (i != s.len) return null;
    const n = std.fmt.parseFloat(f64, s) catch return null;
    var buf: [64]u8 = undefined;
    const printed = std.fmt.bufPrint(&buf, "{d}", .{n}) catch return null;
    if (!std.mem.eql(u8, printed, s)) return null;
    return n;
}

pub const TypedArrayDefineResult = enum { applied, reject };

/// §10.4.5.3 [[DefineOwnProperty]] for Integer-Indexed Exotic Objects.
/// Caller has already passed `key` through CanonicalNumericIndexString.
/// Returns `.applied` if the value (if any) was written to the typed
/// slot; `.reject` if the spec says return false (out-of-bounds,
/// non-integer, non-default descriptor flags, detached buffer).
pub fn typedArrayDefineOwnProperty(
    realm: *Realm,
    obj: *JSObject,
    num: f64,
    has_value: bool,
    value: Value,
    is_accessor: bool,
    has_configurable: bool,
    configurable: bool,
    has_enumerable: bool,
    enumerable: bool,
    has_writable: bool,
    writable: bool,
) NativeError!TypedArrayDefineResult {
    const tv = obj.typed_view orelse unreachable;
    if (std.math.isNan(num)) return .reject;
    if (std.math.isInf(num)) return .reject;
    if (@trunc(num) != num) return .reject;
    if (num == 0.0 and std.math.signbit(num)) return .reject;
    if (num < 0) return .reject;
    const idx: usize = @intFromFloat(num);
    const buf = tv.viewed.array_buffer orelse return .reject;
    if (idx >= tv.length) return .reject;
    const elem_size = tv.kind.elementSize();
    if (tv.byte_offset + (idx + 1) * elem_size > buf.len) return .reject;
    if (is_accessor) return .reject;
    if (has_configurable and !configurable) return .reject;
    if (has_enumerable and !enumerable) return .reject;
    if (has_writable and !writable) return .reject;
    if (has_value) {
        switch (tv.kind) {
            .bigint64, .biguint64 => {
                if (heap_mod.valueAsBigInt(value) == null) {
                    return throwTypeError(realm, "Cannot convert non-BigInt value to BigInt");
                }
            },
            else => {
                if (heap_mod.valueAsBigInt(value) != null) {
                    return throwTypeError(realm, "Cannot convert a BigInt value to a number");
                }
                if (heap_mod.valueAsSymbol(value) != null) {
                    return throwTypeError(realm, "Cannot convert a Symbol value to a number");
                }
            },
        }
        writeTypedElement(buf, tv.kind, tv.byte_offset + idx * elem_size, value);
    }
    return .applied;
}

/// §10.4.5.2 [[GetOwnProperty]] for Integer-Indexed Exotic Objects.
/// Returns the current slot value (caller wraps it in a fresh
/// `{writable, enumerable, configurable}: true` descriptor) or
/// `null` for any key that isn't a valid integer index.
pub fn typedArrayGetOwnPropertyValue(realm: *Realm, obj: *JSObject, num: f64) ?Value {
    const tv = obj.typed_view orelse return null;
    if (std.math.isNan(num)) return null;
    if (std.math.isInf(num)) return null;
    if (@trunc(num) != num) return null;
    if (num == 0.0 and std.math.signbit(num)) return null;
    if (num < 0) return null;
    const idx: usize = @intFromFloat(num);
    const buf = tv.viewed.array_buffer orelse return null;
    if (idx >= tv.length) return null;
    const elem_size = tv.kind.elementSize();
    if (tv.byte_offset + (idx + 1) * elem_size > buf.len) return null;
    return readTypedElement(realm, buf, tv.kind, tv.byte_offset + idx * elem_size);
}

pub fn readTypedElement(realm: *Realm, buf: []const u8, kind: ObjMod.TypedKind, byte_pos: usize) Value {
    // §10.4.5 IsValidIntegerIndex — a view over a resizable
    // ArrayBuffer can be left with `byte_pos + elem_size` past
    // `buf.len` after a shrink. Spec semantics: read as
    // `undefined` (caller treats it as a hole).
    if (byte_pos + kind.elementSize() > buf.len) return Value.undefined_;
    switch (kind) {
        .int8 => return Value.fromInt32(@as(i8, @bitCast(buf[byte_pos]))),
        .uint8 => return Value.fromInt32(buf[byte_pos]),
        .int16 => return Value.fromInt32(std.mem.readInt(i16, buf[byte_pos..][0..2], .little)),
        .uint16 => return Value.fromInt32(std.mem.readInt(u16, buf[byte_pos..][0..2], .little)),
        .int32 => return Value.fromInt32(std.mem.readInt(i32, buf[byte_pos..][0..4], .little)),
        .uint32 => {
            const u = std.mem.readInt(u32, buf[byte_pos..][0..4], .little);
            if (u <= std.math.maxInt(i32)) return Value.fromInt32(@intCast(u));
            return Value.fromDouble(@floatFromInt(u));
        },
        .float32 => {
            const u = std.mem.readInt(u32, buf[byte_pos..][0..4], .little);
            const f: f32 = @bitCast(u);
            return Value.fromDouble(@floatCast(f));
        },
        .float64 => {
            const u = std.mem.readInt(u64, buf[byte_pos..][0..8], .little);
            return Value.fromDouble(@bitCast(u));
        },
        .bigint64, .biguint64 => {
            const u = std.mem.readInt(i64, buf[byte_pos..][0..8], .little);
            const bi = realm.heap.allocateBigInt(@intCast(u)) catch return Value.fromInt32(0);
            return heap_mod.taggedBigInt(bi);
        },
    }
}

