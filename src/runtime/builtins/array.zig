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
const lantern = @import("../lantern/interpreter.zig");
const utf16 = @import("../utf16.zig");

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
const callJSFunction = lantern.callJSFunction;
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
        try installNativeMethodOnProto(realm, arr_proto, "toString", arrayToString, 0);
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
        // §23.1.3.34 — the initial value of `@@iterator` IS the
        // `values` function (same object identity), not a parallel
        // native. Alias the slot so `Array.prototype[Symbol.iterator]
        // === Array.prototype.values`.
        const values_v = arr_proto.get("values");
        arr_proto.setWithFlags(realm.allocator, "@@iterator", values_v, .{
            .writable = true,
            .enumerable = false,
            .configurable = true,
        }) catch return error.OutOfMemory;
        // §23.1.3.36 Array.prototype [ @@unscopables ] — a null-
        // prototype object listing the post-ES5 methods to exclude
        // from `with` scopes. The slot itself is
        // `{w:F, e:F, c:T}` per the spec table; the inner data
        // properties are `{w:T, e:T, c:T}`.
        const u = realm.heap.allocateObject() catch return error.OutOfMemory;
        realm.heap.setObjectPrototype(u, null);
        const ObjMod = @import("../object.zig");
        const dflt = ObjMod.PropertyFlags.default;
        const names = [_][]const u8{
            "copyWithin", "entries",       "fill",       "find",     "findIndex",
            // §1.1 of the `array-find-from-last` proposal.
            "findLast",   "findLastIndex", "flat",       "flatMap",  "includes",
            "keys",       "values",
            // `change-array-by-copy` adds these three but
            // intentionally NOT `with`.
                   "toReversed", "toSorted", "toSpliced",
        };
        for (names) |n| {
            u.setWithFlags(realm.allocator, n, Value.true_, dflt) catch return error.OutOfMemory;
        }
        arr_proto.setWithFlags(realm.allocator, "@@unscopables", heap_mod.taggedObject(u), .{
            .writable = false,
            .enumerable = false,
            .configurable = true,
        }) catch return error.OutOfMemory;
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
        // §10.2.9 SetFunctionName step 7 — a getter's name is
        // prefixed with `"get "`. `Object.getOwnPropertyDescriptor
        // (Array, Symbol.species).get.name === "get [Symbol.species]"`.
        const species_getter = try intrinsics.makeNativeFunction(realm, arraySpeciesGetter, 0, "get [Symbol.species]");
        const entry = try arr_ctor.accessors.getOrPut(realm.allocator, "@@species");
        entry.value_ptr.* = .{ .getter = species_getter };
        try arr_ctor.property_flags.put(realm.allocator, "@@species", .{
            .writable = false,
            .enumerable = false,
            .configurable = true,
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
    // §23.1.3.34 step 6 / step 4.b — "thisRealm" is the realm of the
    // running execution context (the Array method's [[Realm]]), and
    // a defaulted ArrayCreate uses that realm's %Array.prototype%.
    // The dispatch loop stamps the executing native's realm into
    // `active_native_fn_realm`; with a shared heap (a ShadowRealm
    // child) it differs from the dispatch `realm`, so resolve the
    // home realm here. In a single realm `home == realm`.
    const home = realm.active_native_fn_realm orelse realm;
    // Step 2 — IsArray(originalArray). Per §7.2.2 step 3, a Proxy
    // unwraps to its target; a revoked proxy throws. Non-array
    // receivers fall through to ArrayCreate (Step 2 → ArrayCreate
    // with the default %Array% intrinsic).
    const is_arr = try isArrayProxyAware(realm, heap_mod.taggedObject(original));
    if (!is_arr) return defaultArrayCreate(home, length);
    // Step 3 — Get(originalArray, "constructor"). Use the Proxy-
    // and accessor-aware path so a poisoned getter or proxy `get`
    // trap propagates per spec (create-proxy.js et al.).
    var ctor_v = try getPropertyAny(realm, heap_mod.taggedObject(original), "constructor");
    // Step 4 — if IsConstructor(C) is true:
    //   a. Let realmC be ? GetFunctionRealm(C).
    //   b. If thisRealm and realmC are not the same Realm Record:
    //      i. If SameValue(C, realmC.[[Intrinsics]].[[%Array%]])
    //         is true, set C to undefined.
    // Without this carve-out a `class Sub extends Array` created in
    // a child realm via `$262.createRealm()` would never produce a
    // child-realm Array — every `Array.prototype.map` call on a
    // cross-realm Array would funnel back through the child Sub
    // and yield the wrong species. The fixture pattern is
    // `built-ins/Array/prototype/<method>/create-species-non-extensible.js`.
    if (heap_mod.valueAsFunction(ctor_v)) |ctor_fn| {
        if (ctor_fn.has_construct and !ctor_fn.is_arrow) {
            if (ctor_fn.getFunctionRealm()) |realm_c| {
                if (realm_c != home) {
                    if (realm_c.globals.get("Array")) |arr_ctor_v| {
                        if (heap_mod.valueAsFunction(arr_ctor_v)) |realm_c_array| {
                            if (realm_c_array == ctor_fn) {
                                ctor_v = Value.undefined_;
                            }
                        }
                    }
                }
            }
        }
    }
    // Step 5 — if C is an Object, set C to ? Get(C, @@species); if
    // null, set C to undefined. `getPropertyChainOnValue` is the
    // §10.1.8 OrdinaryGet for both a plain object and a function,
    // walking the [[Prototype]] chain — so a `class Sub extends Array`
    // resolves the @@species accessor INHERITED from %Array% (returning
    // Sub), not just Sub's own slots. Returns null only when C is a
    // primitive (not an Object), in which case C is left unchanged and
    // step 7's IsConstructor check rejects it.
    var c_v: Value = ctor_v;
    if (try intrinsics.getPropertyChainOnValue(realm, ctor_v, "@@species")) |species| {
        c_v = if (species.isNull()) Value.undefined_ else species;
    }
    // Step 6 — if C is undefined, return ArrayCreate(length).
    if (c_v.isUndefined()) return defaultArrayCreate(home, length);
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
            if (array_ctor == species_fn) return defaultArrayCreate(home, length);
        }
    }
    // Construct(species, [length]) — go through the public path so a
    // user-defined ctor sees `new.target = species`.
    const ctor_args = [_]Value{numberFromI64(length)};
    const result = lantern.constructValue(realm.allocator, realm, heap_mod.taggedFunction(species_fn), &ctor_args, heap_mod.taggedFunction(species_fn)) catch |err| switch (err) {
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
    realm.heap.setObjectPrototype(out, realm.intrinsics.array_prototype);
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
    // §22.1.1 — Array(...) called as a function (no NewTarget)
    // always creates a fresh Array regardless of `this`. Cynic's
    // native_callback signature doesn't carry new.target, so we
    // recognise the construct path by `this_value.prototype ==
    // %Array.prototype%` (set by `constructValue` after
    // OrdinaryCreateFromConstructor). Any other `this` — including
    // a user object passed via `Array.apply(nonArrayInstance, …)`
    // — must NOT have `is_array_exotic` punched onto it, else
    // subsequent IsArray / IsConcatSpreadable checks lie. See
    // built-ins/Array/prototype/concat/Array.prototype.concat_non-array.js.
    const reuse_this: bool = blk: {
        const obj = heap_mod.valueAsPlainObject(this_value) orelse break :blk false;
        if (obj.is_array_exotic) break :blk true;
        // §22.1.1.1 Array(...) construct path — `this_value` is the
        // fresh OrdinaryCreateFromConstructor instance whose
        // [[Prototype]] is the §10.1.14-resolved proto. For a subclass
        // `class MyArray extends Array {}` (or proxy newTarget that
        // resolves to one), that chain reaches %Array.prototype%
        // but isn't equal to it. Walk the chain so a freshly-built
        // subclass instance still gets `is_array_exotic` punched in
        // and the args populated in-place, instead of allocating a
        // discarded fresh Array with the wrong prototype.
        //
        // The match is realm-agnostic: §23.1.3 makes every realm's
        // %Array.prototype% itself an Array exotic object, so a
        // cross-realm construct (`Reflect.construct(Array, args,
        // newTargetFromOtherRealm)`, where §10.1.14 resolved the proto
        // to *that* realm's %Array.prototype%) is recognised by the
        // `is_array_exotic` chain marker rather than a pointer-compare
        // against the active realm's intrinsic — which would miss it
        // and wrongly allocate a fresh Array with the active realm's
        // prototype (built-ins/Array/proto-from-ctor-realm-*.js). A
        // plain object passed via `Array.apply(plainObj, …)` has no
        // array-exotic ancestor, so it still allocates fresh and
        // never gets `is_array_exotic` punched onto a user object.
        var cur = obj.prototype;
        while (cur) |p| : (cur = p.prototype) {
            if (p.is_array_exotic) break :blk true;
        }
        break :blk false;
    };
    const out = if (reuse_this)
        heap_mod.valueAsPlainObject(this_value).?
    else blk: {
        const fresh = realm.heap.allocateObject() catch return error.OutOfMemory;
        realm.heap.setObjectPrototype(fresh, realm.intrinsics.array_prototype);
        break :blk fresh;
    };
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
        out.set(realm.allocator, owned.flatBytes(), args[i]) catch return error.OutOfMemory;
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
        try setOrThrow(realm, obj, owned.flatBytes(), owned, v);
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
    // §7.1.20 ToLength caps at 2^53 - 1; the saturating helper
    // bottoms out at i64.max so re-clamp here. Without the clamp,
    // `pop()` on `{length: Infinity}` would decrement to i64.max-1
    // and `Set(O, "length", ...)` would store that bogus value.
    const safe_max: i64 = (1 << 53) - 1;
    if (len > safe_max) len = safe_max;
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
/// §7.3.4 Set(O, P, V, true). `key_anchor`, when non-null, is the
/// heap-allocated JSString backing `key` — it is anchored on the
/// receiver when the write lands in the named-property bag, so a
/// GC sweep can't dangle the borrowed key slice. Static-literal
/// keys (`"length"`) pass `null`.
pub fn setOrThrow(realm: *Realm, obj: *JSObject, key: []const u8, key_anchor: ?*JSString, value: Value) NativeError!void {
    // §10.4.5.5 [[Set]] on a TypedArray exotic — when the key is a
    // CanonicalNumericIndexString, route through TypedArraySetElement
    // (§10.4.5.13). Coercion runs FIRST and may observably resize
    // (rab) or detach the backing buffer; after the coercion settles
    // we re-witness the live view and silently drop the write when
    // the index is now invalid. The TA write itself never escapes to
    // OrdinarySet's accessor / DefineOwnProperty fallback — TA
    // [[DefineOwnProperty]] only handles numeric indices specially.
    // (fill/typed-array-resize.js: Array.prototype.fill called on a
    // TA whose `valueOf` shrinks the rab during coercion expects
    // zero writes once the index falls OOB.)
    if (obj.getTypedView()) |tv0| {
        const ta_mod = @import("typed_array.zig");
        if (ta_mod.canonicalNumericIndex(key)) |num| {
            _ = tv0;
            const bigint_mod = @import("bigint.zig");
            const coerced: Value = if (obj.getTypedView().?.kind.isBigInt())
                bigint_mod.toBigIntValue(realm, value) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    else => return error.NativeThrew,
                }
            else
                try intrinsics.toNumber(realm, value);
            // Re-witness — a user `valueOf` could have detached /
            // resized the buffer between ToNumber and the write.
            const live_tv = obj.getTypedView() orelse return;
            if (!ta_mod.isValidIntegerIndexPub(live_tv, num)) return;
            const buf = live_tv.viewed.getArrayBuffer() orelse return;
            const elem_size = live_tv.kind.elementSize();
            const idx: usize = @intFromFloat(num);
            const byte_pos = live_tv.byte_offset + idx * elem_size;
            if (byte_pos + elem_size > buf.len) return;
            intrinsics.writeTypedElementForView(buf, live_tv, byte_pos, coerced);
            return;
        }
    }
    // §10.5.9 [[Set]] — Proxy receiver dispatches the `set` trap;
    // when the trap is absent fall through to `target.[[Set]](P, V,
    // Receiver)` with Receiver = the outer proxy. For a plain
    // target, that's OrdinarySet, which calls
    // `Receiver.[[GetOwnProperty]]` then `Receiver.[[DefineOwnProperty]]`
    // — both fire proxy traps. Emulate that ordering by dispatching
    // `getOwnPropertyDescriptor` + `defineProperty` traps directly
    // when `set` falls through (test262 Array.prototype.splice/
    // property-traps-order-with-species).
    const proxy_mod = @import("proxy.zig");
    var cur = obj;
    while (cur.proxy_target != null or cur.proxy_revoked) {
        const set_r = try proxy_mod.nativeProxySet(realm, cur, key, value, heap_mod.taggedObject(cur), null);
        switch (set_r) {
            .boolean => |b| {
                if (!b) return throwTypeError(realm, "Set: 'set' trap returned false");
                return;
            },
            .fallthrough => {
                // §10.1.9.2 step 2.d (when reached via target.[[Set]]
                // on a plain target with Receiver = outer proxy):
                // `Receiver.[[GetOwnProperty]](P)` fires the
                // outer proxy's `getOwnPropertyDescriptor` trap.
                _ = try proxy_mod.nativeProxyGetOwnPropertyDescriptor(realm, cur, key, null);
                // §10.1.9.2 step 2.e.iv —
                // `Receiver.[[DefineOwnProperty]](P, valueDesc)`
                // fires the outer proxy's `defineProperty` trap.
                const dp_r = try proxy_mod.nativeProxyDefineProperty(realm, cur, key, value, null);
                switch (dp_r) {
                    .boolean => |b| {
                        if (!b) return throwTypeError(realm, "Set: 'defineProperty' trap returned false");
                        return;
                    },
                    .fallthrough => |t2| {
                        if (t2 == cur) break;
                        cur = t2;
                    },
                }
            },
        }
    }
    // §10.1.9.1 OrdinarySet — walk the prototype chain for an
    // accessor setter; own data on the way shadows the inherited
    // accessor (`lookupAccessor` handles that contract).
    const o = cur;
    if (lantern.lookupAccessor(o, key)) |acc_pair| {
        if (acc_pair.setter) |setter| {
            const args = [_]Value{value};
            const outcome = lantern.callJSFunction(realm.allocator, realm, setter, heap_mod.taggedObject(o), &args) catch |err| switch (err) {
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
    if (std.mem.eql(u8, key, "length") and o.is_array_exotic) {
        if (!o.array_length_writable) {
            return throwTypeError(realm, "Cannot assign to read-only property 'length'");
        }
        // §10.4.2.4 ArraySetLength — drives the spec-mandated TWO
        // ToNumber calls (step 3 via ToUint32, step 4 standalone).
        // User valueOf throws propagate via error.NativeThrew.
        const new_len = (try lantern.arrayLengthCoerceSpec(realm, value)) orelse {
            return throwRangeError(realm, "Invalid array length");
        };
        // Re-check writability — a user valueOf could have flipped
        // `length: { writable: false }` between the two coercions.
        if (!o.array_length_writable) {
            return throwTypeError(realm, "Cannot assign to read-only property 'length'");
        }
        const tr = lantern.truncateArrayAtLength(realm.allocator, o, new_len);
        o.setArrayLength(realm.allocator, tr.final_length) catch return error.OutOfMemory;
        if (tr.blocked) {
            return throwTypeError(realm, "Cannot delete non-configurable array index");
        }
        return;
    }
    // §10.4.2.1 [[DefineOwnProperty]] — Array exotic indexed
    // writes go through `setIndexed`. Auto-extend length-gate
    // applies when `length: {writable:false}`.
    if (o.is_array_exotic) {
        if (JSObject.canonicalIntegerIndex(key)) |idx| {
            if (!o.ownDataContains(key)) {
                if (!o.array_length_writable) {
                    const cur_len: u32 = o.arrayLength();
                    if (idx >= cur_len) {
                        return throwTypeError(realm, "Cannot extend non-writable array length");
                    }
                }
                realm.heap.writeBarrier(.{ .object = o }, value);
                o.setIndexed(realm.allocator, idx, value) catch return error.OutOfMemory;
                return;
            }
        }
    }
    // §10.1.9.2 OrdinarySetWithOwnDescriptor — own data wins; if
    // absent, [[DefineOwnProperty]] fails (and so strict-mode
    // [[Set]] throws TypeError) when the receiver is non-extensible.
    const had_entry = o.ownDataContains(key);
    if (had_entry) {
        const flags = o.flagsFor(key);
        if (!flags.writable) {
            return throwTypeError(realm, "Cannot assign to read-only property");
        }
        // §6.1.6.1 NumberValue — length is a Number; preserve the
        // value bit-pattern (don't down-cast a double to int32).
        // Route through `setWithFlags` so the shape's slot stays
        // authoritative for shape-mode receivers under Phase 3 of
        // [docs/lazy-property-bag.md]; the bag stays in sync
        // automatically when the shape demotes.
        o.setWithFlags(realm.allocator, key, value, flags) catch return error.OutOfMemory;
        return;
    }
    if (!o.extensible) {
        return throwTypeError(realm, "Cannot add property, object is not extensible");
    }
    o.set(realm.allocator, key, value) catch return error.OutOfMemory;
    // The named-property bag borrows the `key` slice; anchor the
    // heap key JSString so a GC sweep can't dangle it. (Array-exotic
    // integer writes route to `elements` above and never reach here.)
    if (key_anchor) |ks| {
        if (o.ownDataContains(key)) {
            o.anchorKey(realm.allocator, ks) catch return error.OutOfMemory;
            o.markNonPristine();
        }
    }
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
    try setOrThrow(realm, obj, "length", null, lv);
}

/// §7.3.5 DeletePropertyOrThrow — Strict-mode delete that throws
/// TypeError if the [[Delete]] returns false. Used by push / pop /
/// shift / unshift / splice / copyWithin to drop indices.
///
/// Dispatches through the Proxy `deleteProperty` trap when the
/// receiver is a Proxy (§10.5.10) so trap-thrown abrupts surface,
/// and falls through to §10.1.10.1 OrdinaryDelete which rejects
/// a non-configurable own property with TypeError per §7.3.5.
pub fn deletePropertyOrThrow(realm: *Realm, obj: *JSObject, key: []const u8) NativeError!void {
    const proxy_mod = @import("proxy.zig");
    var cur = obj;
    while (cur.proxy_target != null or cur.proxy_revoked) {
        const r = try proxy_mod.nativeProxyDelete(realm, cur, key, null);
        switch (r) {
            .boolean => |b| {
                if (!b) return throwTypeError(realm, "Cannot delete property");
                return;
            },
            .fallthrough => |t| {
                if (t == cur) {
                    if (!try cur.deleteOwn(realm.allocator, key)) return throwTypeError(realm, "Cannot delete property");
                    return;
                }
                cur = t;
            },
        }
    }
    // §10.1.10.1 OrdinaryDelete step 4 — a non-configurable own
    // property returns false; §7.3.5 lifts that to TypeError.
    // `deleteOwn` already honors configurable on array-exotic
    // indexed slots, but unconditionally strips named bag entries,
    // so reject non-configurable here before calling it. `flagsFor`
    // is shape-aware (Phase 3 of [docs/lazy-property-bag.md]) —
    // a `defineProperty(o, "42", {configurable: false})` on a
    // plain object lands in the shape transition node's attrs,
    // not the bag, so a bag-only read would miss the gate.
    if (cur.hasAccessor(key) or cur.ownDataContains(key)) {
        const flags = cur.flagsFor(key);
        if (!flags.configurable) return throwTypeError(realm, "Cannot delete non-configurable property");
    }
    if (!try cur.deleteOwn(realm.allocator, key)) {
        return throwTypeError(realm, "Cannot delete property");
    }
}

fn arrayIndexOf(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const obj = try toObjectThis(realm, this_value);
    const target = argOr(args, 0, Value.undefined_);
    // §23.1.3.16 step 1-7 — clamp `len` at 2^53 - 1 per §7.1.20
    // ToLength. Don't cap the iteration window: indexOf short-
    // circuits on first match, and fixtures like 15.4.4.14-3-8
    // (`{0: 0, length: Infinity}`) expect the answer at index 0
    // without a RangeError.
    var raw_len = try toLengthOf(realm, obj);
    if (raw_len <= 0) return Value.fromInt32(-1);
    const safe_max: i64 = (1 << 53) - 1;
    if (raw_len > safe_max) raw_len = safe_max;
    const start = (try startIndexFrom(realm, args, raw_len)) orelse return Value.fromInt32(-1);
    var i: i64 = start;
    while (i < raw_len) : (i += 1) {
        if ((i & 0x3FF) == 0) try intrinsics.checkInterruptInNative(realm);
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
    // V8/JSC ordering). Route through `getPropertyAny` so a Proxy
    // `get` trap on the receiver fires for the "length" lookup
    // (`get-prop.js` observes the trap call sequence).
    const safe_max: i64 = (1 << 53) - 1;
    const len_v = try getPropertyAny(realm, heap_mod.taggedObject(obj), "length");
    var raw_len = try intrinsics.toLengthValue(realm, len_v);
    if (raw_len > safe_max) raw_len = safe_max;
    if (raw_len <= 0) return Value.false_;
    const start = (try startIndexFrom(realm, args, raw_len)) orelse return Value.false_;
    // Iterate from `start` to `len` (per §23.1.3.16 step 11). Cap
    // the iteration *window* — not the absolute length — at the
    // engine's max-iter ceiling so receivers with
    // `length: 2 ** 53` and a high `fromIndex` (the
    // `length-boundaries.js` fixture) still get scanned.
    const len = raw_len;
    if (len - start > intrinsics.max_iter_length) {
        return throwRangeError(realm, "Array.prototype.includes scan window exceeds maximum supported");
    }
    var i: i64 = start;
    while (i < len) : (i += 1) {
        var ibuf: [24]u8 = undefined;
        const islice = std.fmt.bufPrint(&ibuf, "{d}", .{i}) catch unreachable;
        // §23.1.3.16 step 12.a — `Get(O, ! ToString(F(k)))`. Use
        // the Proxy-aware accessor so a `get` trap fires per
        // index.
        const v = try getPropertyAny(realm, heap_mod.taggedObject(obj), islice);
        if (sameValueZero(v, target)) return Value.true_;
    }
    return Value.false_;
}

/// §23.1.3.36 Array.prototype.toString:
///   1. array = ? ToObject(this value)
///   2. func = ? Get(array, "join")
///   3. If IsCallable(func) is false, set func = %Object.prototype.toString%
///   4. Return ? Call(func, array)
/// Drives `Array.prototype.toString.call(true)` to fall back to
/// `Object.prototype.toString.call(true)` → `"[object Boolean]"`,
/// because a Boolean wrapper has no `join` in its proto chain.
fn arrayToString(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = args;
    const obj = try toObjectThis(realm, this_value);
    // §23.1.3.36 step 2 — `Get(array, "join")`. Route through
    // `getPropertyAny` so a Proxy `get` trap fires (the
    // `non-callable-join-string-tag.js` fixture sets
    // `proxyTarget.join = undefined` and expects the trap-returned
    // `undefined` to trigger the §23.1.3.36 step 3 fallback to
    // `%Object.prototype.toString%` — otherwise the bare
    // proto-chain walk finds `Array.prototype.join` and calls it).
    const func_v = try getPropertyAny(realm, heap_mod.taggedObject(obj), "join");
    if (heap_mod.valueAsFunction(func_v)) |func| {
        const outcome = lantern.callJSFunction(realm.allocator, realm, func, heap_mod.taggedObject(obj), &.{}) catch |err| switch (err) {
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
    // §23.1.3.36 step 3 — fall back to Object.prototype.toString.
    return @import("object.zig").objectProtoToString(realm, heap_mod.taggedObject(obj), &.{});
}

fn arrayJoin(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    // §23.1.3.15 Array.prototype.join (separator):
    //   1. O = ToObject(this); 2. len = ? LengthOfArrayLike(O)
    //   3. If separator is undefined, sep = ","; else sep = ? ToString(separator)
    // Read `length` BEFORE coercing `separator` per spec step
    // ordering — `separator.toString` may resize a resizable
    // ArrayBuffer backing the TA receiver, but the loop count
    // is fixed at entry (coerced-separator-shrink.js,
    // coerced-separator-grow.js).
    // Native-stack guard. Joining a nested array recurses:
    // `arrayJoin` → `stringifyArg(element)` → the element array's
    // `toString` → `arrayJoin`. A deeply nested array
    // (`let a=[0]; for(…) a=[a]; a.toString()`) would overflow the
    // host stack; throw the RangeError V8 / JSC give for
    // stack-exhausting join/toString instead.
    if (@import("../../stack_guard.zig").nearLimit()) {
        const ex = intrinsics.newRangeError(realm, "Maximum call stack size exceeded") catch return error.OutOfMemory;
        realm.pending_exception = ex;
        return error.NativeThrew;
    }
    const obj = try toObjectThis(realm, this_value);
    const len = try intrinsics.clampArrayLengthR(realm, try toLengthOf(realm, obj));
    const sep_v = argOr(args, 0, Value.undefined_);
    const sep_slice: []const u8 = if (sep_v.isUndefined())
        ","
    else blk: {
        // Route through stringifyArg so booleans, numbers, null,
        // and objects with toString hooks all coerce per §7.1.17
        // ToString (an inherited `Symbol.toPrimitive` / `toString`
        // setter on the receiver participates and can throw).
        const s = try stringifyArg(realm, sep_v);
        break :blk s.flatBytes();
    };
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
        buf.appendSlice(realm.allocator, s.flatBytes()) catch return error.OutOfMemory;
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
    // Native-stack guard — same rationale as `arrayJoin`. A self-
    // referential array (`const a = []; a.push(a); a.toLocaleString()`)
    // would otherwise recurse `arrayToLocaleString → callValue →
    // arrayToLocaleString` forever and overflow the host stack
    // (Fuzzilli reliably surfaced this in 4 of 6 stack-overflow
    // crashes in the post-fix corpus). AGENTS.md host-safety
    // contract: throw a catchable RangeError, never abort the host.
    if (@import("../../stack_guard.zig").nearLimit()) {
        const ex = intrinsics.newRangeError(realm, "Maximum call stack size exceeded") catch return error.OutOfMemory;
        realm.pending_exception = ex;
        return error.NativeThrew;
    }
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
        // §23.1.3.32 step 6.b — Invoke(elt, "toLocaleString").
        // For primitive elements (Boolean / Number / String /
        // BigInt) the spec routes the call through the boxed
        // wrapper; the method itself lives on `<Wrapper>.prototype`,
        // so we must walk the proto chain (the bare `boxed.get`
        // only sees own slots — Boolean wrappers have none).
        // §23.1.3.32 step 6.b — `Invoke(elt, "toLocaleString")`.
        // §7.3.20 Invoke routes through GetV(V, P) (§7.3.18) which
        // ToObject-wraps V purely for the property lookup, then
        // calls the resulting function with `thisArgument = V` —
        // the original (possibly primitive) value. Strict-mode
        // fixtures (`primitive_this_value*.js`) observe `typeof
        // this` inside an overridden `Boolean.prototype.toString`
        // and expect the primitive (`"boolean"`), not the
        // wrapper (`"object"`); passing the boxed wrapper as
        // `this` would change the semantics in strict mode.
        const boxed = try intrinsics.toObjectThis(realm, v);
        const method_v = try getPropertyChain(realm, boxed, "toLocaleString");
        var str_v: Value = v;
        if (heap_mod.valueAsFunction(method_v)) |_| {
            const outcome = lantern.callValue(realm.allocator, realm, realm.active_native_fn_realm orelse realm, method_v, v, &.{}) catch |err| switch (err) {
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
        }
        const s = try stringifyArg(realm, str_v);
        buf.appendSlice(realm.allocator, s.flatBytes()) catch return error.OutOfMemory;
    }
    const out = realm.heap.allocateString(buf.items) catch return error.OutOfMemory;
    return Value.fromString(out);
}

fn arraySlice(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    // §23.1.3.28 Array.prototype.slice:
    //   1-2. ToObject + ToLength
    //   3-6. ToIntegerOrInfinity(start) -> actualStart
    //   7-8. ToIntegerOrInfinity(end) -> final
    //   9. count = max(final - actualStart, 0)
    //   10. A = ? ArraySpeciesCreate(O, count)
    //   11. Loop k in [start, final): HasProperty + (Get +
    //       CreateDataPropertyOrThrow)
    //   12. ? Set(A, "length", n, true)
    const obj = try toObjectThis(realm, this_value);
    // §23.1.3.28 step 2 — `LengthOfArrayLike(O)`. Route through
    // the Proxy-aware accessor so a `get` trap on the receiver
    // fires (the `length-exceeding-integer-limit-proxied-array.js`
    // fixture exposes a fake `length: 2 ** 53 + 2` via the trap).
    const len_v = try getPropertyAny(realm, heap_mod.taggedObject(obj), "length");
    var raw_len = try intrinsics.toLengthValue(realm, len_v);
    const safe_max: i64 = (1 << 53) - 1;
    if (raw_len > safe_max) raw_len = safe_max;
    const len = raw_len;
    // §7.1.5 ToIntegerOrInfinity for start / end — must route
    // through ToNumber so accessor / valueOf hooks fire.
    var start: i64 = 0;
    if (args.len > 0) start = try toIntPropagating(realm, args[0]);
    var end: i64 = len;
    if (args.len > 1 and !args[1].isUndefined()) end = try toIntPropagating(realm, args[1]);
    if (start < 0) start = @max(len + start, 0) else start = @min(start, len);
    if (end < 0) end = @max(len + end, 0) else end = @min(end, len);

    const count = if (end > start) end - start else 0;
    if (count > max_iter_length) {
        const ex = intrinsics.newRangeError(realm, "Slice length exceeds maximum supported") catch return error.OutOfMemory;
        realm.pending_exception = ex;
        return error.NativeThrew;
    }
    const out_v = try arraySpeciesCreate(realm, obj, count);
    const out = heap_mod.valueAsPlainObject(out_v) orelse return throwTypeError(realm, "ArraySpeciesCreate did not return an object");
    // Pin the result and receiver across the re-entrant copy loop.
    const scope = realm.heap.openScope() catch return error.OutOfMemory;
    defer scope.close();
    scope.push(out_v) catch return error.OutOfMemory;
    scope.push(heap_mod.taggedObject(obj)) catch return error.OutOfMemory;
    var write_idx: i64 = 0;
    var read_idx = start;
    while (read_idx < end) : (read_idx += 1) {
        var rbuf: [24]u8 = undefined;
        const rslice = std.fmt.bufPrint(&rbuf, "{d}", .{read_idx}) catch unreachable;
        // §23.1.3.28 step 11.b — `HasProperty(O, Pk)`. Proxy-
        // aware so a `has` trap fires and the per-index walk
        // works against a proxied array that reports a high
        // fake length.
        if (!(try hasPropertyP(realm, obj, rslice))) {
            write_idx += 1;
            continue;
        }
        const v = try getPropertyAny(realm, heap_mod.taggedObject(obj), rslice);
        var wbuf: [24]u8 = undefined;
        const wslice = std.fmt.bufPrint(&wbuf, "{d}", .{write_idx}) catch unreachable;
        const owned = realm.heap.allocateString(wslice) catch return error.OutOfMemory;
        // §23.1.3.28 step 11.c.ii — CreateDataPropertyOrThrow, not Set.
        try createDataPropertyOrThrowGeneric(realm, out, owned, v);
        write_idx += 1;
    }
    // §23.1.3.28 step 12 — ? Set(A, "length", n, true).
    try setLengthOrThrow(realm, out, write_idx);
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

    // Pin the result array and the receiver: every concatAppend
    // re-enters JS (a proxy `get`/`length` trap, an
    // `@@isConcatSpreadable` getter) and setLengthOrThrow runs a
    // user length setter — each re-entry can trigger a GC sweep
    // that would otherwise collect `out` (held only on the Zig
    // stack) or a freshly boxed primitive receiver.
    const scope = realm.heap.openScope() catch return error.OutOfMemory;
    defer scope.close();
    scope.push(out_v) catch return error.OutOfMemory;
    scope.push(heap_mod.taggedObject(obj)) catch return error.OutOfMemory;

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
        // §23.1.3.2 step 8.d.iii — ? LengthOfArrayLike(E). Use
        // the Proxy-aware accessor so a `get` trap on "length"
        // fires and a revoked proxy throws. Functions are
        // Objects in JS too; their indexed slots are read via
        // `getPropertyAny` below.
        const len_v = try getPropertyAny(realm, value, "length");
        var len = try intrinsics.toLengthValue(realm, len_v);
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
            if (!hasPropertyAny(value, rslice)) {
                write_idx.* += 1;
                continue;
            }
            const v = try getPropertyAny(realm, value, rslice);
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
    try createDataPropertyOrThrowGeneric(realm, out, owned, v);
    write_idx.* += 1;
}

/// §23.1.3.2.1 IsConcatSpreadable. `@@isConcatSpreadable` is the
/// override hook; absent it, §7.2.2 IsArray decides. Per §7.2.2
/// step 3 a Proxy unwraps to its target before the IsArray check,
/// and a revoked Proxy throws TypeError. Per §7.1.2 step 4 a
/// non-undefined spreadable value coerces via ToBoolean — including
/// primitives like `7` or `"string"`.
fn isConcatSpreadable(realm: *Realm, v: Value) NativeError!bool {
    if (!isObjectLike(v)) return false;
    const spreadable_v = try getPropertyAny(realm, v, "@@isConcatSpreadable");
    if (!spreadable_v.isUndefined()) return toBoolean(spreadable_v);
    // §7.2.2 IsArray — for a Proxy, recurse into the target;
    // revoked proxy throws.
    return try isArrayProxyAware(realm, v);
}

/// §7.2.2 IsArray with Proxy unwrap. Walks the proxy target chain
/// (§7.2.2 step 3.b); a revoked proxy on the chain raises TypeError
/// per §7.2.2 step 3.a. Returns false for non-Object values.
fn isArrayProxyAware(realm: *Realm, v: Value) NativeError!bool {
    var cur_obj = heap_mod.valueAsPlainObject(v) orelse return false;
    while (true) {
        if (cur_obj.proxy_revoked) {
            return throwTypeError(realm, "Cannot perform 'IsArray' on a proxy that has been revoked");
        }
        if (cur_obj.proxy_target) |t| {
            cur_obj = t;
            continue;
        }
        return cur_obj.is_array_exotic;
    }
}

/// True for Object-typed values per §6.1.7 — plain objects,
/// arrays, proxies, AND functions (Cynic tags functions
/// separately from plain objects on the value side).
fn isObjectLike(v: Value) bool {
    return heap_mod.valueAsPlainObject(v) != null or heap_mod.valueAsFunction(v) != null;
}

/// Proxy- and function-aware Get. For a Proxy target, dispatches
/// through `nativeProxyGet` so the `get` trap fires and a revoked
/// proxy throws (§10.5.5). For a JSFunction, reads from the
/// function's own property/accessor bag (§10.2 ordinary function
/// internal methods). Otherwise delegates to `getPropertyChain`.
fn getPropertyAny(realm: *Realm, v: Value, key: []const u8) NativeError!Value {
    if (heap_mod.valueAsPlainObject(v)) |obj| {
        if (obj.proxy_target != null or obj.proxy_revoked) {
            return getOnProxyChain(realm, obj, key, v);
        }
        return getPropertyChain(realm, obj, key);
    }
    if (heap_mod.valueAsFunction(v)) |fn_obj| {
        // §10.2 ordinary [[Get]] — own props, then accessor, then
        // walk the function's `[[Prototype]]` chain. JSFunction
        // already encapsulates the lookup order (own / prototype /
        // static_parent / proto) for data slots.
        if (fn_obj.ownAccessor(key)) |acc| {
            if (acc.getter) |getter| {
                const outcome = lantern.callJSFunction(realm.allocator, realm, getter, heap_mod.taggedFunction(fn_obj), &[_]Value{}) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    else => return error.NativeThrew,
                };
                switch (outcome) {
                    .value, .yielded => |out_v| return out_v,
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
    return Value.undefined_;
}

/// Walk a Proxy target chain, invoking `nativeProxyGet` at each
/// hop. A revoked proxy anywhere on the chain throws TypeError.
/// A trap-free proxy falls through to `getPropertyChain` on the
/// (possibly nested) plain-object target.
fn getOnProxyChain(realm: *Realm, proxy: *JSObject, key: []const u8, receiver: Value) NativeError!Value {
    const proxy_mod = @import("proxy.zig");
    var cur = proxy;
    while (true) {
        const outcome = try proxy_mod.nativeProxyGet(realm, cur, key, receiver, null);
        switch (outcome) {
            .value => |v| return v,
            .fallthrough => |t| {
                if (t == cur) {
                    // proxy with no target slot — bail out as undefined.
                    return Value.undefined_;
                }
                if (t.proxy_target != null or t.proxy_revoked) {
                    cur = t;
                    continue;
                }
                return getPropertyChain(realm, t, key);
            },
        }
    }
}

/// HasProperty across plain objects + functions. Used by
/// concat's spread loop to skip holes. Proxies are conservatively
/// treated as "has" — the subsequent Get will surface a trap
/// throw or undefined.
fn hasPropertyAny(v: Value, key: []const u8) bool {
    if (heap_mod.valueAsPlainObject(v)) |obj| {
        if (obj.proxy_target != null or obj.proxy_revoked) return true;
        return obj.hasProperty(key);
    }
    if (heap_mod.valueAsFunction(v)) |fn_obj| {
        if (fn_obj.hasOwn(key)) return true;
        if (fn_obj.proto) |p| return p.hasProperty(key);
    }
    return false;
}

// ── Additional Array methods ────────────────────────────────────────────────

fn arrayIsArray(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = this_value;
    const v = argOr(args, 0, Value.undefined_);
    // §23.1.2.2 Array.isArray ⇒ §7.2.2 IsArray. The spec checks
    // the [[ArrayLength]] internal slot (Cynic's
    // `is_array_exotic`), not "has Array.prototype on its chain"
    // — `Object.create([])` is NOT an Array, `Array.prototype`
    // itself IS one, and a revoked Proxy throws TypeError.
    return if (try isArrayProxyAware(realm, v)) Value.true_ else Value.false_;
}

/// §23.1.2.3 Array.of(...items). Per spec:
///   1. Let len be the number of arguments.
///   2. Let C be the `this` value.
///   3. If IsConstructor(C), let A be ? Construct(C, « 𝔽(len) »).
///      Else let A be ? ArrayCreate(len).
///   4. For each item, CreateDataPropertyOrThrow(A, ToString(k), item).
///   5. ? Set(A, "length", 𝔽(len), true).
///   6. Return A.
/// The constructor path is observable via `Array.of.call(Ctor, …)`,
/// the test262 entry point — `Ctor` receives a single `len` argument
/// and may install a `length` accessor that the final Set step
/// invokes (sets-length.js). An abrupt completion from Construct
/// (return-abrupt-from-contructor.js) must propagate; the
/// CreateDataPropertyOrThrow / Set abrupts propagate too
/// (return-abrupt-from-data-property*.js, return-abrupt-from-setting-length.js).
fn arrayOf(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const len_i64: i64 = @intCast(args.len);
    const this_ctor: ?*JSFunction = blk: {
        const f = heap_mod.valueAsFunction(this_value) orelse break :blk null;
        if (!f.has_construct or f.is_arrow) break :blk null;
        break :blk f;
    };

    var out: *JSObject = undefined;
    if (this_ctor) |c| {
        // §23.1.2.3 step 3.a — Construct(C, « 𝔽(len) »).
        const ctor_args = [_]Value{numberFromI64(len_i64)};
        const ctor_v = try constructForFromAsync(realm, c, &ctor_args);
        out = heap_mod.valueAsPlainObject(ctor_v) orelse return throwTypeError(realm, "Array.of: constructor did not return an object");
    } else {
        out = realm.heap.allocateObject() catch return error.OutOfMemory;
        realm.heap.setObjectPrototype(out, realm.intrinsics.array_prototype);
        out.markAsArrayExotic(realm.allocator) catch return error.OutOfMemory;
    }
    // Pin the receiver across the data-property writes and the
    // final length set; both re-enter JS (accessor setters from a
    // user-supplied subclass) and can trigger a GC sweep.
    const scope = realm.heap.openScope() catch return error.OutOfMemory;
    defer scope.close();
    scope.push(heap_mod.taggedObject(out)) catch return error.OutOfMemory;

    for (args, 0..) |v, idx| {
        var ibuf: [24]u8 = undefined;
        const islice = std.fmt.bufPrint(&ibuf, "{d}", .{idx}) catch unreachable;
        const idx_owned = realm.heap.allocateString(islice) catch return error.OutOfMemory;
        // §23.1.2.3 step 4.c — CreateDataPropertyOrThrow.
        try createDataPropertyOrThrowGeneric(realm, out, idx_owned, v);
    }
    // §23.1.2.3 step 5 — Set(A, "length", 𝔽(len), true). Goes
    // through the user-installed setter on subclass receivers.
    try setOrThrow(realm, out, "length", null, numberFromI64(len_i64));
    return heap_mod.taggedObject(out);
}

/// §23.1.2.1 Array.from( items [, mapfn [, thisArg ] ] ).
/// Three paths: string (iterate code points), iterable
/// (walks `@@iterator` — Sets, Maps, generators, custom
/// iterables), and array-like fallback (`length` + indexed get,
/// for `{length: n}` and DOM-style nodelists).
fn arrayFrom(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const items = argOr(args, 0, Value.undefined_);
    const mapfn_v = argOr(args, 1, Value.undefined_);
    const this_arg = argOr(args, 2, Value.undefined_);
    const mapfn: ?*JSFunction = if (mapfn_v.isUndefined()) null else heap_mod.valueAsFunction(mapfn_v) orelse return throwTypeError(realm, "Array.from: mapfn is not a function");

    // §23.1.2.1 Array.from — `let C = this value`. When C is a
    // constructor, the result is allocated via Construct(C) on the
    // iterator path and Construct(C, « 𝔽(len) ») on the array-like
    // path; otherwise we fall back to ArrayCreate. `Array.from.call(
    // C, …)` is the test262 entry point for the constructor path.
    const this_ctor: ?*JSFunction = blk: {
        const f = heap_mod.valueAsFunction(this_value) orelse break :blk null;
        if (!f.has_construct or f.is_arrow) break :blk null;
        break :blk f;
    };

    // Allocate a default Array-exotic receiver; the iterator /
    // array-like branches below MAY override this with the result
    // of `Construct(C, …)` when `this` is a user-supplied
    // constructor. String fast-path keeps the default receiver
    // (Array.from on a string doesn't observe the constructor).
    var out = realm.heap.allocateObject() catch return error.OutOfMemory;
    realm.heap.setObjectPrototype(out, realm.intrinsics.array_prototype);

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
    // String fast path — the §22.1.5.1 String iterator yields code
    // POINTS, so advance by WTF-8 sequence (a valid surrogate pair is
    // stored as one 4-byte sequence, a lone surrogate as 3-byte CESU-8 —
    // either way one sequence == one code point). Slicing one byte per
    // element shattered any multi-byte code point (e.g. an astral char
    // into its 4 bytes). Both the mapfn index and the output index are
    // the code-point index, and the final length is the code-point count.
    if (items.isString()) {
        const s: *JSString = @ptrCast(@alignCast(items.asString()));
        const bytes = s.flatBytes();
        var i: usize = 0; // byte position
        var cp_idx: usize = 0; // code-point (element) index
        while (i < bytes.len) {
            const end = @min(i + utf16.utf8SeqLen(bytes[i]), bytes.len);
            const ch = realm.heap.allocateString(bytes[i..end]) catch return error.OutOfMemory;
            const elem: Value = blk: {
                if (mapfn) |mf| {
                    const cb_args = [_]Value{ Value.fromString(ch), numberFromI64(@intCast(cp_idx)) };

                    const outcome = lantern.callJSFunction(realm.allocator, realm, mf, this_arg, &cb_args) catch return error.NativeThrew;
                    switch (outcome) {
                        .value, .yielded => |v| break :blk v,
                        .thrown => |ex| {
                            realm.pending_exception = ex;
                            return error.NativeThrew;
                        },
                    }
                } else break :blk Value.fromString(ch);
            };
            var ibuf: [24]u8 = undefined;
            const islice = std.fmt.bufPrint(&ibuf, "{d}", .{cp_idx}) catch unreachable;
            const idx_owned = realm.heap.allocateString(islice) catch return error.OutOfMemory;
            out.set(realm.allocator, idx_owned.flatBytes(), elem) catch return error.OutOfMemory;
            i = end;
            cp_idx += 1;
        }
        setLength(realm, out, @intCast(cp_idx)) catch return error.OutOfMemory;
        return heap_mod.taggedObject(out);
    }

    // §23.1.2.1 step 3 — `GetMethod(items, @@iterator)`. Per §7.3.11
    // GetMethod → §7.3.2 GetV → §7.1.18 ToObject when the receiver
    // is a primitive, so a Number / Boolean / BigInt / Symbol with
    // an `@@iterator` reachable from its prototype chain still
    // takes the iterator-protocol path. test262
    // `Iterator/from/iterable-primitives.js` overrides
    // `Number.prototype[Symbol.iterator]` and expects
    // `Array.from(5)` to walk it. The iterator method is called
    // with `this = items` (the original primitive), not the
    // wrapper.
    if (items.isNull() or items.isUndefined()) {
        return throwTypeError(realm, "Array.from: items is null or undefined");
    }
    // For the @@iterator lookup we walk a *JSObject — either the
    // raw object or the primitive's prototype (Number.prototype,
    // Boolean.prototype, …). For the array-like fallback we still
    // use this same `src`; the primitive prototype has no `length`
    // or indexed entries, so the loop exits immediately, matching
    // `arrayLike = ! ToObject(items)` with len=0.
    const src: *JSObject = heap_mod.valueAsPlainObject(items) orelse (intrinsics.lookupPrimitivePrototype(realm, items) orelse return throwTypeError(realm, "Array.from: items is not iterable"));

    // Iterable path — preferred when present per §23.1.2.1 step 4.
    // GetMethod(items, @@iterator) walks the prototype chain; if
    // it resolves to a callable, take the iterator-protocol path.
    // A throwing accessor on `@@iterator` propagates via `try`.
    const iter_method_v = try getPropertyChain(realm, src, "@@iterator");
    if (heap_mod.valueAsFunction(iter_method_v)) |iter_method| {
        // §23.1.2.1 step 5.a — `If IsConstructor(C) is true, let A
        // be ? Construct(C)`. Construct runs BEFORE GetIterator so
        // a throwing constructor (iter-cstm-ctor-err) propagates
        // without ever calling `@@iterator`.
        if (this_ctor) |c| {
            const ctor_v = try constructForFromAsync(realm, c, &.{});
            const ctor_obj = heap_mod.valueAsPlainObject(ctor_v) orelse return throwTypeError(realm, "Array.from: constructor did not return an object");
            out = ctor_obj;
            scope.push(heap_mod.taggedObject(out)) catch return error.OutOfMemory;
        }
        // §7.4.2 GetIterator(items, sync) — `Call(@@iterator, items)`.
        // A throw from the iterator factory (iter-get-iter-err) must
        // propagate as the user's exception, NOT a generic TypeError.
        const iter_outcome = lantern.callJSFunction(realm.allocator, realm, iter_method, items, &.{}) catch |err| switch (err) {
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
        const iter_obj = heap_mod.valueAsPlainObject(iter) orelse return throwTypeError(realm, "Array.from: @@iterator did not return an iterator object");
        scope.push(iter) catch return error.OutOfMemory;
        const next_v = try getPropertyChain(realm, iter_obj, "next");
        const next_fn = heap_mod.valueAsFunction(next_v) orelse return throwTypeError(realm, "Array.from: iterator missing callable 'next'");

        var k: i64 = 0;
        const max_iter: usize = 1 << 24;
        var step: usize = 0;
        while (step < max_iter) : (step += 1) {
            // §7.4.6 IteratorStep — `IteratorNext` then `IteratorComplete`.
            // A throw from `next()` (iter-adv-err) is *not* closed: the
            // iterator's `return` is only invoked when the failure comes
            // from steps *after* a successful `next` per §7.4.10.
            const result_outcome = lantern.callJSFunction(realm.allocator, realm, next_fn, iter, &.{}) catch |err| switch (err) {
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
            const result_obj = heap_mod.valueAsPlainObject(result) orelse return throwTypeError(realm, "Array.from: iterator next() did not return an object");
            // §7.4.7 IteratorComplete / IteratorValue go through
            // ordinary [[Get]] — accessor descriptors on `done` /
            // `value` (poisoned-iterator fixtures) must invoke the
            // getter and propagate any throw.
            if (intrinsics.toBoolean(try getPropertyChain(realm, result_obj, "done"))) break;
            const raw_v = try getPropertyChain(realm, result_obj, "value");
            // §23.1.2.1 step 5.g.vii — if mapping, `Call(mapfn, T,
            // « value, k »)`. Abrupt → IteratorClose(iterator, abrupt)
            // (iter-map-fn-err).
            const elem: Value = blk: {
                if (mapfn) |mf| {
                    const cb_args = [_]Value{ raw_v, numberFromI64(k) };
                    const outcome = lantern.callJSFunction(realm.allocator, realm, mf, this_arg, &cb_args) catch |err| switch (err) {
                        error.OutOfMemory => return error.OutOfMemory,
                        else => {
                            closeIterOnAbrupt(realm, iter_obj, iter);
                            return error.NativeThrew;
                        },
                    };
                    switch (outcome) {
                        .value, .yielded => |v| break :blk v,
                        .thrown => |ex| {
                            realm.pending_exception = ex;
                            closeIterOnAbrupt(realm, iter_obj, iter);
                            return error.NativeThrew;
                        },
                    }
                } else break :blk raw_v;
            };
            var ibuf: [24]u8 = undefined;
            const islice = std.fmt.bufPrint(&ibuf, "{d}", .{k}) catch unreachable;
            // The receiver stores property names by reference; the
            // stack-scoped `ibuf` would dangle. Mint a heap-owned
            // JSString and use its persistent bytes.
            const idx_owned = realm.heap.allocateString(islice) catch return error.OutOfMemory;
            // §23.1.2.1 step 5.g.viii — `CreateDataPropertyOrThrow(A,
            // Pk, mappedValue)`. Failure → IteratorClose(iterator)
            // then propagate (iter-set-elem-prop-err).
            createDataPropertyOrThrowGeneric(realm, out, idx_owned, elem) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => {
                    closeIterOnAbrupt(realm, iter_obj, iter);
                    return error.NativeThrew;
                },
            };
            k += 1;
        }
        // §23.1.2.1 step 5.g.iv.1 — `Set(A, "length", 𝔽(k), true)`.
        // Use the spec-faithful Set so a prototype-chain `length`
        // setter fires (iter-set-length-err). No iterator close —
        // we exited via `done: true`, the iterator is already done.
        try setOrThrow(realm, out, "length", null, numberFromI64(k));
        return heap_mod.taggedObject(out);
    }

    // Array-like fallback (`length` + indexed get).
    const len = try intrinsics.clampArrayLengthR(realm, lengthOfArray(src));
    // §23.1.2.1 step 7.a — `If IsConstructor(C) is true, let A be
    // ? Construct(C, « 𝔽(len) »)`. Replace the default Array
    // receiver with the constructed object.
    if (this_ctor) |c| {
        const ctor_args = [_]Value{numberFromI64(len)};
        const ctor_v = try constructForFromAsync(realm, c, &ctor_args);
        const ctor_obj = heap_mod.valueAsPlainObject(ctor_v) orelse return throwTypeError(realm, "Array.from: constructor did not return an object");
        out = ctor_obj;
        scope.push(heap_mod.taggedObject(out)) catch return error.OutOfMemory;
    }
    var i: i64 = 0;
    while (i < len) : (i += 1) {
        var ibuf: [24]u8 = undefined;
        const islice = std.fmt.bufPrint(&ibuf, "{d}", .{i}) catch unreachable;
        // §23.1.2.1 step 7.e.ii — `Get(arrayLike, Pk)`. Use the
        // accessor-aware chain so a throwing indexed getter
        // propagates rather than being silently coerced.
        const raw_v = try getPropertyChain(realm, src, islice);
        // §23.1.2.1 step 7.e.iv — optional `Call(mapfn, T,
        // « kValue, k »)`. No iterator to close on this path.
        const elem: Value = blk: {
            if (mapfn) |mf| {
                const cb_args = [_]Value{ raw_v, numberFromI64(i) };
                const outcome = lantern.callJSFunction(realm.allocator, realm, mf, this_arg, &cb_args) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    else => return error.NativeThrew,
                };
                switch (outcome) {
                    .value, .yielded => |v| break :blk v,
                    .thrown => |ex| {
                        realm.pending_exception = ex;
                        return error.NativeThrew;
                    },
                }
            } else break :blk raw_v;
        };
        // Receiver stores keys by reference — see iterator path.
        const idx_owned = realm.heap.allocateString(islice) catch return error.OutOfMemory;
        // §23.1.2.1 step 7.e.v — `CreateDataPropertyOrThrow(A, Pk,
        // mappedValue)`. Honours non-extensible / non-configurable
        // (source-object-length-set-elem-prop-err) and overwrites
        // a configurable-but-non-writable own slot back to the
        // {w,e,c}-true default (source-object-length-set-elem-
        // prop-non-writable).
        try createDataPropertyOrThrowGeneric(realm, out, idx_owned, elem);
    }
    // §23.1.2.1 step 7.f — `Set(A, "length", 𝔽(len), true)`. Spec-
    // faithful Set so a prototype-chain `length` setter fires.
    try setOrThrow(realm, out, "length", null, numberFromI64(len));
    return heap_mod.taggedObject(out);
}

/// §7.4.10 IteratorClose — invoke `iter.return()` if present, used
/// when Array.from aborts mid-iteration. Caller has already stashed
/// the abrupt completion in `realm.pending_exception`; per spec, an
/// abrupt from `return` is suppressed in favour of the pre-existing
/// abrupt (§7.4.10 step 5). No-op if `return` is missing / not
/// callable.
fn closeIterOnAbrupt(realm: *Realm, iter_obj: *JSObject, iter_v: Value) void {
    const saved = realm.pending_exception;
    const ret_v = getPropertyChain(realm, iter_obj, "return") catch {
        realm.pending_exception = saved;
        return;
    };
    if (ret_v.isUndefined() or ret_v.isNull()) return;
    const ret_fn = heap_mod.valueAsFunction(ret_v) orelse return;
    const outcome = lantern.callJSFunction(realm.allocator, realm, ret_fn, iter_v, &.{}) catch {
        realm.pending_exception = saved;
        return;
    };
    _ = outcome;
    // Discard any throw from `return`; original abrupt wins.
    realm.pending_exception = saved;
}

fn arrayAt(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    // §23.1.3.1 Array.prototype.at:
    //   1. O = ToObject(this)
    //   2. len = ? LengthOfArrayLike(O)
    //   3. relativeIndex = ? ToIntegerOrInfinity(index)
    //   4-5. k = relativeIndex >= 0 ? relativeIndex : len + relativeIndex
    //   6. If k < 0 or k >= len, return undefined
    //   7. Return ? Get(O, ToString(k))
    const obj = try toObjectThis(realm, this_value);
    const len = try intrinsics.clampArrayLengthR(realm, try toLengthOf(realm, obj));
    // Route through `toIntPropagating` so an object-with-valueOf
    // index fires its hook and a Symbol throws.
    var idx: i64 = if (args.len > 0) try toIntPropagating(realm, args[0]) else 0;
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
    // §7.1.20 cap; the effective fill range (start..end) is what
    // we'll iterate, not `len`.
    const safe_max: i64 = (1 << 53) - 1;
    var len = try toLengthOf(realm, obj);
    if (len > safe_max) len = safe_max;
    // §23.1.3.7 step 5-9 — start / end use ToIntegerOrInfinity,
    // which fires through ToPrimitive (valueOf / toString /
    // @@toPrimitive). The `try` propagates a thrown coercion.
    var start: i64 = if (args.len > 1) try toIntPropagating(realm, args[1]) else 0;
    var end: i64 = if (args.len > 2 and !args[2].isUndefined()) try toIntPropagating(realm, args[2]) else len;
    if (start < 0) start = @max(len + start, 0);
    if (end < 0) end = @max(len + end, 0);
    start = @min(start, len);
    end = @min(end, len);
    // Cap only the *effective* fill window, not `len`. Fixtures
    // like `fill/length-near-integer-limit` have `length: 2^53-1`
    // and a 3-index window — must not RangeError.
    if (end - start > max_iter_length) {
        const ex = intrinsics.newRangeError(realm, "Array.fill window exceeds maximum supported") catch return error.OutOfMemory;
        realm.pending_exception = ex;
        return error.NativeThrew;
    }
    var i = start;
    while (i < end) : (i += 1) {
        if ((i & 0x3FF) == 0) try intrinsics.checkInterruptInNative(realm);
        var ibuf: [24]u8 = undefined;
        const islice = std.fmt.bufPrint(&ibuf, "{d}", .{i}) catch unreachable;
        const owned = realm.heap.allocateString(islice) catch return error.OutOfMemory;
        // §23.1.3.7 step 11.b — Set(O, Pk, value, true). Honor
        // accessor setters / writable / extensible.
        try setOrThrow(realm, obj, owned.flatBytes(), owned, value);
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
    // A large but finite value (|d| > i64::MAX ≈ 9.22e18) must
    // saturate, not trap the host — `@intFromFloat` panics out of
    // range. The clamp lands at the same boundary the callers'
    // index arithmetic already handles for ±Infinity (#23).
    return intrinsics.doubleToI64Saturating(d);
}

fn arrayLastIndexOf(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const obj = try toObjectThis(realm, this_value);
    const target = argOr(args, 0, Value.undefined_);
    var raw_len = try toLengthOf(realm, obj);
    if (raw_len <= 0) return Value.fromInt32(-1);
    const safe_max: i64 = (1 << 53) - 1;
    if (raw_len > safe_max) raw_len = safe_max;
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
    // Plain-object array-likes with a huge `length` (e.g.
    // `{0: x, 4294967295: x, length: 4294967296}` from
    // 15.4.4.15-3-28) can't run a linear loop from `start` down
    // to 0 — it would chew through ~2^32 iterations. Walk the
    // receiver's own integer-indexed property bag descending,
    // checking only the keys that actually exist. Inherited
    // indexed accessors on the prototype chain are skipped
    // (matches the sparseReverseSearch trade-off).
    if (!obj.is_array_exotic and start + 1 > max_iter_length) {
        if (try plainObjectReverseSearch(realm, obj, start, target)) |found| return numberFromI64(found);
        return Value.fromInt32(-1);
    }
    if (start + 1 > max_iter_length) {
        const ex = intrinsics.newRangeError(realm, "Array length window exceeds maximum supported") catch return error.OutOfMemory;
        realm.pending_exception = ex;
        return error.NativeThrew;
    }
    var i: i64 = start;
    while (i >= 0) : (i -= 1) {
        if ((i & 0x3FF) == 0) try intrinsics.checkInterruptInNative(realm);
        var ibuf: [24]u8 = undefined;
        const islice = std.fmt.bufPrint(&ibuf, "{d}", .{i}) catch unreachable;
        if (!obj.hasProperty(islice)) continue;
        const v = try getPropertyChain(realm, obj, islice);
        if (strictEqualsLite(v, target)) return numberFromI64(i);
    }
    return Value.fromInt32(-1);
}

/// Plain-object reverse-search helper for `lastIndexOf` against
/// an array-like with a huge nominal `length` and a small set of
/// actual own integer-indexed properties. Walks the property bag
/// descending, considering only own keys whose ToInteger value is
/// in [0, `start`]. Returns the index that strict-equals `target`,
/// or `null` if none. Skips the inherited-indexed-accessor case
/// — same trade-off `sparseReverseSearch` makes. Keys ≤ 2^53-1
/// (the §7.1.20 ToLength ceiling) are honoured so fixtures like
/// `lastIndexOf/length-near-integer-limit` (own key at 2^53-4)
/// find the match.
fn plainObjectReverseSearch(realm: *Realm, obj: *JSObject, start: i64, target: Value) NativeError!?i64 {
    var keys: std.ArrayListUnmanaged(i64) = .empty;
    defer keys.deinit(realm.allocator);
    var it = obj.iterOwnNamedKeys();
    while (it.next()) |entry| {
        const k = entry.key_ptr.*;
        const idx = std.fmt.parseInt(i64, k, 10) catch continue;
        if (idx < 0 or idx > start) continue;
        keys.append(realm.allocator, idx) catch return error.OutOfMemory;
    }
    std.mem.sort(i64, keys.items, {}, struct {
        fn descending(_: void, a: i64, b: i64) bool {
            return a > b;
        }
    }.descending);
    for (keys.items) |k| {
        var ibuf: [24]u8 = undefined;
        const islice = std.fmt.bufPrint(&ibuf, "{d}", .{k}) catch unreachable;
        if (!obj.hasProperty(islice)) continue;
        const v = try getPropertyChain(realm, obj, islice);
        if (strictEqualsLite(v, target)) return k;
    }
    return null;
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
    var len = try toLengthOf(realm, obj);
    const safe_max: i64 = (1 << 53) - 1;
    if (len > safe_max) len = safe_max;
    const callback = heap_mod.valueAsFunction(argOr(args, 0, Value.undefined_)) orelse return throwTypeError(realm, "Array.prototype.findLast callback must be a function");
    const this_arg = argOr(args, 1, Value.undefined_);
    // findLast walks descending; predicate-returns-true short-
    // circuits. Don't refuse a 2^53-1 length when the search is
    // likely to terminate early — but cap raw iteration count
    // anyway to bound the worst case.
    var i: i64 = len - 1;
    const iter_limit = max_iter_length;
    var seen: i64 = 0;
    while (i >= 0) : (i -= 1) {
        var ibuf: [24]u8 = undefined;
        const islice = std.fmt.bufPrint(&ibuf, "{d}", .{i}) catch unreachable;
        const elem = try getPropertyChain(realm, obj, islice);
        const v = try invokeCallback(realm, callback, this_arg, elem, i, obj);
        if (toBoolean(v)) return elem;
        seen += 1;
        if (seen >= iter_limit) {
            const ex = intrinsics.newRangeError(realm, "Array length window exceeds maximum supported") catch return error.OutOfMemory;
            realm.pending_exception = ex;
            return error.NativeThrew;
        }
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
    var len = try toLengthOf(realm, obj);
    const safe_max: i64 = (1 << 53) - 1;
    if (len > safe_max) len = safe_max;
    const callback = heap_mod.valueAsFunction(argOr(args, 0, Value.undefined_)) orelse return throwTypeError(realm, "Array.prototype.findLastIndex callback must be a function");
    const this_arg = argOr(args, 1, Value.undefined_);
    var i: i64 = len - 1;
    const iter_limit = max_iter_length;
    var seen: i64 = 0;
    while (i >= 0) : (i -= 1) {
        var ibuf: [24]u8 = undefined;
        const islice = std.fmt.bufPrint(&ibuf, "{d}", .{i}) catch unreachable;
        const elem = try getPropertyChain(realm, obj, islice);
        const v = try invokeCallback(realm, callback, this_arg, elem, i, obj);
        if (toBoolean(v)) return numberFromI64(i);
        seen += 1;
        if (seen >= iter_limit) {
            const ex = intrinsics.newRangeError(realm, "Array length window exceeds maximum supported") catch return error.OutOfMemory;
            realm.pending_exception = ex;
            return error.NativeThrew;
        }
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

    // Pin the receiver and the running accumulator across the
    // re-entrant callback loops below (`acc` gets a dedicated slot
    // refreshed at each loop top).
    const scope = realm.heap.openScope() catch return error.OutOfMemory;
    defer scope.close();
    scope.push(heap_mod.taggedObject(obj)) catch return error.OutOfMemory;
    scope.push(acc) catch return error.OutOfMemory;
    const acc_slot = scope.handles.items.len - 1;

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
            scope.handles.items[acc_slot] = acc;
            const k = ks[idx];
            const elem = obj.sparse_elements.get(k) orelse continue;
            const cb_args = [_]Value{ acc, elem, numberFromI64(@as(i64, k)), heap_mod.taggedObject(obj) };
            const outcome = lantern.callJSFunction(realm.allocator, realm, callback, Value.undefined_, &cb_args) catch |err| switch (err) {
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

    var raw_len = try toLengthOf(realm, obj);
    const safe_max_rr: i64 = (1 << 53) - 1;
    if (raw_len > safe_max_rr) raw_len = safe_max_rr;
    // Plain-object array-like with a near-MAX_SAFE_INTEGER `length`
    // and a small set of own integer-indexed properties: walk those
    // own keys descending instead of running a linear loop. Fixture
    // `reduceRight/length-near-integer-limit` is the motivating case.
    if (!obj.is_array_exotic and raw_len > max_iter_length) {
        return reduceRightOwnIndicesDescending(realm, obj, raw_len - 1, callback, acc, have_acc);
    }
    const len = try intrinsics.clampArrayLengthR(realm, raw_len);
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
        scope.handles.items[acc_slot] = acc;
        var ibuf: [24]u8 = undefined;
        const islice = std.fmt.bufPrint(&ibuf, "{d}", .{i}) catch unreachable;
        if (!obj.hasProperty(islice)) continue;
        const elem = try getPropertyChain(realm, obj, islice);

        const cb_args = [_]Value{ acc, elem, numberFromI64(i), heap_mod.taggedObject(obj) };
        const outcome = lantern.callJSFunction(realm.allocator, realm, callback, Value.undefined_, &cb_args) catch |err| switch (err) {
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

/// reduceRight specialization for plain-object array-likes with a
/// huge nominal `length`. Walks own integer-indexed properties
/// descending in [0, start], invoking `callback(acc, val, idx, O)`
/// per spec. Skips inherited indexed accessors (same trade-off as
/// `sparseReverseSearch`). Used only when the linear-loop path
/// would chew through more than `max_iter_length` indices.
fn reduceRightOwnIndicesDescending(
    realm: *Realm,
    obj: *JSObject,
    start: i64,
    callback: *@import("../function.zig").JSFunction,
    initial_acc: Value,
    have_initial: bool,
) NativeError!Value {
    var keys: std.ArrayListUnmanaged(i64) = .empty;
    defer keys.deinit(realm.allocator);
    var it = obj.iterOwnNamedKeys();
    while (it.next()) |entry| {
        const k = entry.key_ptr.*;
        const idx = std.fmt.parseInt(i64, k, 10) catch continue;
        if (idx < 0 or idx > start) continue;
        keys.append(realm.allocator, idx) catch return error.OutOfMemory;
    }
    std.mem.sort(i64, keys.items, {}, struct {
        fn descending(_: void, a: i64, b: i64) bool {
            return a > b;
        }
    }.descending);
    var acc = initial_acc;
    var have_acc = have_initial;
    // Pin the receiver and the running accumulator across the
    // re-entrant callback loop.
    const scope = realm.heap.openScope() catch return error.OutOfMemory;
    defer scope.close();
    scope.push(heap_mod.taggedObject(obj)) catch return error.OutOfMemory;
    scope.push(acc) catch return error.OutOfMemory;
    const acc_slot = scope.handles.items.len - 1;
    var idx: usize = 0;
    if (!have_acc) {
        if (keys.items.len == 0) return throwTypeError(realm, "Reduce of empty array with no initial value");
        var ib: [24]u8 = undefined;
        const isl = std.fmt.bufPrint(&ib, "{d}", .{keys.items[0]}) catch unreachable;
        acc = try getPropertyChain(realm, obj, isl);
        have_acc = true;
        idx = 1;
    }
    while (idx < keys.items.len) : (idx += 1) {
        scope.handles.items[acc_slot] = acc;
        const k = keys.items[idx];
        var ib: [24]u8 = undefined;
        const isl = std.fmt.bufPrint(&ib, "{d}", .{k}) catch unreachable;
        if (!obj.hasProperty(isl)) continue;
        const elem = try getPropertyChain(realm, obj, isl);
        const cb_args = [_]Value{ acc, elem, numberFromI64(k), heap_mod.taggedObject(obj) };
        const outcome = lantern.callJSFunction(realm.allocator, realm, callback, Value.undefined_, &cb_args) catch |err| switch (err) {
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

fn arrayFlat(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const obj = try toObjectThis(realm, this_value);
    // §23.1.3.10 step 2 — `sourceLen = LengthOfArrayLike(O)` runs
    // BEFORE depth coercion and BEFORE ArraySpeciesCreate. Route
    // through the Proxy-aware accessor so the `length` get trap
    // fires first (the `proxy-access-count.js` fixture asserts the
    // exact trap sequence `[length, constructor, 0, 1, ...]`).
    const len_v = try getPropertyAny(realm, heap_mod.taggedObject(obj), "length");
    const source_len = try intrinsics.clampArrayLengthR(realm, try intrinsics.toLengthValue(realm, len_v));
    // §23.1.3.10 step 3 — `depth = ? ToIntegerOrInfinity(args[0])`.
    // Undefined defaults to 1 BEFORE the coercion (so a missing
    // arg flattens one level). For an explicit `undefined` or
    // `null`, ToIntegerOrInfinity → 0; for a string "TestString"
    // or an object, ToNumber → NaN → 0.
    var depth: i64 = 1;
    if (args.len > 0 and !args[0].isUndefined()) {
        const depth_v = args[0];
        if (depth_v.isInt32()) {
            depth = depth_v.asInt32();
            if (depth < 0) depth = 0;
        } else if (depth_v.isDouble()) {
            const d = depth_v.asDouble();
            if (std.math.isNan(d) or d < 0) {
                depth = 0;
            } else if (std.math.isInf(d)) {
                depth = std.math.maxInt(i32);
            } else {
                depth = @intFromFloat(@trunc(d));
            }
        } else {
            // §7.1.5 ToIntegerOrInfinity = ToNumber → trunc.
            // ToNumber of a Symbol throws; ToNumber of an Object
            // runs ToPrimitive → valueOf/toString; both routed via
            // `intrinsics.toNumber`.
            const nv = try intrinsics.toNumber(realm, depth_v);
            const d: f64 = if (nv.isInt32()) @floatFromInt(nv.asInt32()) else nv.asDouble();
            if (std.math.isNan(d) or d < 0) {
                depth = 0;
            } else if (std.math.isInf(d)) {
                depth = std.math.maxInt(i32);
            } else {
                depth = @intFromFloat(@trunc(d));
            }
        }
    }
    // §23.1.3.10 step 4 — ArraySpeciesCreate(O, 0). Fires the
    // "constructor" Get on the receiver after the "length" probe
    // above; the Proxy-aware path inside arraySpeciesCreate
    // surfaces both observably.
    const out_v = try arraySpeciesCreate(realm, obj, 0);
    const out = heap_mod.valueAsPlainObject(out_v) orelse return throwTypeError(realm, "ArraySpeciesCreate did not return an object");
    // Pin the result and the receiver across the recursive,
    // re-entrant flatten walk.
    const scope = realm.heap.openScope() catch return error.OutOfMemory;
    defer scope.close();
    scope.push(out_v) catch return error.OutOfMemory;
    scope.push(heap_mod.taggedObject(obj)) catch return error.OutOfMemory;
    var write_idx: i64 = 0;
    try flattenInto(realm, obj, source_len, depth, out, &write_idx);
    // §23.1.3.13.1 FlattenIntoArray relies on `CreateDataPropertyOrThrow`
    // for the per-index write; an Array exotic's `length` auto-extends
    // as a side effect. For a non-Array species result (e.g.
    // `arr.constructor = { [Symbol.species]: ctor }` returning a plain
    // object) the spec never writes `length` — stamping it added a
    // phantom own property (and bypassed the shape-aware write funnels
    // on a shape-mode receiver). Mirror the flatMap gate below.
    if (out.is_array_exotic) {
        setLength(realm, out, write_idx) catch return error.OutOfMemory;
    }
    return out_v;
}

fn flattenInto(realm: *Realm, source: *JSObject, source_len: i64, depth: i64, target: *JSObject, write_idx: *i64) NativeError!void {
    // Native-stack guard. §23.1.3.10.1 FlattenIntoArray recurses one
    // level per nested array up to `depth` — `arr.flat(Infinity)` on
    // a deeply nested (or runtime-built `a=[a]`×N) array would
    // otherwise overflow the host stack. Throw the RangeError V8 /
    // JSC give for stack-exhausting flattening instead of crashing.
    if (@import("../../stack_guard.zig").nearLimit()) {
        const ex = intrinsics.newRangeError(realm, "Maximum call stack size exceeded") catch return error.OutOfMemory;
        realm.pending_exception = ex;
        return error.NativeThrew;
    }
    // §23.1.3.10.1 FlattenIntoArray step 3 — visit `sourceLen`
    // indices using `HasProperty` + `Get` on the source. Route
    // through the Proxy-aware helpers so traps fire per spec
    // (`proxy-access-count.js` pins the exact sequence).
    // Pin this recursion level's source and the in-flight element
    // across the re-entrant `HasProperty` / `Get` / recursion.
    const scope = realm.heap.openScope() catch return error.OutOfMemory;
    defer scope.close();
    scope.push(heap_mod.taggedObject(source)) catch return error.OutOfMemory;
    scope.push(heap_mod.taggedObject(target)) catch return error.OutOfMemory;
    const scope_base = scope.handles.items.len;
    const len = source_len;
    var i: i64 = 0;
    while (i < len) : (i += 1) {
        var ibuf: [24]u8 = undefined;
        const islice = std.fmt.bufPrint(&ibuf, "{d}", .{i}) catch unreachable;
        if (!(try hasPropertyP(realm, source, islice))) continue;
        const elem = try getPropertyAny(realm, heap_mod.taggedObject(source), islice);
        scope.push(elem) catch return error.OutOfMemory;
        const should_flatten = depth > 0 and isArrayLike(elem);
        if (should_flatten) {
            const inner = heap_mod.valueAsPlainObject(elem).?;
            // §23.1.3.10.1 step 9.c.iv — `LengthOfArrayLike(element)`
            // before recursing. Route through the Proxy-aware
            // accessor so a nested proxy's `length` get trap fires.
            const inner_len_v = try getPropertyAny(realm, elem, "length");
            const inner_len = try intrinsics.clampArrayLengthR(realm, try intrinsics.toLengthValue(realm, inner_len_v));
            try flattenInto(realm, inner, inner_len, depth - 1, target, write_idx);
        } else {
            // §23.1.3.10.1 FlattenIntoArray step 9.c.vi.2 —
            // CreateDataPropertyOrThrow. Non-writable own slot on
            // the target is configurable-redefined back to the
            // all-true default; non-extensible target throws.
            var wbuf: [24]u8 = undefined;
            const wslice = std.fmt.bufPrint(&wbuf, "{d}", .{write_idx.*}) catch unreachable;
            const owned = realm.heap.allocateString(wslice) catch return error.OutOfMemory;
            try createDataPropertyOrThrowGeneric(realm, target, owned, elem);
            write_idx.* += 1;
        }
        scope.handles.shrinkRetainingCapacity(scope_base);
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
    // §23.1.3.11 step 2 — `LengthOfArrayLike(O)`. Route through
    // the Proxy-aware accessor so a `get` trap on "length" fires
    // (the `proxy-access-count.js` fixture pins the exact trap
    // order `[length, constructor, ...]`).
    const len_v = try getPropertyAny(realm, heap_mod.taggedObject(obj), "length");
    const len = try intrinsics.clampArrayLengthR(realm, try intrinsics.toLengthValue(realm, len_v));

    // §23.1.3.11 step 5 — ArraySpeciesCreate(O, 0).
    const out_v = try arraySpeciesCreate(realm, obj, 0);
    const out = heap_mod.valueAsPlainObject(out_v) orelse return throwTypeError(realm, "ArraySpeciesCreate did not return an object");
    // Pin the result and receiver across the re-entrant callback
    // loop; root the in-flight mapped value per iteration.
    const scope = realm.heap.openScope() catch return error.OutOfMemory;
    defer scope.close();
    scope.push(out_v) catch return error.OutOfMemory;
    scope.push(heap_mod.taggedObject(obj)) catch return error.OutOfMemory;
    const scope_base = scope.handles.items.len;
    var write_idx: i64 = 0;
    var i: i64 = 0;
    while (i < len) : (i += 1) {
        var ibuf: [24]u8 = undefined;
        const islice = std.fmt.bufPrint(&ibuf, "{d}", .{i}) catch unreachable;
        // §23.1.3.11.1 FlattenIntoArray step 3.b/c — Proxy-aware
        // `HasProperty` + `Get` so the receiver's `has` / `get`
        // traps fire per index.
        if (!(try hasPropertyP(realm, obj, islice))) continue;
        const elem = try getPropertyAny(realm, heap_mod.taggedObject(obj), islice);
        const mapped = try invokeCallback(realm, callback, this_arg, elem, i, obj);
        scope.push(mapped) catch return error.OutOfMemory;
        if (isArrayLike(mapped)) {
            // §23.1.3.11.1 step 9.c.iv — `LengthOfArrayLike(element)`.
            // Proxy-aware so a nested-proxy `length` get trap fires.
            const inner_len_v = try getPropertyAny(realm, mapped, "length");
            const inner_len = try intrinsics.clampArrayLengthR(realm, try intrinsics.toLengthValue(realm, inner_len_v));
            const inner_obj = heap_mod.valueAsPlainObject(mapped) orelse return throwTypeError(realm, "Array.prototype.flatMap: flattened element is not an object");
            var j: i64 = 0;
            while (j < inner_len) : (j += 1) {
                var jbuf: [24]u8 = undefined;
                const jslice = std.fmt.bufPrint(&jbuf, "{d}", .{j}) catch unreachable;
                // §23.1.3.11.1 step 3.b — HasProperty on the
                // inner element so holes are skipped and a Proxy
                // `has` trap fires.
                if (!(try hasPropertyP(realm, inner_obj, jslice))) continue;
                const v = try getPropertyAny(realm, mapped, jslice);
                var wbuf: [24]u8 = undefined;
                const wslice = std.fmt.bufPrint(&wbuf, "{d}", .{write_idx}) catch unreachable;
                const owned = realm.heap.allocateString(wslice) catch return error.OutOfMemory;
                // §23.1.3.11.1 FlattenIntoArray step 9.c.vi.2 —
                // CreateDataPropertyOrThrow on the result, not
                // [[Set]]. Non-extensible target throws; non-
                // configurable own slot throws; non-writable own
                // slot is configurable-redefined.
                try createDataPropertyOrThrowGeneric(realm, out, owned, v);
                write_idx += 1;
            }
        } else {
            var wbuf: [24]u8 = undefined;
            const wslice = std.fmt.bufPrint(&wbuf, "{d}", .{write_idx}) catch unreachable;
            const owned = realm.heap.allocateString(wslice) catch return error.OutOfMemory;
            try createDataPropertyOrThrowGeneric(realm, out, owned, mapped);
            write_idx += 1;
        }
        scope.handles.shrinkRetainingCapacity(scope_base);
    }
    // §23.1.3.11.1 FlattenIntoArray relies on `CreateDataPropertyOrThrow`
    // for the per-index write; an Array exotic's `length` auto-extends
    // as a side effect. For a non-Array species result (e.g.
    // `arr.constructor = { [Symbol.species]: ctor }` returning a plain
    // object) the spec leaves `length` alone — the fixture
    // `flatMap/this-value-ctor-object-species-custom-ctor.js` asserts
    // the result has NO own `length`. Only stamp it on Array-shaped
    // results where the property already exists.
    if (out.is_array_exotic) {
        setLength(realm, out, write_idx) catch return error.OutOfMemory;
    }
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
    // §23.1.3.30 step 2 — `len = ? LengthOfArrayLike(O)`. Route
    // through the proxy-aware path so a `get` trap on `length`
    // fires (test262
    // built-ins/Array/prototype/splice/create-species-undef-invalid-len,
    // create-species-length-exceeding-integer-limit).
    const len_v = try getPropertyAny(realm, heap_mod.taggedObject(obj), "length");
    var len = try intrinsics.toLengthValue(realm, len_v);
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
                const candidate = len + @as(i64, @intFromFloat(@max(t, -@as(f64, @floatFromInt(safe_max)))));
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

    // Pin the removed-elements array and the receiver across the
    // re-entrant copy / shift / insert loops below.
    const scope = realm.heap.openScope() catch return error.OutOfMemory;
    defer scope.close();
    scope.push(removed_v) catch return error.OutOfMemory;
    scope.push(heap_mod.taggedObject(obj)) catch return error.OutOfMemory;

    // §23.1.3.29 step 12-13 — copy O[start..start+actualDeleteCount-1]
    // into A. Uses HasProperty for hole-aware copy + CreateDataPropertyOrThrow
    // so existing accessor props on `A` don't intercept the per-index write.
    // Dispatch HasProperty and Get through the proxy-aware helpers
    // so a Proxy `O` fires its `has` / `get` traps and the
    // `defineProperty` trap on `A` fires per the spec ordering
    // (test262 splice/create-species-length-exceeding-integer-limit,
    // splice/property-traps-order-with-species).
    var i: i64 = 0;
    while (i < delete_count) : (i += 1) {
        var rbuf: [24]u8 = undefined;
        const rslice = std.fmt.bufPrint(&rbuf, "{d}", .{start + i}) catch unreachable;
        if (!(try hasPropertyP(realm, obj, rslice))) continue;
        const v = try getPropertyAny(realm, heap_mod.taggedObject(obj), rslice);
        var wbuf: [24]u8 = undefined;
        const wslice = std.fmt.bufPrint(&wbuf, "{d}", .{i}) catch unreachable;
        const owned = realm.heap.allocateString(wslice) catch return error.OutOfMemory;
        try createDataPropertyOrThrowGeneric(realm, removed, owned, v);
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
                try setOrThrow(realm, obj, owned.flatBytes(), owned, v);
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
                try setOrThrow(realm, obj, owned.flatBytes(), owned, v);
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
        try setOrThrow(realm, obj, owned.flatBytes(), owned, args[2 + @as(usize, @intCast(ins))]);
    }

    // §23.1.3.29 step 19 — ? Set(O, "length", len - dc + ic, true).
    try setLengthOrThrow(realm, obj, new_len);
    return removed_v;
}

/// §7.3.7 CreateDataPropertyOrThrow — local variant for callers
/// not in the `Array.fromAsync` state-machine. Lands `value` as an
/// own data property with `{w:T,e:T,c:T}`; rejects non-extensible
/// receivers and non-configurable redefines with TypeError.
fn createDataPropertyOrThrowGeneric(realm: *Realm, obj: *JSObject, key_str: *JSString, value: Value) NativeError!void {
    const ObjMod = @import("../object.zig");
    const key = key_str.flatBytes();
    // §7.3.6 CreateDataPropertyOrThrow — for a Proxy receiver,
    // OrdinaryDefineOwnProperty becomes the proxy `defineProperty`
    // trap. Trap-thrown abrupt completions surface here; a falsy
    // trap return is lifted to TypeError per §7.3.6 step 3.
    // (test262 Array.prototype.splice
    // property-traps-order-with-species,
    // create-species-length-exceeding-integer-limit).
    const proxy_mod = @import("proxy.zig");
    var cur = obj;
    while (cur.proxy_target != null or cur.proxy_revoked) {
        const r = try proxy_mod.nativeProxyDefineProperty(realm, cur, key, value, null);
        switch (r) {
            .boolean => |b| {
                if (!b) return throwTypeError(realm, "CreateDataPropertyOrThrow: 'defineProperty' trap returned false");
                return;
            },
            .fallthrough => |t| {
                if (t == cur) break;
                cur = t;
            },
        }
    }
    const had_own = cur.hasOwn(key);
    if (!had_own and !cur.extensible) {
        return throwTypeError(realm, "Cannot define property on non-extensible object");
    }
    if (had_own) {
        const cur_flags = cur.flagsFor(key);
        if (!cur_flags.configurable) {
            return throwTypeError(realm, "Cannot redefine non-configurable property");
        }
        // §10.1.6.3 OrdinaryDefineOwnProperty — a configurable slot
        // can be redefined back to the all-true default. Clear any
        // demoted indexed-slot entry from `properties` so the
        // subsequent `setWithFlags(default)` lands in `elements`
        // again rather than leaving the bag-promoted descriptor.
        // Demote first — the shadow shape can't encode a removal.
        try cur.demoteFromShape(realm.allocator);
        _ = cur.properties.swapRemove(key);
        _ = cur.property_flags.swapRemove(key);
    }
    // Generational write barrier — `setWithFlags` is a raw setter
    // (bypasses the routed `heap.storeProperty` / `storeIndexed`),
    // so a young `value` stored into a mature `cur` would otherwise
    // be an un-remembered old→young edge the next minor cycle drops.
    realm.heap.writeBarrier(.{ .object = cur }, value);
    cur.setWithFlags(realm.allocator, key, value, ObjMod.PropertyFlags.default) catch return error.OutOfMemory;
    // The key is a borrowed slice of a heap-allocated JSString. If it
    // landed in the named-property bag (rather than the array-exotic
    // `elements` vector), anchor the string so GC keeps the key alive.
    if (cur.ownDataContains(key)) {
        cur.anchorKey(realm.allocator, key_str) catch return error.OutOfMemory;
        cur.markNonPristine();
    }
}

fn arrayCopyWithin(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    // §23.1.3.4 step 1-3 — ToObject, then LengthOfArrayLike via the
    // accessor-aware path so a throwing `length` getter propagates.
    const obj = try toObjectThis(realm, this_value);
    // §7.1.20 ToLength cap at 2^53-1. Don't apply Cynic's 16M
    // iteration cap to `len` itself — the spec bounds the loop on
    // the small `count` derived from (end - start, len - target),
    // and a fixture with `length: 2^53-1` and a 3-element range
    // must not RangeError.
    const safe_max: i64 = (1 << 53) - 1;
    // §23.1.3.4 step 2 — `LengthOfArrayLike(O)`. Proxy-aware so a
    // `get` trap on `length` fires before coercion (test262
    // built-ins/Array/prototype/copyWithin/
    // return-abrupt-from-has-start.js uses a Proxy without a `has`
    // trap fire path unless `length` is observed first).
    const len_v = try getPropertyAny(realm, heap_mod.taggedObject(obj), "length");
    var len = try intrinsics.toLengthValue(realm, len_v);
    if (len > safe_max) len = safe_max;
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
    if (count <= 0) return heap_mod.taggedObject(obj);
    if (count > max_iter_length) {
        const ex = intrinsics.newRangeError(realm, "copyWithin count exceeds maximum supported") catch return error.OutOfMemory;
        realm.pending_exception = ex;
        return error.NativeThrew;
    }

    // §23.1.3.4 steps 14-18 — HasProperty / Get / Set / Delete on
    // each visited index. Direction matters when ranges overlap.
    // Use the accessor-aware `getPropertyChain` so a poisoned
    // getter on a copied source slot propagates, and fall back to
    // `Delete` when the source slot is a hole.
    if (start < target and target < start + count) {
        var k: i64 = count - 1;
        while (k >= 0) : (k -= 1) {
            if ((k & 0x3FF) == 0) try intrinsics.checkInterruptInNative(realm);
            try copyWithinStep(realm, obj, start + k, target + k);
        }
    } else {
        var k: i64 = 0;
        while (k < count) : (k += 1) {
            if ((k & 0x3FF) == 0) try intrinsics.checkInterruptInNative(realm);
            try copyWithinStep(realm, obj, start + k, target + k);
        }
    }
    // §23.1.3.4 step 19 — Return O. For a non-Object receiver
    // (Boolean / Number / String / Symbol / BigInt), `toObjectThis`
    // produced a fresh wrapper above; `this_value` is the raw
    // primitive. Return the wrapper so `copyWithin.call(true)` is
    // a Boolean wrapper per §7.1.18 ToObject step 4.
    return heap_mod.taggedObject(obj);
}

fn copyWithinStep(realm: *Realm, obj: *JSObject, src: i64, dst: i64) NativeError!void {
    var sb: [24]u8 = undefined;
    var db: [24]u8 = undefined;
    const sslice = std.fmt.bufPrint(&sb, "{d}", .{src}) catch unreachable;
    const dslice = std.fmt.bufPrint(&db, "{d}", .{dst}) catch unreachable;
    // §23.1.3.4 step 15.b — HasProperty(O, fromKey). Dispatch
    // through the Proxy `has` trap so a poisoned trap propagates
    // its abrupt completion (fixture
    // `copyWithin/return-abrupt-from-has-start.js`).
    const present = try hasPropertyP(realm, obj, sslice);
    if (present) {
        const v = try getPropertyChain(realm, obj, sslice);
        // §23.1.3.4 step 15.b.iv — Set(O, toKey, fromVal, true).
        // Honor setter / writable / extensible.
        const owned = realm.heap.allocateString(dslice) catch return error.OutOfMemory;
        try setOrThrow(realm, obj, owned.flatBytes(), owned, v);
    } else {
        try deletePropertyOrThrow(realm, obj, dslice);
    }
}

/// §7.3.11 HasProperty — proxy-aware wrapper. Dispatches through
/// the Proxy `has` trap (§10.5.7) before falling through to
/// §10.1.7.1 OrdinaryHasProperty.
fn hasPropertyP(realm: *Realm, obj: *JSObject, key: []const u8) NativeError!bool {
    const proxy_mod = @import("proxy.zig");
    var cur = obj;
    while (cur.proxy_target != null or cur.proxy_revoked) {
        const r = try proxy_mod.nativeProxyHas(realm, cur, key, null);
        switch (r) {
            .boolean => |b| return b,
            .fallthrough => |t| {
                if (t == cur) return cur.hasProperty(key);
                cur = t;
            },
        }
    }
    return cur.hasProperty(key);
}

fn arraySort(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    // §23.1.3.30 step 1 — comparefn validation (callable or
    // undefined) runs before ToObject and length, so a non-callable
    // comparator throws synchronously.
    const cmp_v = argOr(args, 0, Value.undefined_);
    const cmp_fn: ?*JSFunction = if (cmp_v.isUndefined())
        null
    else if (heap_mod.valueAsFunction(cmp_v)) |f| f else return throwTypeError(realm, "comparefn must be a function or undefined");
    const obj = try toObjectThis(realm, this_value);
    const len = try intrinsics.clampArrayLengthR(realm, try toLengthOf(realm, obj));
    if (len <= 1) return heap_mod.taggedObject(obj);

    // §23.1.3.30 Array.prototype.sort — spec-precise drive.
    // §23.1.3.30.1 SortIndexedProperties(obj, len, SortCompare,
    // skip-holes): collect items via [[HasProperty]] +
    // [[Get]] (both walk the prototype chain and fire accessor
    // getters, so getters that mutate the array are observed
    // exactly once per slot). Sort the collected items with
    // SortCompare, which §23.1.3.30.2 CompareArrayElements
    // pushes undefineds to the end without invoking the
    // user comparator.
    //
    // Then per §23.1.3.30 steps 7-8: write items back via [[Set]]
    // at 0..items.len-1 (firing inherited accessor setters,
    // honouring read-only / non-extensible, surfacing length-
    // mutating setters) and DeletePropertyOrThrow at
    // items.len..original-len-1 to preserve "absent" slots.
    // Pin the receiver and every gathered item: the collect loop's
    // getters and `sortBufferStable`'s comparator both re-enter JS,
    // and the items live only in a non-GC list until written back.
    const scope = realm.heap.openScope() catch return error.OutOfMemory;
    defer scope.close();
    scope.push(heap_mod.taggedObject(obj)) catch return error.OutOfMemory;
    var items: std.ArrayList(Value) = .empty;
    defer items.deinit(realm.allocator);
    var i: i64 = 0;
    while (i < len) : (i += 1) {
        var ibuf: [24]u8 = undefined;
        const islice = std.fmt.bufPrint(&ibuf, "{d}", .{i}) catch unreachable;
        // skip-holes: only enumerate present keys (own or inherited).
        // `JSObject.hasProperty` walks the prototype chain, so an
        // accessor inherited from %Object.prototype% is observed
        // as present and read through [[Get]].
        if (!obj.hasProperty(islice)) continue;
        const v = try getPropertyChain(realm, obj, islice);
        items.append(realm.allocator, v) catch return error.OutOfMemory;
        scope.push(v) catch return error.OutOfMemory;
    }

    // §23.1.3.30.1 step 4 — sort items with SortCompare. Undefineds
    // are pushed to the end by `sortCompare` itself; no partition
    // needed.
    try sortBufferStable(realm, items.items, cmp_fn);

    // §23.1.3.30 step 7 — Set(O, ToString(j), sortedList[j], true).
    // Honours accessor setters (own and inherited), read-only data,
    // array-exotic `length` writes, and a non-extensible receiver.
    var w: usize = 0;
    while (w < items.items.len) : (w += 1) {
        var wbuf: [24]u8 = undefined;
        const wslice = std.fmt.bufPrint(&wbuf, "{d}", .{w}) catch unreachable;
        // Anchor the key — `setOrThrow` may stash it in the
        // property bag if no accessor / array-exotic path absorbs
        // the write.
        const owned = realm.heap.allocateString(wslice) catch return error.OutOfMemory;
        try setOrThrow(realm, obj, owned.flatBytes(), owned, items.items[w]);
    }
    // §23.1.3.30 step 8 — DeletePropertyOrThrow up to the *original*
    // len. A setter that shrunk the array doesn't shorten the
    // delete loop; the spec runs against the snapshot taken at
    // step 3.
    var d: i64 = @intCast(items.items.len);
    while (d < len) : (d += 1) {
        var dbuf: [24]u8 = undefined;
        const dslice = std.fmt.bufPrint(&dbuf, "{d}", .{d}) catch unreachable;
        try deletePropertyOrThrow(realm, obj, dslice);
    }
    return heap_mod.taggedObject(obj);
}

/// In-place stable sort of `buf`. Uses simple insertion sort —
/// adequate for the test262 fixture sizes (most under a few
/// hundred) and keeps stability per §23.1.3.30 (Array.prototype.
/// sort is required to be stable as of ES2019).
fn sortBufferStable(realm: *Realm, buf: []Value, cmp_fn: ?*JSFunction) NativeError!void {
    // One reusable root scope for `sortCompare`'s ToString
    // intermediates — cleared per comparison, so the default
    // (comparator-less) sort doesn't allocate a fresh scope on
    // every compare.
    const cmp_scope = realm.heap.openScope() catch return error.OutOfMemory;
    defer cmp_scope.close();
    var n: usize = 1;
    while (n < buf.len) : (n += 1) {
        const key = buf[n];
        var j: isize = @as(isize, @intCast(n)) - 1;
        while (j >= 0) : (j -= 1) {
            const cmp = try sortCompare(realm, buf[@intCast(j)], key, cmp_fn, cmp_scope);
            // Stable: only shift left when strictly greater.
            if (cmp <= 0) break;
            buf[@intCast(j + 1)] = buf[@intCast(j)];
        }
        buf[@intCast(j + 1)] = key;
    }
}

/// §23.1.3.30.2 CompareArrayElements. Returns -1, 0, or +1.
/// Per steps 1-3, undefined operands sort after everything else
/// without invoking the user comparator — this is observable:
/// fixtures like `precise-comparefn-throws` expect a throwing
/// comparator to be skipped when one side is undefined.
/// With a user comparator, ToNumber is applied to the result
/// (NaN treated as +0). Without one, both operands go through
/// ToString and are compared lexically.
fn sortCompare(realm: *Realm, x: Value, y: Value, cmp_fn: ?*JSFunction, cmp_scope: *heap_mod.HandleScope) NativeError!i32 {
    // §23.1.3.30.2 steps 1-3 — undefineds last, before the user
    // comparator runs.
    const x_undef = x.isUndefined();
    const y_undef = y.isUndefined();
    if (x_undef and y_undef) return 0;
    if (x_undef) return 1;
    if (y_undef) return -1;
    if (cmp_fn) |c| {
        const cb_args = [_]Value{ x, y };
        const outcome = lantern.callJSFunction(realm.allocator, realm, c, Value.undefined_, &cb_args) catch |err| switch (err) {
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
    // `stringifyArg(y)` can re-enter JS (a user `toString` /
    // `valueOf`) and trigger a GC; `xs` is a native-stack-only
    // local until the comparison below, so root it across the call
    // on the caller's reusable scope (cleared per comparison).
    cmp_scope.handles.clearRetainingCapacity();
    cmp_scope.push(Value.fromString(xs)) catch return error.OutOfMemory;
    const ys = try intrinsics.stringifyArg(realm, y);
    return switch (std.mem.order(u8, xs.flatBytes(), ys.flatBytes())) {
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
    realm.heap.setObjectPrototype(out, realm.intrinsics.array_prototype);
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
    //
    // Pin `out`, the receiver and every gathered item: the read
    // loop and `sortBufferStable`'s comparator both re-enter JS,
    // and the items live only in a non-GC list until written back.
    const scope = realm.heap.openScope() catch return error.OutOfMemory;
    defer scope.close();
    scope.push(heap_mod.taggedObject(out)) catch return error.OutOfMemory;
    scope.push(heap_mod.taggedObject(obj)) catch return error.OutOfMemory;
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
            scope.push(v) catch return error.OutOfMemory;
        }
    }

    try sortBufferStable(realm, items.items, cmp_fn);

    var w: usize = 0;
    while (w < items.items.len) : (w += 1) {
        // Generational barrier — the comparator run by
        // `sortBufferStable` above can promote `out` to mature
        // while `items` still holds young values.
        realm.heap.writeBarrier(.{ .object = out }, items.items[w]);
        out.setIndexed(realm.allocator, @intCast(w), items.items[w]) catch return error.OutOfMemory;
    }
    var u: i64 = 0;
    while (u < undef_count) : (u += 1) {
        out.setIndexed(realm.allocator, @intCast(@as(i64, @intCast(items.items.len)) + u), Value.undefined_) catch return error.OutOfMemory;
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
    realm.heap.setObjectPrototype(out, realm.intrinsics.array_prototype);
    out.markAsArrayExotic(realm.allocator) catch return error.OutOfMemory;
    // Pin `out` and the receiver across the re-entrant read loop.
    const scope = realm.heap.openScope() catch return error.OutOfMemory;
    defer scope.close();
    scope.push(heap_mod.taggedObject(out)) catch return error.OutOfMemory;
    scope.push(heap_mod.taggedObject(obj)) catch return error.OutOfMemory;
    var i: i64 = 0;
    while (i < len) : (i += 1) {
        var rb: [24]u8 = undefined;
        const rslice = std.fmt.bufPrint(&rb, "{d}", .{len - 1 - i}) catch unreachable;
        const v = try getPropertyChain(realm, obj, rslice);
        // Generational barrier — `getPropertyChain` can re-enter JS
        // (a source getter / Proxy trap) and promote `out`.
        realm.heap.writeBarrier(.{ .object = out }, v);
        out.setIndexed(realm.allocator, @intCast(i), v) catch return error.OutOfMemory;
    }
    setLength(realm, out, len) catch return error.OutOfMemory;
    return heap_mod.taggedObject(out);
}

/// §23.1.3.35 Array.prototype.toSpliced — non-mutating sibling
/// of `splice`. Shares the start/deleteCount clamping with the
/// mutating version but writes into a fresh array.
fn arrayToSpliced(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const obj = try toObjectThis(realm, this_value);
    // §23.1.3.35 step 3 — `LengthOfArrayLike(O)`. Capture the raw
    // i64-saturating length so the newLen overflow gate (step 12,
    // §10.4.2.2 step 13) can fire for receivers with
    // length > 2^32 - 1 — `length-exceeding-array-length-limit.js`
    // pins receivers up to `length: 2 ** 53 + 1`.
    const safe_max: i64 = (1 << 53) - 1;
    var len_full = try toLengthOf(realm, obj);
    if (len_full > safe_max) len_full = safe_max;
    const len = len_full;
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
    // §23.1.3.35 step 12 — `If newLen > 2 ** 53 - 1, throw TypeError`.
    // Spec-faithful: TypeError here, RangeError only at the
    // §10.4.2.2 ArrayCreate gate (newLen > 2^32 - 1) below.
    if (new_len > safe_max) {
        return throwTypeError(realm, "Array.prototype.toSpliced: result length exceeds maximum length");
    }
    // §23.1.3.35 step 13 — `A = ArrayCreate(newLen)`. Per §10.4.2.2
    // step 3, `newLen > 2^32 - 1` throws RangeError.
    if (new_len > 0xFFFFFFFF) {
        return throwRangeError(realm, "Invalid array length");
    }
    // Cynic's own iteration cap — copy loops below are bounded.
    if (new_len > intrinsics.max_iter_length) {
        return throwRangeError(realm, "Array.prototype.toSpliced length exceeds maximum supported");
    }

    const out = realm.heap.allocateObject() catch return error.OutOfMemory;
    realm.heap.setObjectPrototype(out, realm.intrinsics.array_prototype);
    out.markAsArrayExotic(realm.allocator) catch return error.OutOfMemory;
    // Pin `out` and the receiver across the re-entrant copy loops.
    const scope = realm.heap.openScope() catch return error.OutOfMemory;
    defer scope.close();
    scope.push(heap_mod.taggedObject(out)) catch return error.OutOfMemory;
    scope.push(heap_mod.taggedObject(obj)) catch return error.OutOfMemory;

    // [0..start) — copy from receiver. `getPropertyChain` can
    // re-enter JS and promote `out`, so barrier each store.
    var i: i64 = 0;
    while (i < start) : (i += 1) {
        var rb: [24]u8 = undefined;
        const rslice = std.fmt.bufPrint(&rb, "{d}", .{i}) catch unreachable;
        const v = try getPropertyChain(realm, obj, rslice);
        realm.heap.writeBarrier(.{ .object = out }, v);
        out.setIndexed(realm.allocator, @intCast(i), v) catch return error.OutOfMemory;
    }
    // [start..start+insert_count) — items.
    var k: i64 = 0;
    while (k < insert_count) : (k += 1) {
        const iv = args[2 + @as(usize, @intCast(k))];
        realm.heap.writeBarrier(.{ .object = out }, iv);
        out.setIndexed(realm.allocator, @intCast(start + k), iv) catch return error.OutOfMemory;
    }
    // [start+insert_count..new_len) — tail of receiver after the gap.
    var r: i64 = start + delete_count;
    var w: i64 = start + insert_count;
    while (r < len) : ({
        r += 1;
        w += 1;
    }) {
        var rb: [24]u8 = undefined;
        const rslice = std.fmt.bufPrint(&rb, "{d}", .{r}) catch unreachable;
        const v = try getPropertyChain(realm, obj, rslice);
        realm.heap.writeBarrier(.{ .object = out }, v);
        out.setIndexed(realm.allocator, @intCast(w), v) catch return error.OutOfMemory;
    }
    setLength(realm, out, new_len) catch return error.OutOfMemory;
    return heap_mod.taggedObject(out);
}

/// §23.1.3.39 Array.prototype.with — non-mutating slot-set. Copy
/// the array, then overwrite the requested index. Negative
/// indices count from the end; out-of-range throws RangeError.
fn arrayWith(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    // §23.1.3.33 Array.prototype.with(index, value):
    //   1-3. ToObject + ToLength
    //   4. relativeIndex = ? ToIntegerOrInfinity(index)
    //   5-6. actualIndex = relativeIndex >= 0 ? relativeIndex : len + relativeIndex
    //   7. If actualIndex >= len or actualIndex < 0, throw RangeError
    //   8-9. A = ArrayCreate(len); copy elements
    //   10. Return A
    const obj = try toObjectThis(realm, this_value);
    const len = try intrinsics.clampArrayLengthR(realm, try toLengthOf(realm, obj));
    const idx_arg = argOr(args, 0, Value.undefined_);
    // Route through `toIntPropagating` so a throwing valueOf
    // propagates and Symbol throws TypeError.
    var idx: i64 = try toIntPropagating(realm, idx_arg);
    if (idx < 0) idx += len;
    if (idx < 0 or idx >= len) {
        const ex = intrinsics.newRangeError(realm, "invalid index") catch return error.OutOfMemory;
        realm.pending_exception = ex;
        return error.NativeThrew;
    }
    const value = argOr(args, 1, Value.undefined_);
    const out = realm.heap.allocateObject() catch return error.OutOfMemory;
    realm.heap.setObjectPrototype(out, realm.intrinsics.array_prototype);
    out.markAsArrayExotic(realm.allocator) catch return error.OutOfMemory;
    // Pin `out` and the receiver across the re-entrant read loop.
    const scope = realm.heap.openScope() catch return error.OutOfMemory;
    defer scope.close();
    scope.push(heap_mod.taggedObject(out)) catch return error.OutOfMemory;
    scope.push(heap_mod.taggedObject(obj)) catch return error.OutOfMemory;
    scope.push(value) catch return error.OutOfMemory;
    var i: i64 = 0;
    while (i < len) : (i += 1) {
        var rb: [24]u8 = undefined;
        const rslice = std.fmt.bufPrint(&rb, "{d}", .{i}) catch unreachable;
        const v = if (i == idx) value else try getPropertyChain(realm, obj, rslice);
        realm.heap.writeBarrier(.{ .object = out }, v);
        out.setIndexed(realm.allocator, @intCast(i), v) catch return error.OutOfMemory;
    }
    setLength(realm, out, len) catch return error.OutOfMemory;
    return heap_mod.taggedObject(out);
}

fn computedKeyForSort(v: Value, scratch: *[64]u8) []const u8 {
    if (v.isString()) {
        const s: *JSString = @ptrCast(@alignCast(v.asString()));
        return s.flatBytes();
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
    // views over a resizable buffer). Don't pre-clamp at Cynic's
    // 16M iteration cap: fixtures like
    // `length-exceeding-integer-limit-with-object` set a length
    // beyond 2^53 with a poisoned getter near the top, and rely on
    // the loop starting (so the getter fires) — not on visiting
    // every index. Route the initial length read through
    // `getPropertyAny` so a Proxy `get` trap fires for the
    // observable "length" probe
    // (`length-exceeding-integer-limit-with-proxy.js`).
    const safe_max: i64 = (1 << 53) - 1;
    const len_v = try getPropertyAny(realm, heap_mod.taggedObject(obj), "length");
    var len = try intrinsics.toLengthValue(realm, len_v);
    if (len > safe_max) len = safe_max;
    var i: i64 = 0;
    const half = @divFloor(len, 2);
    while (i < half) : (i += 1) {
        if ((i & 0x3FF) == 0) try intrinsics.checkInterruptInNative(realm);
        // The `hasPropertyP` / `getPropertyAny` / `setOrThrow` /
        // `deletePropertyOrThrow` calls below all re-enter JS for a
        // Proxy receiver and can trigger a GC. Root the per-iteration
        // key strings and the read values so the second `setOrThrow`
        // doesn't hand the trap a swept key (observed as a garbled
        // `Set:<key>` in the proxy trap log).
        const iter_scope = realm.heap.openScope() catch return error.OutOfMemory;
        defer iter_scope.close();
        var ibuf: [24]u8 = undefined;
        var jbuf: [24]u8 = undefined;
        const islice = std.fmt.bufPrint(&ibuf, "{d}", .{i}) catch unreachable;
        const j = len - 1 - i;
        const jslice = std.fmt.bufPrint(&jbuf, "{d}", .{j}) catch unreachable;
        // §23.1.3.26 step 6 — order matters: HasProperty(lower),
        // then Get(lower) if present, then HasProperty(upper),
        // then Get(upper) if present. A `get` accessor on `lower`
        // can mutate the receiver in between (the
        // `get_if_present_with_delete.js` fixture truncates
        // `array.length = 0` from inside the lower getter so the
        // upper slot disappears before its HasProperty fires).
        // Route through the Proxy-aware helpers so a `has` / `get`
        // trap is observable per spec.
        const lower_exists = try hasPropertyP(realm, obj, islice);
        const lower_v = if (lower_exists)
            try getPropertyAny(realm, heap_mod.taggedObject(obj), islice)
        else
            Value.undefined_;
        iter_scope.push(lower_v) catch return error.OutOfMemory;
        const upper_exists = try hasPropertyP(realm, obj, jslice);
        const upper_v = if (upper_exists)
            try getPropertyAny(realm, heap_mod.taggedObject(obj), jslice)
        else
            Value.undefined_;
        iter_scope.push(upper_v) catch return error.OutOfMemory;
        const owned_i = realm.heap.allocateString(islice) catch return error.OutOfMemory;
        const owned_j = realm.heap.allocateString(jslice) catch return error.OutOfMemory;
        iter_scope.push(Value.fromString(owned_i)) catch return error.OutOfMemory;
        iter_scope.push(Value.fromString(owned_j)) catch return error.OutOfMemory;
        if (lower_exists and upper_exists) {
            try setOrThrow(realm, obj, owned_i.flatBytes(), owned_i, upper_v);
            try setOrThrow(realm, obj, owned_j.flatBytes(), owned_j, lower_v);
        } else if (upper_exists) {
            try setOrThrow(realm, obj, owned_i.flatBytes(), owned_i, upper_v);
            try deletePropertyOrThrow(realm, obj, owned_j.flatBytes());
        } else if (lower_exists) {
            try deletePropertyOrThrow(realm, obj, owned_i.flatBytes());
            try setOrThrow(realm, obj, owned_j.flatBytes(), owned_j, lower_v);
        }
    }
    // §23.1.3.26 step 6 — Return O (the ToObject wrapper, not the
    // raw `this_value` primitive).
    return heap_mod.taggedObject(obj);
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
            try setOrThrow(realm, obj, owned.flatBytes(), owned, v);
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
                try setOrThrow(realm, obj, owned.flatBytes(), owned, v);
            } else {
                try deletePropertyOrThrow(realm, obj, tslice);
            }
        }
        // Insert new args at indices [0, argCount).
        for (args, 0..) |a, idx| {
            var b: [24]u8 = undefined;
            const slc = std.fmt.bufPrint(&b, "{d}", .{idx}) catch unreachable;
            const owned = realm.heap.allocateString(slc) catch return error.OutOfMemory;
            try setOrThrow(realm, obj, owned.flatBytes(), owned, a);
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
// method's contract. They use `lantern.callJSFunction` to
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
    const outcome = lantern.callJSFunction(realm.allocator, realm, callback, this_arg, &cb_args) catch |err| switch (err) {
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
    // Pin the receiver across the length getter and the callback
    // loop — both re-enter JS and can GC, and `obj` is a native
    // local the GC can't see (mirrors the map/filter rooting). Open
    // the scope BEFORE `toLengthOf`: without this, gc-threshold=1
    // sweeps `obj` during the length read, the freed object has no
    // `length` accessor, and forEach sees length 0 (zero iterations).
    const scope = realm.heap.openScope() catch return error.OutOfMemory;
    defer scope.close();
    scope.push(heap_mod.taggedObject(obj)) catch return error.OutOfMemory;
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
    // → callback IsCallable check, so a throwing length wins. Route
    // the length read through `getPropertyAny` so a Proxy `get`
    // trap fires; pass the raw length to ArraySpeciesCreate so the
    // §10.4.2.2 step 3 RangeError gate (`length > 2^32 - 1`) trips
    // for fixtures that expose a fake huge length
    // (`create-species-undef-invalid-len.js`).
    const obj = try toObjectThis(realm, this_value);
    const safe_max: i64 = (1 << 53) - 1;
    const len_v = try getPropertyAny(realm, heap_mod.taggedObject(obj), "length");
    var raw_len = try intrinsics.toLengthValue(realm, len_v);
    if (raw_len > safe_max) raw_len = safe_max;
    const callback = heap_mod.valueAsFunction(argOr(args, 0, Value.undefined_)) orelse return throwTypeError(realm, "Array.prototype.map callback must be a function");
    const this_arg = argOr(args, 1, Value.undefined_);

    // §23.1.3.19 step 5 — ArraySpeciesCreate(O, len) so `@@species`
    // on the receiver's constructor controls the result type. Pass
    // the raw length so a `length > 2^32 - 1` reports RangeError
    // before any callback fires.
    const out_v = try arraySpeciesCreate(realm, obj, raw_len);
    const out = heap_mod.valueAsPlainObject(out_v) orelse return throwTypeError(realm, "ArraySpeciesCreate did not return an object");
    // Pin the result array and the receiver across the callback
    // loop — each `invokeCallback` re-enters JS and can trigger a
    // GC sweep that would otherwise free `out` (held only on the
    // Zig stack). The per-iteration callback result is rooted on
    // the same scope, then dropped back to the base before the
    // next iteration so the scope can't grow unboundedly.
    const scope = realm.heap.openScope() catch return error.OutOfMemory;
    defer scope.close();
    scope.push(out_v) catch return error.OutOfMemory;
    scope.push(heap_mod.taggedObject(obj)) catch return error.OutOfMemory;
    const scope_base = scope.handles.items.len;
    // Bound the iteration loop at the engine's safety ceiling.
    const len = try intrinsics.clampArrayLengthR(realm, raw_len);
    var i: i64 = 0;
    while (i < len) : (i += 1) {
        // Cooperative interrupt poll every 1024 elements so a
        // `Array(2**24).map(...)` body can be terminated by a host
        // watchdog or step-budget exhaustion even though no JS
        // opcodes dispatch between callback invocations.
        if ((i & 0x3FF) == 0) try intrinsics.checkInterruptInNative(realm);
        var ibuf: [24]u8 = undefined;
        const islice = std.fmt.bufPrint(&ibuf, "{d}", .{i}) catch unreachable;
        if (!(try hasPropertyP(realm, obj, islice))) continue;
        const elem = try getPropertyAny(realm, heap_mod.taggedObject(obj), islice);
        const v = try invokeCallback(realm, callback, this_arg, elem, i, obj);
        scope.push(v) catch return error.OutOfMemory;
        const owned = realm.heap.allocateString(islice) catch return error.OutOfMemory;
        // §23.1.3.19 step 6.c.iii — CreateDataPropertyOrThrow.
        try createDataPropertyOrThrowGeneric(realm, out, owned, v);
        scope.handles.shrinkRetainingCapacity(scope_base);
    }
    try setLengthOrThrow(realm, out, len);
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
    // Pin the result array and the receiver across the re-entrant
    // callback loop; root each kept element while it is in flight.
    const scope = realm.heap.openScope() catch return error.OutOfMemory;
    defer scope.close();
    scope.push(out_v) catch return error.OutOfMemory;
    scope.push(heap_mod.taggedObject(obj)) catch return error.OutOfMemory;
    const scope_base = scope.handles.items.len;
    var i: i64 = 0;
    var write_idx: i64 = 0;
    while (i < len) : (i += 1) {
        if ((i & 0x3FF) == 0) try intrinsics.checkInterruptInNative(realm);
        var ibuf: [24]u8 = undefined;
        const islice = std.fmt.bufPrint(&ibuf, "{d}", .{i}) catch unreachable;
        if (!obj.hasProperty(islice)) continue;
        const elem = try getPropertyChain(realm, obj, islice);
        scope.push(elem) catch return error.OutOfMemory;
        const keep = try invokeCallback(realm, callback, this_arg, elem, i, obj);
        if (toBoolean(keep)) {
            var wbuf: [24]u8 = undefined;
            const wslice = std.fmt.bufPrint(&wbuf, "{d}", .{write_idx}) catch unreachable;
            const owned = realm.heap.allocateString(wslice) catch return error.OutOfMemory;
            // §23.1.3.8 step 6.c.iii.2 — CreateDataPropertyOrThrow.
            try createDataPropertyOrThrowGeneric(realm, out, owned, elem);
            write_idx += 1;
        }
        scope.handles.shrinkRetainingCapacity(scope_base);
    }
    try setLengthOrThrow(realm, out, write_idx);
    return out_v;
}

fn arrayEvery(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    // §23.1.3.6 spec step order: ToObject → length → IsCallable.
    const obj = try toObjectThis(realm, this_value);
    // §7.1.20 ToLength caps at 2^53-1; don't pre-clamp at Cynic's
    // 16M iteration ceiling. `every` short-circuits on the first
    // falsy callback result — fixtures like 15.4.4.16-3-8 set
    // `length: Infinity` and expect the answer at index 0.
    const safe_max: i64 = (1 << 53) - 1;
    var len = try toLengthOf(realm, obj);
    if (len > safe_max) len = safe_max;
    const callback = heap_mod.valueAsFunction(argOr(args, 0, Value.undefined_)) orelse return throwTypeError(realm, "Array.prototype.every callback must be a function");
    const this_arg = argOr(args, 1, Value.undefined_);
    var i: i64 = 0;
    while (i < len) : (i += 1) {
        if ((i & 0x3FF) == 0) try intrinsics.checkInterruptInNative(realm);
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
    // §7.1.20 ToLength cap; `some` short-circuits on first truthy.
    const safe_max: i64 = (1 << 53) - 1;
    var len = try toLengthOf(realm, obj);
    if (len > safe_max) len = safe_max;
    const callback = heap_mod.valueAsFunction(argOr(args, 0, Value.undefined_)) orelse return throwTypeError(realm, "Array.prototype.some callback must be a function");
    const this_arg = argOr(args, 1, Value.undefined_);
    var i: i64 = 0;
    while (i < len) : (i += 1) {
        if ((i & 0x3FF) == 0) try intrinsics.checkInterruptInNative(realm);
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
    const safe_max: i64 = (1 << 53) - 1;
    var len = try toLengthOf(realm, obj);
    if (len > safe_max) len = safe_max;
    const callback = heap_mod.valueAsFunction(argOr(args, 0, Value.undefined_)) orelse return throwTypeError(realm, "Array.prototype.find callback must be a function");
    const this_arg = argOr(args, 1, Value.undefined_);
    var i: i64 = 0;
    while (i < len) : (i += 1) {
        if ((i & 0x3FF) == 0) try intrinsics.checkInterruptInNative(realm);
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
    const safe_max: i64 = (1 << 53) - 1;
    var len = try toLengthOf(realm, obj);
    if (len > safe_max) len = safe_max;
    const callback = heap_mod.valueAsFunction(argOr(args, 0, Value.undefined_)) orelse return throwTypeError(realm, "Array.prototype.findIndex callback must be a function");
    const this_arg = argOr(args, 1, Value.undefined_);
    var i: i64 = 0;
    while (i < len) : (i += 1) {
        if ((i & 0x3FF) == 0) try intrinsics.checkInterruptInNative(realm);
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

    // Pin the receiver and the running accumulator across the
    // re-entrant callback loop. `acc` changes every iteration, so
    // it gets a dedicated handle slot refreshed at each loop top.
    const scope = realm.heap.openScope() catch return error.OutOfMemory;
    defer scope.close();
    scope.push(heap_mod.taggedObject(obj)) catch return error.OutOfMemory;
    scope.push(acc) catch return error.OutOfMemory;
    const acc_slot = scope.handles.items.len - 1;

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
        scope.handles.items[acc_slot] = acc;
        var ibuf: [24]u8 = undefined;
        const islice = std.fmt.bufPrint(&ibuf, "{d}", .{i}) catch unreachable;
        if (!obj.hasProperty(islice)) continue;
        const elem = try getPropertyChain(realm, obj, islice);

        const cb_args = [_]Value{ acc, elem, numberFromI64(i), heap_mod.taggedObject(obj) };
        const outcome = lantern.callJSFunction(realm.allocator, realm, callback, Value.undefined_, &cb_args) catch |err| switch (err) {
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
        return s.flatBytes().len > 0;
    }
    if (v.isInt32()) return v.asInt32() != 0;
    if (v.isDouble()) {
        const d = v.asDouble();
        return d != 0 and !std.math.isNan(d);
    }
    if (v.isBool()) return v.asBool();
    if (v.isNull() or v.isUndefined()) return false;
    // §7.1.2 step 8 — BigInt is falsy iff zero. Stored as
    // Object-tagged, so this must come before the catch-all
    // "all objects truthy" rule below.
    if (heap_mod.valueAsBigInt(v)) |bi| return !bi.isZero();
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
// §23.1.2.1.1 step 3.j.ii — async-iterator path does NOT await
// `nextValue` (the iterator already returned it after awaiting
// the IteratorResult promise). Sync-iterator path wraps via
// %AsyncFromSyncIteratorPrototype% so its values ARE awaited.
const k_fa_is_async = "__cynic_fa_is_async__";

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
    realm.heap.setObjectPrototype(out, realm.intrinsics.array_prototype);
    out.markAsArrayExotic(realm.allocator) catch return error.OutOfMemory;

    const state = realm.heap.allocateObject() catch return error.OutOfMemory;
    realm.heap.setObjectPrototype(state, realm.intrinsics.object_prototype);
    // Root `state` for the rest of `arrayFromAsync` — the
    // `@@asyncIterator` / `@@iterator` lookups, the iterator-method
    // call, `LengthOfArrayLike`, and `Construct(C)` below all
    // re-enter JS and can GC before the first driver step has
    // registered a `state`-bound continuation.
    const fa_sc = try faRootState(realm, state);
    defer fa_sc.close();
    try faStateSet(realm, state, k_fa_cap_resolve, heap_mod.taggedFunction(cap.resolve));
    try faStateSet(realm, state, k_fa_cap_reject, heap_mod.taggedFunction(cap.reject));
    try faStateSet(realm, state, k_fa_array, heap_mod.taggedObject(out));
    try faStateSet(realm, state, k_fa_index, Value.fromInt32(0));
    try faStateSet(realm, state, k_fa_mapfn, mapfn_v);
    try faStateSet(realm, state, k_fa_this_arg, this_arg);
    try faStateSet(realm, state, k_fa_items, items);

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
            try faStateSet(realm, state, k_fa_array, ctor_v);
        }
        const iter_outcome = lantern.callJSFunction(realm.allocator, realm, async_iter_fn, items, &.{}) catch {
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
        try faStateSet(realm, state, k_fa_iter, iter_v);
        try faStateSet(realm, state, k_fa_next_fn, heap_mod.taggedFunction(next_fn));
        try faStateSet(realm, state, k_fa_mode, Value.fromInt32(1));
        try faStateSet(realm, state, k_fa_is_async, Value.true_);
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
            try faStateSet(realm, state, k_fa_array, ctor_v);
        }
        // step 3.h — sync `@@iterator` fallback. Per spec, wrap in
        // %AsyncFromSyncIteratorPrototype%. Cynic shortcut: drive the
        // sync iterator directly and `awaitAndThen` no-ops on non-
        // promise values, which matches the observable behavior for
        // the simple fixtures (sync iterator yielding non-promise
        // values).
        const iter_outcome = lantern.callJSFunction(realm.allocator, realm, sync_iter_fn, items, &.{}) catch {
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
        try faStateSet(realm, state, k_fa_iter, iter_v);
        try faStateSet(realm, state, k_fa_next_fn, heap_mod.taggedFunction(next_fn));
        try faStateSet(realm, state, k_fa_mode, Value.fromInt32(1));
        try faStateSet(realm, state, k_fa_is_async, Value.false_);
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
    try faStateSet(realm, state, k_fa_items, heap_mod.taggedObject(items_obj));

    const raw_len = toLengthOf(realm, items_obj) catch {
        return rejectPendingException(realm, cap);
    };
    const len = intrinsics.clampArrayLengthR(realm, raw_len) catch {
        return rejectPendingException(realm, cap);
    };
    try faStateSet(realm, state, k_fa_length, numberFromI64(len));
    try faStateSet(realm, state, k_fa_mode, Value.fromInt32(0));

    // §23.1.2.1.1 step 3.k.iv — `IsConstructor(C)` → `Construct(C, « 𝔽(len) »)`.
    if (this_ctor) |c| {
        const ctor_args = [_]Value{numberFromI64(len)};
        const ctor_v = constructForFromAsync(realm, c, &ctor_args) catch {
            return rejectPendingException(realm, cap);
        };
        try faStateSet(realm, state, k_fa_array, ctor_v);
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
    const outcome = lantern.constructValue(
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
    // Root `source` (possibly a freshly-wrapped promise) and the
    // result promise across the allocations that follow — the
    // `result_promise` allocation and `promiseReactionsPtr` /
    // reaction-list growth would otherwise sweep an un-anchored
    // `source` under aggressive GC.
    const sc = realm.heap.openScope() catch return error.OutOfMemory;
    defer sc.close();

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
    sc.push(heap_mod.taggedObject(source)) catch return error.OutOfMemory;

    const result_promise = promise_mod.allocatePromiseFor(realm, null, .pending, Value.undefined_) catch return error.OutOfMemory;
    sc.push(result_promise) catch return error.OutOfMemory;
    const on_resolve_v = heap_mod.taggedFunction(on_resolve);
    const on_reject_v = heap_mod.taggedFunction(on_reject);
    switch (source.promise_state) {
        .fulfilled => realm.enqueuePromiseReaction(on_resolve_v, source.promise_value, result_promise, false) catch return error.OutOfMemory,
        .rejected => realm.enqueuePromiseReaction(on_reject_v, source.promise_value, result_promise, true) catch return error.OutOfMemory,
        else => {
            const reactions = source.promiseReactionsPtr(realm.allocator) catch return error.OutOfMemory;
            reactions.append(realm.allocator, .{
                .on_fulfilled = on_resolve_v,
                .on_rejected = on_reject_v,
                .result_promise = result_promise,
            }) catch return error.OutOfMemory;
        },
    }
}

fn wrapValueInPromise(realm: *Realm, value: Value) NativeError!*JSObject {
    const wrap_v = promise_mod.allocatePromiseFor(realm, null, .pending, Value.undefined_) catch return error.OutOfMemory;
    const wrap = heap_mod.valueAsPlainObject(wrap_v).?;
    // Root `wrap` across `promiseResolveImplExported` — it re-enters
    // JS (runs the resolve machinery) and can GC, which would
    // otherwise sweep the freshly-allocated, not-yet-referenced
    // `wrap` and return a dangling promise to `awaitAndThen`.
    const sc = realm.heap.openScope() catch return error.OutOfMemory;
    defer sc.close();
    sc.push(wrap_v) catch return error.OutOfMemory;
    const args = [_]Value{value};
    _ = promise_mod.promiseResolveImplExported(realm, heap_mod.taggedObject(wrap), &args) catch return error.OutOfMemory;
    return wrap;
}

// ── Bound-callback helpers ──────────────────────────────────────────────────

fn makeBoundCb(
    realm: *Realm,
    impl: *const fn (*Realm, Value, []const Value) NativeError!Value,
    state: *JSObject,
    sc: *heap_mod.HandleScope,
) NativeError!*JSFunction {
    const impl_fn = realm.heap.allocateFunctionNative(realm, impl, 1, "") catch return error.OutOfMemory;
    impl_fn.proto = realm.intrinsics.function_prototype;
    impl_fn.has_construct = false;
    // Root `impl_fn` across the `bound` allocation below — otherwise
    // a GC there (deterministic at `gc-threshold=1`) sweeps the
    // un-anchored `impl_fn`, leaving `setBoundTarget` to store a
    // dangling pointer that surfaces as "value is not callable" when
    // the trampoline later dereferences `bound_target`.
    sc.push(heap_mod.taggedFunction(impl_fn)) catch return error.OutOfMemory;
    const bound = realm.heap.allocateFunctionNative(realm, promise_mod.boundResolveTrampolineExported, 1, "") catch return error.OutOfMemory;
    bound.proto = realm.intrinsics.function_prototype;
    bound.has_construct = false;
    realm.heap.setBoundTarget(bound, impl_fn);
    realm.heap.setBoundThis(bound, heap_mod.taggedObject(state));
    // Keep `bound` rooted until the caller registers it in a promise
    // reaction — a sibling `makeBoundCb` call (the reject twin)
    // allocates again before `awaitAndThen` runs.
    sc.push(heap_mod.taggedFunction(bound)) catch return error.OutOfMemory;
    return bound;
}

/// Allocate the resolve / reject bound continuations for one
/// `Array.fromAsync` await and schedule them. Roots the awaited
/// `value` and every intermediate function on `sc` so the cascade
/// of allocations under aggressive GC can't sweep a callable before
/// it lands in a (rooted) promise reaction.
fn awaitWithCbs(
    realm: *Realm,
    sc: *heap_mod.HandleScope,
    state: *JSObject,
    value: Value,
    on_res_impl: *const fn (*Realm, Value, []const Value) NativeError!Value,
    on_rej_impl: *const fn (*Realm, Value, []const Value) NativeError!Value,
) NativeError!void {
    sc.push(value) catch return error.OutOfMemory;
    const on_res = try makeBoundCb(realm, on_res_impl, state, sc);
    const on_rej = try makeBoundCb(realm, on_rej_impl, state, sc);
    try awaitAndThen(realm, value, on_res, on_rej);
}

/// Store into the engine-internal `Array.fromAsync` driver `state`
/// object with the generational write barrier. `state` lives across
/// every `await` suspension and is therefore promoted to mature; a
/// later young value stored into a `__cynic_fa_*` slot via the raw
/// `JSObject.set` (which doesn't barrier) is an un-remembered
/// mature→young edge that the next minor GC sweeps — a
/// use-after-free on the next driver step. The barrier no-ops for
/// the primitive slots (index / mode / length flags).
fn faStateSet(realm: *Realm, state: *JSObject, key: []const u8, value: Value) NativeError!void {
    realm.heap.writeBarrier(.{ .object = state }, value);
    state.set(realm.allocator, key, value) catch return error.OutOfMemory;
}

// ── Iterator-path driver ────────────────────────────────────────────────────

/// Root the `Array.fromAsync` `state` object for the duration of a
/// driver step. Every step re-enters JS — `iter.next()`, the
/// mapper, indexed-element reads, `iter.return()` — and a GC there
/// would free `state` (and, transitively, the result array, the
/// iterator, the capability functions) on the very first step,
/// before any `state`-bound continuation callback exists to hold
/// it. Caller pairs with `defer sc.close()`.
fn faRootState(realm: *Realm, state: *JSObject) NativeError!*heap_mod.HandleScope {
    const sc = realm.heap.openScope() catch return error.OutOfMemory;
    sc.push(heap_mod.taggedObject(state)) catch {
        sc.close();
        return error.OutOfMemory;
    };
    return sc;
}

fn fromAsyncIterStep(realm: *Realm, state: *JSObject) NativeError!void {
    const fa_sc = try faRootState(realm, state);
    defer fa_sc.close();
    const iter_v = state.get(k_fa_iter);
    const next_fn = heap_mod.valueAsFunction(state.get(k_fa_next_fn)) orelse return;
    const next_outcome = lantern.callJSFunction(realm.allocator, realm, next_fn, iter_v, &.{}) catch |err| switch (err) {
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
    try awaitWithCbs(realm, fa_sc, state, next_v, fromAsyncIterOnNextResult, fromAsyncIterOnNextReject);
}

fn fromAsyncIterOnNextResult(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const state = heap_mod.valueAsPlainObject(this_value) orelse return Value.undefined_;
    const fa_sc = try faRootState(realm, state);
    defer fa_sc.close();
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
        // §23.1.2.1.1 step 3.j.ii.4.a — `Set(A, "length", 𝔽(k), true)`
        // fires user-installed setters (`this-constructor-with-bad-
        // length-setter.js`) and honors writable:false
        // (`this-constructor-with-readonly-length.js`).
        setLengthOrThrow(realm, out, k) catch {
            return rejectFromState(realm, state);
        };
        return resolveFromState(realm, state, heap_mod.taggedObject(out));
    }

    // §23.1.2.1.1 step 3.j.ii — for the async-iterator path the
    // value coming out of `IteratorValue(iterResult)` is NOT
    // awaited (the iter already awaited the IteratorResult
    // promise). The sync-iterator branch wraps via
    // %AsyncFromSyncIteratorPrototype% which DOES await values,
    // so re-await there. `async-iterable-input-does-not-await-
    // input.js` asserts a `value: Promise` yielded from an async
    // iterator survives as a Promise in the resulting array.
    if (state.get(k_fa_is_async).toBooleanPrimitive()) {
        return fromAsyncIterOnValueAwaited(realm, this_value, &[_]Value{value_v});
    }
    // §23.1.2.1.1 sync-iterator branch — value comes from a sync
    // iterator wrapped via %AsyncFromSyncIteratorPrototype%; the
    // continuation awaits the yielded value. If that await rejects
    // (e.g. a thenable yielded by the generator calls `reject`), the
    // sync iterator MUST be closed (IfAbruptCloseAsyncIterator).
    // `sync-iterable-with-rejecting-thenable-closes.js`.
    try awaitWithCbs(realm, fa_sc, state, value_v, fromAsyncIterOnValueAwaited, fromAsyncIterOnValueReject);
    return Value.undefined_;
}

fn fromAsyncIterOnValueReject(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const state = heap_mod.valueAsPlainObject(this_value) orelse return Value.undefined_;
    const reason = argOr(args, 0, Value.undefined_);
    realm.pending_exception = reason;
    return closeIterAndReject(realm, state);
}

fn fromAsyncIterOnValueAwaited(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const state = heap_mod.valueAsPlainObject(this_value) orelse return Value.undefined_;
    const fa_sc = try faRootState(realm, state);
    defer fa_sc.close();
    const value = argOr(args, 0, Value.undefined_);
    const mapfn_v = state.get(k_fa_mapfn);

    if (heap_mod.valueAsFunction(mapfn_v)) |mapfn| {
        const k = state.get(k_fa_index).asInt32();
        const this_arg = state.get(k_fa_this_arg);
        const cb_args = [_]Value{ value, Value.fromInt32(k) };
        const mapped_outcome = lantern.callJSFunction(realm.allocator, realm, mapfn, this_arg, &cb_args) catch {
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
        try awaitWithCbs(realm, fa_sc, state, mapped, fromAsyncIterOnMappedAwaited, fromAsyncIterOnMappedReject);
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
    key_str: *JSString,
    value: Value,
) NativeError!void {
    const ObjMod = @import("../object.zig");
    const key = key_str.flatBytes();
    // §7.3.7 CreateDataPropertyOrThrow → §10.5.6 — when the
    // receiver is a Proxy (the result of `Array.fromAsync.call(C,
    // …)` where `C` constructs one), OrdinaryDefineOwnProperty
    // becomes the proxy `defineProperty` trap. Each indexed
    // element must fire it (test262 Array/fromAsync
    // this-constructor-operations); a direct `setWithFlags` would
    // write through to the target and skip the trap. Mirrors
    // `createDataPropertyOrThrowGeneric`.
    const proxy_mod = @import("proxy.zig");
    var cur = obj;
    while (cur.proxy_target != null or cur.proxy_revoked) {
        const r = try proxy_mod.nativeProxyDefineProperty(realm, cur, key, value, null);
        switch (r) {
            .boolean => |b| {
                if (!b) return throwTypeError(realm, "Array.fromAsync: 'defineProperty' trap returned false");
                return;
            },
            .fallthrough => |t| {
                if (t == cur) break;
                cur = t;
            },
        }
    }
    const had_own = cur.hasOwn(key);
    if (!had_own) {
        if (!cur.extensible) {
            return throwTypeError(realm, "Array.fromAsync: cannot define property on non-extensible object");
        }
    } else {
        const cur_flags = cur.flagsFor(key);
        // §10.1.6.3 step 4 — redefining with `{w:T,e:T,c:T}` over
        // a non-configurable own property fails whenever any of
        // the current flags differs (configurable:false alone is
        // sufficient; configurable:true with writable:false /
        // enumerable:false is still allowed because the redefine
        // can flip them back on).
        if (!cur_flags.configurable) {
            return throwTypeError(realm, "Array.fromAsync: cannot redefine non-configurable property");
        }
    }
    // Generational write barrier — raw setter bypasses the routed
    // `heap.storeProperty` / `storeIndexed` (see
    // `createDataPropertyOrThrowGeneric`).
    realm.heap.writeBarrier(.{ .object = cur }, value);
    cur.setWithFlags(realm.allocator, key, value, ObjMod.PropertyFlags.default) catch return error.OutOfMemory;
    // Anchor the heap key string when the slice landed in the
    // named-property bag — see `createDataPropertyOrThrowGeneric`.
    if (cur.ownDataContains(key)) {
        cur.anchorKey(realm.allocator, key_str) catch return error.OutOfMemory;
        cur.markNonPristine();
    }
}

fn appendAndStepIter(realm: *Realm, state: *JSObject, value: Value) NativeError!Value {
    const fa_sc = try faRootState(realm, state);
    defer fa_sc.close();
    const out = heap_mod.valueAsPlainObject(state.get(k_fa_array)) orelse return Value.undefined_;
    const k = state.get(k_fa_index).asInt32();
    var ibuf: [24]u8 = undefined;
    const islice = std.fmt.bufPrint(&ibuf, "{d}", .{k}) catch unreachable;
    const owned = realm.heap.allocateString(islice) catch return error.OutOfMemory;
    // Root the key string and the element value across
    // `createDataPropertyOrThrow` — for a Proxy `A` it fires the
    // `defineProperty` trap (user JS, can GC), and the borrowed
    // `key` slice into `owned.bytes` would dangle if `owned` were
    // swept mid-trap.
    fa_sc.push(Value.fromString(owned)) catch return error.OutOfMemory;
    fa_sc.push(value) catch return error.OutOfMemory;
    // §23.1.2.1.1 step 3.j.ii.8 — `CreateDataPropertyOrThrow(A, Pk,
    // mappedValue)`. Abrupt completion routes through
    // `closeIterAndReject` (step 9 — `AsyncIteratorClose`).
    createDataPropertyOrThrow(realm, out, owned, value) catch {
        return closeIterAndReject(realm, state);
    };
    try faStateSet(realm, state, k_fa_index, Value.fromInt32(k + 1));
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
    const fa_sc = try faRootState(realm, state);
    defer fa_sc.close();
    const iter_v = state.get(k_fa_iter);
    if (heap_mod.valueAsPlainObject(iter_v)) |obj| {
        const ret_v = getPropertyChain(realm, obj, "return") catch Value.undefined_;
        if (heap_mod.valueAsFunction(ret_v)) |ret_fn| {
            const outcome = lantern.callJSFunction(realm.allocator, realm, ret_fn, iter_v, &.{}) catch null;
            _ = outcome;
            // §7.4.11 — original abrupt wins; clear any thrown
            // exception from `return` itself.
        }
    }
    return rejectFromState(realm, state);
}

// ── Array-like driver ──────────────────────────────────────────────────────

fn fromAsyncArrayLikeStep(realm: *Realm, state: *JSObject) NativeError!void {
    const fa_sc = try faRootState(realm, state);
    defer fa_sc.close();
    const k = state.get(k_fa_index).asInt32();
    const len_v = state.get(k_fa_length);
    const len: i64 = if (len_v.isInt32()) len_v.asInt32() else if (len_v.isDouble()) @intFromFloat(len_v.asDouble()) else 0;

    if (@as(i64, k) >= len) {
        const out = heap_mod.valueAsPlainObject(state.get(k_fa_array)) orelse return;
        // §23.1.2.1.1 step 3.k.viii — `Set(A, "length", 𝔽(len), true)`
        // honors a readonly / setter-installed `length`
        // (`this-constructor-with-{readonly-length,bad-length-setter}.js`).
        setLengthOrThrow(realm, out, len) catch {
            _ = rejectFromState(realm, state) catch {};
            return;
        };
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

    try awaitWithCbs(realm, fa_sc, state, raw, fromAsyncArrayLikeOnAwaited, fromAsyncArrayLikeOnReject);
}

fn fromAsyncArrayLikeOnAwaited(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const state = heap_mod.valueAsPlainObject(this_value) orelse return Value.undefined_;
    const fa_sc = try faRootState(realm, state);
    defer fa_sc.close();
    const value = argOr(args, 0, Value.undefined_);
    const mapfn_v = state.get(k_fa_mapfn);

    if (heap_mod.valueAsFunction(mapfn_v)) |mapfn| {
        const k = state.get(k_fa_index).asInt32();
        const this_arg = state.get(k_fa_this_arg);
        const cb_args = [_]Value{ value, Value.fromInt32(k) };
        const mapped_outcome = lantern.callJSFunction(realm.allocator, realm, mapfn, this_arg, &cb_args) catch {
            return rejectFromState(realm, state);
        };
        const mapped = switch (mapped_outcome) {
            .value, .yielded => |v| v,
            .thrown => |ex| return rejectFromStateWithReason(realm, state, ex),
        };
        try awaitWithCbs(realm, fa_sc, state, mapped, fromAsyncArrayLikeOnMapped, fromAsyncArrayLikeOnReject);
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
    const fa_sc = try faRootState(realm, state);
    defer fa_sc.close();
    const out = heap_mod.valueAsPlainObject(state.get(k_fa_array)) orelse return Value.undefined_;
    const k = state.get(k_fa_index).asInt32();
    var ibuf: [24]u8 = undefined;
    const islice = std.fmt.bufPrint(&ibuf, "{d}", .{k}) catch unreachable;
    const owned = realm.heap.allocateString(islice) catch return error.OutOfMemory;
    // Root key + value across the (proxy-capable) define — see
    // `appendAndStepIter`.
    fa_sc.push(Value.fromString(owned)) catch return error.OutOfMemory;
    fa_sc.push(value) catch return error.OutOfMemory;
    // §23.1.2.1.1 step 3.l.iii — `CreateDataPropertyOrThrow(A, Pk,
    // mappedValue)`. There's no iterator to close on the array-like
    // path; an abrupt completion just rejects the outer promise.
    createDataPropertyOrThrow(realm, out, owned, value) catch {
        return rejectFromState(realm, state);
    };
    try faStateSet(realm, state, k_fa_index, Value.fromInt32(k + 1));
    fromAsyncArrayLikeStep(realm, state) catch {
        return rejectFromState(realm, state);
    };
    return Value.undefined_;
}

// ── Settlement helpers (state → capability) ────────────────────────────────

fn resolveFromState(realm: *Realm, state: *JSObject, value: Value) NativeError!Value {
    const resolve_fn = heap_mod.valueAsFunction(state.get(k_fa_cap_resolve)) orelse return Value.undefined_;
    const outcome = lantern.callJSFunction(realm.allocator, realm, resolve_fn, Value.undefined_, &.{value}) catch |err| switch (err) {
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
    const outcome = lantern.callJSFunction(realm.allocator, realm, reject_fn, Value.undefined_, &.{reason}) catch |err| switch (err) {
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
