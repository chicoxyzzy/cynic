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
        // §22.1.3 — %Array.prototype% is itself an Array exotic
        // object. `Array.prototype[2] = 42` must auto-extend
        // length to 3, and indexed reads must come from the
        // packed elements vector.
        try arr_proto.markAsArrayExotic(realm.allocator);
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
        try installNativeMethodOnProto(realm, arr_proto, "toLocaleString", arrayToLocaleString, 0);
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
        // §23.1.3.{32-35} — ES2023 change-array-by-copy. Each
        // method allocates a fresh array, applies the mutating
        // operation to the copy, and leaves the receiver
        // untouched.
        try installNativeMethodOnProto(realm, arr_proto, "toSorted", arrayToSorted, 1);
        try installNativeMethodOnProto(realm, arr_proto, "toReversed", arrayToReversed, 0);
        try installNativeMethodOnProto(realm, arr_proto, "toSpliced", arrayToSpliced, 2);
        try installNativeMethodOnProto(realm, arr_proto, "with", arrayWith, 2);
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
        try installNativeMethod(realm, arr_ctor, "fromAsync", arrayFromAsync, 1);
        // §22.1.2.5 get Array [ @@species ] returns this.
        const species_getter = try realm.heap.allocateFunctionNative(arraySpeciesGetter, 0, "[Symbol.species]");
        species_getter.proto = realm.intrinsics.function_prototype;
        const entry = try arr_ctor.accessors.getOrPut(realm.allocator, "@@species");
        entry.value_ptr.* = .{ .getter = species_getter };
        try arr_ctor.property_flags.put(realm.allocator, "@@species", .{
            .writable = false, .enumerable = false, .configurable = true,
        });
    }
}

fn arraySpeciesGetter(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = realm;
    _ = args;
    return this_value;
}

/// §10.1.8 [[Get]] applied to a function object — invokes an
/// own accessor's getter if present, otherwise walks the function's
/// data-property + proto chain. Used by ArraySpeciesCreate to read
/// `@@species` off a constructor function where the species slot
/// is a get-only accessor (e.g. the built-in `Array[@@species]`).
fn getFunctionMember(realm: *Realm, fn_obj: *JSFunction, key: []const u8) NativeError!Value {
    if (fn_obj.accessors.get(key)) |acc| {
        if (acc.getter) |getter| {
            const outcome = interpreter.callJSFunction(realm.allocator, realm, getter, heap_mod.taggedFunction(fn_obj), &[_]Value{}) catch |err| switch (err) {
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
    return fn_obj.get(key);
}

/// §23.1.3.34 ArraySpeciesCreate(originalArray, length).
/// 1. isArray = IsArray(originalArray)
/// 2. If !isArray, return ! ArrayCreate(length).
/// 3. C = ? Get(originalArray, "constructor")
/// 4. If IsConstructor(C):
///    a. If GetFunctionRealm(C) is different from current realm AND
///       C === currentRealm.%Array%, set C to undefined.
/// 5. If C is Object, C = ? Get(C, @@species); if C is null,
///    set C to undefined.
/// 6. If C is undefined, return ! ArrayCreate(length).
/// 7. If !IsConstructor(C), throw TypeError.
/// 8. Return ? Construct(C, « 𝔽(length) »).
///
/// Returns the freshly created array-shaped object.
pub fn arraySpeciesCreate(realm: *Realm, original: *JSObject, length: i64) NativeError!Value {
    // Fast path — non-array original. Step 2: if isArray is false,
    // return ArrayCreate(length).
    if (!original.is_array_exotic) return defaultArrayCreate(realm, length);
    // Step 3 — Get(originalArray, "constructor"). Use the full
    // accessor-aware path so a poisoned getter propagates per spec.
    const ctor_v = try intrinsics.getPropertyChain(realm, original, "constructor");
    // Step 4 — if IsConstructor(C) true and cross-realm %Array%, set
    // to undefined. Cynic is single-realm by default, so the
    // cross-realm carve-out is currently a no-op.
    // Step 5 — if C is an Object, set C to ? Get(C, @@species); if
    // null, set C to undefined.
    var c_v: Value = ctor_v;
    if (heap_mod.valueAsFunction(ctor_v)) |ctor_fn| {
        c_v = try getFunctionMember(realm, ctor_fn, "@@species");
        if (c_v.isNull()) c_v = Value.undefined_;
    } else if (heap_mod.valueAsPlainObject(ctor_v)) |ctor_obj| {
        c_v = try intrinsics.getPropertyChain(realm, ctor_obj, "@@species");
        if (c_v.isNull()) c_v = Value.undefined_;
    }
    // Step 6 — if C is undefined, return ArrayCreate(length).
    if (c_v.isUndefined()) return defaultArrayCreate(realm, length);
    // Step 7 — if IsConstructor(C) is false, throw a TypeError. A
    // primitive constructor (e.g. `a.constructor = null` or `= 1`)
    // lands here; so does an object/function without [[Construct]].
    const species_v = c_v;
    const species_fn = heap_mod.valueAsFunction(species_v) orelse {
        return throwTypeError(realm, "Array species is not a constructor");
    };
    if (!species_fn.has_construct or species_fn.is_arrow) {
        return throwTypeError(realm, "Array species is not a constructor");
    }
    // Fast path: species === %Array% (the spec's default). Skip the
    // call and allocate directly.
    if (realm.globals.get("Array")) |array_global| {
        if (heap_mod.valueAsFunction(array_global)) |array_ctor| {
            if (array_ctor == species_fn) return defaultArrayCreate(realm, length);
        }
    }
    // Construct(species, [length]) — go through the public path so a
    // user-defined ctor sees `new.target = species`.
    const ctor_args = [_]Value{numberFromI64(length)};
    const result = interpreter.constructValue(realm.allocator, realm, heap_mod.taggedFunction(species_fn), &ctor_args, heap_mod.taggedFunction(species_fn)) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.NativeThrew,
    };
    switch (result) {
        .value, .yielded => |v| return v,
        .thrown => |ex| {
            realm.pending_exception = ex;
            return error.NativeThrew;
        },
    }
}

fn defaultArrayCreate(realm: *Realm, length: i64) NativeError!Value {
    // §10.4.2.2 ArrayCreate step 3 — `length > 2^32 - 1` throws
    // RangeError. Splice / slice / etc. forward `actualDeleteCount`
    // computed from an i64 length and ToInteger'd args, so a
    // proxy reporting length=2^32 or larger triggers this gate.
    if (length < 0 or length > 0xFFFFFFFF) {
        return throwRangeError(realm, "Invalid array length");
    }
    const out = realm.heap.allocateObject() catch return error.OutOfMemory;
    out.prototype = realm.intrinsics.array_prototype;
    out.markAsArrayExotic(realm.allocator) catch return error.OutOfMemory;
    if (length > 0) setLength(realm, out, length) catch return error.OutOfMemory;
    return heap_mod.taggedObject(out);
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
    // `new Array(...)` arrives with `this` already allocated by
    // OrdinaryCreateFromConstructor — it inherits Array.prototype
    // but doesn't carry our exotic flag, so flag it here. Plain-call
    // path needs the same flip; doing it unconditionally is cheap.
    if (!out.is_array_exotic) out.markAsArrayExotic(realm.allocator) catch return error.OutOfMemory;

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
        // §22.1.1.2 — `Array(N)` allocates an array with length
        // N and N holes. The packed representation pre-grows
        // `elements` to N hole sentinels so subsequent indexed
        // writes leave length at N (only writes at idx >= len
        // bump length).
        out.setArrayLength(realm.allocator, len) catch return error.OutOfMemory;
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
    // §23.1.3.18 Array.prototype.push:
    //   1. O = ToObject(this)
    //   2. len = ? ToLength(? Get(O, "length"))
    //   3. argCount = items.length
    //   4. If len + argCount > 2^53-1, throw TypeError
    //   5. For each E of items: ? Set(O, ToString(len), E, true); len += 1
    //   6. ? Set(O, "length", F(len), true)
    //   7. Return F(len)
    const obj = try toObjectThis(realm, this_value);
    var len = try toLengthOf(realm, obj);
    // §7.1.20 ToLength caps at 2^53 - 1 (`min(len, 2^53 - 1)`).
    // toLengthOf's saturating helper bottoms out at maxInt(i64);
    // re-clamp here so the overflow check is against the spec
    // safe-integer ceiling, not the i64 cap.
    const safe_max: i64 = (1 << 53) - 1;
    if (len > safe_max) len = safe_max;
    const argc: i64 = @intCast(args.len);
    // §23.1.3.18 step 4 — `len + argCount > 2^53 - 1` throws.
    if (argc > 0 and len > safe_max - argc) {
        return throwTypeError(realm, "Pushed value would exceed maximum length");
    }
    for (args) |v| {
        var ibuf: [24]u8 = undefined;
        const islice = std.fmt.bufPrint(&ibuf, "{d}", .{len}) catch unreachable;
        // Anchor the key — `setOrThrow` may land it in the
        // property bag if the receiver isn't an Array exotic.
        const owned = realm.heap.allocateString(islice) catch return error.OutOfMemory;
        try setOrThrow(realm, obj, owned.bytes, v);
        len += 1;
    }
    try setLengthOrThrow(realm, obj, len);
    return numberFromI64(len);
}

fn arrayPop(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    // §23.1.3.17 Array.prototype.pop:
    //   1. O = ToObject(this)
    //   2. len = ? ToLength(? Get(O, "length"))
    //   3. If len = 0:
    //        ? Set(O, "length", 0, true); return undefined
    //   4. Else:
    //        newLen = len - 1
    //        index = ToString(newLen)
    //        element = ? Get(O, index)
    //        ? DeletePropertyOrThrow(O, index)
    //        ? Set(O, "length", newLen, true); return element
    _ = args;
    const obj = try toObjectThis(realm, this_value);
    var len = try toLengthOf(realm, obj);
    if (len <= 0) {
        try setLengthOrThrow(realm, obj, 0);
        return Value.undefined_;
    }
    len -= 1;
    var ibuf: [24]u8 = undefined;
    const islice = std.fmt.bufPrint(&ibuf, "{d}", .{len}) catch unreachable;
    const v = try getPropertyChain(realm, obj, islice);
    try deletePropertyOrThrow(realm, obj, islice);
    try setLengthOrThrow(realm, obj, len);
    return v;
}

/// Store a length on an array-shaped object. Length values that
/// overflow `i32` get stored as a `Value.fromDouble` instead —
/// matches §6.1.6.1 NumberValue (length is a Number, not int32).
pub fn setLength(realm: *Realm, obj: *JSObject, len: i64) !void {
    // §10.4.2.4 ArraySetLength — for Array exotics this also
    // truncates / grows the packed `elements` vector.
    const clamped: u32 = if (len < 0) 0 else if (len > 0xFFFFFFFE) 0xFFFFFFFE else @intCast(len);
    try obj.setArrayLength(realm.allocator, clamped);
}

pub fn numberFromI64(n: i64) Value {
    if (n >= std.math.minInt(i32) and n <= std.math.maxInt(i32)) {
        return Value.fromInt32(@intCast(n));
    }
    return Value.fromDouble(@floatFromInt(n));
}

/// §7.3.4 Set ( O, P, V, Throw ) — spec-faithful property write
/// for native Array.prototype.* methods. Mirrors the interpreter's
/// strictSetProperty path: invokes inherited accessor setters,
/// honors `writable: false` / `extensible: false` with a thrown
/// TypeError, runs ArraySetLength for length writes, and gates
/// indexed writes against non-writable `length`.
///
/// Returns normally on success. Returns `error.NativeThrew` with
/// `realm.pending_exception` populated when the spec mandates a
/// TypeError (writability gate, integrity-level violation, getter-
/// only accessor). The setter itself can throw — that exception
/// also propagates through `error.NativeThrew`.
pub fn setOrThrow(realm: *Realm, obj: *JSObject, key: []const u8, value: Value) NativeError!void {
    // §10.1.9.1 OrdinarySet — walk the prototype chain for an
    // accessor setter; own data on the way shadows the inherited
    // accessor (`lookupAccessor` handles that contract).
    if (interpreter.lookupAccessor(obj, key)) |acc_pair| {
        if (acc_pair.setter) |setter| {
            const args = [_]Value{value};
            const outcome = interpreter.callJSFunction(realm.allocator, realm, setter, heap_mod.taggedObject(obj), &args) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return error.NativeThrew,
            };
            switch (outcome) {
                .value, .yielded => return,
                .thrown => |ex| {
                    realm.pending_exception = ex;
                    return error.NativeThrew;
                },
            }
        }
        // Getter-only accessor — strict-mode write throws.
        return throwTypeError(realm, "Cannot set property which has only a getter");
    }
    // §10.4.2.4 ArraySetLength — write to `length` on an Array
    // exotic (or anything in the array-prototype chain) coerces
    // to u32, throws RangeError on invalid value, and truncates
    // descending indexed slots. Non-writable length blocks.
    if (std.mem.eql(u8, key, "length") and obj.is_array_exotic) {
        if (obj.property_flags.get("length")) |flags| {
            if (!flags.writable) {
                return throwTypeError(realm, "Cannot assign to read-only property 'length'");
            }
        }
        const new_len = interpreter.arrayLengthCoerce(value) orelse {
            return throwRangeError(realm, "Invalid array length");
        };
        const tr = interpreter.truncateArrayAtLength(realm.allocator, obj, new_len);
        obj.setArrayLength(realm.allocator, tr.final_length) catch return error.OutOfMemory;
        if (tr.blocked) {
            return throwTypeError(realm, "Cannot delete non-configurable array index");
        }
        return;
    }
    // §10.4.2.1 [[DefineOwnProperty]] — Array exotic indexed
    // writes go through `setIndexed`. Auto-extend length-gate
    // applies when `length: {writable:false}`.
    if (obj.is_array_exotic) {
        if (JSObject.canonicalIntegerIndex(key)) |idx| {
            if (!obj.properties.contains(key)) {
                if (obj.property_flags.get("length")) |flags| {
                    if (!flags.writable) {
                        const cur_len_v = obj.properties.get("length") orelse Value.fromInt32(0);
                        const cur_len: u32 = if (cur_len_v.isInt32()) @intCast(@max(0, cur_len_v.asInt32())) else 0;
                        if (idx >= cur_len) {
                            return throwTypeError(realm, "Cannot extend non-writable array length");
                        }
                    }
                }
                obj.setIndexed(realm.allocator, idx, value) catch return error.OutOfMemory;
                return;
            }
        }
    }
    // §10.1.9.2 OrdinarySetWithOwnDescriptor — own data wins; if
    // absent, [[DefineOwnProperty]] fails (and so strict-mode
    // [[Set]] throws TypeError) when the receiver is non-extensible.
    const had_entry = obj.properties.contains(key);
    if (had_entry) {
        const flags = obj.flagsFor(key);
        if (!flags.writable) {
            return throwTypeError(realm, "Cannot assign to read-only property");
        }
        // §6.1.6.1 NumberValue — length is a Number; preserve the
        // value bit-pattern (don't down-cast a double to int32).
        obj.properties.put(realm.allocator, key, value) catch return error.OutOfMemory;
        return;
    }
    if (!obj.extensible) {
        return throwTypeError(realm, "Cannot add property, object is not extensible");
    }
    obj.set(realm.allocator, key, value) catch return error.OutOfMemory;
}

/// Spec-faithful `Set(O, "length", F(len), true)` — routes
/// through `setOrThrow` so a non-writable `length`, an accessor
/// setter, or an array-exotic `length` write get the same
/// treatment as user JS `O.length = …`. Used by `push` / `pop`
/// / `unshift` / `splice` etc. instead of the bypass `setLength`.
pub fn setLengthOrThrow(realm: *Realm, obj: *JSObject, len: i64) NativeError!void {
    // §6.1.6.1 NumberValue — `length` is a Number. The push/pop
    // family deal in i64 (so the 2^53-1 overflow check has the
    // headroom it needs); convert back to Value here so a length
    // beyond i32 range lands as a double.
    const lv: Value = if (len >= std.math.minInt(i32) and len <= std.math.maxInt(i32))
        Value.fromInt32(@intCast(len))
    else
        Value.fromDouble(@floatFromInt(len));
    try setOrThrow(realm, obj, "length", lv);
}

/// §7.3.5 DeletePropertyOrThrow — Strict-mode delete that throws
/// TypeError if the [[Delete]] returns false. Used by push / pop /
/// shift / unshift / splice to drop indices.
pub fn deletePropertyOrThrow(realm: *Realm, obj: *JSObject, key: []const u8) NativeError!void {
    if (!obj.deleteOwn(key)) {
        return throwTypeError(realm, "Cannot delete property");
    }
}

fn arrayIndexOf(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const obj = try toObjectThis(realm, this_value);
    const target = argOr(args, 0, Value.undefined_);
    // §23.1.3.16 step 1-7 — handle fromIndex BEFORE clamping
    // length so a fromIndex of +∞ short-circuits to -1 even when
    // the array's length exceeds our 16M iteration cap.
    const raw_len = try toLengthOf(realm, obj);
    if (raw_len <= 0) return Value.fromInt32(-1);
    const start = (try startIndexFrom(realm, args, raw_len)) orelse return Value.fromInt32(-1);
    const len = try intrinsics.clampArrayLengthR(realm, raw_len);
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
fn startIndexFrom(realm: *Realm, args: []const Value, len: i64) NativeError!?i64 {
    if (args.len < 2) return 0;
    // §7.1.5 ToIntegerOrInfinity → ToNumber. Route through
    // `intrinsics.toNumber` so Symbol / BigInt throw TypeError
    // and `{valueOf: () => throw}` propagates.
    const nv = try intrinsics.toNumber(realm, args[1]);
    const n: f64 = if (nv.isInt32()) @floatFromInt(nv.asInt32()) else nv.asDouble();
    if (std.math.isNan(n)) return @as(?i64, 0);
    if (n == std.math.inf(f64)) return @as(?i64, null);
    if (n == -std.math.inf(f64)) return @as(?i64, 0);
    const trunc_n = @trunc(n);
    if (trunc_n >= 0) {
        const flen: f64 = @floatFromInt(len);
        if (trunc_n >= flen) return @as(?i64, null);
        return @as(?i64, @intFromFloat(trunc_n));
    }
    // Negative — count from the end.
    const flen: f64 = @floatFromInt(len);
    const adjusted = flen + trunc_n;
    if (adjusted < 0) return @as(?i64, 0);
    return @as(?i64, @intFromFloat(adjusted));
}

fn arrayIncludes(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const obj = try toObjectThis(realm, this_value);
    const target = argOr(args, 0, Value.undefined_);
    // §23.1.3.16 — `length` first, then `fromIndex` (so a
    // throwing `valueOf` on fromIndex propagates and matches
    // V8/JSC ordering).
    const raw_len = try toLengthOf(realm, obj);
    if (raw_len <= 0) return Value.false_;
    const start = (try startIndexFrom(realm, args, raw_len)) orelse return Value.false_;
    const len = try intrinsics.clampArrayLengthR(realm, raw_len);
    var i: i64 = start;
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
    const len = try intrinsics.clampArrayLengthR(realm, try toLengthOf(realm, obj));
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(realm.allocator);
    var i: i64 = 0;
    while (i < len) : (i += 1) {
        if (i != 0) buf.appendSlice(realm.allocator, sep_slice) catch return error.OutOfMemory;
        var ibuf: [24]u8 = undefined;
        const islice = std.fmt.bufPrint(&ibuf, "{d}", .{i}) catch unreachable;
        const v = try getPropertyChain(realm, obj, islice);
        if (v.isUndefined() or v.isNull()) continue; // §23.1.3.18 — undefined / null become empty
        const s = try stringifyArg(realm, v);
        buf.appendSlice(realm.allocator, s.bytes) catch return error.OutOfMemory;
    }
    const out = realm.heap.allocateString(buf.items) catch return error.OutOfMemory;
    return Value.fromString(out);
}

/// §23.1.3.32 Array.prototype.toLocaleString — like join with ","
/// but each element is fed through `Invoke(elt, "toLocaleString")`
/// before string-conversion, so a user-installed
/// `Number.prototype.toLocaleString` is observed. `undefined` and
/// `null` slots stringify to empty per step 6.c (matching join).
fn arrayToLocaleString(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = args;
    const obj = try toObjectThis(realm, this_value);
    const len = try intrinsics.clampArrayLengthR(realm, try toLengthOf(realm, obj));
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(realm.allocator);
    var i: i64 = 0;
    while (i < len) : (i += 1) {
        if (i != 0) buf.appendSlice(realm.allocator, ",") catch return error.OutOfMemory;
        var ibuf: [24]u8 = undefined;
        const islice = std.fmt.bufPrint(&ibuf, "{d}", .{i}) catch unreachable;
        const v = try getPropertyChain(realm, obj, islice);
        if (v.isUndefined() or v.isNull()) continue;
        const boxed = try intrinsics.toObjectThis(realm, v);
        const method_v = boxed.get("toLocaleString");
        var str_v: Value = v;
        if (heap_mod.valueAsFunction(method_v)) |_| {
            const outcome = interpreter.callValue(realm.allocator, realm, method_v, heap_mod.taggedObject(boxed), &.{}) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return error.NativeThrew,
            };
            switch (outcome) {
                .value, .yielded => |x| str_v = x,
                .thrown => return error.NativeThrew,
            }
        }
        const s = try stringifyArg(realm, str_v);
        buf.appendSlice(realm.allocator, s.bytes) catch return error.OutOfMemory;
    }
    const out = realm.heap.allocateString(buf.items) catch return error.OutOfMemory;
    return Value.fromString(out);
}

fn arraySlice(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const obj = try toObjectThis(realm, this_value);
    const raw_len = try toLengthOf(realm, obj);
    const len = try intrinsics.clampArrayLengthR(realm, raw_len);
    var start: i64 = if (args.len > 0) toInt(args[0]) else 0;
    var end: i64 = if (args.len > 1 and !args[1].isUndefined()) toInt(args[1]) else len;
    if (start < 0) start = @max(len + start, 0);
    if (end < 0) end = @max(len + end, 0);
    start = @min(start, len);
    end = @min(end, len);

    // §23.1.3.28 step 7 — `count = max(end - start, 0)`,
    // ArraySpeciesCreate(O, count).
    const count = if (end > start) end - start else 0;
    const out_v = try arraySpeciesCreate(realm, obj, count);
    const out = heap_mod.valueAsPlainObject(out_v) orelse return throwTypeError(realm, "ArraySpeciesCreate did not return an object");
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
    return out_v;
}

/// §23.1.3.2 Array.prototype.concat. The algorithm prepends the
/// receiver to `items`, then for each element decides spread via
/// IsConcatSpreadable: an explicit `@@isConcatSpreadable` overrides
/// the default IsArray check (so RegExp can opt in, a subclass can
/// opt out). Non-spreadable elements are appended whole.
fn arrayConcat(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const obj = try toObjectThis(realm, this_value);
    // §23.1.3.2 step 4 — ArraySpeciesCreate(O, 0).
    const out_v = try arraySpeciesCreate(realm, obj, 0);
    const out = heap_mod.valueAsPlainObject(out_v) orelse return throwTypeError(realm, "ArraySpeciesCreate did not return an object");
    var write_idx: i64 = 0;

    // §23.1.3.2 step 5 prepends O to `items`. O is treated like
    // any other item — IsConcatSpreadable decides whether it
    // spreads or appends whole (so concat.call(nonArray, ...) puts
    // the non-array in slot 0 rather than splaying its indices).
    try concatAppend(realm, out, heap_mod.taggedObject(obj), &write_idx);
    for (args) |arg| {
        try concatAppend(realm, out, arg, &write_idx);
    }
    // §23.1.3.2 step 6 — ? Set(A, "length", n, true). Routes
    // through `setOrThrow` so a user-installed length setter on
    // the species ctor fires and a non-writable length throws.
    try setLengthOrThrow(realm, out, write_idx);
    return out_v;
}

fn concatAppend(realm: *Realm, out: *JSObject, value: Value, write_idx: *i64) NativeError!void {
    const spreadable = try isConcatSpreadable(realm, value);
    const safe_max: i64 = (1 << 53) - 1;
    if (spreadable) {
        const arr = heap_mod.valueAsPlainObject(value) orelse {
            try concatWriteOne(realm, out, value, write_idx);
            return;
        };
        // §23.1.3.2 step 8.d.iii — ? LengthOfArrayLike(E). Must
        // propagate ToLength throws (e.g. poisoned `length.toString`
        // on an opted-in non-array spreadable). Cap at 2^53-1 per
        // §7.1.20 ToLength.
        var len = try intrinsics.toLengthOf(realm, arr);
        if (len > safe_max) len = safe_max;
        // §23.1.3.2 step 8.d.ii — `n + len > 2^53 - 1` throws.
        if (write_idx.* + len > safe_max) {
            return throwTypeError(realm, "Array.prototype.concat length exceeds maximum length");
        }
        var i: i64 = 0;
        while (i < len) : (i += 1) {
            var rbuf: [24]u8 = undefined;
            const rslice = std.fmt.bufPrint(&rbuf, "{d}", .{i}) catch unreachable;
            // HasProperty walks the proto chain; if absent, hole — skip.
            if (!hasPropertyChain(arr, rslice)) {
                write_idx.* += 1;
                continue;
            }
            const v = try getPropertyChain(realm, arr, rslice);
            try concatWriteOne(realm, out, v, write_idx);
        }
    } else {
        // §23.1.3.2 step 8.e.i — `n >= 2^53 - 1` throws.
        if (write_idx.* >= safe_max) {
            return throwTypeError(realm, "Array.prototype.concat length exceeds maximum length");
        }
        try concatWriteOne(realm, out, value, write_idx);
    }
}

fn concatWriteOne(realm: *Realm, out: *JSObject, v: Value, write_idx: *i64) NativeError!void {
    var wbuf: [24]u8 = undefined;
    const wslice = std.fmt.bufPrint(&wbuf, "{d}", .{write_idx.*}) catch unreachable;
    const owned = realm.heap.allocateString(wslice) catch return error.OutOfMemory;
    // §23.1.3.2 step 8.d.iii.3.b / step 8.e.iii — the per-item
    // write is CreateDataPropertyOrThrow, NOT a regular [[Set]].
    // The species-provided result array may have non-writable own
    // slots configured by its constructor; the spec mandates a
    // CreateDataProperty, which redefines the slot back to the
    // default `{w:T,e:T,c:T}` and rejects non-configurable own
    // slots / non-extensible receivers.
    try createDataPropertyOrThrowGeneric(realm, out, owned.bytes, v);
    write_idx.* += 1;
}

/// §23.1.3.2.1 IsConcatSpreadable. `@@isConcatSpreadable` is the
/// override hook; absent it, IsArray decides.
fn isConcatSpreadable(realm: *Realm, v: Value) NativeError!bool {
    const obj = heap_mod.valueAsPlainObject(v) orelse return false;
    const spreadable_v = try getPropertyChain(realm, obj, "@@isConcatSpreadable");
    if (!spreadable_v.isUndefined()) return toBoolean(spreadable_v);
    return obj.is_array_exotic;
}

fn hasPropertyChain(obj: *JSObject, key: []const u8) bool {
    return obj.hasProperty(key);
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
    out.markAsArrayExotic(realm.allocator) catch return error.OutOfMemory;
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

    out.markAsArrayExotic(realm.allocator) catch return error.OutOfMemory;
    // §23.1.2.1 — every branch below re-enters JS (string fast
    // path, @@iterator next(), array-like indexed get, optional
    // mapfn callback) and each re-entry can trigger a GC sweep
    // that would otherwise collect `out` (held only on the Zig
    // stack) and the source/iterator if it's ephemeral. Pin them
    // through a HandleScope until we return.
    const scope = realm.heap.openScope() catch return error.OutOfMemory;
    defer scope.close();
    scope.push(heap_mod.taggedObject(out)) catch return error.OutOfMemory;
    if (heap_mod.valueAsPlainObject(items) != null) {
        scope.push(items) catch return error.OutOfMemory;
    }
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
    const len = try intrinsics.clampArrayLengthR(realm, lengthOfArray(src));
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
    const len = try intrinsics.clampArrayLengthR(realm, try toLengthOf(realm, obj));
    var idx = if (args.len > 0) toInt(args[0]) else 0;
    if (idx < 0) idx += len;
    if (idx < 0 or idx >= len) return Value.undefined_;
    var ibuf: [24]u8 = undefined;
    const islice = std.fmt.bufPrint(&ibuf, "{d}", .{idx}) catch unreachable;
    return try getPropertyChain(realm, obj, islice);
}

fn arrayFill(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    // §23.1.3.7 — `ToObject(this)` + `LengthOfArrayLike` + the
    // start/end ToIntegerOrInfinity coercions are all spec-?
    // abrupt-completing. Use the accessor-aware helpers so a
    // throwing `length` / `valueOf` propagates as the user's
    // exception instead of being silently coerced to 0.
    const obj = try toObjectThis(realm, this_value);
    const value = argOr(args, 0, Value.undefined_);
    const len = try intrinsics.clampArrayLengthR(realm, try toLengthOf(realm, obj));
    // §23.1.3.7 step 5-9 — start / end use ToIntegerOrInfinity,
    // which fires through ToPrimitive (valueOf / toString /
    // @@toPrimitive). The `try` propagates a thrown coercion.
    var start: i64 = if (args.len > 1) try toIntPropagating(realm, args[1]) else 0;
    var end: i64 = if (args.len > 2 and !args[2].isUndefined()) try toIntPropagating(realm, args[2]) else len;
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
    return heap_mod.taggedObject(obj);
}

/// §7.1.5 ToIntegerOrInfinity with the abrupt-completion path
/// propagated. Symbols → TypeError; objects → ToPrimitive
/// chain (valueOf / toString / @@toPrimitive) which may throw.
fn toIntPropagating(realm: *Realm, v: Value) NativeError!i64 {
    // §7.1.4 ToNumber — invokes toPrimitive for object receivers
    // (so a throwing `valueOf` / `toString` propagates), and rejects
    // Symbol / BigInt with TypeError per the abstract op.
    const n = try intrinsics.toNumber(realm, v);
    const d: f64 = if (n.isInt32()) @floatFromInt(n.asInt32()) else if (n.isDouble()) n.asDouble() else 0;
    if (std.math.isNan(d)) return 0;
    if (d == std.math.inf(f64)) return std.math.maxInt(i64);
    if (d == -std.math.inf(f64)) return std.math.minInt(i64);
    return @intFromFloat(@trunc(d));
}

fn arrayLastIndexOf(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const obj = try toObjectThis(realm, this_value);
    const target = argOr(args, 0, Value.undefined_);
    const raw_len = try toLengthOf(realm, obj);
    if (raw_len <= 0) return Value.fromInt32(-1);
    // §23.1.3.20 steps 4-7 — fromIndex handling. Default to
    // `len - 1`. -∞ short-circuits (return -1). Positive values
    // clamp to `len - 1`. Negative values offset from the end;
    // if the result is < 0 the loop never runs and we return -1.
    const start = (try lastStartIndexFrom(realm, args, raw_len)) orelse return Value.fromInt32(-1);
    // Sparse fast path — see `sparseReverseSearch`.
    if (obj.is_array_exotic and obj.is_sparse) {
        if (try sparseReverseSearch(realm, obj, start, target)) |found| return numberFromI64(found);
        return Value.fromInt32(-1);
    }
    const len = try intrinsics.clampArrayLengthR(realm, raw_len);
    // Iteration cap can't truncate above `start` — but if the
    // raw length exceeded the cap, `start` might too. Clamp.
    var i: i64 = if (start >= len) len - 1 else start;
    while (i >= 0) : (i -= 1) {
        var ibuf: [24]u8 = undefined;
        const islice = std.fmt.bufPrint(&ibuf, "{d}", .{i}) catch unreachable;
        if (!obj.hasProperty(islice)) continue;
        const v = try getPropertyChain(realm, obj, islice);
        if (strictEqualsLite(v, target)) return numberFromI64(i);
    }
    return Value.fromInt32(-1);
}

/// Sparse-aware reverse search. When the receiver is an array
/// exotic in sparse mode, iterating `start..0` linearly hits
/// `clampArrayLength`'s 16M cap (intentional — the cap exists
/// to avoid OOM on `arr.length = 2**32 - 1`). Walk own sparse
/// keys ≤ `start` in descending order instead.
///
/// Returns the index of the first key whose value strict-equals
/// `target`, or `null` if none matches. The walk is over OWN
/// keys only — inherited indexed accessors on the prototype
/// chain are NOT consulted (spec would have us hit every k from
/// `start` down to 0). The typical sparse fixture uses default
/// `Array.prototype` (no indexed accessors), so this trades
/// strict §10.1.7 HasProperty completeness for tractable RSS.
fn sparseReverseSearch(realm: *Realm, arr: *JSObject, start: i64, target: Value) NativeError!?i64 {
    const keys = try sparseDescendingKeys(realm, arr, start);
    defer realm.allocator.free(keys);
    for (keys) |k| {
        const v = arr.sparse_elements.get(k) orelse continue;
        if (strictEqualsLite(v, target)) return @as(i64, k);
    }
    return null;
}

/// Return a heap-allocated slice of `arr`'s sparse-mode own
/// keys ≤ `start`, sorted descending. Caller frees with
/// `realm.allocator.free`. Skips hole entries (defensive — the
/// sparse map shouldn't store them, but `holeIndexed`'s
/// invariant is checked at the caller boundary).
fn sparseDescendingKeys(realm: *Realm, arr: *JSObject, start: i64) NativeError![]u32 {
    if (start < 0) return realm.allocator.alloc(u32, 0) catch return error.OutOfMemory;
    const start_u32: u32 = if (start > std.math.maxInt(u32)) std.math.maxInt(u32) else @intCast(start);
    var keys: std.ArrayListUnmanaged(u32) = .empty;
    errdefer keys.deinit(realm.allocator);
    keys.ensureTotalCapacity(realm.allocator, arr.sparse_elements.count()) catch return error.OutOfMemory;
    var it = arr.sparse_elements.iterator();
    while (it.next()) |entry| {
        if (entry.key_ptr.* > start_u32) continue;
        if (JSObject.isElementHole(entry.value_ptr.*)) continue;
        keys.appendAssumeCapacity(entry.key_ptr.*);
    }
    std.mem.sort(u32, keys.items, {}, struct {
        fn descending(_: void, a: u32, b: u32) bool {
            return a > b;
        }
    }.descending);
    return keys.toOwnedSlice(realm.allocator) catch return error.OutOfMemory;
}

/// §23.1.3.20 steps 4-7 — clamp the optional `fromIndex` arg
/// for `lastIndexOf`. Returns the starting index (iteration goes
/// downward) or `null` when the start is < 0 (caller short-
/// circuits to -1). When fromIndex is absent, start = len - 1.
fn lastStartIndexFrom(realm: *Realm, args: []const Value, len: i64) NativeError!?i64 {
    if (args.len < 2) return len - 1;
    // §7.1.5 ToIntegerOrInfinity → ToNumber. Route through
    // `intrinsics.toNumber` so an object fromIndex with a
    // `valueOf` / `toString` participates in ToPrimitive, and
    // Symbol / BigInt throw TypeError. The pre-fix fallthrough
    // silently coerced any object to 0, defeating fixtures like
    // `[…].lastIndexOf(x, {valueOf: () => 2})`.
    const nv = try intrinsics.toNumber(realm, args[1]);
    const n: f64 = if (nv.isInt32()) @floatFromInt(nv.asInt32()) else nv.asDouble();
    if (std.math.isNan(n)) return 0;
    // -∞ short-circuits per spec: "If n is -∞, return -1."
    if (n == -std.math.inf(f64)) return null;
    if (n == std.math.inf(f64)) return len - 1;
    const trunc_n = @trunc(n);
    if (trunc_n >= 0) {
        const flen: f64 = @floatFromInt(len);
        if (trunc_n >= flen - 1) return len - 1;
        return @intFromFloat(trunc_n);
    }
    // Negative — count from the end. `len + trunc_n < 0` means
    // the start is before the array; loop never runs → return -1.
    const flen: f64 = @floatFromInt(len);
    const adjusted = flen + trunc_n;
    if (adjusted < 0) return null;
    return @intFromFloat(adjusted);
}

fn arrayFindLast(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const obj = try toObjectThis(realm, this_value);
    const len = try intrinsics.clampArrayLengthR(realm, try toLengthOf(realm, obj));
    const callback = heap_mod.valueAsFunction(argOr(args, 0, Value.undefined_)) orelse return throwTypeError(realm, "Array.prototype.findLast callback must be a function");
    const this_arg = argOr(args, 1, Value.undefined_);
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
    // §23.1.3.12 — spec mandates `LengthOfArrayLike(O)` (via
    // `Get(O, "length")`) and `Get(O, ! ToString(k))` for each
    // step, so callers can observe an overridden `length` getter
    // and inherited indexed accessors on the prototype chain.
    // Step order: ToObject → length → IsCallable.
    const obj = try toObjectThis(realm, this_value);
    const len = try intrinsics.clampArrayLengthR(realm, try toLengthOf(realm, obj));
    const callback = heap_mod.valueAsFunction(argOr(args, 0, Value.undefined_)) orelse return throwTypeError(realm, "Array.prototype.findLastIndex callback must be a function");
    const this_arg = argOr(args, 1, Value.undefined_);
    var i: i64 = len - 1;
    while (i >= 0) : (i -= 1) {
        var ibuf: [24]u8 = undefined;
        const islice = std.fmt.bufPrint(&ibuf, "{d}", .{i}) catch unreachable;
        const elem = try getPropertyChain(realm, obj, islice);
        const v = try invokeCallback(realm, callback, this_arg, elem, i, obj);
        if (toBoolean(v)) return numberFromI64(i);
    }
    return Value.fromInt32(-1);
}

fn arrayReduceRight(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    // §23.1.3.27 — `LengthOfArrayLike(O)` + `HasProperty` /
    // `Get` on each step. Walks the prototype chain so an
    // inherited indexed accessor / `Boolean.prototype[0]` style
    // fixture works. Step order: ToObject → length → IsCallable.
    const obj = try toObjectThis(realm, this_value);
    // We re-read length below in the sparse fast path; the eager
    // up-front read here also fixes step-order fixtures that
    // expect a throwing length-getter to win over a missing
    // callback.
    _ = try toLengthOf(realm, obj);
    const callback = heap_mod.valueAsFunction(argOr(args, 0, Value.undefined_)) orelse return throwTypeError(realm, "Array.prototype.reduceRight callback must be a function");
    var acc: Value = Value.undefined_;
    var have_acc = args.len >= 2;
    if (have_acc) acc = args[1];

    // Sparse fast path — walk own keys in descending order.
    // Like §23.1.3.27 step 5 (initial-acc seeding from the
    // rightmost present element), the descending sort means the
    // first iteration produces the initial acc when no explicit
    // one was passed.
    if (obj.is_array_exotic and obj.is_sparse) {
        const raw_len = try toLengthOf(realm, obj);
        if (raw_len <= 0) {
            if (have_acc) return acc;
            return throwTypeError(realm, "Reduce of empty array with no initial value");
        }
        const ks = try sparseDescendingKeys(realm, obj, raw_len - 1);
        defer realm.allocator.free(ks);
        var idx: usize = 0;
        if (!have_acc) {
            if (ks.len == 0) return throwTypeError(realm, "Reduce of empty array with no initial value");
            acc = obj.sparse_elements.get(ks[0]) orelse Value.undefined_;
            have_acc = true;
            idx = 1;
        }
        while (idx < ks.len) : (idx += 1) {
            const k = ks[idx];
            const elem = obj.sparse_elements.get(k) orelse continue;
            const cb_args = [_]Value{ acc, elem, numberFromI64(@as(i64, k)), heap_mod.taggedObject(obj) };
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

    const len = try intrinsics.clampArrayLengthR(realm, try toLengthOf(realm, obj));
    var i: i64 = len - 1;
    if (!have_acc) {
        while (i >= 0) : (i -= 1) {
            var ibuf: [24]u8 = undefined;
            const islice = std.fmt.bufPrint(&ibuf, "{d}", .{i}) catch unreachable;
            if (obj.hasProperty(islice)) {
                acc = try getPropertyChain(realm, obj, islice);
                have_acc = true;
                i -= 1;
                break;
            }
        }
        if (!have_acc) return throwTypeError(realm, "Reduce of empty array with no initial value");
    }

    while (i >= 0) : (i -= 1) {
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
    // §23.1.3.10 step 4 — ArraySpeciesCreate(O, 0).
    const out_v = try arraySpeciesCreate(realm, obj, 0);
    const out = heap_mod.valueAsPlainObject(out_v) orelse return throwTypeError(realm, "ArraySpeciesCreate did not return an object");
    var write_idx: i64 = 0;
    try flattenInto(realm, obj, depth, out, &write_idx);
    setLength(realm, out, write_idx) catch return error.OutOfMemory;
    return out_v;
}

fn flattenInto(realm: *Realm, source: *JSObject, depth: i64, target: *JSObject, write_idx: *i64) NativeError!void {
    const len = try intrinsics.clampArrayLengthR(realm, lengthOfArray(source));
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
    const callback = heap_mod.valueAsFunction(argOr(args, 0, Value.undefined_)) orelse return throwTypeError(realm, "Array.prototype.flatMap callback must be a function");
    const this_arg = argOr(args, 1, Value.undefined_);
    // §23.1.3.10 — `LengthOfArrayLike(O)` + `Get(O, ! ToString(P))`
    // walks the prototype chain (so a fixture that maps over
    // `Array.prototype.flatMap.call(false, cb)` sees inherited
    // accessors from `Boolean.prototype`).
    const len = try intrinsics.clampArrayLengthR(realm, try toLengthOf(realm, obj));

    // §23.1.3.11 step 5 — ArraySpeciesCreate(O, 0).
    const out_v = try arraySpeciesCreate(realm, obj, 0);
    const out = heap_mod.valueAsPlainObject(out_v) orelse return throwTypeError(realm, "ArraySpeciesCreate did not return an object");
    var write_idx: i64 = 0;
    var i: i64 = 0;
    while (i < len) : (i += 1) {
        var ibuf: [24]u8 = undefined;
        const islice = std.fmt.bufPrint(&ibuf, "{d}", .{i}) catch unreachable;
        if (!obj.hasProperty(islice)) continue;
        const elem = try getPropertyChain(realm, obj, islice);
        const mapped = try invokeCallback(realm, callback, this_arg, elem, i, obj);
        if (isArrayLike(mapped)) {
            const inner = heap_mod.valueAsPlainObject(mapped).?;
            const inner_len = try intrinsics.clampArrayLengthR(realm, try toLengthOf(realm, inner));
            var j: i64 = 0;
            while (j < inner_len) : (j += 1) {
                var jbuf: [24]u8 = undefined;
                const jslice = std.fmt.bufPrint(&jbuf, "{d}", .{j}) catch unreachable;
                const v = try getPropertyChain(realm, inner, jslice);
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
    return out_v;
}

fn arraySplice(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    // §23.1.3.29 Array.prototype.splice (start, deleteCount, ...items):
    //   1. O = ToObject(this); 2. len = ? ToLength(? Get(O, "length"))
    //   3-6. relativeStart = ? ToIntegerOrInfinity(start), clamp -> actualStart
    //   7. If args.len == 0:  insertCount=0, actualDeleteCount=0
    //   8. ElseIf args.len == 1: insertCount=0, actualDeleteCount=len-actualStart
    //   9. Else: insertCount=args.len-2; dc=? ToInteger(deleteCount);
    //            actualDeleteCount = min(max(dc,0), len-actualStart)
    //   10. If len + insertCount - actualDeleteCount > 2^53-1, throw TypeError
    //   11. A = ? ArraySpeciesCreate(O, actualDeleteCount)
    //   12-13. Copy O[actualStart..+actualDeleteCount-1] into A via
    //         HasProperty + (Get + CreateDataPropertyOrThrow)
    //   14. ? Set(A, "length", actualDeleteCount, true)
    //   15-18. Shift remaining elements left or right; insert items
    //   19. ? Set(O, "length", len - actualDeleteCount + insertCount, true)
    //   20. Return A
    const obj = try toObjectThis(realm, this_value);
    var len = try toLengthOf(realm, obj);
    const safe_max: i64 = (1 << 53) - 1;
    if (len > safe_max) len = safe_max;

    // §23.1.3.29 step 3 — ToIntegerOrInfinity(start). Use ToNumber so
    // accessor / valueOf hooks fire and Symbol throws.
    var start: i64 = 0;
    if (args.len > 0) {
        const nv = try intrinsics.toNumber(realm, args[0]);
        const d: f64 = if (nv.isInt32()) @floatFromInt(nv.asInt32()) else nv.asDouble();
        if (std.math.isNan(d)) {
            start = 0;
        } else if (d == -std.math.inf(f64)) {
            start = 0;
        } else if (d == std.math.inf(f64)) {
            start = len;
        } else {
            const t = @trunc(d);
            if (t < 0) {
                const candidate = len + @as(i64, @intFromFloat(@max(t, -@as(f64, @floatFromInt(safe_max))))) ;
                start = @max(candidate, 0);
            } else {
                start = @min(@as(i64, @intFromFloat(@min(t, @as(f64, @floatFromInt(safe_max))))), len);
            }
        }
    }

    var delete_count: i64 = 0;
    if (args.len == 1) {
        delete_count = len - start;
    } else if (args.len >= 2) {
        const nv = try intrinsics.toNumber(realm, args[1]);
        const d: f64 = if (nv.isInt32()) @floatFromInt(nv.asInt32()) else nv.asDouble();
        if (std.math.isNan(d) or d < 0) {
            delete_count = 0;
        } else if (d == std.math.inf(f64)) {
            delete_count = len - start;
        } else {
            const t = @trunc(d);
            const clamped: i64 = @intFromFloat(@min(t, @as(f64, @floatFromInt(safe_max))));
            delete_count = @max(@min(clamped, len - start), 0);
        }
    }

    const insert_count: i64 = if (args.len > 2) @as(i64, @intCast(args.len - 2)) else 0;
    // §23.1.3.29 step 10 — 2^53 - 1 cap on the resulting length.
    if (len + insert_count - delete_count > safe_max) {
        return throwTypeError(realm, "Splice would exceed maximum length");
    }

    // §23.1.3.29 step 11 — ArraySpeciesCreate(O, actualDeleteCount).
    // The ArrayCreate inside `defaultArrayCreate` enforces the
    // 2^32-1 cap → RangeError when actualDeleteCount is huge.
    const removed_v = try arraySpeciesCreate(realm, obj, delete_count);
    const removed = heap_mod.valueAsPlainObject(removed_v) orelse return throwTypeError(realm, "ArraySpeciesCreate did not return an object");

    // §23.1.3.29 step 12-13 — copy O[start..start+actualDeleteCount-1]
    // into A. Uses HasProperty for hole-aware copy + CreateDataPropertyOrThrow
    // so existing accessor props on `A` don't intercept the per-index write.
    var i: i64 = 0;
    while (i < delete_count) : (i += 1) {
        var rbuf: [24]u8 = undefined;
        const rslice = std.fmt.bufPrint(&rbuf, "{d}", .{start + i}) catch unreachable;
        if (!obj.hasProperty(rslice)) continue;
        const v = try getPropertyChain(realm, obj, rslice);
        var wbuf: [24]u8 = undefined;
        const wslice = std.fmt.bufPrint(&wbuf, "{d}", .{i}) catch unreachable;
        const owned = realm.heap.allocateString(wslice) catch return error.OutOfMemory;
        try createDataPropertyOrThrowGeneric(realm, removed, owned.bytes, v);
    }
    try setLengthOrThrow(realm, removed, delete_count);

    const new_len = len - delete_count + insert_count;

    if (insert_count < delete_count) {
        // §23.1.3.29 step 15.b — shift O[start+actualDeleteCount..len-1]
        // left by (actualDeleteCount - insertCount) using
        // HasProperty + (Set or DeletePropertyOrThrow).
        var k: i64 = start;
        while (k < len - delete_count) : (k += 1) {
            const from = k + delete_count;
            const to = k + insert_count;
            var sb: [24]u8 = undefined;
            var db: [24]u8 = undefined;
            const sslice = std.fmt.bufPrint(&sb, "{d}", .{from}) catch unreachable;
            const dslice = std.fmt.bufPrint(&db, "{d}", .{to}) catch unreachable;
            if (obj.hasProperty(sslice)) {
                const v = try getPropertyChain(realm, obj, sslice);
                const owned = realm.heap.allocateString(dslice) catch return error.OutOfMemory;
                try setOrThrow(realm, obj, owned.bytes, v);
            } else {
                try deletePropertyOrThrow(realm, obj, dslice);
            }
        }
        // §23.1.3.29 step 15.d — DeletePropertyOrThrow indices in
        // [new_len, len) descending so a non-configurable element
        // surfaces an honest TypeError.
        var trim: i64 = len;
        while (trim > new_len) {
            trim -= 1;
            var tb: [24]u8 = undefined;
            const tslice = std.fmt.bufPrint(&tb, "{d}", .{trim}) catch unreachable;
            try deletePropertyOrThrow(realm, obj, tslice);
        }
    } else if (insert_count > delete_count) {
        // §23.1.3.29 step 16 — shift right from the top.
        var k: i64 = len - delete_count;
        while (k > start) {
            k -= 1;
            const from = k + delete_count;
            const to = k + insert_count;
            var sb: [24]u8 = undefined;
            var db: [24]u8 = undefined;
            const sslice = std.fmt.bufPrint(&sb, "{d}", .{from}) catch unreachable;
            const dslice = std.fmt.bufPrint(&db, "{d}", .{to}) catch unreachable;
            if (obj.hasProperty(sslice)) {
                const v = try getPropertyChain(realm, obj, sslice);
                const owned = realm.heap.allocateString(dslice) catch return error.OutOfMemory;
                try setOrThrow(realm, obj, owned.bytes, v);
            } else {
                try deletePropertyOrThrow(realm, obj, dslice);
            }
        }
    }

    // §23.1.3.29 step 17-18 — insert items.
    var ins: i64 = 0;
    while (ins < insert_count) : (ins += 1) {
        var b: [24]u8 = undefined;
        const slc = std.fmt.bufPrint(&b, "{d}", .{start + ins}) catch unreachable;
        const owned = realm.heap.allocateString(slc) catch return error.OutOfMemory;
        try setOrThrow(realm, obj, owned.bytes, args[2 + @as(usize, @intCast(ins))]);
    }

    // §23.1.3.29 step 19 — ? Set(O, "length", len - dc + ic, true).
    try setLengthOrThrow(realm, obj, new_len);
    return removed_v;
}

/// §7.3.7 CreateDataPropertyOrThrow — local variant for callers
/// not in the `Array.fromAsync` state-machine. Lands `value` as an
/// own data property with `{w:T,e:T,c:T}`; rejects non-extensible
/// receivers and non-configurable redefines with TypeError.
fn createDataPropertyOrThrowGeneric(realm: *Realm, obj: *JSObject, key: []const u8, value: Value) NativeError!void {
    const ObjMod = @import("../object.zig");
    const had_own = obj.hasOwn(key);
    if (!had_own and !obj.extensible) {
        return throwTypeError(realm, "Cannot define property on non-extensible object");
    }
    if (had_own) {
        const cur = obj.flagsFor(key);
        if (!cur.configurable) {
            return throwTypeError(realm, "Cannot redefine non-configurable property");
        }
        // §10.1.6.3 OrdinaryDefineOwnProperty — a configurable slot
        // can be redefined back to the all-true default. Clear any
        // demoted indexed-slot entry from `properties` so the
        // subsequent `setWithFlags(default)` lands in `elements`
        // again rather than leaving the bag-promoted descriptor.
        _ = obj.properties.swapRemove(key);
        _ = obj.property_flags.swapRemove(key);
    }
    obj.setWithFlags(realm.allocator, key, value, ObjMod.PropertyFlags.default) catch return error.OutOfMemory;
}

fn arrayCopyWithin(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    // §23.1.3.4 step 1-3 — ToObject, then LengthOfArrayLike via the
    // accessor-aware path so a throwing `length` getter propagates.
    const obj = try toObjectThis(realm, this_value);
    const len = try intrinsics.clampArrayLengthR(realm, try toLengthOf(realm, obj));
    // §23.1.3.4 steps 4-8 — ToIntegerOrInfinity on target / start /
    // end. Each can be an object with a throwing `valueOf` /
    // `toString` (or a Symbol → TypeError); use the propagating
    // helper so abrupt completions surface as JS exceptions.
    var target: i64 = if (args.len > 0) try toIntPropagating(realm, args[0]) else 0;
    var start: i64 = if (args.len > 1) try toIntPropagating(realm, args[1]) else 0;
    var end: i64 = if (args.len > 2 and !args[2].isUndefined()) try toIntPropagating(realm, args[2]) else len;
    if (target < 0) target = @max(len + target, 0);
    if (start < 0) start = @max(len + start, 0);
    if (end < 0) end = @max(len + end, 0);
    target = @min(target, len);
    start = @min(start, len);
    end = @min(end, len);
    const count: i64 = @min(end - start, len - target);
    if (count <= 0) return this_value;

    // §23.1.3.4 steps 14-18 — HasProperty / Get / Set / Delete on
    // each visited index. Direction matters when ranges overlap.
    // Use the accessor-aware `getPropertyChain` so a poisoned
    // getter on a copied source slot propagates, and fall back to
    // `Delete` when the source slot is a hole.
    if (start < target and target < start + count) {
        var k: i64 = count - 1;
        while (k >= 0) : (k -= 1) {
            try copyWithinStep(realm, obj, start + k, target + k);
        }
    } else {
        var k: i64 = 0;
        while (k < count) : (k += 1) {
            try copyWithinStep(realm, obj, start + k, target + k);
        }
    }
    return this_value;
}

fn copyWithinStep(realm: *Realm, obj: *JSObject, src: i64, dst: i64) NativeError!void {
    var sb: [24]u8 = undefined;
    var db: [24]u8 = undefined;
    const sslice = std.fmt.bufPrint(&sb, "{d}", .{src}) catch unreachable;
    const dslice = std.fmt.bufPrint(&db, "{d}", .{dst}) catch unreachable;
    if (obj.hasProperty(sslice)) {
        const v = try getPropertyChain(realm, obj, sslice);
        obj.set(realm.allocator, dslice, v) catch return error.OutOfMemory;
    } else {
        _ = obj.deleteOwn(dslice);
    }
}

fn arraySort(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    // §23.1.3.30 step 1 — comparefn validation (callable or
    // undefined) runs before ToObject and length, so a non-callable
    // comparator throws synchronously.
    const cmp_v = argOr(args, 0, Value.undefined_);
    const cmp_fn: ?*JSFunction = if (cmp_v.isUndefined())
        null
    else if (heap_mod.valueAsFunction(cmp_v)) |f| f
    else
        return throwTypeError(realm, "comparefn must be a function or undefined");
    const obj = try toObjectThis(realm, this_value);
    const len = try intrinsics.clampArrayLengthR(realm, try toLengthOf(realm, obj));
    if (len <= 1) return heap_mod.taggedObject(obj);

    // §23.1.3.30.1 SortIndexedProperties — gather only present
    // entries (HasProperty true), partition out undefineds, sort
    // the remaining values, write items back at 0..items.len,
    // then a run of undefineds, then Delete the trailing slots
    // so holes that existed in the receiver propagate to the end.
    var items: std.ArrayList(Value) = .empty;
    defer items.deinit(realm.allocator);
    var undef_count: i64 = 0;
    var hole_count: i64 = 0;
    var i: i64 = 0;
    while (i < len) : (i += 1) {
        var ibuf: [24]u8 = undefined;
        const islice = std.fmt.bufPrint(&ibuf, "{d}", .{i}) catch unreachable;
        if (!obj.hasProperty(islice)) {
            hole_count += 1;
            continue;
        }
        const v = try getPropertyChain(realm, obj, islice);
        if (v.isUndefined()) {
            undef_count += 1;
        } else {
            items.append(realm.allocator, v) catch return error.OutOfMemory;
        }
    }

    try sortBufferStable(realm, items.items, cmp_fn);

    // Write sorted items back at 0..items.len.
    var w: usize = 0;
    while (w < items.items.len) : (w += 1) {
        var wbuf: [24]u8 = undefined;
        const wslice = std.fmt.bufPrint(&wbuf, "{d}", .{w}) catch unreachable;
        const owned = realm.heap.allocateString(wslice) catch return error.OutOfMemory;
        obj.set(realm.allocator, owned.bytes, items.items[w]) catch return error.OutOfMemory;
    }
    // Then `undef_count` undefineds (so `[undef, 1].sort()` puts
    // `1` first and the undefined back at index 1).
    var u: i64 = 0;
    while (u < undef_count) : (u += 1) {
        var wbuf: [24]u8 = undefined;
        const wslice = std.fmt.bufPrint(&wbuf, "{d}", .{@as(i64, @intCast(items.items.len)) + u}) catch unreachable;
        const owned = realm.heap.allocateString(wslice) catch return error.OutOfMemory;
        obj.set(realm.allocator, owned.bytes, Value.undefined_) catch return error.OutOfMemory;
    }
    // Holes: delete the remaining trailing indices, preserving
    // them as absent rather than padding with undefined.
    var d: i64 = 0;
    const written: i64 = @as(i64, @intCast(items.items.len)) + undef_count;
    while (d < hole_count) : (d += 1) {
        var dbuf: [24]u8 = undefined;
        const dslice = std.fmt.bufPrint(&dbuf, "{d}", .{written + d}) catch unreachable;
        _ = obj.deleteOwn(dslice);
    }
    return heap_mod.taggedObject(obj);
}

/// In-place stable sort of `buf`. Uses simple insertion sort —
/// adequate for the test262 fixture sizes (most under a few
/// hundred) and keeps stability per §23.1.3.30 (Array.prototype.
/// sort is required to be stable as of ES2019).
fn sortBufferStable(realm: *Realm, buf: []Value, cmp_fn: ?*JSFunction) NativeError!void {
    var n: usize = 1;
    while (n < buf.len) : (n += 1) {
        const key = buf[n];
        var j: isize = @as(isize, @intCast(n)) - 1;
        while (j >= 0) : (j -= 1) {
            const cmp = try sortCompare(realm, buf[@intCast(j)], key, cmp_fn);
            // Stable: only shift left when strictly greater.
            if (cmp <= 0) break;
            buf[@intCast(j + 1)] = buf[@intCast(j)];
        }
        buf[@intCast(j + 1)] = key;
    }
}

/// §23.1.3.30.2 CompareArrayElements. Returns -1, 0, or +1
/// (the sign of the comparator's result, NaN treated as +0).
/// With a user comparator, ToNumber is applied to the result.
/// Without one, both operands go through ToString (hint
/// "string"), then are compared lexically. Undefineds never
/// reach here — `arraySort` partitions them out before sorting.
fn sortCompare(realm: *Realm, x: Value, y: Value, cmp_fn: ?*JSFunction) NativeError!i32 {
    if (cmp_fn) |c| {
        const cb_args = [_]Value{ x, y };
        const outcome = interpreter.callJSFunction(realm.allocator, realm, c, Value.undefined_, &cb_args) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.NativeThrew,
        };
        switch (outcome) {
            .value, .yielded => |v| {
                // §23.1.3.30.2 step 6 — ToNumber on the return; a
                // throwing ToNumber propagates.
                const num = try intrinsics.toNumber(realm, v);
                const d: f64 = if (num.isInt32())
                    @floatFromInt(num.asInt32())
                else if (num.isDouble())
                    num.asDouble()
                else
                    0;
                if (std.math.isNan(d)) return 0;
                if (d < 0) return -1;
                if (d > 0) return 1;
                return 0;
            },
            .thrown => |ex| {
                realm.pending_exception = ex;
                return error.NativeThrew;
            },
        }
    }
    // Default: ToString both sides via §7.1.17 (consulting
    // `toString` / `valueOf` per the spec hint chain).
    const xs = try intrinsics.stringifyArg(realm, x);
    const ys = try intrinsics.stringifyArg(realm, y);
    return switch (std.mem.order(u8, xs.bytes, ys.bytes)) {
        .lt => -1,
        .eq => 0,
        .gt => 1,
    };
}

/// §23.1.3.34 Array.prototype.toSorted — non-mutating sibling
/// of `sort`. Allocate a fresh array, copy the source values,
/// sort the copy, return it; the receiver is untouched.
///
/// Spec step 1 requires the comparator (when provided) to be
/// callable, throwing TypeError synchronously before any read.
fn arrayToSorted(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    // §23.1.3.34 step 1 — comparator validation before ToObject.
    const cmp_v = argOr(args, 0, Value.undefined_);
    const cmp_fn: ?*JSFunction = blk: {
        if (cmp_v.isUndefined()) break :blk null;
        if (heap_mod.valueAsFunction(cmp_v)) |f| break :blk f;
        return intrinsics.throwTypeError(realm, "comparefn must be a function");
    };
    const obj = try toObjectThis(realm, this_value);
    const len = try intrinsics.clampArrayLengthR(realm, try toLengthOf(realm, obj));
    const out = realm.heap.allocateObject() catch return error.OutOfMemory;
    out.prototype = realm.intrinsics.array_prototype;
    out.markAsArrayExotic(realm.allocator) catch return error.OutOfMemory;
    if (len == 0) {
        setLength(realm, out, 0) catch return error.OutOfMemory;
        return heap_mod.taggedObject(out);
    }

    // §23.1.3.34 — read every index via [[Get]], partition out
    // undefineds, sort, and write the result. Holes (HasProperty
    // false) read as undefined per the spec ([[Get]] returns
    // undefined for absent) which then sorts to the end alongside
    // explicit undefineds — toSorted does NOT preserve holes, it
    // produces a dense array of the same length.
    var items: std.ArrayList(Value) = .empty;
    defer items.deinit(realm.allocator);
    var undef_count: i64 = 0;
    var i: i64 = 0;
    while (i < len) : (i += 1) {
        var ibuf: [24]u8 = undefined;
        const islice = std.fmt.bufPrint(&ibuf, "{d}", .{i}) catch unreachable;
        const v = try getPropertyChain(realm, obj, islice);
        if (v.isUndefined()) {
            undef_count += 1;
        } else {
            items.append(realm.allocator, v) catch return error.OutOfMemory;
        }
    }

    try sortBufferStable(realm, items.items, cmp_fn);

    var w: usize = 0;
    while (w < items.items.len) : (w += 1) {
        var wbuf: [24]u8 = undefined;
        const wslice = std.fmt.bufPrint(&wbuf, "{d}", .{w}) catch unreachable;
        const owned = realm.heap.allocateString(wslice) catch return error.OutOfMemory;
        out.set(realm.allocator, owned.bytes, items.items[w]) catch return error.OutOfMemory;
    }
    var u: i64 = 0;
    while (u < undef_count) : (u += 1) {
        var wbuf: [24]u8 = undefined;
        const wslice = std.fmt.bufPrint(&wbuf, "{d}", .{@as(i64, @intCast(items.items.len)) + u}) catch unreachable;
        const owned = realm.heap.allocateString(wslice) catch return error.OutOfMemory;
        out.set(realm.allocator, owned.bytes, Value.undefined_) catch return error.OutOfMemory;
    }
    setLength(realm, out, len) catch return error.OutOfMemory;
    return heap_mod.taggedObject(out);
}

/// §23.1.3.33 Array.prototype.toReversed — non-mutating sibling
/// of `reverse`. Allocate, copy back-to-front, return.
fn arrayToReversed(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = args;
    const obj = try toObjectThis(realm, this_value);
    const len = try intrinsics.clampArrayLengthR(realm, try toLengthOf(realm, obj));
    const out = realm.heap.allocateObject() catch return error.OutOfMemory;
    out.prototype = realm.intrinsics.array_prototype;
    out.markAsArrayExotic(realm.allocator) catch return error.OutOfMemory;
    var i: i64 = 0;
    while (i < len) : (i += 1) {
        var rb: [24]u8 = undefined;
        var wb: [24]u8 = undefined;
        const rslice = std.fmt.bufPrint(&rb, "{d}", .{len - 1 - i}) catch unreachable;
        const wslice = std.fmt.bufPrint(&wb, "{d}", .{i}) catch unreachable;
        const v = try getPropertyChain(realm, obj, rslice);
        const owned = realm.heap.allocateString(wslice) catch return error.OutOfMemory;
        out.set(realm.allocator, owned.bytes, v) catch return error.OutOfMemory;
    }
    setLength(realm, out, len) catch return error.OutOfMemory;
    return heap_mod.taggedObject(out);
}

/// §23.1.3.35 Array.prototype.toSpliced — non-mutating sibling
/// of `splice`. Shares the start/deleteCount clamping with the
/// mutating version but writes into a fresh array.
fn arrayToSpliced(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const obj = try toObjectThis(realm, this_value);
    const len = try intrinsics.clampArrayLengthR(realm, try toLengthOf(realm, obj));
    var start: i64 = if (args.len > 0) toInt(args[0]) else 0;
    if (start < 0) start = @max(len + start, 0);
    start = @min(start, len);
    // §23.1.3.35 steps 8–10:
    //   - start absent → actualDeleteCount = 0
    //   - start present, deleteCount absent → actualDeleteCount = len - start
    //   - both present → clamp ToIntegerOrInfinity(deleteCount) to [0, len-start]
    var delete_count: i64 = if (args.len == 0)
        0
    else if (args.len < 2)
        len - start
    else
        toInt(args[1]);
    if (delete_count < 0) delete_count = 0;
    if (delete_count > len - start) delete_count = len - start;
    const insert_count: i64 = if (args.len > 2) @as(i64, @intCast(args.len - 2)) else 0;
    const new_len = len - delete_count + insert_count;

    const out = realm.heap.allocateObject() catch return error.OutOfMemory;
    out.prototype = realm.intrinsics.array_prototype;
    out.markAsArrayExotic(realm.allocator) catch return error.OutOfMemory;

    // [0..start) — copy from receiver.
    var i: i64 = 0;
    while (i < start) : (i += 1) {
        var rb: [24]u8 = undefined;
        const rslice = std.fmt.bufPrint(&rb, "{d}", .{i}) catch unreachable;
        const owned = realm.heap.allocateString(rslice) catch return error.OutOfMemory;
        const v = try getPropertyChain(realm, obj, rslice);
        out.set(realm.allocator, owned.bytes, v) catch return error.OutOfMemory;
    }
    // [start..start+insert_count) — items.
    var k: i64 = 0;
    while (k < insert_count) : (k += 1) {
        var wb: [24]u8 = undefined;
        const wslice = std.fmt.bufPrint(&wb, "{d}", .{start + k}) catch unreachable;
        const owned = realm.heap.allocateString(wslice) catch return error.OutOfMemory;
        out.set(realm.allocator, owned.bytes, args[2 + @as(usize, @intCast(k))]) catch return error.OutOfMemory;
    }
    // [start+insert_count..new_len) — tail of receiver after the gap.
    var r: i64 = start + delete_count;
    var w: i64 = start + insert_count;
    while (r < len) : ({
        r += 1;
        w += 1;
    }) {
        var rb: [24]u8 = undefined;
        var wb: [24]u8 = undefined;
        const rslice = std.fmt.bufPrint(&rb, "{d}", .{r}) catch unreachable;
        const wslice = std.fmt.bufPrint(&wb, "{d}", .{w}) catch unreachable;
        const owned = realm.heap.allocateString(wslice) catch return error.OutOfMemory;
        const v = try getPropertyChain(realm, obj, rslice);
        out.set(realm.allocator, owned.bytes, v) catch return error.OutOfMemory;
    }
    setLength(realm, out, new_len) catch return error.OutOfMemory;
    return heap_mod.taggedObject(out);
}

/// §23.1.3.39 Array.prototype.with — non-mutating slot-set. Copy
/// the array, then overwrite the requested index. Negative
/// indices count from the end; out-of-range throws RangeError.
fn arrayWith(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const obj = try toObjectThis(realm, this_value);
    const len = try intrinsics.clampArrayLengthR(realm, try toLengthOf(realm, obj));
    const idx_arg = argOr(args, 0, Value.undefined_);
    var idx: i64 = toInt(idx_arg);
    if (idx < 0) idx += len;
    if (idx < 0 or idx >= len) {
        const ex = intrinsics.newRangeError(realm, "invalid index") catch return error.OutOfMemory;
        realm.pending_exception = ex;
        return error.NativeThrew;
    }
    const value = argOr(args, 1, Value.undefined_);
    const out = realm.heap.allocateObject() catch return error.OutOfMemory;
    out.prototype = realm.intrinsics.array_prototype;
    out.markAsArrayExotic(realm.allocator) catch return error.OutOfMemory;
    var i: i64 = 0;
    while (i < len) : (i += 1) {
        var rb: [24]u8 = undefined;
        const rslice = std.fmt.bufPrint(&rb, "{d}", .{i}) catch unreachable;
        const v = if (i == idx) value else try getPropertyChain(realm, obj, rslice);
        const owned = realm.heap.allocateString(rslice) catch return error.OutOfMemory;
        out.set(realm.allocator, owned.bytes, v) catch return error.OutOfMemory;
    }
    setLength(realm, out, len) catch return error.OutOfMemory;
    return heap_mod.taggedObject(out);
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
    const obj = try toObjectThis(realm, this_value);
    // §23.1.3.26 — use LengthOfArrayLike so the TA `length`
    // accessor returns the live element count (length-tracking
    // views over a resizable buffer).
    const len = try intrinsics.clampArrayLengthR(realm, try toLengthOf(realm, obj));
    var i: i64 = 0;
    const half = @divFloor(len, 2);
    while (i < half) : (i += 1) {
        var ibuf: [24]u8 = undefined;
        var jbuf: [24]u8 = undefined;
        const islice = std.fmt.bufPrint(&ibuf, "{d}", .{i}) catch unreachable;
        const j = len - 1 - i;
        const jslice = std.fmt.bufPrint(&jbuf, "{d}", .{j}) catch unreachable;
        // Route reads through `getPropertyChain` so TypedArray
        // numeric-index Get fires (else `obj.get` misses the
        // backing buffer; `Array.prototype.reverse.call(ta)` then
        // sees undefined at every index).
        const a = try getPropertyChain(realm, obj, islice);
        const b = try getPropertyChain(realm, obj, jslice);
        const owned_i = realm.heap.allocateString(islice) catch return error.OutOfMemory;
        const owned_j = realm.heap.allocateString(jslice) catch return error.OutOfMemory;
        obj.set(realm.allocator, owned_i.bytes, b) catch return error.OutOfMemory;
        obj.set(realm.allocator, owned_j.bytes, a) catch return error.OutOfMemory;
    }
    return this_value;
}

fn arrayShift(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    // §23.1.3.25 Array.prototype.shift:
    //   1. O = ToObject(this); 2. len = ? ToLength(? Get(O, "length"))
    //   3. If len = 0: ? Set(O, "length", 0, true); return undefined
    //   4. first = ? Get(O, "0")
    //   5. For k from 1 to len-1: move O[k] to O[k-1] using
    //      HasProperty + (Get + Set or DeletePropertyOrThrow)
    //   6. ? DeletePropertyOrThrow(O, ToString(len - 1))
    //   7. ? Set(O, "length", len - 1, true); return first
    _ = args;
    const obj = try toObjectThis(realm, this_value);
    var len = try toLengthOf(realm, obj);
    const safe_max: i64 = (1 << 53) - 1;
    if (len > safe_max) len = safe_max;
    if (len <= 0) {
        try setLengthOrThrow(realm, obj, 0);
        return Value.undefined_;
    }
    const head = try getPropertyChain(realm, obj, "0");
    var k: i64 = 1;
    while (k < len) : (k += 1) {
        var fbuf: [24]u8 = undefined;
        var tbuf: [24]u8 = undefined;
        const fslice = std.fmt.bufPrint(&fbuf, "{d}", .{k}) catch unreachable;
        const tslice = std.fmt.bufPrint(&tbuf, "{d}", .{k - 1}) catch unreachable;
        // §23.1.3.25 step 5.d / 5.e — HasProperty(O, from)
        // distinguishes "real entry" from "hole" so a sparse
        // shift collapses holes properly.
        if (obj.hasProperty(fslice)) {
            const v = try getPropertyChain(realm, obj, fslice);
            const owned = realm.heap.allocateString(tslice) catch return error.OutOfMemory;
            try setOrThrow(realm, obj, owned.bytes, v);
        } else {
            try deletePropertyOrThrow(realm, obj, tslice);
        }
    }
    {
        var lbuf: [24]u8 = undefined;
        const lslice = std.fmt.bufPrint(&lbuf, "{d}", .{len - 1}) catch unreachable;
        try deletePropertyOrThrow(realm, obj, lslice);
    }
    try setLengthOrThrow(realm, obj, len - 1);
    return head;
}

fn arrayUnshift(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    // §23.1.3.32 Array.prototype.unshift:
    //   1. O = ToObject(this); 2. len = ? ToLength(? Get(O, "length"))
    //   3. argCount = items.length
    //   4. If argCount > 0:
    //      a. If len + argCount > 2^53-1 throw TypeError
    //      b. shift O[k-1] -> O[k+argCount-1] for k = len-1 downto 0,
    //         using HasProperty + (Set or DeletePropertyOrThrow)
    //      c. ? Set(O, ToString(j), items[j], true) for j in [0, argCount)
    //   5. ? Set(O, "length", len + argCount, true)
    const obj = try toObjectThis(realm, this_value);
    var len = try toLengthOf(realm, obj);
    const safe_max: i64 = (1 << 53) - 1;
    if (len > safe_max) len = safe_max;
    const argc: i64 = @intCast(args.len);
    if (argc > 0) {
        if (len > safe_max - argc) {
            return throwTypeError(realm, "Unshifted length would exceed maximum length");
        }
        // Shift right from the top so we don't overwrite source slots.
        var i: i64 = len;
        while (i > 0) : (i -= 1) {
            const from = i - 1;
            const to = from + argc;
            var fbuf: [24]u8 = undefined;
            var tbuf: [24]u8 = undefined;
            const fslice = std.fmt.bufPrint(&fbuf, "{d}", .{from}) catch unreachable;
            const tslice = std.fmt.bufPrint(&tbuf, "{d}", .{to}) catch unreachable;
            if (obj.hasProperty(fslice)) {
                const v = try getPropertyChain(realm, obj, fslice);
                const owned = realm.heap.allocateString(tslice) catch return error.OutOfMemory;
                try setOrThrow(realm, obj, owned.bytes, v);
            } else {
                try deletePropertyOrThrow(realm, obj, tslice);
            }
        }
        // Insert new args at indices [0, argCount).
        for (args, 0..) |a, idx| {
            var b: [24]u8 = undefined;
            const slc = std.fmt.bufPrint(&b, "{d}", .{idx}) catch unreachable;
            const owned = realm.heap.allocateString(slc) catch return error.OutOfMemory;
            try setOrThrow(realm, obj, owned.bytes, a);
        }
    }
    const new_len = len + argc;
    try setLengthOrThrow(realm, obj, new_len);
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
        // §6.2.4.4 — the user-supplied callback threw. Pin the
        // thrown value in `realm.pending_exception` so the
        // unwind machinery resurfaces *its* error class /
        // message instead of the generic "native error" filler
        // (test262 inspects `e instanceof Test262Error`, etc.).
        .thrown => |ex| {
            realm.pending_exception = ex;
            return error.NativeThrew;
        },
    }
}

fn arrayForEach(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    // §23.1.3.16 — spec step order is ToObject → LengthOfArrayLike
    // → IsCallable check, so a throwing length getter wins over the
    // callback-not-callable TypeError. Fixture 15.4.4.18-4-11
    // installs `obj.length` with a poisoned `toString` and passes
    // `undefined` as the callback; the test expects the length-
    // coercion throw to propagate, not the IsCallable error.
    const obj = try toObjectThis(realm, this_value);
    const len = try intrinsics.clampArrayLengthR(realm, try toLengthOf(realm, obj));
    const callback = heap_mod.valueAsFunction(argOr(args, 0, Value.undefined_)) orelse return throwTypeError(realm, "Array.prototype.forEach callback must be a function");
    const this_arg = argOr(args, 1, Value.undefined_);
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
    // §23.1.3.19 — spec step order is ToObject → LengthOfArrayLike
    // → callback IsCallable check, so a throwing length wins.
    const obj = try toObjectThis(realm, this_value);
    const len = try intrinsics.clampArrayLengthR(realm, try toLengthOf(realm, obj));
    const callback = heap_mod.valueAsFunction(argOr(args, 0, Value.undefined_)) orelse return throwTypeError(realm, "Array.prototype.map callback must be a function");
    const this_arg = argOr(args, 1, Value.undefined_);

    // §23.1.3.20 step 5 — ArraySpeciesCreate(O, len) so `@@species`
    // on the receiver's constructor controls the result type.
    const out_v = try arraySpeciesCreate(realm, obj, len);
    const out = heap_mod.valueAsPlainObject(out_v) orelse return throwTypeError(realm, "ArraySpeciesCreate did not return an object");
    var i: i64 = 0;
    while (i < len) : (i += 1) {
        // Cooperative interrupt poll every 1024 elements so a
        // `Array(2**24).map(...)` body can be terminated by a host
        // watchdog or step-budget exhaustion even though no JS
        // opcodes dispatch between callback invocations.
        if ((i & 0x3FF) == 0) try intrinsics.checkInterruptInNative(realm);
        var ibuf: [24]u8 = undefined;
        const islice = std.fmt.bufPrint(&ibuf, "{d}", .{i}) catch unreachable;
        if (!obj.hasProperty(islice)) continue;
        const elem = try getPropertyChain(realm, obj, islice);
        const v = try invokeCallback(realm, callback, this_arg, elem, i, obj);
        const owned = realm.heap.allocateString(islice) catch return error.OutOfMemory;
        out.set(realm.allocator, owned.bytes, v) catch return error.OutOfMemory;
    }
    setLength(realm, out, len) catch return error.OutOfMemory;
    return out_v;
}

fn arrayFilter(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    // §23.1.3.8 spec step order: ToObject → length → IsCallable.
    const obj = try toObjectThis(realm, this_value);
    const len = try intrinsics.clampArrayLengthR(realm, try toLengthOf(realm, obj));
    const callback = heap_mod.valueAsFunction(argOr(args, 0, Value.undefined_)) orelse return throwTypeError(realm, "Array.prototype.filter callback must be a function");
    const this_arg = argOr(args, 1, Value.undefined_);

    // §23.1.3.8 step 5 — ArraySpeciesCreate(O, 0).
    const out_v = try arraySpeciesCreate(realm, obj, 0);
    const out = heap_mod.valueAsPlainObject(out_v) orelse return throwTypeError(realm, "ArraySpeciesCreate did not return an object");
    var i: i64 = 0;
    var write_idx: i64 = 0;
    while (i < len) : (i += 1) {
        if ((i & 0x3FF) == 0) try intrinsics.checkInterruptInNative(realm);
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
    return out_v;
}

fn arrayEvery(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    // §23.1.3.6 spec step order: ToObject → length → IsCallable.
    const obj = try toObjectThis(realm, this_value);
    const len = try intrinsics.clampArrayLengthR(realm, try toLengthOf(realm, obj));
    const callback = heap_mod.valueAsFunction(argOr(args, 0, Value.undefined_)) orelse return throwTypeError(realm, "Array.prototype.every callback must be a function");
    const this_arg = argOr(args, 1, Value.undefined_);
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
    const len = try intrinsics.clampArrayLengthR(realm, try toLengthOf(realm, obj));
    const callback = heap_mod.valueAsFunction(argOr(args, 0, Value.undefined_)) orelse return throwTypeError(realm, "Array.prototype.some callback must be a function");
    const this_arg = argOr(args, 1, Value.undefined_);
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
    const len = try intrinsics.clampArrayLengthR(realm, try toLengthOf(realm, obj));
    const callback = heap_mod.valueAsFunction(argOr(args, 0, Value.undefined_)) orelse return throwTypeError(realm, "Array.prototype.find callback must be a function");
    const this_arg = argOr(args, 1, Value.undefined_);
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
    const len = try intrinsics.clampArrayLengthR(realm, try toLengthOf(realm, obj));
    const callback = heap_mod.valueAsFunction(argOr(args, 0, Value.undefined_)) orelse return throwTypeError(realm, "Array.prototype.findIndex callback must be a function");
    const this_arg = argOr(args, 1, Value.undefined_);
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
    const len = try intrinsics.clampArrayLengthR(realm, try toLengthOf(realm, obj));
    const callback = heap_mod.valueAsFunction(argOr(args, 0, Value.undefined_)) orelse return throwTypeError(realm, "Array.prototype.reduce callback must be a function");
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
        if ((i & 0x3FF) == 0) try intrinsics.checkInterruptInNative(realm);
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

// ── §23.1.2.1.1 Array.fromAsync ─────────────────────────────────────────────
//
// State machine. `Array.fromAsync(asyncItems, mapfn, thisArg)` returns
// a Promise whose driver lives in a `JSObject` keyed with a handful of
// well-known slots. The recursive "loop" is a chain of `.then` reactions
// that re-enter the driver per step — every transition defers via a
// microtask, satisfying AGENTS.md's microtask-discipline rule.
//
// Two iteration shapes:
//   1. **Iterator path** — `@@asyncIterator` callable, OR
//      `@@iterator` callable (sync wrapped via per-step `await`).
//      Driver: call `iter.next()`, await the result, read `done/value`,
//      optionally map, write to the array, loop.
//   2. **Array-like path** — neither symbol present (or both undefined/null).
//      Driver: `len = ToLength(items.length)`, then for `k = 0..len`
//      read `items[k]`, await it, optionally map, write, loop.
//
// Errors anywhere reject the result capability and run IteratorClose
// when an iterator is open (§7.4.11 AsyncIteratorClose — `iter.return()`
// is invoked but we don't await it; a thrown `return` is swallowed since
// we're already unwinding).

const k_fa_cap_resolve = "__cynic_fa_cap_resolve__";
const k_fa_cap_reject = "__cynic_fa_cap_reject__";
const k_fa_array = "__cynic_fa_array__";
const k_fa_index = "__cynic_fa_index__";
const k_fa_length = "__cynic_fa_length__";
const k_fa_iter = "__cynic_fa_iter__";
const k_fa_next_fn = "__cynic_fa_next_fn__";
const k_fa_mapfn = "__cynic_fa_mapfn__";
const k_fa_this_arg = "__cynic_fa_this_arg__";
const k_fa_items = "__cynic_fa_items__";
const k_fa_mode = "__cynic_fa_mode__"; // 0 = array-like, 1 = iterator

const promise_mod = @import("promise.zig");

/// `Array.fromAsync(asyncItems, mapfn?, thisArg?)`. Returns a Promise.
/// §23.1.2.1.1 (Stage 4 proposal — Igalia / TC39).
fn arrayFromAsync(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    // §23.1.2.1.1 step 1 — IfAbruptRejectPromise pattern. Allocate
    // the result capability up front so any synchronous abrupt
    // becomes a rejection rather than a throw.
    const builtin_promise = heap_mod.valueAsFunction(realm.globals.get("Promise") orelse Value.undefined_) orelse return throwTypeError(realm, "Array.fromAsync: %Promise% missing");
    const cap = try promise_mod.newPromiseCapability(realm, builtin_promise);

    const items = argOr(args, 0, Value.undefined_);
    const mapfn_v = argOr(args, 1, Value.undefined_);
    const this_arg = argOr(args, 2, Value.undefined_);

    // step 2.b — `IsCallable(mapfn)` check.
    if (!mapfn_v.isUndefined()) {
        if (heap_mod.valueAsFunction(mapfn_v) == null) {
            return rejectWithTypeError(realm, cap, "Array.fromAsync: mapfn is not a function");
        }
    }

    // §23.1.2.1.1 step 3.e / 3.k.iv — when `this` is a constructor
    // (the receiver of `Array.fromAsync.call(C, …)`), the spec
    // allocates the result via `Construct(C)` (iterator path) or
    // `Construct(C, « 𝔽(len) »)` (array-like path). We don't yet
    // know which path applies, so defer the array-like construction
    // until step 4; the iterator path uses `Construct(C)` below.
    const this_ctor: ?*JSFunction = blk: {
        const f = heap_mod.valueAsFunction(this_value) orelse break :blk null;
        if (!f.has_construct or f.is_arrow) break :blk null;
        break :blk f;
    };

    // Allocate the result array + driver state.
    const out = realm.heap.allocateObject() catch return error.OutOfMemory;
    out.prototype = realm.intrinsics.array_prototype;
    out.markAsArrayExotic(realm.allocator) catch return error.OutOfMemory;

    const state = realm.heap.allocateObject() catch return error.OutOfMemory;
    state.prototype = realm.intrinsics.object_prototype;
    state.set(realm.allocator, k_fa_cap_resolve, heap_mod.taggedFunction(cap.resolve)) catch return error.OutOfMemory;
    state.set(realm.allocator, k_fa_cap_reject, heap_mod.taggedFunction(cap.reject)) catch return error.OutOfMemory;
    state.set(realm.allocator, k_fa_array, heap_mod.taggedObject(out)) catch return error.OutOfMemory;
    state.set(realm.allocator, k_fa_index, Value.fromInt32(0)) catch return error.OutOfMemory;
    state.set(realm.allocator, k_fa_mapfn, mapfn_v) catch return error.OutOfMemory;
    state.set(realm.allocator, k_fa_this_arg, this_arg) catch return error.OutOfMemory;
    state.set(realm.allocator, k_fa_items, items) catch return error.OutOfMemory;

    // step 3 — GetMethod(asyncItems, @@asyncIterator). Per §7.3.10
    // GetMethod, if the property is null/undefined return undefined
    // (no method); if non-callable, throw TypeError. We then fall
    // back to @@iterator with the same semantics. A non-object
    // `asyncItems` carries no symbol-keyed slots, so it skips both
    // iterator branches and lands in the array-like ToObject path.
    var iter_method_v: Value = Value.undefined_;
    var sync_iter_method_v: Value = Value.undefined_;
    if (heap_mod.valueAsPlainObject(items)) |obj| {
        iter_method_v = getPropertyChain(realm, obj, "@@asyncIterator") catch {
            return rejectPendingException(realm, cap);
        };
        if (iter_method_v.isUndefined() or iter_method_v.isNull()) {
            iter_method_v = Value.undefined_;
            sync_iter_method_v = getPropertyChain(realm, obj, "@@iterator") catch {
                return rejectPendingException(realm, cap);
            };
            if (sync_iter_method_v.isUndefined() or sync_iter_method_v.isNull()) {
                sync_iter_method_v = Value.undefined_;
            } else if (heap_mod.valueAsFunction(sync_iter_method_v) == null) {
                return rejectWithTypeError(realm, cap, "Array.fromAsync: @@iterator is not callable");
            }
        } else if (heap_mod.valueAsFunction(iter_method_v) == null) {
            return rejectWithTypeError(realm, cap, "Array.fromAsync: @@asyncIterator is not callable");
        }
    }

    // Iterator path?
    if (heap_mod.valueAsFunction(iter_method_v)) |async_iter_fn| {
        // §23.1.2.1.1 step 3.e — `IsConstructor(C)` → `Construct(C)`.
        if (this_ctor) |c| {
            const ctor_v = constructForFromAsync(realm, c, &.{}) catch {
                return rejectPendingException(realm, cap);
            };
            state.set(realm.allocator, k_fa_array, ctor_v) catch return error.OutOfMemory;
        }
        const iter_outcome = interpreter.callJSFunction(realm.allocator, realm, async_iter_fn, items, &.{}) catch {
            return rejectPendingException(realm, cap);
        };
        const iter_v = switch (iter_outcome) {
            .value, .yielded => |v| v,
            .thrown => |ex| return rejectWithValue(realm, cap, ex),
        };
        const iter_obj = heap_mod.valueAsPlainObject(iter_v) orelse {
            return rejectWithTypeError(realm, cap, "Array.fromAsync: @@asyncIterator did not return an object");
        };
        const next_v = getPropertyChain(realm, iter_obj, "next") catch {
            return rejectPendingException(realm, cap);
        };
        const next_fn = heap_mod.valueAsFunction(next_v) orelse {
            return rejectWithTypeError(realm, cap, "Array.fromAsync: async iterator missing callable 'next'");
        };
        state.set(realm.allocator, k_fa_iter, iter_v) catch return error.OutOfMemory;
        state.set(realm.allocator, k_fa_next_fn, heap_mod.taggedFunction(next_fn)) catch return error.OutOfMemory;
        state.set(realm.allocator, k_fa_mode, Value.fromInt32(1)) catch return error.OutOfMemory;
        fromAsyncIterStep(realm, state) catch {
            return rejectPendingException(realm, cap);
        };
        return cap.promise;
    }

    if (heap_mod.valueAsFunction(sync_iter_method_v)) |sync_iter_fn| {
        if (this_ctor) |c| {
            const ctor_v = constructForFromAsync(realm, c, &.{}) catch {
                return rejectPendingException(realm, cap);
            };
            state.set(realm.allocator, k_fa_array, ctor_v) catch return error.OutOfMemory;
        }
        // step 3.h — sync `@@iterator` fallback. Per spec, wrap in
        // %AsyncFromSyncIteratorPrototype%. Cynic shortcut: drive the
        // sync iterator directly and `awaitAndThen` no-ops on non-
        // promise values, which matches the observable behavior for
        // the simple fixtures (sync iterator yielding non-promise
        // values).
        const iter_outcome = interpreter.callJSFunction(realm.allocator, realm, sync_iter_fn, items, &.{}) catch {
            return rejectPendingException(realm, cap);
        };
        const iter_v = switch (iter_outcome) {
            .value, .yielded => |v| v,
            .thrown => |ex| return rejectWithValue(realm, cap, ex),
        };
        const iter_obj = heap_mod.valueAsPlainObject(iter_v) orelse {
            return rejectWithTypeError(realm, cap, "Array.fromAsync: @@iterator did not return an object");
        };
        const next_v = getPropertyChain(realm, iter_obj, "next") catch {
            return rejectPendingException(realm, cap);
        };
        const next_fn = heap_mod.valueAsFunction(next_v) orelse {
            return rejectWithTypeError(realm, cap, "Array.fromAsync: iterator missing callable 'next'");
        };
        state.set(realm.allocator, k_fa_iter, iter_v) catch return error.OutOfMemory;
        state.set(realm.allocator, k_fa_next_fn, heap_mod.taggedFunction(next_fn)) catch return error.OutOfMemory;
        state.set(realm.allocator, k_fa_mode, Value.fromInt32(1)) catch return error.OutOfMemory;
        fromAsyncIterStep(realm, state) catch {
            return rejectPendingException(realm, cap);
        };
        return cap.promise;
    }

    // step 4 — array-like fallback. ToObject + ToLength.
    // §7.1.18 ToObject autoboxes every primitive except null /
    // undefined; route through `toObjectThis` so Symbol / Number /
    // Boolean / BigInt items pick up the inherited prototype walk
    // (a `Symbol.prototype.length` / `[0]` augmentation observably
    // wraps via the Symbol wrapper). Null / undefined remain a
    // TypeError rejection.
    if (items.isNull() or items.isUndefined()) {
        return rejectWithTypeError(realm, cap, "Array.fromAsync: cannot convert null or undefined to object");
    }
    const items_obj = blk: {
        if (heap_mod.valueAsPlainObject(items)) |o| break :blk o;
        break :blk intrinsics.toObjectThis(realm, items) catch {
            return rejectPendingException(realm, cap);
        };
    };
    state.set(realm.allocator, k_fa_items, heap_mod.taggedObject(items_obj)) catch return error.OutOfMemory;

    const raw_len = toLengthOf(realm, items_obj) catch {
        return rejectPendingException(realm, cap);
    };
    const len = intrinsics.clampArrayLengthR(realm, raw_len) catch {
        return rejectPendingException(realm, cap);
    };
    state.set(realm.allocator, k_fa_length, numberFromI64(len)) catch return error.OutOfMemory;
    state.set(realm.allocator, k_fa_mode, Value.fromInt32(0)) catch return error.OutOfMemory;

    // §23.1.2.1.1 step 3.k.iv — `IsConstructor(C)` → `Construct(C, « 𝔽(len) »)`.
    if (this_ctor) |c| {
        const ctor_args = [_]Value{numberFromI64(len)};
        const ctor_v = constructForFromAsync(realm, c, &ctor_args) catch {
            return rejectPendingException(realm, cap);
        };
        state.set(realm.allocator, k_fa_array, ctor_v) catch return error.OutOfMemory;
    }

    fromAsyncArrayLikeStep(realm, state) catch {
        return rejectPendingException(realm, cap);
    };
    return cap.promise;
}

/// §7.3.14 Construct(F, args) — invoke the constructor with
/// `newTarget = F`. Errors bubble through `realm.pending_exception`
/// so the caller can route them into the result capability.
fn constructForFromAsync(realm: *Realm, ctor: *JSFunction, ctor_args: []const Value) NativeError!Value {
    const outcome = interpreter.constructValue(
        realm.allocator,
        realm,
        heap_mod.taggedFunction(ctor),
        ctor_args,
        heap_mod.taggedFunction(ctor),
    ) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.NativeThrew,
    };
    return switch (outcome) {
        .value, .yielded => |v| v,
        .thrown => |ex| {
            realm.pending_exception = ex;
            return error.NativeThrew;
        },
    };
}

// ── Capability helpers ──────────────────────────────────────────────────────

fn rejectWithTypeError(realm: *Realm, cap: promise_mod.PromiseCapability, msg: []const u8) NativeError!Value {
    const ex = intrinsics.newTypeError(realm, msg) catch return error.OutOfMemory;
    return rejectWithValue(realm, cap, ex);
}

fn rejectPendingException(realm: *Realm, cap: promise_mod.PromiseCapability) NativeError!Value {
    const ex = realm.pending_exception orelse Value.undefined_;
    realm.pending_exception = null;
    return rejectWithValue(realm, cap, ex);
}

fn rejectWithValue(realm: *Realm, cap: promise_mod.PromiseCapability, value: Value) NativeError!Value {
    _ = promise_mod.capabilityReject(realm, cap, value) catch {};
    return cap.promise;
}

// ── awaitAndThen: schedule a `.then(onResolve, onReject)` on a value ───────

/// Mirrors `Promise.resolve(value).then(onResolve, onReject)` but bypasses
/// the user-observable `.then` lookup — Array.fromAsync's spec text uses
/// the abstract `Await` op which always routes through the built-in
/// reaction machinery. Non-Promise values get wrapped via the spec's
/// resolve function; thenables go through the standard resolve path.
fn awaitAndThen(
    realm: *Realm,
    value: Value,
    on_resolve: *JSFunction,
    on_reject: *JSFunction,
) NativeError!void {
    var source: *JSObject = undefined;
    if (heap_mod.valueAsPlainObject(value)) |obj| {
        if (obj.isPromise()) {
            source = obj;
        } else {
            source = try wrapValueInPromise(realm, value);
        }
    } else {
        source = try wrapValueInPromise(realm, value);
    }

    const result_promise = promise_mod.allocatePromiseFor(realm, null, .pending, Value.undefined_) catch return error.OutOfMemory;
    const on_resolve_v = heap_mod.taggedFunction(on_resolve);
    const on_reject_v = heap_mod.taggedFunction(on_reject);
    switch (source.promise_state) {
        .fulfilled => realm.enqueuePromiseReaction(on_resolve_v, source.promise_value, result_promise, false) catch return error.OutOfMemory,
        .rejected => realm.enqueuePromiseReaction(on_reject_v, source.promise_value, result_promise, true) catch return error.OutOfMemory,
        else => source.promise_reactions.append(realm.allocator, .{
            .on_fulfilled = on_resolve_v,
            .on_rejected = on_reject_v,
            .result_promise = result_promise,
        }) catch return error.OutOfMemory,
    }
}

fn wrapValueInPromise(realm: *Realm, value: Value) NativeError!*JSObject {
    const wrap_v = promise_mod.allocatePromiseFor(realm, null, .pending, Value.undefined_) catch return error.OutOfMemory;
    const wrap = heap_mod.valueAsPlainObject(wrap_v).?;
    const args = [_]Value{value};
    _ = promise_mod.promiseResolveImplExported(realm, heap_mod.taggedObject(wrap), &args) catch return error.OutOfMemory;
    return wrap;
}

// ── Bound-callback helpers ──────────────────────────────────────────────────

fn makeBoundCb(realm: *Realm, impl: *const fn (*Realm, Value, []const Value) NativeError!Value, state: *JSObject) NativeError!*JSFunction {
    const impl_fn = realm.heap.allocateFunctionNative(impl, 1, "") catch return error.OutOfMemory;
    impl_fn.proto = realm.intrinsics.function_prototype;
    impl_fn.has_construct = false;
    const bound = realm.heap.allocateFunctionNative(promise_mod.boundResolveTrampolineExported, 1, "") catch return error.OutOfMemory;
    bound.proto = realm.intrinsics.function_prototype;
    bound.has_construct = false;
    bound.bound_target = impl_fn;
    bound.bound_this = heap_mod.taggedObject(state);
    return bound;
}

// ── Iterator-path driver ────────────────────────────────────────────────────

fn fromAsyncIterStep(realm: *Realm, state: *JSObject) NativeError!void {
    const iter_v = state.get(k_fa_iter);
    const next_fn = heap_mod.valueAsFunction(state.get(k_fa_next_fn)) orelse return;
    const next_outcome = interpreter.callJSFunction(realm.allocator, realm, next_fn, iter_v, &.{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            _ = try rejectFromState(realm, state);
            return;
        },
    };
    const next_v = switch (next_outcome) {
        .value, .yielded => |v| v,
        .thrown => |ex| {
            realm.pending_exception = ex;
            _ = try rejectFromState(realm, state);
            return;
        },
    };
    const on_res = try makeBoundCb(realm, fromAsyncIterOnNextResult, state);
    const on_rej = try makeBoundCb(realm, fromAsyncIterOnNextReject, state);
    try awaitAndThen(realm, next_v, on_res, on_rej);
}

fn fromAsyncIterOnNextResult(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const state = heap_mod.valueAsPlainObject(this_value) orelse return Value.undefined_;
    const result = argOr(args, 0, Value.undefined_);
    const result_obj = heap_mod.valueAsPlainObject(result) orelse {
        return rejectWithTypeErrorFromState(realm, state, "Array.fromAsync: iterator next() did not return an object");
    };
    const done_v = getPropertyChain(realm, result_obj, "done") catch {
        return rejectFromState(realm, state);
    };
    const value_v = getPropertyChain(realm, result_obj, "value") catch {
        return rejectFromState(realm, state);
    };
    if (intrinsics.toBoolean(done_v)) {
        const out = heap_mod.valueAsPlainObject(state.get(k_fa_array)) orelse return Value.undefined_;
        const k = state.get(k_fa_index).asInt32();
        setLength(realm, out, k) catch return error.OutOfMemory;
        return resolveFromState(realm, state, heap_mod.taggedObject(out));
    }

    // Await the raw value (per spec the mapfn input is awaited too).
    const on_res = try makeBoundCb(realm, fromAsyncIterOnValueAwaited, state);
    const on_rej = try makeBoundCb(realm, fromAsyncIterOnNextReject, state);
    try awaitAndThen(realm, value_v, on_res, on_rej);
    return Value.undefined_;
}

fn fromAsyncIterOnValueAwaited(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const state = heap_mod.valueAsPlainObject(this_value) orelse return Value.undefined_;
    const value = argOr(args, 0, Value.undefined_);
    const mapfn_v = state.get(k_fa_mapfn);

    if (heap_mod.valueAsFunction(mapfn_v)) |mapfn| {
        const k = state.get(k_fa_index).asInt32();
        const this_arg = state.get(k_fa_this_arg);
        const cb_args = [_]Value{ value, Value.fromInt32(k) };
        const mapped_outcome = interpreter.callJSFunction(realm.allocator, realm, mapfn, this_arg, &cb_args) catch {
            // mapfn threw — IfAbruptCloseAsyncIterator.
            return closeIterAndReject(realm, state);
        };
        const mapped = switch (mapped_outcome) {
            .value, .yielded => |v| v,
            .thrown => |ex| {
                realm.pending_exception = ex;
                return closeIterAndReject(realm, state);
            },
        };
        const on_res = try makeBoundCb(realm, fromAsyncIterOnMappedAwaited, state);
        const on_rej = try makeBoundCb(realm, fromAsyncIterOnMappedReject, state);
        try awaitAndThen(realm, mapped, on_res, on_rej);
        return Value.undefined_;
    }

    return appendAndStepIter(realm, state, value);
}

fn fromAsyncIterOnMappedAwaited(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const state = heap_mod.valueAsPlainObject(this_value) orelse return Value.undefined_;
    const value = argOr(args, 0, Value.undefined_);
    return appendAndStepIter(realm, state, value);
}

fn fromAsyncIterOnMappedReject(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const state = heap_mod.valueAsPlainObject(this_value) orelse return Value.undefined_;
    const reason = argOr(args, 0, Value.undefined_);
    realm.pending_exception = reason;
    return closeIterAndReject(realm, state);
}

/// §7.3.7 CreateDataPropertyOrThrow — used by Array.fromAsync's
/// per-element write step (§23.1.2.1.1 steps 3.j.ii.8 and
/// 3.k.vii.6, mirrored in 3.l.iii). Unlike `[[Set]]`, this op
/// ignores any inherited setter / writable:false ancestor on the
/// prototype chain and lands the value as an own data property
/// with `{w:T, e:T, c:T}`. It still rejects with TypeError when:
///   - the receiver is not extensible AND has no own slot, or
///   - the existing own property is `configurable: false` (any
///     non-default flag conflict implies a non-configurable
///     redefine per §10.1.6.3 step 4).
/// Returns `error.NativeThrew` with `realm.pending_exception`
/// set on the reject path so the caller can route the failure
/// into its promise / iterator-close machinery.
fn createDataPropertyOrThrow(
    realm: *Realm,
    obj: *JSObject,
    key: []const u8,
    value: Value,
) NativeError!void {
    const ObjMod = @import("../object.zig");
    const had_own = obj.hasOwn(key);
    if (!had_own) {
        if (!obj.extensible) {
            return throwTypeError(realm, "Array.fromAsync: cannot define property on non-extensible object");
        }
    } else {
        const cur = obj.flagsFor(key);
        // §10.1.6.3 step 4 — redefining with `{w:T,e:T,c:T}` over
        // a non-configurable own property fails whenever any of
        // the current flags differs (configurable:false alone is
        // sufficient; configurable:true with writable:false /
        // enumerable:false is still allowed because the redefine
        // can flip them back on).
        if (!cur.configurable) {
            return throwTypeError(realm, "Array.fromAsync: cannot redefine non-configurable property");
        }
    }
    obj.setWithFlags(realm.allocator, key, value, ObjMod.PropertyFlags.default) catch return error.OutOfMemory;
}

fn appendAndStepIter(realm: *Realm, state: *JSObject, value: Value) NativeError!Value {
    const out = heap_mod.valueAsPlainObject(state.get(k_fa_array)) orelse return Value.undefined_;
    const k = state.get(k_fa_index).asInt32();
    var ibuf: [24]u8 = undefined;
    const islice = std.fmt.bufPrint(&ibuf, "{d}", .{k}) catch unreachable;
    const owned = realm.heap.allocateString(islice) catch return error.OutOfMemory;
    // §23.1.2.1.1 step 3.j.ii.8 — `CreateDataPropertyOrThrow(A, Pk,
    // mappedValue)`. Abrupt completion routes through
    // `closeIterAndReject` (step 9 — `AsyncIteratorClose`).
    createDataPropertyOrThrow(realm, out, owned.bytes, value) catch {
        return closeIterAndReject(realm, state);
    };
    state.set(realm.allocator, k_fa_index, Value.fromInt32(k + 1)) catch return error.OutOfMemory;
    fromAsyncIterStep(realm, state) catch {
        return rejectFromState(realm, state);
    };
    return Value.undefined_;
}

fn fromAsyncIterOnNextReject(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const state = heap_mod.valueAsPlainObject(this_value) orelse return Value.undefined_;
    const reason = argOr(args, 0, Value.undefined_);
    return rejectFromStateWithReason(realm, state, reason);
}

fn closeIterAndReject(realm: *Realm, state: *JSObject) NativeError!Value {
    const iter_v = state.get(k_fa_iter);
    if (heap_mod.valueAsPlainObject(iter_v)) |obj| {
        const ret_v = getPropertyChain(realm, obj, "return") catch Value.undefined_;
        if (heap_mod.valueAsFunction(ret_v)) |ret_fn| {
            const outcome = interpreter.callJSFunction(realm.allocator, realm, ret_fn, iter_v, &.{}) catch null;
            _ = outcome;
            // §7.4.11 — original abrupt wins; clear any thrown
            // exception from `return` itself.
        }
    }
    return rejectFromState(realm, state);
}

// ── Array-like driver ──────────────────────────────────────────────────────

fn fromAsyncArrayLikeStep(realm: *Realm, state: *JSObject) NativeError!void {
    const k = state.get(k_fa_index).asInt32();
    const len_v = state.get(k_fa_length);
    const len: i64 = if (len_v.isInt32()) len_v.asInt32() else if (len_v.isDouble()) @intFromFloat(len_v.asDouble()) else 0;

    if (@as(i64, k) >= len) {
        const out = heap_mod.valueAsPlainObject(state.get(k_fa_array)) orelse return;
        setLength(realm, out, len) catch return error.OutOfMemory;
        _ = resolveFromState(realm, state, heap_mod.taggedObject(out)) catch {};
        return;
    }

    const items = heap_mod.valueAsPlainObject(state.get(k_fa_items)) orelse return;
    var ibuf: [24]u8 = undefined;
    const islice = std.fmt.bufPrint(&ibuf, "{d}", .{k}) catch unreachable;
    const raw = getPropertyChain(realm, items, islice) catch {
        _ = rejectFromState(realm, state) catch {};
        return;
    };

    const on_res = try makeBoundCb(realm, fromAsyncArrayLikeOnAwaited, state);
    const on_rej = try makeBoundCb(realm, fromAsyncArrayLikeOnReject, state);
    try awaitAndThen(realm, raw, on_res, on_rej);
}

fn fromAsyncArrayLikeOnAwaited(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const state = heap_mod.valueAsPlainObject(this_value) orelse return Value.undefined_;
    const value = argOr(args, 0, Value.undefined_);
    const mapfn_v = state.get(k_fa_mapfn);

    if (heap_mod.valueAsFunction(mapfn_v)) |mapfn| {
        const k = state.get(k_fa_index).asInt32();
        const this_arg = state.get(k_fa_this_arg);
        const cb_args = [_]Value{ value, Value.fromInt32(k) };
        const mapped_outcome = interpreter.callJSFunction(realm.allocator, realm, mapfn, this_arg, &cb_args) catch {
            return rejectFromState(realm, state);
        };
        const mapped = switch (mapped_outcome) {
            .value, .yielded => |v| v,
            .thrown => |ex| return rejectFromStateWithReason(realm, state, ex),
        };
        const on_res = try makeBoundCb(realm, fromAsyncArrayLikeOnMapped, state);
        const on_rej = try makeBoundCb(realm, fromAsyncArrayLikeOnReject, state);
        try awaitAndThen(realm, mapped, on_res, on_rej);
        return Value.undefined_;
    }

    return appendAndStepArrayLike(realm, state, value);
}

fn fromAsyncArrayLikeOnMapped(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const state = heap_mod.valueAsPlainObject(this_value) orelse return Value.undefined_;
    const value = argOr(args, 0, Value.undefined_);
    return appendAndStepArrayLike(realm, state, value);
}

fn fromAsyncArrayLikeOnReject(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const state = heap_mod.valueAsPlainObject(this_value) orelse return Value.undefined_;
    const reason = argOr(args, 0, Value.undefined_);
    return rejectFromStateWithReason(realm, state, reason);
}

fn appendAndStepArrayLike(realm: *Realm, state: *JSObject, value: Value) NativeError!Value {
    const out = heap_mod.valueAsPlainObject(state.get(k_fa_array)) orelse return Value.undefined_;
    const k = state.get(k_fa_index).asInt32();
    var ibuf: [24]u8 = undefined;
    const islice = std.fmt.bufPrint(&ibuf, "{d}", .{k}) catch unreachable;
    const owned = realm.heap.allocateString(islice) catch return error.OutOfMemory;
    // §23.1.2.1.1 step 3.l.iii — `CreateDataPropertyOrThrow(A, Pk,
    // mappedValue)`. There's no iterator to close on the array-like
    // path; an abrupt completion just rejects the outer promise.
    createDataPropertyOrThrow(realm, out, owned.bytes, value) catch {
        return rejectFromState(realm, state);
    };
    state.set(realm.allocator, k_fa_index, Value.fromInt32(k + 1)) catch return error.OutOfMemory;
    fromAsyncArrayLikeStep(realm, state) catch {
        return rejectFromState(realm, state);
    };
    return Value.undefined_;
}

// ── Settlement helpers (state → capability) ────────────────────────────────

fn resolveFromState(realm: *Realm, state: *JSObject, value: Value) NativeError!Value {
    const resolve_fn = heap_mod.valueAsFunction(state.get(k_fa_cap_resolve)) orelse return Value.undefined_;
    const outcome = interpreter.callJSFunction(realm.allocator, realm, resolve_fn, Value.undefined_, &.{value}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return Value.undefined_,
    };
    _ = outcome;
    return Value.undefined_;
}

fn rejectFromState(realm: *Realm, state: *JSObject) NativeError!Value {
    const reason = realm.pending_exception orelse Value.undefined_;
    realm.pending_exception = null;
    return rejectFromStateWithReason(realm, state, reason);
}

fn rejectFromStateWithReason(realm: *Realm, state: *JSObject, reason: Value) NativeError!Value {
    const reject_fn = heap_mod.valueAsFunction(state.get(k_fa_cap_reject)) orelse return Value.undefined_;
    const outcome = interpreter.callJSFunction(realm.allocator, realm, reject_fn, Value.undefined_, &.{reason}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return Value.undefined_,
    };
    _ = outcome;
    return Value.undefined_;
}

fn rejectWithTypeErrorFromState(realm: *Realm, state: *JSObject, msg: []const u8) NativeError!Value {
    const ex = intrinsics.newTypeError(realm, msg) catch return error.OutOfMemory;
    return rejectFromStateWithReason(realm, state, ex);
}
