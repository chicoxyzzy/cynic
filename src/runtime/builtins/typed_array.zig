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

pub fn install(realm: *Realm) !void {
    // ArrayBuffer constructor.
    {
        const r = try installConstructor(realm, .{
            .name = "ArrayBuffer", .ctor = arrayBufferConstructor, .arity = 1,
            .set_home_object = false,
            .to_string_tag = "ArrayBuffer",
        });
        const proto = r.proto;
        try installNativeGetter(realm, proto, "byteLength", arrayBufferByteLength);
        try installNativeMethodOnProto(realm, proto, "slice", arrayBufferSlice, 2);
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
        try installNativeMethodOnProto(realm, ta_proto, "set", typedArraySet, 2);
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
    const len_v = coerceToNumber(argOr(args, 0, Value.fromInt32(0)));
    const len_d: f64 = if (len_v.isInt32()) @floatFromInt(len_v.asInt32()) else len_v.asDouble();
    if (std.math.isNan(len_d) or len_d < 0 or len_d > @as(f64, @floatFromInt(std.math.maxInt(u32))))
        return throwRangeError(realm, "ArrayBuffer length out of range");
    const len: usize = @intFromFloat(len_d);
    const buf = realm.allocator.alloc(u8, len) catch return error.OutOfMemory;
    @memset(buf, 0);
    inst.array_buffer = buf;
    return this_value;
}

fn arrayBufferByteLength(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = realm;
    _ = args;
    const obj = heap_mod.valueAsPlainObject(this_value) orelse return Value.fromInt32(0);
    if (obj.array_buffer) |ab| return Value.fromInt32(@intCast(ab.len));
    return Value.fromInt32(0);
}

fn arrayBufferSlice(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const src = heap_mod.valueAsPlainObject(this_value) orelse return throwTypeError(realm, "slice on non-ArrayBuffer");
    const buf = src.array_buffer orelse return throwTypeError(realm, "slice on non-ArrayBuffer");
    const total: i64 = @intCast(buf.len);
    var start_d: f64 = 0;
    if (args.len > 0) {
        const v = coerceToNumber(args[0]);
        start_d = if (v.isInt32()) @floatFromInt(v.asInt32()) else v.asDouble();
    }
    var end_d: f64 = @floatFromInt(total);
    if (args.len > 1 and !args[1].isUndefined()) {
        const v = coerceToNumber(args[1]);
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
            if (arg.isInt32() or arg.isDouble() or arg.isUndefined()) {
                // §23.2.5.1.1 — `new TypedArray()` allocates a
                // zero-length view. `coerceToNumber(undefined)`
                // would produce NaN and fall into the RangeError
                // branch; short-circuit here.
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

                inst.typed_view = .{ .kind = kind, .viewed = buf_obj, .byte_offset = 0, .length = length };
                return this_value;
            }

            // ArrayBuffer source.
            if (heap_mod.valueAsPlainObject(arg)) |src| {
                if (src.array_buffer) |ab| {
                    var byte_offset: usize = 0;
                    if (args.len > 1 and !args[1].isUndefined()) {
                        const ov = coerceToNumber(args[1]);
                        const od: f64 = if (ov.isInt32()) @floatFromInt(ov.asInt32()) else ov.asDouble();
                        if (std.math.isNan(od) or od < 0) return throwRangeError(realm, "byteOffset out of range");
                        byte_offset = @intFromFloat(od);
                    }
                    if (byte_offset > ab.len) return throwRangeError(realm, "byteOffset exceeds buffer");
                    if (byte_offset % elem_size != 0) return throwRangeError(realm, "byteOffset not aligned");

                    const remaining = ab.len - byte_offset;
                    var length: usize = remaining / elem_size;
                    if (args.len > 2 and !args[2].isUndefined()) {
                        const lv = coerceToNumber(args[2]);
                        const ld: f64 = if (lv.isInt32()) @floatFromInt(lv.asInt32()) else lv.asDouble();
                        if (std.math.isNan(ld) or ld < 0) return throwRangeError(realm, "length out of range");
                        length = @intFromFloat(ld);
                        if (length * elem_size > remaining) return throwRangeError(realm, "view exceeds buffer");
                    }
                    inst.typed_view = .{ .kind = kind, .viewed = src, .byte_offset = byte_offset, .length = length };
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
    _ = realm;
    const obj = heap_mod.valueAsPlainObject(this_value) orelse return error.NativeThrew;
    const tv = obj.typed_view orelse return error.NativeThrew;
    const buf = tv.viewed.array_buffer orelse return error.NativeThrew;
    const elem_size = tv.kind.elementSize();
    const value = argOr(args, 0, Value.undefined_);
    var i: usize = 0;
    while (i < tv.length) : (i += 1) {
        writeTypedElement(buf, tv.kind, tv.byte_offset + i * elem_size, value);
    }
    return this_value;
}

fn typedArraySet(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const obj = heap_mod.valueAsPlainObject(this_value) orelse return error.NativeThrew;
    const tv = obj.typed_view orelse return error.NativeThrew;
    const buf = tv.viewed.array_buffer orelse return error.NativeThrew;
    const elem_size = tv.kind.elementSize();
    const src = heap_mod.valueAsPlainObject(argOr(args, 0, Value.undefined_)) orelse return error.NativeThrew;
    var offset: usize = 0;
    if (args.len > 1 and !args[1].isUndefined()) {
        const ov = coerceToNumber(args[1]);
        const od: f64 = if (ov.isInt32()) @floatFromInt(ov.asInt32()) else ov.asDouble();
        // Spec §23.2.3.26 step 5: offset = ToIntegerOrInfinity(arg);
        // negative / NaN / non-integer-or-overflow → RangeError.
        if (std.math.isNan(od) or od < 0 or od > @as(f64, @floatFromInt(std.math.maxInt(usize)))) {
            return throwRangeError(realm, "TypedArray.prototype.set: offset out of range");
        }
        offset = @intFromFloat(@trunc(od));
    }
    // §23.2.3.26 SetTypedArrayFromTypedArray — fast path when the
    // source is itself a typed view: copy via the same byte
    // representation when kinds match, else read/write through the
    // numeric conversion.
    if (src.typed_view) |src_tv| {
        if (src_tv.viewed.array_buffer) |src_buf| {
            // §23.2.3.26 step 19 / SetTypedArrayFromTypedArray —
            // RangeError when the source overflows the destination.
            if (offset > tv.length or src_tv.length > tv.length - offset) {
                return throwRangeError(realm, "TypedArray.prototype.set: source overflows destination");
            }
            const src_size = src_tv.kind.elementSize();
            var i: usize = 0;
            while (i < src_tv.length) : (i += 1) {
                const v = readTypedElement(realm, src_buf, src_tv.kind, src_tv.byte_offset + i * src_size);
                writeTypedElement(buf, tv.kind, tv.byte_offset + (offset + i) * elem_size, v);
            }
            return Value.undefined_;
        }
    }
    const len_v = src.get("length");
    const len: usize = if (len_v.isInt32()) @intCast(len_v.asInt32()) else if (len_v.isDouble()) @intFromFloat(len_v.asDouble()) else 0;
    if (offset > tv.length or len > tv.length - offset) {
        return throwRangeError(realm, "TypedArray.prototype.set: source overflows destination");
    }
    var i: usize = 0;
    while (i < len) : (i += 1) {
        var ibuf: [16]u8 = undefined;
        const s = std.fmt.bufPrint(&ibuf, "{d}", .{i}) catch unreachable;
        writeTypedElement(buf, tv.kind, tv.byte_offset + (offset + i) * elem_size, src.get(s));
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

/// Resolve a §7.1.5 ToIntegerOrInfinity-style index relative to
/// `length`, with the standard negative-from-end + clamp-to-bounds
/// rules. Used by `slice` / `subarray` / `copyWithin` / `fill`.
fn taResolveIndex(arg: Value, length: i64, default_val: i64) i64 {
    if (arg.isUndefined()) return default_val;
    const v = coerceToNumber(arg);
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
    inst.typed_view = .{ .kind = kind, .viewed = buf_obj, .byte_offset = 0, .length = length };
    return inst;
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

/// Common shape for callback-driven methods: pull tv + buf + the
/// mandatory function callback + optional thisArg.
fn taCallbackPreamble(realm: *Realm, this_value: Value, args: []const Value) NativeError!struct {
    tv: ObjMod.TypedView,
    buf: []u8,
    callback: *JSFunction,
    this_arg: Value,
    self_obj: *JSObject,
} {
    const obj = heap_mod.valueAsPlainObject(this_value) orelse return throwTypeError(realm, "TypedArray method on non-object");
    const tv = obj.typed_view orelse return throwTypeError(realm, "TypedArray method on non-TypedArray");
    const buf = tv.viewed.array_buffer orelse return throwTypeError(realm, "TypedArray detached");
    const callback = heap_mod.valueAsFunction(argOr(args, 0, Value.undefined_)) orelse return throwTypeError(realm, "callback is not a function");
    const this_arg = argOr(args, 1, Value.undefined_);
    return .{ .tv = tv, .buf = buf, .callback = callback, .this_arg = this_arg, .self_obj = obj };
}

fn typedArrayAt(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const tv = taViewOf(this_value) orelse return throwTypeError(realm, "at on non-TypedArray");
    const buf = taBufOf(tv) orelse return throwTypeError(realm, "TypedArray detached");
    const len: i64 = @intCast(tv.length);
    const i = taResolveIndex(argOr(args, 0, Value.fromInt32(0)), len, 0);
    // `at` returns undefined for out-of-range; resolveIndex clamps,
    // so we re-check using the raw arg to detect "explicitly out of
    // range" vs "negative index in range."
    const raw = argOr(args, 0, Value.fromInt32(0));
    const raw_n: f64 = if (raw.isInt32()) @floatFromInt(raw.asInt32()) else if (raw.isDouble()) raw.asDouble() else 0;
    const raw_i: i64 = if (std.math.isNan(raw_n)) 0 else @intFromFloat(@trunc(raw_n));
    const target_i: i64 = if (raw_i < 0) raw_i + len else raw_i;
    if (target_i < 0 or target_i >= len) return Value.undefined_;
    _ = i;
    return readTypedElement(realm, buf, tv.kind, tv.byte_offset + @as(usize, @intCast(target_i)) * tv.kind.elementSize());
}

fn typedArrayCopyWithin(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = realm;
    const obj = heap_mod.valueAsPlainObject(this_value) orelse return error.NativeThrew;
    const tv = obj.typed_view orelse return error.NativeThrew;
    const buf = tv.viewed.array_buffer orelse return error.NativeThrew;
    const len: i64 = @intCast(tv.length);
    const target = taResolveIndex(argOr(args, 0, Value.fromInt32(0)), len, 0);
    const start = taResolveIndex(argOr(args, 1, Value.fromInt32(0)), len, 0);
    const end = taResolveIndex(argOr(args, 2, Value.undefined_), len, len);
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
    const elem_size = ctx.tv.kind.elementSize();
    var i: usize = 0;
    while (i < ctx.tv.length) : (i += 1) {
        const v = readTypedElement(realm, ctx.buf, ctx.tv.kind, ctx.tv.byte_offset + i * elem_size);
        _ = try invokeCallback(realm, ctx.callback, ctx.this_arg, v, @intCast(i), ctx.self_obj);
    }
    return Value.undefined_;
}

fn typedArrayEvery(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const ctx = try taCallbackPreamble(realm, this_value, args);
    const elem_size = ctx.tv.kind.elementSize();
    var i: usize = 0;
    while (i < ctx.tv.length) : (i += 1) {
        const v = readTypedElement(realm, ctx.buf, ctx.tv.kind, ctx.tv.byte_offset + i * elem_size);
        const r = try invokeCallback(realm, ctx.callback, ctx.this_arg, v, @intCast(i), ctx.self_obj);
        if (!toBoolean(r)) return Value.false_;
    }
    return Value.true_;
}

fn typedArraySome(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const ctx = try taCallbackPreamble(realm, this_value, args);
    const elem_size = ctx.tv.kind.elementSize();
    var i: usize = 0;
    while (i < ctx.tv.length) : (i += 1) {
        const v = readTypedElement(realm, ctx.buf, ctx.tv.kind, ctx.tv.byte_offset + i * elem_size);
        const r = try invokeCallback(realm, ctx.callback, ctx.this_arg, v, @intCast(i), ctx.self_obj);
        if (toBoolean(r)) return Value.true_;
    }
    return Value.false_;
}

fn typedArrayFind(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const ctx = try taCallbackPreamble(realm, this_value, args);
    const elem_size = ctx.tv.kind.elementSize();
    var i: usize = 0;
    while (i < ctx.tv.length) : (i += 1) {
        const v = readTypedElement(realm, ctx.buf, ctx.tv.kind, ctx.tv.byte_offset + i * elem_size);
        const r = try invokeCallback(realm, ctx.callback, ctx.this_arg, v, @intCast(i), ctx.self_obj);
        if (toBoolean(r)) return v;
    }
    return Value.undefined_;
}

fn typedArrayFindIndex(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const ctx = try taCallbackPreamble(realm, this_value, args);
    const elem_size = ctx.tv.kind.elementSize();
    var i: usize = 0;
    while (i < ctx.tv.length) : (i += 1) {
        const v = readTypedElement(realm, ctx.buf, ctx.tv.kind, ctx.tv.byte_offset + i * elem_size);
        const r = try invokeCallback(realm, ctx.callback, ctx.this_arg, v, @intCast(i), ctx.self_obj);
        if (toBoolean(r)) return numberFromI64(@intCast(i));
    }
    return Value.fromInt32(-1);
}

fn typedArrayFindLast(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const ctx = try taCallbackPreamble(realm, this_value, args);
    const elem_size = ctx.tv.kind.elementSize();
    var i: i64 = @as(i64, @intCast(ctx.tv.length)) - 1;
    while (i >= 0) : (i -= 1) {
        const v = readTypedElement(realm, ctx.buf, ctx.tv.kind, ctx.tv.byte_offset + @as(usize, @intCast(i)) * elem_size);
        const r = try invokeCallback(realm, ctx.callback, ctx.this_arg, v, i, ctx.self_obj);
        if (toBoolean(r)) return v;
    }
    return Value.undefined_;
}

fn typedArrayFindLastIndex(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const ctx = try taCallbackPreamble(realm, this_value, args);
    const elem_size = ctx.tv.kind.elementSize();
    var i: i64 = @as(i64, @intCast(ctx.tv.length)) - 1;
    while (i >= 0) : (i -= 1) {
        const v = readTypedElement(realm, ctx.buf, ctx.tv.kind, ctx.tv.byte_offset + @as(usize, @intCast(i)) * elem_size);
        const r = try invokeCallback(realm, ctx.callback, ctx.this_arg, v, i, ctx.self_obj);
        if (toBoolean(r)) return numberFromI64(i);
    }
    return Value.fromInt32(-1);
}

fn typedArrayIncludes(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const tv = taViewOf(this_value) orelse return throwTypeError(realm, "includes on non-TypedArray");
    const buf = taBufOf(tv) orelse return throwTypeError(realm, "TypedArray detached");
    const target = argOr(args, 0, Value.undefined_);
    const len: i64 = @intCast(tv.length);
    const from_arg = argOr(args, 1, Value.fromInt32(0));
    var from = taResolveIndex(from_arg, len, 0);
    if (from < 0) from = 0;
    const elem_size = tv.kind.elementSize();
    var i: i64 = from;
    while (i < len) : (i += 1) {
        const v = readTypedElement(realm, buf, tv.kind, tv.byte_offset + @as(usize, @intCast(i)) * elem_size);
        if (sameValueZero(v, target)) return Value.true_;
    }
    return Value.false_;
}

fn typedArrayIndexOf(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const tv = taViewOf(this_value) orelse return throwTypeError(realm, "indexOf on non-TypedArray");
    const buf = taBufOf(tv) orelse return throwTypeError(realm, "TypedArray detached");
    const target = argOr(args, 0, Value.undefined_);
    const len: i64 = @intCast(tv.length);
    var from = taResolveIndex(argOr(args, 1, Value.fromInt32(0)), len, 0);
    if (from < 0) from = 0;
    const elem_size = tv.kind.elementSize();
    var i: i64 = from;
    while (i < len) : (i += 1) {
        const v = readTypedElement(realm, buf, tv.kind, tv.byte_offset + @as(usize, @intCast(i)) * elem_size);
        if (strictEqualsLite(v, target)) return numberFromI64(i);
    }
    return Value.fromInt32(-1);
}

fn typedArrayLastIndexOf(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const tv = taViewOf(this_value) orelse return throwTypeError(realm, "lastIndexOf on non-TypedArray");
    const buf = taBufOf(tv) orelse return throwTypeError(realm, "TypedArray detached");
    const target = argOr(args, 0, Value.undefined_);
    const len: i64 = @intCast(tv.length);
    var from: i64 = len - 1;
    if (args.len > 1 and !args[1].isUndefined()) {
        from = taResolveIndex(args[1], len, len - 1);
        if (from >= len) from = len - 1;
    }
    const elem_size = tv.kind.elementSize();
    var i: i64 = from;
    while (i >= 0) : (i -= 1) {
        const v = readTypedElement(realm, buf, tv.kind, tv.byte_offset + @as(usize, @intCast(i)) * elem_size);
        if (strictEqualsLite(v, target)) return numberFromI64(i);
    }
    return Value.fromInt32(-1);
}

fn typedArrayJoin(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const tv = taViewOf(this_value) orelse return throwTypeError(realm, "join on non-TypedArray");
    const buf = taBufOf(tv) orelse return throwTypeError(realm, "TypedArray detached");
    const sep_v = argOr(args, 0, Value.undefined_);
    const sep_s: []const u8 = if (sep_v.isUndefined()) "," else blk: {
        const s = stringifyArg(realm, sep_v) catch return error.OutOfMemory;
        break :blk s.bytes;
    };
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(realm.allocator);
    const elem_size = tv.kind.elementSize();
    var i: usize = 0;
    while (i < tv.length) : (i += 1) {
        if (i > 0) out.appendSlice(realm.allocator, sep_s) catch return error.OutOfMemory;
        const v = readTypedElement(realm, buf, tv.kind, tv.byte_offset + i * elem_size);
        const s = stringifyArg(realm, v) catch return error.OutOfMemory;
        out.appendSlice(realm.allocator, s.bytes) catch return error.OutOfMemory;
    }
    const result = realm.heap.allocateString(out.items) catch return error.OutOfMemory;
    return Value.fromString(result);
}

fn typedArrayToString(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = args;
    return typedArrayJoin(realm, this_value, &.{});
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
    const tv = taViewOf(this_value) orelse return throwTypeError(realm, "slice on non-TypedArray");
    const buf = taBufOf(tv) orelse return throwTypeError(realm, "TypedArray detached");
    const len: i64 = @intCast(tv.length);
    const start = taResolveIndex(argOr(args, 0, Value.fromInt32(0)), len, 0);
    const end = taResolveIndex(argOr(args, 1, Value.undefined_), len, len);
    const new_len: usize = if (end > start) @intCast(end - start) else 0;
    const out = try taMakeNew(realm, tv.kind, new_len);
    if (new_len > 0) {
        const elem_size = tv.kind.elementSize();
        const out_buf = out.typed_view.?.viewed.array_buffer.?;
        const src_off = tv.byte_offset + @as(usize, @intCast(start)) * elem_size;
        @memcpy(out_buf[0 .. new_len * elem_size], buf[src_off .. src_off + new_len * elem_size]);
    }
    return heap_mod.taggedObject(out);
}

fn typedArraySubarray(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const tv = taViewOf(this_value) orelse return throwTypeError(realm, "subarray on non-TypedArray");
    const len: i64 = @intCast(tv.length);
    const begin = taResolveIndex(argOr(args, 0, Value.fromInt32(0)), len, 0);
    const end = taResolveIndex(argOr(args, 1, Value.undefined_), len, len);
    const new_len: usize = if (end > begin) @intCast(end - begin) else 0;
    // Subarray VIEWS the same buffer rather than copying. Allocate
    // a fresh wrapper and reuse the existing ArrayBuffer.
    const ctor_name = nameForTypedKind(tv.kind);
    const ctor = heap_mod.valueAsFunction(realm.globals.get(ctor_name) orelse Value.undefined_) orelse return throwTypeError(realm, "TypedArray constructor not found");
    const inst = realm.heap.allocateObject() catch return error.OutOfMemory;
    inst.prototype = ctor.prototype;
    const elem_size = tv.kind.elementSize();
    inst.typed_view = .{
        .kind = tv.kind,
        .viewed = tv.viewed,
        .byte_offset = tv.byte_offset + @as(usize, @intCast(begin)) * elem_size,
        .length = new_len,
    };
    return heap_mod.taggedObject(inst);
}

fn typedArrayMap(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const ctx = try taCallbackPreamble(realm, this_value, args);
    const elem_size = ctx.tv.kind.elementSize();
    const out = try taMakeNew(realm, ctx.tv.kind, ctx.tv.length);
    const out_buf = out.typed_view.?.viewed.array_buffer.?;
    var i: usize = 0;
    while (i < ctx.tv.length) : (i += 1) {
        const v = readTypedElement(realm, ctx.buf, ctx.tv.kind, ctx.tv.byte_offset + i * elem_size);
        const mapped = try invokeCallback(realm, ctx.callback, ctx.this_arg, v, @intCast(i), ctx.self_obj);
        writeTypedElement(out_buf, ctx.tv.kind, i * elem_size, mapped);
    }
    return heap_mod.taggedObject(out);
}

fn typedArrayFilter(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const ctx = try taCallbackPreamble(realm, this_value, args);
    const elem_size = ctx.tv.kind.elementSize();
    // Two-pass: first decide which elements are kept (record into
    // a temp byte array), then allocate the result with the exact
    // size and copy. Avoids two reallocations for the common case
    // where most pass.
    var kept: std.ArrayListUnmanaged(usize) = .empty;
    defer kept.deinit(realm.allocator);
    var i: usize = 0;
    while (i < ctx.tv.length) : (i += 1) {
        const v = readTypedElement(realm, ctx.buf, ctx.tv.kind, ctx.tv.byte_offset + i * elem_size);
        const r = try invokeCallback(realm, ctx.callback, ctx.this_arg, v, @intCast(i), ctx.self_obj);
        if (toBoolean(r)) kept.append(realm.allocator, i) catch return error.OutOfMemory;
    }
    const out = try taMakeNew(realm, ctx.tv.kind, kept.items.len);
    const out_buf = out.typed_view.?.viewed.array_buffer.?;
    for (kept.items, 0..) |src_i, dst_i| {
        const src_off = ctx.tv.byte_offset + src_i * elem_size;
        const dst_off = dst_i * elem_size;
        @memcpy(out_buf[dst_off .. dst_off + elem_size], ctx.buf[src_off .. src_off + elem_size]);
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

fn taSortInPlace(realm: *Realm, tv: ObjMod.TypedView, buf: []u8, comparator: ?*JSFunction) NativeError!void {
    const elem_size = tv.kind.elementSize();
    // Simple insertion sort — TypedArray sort doesn't need to be
    // O(n log n) for the corpus, and avoiding the allocator
    // keeps it simple. M5+ can swap in a quicksort if it matters.
    var i: usize = 1;
    while (i < tv.length) : (i += 1) {
        const cur = readTypedElement(realm, buf, tv.kind, tv.byte_offset + i * elem_size);
        var j: i64 = @as(i64, @intCast(i)) - 1;
        while (j >= 0) : (j -= 1) {
            const prev = readTypedElement(realm, buf, tv.kind, tv.byte_offset + @as(usize, @intCast(j)) * elem_size);
            const cmp: i32 = blk: {
                if (comparator) |cf| {
                    const interpreter = @import("../interpreter.zig");
                    const cb_args = [_]Value{ prev, cur };
                    const outcome = interpreter.callJSFunction(realm.allocator, realm, cf, Value.undefined_, &cb_args) catch return error.NativeThrew;
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
            // shift prev forward into j+1
            const a_off = tv.byte_offset + @as(usize, @intCast(j)) * elem_size;
            const b_off = tv.byte_offset + (@as(usize, @intCast(j)) + 1) * elem_size;
            @memcpy(buf[b_off .. b_off + elem_size], buf[a_off .. a_off + elem_size]);
        }
        // place cur at j+1
        const place: usize = @intCast(j + 1);
        writeTypedElement(buf, tv.kind, tv.byte_offset + place * elem_size, cur);
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
    const idx_n: f64 = if (idx_arg.isInt32()) @floatFromInt(idx_arg.asInt32()) else if (idx_arg.isDouble()) idx_arg.asDouble() else 0;
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

pub fn readTypedElement(realm: *Realm, buf: []const u8, kind: ObjMod.TypedKind, byte_pos: usize) Value {
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

