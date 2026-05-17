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
const arrayLikeEntriesMethod = intrinsics.typedArrayEntriesMethod;
const arrayLikeKeysMethod = intrinsics.typedArrayKeysMethod;
const arrayLikeValuesMethod = intrinsics.typedArrayValuesMethod;
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
        // §25.1.4.2 `get ArrayBuffer [ @@species ]` returns `this`.
        // Subclasses pick up the inherited getter via
        // `static_parent` (so `MyAB[@@species] === MyAB` unless
        // overridden). `Symbol.species` is the hook every
        // ArrayBuffer.prototype.slice fixture pokes at.
        {
            const species_getter = try realm.heap.allocateFunctionNative(arrayBufferSpeciesGetter, 0, "get [Symbol.species]");
            species_getter.proto = realm.intrinsics.function_prototype;
            const entry = try ctor.accessors.getOrPut(realm.allocator, "@@species");
            entry.value_ptr.* = .{ .getter = species_getter };
            try ctor.property_flags.put(realm.allocator, "@@species", .{
                .writable = false, .enumerable = false, .configurable = true,
            });
        }
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
        try installNativeMethodOnProto(realm, proto, "getFloat16", dataViewGetFloat16, 1);
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
        try installNativeMethodOnProto(realm, proto, "setFloat16", dataViewSetFloat16, 2);
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

    // §23.2.3.32 — `get %TypedArray%.prototype [ @@toStringTag ]`
    // is an accessor on `%TypedArray%.prototype` that reads
    // `[[TypedArrayName]]` off `this`. Returns `undefined` when
    // `this` lacks a typed-view slot (test262 verifies via
    // `getter.call({})`, DataView, ArrayBuffer, …). The concrete
    // prototypes (`Int8Array.prototype` etc.) inherit this
    // accessor — they must NOT carry an own @@toStringTag.
    try installNativeGetter(realm, ta_proto, "@@toStringTag", typedArrayToStringTagGetter);

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

    // §23.2.2 static methods on %TypedArray% itself. Concrete
    // constructors (Int8Array etc.) inherit these through the
    // `static_parent` link — `Int8Array.from === %TypedArray%.from`
    // and `Int8Array.hasOwnProperty("from")` is false.
    try intrinsics.installNativeMethod(realm, ta_ctor, "from", typedArrayFrom, 1);
    try intrinsics.installNativeMethod(realm, ta_ctor, "of", typedArrayOf, 0);

    // §23.2.2.4 get %TypedArray% [ @@species ] returns this.
    // Inherited by every concrete constructor through
    // `static_parent`, so `Uint8Array[@@species] === Uint8Array`
    // unless the user overrides it; subclasses pick up the
    // inherited getter and resolve to the subclass.
    {
        const species_getter = try realm.heap.allocateFunctionNative(typedArraySpeciesGetter, 0, "[Symbol.species]");
        species_getter.proto = realm.intrinsics.function_prototype;
        const entry = try ta_ctor.accessors.getOrPut(realm.allocator, "@@species");
        entry.value_ptr.* = .{ .getter = species_getter };
        try ta_ctor.property_flags.put(realm.allocator, "@@species", .{
            .writable = false, .enumerable = false, .configurable = true,
        });
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
        .{ .name = "Float16Array", .kind = .float16 },
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
        const ctor = try realm.heap.allocateFunctionNative(typedArrayConstructorBuilder(variant.kind, variant.name), 3, variant.name);
        ctor.is_class_constructor = true;
        ctor.static_parent = ta_ctor; // §23.2.6 — Int8Array.[[Prototype]] = %TypedArray%
        const proto = try realm.heap.allocateObject();
        proto.prototype = ta_proto; // §23.2.6 — concrete proto inherits from %TypedArray%.prototype.
        try setNonEnumerable(proto, realm.allocator, "constructor", heap_mod.taggedFunction(ctor));
        // §23.2.6.2 — `<TypedArray>.prototype.BYTES_PER_ELEMENT`
        // is `{w:false, e:false, c:false}`.
        try proto.setWithFlags(realm.allocator, "BYTES_PER_ELEMENT", Value.fromInt32(variant.kind.elementSize()), frozen);
        // §23.2.6 — concrete typed arrays inherit @@toStringTag
        // from `%TypedArray%.prototype` (installed above as a
        // spec-faithful getter that reads [[TypedArrayName]]).
        // No own @@toStringTag here — `hasOwnProperty(Symbol.
        // toStringTag)` must be `false` on each concrete proto.
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

/// §25.1.4.2 `get ArrayBuffer [ @@species ]` — returns `this`.
/// Subclasses inherit this getter through `static_parent`, so
/// `MyAB[@@species]` resolves to `MyAB` (the subclass) by
/// default; user code can override on the subclass to interpose.
fn arrayBufferSpeciesGetter(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = realm;
    _ = args;
    return this_value;
}

/// §7.3.22 SpeciesConstructor(O, defaultConstructor) — the
/// helper the spec invokes from `slice` (and friends). Resolution:
///   1. Let C be ? Get(O, "constructor").
///   2. If C is undefined, return defaultConstructor.
///   3. If Type(C) is not Object, throw TypeError.
///   4. Let S be ? Get(C, @@species).
///   5. If S is either undefined or null, return defaultConstructor.
///   6. If IsConstructor(S) is true, return S.
///   7. Throw TypeError.
fn arrayBufferSpeciesConstructor(realm: *Realm, exemplar: *JSObject, default_ctor: ?*JSFunction) NativeError!?*JSFunction {
    const ctor_prop = try intrinsics.getPropertyChain(realm, exemplar, "constructor");
    // §7.3.22 step 2 — undefined → default.
    if (ctor_prop.isUndefined()) return default_ctor;
    // §7.3.22 step 3 — non-Object → TypeError. A bare function
    // counts as Object here, so `valueAsFunction` is the same as
    // `Type(C) is Object` for our purposes.
    var species_v: Value = Value.undefined_;
    if (heap_mod.valueAsFunction(ctor_prop)) |fn_obj| {
        species_v = try taGetFunctionMember(realm, fn_obj, "@@species");
    } else if (heap_mod.valueAsPlainObject(ctor_prop)) |obj| {
        species_v = try intrinsics.getPropertyChain(realm, obj, "@@species");
    } else {
        return throwTypeError(realm, "ArrayBuffer.prototype.slice: constructor is not an object");
    }
    // §7.3.22 step 5 — undefined / null → default.
    if (species_v.isUndefined() or species_v.isNull()) return default_ctor;
    // §7.3.22 step 6 — must be a constructor. Cynic treats every
    // JSFunction with `has_construct = true` (the install-time
    // default for `installConstructor`) as a constructor. A bare
    // method (e.g. `Function.prototype` itself, or an arrow) has
    // `has_construct = false` and must throw.
    const species_fn = heap_mod.valueAsFunction(species_v) orelse
        return throwTypeError(realm, "ArrayBuffer.prototype.slice: @@species is not a constructor");
    if (!species_fn.has_construct)
        return throwTypeError(realm, "ArrayBuffer.prototype.slice: @@species is not a constructor");
    return species_fn;
}

fn arrayBufferSlice(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const src = heap_mod.valueAsPlainObject(this_value) orelse return throwTypeError(realm, "slice on non-ArrayBuffer");
    const src_buf = src.array_buffer orelse return throwTypeError(realm, "slice on non-ArrayBuffer");
    const total: i64 = @intCast(src_buf.len);
    // §25.1.5.5 ArrayBuffer.prototype.slice step 5-9 — start / end
    // go through ToIntegerOrInfinity. NaN -> 0; -Infinity stays
    // -Infinity (clamps to 0 in step 8); +Infinity stays +Infinity
    // (clamps to `len` in step 8). `tointeger-conversion-end.js`
    // and `negative-end.js` together pin the corner cases.
    var start_d: f64 = 0;
    if (args.len > 0) {
        start_d = try taSetToIntegerOrInfinity(realm, args[0]);
    }
    var end_d: f64 = @floatFromInt(total);
    if (args.len > 1 and !args[1].isUndefined()) {
        end_d = try taSetToIntegerOrInfinity(realm, args[1]);
    }
    // §25.1.5.5 step 6/8 — relativeStart < 0 → max(len + s, 0);
    // else → min(s, len). Same for relativeEnd.
    const total_f: f64 = @floatFromInt(total);
    const start_f: f64 = if (start_d < 0) @max(total_f + start_d, 0) else @min(start_d, total_f);
    const end_f: f64 = if (end_d < 0) @max(total_f + end_d, 0) else @min(end_d, total_f);
    const start_i: i64 = @intFromFloat(start_f);
    const end_i: i64 = @intFromFloat(end_f);
    const new_len: usize = if (end_i > start_i) @intCast(end_i - start_i) else 0;

    // §25.1.5.5 step 12-14 — SpeciesConstructor(O, %ArrayBuffer%)
    // and `Construct(ctor, « newLen »)`.
    const default_ctor = heap_mod.valueAsFunction(realm.globals.get("ArrayBuffer") orelse Value.undefined_);
    const ctor_fn = try arrayBufferSpeciesConstructor(realm, src, default_ctor);

    // Open a HandleScope across the user construct — it can
    // trigger GC, which would otherwise sweep ephemerals.
    const scope = realm.heap.openScope() catch return error.OutOfMemory;
    defer scope.close();

    const ctor_args = [_]Value{numberFromI64(@intCast(new_len))};
    const interpreter = @import("../interpreter.zig");
    const result_v = if (ctor_fn) |cf| blk: {
        const callee_v = heap_mod.taggedFunction(cf);
        const outcome = interpreter.constructValue(realm.allocator, realm, callee_v, &ctor_args, callee_v) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.NativeThrew,
        };
        break :blk switch (outcome) {
            .value, .yielded => |v| v,
            .thrown => |ex| {
                realm.pending_exception = ex;
                return error.NativeThrew;
            },
        };
    } else err: {
        // Default path: allocate a fresh ArrayBuffer directly.
        // This only fires when no `ArrayBuffer` global exists,
        // which shouldn't happen in practice.
        const out = realm.heap.allocateObject() catch return error.OutOfMemory;
        const new_buf = realm.allocator.alloc(u8, new_len) catch return error.OutOfMemory;
        @memset(new_buf, 0);
        out.array_buffer = new_buf;
        out.has_array_buffer_data = true;
        break :err heap_mod.taggedObject(out);
    };

    // §25.1.5.5 step 17 — result must have an [[ArrayBufferData]]
    // internal slot (i.e. be a real ArrayBuffer, not a stub).
    const result_obj = heap_mod.valueAsPlainObject(result_v) orelse
        return throwTypeError(realm, "ArrayBuffer.prototype.slice: species ctor returned non-object");
    const result_buf = result_obj.array_buffer orelse
        return throwTypeError(realm, "ArrayBuffer.prototype.slice: species ctor did not return an ArrayBuffer");
    // §25.1.5.5 step 19 — `SameValue(new, O)` is true → TypeError.
    // The fixture `species-returns-same-arraybuffer.js` returns
    // the receiver from `@@species` and asserts this throws.
    if (result_obj == src)
        return throwTypeError(realm, "ArrayBuffer.prototype.slice: species ctor returned the receiver");
    // §25.1.5.5 step 20 — result.[[ArrayBufferByteLength]] < newLen
    // is a TypeError (`species-returns-smaller-arraybuffer.js`).
    // A larger buffer is allowed (`species-returns-larger-…`).
    if (result_buf.len < new_len)
        return throwTypeError(realm, "ArrayBuffer.prototype.slice: species ctor returned too-short ArrayBuffer");
    // §25.1.5.5 step 22 — CopyDataBlockBytes(result, 0, O, first, newLen).
    if (new_len > 0) {
        @memcpy(result_buf[0..new_len], src_buf[@intCast(start_i)..@intCast(end_i)]);
    }
    return heap_mod.taggedObject(result_obj);
}

fn typedArrayConstructorBuilder(comptime kind: ObjMod.TypedKind, comptime ta_name: []const u8) NativeFn {
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

                inst.typed_view = .{ .kind = kind, .viewed = buf_obj, .byte_offset = 0, .length = length, .name = ta_name };
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
                    // §23.2.5.1.4 — length argument omitted (or
                    // undefined) over a resizable buffer creates a
                    // length-tracking view (§10.4.5 [[ArrayLength]] =
                    // auto). Over a fixed-length buffer it's just the
                    // remaining size; the flag stays false.
                    const length_omitted = !(args.len > 2 and !args[2].isUndefined());
                    const is_resizable = src.array_buffer_max_byte_length != null;
                    var length_tracking = false;
                    if (length_omitted) {
                        if (is_resizable) length_tracking = true;
                    } else {
                        const lv = try intrinsics.toNumber(realm, args[2]);
                        const ld: f64 = if (lv.isInt32()) @floatFromInt(lv.asInt32()) else lv.asDouble();
                        if (std.math.isNan(ld) or ld < 0) return throwRangeError(realm, "length out of range");
                        length = @intFromFloat(ld);
                        if (length * elem_size > remaining) return throwRangeError(realm, "view exceeds buffer");
                    }
                    inst.typed_view = .{ .kind = kind, .viewed = src, .byte_offset = byte_offset, .length = length, .name = ta_name, .length_tracking = length_tracking };
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
                        .thrown => |ex| {
                            realm.pending_exception = ex;
                            return error.NativeThrew;
                        },
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
                            .thrown => |ex| {
                            realm.pending_exception = ex;
                            return error.NativeThrew;
                        },
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
                    inst.typed_view = .{ .kind = kind, .viewed = buf_obj, .byte_offset = 0, .length = length, .name = ta_name };
                    // §23.2.6.4 / §7.1.11 — Uint8ClampedArray's
                    // [[ContentType]] is still Number but writes
                    // route through ToUint8Clamp instead of modular
                    // ToUint8. The view stores its name explicitly
                    // so the dispatch is name-aware.
                    const clamped = std.mem.eql(u8, ta_name, "Uint8ClampedArray");
                    // §23.2.5.1.5 InitializeTypedArrayFromList step 4 —
                    // the spec calls IntegerIndexedElementSet(O, F(k),
                    // value) per item, which is ? ToBigInt / ToNumber.
                    // `writeTypedElement` only knows about primitives
                    // (its inner `coerceToNumber` collapses objects to
                    // NaN → 0), so a Number / String wrapper item
                    // ends up zeroed.  Coerce up front through the
                    // realm-aware path.
                    const bigint_mod = @import("bigint.zig");
                    var idx: usize = 0;
                    while (idx < length) : (idx += 1) {
                        const raw_item = collected.items[idx];
                        const coerced_item: Value = switch (kind) {
                            .bigint64, .biguint64 => bigint_mod.toBigIntValue(realm, raw_item) catch |err| switch (err) {
                                error.OutOfMemory => return error.OutOfMemory,
                                else => return error.NativeThrew,
                            },
                            else => try intrinsics.toNumber(realm, raw_item),
                        };
                        if (clamped) {
                            writeUint8Clamped(buf_bytes, idx * elem_size, coerced_item);
                        } else {
                            writeTypedElement(buf_bytes, kind, idx * elem_size, coerced_item);
                        }
                    }
                    return this_value;
                }

                // Array-like source — §23.2.5.1.6
                // InitializeTypedArrayFromArrayLike. `length` is
                // observed via Get + ToLength (accessors / proxy
                // traps fire). Each indexed element is fetched via
                // Get and coerced via ToNumber (or ToBigInt for
                // BigInt views); valueOf / Symbol.toPrimitive
                // throws must propagate.
                const length_i = try intrinsics.toLengthOf(realm, src);
                const length: usize = @intCast(length_i);
                const byte_len = length * elem_size;
                const buf_obj = realm.heap.allocateObject() catch return error.OutOfMemory;
                if (heap_mod.valueAsFunction(realm.globals.get("ArrayBuffer") orelse Value.undefined_)) |ab| {
                    buf_obj.prototype = ab.prototype;
                }
                const buf_bytes = realm.allocator.alloc(u8, byte_len) catch return error.OutOfMemory;
                @memset(buf_bytes, 0);
                buf_obj.array_buffer = buf_bytes;
                buf_obj.has_array_buffer_data = true;
                inst.typed_view = .{ .kind = kind, .viewed = buf_obj, .byte_offset = 0, .length = length, .name = ta_name };
                // Copy each element via Get + ToNumber/ToBigInt.
                const bigint_mod = @import("bigint.zig");
                const clamped_al = std.mem.eql(u8, ta_name, "Uint8ClampedArray");
                var i: usize = 0;
                while (i < length) : (i += 1) {
                    var ibuf: [16]u8 = undefined;
                    const s = std.fmt.bufPrint(&ibuf, "{d}", .{i}) catch unreachable;
                    const src_v = try getPropertyChain(realm, src, s);
                    // §10.4.5.x IntegerIndexedElementSet — coerce
                    // before the write so valueOf / Symbol.toPrimitive
                    // exceptions propagate per §23.2.5.1.6 step 8.c.
                    const coerced = switch (kind) {
                        .bigint64, .biguint64 => bigint_mod.toBigIntValue(realm, src_v) catch |err| switch (err) {
                            error.OutOfMemory => return error.OutOfMemory,
                            else => return error.NativeThrew,
                        },
                        else => try intrinsics.toNumber(realm, src_v),
                    };
                    if (clamped_al) {
                        writeUint8Clamped(buf_bytes, i * elem_size, coerced);
                    } else {
                        writeTypedElement(buf_bytes, kind, i * elem_size, coerced);
                    }
                }
                return this_value;
            }
            return throwTypeError(realm, "TypedArray: unsupported constructor argument");
        }
    }.ctor;
}

/// §23.2.4.2 TypedArrayCreate(constructor, argumentList) — calls
/// `Construct(constructor, argumentList)`, then performs
/// `ValidateTypedArray(newTypedArray)` (must have `[[TypedArrayName]]`
/// and a non-detached buffer). For the single-`len` argumentList
/// variant used by `%TypedArray%.from` / `.of`, additionally checks
/// `newTypedArray.[[ArrayLength]] >= len`.
fn typedArrayCreate(
    realm: *Realm,
    ctor_v: Value,
    args: []const Value,
    expected_len: ?usize,
) NativeError!*JSObject {
    const interp = @import("../interpreter.zig");
    const outcome = interp.constructValue(realm.allocator, realm, ctor_v, args, ctor_v) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.NativeThrew,
    };
    const result_v: Value = switch (outcome) {
        .value, .yielded => |v| v,
        .thrown => |ex| {
            realm.pending_exception = ex;
            return error.NativeThrew;
        },
    };
    const result = heap_mod.valueAsPlainObject(result_v) orelse
        return throwTypeError(realm, "TypedArrayCreate: constructor did not return an object");
    const tv = result.typed_view orelse
        return throwTypeError(realm, "TypedArrayCreate: constructor did not return a TypedArray");
    _ = tv.viewed.array_buffer orelse
        return throwTypeError(realm, "TypedArrayCreate: returned TypedArray has a detached buffer");
    if (expected_len) |min_len| {
        if (tv.length < min_len) {
            return throwTypeError(realm, "TypedArrayCreate: returned TypedArray is too small");
        }
    }
    return result;
}

/// IntegerIndexedElementSet — coerce `v` to the target's element
/// type (ToNumber or ToBigInt) and write at index `idx`.
fn typedArrayWriteIndex(realm: *Realm, target: *JSObject, idx: usize, v: Value) NativeError!void {
    const bigint_mod = @import("bigint.zig");
    const tv = target.typed_view orelse return throwTypeError(realm, "TypedArray write on non-TypedArray");
    const elem_size = tv.kind.elementSize();
    const coerced = switch (tv.kind) {
        .bigint64, .biguint64 => bigint_mod.toBigIntValue(realm, v) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.NativeThrew,
        },
        else => try intrinsics.toNumber(realm, v),
    };
    const buf = tv.viewed.array_buffer orelse return throwTypeError(realm, "TypedArray write on detached buffer");
    const byte_pos = tv.byte_offset + idx * elem_size;
    if (byte_pos + elem_size > buf.len) return;
    writeTypedElementForView(buf, tv, byte_pos, coerced);
}

/// §23.2.2.1 %TypedArray%.from ( source [ , mapfn [ , thisArg ] ] ).
fn typedArrayFrom(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    // §23.2.2.1 step 1-2 — IsConstructor(this).
    const ctor_fn = heap_mod.valueAsFunction(this_value) orelse
        return throwTypeError(realm, "%TypedArray%.from requires a constructor 'this'");
    if (!ctor_fn.has_construct or ctor_fn.is_arrow)
        return throwTypeError(realm, "%TypedArray%.from requires a constructor 'this'");

    const source = argOr(args, 0, Value.undefined_);
    const mapfn_v = argOr(args, 1, Value.undefined_);
    const this_arg = argOr(args, 2, Value.undefined_);
    // §23.2.2.1 step 3 — IsCallable(mapfn). Run BEFORE touching
    // `source[@@iterator]` (mapfn-is-not-callable fixture asserts
    // `getIterator === 0`).
    const mapfn: ?*JSFunction = blk: {
        if (mapfn_v.isUndefined()) break :blk null;
        const f = heap_mod.valueAsFunction(mapfn_v) orelse
            return throwTypeError(realm, "%TypedArray%.from: mapfn is not callable");
        break :blk f;
    };

    const interp = @import("../interpreter.zig");

    if (source.isUndefined() or source.isNull())
        return throwTypeError(realm, "%TypedArray%.from: source is null or undefined");

    const src_obj = heap_mod.valueAsPlainObject(source);
    if (src_obj) |src| {
        // §23.2.2.1 step 5 — GetMethod(source, @@iterator).
        const iter_method_v = try getPropertyChain(realm, src, "@@iterator");
        if (heap_mod.valueAsFunction(iter_method_v)) |iter_method| {
            // §23.2.2.1 step 6 — IterableToList path.
            const iter_outcome = interp.callJSFunction(realm.allocator, realm, iter_method, source, &.{}) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return error.NativeThrew,
            };
            const iter = switch (iter_outcome) {
                .value, .yielded => |v| v,
                .thrown => |ex| {
                    realm.pending_exception = ex;
                    return error.NativeThrew;
                },
            };
            const iter_obj = heap_mod.valueAsPlainObject(iter) orelse
                return throwTypeError(realm, "%TypedArray%.from: @@iterator did not return an iterator object");
            const next_v = try getPropertyChain(realm, iter_obj, "next");
            const next_fn = heap_mod.valueAsFunction(next_v) orelse
                return throwTypeError(realm, "%TypedArray%.from: iterator missing callable 'next'");

            var collected: std.ArrayListUnmanaged(Value) = .empty;
            defer collected.deinit(realm.allocator);
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
                    .thrown => |ex| {
                        realm.pending_exception = ex;
                        return error.NativeThrew;
                    },
                };
                const result_o = heap_mod.valueAsPlainObject(result) orelse
                    return throwTypeError(realm, "%TypedArray%.from: iterator next() did not return an object");
                if (toBoolean(try getPropertyChain(realm, result_o, "done"))) break;
                const item = try getPropertyChain(realm, result_o, "value");
                scope.push(item) catch return error.OutOfMemory;
                collected.append(realm.allocator, item) catch return error.OutOfMemory;
            }
            const len = collected.items.len;
            const create_args = [_]Value{numberFromUsize(len)};
            const target = try typedArrayCreate(realm, this_value, &create_args, len);
            scope.push(heap_mod.taggedObject(target)) catch return error.OutOfMemory;
            var k: usize = 0;
            while (k < len) : (k += 1) {
                const raw_v = collected.items[k];
                const final_v: Value = blk: {
                    if (mapfn) |mf| {
                        const cb_args = [_]Value{ raw_v, numberFromI64(@intCast(k)) };
                        const cb_out = interp.callJSFunction(realm.allocator, realm, mf, this_arg, &cb_args) catch |err| switch (err) {
                            error.OutOfMemory => return error.OutOfMemory,
                            else => return error.NativeThrew,
                        };
                        switch (cb_out) {
                            .value, .yielded => |v| break :blk v,
                            .thrown => |ex| {
                                realm.pending_exception = ex;
                                return error.NativeThrew;
                            },
                        }
                    } else break :blk raw_v;
                };
                try typedArrayWriteIndex(realm, target, k, final_v);
            }
            return heap_mod.taggedObject(target);
        }
    }

    // §23.2.2.1 step 7 — array-like fallback.
    const src = src_obj orelse return throwTypeError(realm, "%TypedArray%.from: source is not iterable or array-like");
    const len_i = try intrinsics.toLengthOf(realm, src);
    const len: usize = @intCast(len_i);
    const create_args = [_]Value{numberFromUsize(len)};
    const target = try typedArrayCreate(realm, this_value, &create_args, len);
    const scope = realm.heap.openScope() catch return error.OutOfMemory;
    defer scope.close();
    scope.push(heap_mod.taggedObject(target)) catch return error.OutOfMemory;
    scope.push(source) catch return error.OutOfMemory;
    var k: usize = 0;
    while (k < len) : (k += 1) {
        var ibuf: [24]u8 = undefined;
        const islice = std.fmt.bufPrint(&ibuf, "{d}", .{k}) catch unreachable;
        const raw_v = try getPropertyChain(realm, src, islice);
        const final_v: Value = blk: {
            if (mapfn) |mf| {
                const cb_args = [_]Value{ raw_v, numberFromI64(@intCast(k)) };
                const cb_out = interp.callJSFunction(realm.allocator, realm, mf, this_arg, &cb_args) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    else => return error.NativeThrew,
                };
                switch (cb_out) {
                    .value, .yielded => |v| break :blk v,
                    .thrown => |ex| {
                        realm.pending_exception = ex;
                        return error.NativeThrew;
                    },
                }
            } else break :blk raw_v;
        };
        try typedArrayWriteIndex(realm, target, k, final_v);
    }
    return heap_mod.taggedObject(target);
}

/// §23.2.2.2 %TypedArray%.of ( ...items ).
fn typedArrayOf(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const ctor_fn = heap_mod.valueAsFunction(this_value) orelse
        return throwTypeError(realm, "%TypedArray%.of requires a constructor 'this'");
    if (!ctor_fn.has_construct or ctor_fn.is_arrow)
        return throwTypeError(realm, "%TypedArray%.of requires a constructor 'this'");

    const len = args.len;
    const create_args = [_]Value{numberFromUsize(len)};
    const target = try typedArrayCreate(realm, this_value, &create_args, len);
    const scope = realm.heap.openScope() catch return error.OutOfMemory;
    defer scope.close();
    scope.push(heap_mod.taggedObject(target)) catch return error.OutOfMemory;
    var k: usize = 0;
    while (k < len) : (k += 1) {
        try typedArrayWriteIndex(realm, target, k, args[k]);
    }
    return heap_mod.taggedObject(target);
}

fn typedArrayLength(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = args;
    const obj = heap_mod.valueAsPlainObject(this_value) orelse return throwTypeError(realm, "TypedArray accessor on non-object");
    const tv = obj.typed_view orelse return throwTypeError(realm, "TypedArray.prototype.length called on a non-TypedArray");
    // §23.2.3.18 — IsDetachedBuffer or IsTypedArrayOutOfBounds
    // → return 0. For a length-tracking view, the current length
    // is recomputed against the live buffer.
    if (tv.viewed.array_buffer == null) return Value.fromInt32(0);
    if (taIsOutOfBounds(tv)) return Value.fromInt32(0);
    return Value.fromInt32(@intCast(taCurrentLength(tv)));
}

fn typedArrayByteLength(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = args;
    const obj = heap_mod.valueAsPlainObject(this_value) orelse return throwTypeError(realm, "TypedArray accessor on non-object");
    const tv = obj.typed_view orelse return throwTypeError(realm, "TypedArray.prototype.byteLength called on a non-TypedArray");
    // §23.2.3.2 — IsDetachedBuffer or IsTypedArrayOutOfBounds → 0.
    if (tv.viewed.array_buffer == null) return Value.fromInt32(0);
    if (taIsOutOfBounds(tv)) return Value.fromInt32(0);
    return Value.fromInt32(@intCast(taCurrentLength(tv) * tv.kind.elementSize()));
}

fn typedArrayByteOffset(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = args;
    const obj = heap_mod.valueAsPlainObject(this_value) orelse return throwTypeError(realm, "TypedArray accessor on non-object");
    const tv = obj.typed_view orelse return throwTypeError(realm, "TypedArray.prototype.byteOffset called on a non-TypedArray");
    // §23.2.3.3 — IsDetachedBuffer or IsTypedArrayOutOfBounds → 0.
    if (tv.viewed.array_buffer == null) return Value.fromInt32(0);
    if (taIsOutOfBounds(tv)) return Value.fromInt32(0);
    return Value.fromInt32(@intCast(tv.byte_offset));
}

/// §23.2.3.32 get %TypedArray%.prototype [ @@toStringTag ].
/// Returns the [[TypedArrayName]] string when `this` is a
/// TypedArray instance; otherwise `undefined` (never throws,
/// even on non-Object — invoking as a function passes
/// `undefined` as `this`).
fn typedArrayToStringTagGetter(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = args;
    // §23.2.3.32 step 1-3 — non-Object `this`, or Object without
    // a [[TypedArrayName]] slot, returns `undefined` (and the
    // getter never throws).
    const obj = heap_mod.valueAsPlainObject(this_value) orelse return Value.undefined_;
    const tv = obj.typed_view orelse return Value.undefined_;
    if (tv.name.len == 0) return Value.undefined_;
    const s = realm.heap.allocateString(tv.name) catch return error.OutOfMemory;
    return Value.fromString(s);
}

fn typedArrayBuffer(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = args;
    const obj = heap_mod.valueAsPlainObject(this_value) orelse return throwTypeError(realm, "TypedArray accessor on non-object");
    const tv = obj.typed_view orelse return throwTypeError(realm, "TypedArray.prototype.buffer called on a non-TypedArray");
    return heap_mod.taggedObject(tv.viewed);
}


fn typedArrayFill(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const bigint_mod = @import("bigint.zig");
    const tv = try taValidatedView(realm, this_value, "fill");
    // §23.2.3.11 step 3 — snapshot len. We re-read length /
    // buffer AFTER the coercions; spec step 10 (IsDetachedBuffer)
    // is checked there.
    const len_i: i64 = @intCast(taCurrentLength(tv));

    // §23.2.3.11 step 4 — coerce value first. ToBigInt for
    // BigInt typed arrays (must throw on undefined/null/string/
    // boolean), ToNumber otherwise. Both can fire side-effecting
    // valueOf / toString hooks; the coercion's normal completion
    // is reused per spec (once only).
    const value_arg = argOr(args, 0, Value.undefined_);
    const value_coerced: Value = switch (tv.kind) {
        .bigint64, .biguint64 => bigint_mod.toBigIntValue(realm, value_arg) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.NativeThrew,
        },
        else => try intrinsics.toNumber(realm, value_arg),
    };

    // §23.2.3.11 step 5-9 — start / end via ToIntegerOrInfinity,
    // clamped to [0, len]. ±Infinity / NaN handled inline.
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

    // §23.2.3.11 step 10 — `If IsDetachedBuffer(O.[[ViewedArrayBuffer]])
    // is true, throw a TypeError exception`. The coercions above
    // may have run a user `valueOf` that detached the buffer (or
    // resized a RAB to put the view OOB); fault HERE, before the
    // fill loop, per the spec's deferred detach check.
    const buf = taBufOf(tv) orelse return throwTypeError(realm, "TypedArray.prototype.fill: buffer detached during coercion");
    if (taIsOutOfBounds(tv)) {
        return throwTypeError(realm, "TypedArray.prototype.fill: TypedArray went out-of-bounds during coercion");
    }
    // Re-snapshot length: a RAB grow during coercion is observed
    // by the loop; a shrink that left us in-bounds is honored by
    // clamping `end` to the new length. (Spec §23.2.3.11 step 11
    // says: "Set endIndex to min(endIndex, len)" after the detach
    // check — Cynic took `end` against pre-coercion `len_i` so
    // re-clamp now.)
    const live_len: i64 = @intCast(taCurrentLength(tv));
    const end_clamped: i64 = @min(end, live_len);
    const elem_size = tv.kind.elementSize();

    var i: i64 = start;
    while (i < end_clamped) : (i += 1) {
        writeTypedElementForView(buf, tv, tv.byte_offset + @as(usize, @intCast(i)) * elem_size, value_coerced);
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

    // §23.2.3.27 step 8 — `ValidateTypedArray(target, SEQ-CST)`
    // happens BEFORE the source argument is touched. When the
    // target view is out-of-bounds over a resizable buffer (or
    // detached), a TypeError must propagate without ever calling
    // any source getters; V8 / JSC observably evaluate the
    // bounds witness here, not in the per-element loop.
    if (taIsOutOfBounds(tv)) {
        return throwTypeError(realm, "TypedArray.prototype.set: target is out-of-bounds");
    }

    const source_arg = argOr(args, 0, Value.undefined_);
    // §23.2.3.27 step 8/9 — branch on whether `array` already
    // has a [[TypedArrayName]] internal slot.
    //   - Object path: SetTypedArrayFromTypedArray.
    //   - Non-object / non-TA path: SetTypedArrayFromArrayLike,
    //     after ? ToObject(source).
    //
    // ToObject is what makes `ta.set(\"678\", 1)` valid:
    // the string is boxed → an arraylike with indexed slots +
    // \`length\`.  Numbers / booleans box to {} (length undefined
    // → 0), so \`ta.set(0)\` becomes a no-op.  Symbols / null /
    // undefined throw TypeError per ToObject.
    if (heap_mod.valueAsPlainObject(source_arg)) |po| {
        if (po.typed_view != null) {
            return try taSetFromTypedArray(realm, obj, tv, po, target_offset);
        }
        return try taSetFromArrayLike(realm, obj, tv, po, target_offset);
    }
    // §23.2.3.27 step 14 — `src = ? ToObject(array)`. ToObject
    // on Symbol / null / undefined throws TypeError; on
    // string / number / boolean it boxes.
    const boxed = try intrinsics.toObjectThis(realm, source_arg);
    return try taSetFromArrayLike(realm, obj, tv, boxed, target_offset);
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

    // §23.2.3.27.2 step 4 — `ValidateTypedArray(source, SEQ-CST)`
    // throws TypeError when the source view is out-of-bounds
    // (resizable buffer shrunk below its window).  Target was
    // already validated at method entry.
    if (taIsOutOfBounds(src_tv)) {
        return throwTypeError(realm, "TypedArray.prototype.set: source is out-of-bounds");
    }

    // §23.2.3.27.2 step 6 — disallow Big↔non-Big mixes (the
    // "ContentType(srcType) != ContentType(targetType)" check).
    {
        const src_big = src_tv.kind == .bigint64 or src_tv.kind == .biguint64;
        const dst_big = tv.kind == .bigint64 or tv.kind == .biguint64;
        if (src_big != dst_big) {
            return throwTypeError(realm, "TypedArray.prototype.set: cannot mix BigInt and Number typed arrays");
        }
    }
    // §23.2.3.27.2 — use the live `[[ArrayLength]]` so a length-
    // tracking view's count reflects the current buffer size.
    const target_length: usize = taCurrentLength(tv);
    const src_length: usize = taCurrentLength(src_tv);

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
            writeTypedElementForView(dst_buf, tv, dst_base + i * elem_size, v);
        }
        return Value.undefined_;
    }

    var i: usize = 0;
    while (i < src_length) : (i += 1) {
        const v = readTypedElement(realm, src_buf, src_tv.kind, src_base + i * src_size);
        writeTypedElementForView(dst_buf, tv, dst_base + i * elem_size, v);
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
    // §23.2.3.27.1 — use live `[[ArrayLength]]` so a length-
    // tracking target's capacity reflects the current buffer
    // size, and so a fixed-length target that's been shrunk OOB
    // reports 0 (the entry validation also throws TypeError on
    // OOB, but the per-element math still has to be correct).
    const target_length: usize = taCurrentLength(tv);
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
        // §23.2.3.27.1 step 22 — the per-element loop continues
        // even after a user `Get` accessor detaches the buffer or
        // shrinks the RAB so the view becomes OOB.  Writes to a
        // detached / OOB slot silently no-op (per
        // IntegerIndexedElementSet's IsValidIntegerIndex gate),
        // but ToNumber on the remaining source items still fires.
        const cur_tv = target.typed_view orelse continue;
        const cur_buf = cur_tv.viewed.array_buffer orelse continue;
        const slot = dst_base + k * elem_size;
        if (slot + elem_size > cur_buf.len) continue;
        writeTypedElementForView(cur_buf, cur_tv, slot, converted);
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

/// §10.4.5 ValidateTypedArray — combines the "is a TypedArray?"
/// brand check with the resizable-buffer out-of-bounds check.
/// Returns the view on success, throws TypeError otherwise.
/// `label` names the calling method for the diagnostic.
fn taValidatedView(realm: *Realm, this_value: Value, comptime label: []const u8) NativeError!ObjMod.TypedView {
    const tv = taViewOf(this_value) orelse return throwTypeError(realm, label ++ " called on non-TypedArray");
    if (taIsOutOfBounds(tv)) return throwTypeError(realm, label ++ " on out-of-bounds TypedArray");
    return tv;
}

/// §10.4.5 IsTypedArrayOutOfBounds — true when the view's
/// `[byte_offset, byte_offset + length*elemSize)` window spills
/// past the backing buffer's current length. Resizable
/// ArrayBuffers can be shrunk so that a fixed-length view that
/// was once in-bounds becomes out-of-bounds; the spec then
/// requires the TA method to throw TypeError via
/// ValidateTypedArray.
///
/// Per ES2024 §25.1.3.x IsTypedArrayOutOfBounds, a detached
/// buffer is reported as out-of-bounds (a detached buffer has
/// effective byte length 0). ValidateTypedArray therefore
/// throws TypeError at method entry on detach.
///
/// The ES2024 "align-detached-buffer-semantics-with-web-reality"
/// fixtures detach the buffer DURING the call (after Validate
/// returned) — per-element reads then fall through `taSafeRead`,
/// which returns undefined; the method completes without
/// throwing. See `taSafeRead` for that path.
fn taIsOutOfBounds(tv: ObjMod.TypedView) bool {
    const buf = tv.viewed.array_buffer orelse return true;
    // §10.4.5 IsTypedArrayOutOfBounds — for a length-tracking
    // view the only OOB condition is `byte_offset > buf.len`;
    // any remaining bytes (even zero) keep the view in-bounds.
    if (tv.length_tracking) return tv.byte_offset > buf.len;
    const elem_size = tv.kind.elementSize();
    const end = tv.byte_offset + tv.length * elem_size;
    return end > buf.len;
}

/// §10.4.5 [[ArrayLength]] for a possibly-length-tracking view.
/// Returns the live element count. Caller must have verified
/// `!taIsOutOfBounds(tv)` already; this routine only computes a
/// value and does not throw.
fn taCurrentLength(tv: ObjMod.TypedView) usize {
    const buf = tv.viewed.array_buffer orelse return 0;
    const elem_size = tv.kind.elementSize();
    if (!tv.length_tracking) {
        // §10.4.5 IsTypedArrayOutOfBounds — a fixed-length view
        // over a resizable buffer that's been shrunk past its
        // window reports a current length of 0; per-element
        // reads at any index then collapse to `undefined`
        // (ES2024 align-detached-buffer-semantics).
        if (tv.byte_offset + tv.length * elem_size > buf.len) return 0;
        return tv.length;
    }
    if (tv.byte_offset > buf.len) return 0;
    return (buf.len - tv.byte_offset) / elem_size;
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
    const cur_len = taCurrentLength(tv);
    if (i < 0 or i >= @as(i64, @intCast(cur_len))) return Value.undefined_;
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

/// §10.4.5 — "live" length used by iterators. For fixed-length
/// views this is the stored `[[ArrayLength]]`; for length-
/// tracking views it's the current count under the buffer.
fn taLiveLength(tv: ObjMod.TypedView) i64 {
    if (tv.length_tracking) return @intCast(taCurrentLength(tv));
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
    // §10.4.5 — length-tracking views always report the live
    // available element count; fixed-length views are clamped to
    // their stored `tv.length` (shrinks below it stay safe, even
    // though IsTypedArrayOutOfBounds usually catches that case).
    if (tv.length_tracking) return avail_elems;
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
///
/// `name_hint` (optional) lets callers disambiguate the two
/// constructors that share `kind = .uint8` — `Uint8Array` and
/// `Uint8ClampedArray`. When non-empty, it overrides the kind →
/// name mapping; otherwise the default-per-kind name is used.
/// `slice` / `map` / `filter` on a `Uint8ClampedArray` must
/// allocate a `Uint8ClampedArray` for the result (§23.2.4.7
/// TypedArraySpeciesCreate uses the exemplar's [[TypedArrayName]]
/// for the default constructor).
fn taMakeNew(realm: *Realm, kind: ObjMod.TypedKind, length: usize) NativeError!*JSObject {
    return taMakeNewNamed(realm, kind, length, "");
}

fn taMakeNewNamed(realm: *Realm, kind: ObjMod.TypedKind, length: usize, name_hint: []const u8) NativeError!*JSObject {
    const ctor_name = if (name_hint.len != 0) name_hint else nameForTypedKind(kind);
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
    inst.typed_view = .{ .kind = kind, .viewed = buf_obj, .byte_offset = 0, .length = length, .name = ctor_name };
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
/// §23.2.2.4 — `get %TypedArray% [@@species]`.  The getter is
/// installed on `%TypedArray%` and inherited by every concrete
/// constructor through `static_parent`, so `Uint8Array[@@species]`
/// resolves to `Uint8Array` and `MyU8[@@species]` (subclass of
/// `Uint8Array`) resolves to `MyU8` — exactly what TypedArrayCreate
/// needs when allocating the destination view of a `map` / `filter`
/// / `slice` / `subarray`.
fn typedArraySpeciesGetter(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = realm;
    _ = args;
    return this_value;
}

/// §10.1.8 [[Get]] applied to a function object — invokes an own
/// accessor's getter if present, otherwise walks the function's
/// proto chain (via `static_parent` → `proto`) looking for an
/// inherited accessor before falling through to the data-property
/// lookup.  Used to read `@@species` off a subclass constructor
/// where the slot is a getter on `%TypedArray%`.
fn taGetFunctionMember(realm: *Realm, fn_obj: *JSFunction, key: []const u8) NativeError!Value {
    var cur: ?*JSFunction = fn_obj;
    while (cur) |f| {
        if (f.accessors.get(key)) |acc| {
            if (acc.getter) |getter| {
                const interp = @import("../interpreter.zig");
                const outcome = interp.callJSFunction(realm.allocator, realm, getter, heap_mod.taggedFunction(fn_obj), &[_]Value{}) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    else => return error.NativeThrew,
                };
                switch (outcome) {
                    .value, .yielded => |v| return v,
                    .thrown => |ex| {
                        realm.pending_exception = ex;
                        return error.NativeThrew;
                    },
                }
            }
            return Value.undefined_;
        }
        cur = f.static_parent;
    }
    return fn_obj.get(key);
}

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
                species_v = try taGetFunctionMember(realm, fn_obj, "@@species");
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
    // Use the exemplar's [[TypedArrayName]] so Uint8Array vs
    // Uint8ClampedArray (which share `kind = .uint8`) round-trip
    // through species fallback as themselves.
    if (species_v.isUndefined() or species_v.isNull()) {
        const exemplar_name: []const u8 = if (exemplar.typed_view) |tv| tv.name else "";
        return taMakeNewNamed(realm, kind, length, exemplar_name);
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
    // §23.2.4.4 TypedArrayCreate post-conditions:
    //   - The result is a TypedArray (has [[TypedArrayName]]).
    //   - result.[[ContentType]] === exemplar.[[ContentType]].
    //     ContentType is `bigint` for BigInt64Array/BigUint64Array
    //     and `number` for everything else — kind equality is
    //     too strict (an Int8Array ↔ Uint8Array swap is fine).
    //   - When argumentList is « length », result.[[ArrayLength]]
    //     ≥ length. The "too short" check is done by the caller
    //     (slice/filter/map post-allocate); we still do it here as
    //     the only common bottleneck.
    const result_obj = heap_mod.valueAsPlainObject(result_v) orelse return throwTypeError(realm, "TypedArray species ctor returned non-object");
    const result_tv = result_obj.typed_view orelse return throwTypeError(realm, "TypedArray species ctor returned non-TypedArray");
    if (result_tv.kind.isBigInt() != kind.isBigInt()) return throwTypeError(realm, "TypedArray species ctor returned wrong content type");
    if (taCurrentLength(result_tv) < length) return throwTypeError(realm, "TypedArray species ctor returned too-short TypedArray");
    // §23.2.4.4 step 2.b — if the species ctor returned the same
    // buffer as the exemplar (i.e. the result aliases over
    // exemplar's storage), TypedArrayCreate would still allow it.
    // We don't track an "is same buffer" check explicitly; callers
    // that copy element-by-element (slice/filter/map) handle it.
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
        .float16 => "Float16Array",
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
    /// §23.2.3.x — length snapshot taken via TypedArrayLength
    /// against the buffer witness at method entry. The spec
    /// iterates this snapshot even if the buffer shrinks
    /// mid-callback (out-of-range reads then yield `undefined`
    /// per §10.4.5 IntegerIndexedElementGet).
    len: usize,
} {
    const obj = heap_mod.valueAsPlainObject(this_value) orelse return throwTypeError(realm, "TypedArray method on non-object");
    const tv = obj.typed_view orelse return throwTypeError(realm, "TypedArray method on non-TypedArray");
    // §10.4.5 ValidateTypedArray — a resizable backing buffer
    // may have been shrunk under us, leaving the view's window
    // off the end of the buffer. The spec requires this check
    // before any element read.
    if (taIsOutOfBounds(tv)) return throwTypeError(realm, "TypedArray method called on out-of-bounds TypedArray");
    const callback = heap_mod.valueAsFunction(argOr(args, 0, Value.undefined_)) orelse return throwTypeError(realm, "callback is not a function");
    const this_arg = argOr(args, 1, Value.undefined_);
    return .{ .tv = tv, .buf = tv.viewed.array_buffer, .callback = callback, .this_arg = this_arg, .self_obj = obj, .len = taCurrentLength(tv) };
}

fn typedArrayAt(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    // §23.2.3.1 %TypedArray%.prototype.at(index).
    const tv = try taValidatedView(realm, this_value, "at");
    const idx_arg = argOr(args, 0, Value.fromInt32(0));
    // §23.2.3.1 step 4 — ToIntegerOrInfinity(index).
    // We must run the coercion (fires user `valueOf`) BEFORE
    // looking at the typed array length, and use the coerced
    // integer (not the raw arg) for the negative-from-end /
    // range test.
    const idx_num = try intrinsics.toNumber(realm, idx_arg);
    const idx_n: f64 = if (idx_num.isInt32())
        @floatFromInt(idx_num.asInt32())
    else if (idx_num.isDouble())
        idx_num.asDouble()
    else
        0;
    const len: i64 = @intCast(taCurrentLength(tv));
    // §7.1.5 ToIntegerOrInfinity — NaN→0; trunc otherwise.
    const trunc_n = if (std.math.isNan(idx_n)) 0.0 else @trunc(idx_n);
    const max_i: f64 = @floatFromInt(std.math.maxInt(i64));
    const min_i: f64 = @floatFromInt(std.math.minInt(i64));
    const raw_i: i64 = if (trunc_n >= max_i) std.math.maxInt(i64) else if (trunc_n <= min_i) std.math.minInt(i64) else @intFromFloat(trunc_n);
    const target_i: i64 = if (raw_i < 0) raw_i +| len else raw_i;
    if (target_i < 0 or target_i >= len) return Value.undefined_;
    // §23.2.3.1 step 8 — `at` reads through IntegerIndexedElementGet;
    // ES2024 detached buffers return undefined, not throw.
    return taSafeRead(realm, tv, target_i);
}

fn typedArrayCopyWithin(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    // §23.2.3.6 step 1-2 — ValidateTypedArray + snapshot len.
    const tv = try taValidatedView(realm, this_value, "copyWithin");
    const len: i64 = @intCast(taCurrentLength(tv));
    // §23.2.3.6 step 3-8 — coerce target / start / end FIRST.
    // The valueOf hooks may detach the buffer (or resize a RAB
    // to leave the view OOB); both are checked at step 9 below.
    const target = try taResolveIndex(realm, argOr(args, 0, Value.fromInt32(0)), len, 0);
    const start = try taResolveIndex(realm, argOr(args, 1, Value.fromInt32(0)), len, 0);
    const end = try taResolveIndex(realm, argOr(args, 2, Value.undefined_), len, len);
    // §23.2.3.6 step 9 — re-validate after coercions. A user
    // valueOf may have detached `O.[[ViewedArrayBuffer]]`; the
    // spec calls IsDetachedBuffer here (effectively the same
    // ValidateTypedArray check) and only proceeds with the
    // memmove when the buffer is still live.
    const buf = taBufOf(tv) orelse return throwTypeError(realm, "TypedArray.prototype.copyWithin: buffer detached during coercion");
    if (taIsOutOfBounds(tv)) {
        return throwTypeError(realm, "TypedArray.prototype.copyWithin: TypedArray went out-of-bounds during coercion");
    }
    // §23.2.3.6 step 10 — recompute len against the post-coercion
    // buffer (a RAB shrink reduces the count; a grow leaves the
    // original count intact since we capture it pre-coercion).
    const live_len: i64 = @intCast(taCurrentLength(tv));
    const eff_target = @min(target, live_len);
    const eff_start = @min(start, live_len);
    const eff_end = @min(end, live_len);
    const count = @min(eff_end - eff_start, live_len - eff_target);
    if (count <= 0) return this_value;
    const elem_size = tv.kind.elementSize();
    const byte_count: usize = @as(usize, @intCast(count)) * elem_size;
    const src_off = tv.byte_offset + @as(usize, @intCast(eff_start)) * elem_size;
    const dst_off = tv.byte_offset + @as(usize, @intCast(eff_target)) * elem_size;
    if (src_off + byte_count > buf.len or dst_off + byte_count > buf.len) {
        return this_value; // clamped to whatever's available
    }
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
    while (i < ctx.len) : (i += 1) {
        const v = taSafeRead(realm, ctx.tv, @intCast(i));
        _ = try invokeCallback(realm, ctx.callback, ctx.this_arg, v, @intCast(i), ctx.self_obj);
    }
    return Value.undefined_;
}

fn typedArrayEvery(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const ctx = try taCallbackPreamble(realm, this_value, args);
    var i: usize = 0;
    while (i < ctx.len) : (i += 1) {
        const v = taSafeRead(realm, ctx.tv, @intCast(i));
        const r = try invokeCallback(realm, ctx.callback, ctx.this_arg, v, @intCast(i), ctx.self_obj);
        if (!toBoolean(r)) return Value.false_;
    }
    return Value.true_;
}

fn typedArraySome(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const ctx = try taCallbackPreamble(realm, this_value, args);
    var i: usize = 0;
    while (i < ctx.len) : (i += 1) {
        const v = taSafeRead(realm, ctx.tv, @intCast(i));
        const r = try invokeCallback(realm, ctx.callback, ctx.this_arg, v, @intCast(i), ctx.self_obj);
        if (toBoolean(r)) return Value.true_;
    }
    return Value.false_;
}

fn typedArrayFind(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const ctx = try taCallbackPreamble(realm, this_value, args);
    var i: usize = 0;
    while (i < ctx.len) : (i += 1) {
        const v = taSafeRead(realm, ctx.tv, @intCast(i));
        const r = try invokeCallback(realm, ctx.callback, ctx.this_arg, v, @intCast(i), ctx.self_obj);
        if (toBoolean(r)) return v;
    }
    return Value.undefined_;
}

fn typedArrayFindIndex(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const ctx = try taCallbackPreamble(realm, this_value, args);
    var i: usize = 0;
    while (i < ctx.len) : (i += 1) {
        const v = taSafeRead(realm, ctx.tv, @intCast(i));
        const r = try invokeCallback(realm, ctx.callback, ctx.this_arg, v, @intCast(i), ctx.self_obj);
        if (toBoolean(r)) return numberFromI64(@intCast(i));
    }
    return Value.fromInt32(-1);
}

fn typedArrayFindLast(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const ctx = try taCallbackPreamble(realm, this_value, args);
    var i: i64 = @as(i64, @intCast(ctx.len)) - 1;
    while (i >= 0) : (i -= 1) {
        const v = taSafeRead(realm, ctx.tv, i);
        const r = try invokeCallback(realm, ctx.callback, ctx.this_arg, v, i, ctx.self_obj);
        if (toBoolean(r)) return v;
    }
    return Value.undefined_;
}

fn typedArrayFindLastIndex(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const ctx = try taCallbackPreamble(realm, this_value, args);
    var i: i64 = @as(i64, @intCast(ctx.len)) - 1;
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
    const tv = try taValidatedView(realm, this_value, "includes");
    const len: i64 = @intCast(taCurrentLength(tv));
    // §23.2.3.14 step 4 — If len is 0, return false. Length is
    // checked BEFORE ToIntegerOrInfinity(fromIndex), so an empty
    // TA + throwing fromIndex returns false without firing the
    // valueOf throw.
    if (len == 0) return Value.false_;
    const target = argOr(args, 0, Value.undefined_);
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
    const tv = try taValidatedView(realm, this_value, "indexOf");
    // §23.2.3.16 step 4 — If len is 0, return -1. The length
    // check happens BEFORE ToIntegerOrInfinity(fromIndex), so a
    // throwing `fromIndex.valueOf` is not observed on an empty
    // TypedArray.
    const len: i64 = @intCast(taCurrentLength(tv));
    if (len == 0) return Value.fromInt32(-1);
    // §23.2.3.16 — indexOf uses IsStrictlyEqual; reads from a
    // detached buffer surface as undefined and only equal a
    // strictly-undefined search target.
    const target = argOr(args, 0, Value.undefined_);
    var from = try taResolveIndex(realm, argOr(args, 1, Value.fromInt32(0)), len, 0);
    if (from < 0) from = 0;
    // §23.2.3.16 step 8 — HasProperty(O, k) is `false` once the
    // buffer is detached (mid-call via `fromIndex.valueOf`); the
    // spec's loop returns -1 in that case.
    if (tv.viewed.array_buffer == null) return Value.fromInt32(-1);
    var i: i64 = from;
    while (i < len) : (i += 1) {
        const v = taSafeRead(realm, tv, i);
        if (strictEqualsLite(v, target)) return numberFromI64(i);
    }
    return Value.fromInt32(-1);
}

fn typedArrayLastIndexOf(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const tv = try taValidatedView(realm, this_value, "lastIndexOf");
    // §23.2.3.18 step 4 — If len is 0, return -1.  This happens
    // BEFORE ToIntegerOrInfinity(fromIndex), so an empty TA + a
    // throwing fromIndex still returns -1.
    const len: i64 = @intCast(taCurrentLength(tv));
    if (len == 0) return Value.fromInt32(-1);
    const target = argOr(args, 0, Value.undefined_);
    var from: i64 = len - 1;
    // §23.2.3.18 step 4 — "If fromIndex is present" means present
    // as an argument; passing `undefined` explicitly still triggers
    // the ToIntegerOrInfinity branch (which yields 0).  Only an
    // omitted second arg falls back to `len - 1`.
    if (args.len > 1) {
        // §23.2.3.18 step 5 — ToIntegerOrInfinity(fromIndex).
        // Use taResolveIndex which routes through `toNumber` so
        // user `valueOf` fires + throws propagate.
        const fi_num = try intrinsics.toNumber(realm, args[1]);
        const fi_n: f64 = if (fi_num.isInt32())
            @floatFromInt(fi_num.asInt32())
        else if (fi_num.isDouble())
            fi_num.asDouble()
        else
            0;
        // §23.2.3.18 step 6 — relativeIndex semantics:
        //   if fromIndex < 0: from := len + fromIndex
        //   else: from := min(fromIndex, len - 1)
        if (std.math.isNan(fi_n)) {
            from = 0;
        } else {
            const trunc_n = @trunc(fi_n);
            const max_i: f64 = @floatFromInt(std.math.maxInt(i64));
            const min_i: f64 = @floatFromInt(std.math.minInt(i64));
            const fi_i: i64 = if (trunc_n >= max_i)
                std.math.maxInt(i64)
            else if (trunc_n <= min_i)
                std.math.minInt(i64)
            else
                @intFromFloat(trunc_n);
            from = if (fi_i < 0) len +| fi_i else @min(fi_i, len - 1);
        }
    }
    // §23.2.3.18 step 8 — `kPresent` is `false` after detach
    // (the `fromIndex.valueOf` may have triggered it), so the
    // loop returns -1 without inspecting elements.
    if (tv.viewed.array_buffer == null) return Value.fromInt32(-1);
    var i: i64 = from;
    while (i >= 0) : (i -= 1) {
        const v = taSafeRead(realm, tv, i);
        if (strictEqualsLite(v, target)) return numberFromI64(i);
    }
    return Value.fromInt32(-1);
}

fn typedArrayJoin(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    // §23.2.3.15 step 2 — ValidateTypedArray throws on pre-call
    // detach. ES2024 "align-detached-buffer-semantics-with-web-
    // reality": if `separator.toString` detaches mid-call, the
    // per-element reads return `undefined` (via `taSafeRead`),
    // each stringifies to the empty string per step 7.c, and
    // the join completes producing only the separators.
    const tv = try taValidatedView(realm, this_value, "join");
    // §23.2.3.15 step 3 — `Let len be TypedArrayLength(taRecord)`.
    // Capture BEFORE coercing `separator`; per
    // detached-buffer-during-fromIndex-returns-single-comma.js
    // the original len is iterated even if separator.toString
    // detaches the buffer mid-call.
    const join_len = taCurrentLength(tv);
    const sep_v = argOr(args, 0, Value.undefined_);
    const sep_s: []const u8 = if (sep_v.isUndefined()) "," else blk: {
        const s = try stringifyArg(realm, sep_v);
        break :blk s.bytes;
    };
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(realm.allocator);
    var i: usize = 0;
    while (i < join_len) : (i += 1) {
        if (i > 0) out.appendSlice(realm.allocator, sep_s) catch return error.OutOfMemory;
        const v = taSafeRead(realm, tv, @intCast(i));
        // §23.2.3.15 step 7.c — `If element is undefined or null,
        // let next be the empty String`. Skip stringification.
        if (v.isUndefined() or v.isNull()) continue;
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
    const tv = try taValidatedView(realm, this_value, "toLocaleString");
    const buf = taBufOf(tv) orelse return throwTypeError(realm, "TypedArray detached");
    const elem_size = tv.kind.elementSize();
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(realm.allocator);
    const interpreter = @import("../interpreter.zig");
    const tls_len = taCurrentLength(tv);
    var i: usize = 0;
    while (i < tls_len) : (i += 1) {
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
                .thrown => |ex| {
                    realm.pending_exception = ex;
                    return error.NativeThrew;
                },
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
    const tv = try taValidatedView(realm, this_value, "reduce");
    const obj = heap_mod.valueAsPlainObject(this_value).?;
    const callback = heap_mod.valueAsFunction(argOr(args, 0, Value.undefined_)) orelse return throwTypeError(realm, "callback is not a function");
    const has_init = args.len >= 2;
    // §23.2.3.22 step 5 — `[[ArrayLength]]` is captured once at
    // method entry; the loop iterates that many times even when
    // the user callback shrinks the backing buffer mid-iteration.
    // OOB reads inside the loop must collapse to `undefined`
    // (§10.4.5.1 IntegerIndexedElementGet; ES2024 align-detached-
    // buffer-semantics).
    const reduce_len = taCurrentLength(tv);
    if (reduce_len == 0 and !has_init) return throwTypeError(realm, "Reduce of empty TypedArray with no initial value");
    var acc: Value = if (has_init) args[1] else taSafeRead(realm, tv, 0);
    var i: usize = if (has_init) 0 else 1;
    while (i < reduce_len) : (i += 1) {
        const v = taSafeRead(realm, tv, @intCast(i));
        const interpreter = @import("../interpreter.zig");
        const cb_args = [_]Value{ acc, v, numberFromI64(@intCast(i)), heap_mod.taggedObject(obj) };
        const outcome = interpreter.callJSFunction(realm.allocator, realm, callback, Value.undefined_, &cb_args) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.NativeThrew,
        };
        switch (outcome) {
            .value, .yielded => |x| acc = x,
            .thrown => |ex| {
                realm.pending_exception = ex;
                return error.NativeThrew;
            },
        }
    }
    return acc;
}

fn typedArrayReduceRight(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const tv = try taValidatedView(realm, this_value, "reduceRight");
    const obj = heap_mod.valueAsPlainObject(this_value).?;
    const callback = heap_mod.valueAsFunction(argOr(args, 0, Value.undefined_)) orelse return throwTypeError(realm, "callback is not a function");
    const has_init = args.len >= 2;
    // §23.2.3.23 — see `typedArrayReduce`: length captured at
    // entry; OOB reads after a callback-driven shrink collapse to
    // `undefined` via `taSafeRead`.
    const rr_len = taCurrentLength(tv);
    if (rr_len == 0 and !has_init) return throwTypeError(realm, "Reduce of empty TypedArray with no initial value");
    var i: i64 = @as(i64, @intCast(rr_len)) - 1;
    var acc: Value = if (has_init) args[1] else blk: {
        const v = taSafeRead(realm, tv, i);
        i -= 1;
        break :blk v;
    };
    while (i >= 0) : (i -= 1) {
        const v = taSafeRead(realm, tv, i);
        const interpreter = @import("../interpreter.zig");
        const cb_args = [_]Value{ acc, v, numberFromI64(i), heap_mod.taggedObject(obj) };
        const outcome = interpreter.callJSFunction(realm.allocator, realm, callback, Value.undefined_, &cb_args) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.NativeThrew,
        };
        switch (outcome) {
            .value, .yielded => |x| acc = x,
            .thrown => |ex| {
                realm.pending_exception = ex;
                return error.NativeThrew;
            },
        }
    }
    return acc;
}

fn typedArrayReverse(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = args;
    const tv = try taValidatedView(realm, this_value, "reverse");
    const buf = tv.viewed.array_buffer orelse return error.NativeThrew;
    const elem_size = tv.kind.elementSize();
    var lo: usize = 0;
    var hi: usize = taCurrentLength(tv);
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
    const tv_pre = try taValidatedView(realm, this_value, "slice");
    const self = heap_mod.valueAsPlainObject(this_value).?;
    const len: i64 = @intCast(taCurrentLength(tv_pre));
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
    // §23.2.3.30 step 2 — ValidateTypedArray. NOTE: subarray
    // is one of the few methods that historically did NOT
    // throw on OOB (it just produces a new OOB view). The
    // ES2024 RAB integration ratified the OOB throw for
    // *most* methods but subarray's behavior is to compute
    // against the current bounds — keep the brand check only.
    const self = heap_mod.valueAsPlainObject(this_value) orelse return throwTypeError(realm, "subarray on non-TypedArray");
    const tv = self.typed_view orelse return throwTypeError(realm, "subarray on non-TypedArray");
    // §23.2.3.30 subarray — uses GetArrayBufferMaxByteLength
    // and the buffer witness's `[[ArrayLength]]`. For a length-
    // tracking view this is the live count; for fixed-length
    // views it's the stored length.
    const len: i64 = @intCast(taCurrentLength(tv));
    const begin = try taResolveIndex(realm, argOr(args, 0, Value.fromInt32(0)), len, 0);
    const elem_size = tv.kind.elementSize();
    const new_offset = tv.byte_offset + @as(usize, @intCast(begin)) * elem_size;

    // §23.2.3.31 step 15 — when `end` is undefined AND the source
    // view is length-tracking, the new subarray inherits the
    // length-tracking property (no fixed length is supplied to
    // TypedArrayCreate). Otherwise a concrete `newLength` is
    // computed from `(end - begin)`, clamped to ≥ 0.
    const end_arg = argOr(args, 1, Value.undefined_);
    const inherit_length_tracking = tv.length_tracking and end_arg.isUndefined();
    const new_len: usize = if (inherit_length_tracking)
        0
    else blk: {
        const end_i = try taResolveIndex(realm, end_arg, len, len);
        break :blk if (end_i > begin) @as(usize, @intCast(end_i - begin)) else 0;
    };

    // §23.2.3.31 step 17 — `TypedArraySpeciesCreate(O, «buffer,
    // byteOffset, newLength»)`; or, when the new view inherits
    // length-tracking from O (step 15), the two-arg shape
    // «buffer, byteOffset».
    const out_obj = try taSpeciesCreateSubarray(realm, self, tv.kind, tv.viewed, new_offset, new_len, inherit_length_tracking);
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
    length_tracking: bool,
) NativeError!*JSObject {
    const ctor_prop = intrinsics.getPropertyChain(realm, exemplar, "constructor") catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.NativeThrew,
    };
    var species_v = Value.undefined_;
    if (!ctor_prop.isUndefined()) {
        const ctor_obj_or_fn = heap_mod.valueAsPlainObject(ctor_prop) orelse blk: {
            if (heap_mod.valueAsFunction(ctor_prop)) |fn_obj| {
                species_v = try taGetFunctionMember(realm, fn_obj, "@@species");
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
        // §23.2.4.2 TypedArrayCreate inlined for the default species:
        // build a view directly on the shared buffer. §23.2.5.1.4
        // step 11 — `If IsDetachedBuffer(buffer) is true, throw a
        // TypeError`. The user's `valueOf` on `begin` / `end` (run
        // earlier in `subarray`) may have detached the buffer
        // between the brand check and here; the spec defers the
        // throw to this inner TA construction.
        if (buffer.array_buffer == null) return throwTypeError(realm, "TypedArray: ArrayBuffer is detached");
        // §23.2.5.1.4 — the inlined TypedArrayCreate refuses a
        // byteOffset past the live buffer length, and (for fixed-
        // length views) refuses `byteOffset + length*elemSize` past
        // it.  Subarray inherits that throw via
        // TypedArraySpeciesCreate.
        const buf_bytes = buffer.array_buffer.?;
        const elem_size = kind.elementSize();
        if (byte_offset > buf_bytes.len) return throwRangeError(realm, "subarray: byteOffset exceeds buffer");
        if (!length_tracking and byte_offset + length * elem_size > buf_bytes.len) return throwRangeError(realm, "subarray: view exceeds buffer");
        // Preserve [[TypedArrayName]] across the default-species
        // fallback so a Uint8ClampedArray subarray stays clamped.
        const ctor_name: []const u8 = if (exemplar.typed_view) |etv|
            (if (etv.name.len != 0) etv.name else nameForTypedKind(kind))
        else
            nameForTypedKind(kind);
        const ctor = heap_mod.valueAsFunction(realm.globals.get(ctor_name) orelse Value.undefined_) orelse return throwTypeError(realm, "TypedArray constructor not found");
        const inst = realm.heap.allocateObject() catch return error.OutOfMemory;
        inst.prototype = ctor.prototype;
        inst.typed_view = .{
            .kind = kind,
            .viewed = buffer,
            .byte_offset = byte_offset,
            .length = length,
            .name = ctor_name,
            .length_tracking = length_tracking,
        };
        return inst;
    }
    const species_fn = heap_mod.valueAsFunction(species_v) orelse return throwTypeError(realm, "TypedArray @@species is not a constructor");
    // §23.2.5.1.4 NewTypedArrayFromArrayBuffer step 11 — even
    // the user-overridden species ctor receives a detached
    // buffer and will throw inside its TA constructor. Throw
    // earlier so we don't re-enter for nothing; this also
    // sidesteps engines that short-circuit the construct
    // when buffer is null. (The construct path below would
    // throw anyway via the inner ArrayBuffer-detached check
    // inside `typedArrayConstructorBuilder`, but failing fast
    // matches V8 / JSC.)
    if (buffer.array_buffer == null) return throwTypeError(realm, "TypedArray: ArrayBuffer is detached");
    const scope = realm.heap.openScope() catch return error.OutOfMemory;
    defer scope.close();
    // §23.2.3.31 steps 15-16 — argument list shape depends on
    // length-tracking inheritance.  When O.[[ArrayLength]] is auto
    // and end is undefined the species ctor receives «buffer,
    // beginByteOffset»; otherwise it receives the three-arg
    // form «buffer, beginByteOffset, newLength».
    const ctor_args_three = [_]Value{
        heap_mod.taggedObject(buffer),
        Value.fromInt32(@as(i32, @intCast(@min(byte_offset, std.math.maxInt(i32))))),
        Value.fromInt32(@as(i32, @intCast(@min(length, std.math.maxInt(i32))))),
    };
    const ctor_args_two = [_]Value{
        heap_mod.taggedObject(buffer),
        Value.fromInt32(@as(i32, @intCast(@min(byte_offset, std.math.maxInt(i32))))),
    };
    const ctor_args: []const Value = if (length_tracking) ctor_args_two[0..] else ctor_args_three[0..];
    const interpreter = @import("../interpreter.zig");
    const callee_v = heap_mod.taggedFunction(species_fn);
    const outcome = interpreter.constructValue(realm.allocator, realm, callee_v, ctor_args, callee_v) catch |err| switch (err) {
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
    // §23.2.4.4 TypedArrayCreate — content-type parity only
    // (BigInt vs Number); kind itself can differ across the
    // Uint8Array / Uint8ClampedArray boundary.
    if (result_tv.kind.isBigInt() != kind.isBigInt()) return throwTypeError(realm, "TypedArray species ctor returned wrong content type");
    return result_obj;
}

fn typedArrayMap(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const ctx = try taCallbackPreamble(realm, this_value, args);
    // §23.2.3.19 step 6 — TypedArraySpeciesCreate(O, « len »).
    const out = try taSpeciesCreate(realm, ctx.self_obj, ctx.tv.kind, ctx.len);
    // §23.2.3.20 map writes through the species result's
    // [[ElementType]], which may differ from `O.[[ContentType]]`
    // when a custom @@species returns a different-kind TA.
    const out_tv = out.typed_view.?;
    const out_buf = out_tv.viewed.array_buffer.?;
    const out_elem_size = out_tv.kind.elementSize();
    var i: usize = 0;
    while (i < ctx.len) : (i += 1) {
        const v = taSafeRead(realm, ctx.tv, @intCast(i));
        const mapped = try invokeCallback(realm, ctx.callback, ctx.this_arg, v, @intCast(i), ctx.self_obj);
        writeTypedElementForView(out_buf, out_tv, i * out_elem_size, mapped);
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
    while (i < ctx.len) : (i += 1) {
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
    // §25.3.2.1 step 2 — RequireInternalSlot(buffer, [[ArrayBufferData]]):
    // brand check on the constructor argument. Use
    // `has_array_buffer_data` so a *detached* ArrayBuffer still
    // satisfies the brand here; the dedicated detached-buffer
    // throw lives further down per step 7 — after ToIndex has had
    // a chance to fire any user-observable `valueOf` on
    // `byteOffset`.
    if (!buf_obj.has_array_buffer_data) return throwTypeError(realm, "DataView: first argument must be an ArrayBuffer");

    // §25.3.2.1 step 3 — ToIndex(byteOffset). Runs BEFORE the
    // detached check (step 7) so a `valueOf` side-effect on
    // `byteOffset` is still observable when the buffer was
    // detached before the call.
    const byte_offset = try dvToIndex(realm, argOr(args, 1, Value.undefined_));

    // §25.3.2.1 step 7 — IsDetachedBuffer. The detach can happen
    // before the call or inside `byteOffset`'s `valueOf`; either
    // way `array_buffer == null` once we reach this point.
    const buf1 = buf_obj.array_buffer orelse return throwTypeError(realm, "DataView: ArrayBuffer is detached");
    if (byte_offset > buf1.len) return throwRangeError(realm, "DataView: byteOffset exceeds buffer");

    const length_arg = argOr(args, 2, Value.undefined_);
    var byte_length: usize = undefined;
    // §25.3.2.1 — `byteLength` omitted over a resizable buffer
    // creates a length-tracking DataView; the live byte length
    // is `bufLen - byte_offset` (re-resolved on every access),
    // and going out of bounds throws TypeError on the accessor.
    var length_tracking = false;
    const is_resizable_dv = buf_obj.array_buffer_max_byte_length != null;
    if (length_arg.isUndefined()) {
        byte_length = buf1.len - byte_offset;
        if (is_resizable_dv) length_tracking = true;
    } else {
        byte_length = try dvToIndex(realm, length_arg);
        const buf2 = buf_obj.array_buffer orelse return throwTypeError(realm, "DataView: ArrayBuffer detached during construction");
        if (byte_offset > buf2.len or byte_length > buf2.len - byte_offset) return throwRangeError(realm, "DataView: byteLength exceeds buffer");
    }
    inst.data_view = .{ .viewed = buf_obj, .byte_offset = byte_offset, .byte_length = byte_length, .length_tracking = length_tracking };
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
    // §25.3.4.1 — detached or OOB → TypeError. For a length-
    // tracking DataView the live byte length is recomputed from
    // the current buffer; the view is OOB only when its
    // `byte_offset` is past the end of the buffer.
    const buf = dv.viewed.array_buffer orelse return throwTypeError(realm, "DataView: buffer is detached");
    if (dv.length_tracking) {
        if (dv.byte_offset > buf.len) return throwTypeError(realm, "DataView: out-of-bounds");
        return Value.fromInt32(@intCast(buf.len - dv.byte_offset));
    }
    if (dv.byte_offset + dv.byte_length > buf.len) return throwTypeError(realm, "DataView: out-of-bounds");
    return Value.fromInt32(@intCast(dv.byte_length));
}

fn dataViewByteOffset(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = args;
    const dv = dvOf(this_value) orelse return throwTypeError(realm, "DataView accessor on non-DataView");
    // §25.3.4.2 — detached or OOB → TypeError.
    const buf = dv.viewed.array_buffer orelse return throwTypeError(realm, "DataView: buffer is detached");
    if (dv.length_tracking) {
        if (dv.byte_offset > buf.len) return throwTypeError(realm, "DataView: out-of-bounds");
    } else if (dv.byte_offset + dv.byte_length > buf.len) {
        return throwTypeError(realm, "DataView: out-of-bounds");
    }
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
    // §25.3.1.1 GetViewByteLength — live byte length for length-
    // tracking views; the stored snapshot for fixed-length ones.
    // If the view is itself OOB after a resize of the underlying
    // resizable buffer, throw TypeError per spec (IsViewOutOfBounds).
    const view_byte_len: usize = if (dv.length_tracking) blk: {
        if (dv.byte_offset > buf.len) return throwTypeError(realm, "DataView: out-of-bounds");
        break :blk buf.len - dv.byte_offset;
    } else blk: {
        // Fixed-length view: byteOffset + byteLength must still fit
        // in the (possibly shrunk) resizable buffer.
        if (dv.byte_offset > buf.len or dv.byte_length > buf.len - dv.byte_offset) {
            return throwTypeError(realm, "DataView: out-of-bounds");
        }
        break :blk dv.byte_length;
    };
    // step 12-13 — bounds (overflow-safe).
    if (elem_size > view_byte_len or off > view_byte_len - elem_size) {
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
    const view_byte_len: usize = if (dv.length_tracking) blk: {
        if (dv.byte_offset > buf.len) return throwTypeError(realm, "DataView: out-of-bounds");
        break :blk buf.len - dv.byte_offset;
    } else blk: {
        if (dv.byte_offset > buf.len or dv.byte_length > buf.len - dv.byte_offset) {
            return throwTypeError(realm, "DataView: out-of-bounds");
        }
        break :blk dv.byte_length;
    };
    if (elem_size > view_byte_len or off > view_byte_len - elem_size) {
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
// §25.3.4.6 DataView.prototype.getFloat16 — ES2024 Float16Array
// proposal. Reads 2 bytes, decodes as IEEE 754 binary16 (1+5+10),
// returns as a Number (f64). NaN/Inf/subnormals fall out of the
// hardware @floatCast.
fn dataViewGetFloat16(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const a = try dvGetPrologue(realm, this_value, args, 2);
    const u = dvReadEndian(u16, a.buf, a.abs_offset, dvLittleEndian(args, 1));
    const f: f16 = @bitCast(u);
    return Value.fromDouble(@floatCast(f));
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
// §25.3.4.18 DataView.prototype.setFloat16 — round-to-nearest-ties-
// to-even per IEEE 754 §11.5 falls out of Zig's @floatCast f64 → f16
// on every supported target. Bit-cast to u16 and write 2 bytes.
fn dataViewSetFloat16(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const a = try dvSetNumPrologue(realm, this_value, args, 2);
    const f: f16 = @floatCast(a.value);
    const u: u16 = @bitCast(f);
    dvWriteEndian(u16, a.buf, a.abs_offset, u, dvLittleEndian(args, 2));
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
    const vbl: usize = if (dv.length_tracking) blk: {
        if (dv.byte_offset > buf.len) return throwTypeError(realm, "DataView: out-of-bounds");
        break :blk buf.len - dv.byte_offset;
    } else blk: {
        if (dv.byte_offset > buf.len or dv.byte_length > buf.len - dv.byte_offset) {
            return throwTypeError(realm, "DataView: out-of-bounds");
        }
        break :blk dv.byte_length;
    };
    if (8 > vbl or off > vbl - 8) return throwRangeError(realm, "DataView: byte offset out of bounds");
    dvWriteEndian(i64, buf, dv.byte_offset + off, i, dvLittleEndian(args, 2));
    return Value.undefined_;
}
fn dataViewSetBigUint64(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const dv = dvOf(this_value) orelse return throwTypeError(realm, "DataView method on non-DataView");
    const off = try dvToIndex(realm, argOr(args, 0, Value.undefined_));
    const i = try dvToBigInt64(realm, argOr(args, 1, Value.undefined_));
    const buf = dv.viewed.array_buffer orelse return throwTypeError(realm, "DataView: buffer is detached");
    const vbl: usize = if (dv.length_tracking) blk: {
        if (dv.byte_offset > buf.len) return throwTypeError(realm, "DataView: out-of-bounds");
        break :blk buf.len - dv.byte_offset;
    } else blk: {
        if (dv.byte_offset > buf.len or dv.byte_length > buf.len - dv.byte_offset) {
            return throwTypeError(realm, "DataView: out-of-bounds");
        }
        break :blk dv.byte_length;
    };
    if (8 > vbl or off > vbl - 8) return throwRangeError(realm, "DataView: byte offset out of bounds");
    const u: u64 = @bitCast(i);
    dvWriteEndian(u64, buf, dv.byte_offset + off, u, dvLittleEndian(args, 2));
    return Value.undefined_;
}

// ── TypedArray.prototype.sort + ES2023 immutable variants ────────────────────

/// §23.2.3.30 — default order is numeric (NOT stringified, unlike
/// Array.prototype.sort). Custom comparator is optional. NaN sorts
/// to the end.
fn taCompareNumeric(a: Value, b: Value) i32 {
    // §23.2.3.30 default ordering — numeric comparison, with NaN
    // sorted to the end. BigInt-element TypedArrays (BigInt64 /
    // BigUint64) compare by the underlying i128 value; the Number
    // branch is never reached for them.
    if (heap_mod.valueAsBigInt(a)) |abi| {
        if (heap_mod.valueAsBigInt(b)) |bbi| {
            if (abi.value < bbi.value) return -1;
            if (abi.value > bbi.value) return 1;
            return 0;
        }
    }
    const av: f64 = if (a.isInt32()) @floatFromInt(a.asInt32()) else if (a.isDouble()) a.asDouble() else 0;
    const bv: f64 = if (b.isInt32()) @floatFromInt(b.asInt32()) else if (b.isDouble()) b.asDouble() else 0;
    if (std.math.isNan(av) and std.math.isNan(bv)) return 0;
    if (std.math.isNan(av)) return 1;
    if (std.math.isNan(bv)) return -1;
    if (av < bv) return -1;
    if (av > bv) return 1;
    // §23.2.3.32 SortCompare — when av equals bv but they're
    // not the same number, treat -0 as less than +0. The IEEE
    // `==` collapses both to "equal"; check the sign bit to
    // disambiguate. (Spec wording: "If x is -0𝔽 and y is +0𝔽,
    // return -1. If x is +0𝔽 and y is -0𝔽, return 1.")
    if (av == 0.0 and bv == 0.0) {
        const a_bits: u64 = @bitCast(av);
        const b_bits: u64 = @bitCast(bv);
        const a_neg = (a_bits >> 63) == 1;
        const b_neg = (b_bits >> 63) == 1;
        if (a_neg and !b_neg) return -1;
        if (!a_neg and b_neg) return 1;
    }
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
    //
    // §10.4.5 [[ArrayLength]] — must come from `taCurrentLength`
    // rather than `tv.length`. For a length-tracking view the
    // latter is the construction-time snapshot (typically 0) and
    // lags every subsequent resize; using it would sort only a
    // prefix when the buffer has grown.
    var buf = buf_in;
    const sort_len = taCurrentLength(tv);
    var i: usize = 1;
    while (i < sort_len) : (i += 1) {
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
                        .thrown => |ex| {
                            realm.pending_exception = ex;
                            return error.NativeThrew;
                        },
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
    const tv = try taValidatedView(realm, this_value, "sort");
    const buf = taBufOf(tv) orelse return throwTypeError(realm, "TypedArray detached");
    const cmp_v = argOr(args, 0, Value.undefined_);
    const cmp_fn: ?*JSFunction = if (cmp_v.isUndefined()) null else heap_mod.valueAsFunction(cmp_v) orelse return throwTypeError(realm, "sort comparator must be a function");
    try taSortInPlace(realm, tv, buf, cmp_fn);
    return this_value;
}

fn typedArrayToSorted(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const tv = try taValidatedView(realm, this_value, "toSorted");
    const buf = taBufOf(tv) orelse return throwTypeError(realm, "TypedArray detached");
    const cmp_v = argOr(args, 0, Value.undefined_);
    const cmp_fn: ?*JSFunction = if (cmp_v.isUndefined()) null else heap_mod.valueAsFunction(cmp_v) orelse return throwTypeError(realm, "toSorted comparator must be a function");
    const ts_len = taCurrentLength(tv);
    // §23.2.3.34 toSorted — ignores @@species; allocates default
    // %TypedArray% per [[TypedArrayName]] so Uint8ClampedArray
    // round-trips as itself.
    const out = try taMakeNewNamed(realm, tv.kind, ts_len, tv.name);
    const out_buf = out.typed_view.?.viewed.array_buffer.?;
    const elem_size = tv.kind.elementSize();
    @memcpy(out_buf[0 .. ts_len * elem_size], buf[tv.byte_offset .. tv.byte_offset + ts_len * elem_size]);
    try taSortInPlace(realm, out.typed_view.?, out_buf, cmp_fn);
    return heap_mod.taggedObject(out);
}

fn typedArrayToReversed(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = args;
    const tv = try taValidatedView(realm, this_value, "toReversed");
    const buf = taBufOf(tv) orelse return throwTypeError(realm, "TypedArray detached");
    const tr_len = taCurrentLength(tv);
    // §23.2.3.33 toReversed — ignores @@species; preserve
    // [[TypedArrayName]] so Uint8ClampedArray stays clamped.
    const out = try taMakeNewNamed(realm, tv.kind, tr_len, tv.name);
    const out_buf = out.typed_view.?.viewed.array_buffer.?;
    const elem_size = tv.kind.elementSize();
    var i: usize = 0;
    while (i < tr_len) : (i += 1) {
        const src_off = tv.byte_offset + (tr_len - 1 - i) * elem_size;
        const dst_off = i * elem_size;
        @memcpy(out_buf[dst_off .. dst_off + elem_size], buf[src_off .. src_off + elem_size]);
    }
    return heap_mod.taggedObject(out);
}

fn typedArrayWith(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const bigint_mod = @import("bigint.zig");
    // §23.2.3.39 step 1-2 — ValidateTypedArray(O, seq-cst) and
    // snapshot len. We deliberately re-read length / buffer
    // BELOW after coercions because step 9 (IsValidIntegerIndex)
    // tests against the post-coercion buffer state.
    const tv = try taValidatedView(realm, this_value, "with");
    const initial_len: i64 = @intCast(taCurrentLength(tv));

    const idx_arg = argOr(args, 0, Value.fromInt32(0));
    const value_arg = argOr(args, 1, Value.undefined_);

    // §23.2.3.39 step 4 — ToIntegerOrInfinity(index). Coerce
    // INDEX FIRST so logs.push("index"), logs.push("value")
    // ordering is preserved (see order-of-evaluation.js).
    const idx_num = try intrinsics.toNumber(realm, idx_arg);
    const idx_n: f64 = if (idx_num.isInt32())
        @floatFromInt(idx_num.asInt32())
    else if (idx_num.isDouble())
        idx_num.asDouble()
    else
        0;
    const trunc_n = if (std.math.isNan(idx_n)) 0.0 else @trunc(idx_n);
    const max_i: f64 = @floatFromInt(std.math.maxInt(i64));
    const min_i: f64 = @floatFromInt(std.math.minInt(i64));
    const idx_i: i64 = if (trunc_n >= max_i) std.math.maxInt(i64) else if (trunc_n <= min_i) std.math.minInt(i64) else @intFromFloat(trunc_n);
    // §23.2.3.39 step 5/6 — actualIndex; we'll re-check range
    // against the *post-coercion* len below.
    const actual_index: i64 = if (idx_i < 0) idx_i +| initial_len else idx_i;

    // §23.2.3.39 step 7-8 — coerce VALUE next. ToBigInt for
    // BigInt typed arrays, ToNumber otherwise. Either may throw,
    // and either may run side-effecting valueOf hooks that
    // mutate `O` (early-type-coercion.js) or resize a backing
    // RAB (valid-typedarray-index-checked-after-coercions.js).
    const numeric_value: Value = switch (tv.kind) {
        .bigint64, .biguint64 => bigint_mod.toBigIntValue(realm, value_arg) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.NativeThrew,
        },
        else => try intrinsics.toNumber(realm, value_arg),
    };

    // §23.2.3.39 step 9 — IsValidIntegerIndex against current
    // buffer witness (post-coercion). This is what makes
    // `with(100, throwingValue)` propagate the value-coercion
    // throw rather than RangeError.
    const post_len: i64 = @intCast(taCurrentLength(tv));
    if (actual_index < 0 or actual_index >= post_len) {
        return throwRangeError(realm, "with: index out of range");
    }
    const out_len_us: usize = @intCast(post_len);

    // §23.2.3.39 step 10-11 — TypedArrayCreateSameType, then
    // copy + overwrite. SameType means default ctor for the
    // exemplar's [[TypedArrayName]] — preserve clamped vs unclamped.
    const out = try taMakeNewNamed(realm, tv.kind, out_len_us, tv.name);
    const out_buf = out.typed_view.?.viewed.array_buffer.?;
    const buf_now = taBufOf(tv) orelse return throwTypeError(realm, "TypedArray detached after coercion");
    const elem_size = tv.kind.elementSize();
    const src_byte_len = out_len_us * elem_size;
    // The source view's window may have shrunk during coercion;
    // copy whatever's in bounds and zero-fill the rest (the
    // allocation already zeroed it, so just clamp the memcpy).
    const src_avail: usize = if (buf_now.len > tv.byte_offset) buf_now.len - tv.byte_offset else 0;
    const copy_len = @min(src_byte_len, src_avail);
    if (copy_len > 0) {
        @memcpy(out_buf[0..copy_len], buf_now[tv.byte_offset .. tv.byte_offset + copy_len]);
    }
    // `out` preserves [[TypedArrayName]] via taMakeNewNamed, so
    // a clamped exemplar writes through ToUint8Clamp.
    writeTypedElementForView(out_buf, out.typed_view.?, @as(usize, @intCast(actual_index)) * elem_size, numeric_value);
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

/// §7.1.11 ToUint8Clamp — IEEE 754 round-to-nearest-ties-to-even,
/// then clamp to [0, 255]. NaN → 0. Used only by Uint8ClampedArray.
pub fn toUint8Clamp(d: f64) u8 {
    if (std.math.isNan(d)) return 0;
    if (d <= 0) return 0;
    if (d >= 255) return 255;
    // §7.1.11 — round-half-to-even (banker's rounding).
    const fl = @floor(d);
    const frac = d - fl;
    var rounded: f64 = fl;
    if (frac > 0.5) {
        rounded = fl + 1.0;
    } else if (frac < 0.5) {
        rounded = fl;
    } else {
        // Tie: round to even.
        const fl_u: u64 = @intFromFloat(fl);
        rounded = if (fl_u % 2 == 0) fl else fl + 1.0;
    }
    return @intFromFloat(rounded);
}

/// `writeTypedElement` for a `Uint8ClampedArray`. Cynic shares
/// `kind = .uint8` between Uint8Array and Uint8ClampedArray;
/// regular `writeTypedElement(.uint8, …)` does modular ToUint8.
/// Callers that know they're writing a clamped slot route here
/// instead.
pub fn writeUint8Clamped(buf: []u8, byte_pos: usize, value: Value) void {
    if (byte_pos + 1 > buf.len) return;
    const v = coerceToNumber(value);
    const d: f64 = if (v.isInt32()) @floatFromInt(v.asInt32()) else v.asDouble();
    buf[byte_pos] = toUint8Clamp(d);
}

/// True when this TypedView is a `Uint8ClampedArray`. The kind
/// alone can't tell — clamped shares `kind = .uint8` — so we
/// compare [[TypedArrayName]] (stored on the view).
pub fn isClampedView(tv: ObjMod.TypedView) bool {
    return std.mem.eql(u8, tv.name, "Uint8ClampedArray");
}

/// Dispatch helper: clamped writes go through ToUint8Clamp,
/// every other kind goes through `writeTypedElement`.
pub fn writeTypedElementForView(buf: []u8, tv: ObjMod.TypedView, byte_pos: usize, value: Value) void {
    if (isClampedView(tv)) {
        writeUint8Clamped(buf, byte_pos, value);
    } else {
        writeTypedElement(buf, tv.kind, byte_pos, value);
    }
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
        .float16 => {
            // §10.4.5 Set IntegerIndexedElement / ES2024 Float16Array —
            // ToNumber → round-to-nearest-ties-to-even (IEEE 754
            // binary16). Zig's @floatCast does the right thing.
            const v = coerceToNumber(value);
            const d: f64 = if (v.isInt32()) @floatFromInt(v.asInt32()) else v.asDouble();
            const f: f16 = @floatCast(d);
            const u: u16 = @bitCast(f);
            std.mem.writeInt(u16, buf[byte_pos..][0..2], u, .little);
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
    // §7.1.21 CanonicalNumericIndexString — round-trip via the
    // ECMAScript Number.prototype.toString (§6.1.6.1.20). The
    // shared `formatDoubleSafe` helper produces the JS form
    // (`1e+21` past 10^21, `0.0000001` etc.), which is what the
    // spec compares against. Plain `{d}` would emit a decimal
    // expansion for `1e21` and falsely accept "1000000000000000000000".
    var buf: [64]u8 = undefined;
    const printed = @import("../interpreter.zig").formatDoubleSafe(&buf, n);
    if (!std.mem.eql(u8, printed, s)) return null;
    return n;
}

pub const TypedArrayDefineResult = enum { applied, reject };

/// §10.4.5.3 [[DefineOwnProperty]] for Integer-Indexed Exotic Objects.
/// Caller has already passed `key` through CanonicalNumericIndexString.
/// Per current spec, IsValidIntegerIndex(O, numericIndex) is checked
/// FIRST (rejecting NaN, ±Inf, non-integer, -0, negative, ≥ length,
/// detached buffer). Only on success does step vi run
/// SetTypedArrayElement, which calls ToNumber / ToBigInt with full
/// side-effect observability — a user `valueOf` can throw or detach
/// the buffer mid-flight (the second IsValidIntegerIndex check
/// inside SetTypedArrayElement then silently drops the write).
///
/// Returns `.applied` if the descriptor was accepted (write done or
/// dropped per spec; no further action on the caller's side);
/// `.reject` if the spec says return false (invalid index, non-default
/// descriptor flags, accessor on top of a typed slot).
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
    // §10.4.5.3 step b.i — IsValidIntegerIndex(O, numericIndex).
    // Rejects NaN, ±Infinity, non-integer, -0, negatives, ≥ length,
    // and any index against a detached or OOB-resizable view.
    if (!isValidIntegerIndex(tv, num)) return .reject;
    // §10.4.5.3 steps b.ii-v — descriptor must default to
    // {writable: true, enumerable: true, configurable: true}.
    // Any explicit `false` (or accessor shape) rejects.
    if (is_accessor) return .reject;
    if (has_configurable and !configurable) return .reject;
    if (has_enumerable and !enumerable) return .reject;
    if (has_writable and !writable) return .reject;
    if (has_value) {
        // §10.4.5.3 step b.vi → SetTypedArrayElement(O, idx, value).
        // ToNumber/ToBigInt fires with full observability — a user
        // `valueOf` may throw (caller surfaces as TypeError) or detach
        // the backing buffer. After coercion we re-check
        // IsValidIntegerIndex (spec: SetTypedArrayElement step 4); a
        // detach turns the write into a silent no-op while still
        // returning `.applied` so the caller reports the [[DefineOwnProperty]]
        // result as true.
        const coerced = try coerceForTypedSlot(realm, tv.kind, value);
        const live_tv = obj.typed_view orelse return .applied;
        if (!isValidIntegerIndex(live_tv, num)) return .applied;
        const buf = live_tv.viewed.array_buffer orelse return .applied;
        const elem_size = live_tv.kind.elementSize();
        const idx: usize = @intFromFloat(num);
        writeTypedElement(buf, live_tv.kind, live_tv.byte_offset + idx * elem_size, coerced);
    }
    return .applied;
}

/// Public façade over `isValidIntegerIndex` for callers outside
/// this file (interpreter `delete`, the `[[HasProperty]]` /
/// `[[Get]]` / `[[Set]]` fallthrough sites in `object.zig` /
/// `reflect.zig`). The internal callers stay on the unexported
/// helper.
pub fn isValidIntegerIndexPub(tv: ObjMod.TypedView, num: f64) bool {
    return isValidIntegerIndex(tv, num);
}

/// §10.4.5.13 IsValidIntegerIndex — true iff `num` is a finite
/// non-negative integer that doesn't coincide with `-0`, lies within
/// the current live length of the view, and the backing buffer is
/// still attached and big enough to cover the slot. Floats above
/// the usize range (e.g. `1e21`, an in-spec CanonicalNumericIndex
/// that exceeds any conceivable buffer length) short-circuit to
/// false before the `@intFromFloat` cast — without the guard the
/// safety-checked truncation panics on `integer part of floating
/// point value out of bounds`.
fn isValidIntegerIndex(tv: ObjMod.TypedView, num: f64) bool {
    if (std.math.isNan(num)) return false;
    if (std.math.isInf(num)) return false;
    if (@trunc(num) != num) return false;
    if (num == 0.0 and std.math.signbit(num)) return false;
    if (num < 0) return false;
    if (num >= @as(f64, @floatFromInt(std.math.maxInt(usize)))) return false;
    const buf = tv.viewed.array_buffer orelse return false;
    const elem_size = tv.kind.elementSize();
    const live_len: usize = if (tv.length_tracking) blk: {
        if (tv.byte_offset > buf.len) break :blk 0;
        break :blk (buf.len - tv.byte_offset) / elem_size;
    } else blk: {
        if (tv.byte_offset + tv.length * elem_size > buf.len) break :blk 0;
        break :blk tv.length;
    };
    const idx: usize = @intFromFloat(num);
    if (idx >= live_len) return false;
    if (tv.byte_offset + (idx + 1) * elem_size > buf.len) return false;
    return true;
}

/// §10.4.5.16 SetTypedArrayElement step 1-2 — coerce the inbound
/// JS value to the typed slot's element type. BigInt views run
/// `? ToBigInt(value)` (rejects Number / null / undefined / Symbol);
/// Number views run `? ToNumber(value)` (rejects BigInt / Symbol).
/// Both sides observe user-defined `valueOf` / `Symbol.toPrimitive`
/// hooks, so callers MUST treat this as a side-effecting operation
/// (a user hook can detach the backing buffer mid-coercion).
pub fn coerceForTypedSlot(realm: *Realm, kind: ObjMod.TypedKind, value: Value) NativeError!Value {
    switch (kind) {
        .bigint64, .biguint64 => return try @import("bigint.zig").toBigIntValue(realm, value),
        else => return try @import("../intrinsics.zig").toNumber(realm, value),
    }
}

/// §10.4.5.2 [[GetOwnProperty]] for Integer-Indexed Exotic Objects.
/// Returns the current slot value (caller wraps it in a fresh
/// `{writable, enumerable, configurable}: true` descriptor) or
/// `null` for any key that isn't a valid integer index.
pub fn typedArrayGetOwnPropertyValue(realm: *Realm, obj: *JSObject, num: f64) ?Value {
    const tv = obj.typed_view orelse return null;
    if (!isValidIntegerIndex(tv, num)) return null;
    const buf = tv.viewed.array_buffer orelse return null;
    const elem_size = tv.kind.elementSize();
    const idx: usize = @intFromFloat(num);
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
        .float16 => {
            const u = std.mem.readInt(u16, buf[byte_pos..][0..2], .little);
            const f: f16 = @bitCast(u);
            return Value.fromDouble(@floatCast(f));
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

