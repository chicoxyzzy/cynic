//! §20 Object — extracted from `intrinsics.zig`. Covers four
//! related sections that all hang off the global `Object`:
//! • Static methods (`keys`, `values`, `entries`,
//! `getOwnPropertyDescriptor`, `assign`, `defineProperty`,
//! `defineProperties`, etc.).
//! • Property descriptor machinery (§6.2.5
//! ToPropertyDescriptor + §10.1.6.3
//! ValidateAndApplyPropertyDescriptor — non-configurable
//! redefine guard).
//! • Object extensibility statics (`freeze`, `seal`,
//! `isFrozen`, `isExtensible`, `preventExtensions`,
//! `create`).
//! • `Object.prototype` instance methods (`hasOwnProperty`,
//! `propertyIsEnumerable`, `isPrototypeOf`, `toString`,
//! `valueOf`).

const std = @import("std");

const Realm = @import("../realm.zig").Realm;
const Value = @import("../value.zig").Value;
const JSString = @import("../string.zig").JSString;
const JSObject = @import("../object.zig").JSObject;
const JSFunction = @import("../function.zig").JSFunction;
const NativeError = @import("../function.zig").NativeError;
const heap_mod = @import("../heap.zig");
const ObjMod = @import("../object.zig");
const intrinsics = @import("../intrinsics.zig");

const installNativeMethod = intrinsics.installNativeMethod;
const installNativeMethodOnProto = intrinsics.installNativeMethodOnProto;
const setNonEnumerable = intrinsics.setNonEnumerable;
const argOr = intrinsics.argOr;
const throwTypeError = intrinsics.throwTypeError;
const stringifyArg = intrinsics.stringifyArg;
const toBoolean = intrinsics.toBoolean;
const sameValueZero = intrinsics.sameValueZero;
const getPropertyChain = intrinsics.getPropertyChain;

/// §20.1.1.1 Object ( [ value ] ) — both `new` and plain-call.
/// Plain `Object()` / `Object(undefined)` / `Object(null)` →
/// fresh empty object whose proto is `%Object.prototype%`.
/// Plain `Object(value)` for an existing object → return value
/// (identity, no copy). For primitive values we fall back to a
/// fresh empty object — primitive boxing (`Object(42)` → Number
/// wrapper) needs the wrapper plumbing that's not wired here.
/// `new Object(value)` arrives with `this_value` set to the
/// freshly allocated `this`; if `value` is already an object
/// the spec says to return it (overriding `this`), otherwise
/// just hand back `this` (the caller's `new` makes it the
/// return value if we return undefined).
pub fn objectConstructor(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const arg = argOr(args, 0, Value.undefined_);
    // §20.1.1.1 step 2 — `Object(value)` with a non-nullish
    // value-that-is-an-object returns the value unchanged. This
    // is the identity case for both `new` and plain-call.
    if (arg.isObject() or heap_mod.valueAsFunction(arg) != null) {
        return arg;
    }
    // §20.1.1.1 step 3 — non-null/non-undefined primitive →
    // ToObject(value). Boxes Numbers / Booleans / Strings into
    // the appropriate `<X>.prototype`-prototype wrapper so
    // inherited `.toString` / `.valueOf` etc. resolve correctly.
    // Without this, `new Object(42)` produced a plain `%Object.prototype%`
    // object and `wrap.toString()` → "[object Object]" instead
    // of "42".
    if (!arg.isUndefined() and !arg.isNull()) {
        const w = try intrinsics.toObjectThis(realm, arg);
        return heap_mod.taggedObject(w);
    }
    // `new Object(...)` path — `this_value` is the freshly
    // allocated object the interpreter built for us. For
    // null/undefined args, that empty object IS the result.
    if (heap_mod.valueAsPlainObject(this_value)) |_| {
        return this_value;
    }
    // Plain `Object()` / `Object(undefined)` / `Object(null)` —
    // build a fresh empty object.
    const obj = realm.heap.allocateObject() catch return error.OutOfMemory;
    obj.prototype = realm.intrinsics.object_prototype;
    return heap_mod.taggedObject(obj);
}

/// Wire `Object.*` statics and `Object.prototype` instance
/// methods. Caller arranges that `realm.intrinsics.object_prototype`
/// + the `Object` global stub already exist; this fn pours the
/// methods in.
pub fn install(realm: *Realm) !void {
    if (heap_mod.valueAsFunction(realm.globals.get("Object").?)) |obj_ctor| {
        // Replace the stub-constructor body installed during the
        // bootstrap with the real §20.1.1.1 semantics now that
        // `object_prototype` is wired.
        obj_ctor.native_callback = objectConstructor;
        try installNativeMethod(realm, obj_ctor, "keys", objectKeys, 1);
        try installNativeMethod(realm, obj_ctor, "values", objectValues, 1);
        try installNativeMethod(realm, obj_ctor, "entries", objectEntries, 1);
        try installNativeMethod(realm, obj_ctor, "getPrototypeOf", objectGetPrototypeOf, 1);
        try installNativeMethod(realm, obj_ctor, "hasOwn", objectHasOwn, 2);
        try installNativeMethod(realm, obj_ctor, "defineProperty", objectDefineProperty, 3);
        try installNativeMethod(realm, obj_ctor, "defineProperties", objectDefineProperties, 2);
        try installNativeMethod(realm, obj_ctor, "getOwnPropertyDescriptor", objectGetOwnPropertyDescriptor, 2);
        try installNativeMethod(realm, obj_ctor, "getOwnPropertyDescriptors", objectGetOwnPropertyDescriptors, 1);
        try installNativeMethod(realm, obj_ctor, "getOwnPropertyNames", objectGetOwnPropertyNames, 1);
        try installNativeMethod(realm, obj_ctor, "getOwnPropertySymbols", objectGetOwnPropertySymbols, 1);
        try installNativeMethod(realm, obj_ctor, "create", objectCreate, 2);
        try installNativeMethod(realm, obj_ctor, "assign", objectAssign, 2);
        try installNativeMethod(realm, obj_ctor, "freeze", objectFreeze, 1);
        try installNativeMethod(realm, obj_ctor, "isFrozen", objectIsFrozen, 1);
        try installNativeMethod(realm, obj_ctor, "seal", objectSeal, 1);
        try installNativeMethod(realm, obj_ctor, "isSealed", objectIsSealed, 1);
        try installNativeMethod(realm, obj_ctor, "preventExtensions", objectPreventExtensions, 1);
        try installNativeMethod(realm, obj_ctor, "isExtensible", objectIsExtensible, 1);
        try installNativeMethod(realm, obj_ctor, "fromEntries", objectFromEntries, 1);
        try installNativeMethod(realm, obj_ctor, "setPrototypeOf", objectSetPrototypeOf, 2);
        try installNativeMethod(realm, obj_ctor, "groupBy", objectGroupBy, 2);
        try installNativeMethod(realm, obj_ctor, "is", objectIs, 2);
    }
    if (realm.intrinsics.object_prototype) |obj_proto| {
        try installNativeMethodOnProto(realm, obj_proto, "hasOwnProperty", objectHasOwnProperty, 1);
        try installNativeMethodOnProto(realm, obj_proto, "toString", objectProtoToString, 0);
        try installNativeMethodOnProto(realm, obj_proto, "valueOf", objectProtoValueOf, 0);
        try installNativeMethodOnProto(realm, obj_proto, "propertyIsEnumerable", objectProtoPropertyIsEnumerable, 1);
        try installNativeMethodOnProto(realm, obj_proto, "isPrototypeOf", objectProtoIsPrototypeOf, 1);
    }
}

// ── Object static methods ───────────────────────────────────────────────────

/// §7.1.21 CanonicalNumericIndexString — a string `s` is an
/// integer-indexed key iff `s == String(ToUint32(s))` and the
/// numeric value is in [0, 2^32 - 1]. The simplification used
/// here: the canonical form has no leading zeros except for
/// `"0"` itself, contains only ASCII digits, and parses to a
/// number that round-trips. Returns the numeric value or
/// `null` for non-integer keys.
fn canonicalIntegerIndex(s: []const u8) ?u32 {
    if (s.len == 0) return null;
    if (s.len > 10) return null; // u32 max is 10 digits
    if (s[0] == '0' and s.len > 1) return null; // no leading zero
    var n: u64 = 0;
    for (s) |c| {
        if (c < '0' or c > '9') return null;
        n = n * 10 + (c - '0');
        if (n > std.math.maxInt(u32)) return null;
    }
    return @intCast(n);
}

/// §10.1.11 OrdinaryOwnPropertyKeys ordering. Returns own
/// property keys in spec order: integer-indexed in ascending
/// numeric order, then string keys in insertion order, then
/// (eventually) symbol keys. Skips internal `__cynic_*` slots.
/// Caller owns the returned slice (allocated via `realm.allocator`).
pub fn ownPropertyKeysOrdered(
    realm: *Realm,
    obj: *JSObject,
) NativeError![]const []const u8 {
    const KeyEntry = struct { idx: u32, key: []const u8 };
    var integer_keys: std.ArrayListUnmanaged(KeyEntry) = .empty;
    defer integer_keys.deinit(realm.allocator);
    var string_keys: std.ArrayListUnmanaged([]const u8) = .empty;
    defer string_keys.deinit(realm.allocator);

    // §10.4.2 Array exotic — packed-element indices are own
    // string-keyed properties for §7.3.21 OrdinaryOwnPropertyKeys.
    // Holes (slots equal to the hole sentinel) are NOT own
    // properties (§10.4.2.1 step 2) and are skipped here.
    if (obj.is_array_exotic) {
        if (obj.is_sparse) {
            var sit = obj.sparse_elements.iterator();
            while (sit.next()) |entry| {
                const idx = entry.key_ptr.*;
                if (JSObject.isElementHole(entry.value_ptr.*)) continue;
                var ibuf: [16]u8 = undefined;
                const ks = std.fmt.bufPrint(&ibuf, "{d}", .{idx}) catch continue;
                const owned = realm.heap.allocateString(ks) catch return error.OutOfMemory;
                integer_keys.append(realm.allocator, .{ .idx = idx, .key = owned.bytes }) catch return error.OutOfMemory;
            }
        } else {
            var ei: u32 = 0;
            while (ei < obj.elements.items.len) : (ei += 1) {
                if (JSObject.isElementHole(obj.elements.items[ei])) continue;
                var ibuf: [16]u8 = undefined;
                const ks = std.fmt.bufPrint(&ibuf, "{d}", .{ei}) catch continue;
                const owned = realm.heap.allocateString(ks) catch return error.OutOfMemory;
                integer_keys.append(realm.allocator, .{ .idx = ei, .key = owned.bytes }) catch return error.OutOfMemory;
            }
        }
    }
    var it = obj.properties.iterator();
    while (it.next()) |entry| {
        const k = entry.key_ptr.*;
        if (std.mem.startsWith(u8, k, "__cynic_")) continue;
        if (canonicalIntegerIndex(k)) |i| {
            integer_keys.append(realm.allocator, .{ .idx = i, .key = k }) catch return error.OutOfMemory;
        } else {
            string_keys.append(realm.allocator, k) catch return error.OutOfMemory;
        }
    }
    // Accessors live in a separate map; include their keys too.
    var ait = obj.accessors.iterator();
    while (ait.next()) |entry| {
        const k = entry.key_ptr.*;
        if (std.mem.startsWith(u8, k, "__cynic_")) continue;
        if (obj.properties.contains(k)) continue; // already counted
        if (canonicalIntegerIndex(k)) |i| {
            integer_keys.append(realm.allocator, .{ .idx = i, .key = k }) catch return error.OutOfMemory;
        } else {
            string_keys.append(realm.allocator, k) catch return error.OutOfMemory;
        }
    }

    std.mem.sort(KeyEntry, integer_keys.items, {}, struct {
        fn lessThan(_: void, a: KeyEntry, b: KeyEntry) bool {
            return a.idx < b.idx;
        }
    }.lessThan);

    const total = integer_keys.items.len + string_keys.items.len;
    const out = realm.allocator.alloc([]const u8, total) catch return error.OutOfMemory;
    var i: usize = 0;
    for (integer_keys.items) |e| {
        out[i] = e.key;
        i += 1;
    }
    for (string_keys.items) |k| {
        out[i] = k;
        i += 1;
    }
    return out;
}

/// §10.5.11 Proxy [[OwnPropertyKeys]] — when `obj` is a proxy
/// with an `ownKeys` handler trap, call it and convert the
/// returned Array into a `[]const []const u8` slice. The caller
/// owns the slice and frees it via `realm.allocator`. Returns
/// `null` when no trap fires; the caller falls back to walking
/// the target's own keys directly.
fn proxyOwnKeysOrNull(realm: *Realm, obj: *JSObject) NativeError!?[]const []const u8 {
    const proxy_target = obj.proxy_target orelse return null;
    // §10.5.11 step 2 — revoked proxy throws TypeError.
    if (obj.proxy_revoked) return throwTypeError(realm, "Cannot perform 'ownKeys' on a revoked proxy");
    const handler = obj.proxy_handler orelse return throwTypeError(realm, "Cannot perform 'ownKeys' on a proxy with null handler");
    const trap_v = handler.get("ownKeys");
    // §10.5.11 step 5 — trap is `undefined` / `null` → fall back
    // to target's [[OwnPropertyKeys]]. Anything else non-callable
    // is a TypeError per IsCallable.
    if (trap_v.isUndefined() or trap_v.isNull()) {
        return try ownPropertyKeysOrdered(realm, proxy_target);
    }
    const trap_fn = heap_mod.valueAsFunction(trap_v) orelse return throwTypeError(realm, "Proxy 'ownKeys' trap is not callable");
    const interpreter = @import("../interpreter.zig");
    const trap_args = [_]Value{heap_mod.taggedObject(proxy_target)};
    const outcome = interpreter.callJSFunction(realm.allocator, realm, trap_fn, heap_mod.taggedObject(handler), &trap_args) catch |err| switch (err) {
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
    const result = heap_mod.valueAsPlainObject(result_v) orelse return throwTypeError(realm, "'ownKeys' on proxy must return an array-like");
    const len = lengthOfArrayLocal(result);
    var out: std.ArrayListUnmanaged([]const u8) = .empty;
    var seen: std.StringArrayHashMapUnmanaged(void) = .empty;
    defer seen.deinit(realm.allocator);
    var i: i64 = 0;
    while (i < len) : (i += 1) {
        var ibuf: [24]u8 = undefined;
        const islice = std.fmt.bufPrint(&ibuf, "{d}", .{i}) catch unreachable;
        const k_v = result.get(islice);
        // §10.5.11 step 8 — CreateListFromArrayLike rejects any
        // entry that isn't a String or Symbol. Numbers / booleans /
        // null / undefined → TypeError.
        if (!k_v.isString()) {
            // Cynic symbols are represented as JSSymbol values;
            // for the purpose of these tests anything not a
            // string is rejected. (Cross-realm symbols are out
            // of scope.)
            const sym = heap_mod.valueAsSymbol(k_v);
            if (sym == null) return throwTypeError(realm, "'ownKeys' on proxy returned a non-String, non-Symbol entry");
        }
        const key_str = if (k_v.isString())
            (@as(*JSString, @ptrCast(@alignCast(k_v.asString())))).bytes
        else blk: {
            const s = stringifyArg(realm, k_v) catch return error.OutOfMemory;
            break :blk s.bytes;
        };
        // §10.5.11 step 9 — duplicate keys → TypeError.
        const entry = seen.getOrPut(realm.allocator, key_str) catch return error.OutOfMemory;
        if (entry.found_existing) return throwTypeError(realm, "'ownKeys' on proxy returned duplicate entries");
        out.append(realm.allocator, key_str) catch return error.OutOfMemory;
    }
    // §10.5.11 step 17-24 — non-extensible target invariants.
    // Every non-configurable own key on the target must appear
    // in the result, and the result must not introduce keys
    // that don't exist on a non-extensible target.
    if (!proxy_target.extensible) {
        // Build a set of target's own keys for invariant checks.
        const target_keys = try ownPropertyKeysOrdered(realm, proxy_target);
        defer realm.allocator.free(target_keys);
        // (a) every target own key must be present in result.
        for (target_keys) |tk| {
            if (!seen.contains(tk)) {
                return throwTypeError(realm, "'ownKeys' on proxy omitted a key present on a non-extensible target");
            }
        }
        // (b) result must not contain extras absent from target.
        var target_set: std.StringArrayHashMapUnmanaged(void) = .empty;
        defer target_set.deinit(realm.allocator);
        for (target_keys) |tk| {
            target_set.put(realm.allocator, tk, {}) catch return error.OutOfMemory;
        }
        for (out.items) |rk| {
            if (!target_set.contains(rk)) {
                return throwTypeError(realm, "'ownKeys' on proxy added a key absent from a non-extensible target");
            }
        }
    }
    return out.toOwnedSlice(realm.allocator) catch return error.OutOfMemory;
}

fn lengthOfArrayLocal(obj: *JSObject) i64 {
    const len_v = obj.get("length");
    if (len_v.isInt32()) {
        const n = len_v.asInt32();
        return if (n < 0) 0 else n;
    }
    if (len_v.isDouble()) {
        const d = len_v.asDouble();
        if (std.math.isNan(d) or d <= 0) return 0;
        if (d > @as(f64, @floatFromInt(std.math.maxInt(i64)))) return std.math.maxInt(i64);
        return @intFromFloat(d);
    }
    return 0;
}

fn objectKeys(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = this_value;
    const arg = argOr(args, 0, Value.undefined_);
    // §17 — Function objects are also ordinary objects. Build
    // the result the same way as for a plain JSObject so
    // `Object.keys(class C { static x = 1 })` produces `["x"]`.
    if (heap_mod.valueAsFunction(arg)) |fn_obj| {
        const result = realm.heap.allocateObject() catch return error.OutOfMemory;
        result.prototype = realm.intrinsics.array_prototype;
        result.markAsArrayExotic(realm.allocator) catch return error.OutOfMemory;
        var idx: usize = 0;
        var fit = fn_obj.properties.iterator();
        while (fit.next()) |entry| {
            const key = entry.key_ptr.*;
            if (std.mem.startsWith(u8, key, "__cynic_")) continue;
            if (isSymbolKey(key)) continue;
            if (!fn_obj.flagsForOwn(key).enumerable) continue;
            const key_owned = realm.heap.allocateString(key) catch return error.OutOfMemory;
            var ibuf: [16]u8 = undefined;
            const islice = std.fmt.bufPrint(&ibuf, "{d}", .{idx}) catch unreachable;
            const idx_owned = realm.heap.allocateString(islice) catch return error.OutOfMemory;
            result.set(realm.allocator, idx_owned.bytes, Value.fromString(key_owned)) catch return error.OutOfMemory;
            idx += 1;
        }
        result.set(realm.allocator, "length", Value.fromInt32(@intCast(idx))) catch return error.OutOfMemory;
        return heap_mod.taggedObject(result);
    }
    const obj = heap_mod.valueAsPlainObject(arg) orelse return throwTypeError(realm, "Object.keys called on non-object");
    const keys = if (try proxyOwnKeysOrNull(realm, obj)) |k| k else try ownPropertyKeysOrdered(realm, obj);
    defer realm.allocator.free(keys);
    const result = realm.heap.allocateObject() catch return error.OutOfMemory;
    result.prototype = realm.intrinsics.array_prototype;
    result.markAsArrayExotic(realm.allocator) catch return error.OutOfMemory;
    var idx: usize = 0;
    for (keys) |key| {
        if (!obj.flagsFor(key).enumerable) continue;
        const key_str = realm.heap.allocateString(key) catch return error.OutOfMemory;
        var ibuf: [16]u8 = undefined;
        const islice = std.fmt.bufPrint(&ibuf, "{d}", .{idx}) catch unreachable;
        const owned = realm.heap.allocateString(islice) catch return error.OutOfMemory;
        result.set(realm.allocator, owned.bytes, Value.fromString(key_str)) catch return error.OutOfMemory;
        idx += 1;
    }
    result.set(realm.allocator, "length", Value.fromInt32(@intCast(idx))) catch return error.OutOfMemory;
    return heap_mod.taggedObject(result);
}

fn objectValues(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = this_value;
    const obj = heap_mod.valueAsPlainObject(argOr(args, 0, Value.undefined_)) orelse return throwTypeError(realm, "Object.values called on non-object");
    const keys = try ownPropertyKeysOrdered(realm, obj);
    defer realm.allocator.free(keys);
    const result = realm.heap.allocateObject() catch return error.OutOfMemory;
    result.prototype = realm.intrinsics.array_prototype;
    result.markAsArrayExotic(realm.allocator) catch return error.OutOfMemory;
    var idx: usize = 0;
    for (keys) |key| {
        if (!obj.flagsFor(key).enumerable) continue;
        var ibuf: [16]u8 = undefined;
        const islice = std.fmt.bufPrint(&ibuf, "{d}", .{idx}) catch unreachable;
        const owned = realm.heap.allocateString(islice) catch return error.OutOfMemory;
        const v = try getPropertyChain(realm, obj, key);
        result.set(realm.allocator, owned.bytes, v) catch return error.OutOfMemory;
        idx += 1;
    }
    result.set(realm.allocator, "length", Value.fromInt32(@intCast(idx))) catch return error.OutOfMemory;
    return heap_mod.taggedObject(result);
}

fn objectEntries(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = this_value;
    const obj = heap_mod.valueAsPlainObject(argOr(args, 0, Value.undefined_)) orelse return throwTypeError(realm, "Object.entries called on non-object");
    const keys = try ownPropertyKeysOrdered(realm, obj);
    defer realm.allocator.free(keys);
    const result = realm.heap.allocateObject() catch return error.OutOfMemory;
    result.prototype = realm.intrinsics.array_prototype;
    result.markAsArrayExotic(realm.allocator) catch return error.OutOfMemory;
    var idx: usize = 0;
    for (keys) |key| {
        if (!obj.flagsFor(key).enumerable) continue;
        const pair = realm.heap.allocateObject() catch return error.OutOfMemory;
        pair.prototype = realm.intrinsics.array_prototype;
        pair.markAsArrayExotic(realm.allocator) catch return error.OutOfMemory;
        const key_str = realm.heap.allocateString(key) catch return error.OutOfMemory;
        const v = try getPropertyChain(realm, obj, key);
        pair.set(realm.allocator, "0", Value.fromString(key_str)) catch return error.OutOfMemory;
        pair.set(realm.allocator, "1", v) catch return error.OutOfMemory;
        pair.set(realm.allocator, "length", Value.fromInt32(2)) catch return error.OutOfMemory;
        var ibuf: [16]u8 = undefined;
        const islice = std.fmt.bufPrint(&ibuf, "{d}", .{idx}) catch unreachable;
        const owned = realm.heap.allocateString(islice) catch return error.OutOfMemory;
        result.set(realm.allocator, owned.bytes, heap_mod.taggedObject(pair)) catch return error.OutOfMemory;
        idx += 1;
    }
    result.set(realm.allocator, "length", Value.fromInt32(@intCast(idx))) catch return error.OutOfMemory;
    return heap_mod.taggedObject(result);
}

pub fn objectGetPrototypeOf(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = this_value;
    const arg = argOr(args, 0, Value.undefined_);
    // §10.5.1 Proxy [[GetPrototypeOf]] — dispatch through the
    // handler's `getPrototypeOf` trap before falling back.
    if (heap_mod.valueAsPlainObject(arg)) |obj| {
        if (obj.proxy_target) |proxy_target| {
            if (obj.proxy_revoked) return throwTypeError(realm, "Cannot perform 'getPrototypeOf' on a revoked proxy");
            const handler = obj.proxy_handler orelse return throwTypeError(realm, "Cannot perform 'getPrototypeOf' on a proxy with null handler");
            const trap_v = handler.get("getPrototypeOf");
            if (heap_mod.valueAsFunction(trap_v)) |trap_fn| {
                const interpreter = @import("../interpreter.zig");
                const trap_args = [_]Value{heap_mod.taggedObject(proxy_target)};
                const outcome = interpreter.callJSFunction(realm.allocator, realm, trap_fn, heap_mod.taggedObject(handler), &trap_args) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    else => return error.NativeThrew,
                };
                switch (outcome) {
                    .value, .yielded => |v| {
                        // §10.5.1 step 7 — trap result must be
                        // Object or Null.
                        if (!v.isNull() and heap_mod.valueAsPlainObject(v) == null and heap_mod.valueAsFunction(v) == null) {
                            return throwTypeError(realm, "'getPrototypeOf' on proxy must return an object or null");
                        }
                        return v;
                    },
                    .thrown => |ex| {
                        realm.pending_exception = ex;
                        return error.NativeThrew;
                    },
                }
            }
            // Trap absent — recurse on the target.
            const inner_args = [_]Value{heap_mod.taggedObject(proxy_target)};
            return objectGetPrototypeOf(realm, Value.undefined_, &inner_args);
        }
        if (obj.prototype) |p| return heap_mod.taggedObject(p);
        return Value.null_;
    }
    if (heap_mod.valueAsFunction(arg)) |fn_obj| {
        // §10.2.4 — a Function's `[[Prototype]]` is whichever
        // function-or-object slot is set. `static_parent` (a
        // `*JSFunction`) wins when present: that's how class
        // `B extends A` and the TypedArray `Int8Array → %TypedArray%`
        // chain are stored, since `JSFunction.proto` is typed
        // `*JSObject` and can't hold a function. `.prototype` is a
        // separate thing (the proto-of-instances-from-`new`).
        if (fn_obj.static_parent) |sp| return heap_mod.taggedFunction(sp);
        if (fn_obj.proto) |p| return heap_mod.taggedObject(p);
        return Value.null_;
    }
    return error.NativeThrew;
}

/// §20.1.2.13 Object.is(value1, value2) — SameValue per §7.2.10.
/// Distinguishes `+0` from `-0`, treats `NaN === NaN` as true,
/// uses strict equality otherwise.
fn objectIs(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = realm;
    _ = this_value;
    const a = argOr(args, 0, Value.undefined_);
    const b = argOr(args, 1, Value.undefined_);
    return Value.fromBool(intrinsics.sameValue(a, b));
}

fn objectHasOwn(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = this_value;
    const obj = heap_mod.valueAsPlainObject(argOr(args, 0, Value.undefined_)) orelse {
        return error.NativeThrew;
    };
    // §7.1.19 ToPropertyKey — the spec coerces non-string,
    // non-symbol args; `descriptorKey` handles strings, symbols,
    // and primitive ToString fallback.
    const key = descriptorKey(realm, argOr(args, 1, Value.undefined_)) catch return error.OutOfMemory;
    return Value.fromBool(obj.hasOwn(key));
}

// ── Property descriptors (§20.1.2) ──────────────────────────────────────────

fn descriptorKey(realm: *Realm, v: Value) NativeError![]const u8 {
    if (v.isString()) {
        const s: *JSString = @ptrCast(@alignCast(v.asString()));
        return s.bytes;
    }
    // Symbols use their stable `prop_key` slug (`@@iterator` for
    // well-known, `<sym:N>` for user-allocated). The interpreter's
    // computed-key path stringifies via the same slug, so
    // `Object.defineProperty(o, sym, ...)` and `o[sym]` resolve
    // to the same slot.
    if (heap_mod.valueAsSymbol(v)) |sym| return sym.prop_key;
    // §7.1.19 ToPropertyKey — fall back to ToString for numbers,
    // booleans, etc.
    const s = stringifyArg(realm, v) catch return error.OutOfMemory;
    return s.bytes;
}

/// §6.2.5.5 ToPropertyDescriptor result. Each `has_*` flag
/// records *presence* of the field on the descriptor object
/// (chain-walked via §7.3.12 HasProperty); the value alongside
/// is set only when present. `null` getter/setter means
/// `undefined` (legitimate per §6.2.5.4 — "no setter, throws on
/// write").
const ParsedDescriptor = struct {
    has_value: bool = false,
    value: Value = Value.undefined_,
    has_writable: bool = false,
    writable: bool = false,
    has_enumerable: bool = false,
    enumerable: bool = false,
    has_configurable: bool = false,
    configurable: bool = false,
    has_get: bool = false,
    getter: ?*JSFunction = null,
    has_set: bool = false,
    setter: ?*JSFunction = null,

    fn isAccessor(self: ParsedDescriptor) bool {
        return self.has_get or self.has_set;
    }
    fn isData(self: ParsedDescriptor) bool {
        return self.has_value or self.has_writable;
    }
    fn isGeneric(self: ParsedDescriptor) bool {
        return !self.isAccessor() and !self.isData();
    }
};

/// §6.2.5.5 ToPropertyDescriptor. Throws TypeError if:
/// • `get` is present and not callable / undefined.
/// • `set` is present and not callable / undefined.
/// • Both data fields (`value`/`writable`) and accessor fields
/// (`get`/`set`) are present (descriptors must be one shape).
fn parseDescriptor(realm: *Realm, desc: *@import("../object.zig").JSObject) NativeError!ParsedDescriptor {
    var out: ParsedDescriptor = .{};

    // §6.2.5.5 step 2 onward — every "Has + Get" pair walks the
    // descriptor's prototype chain. Use `getPropertyChain` so
    // inherited *accessor* properties (e.g. `Object.defineProperty(
    // proto, "value", { get: () => 42 })`) fire instead of being
    // silently treated as `undefined`.
    if (desc.hasProperty("enumerable")) {
        out.has_enumerable = true;
        out.enumerable = toBoolean(try getPropertyChain(realm, desc, "enumerable"));
    }
    if (desc.hasProperty("configurable")) {
        out.has_configurable = true;
        out.configurable = toBoolean(try getPropertyChain(realm, desc, "configurable"));
    }
    if (desc.hasProperty("value")) {
        out.has_value = true;
        out.value = try getPropertyChain(realm, desc, "value");
    }
    if (desc.hasProperty("writable")) {
        out.has_writable = true;
        out.writable = toBoolean(try getPropertyChain(realm, desc, "writable"));
    }
    if (desc.hasProperty("get")) {
        out.has_get = true;
        const get_v = try getPropertyChain(realm, desc, "get");
        if (!get_v.isUndefined()) {
            out.getter = heap_mod.valueAsFunction(get_v) orelse return throwTypeError(realm, "Object.defineProperty: getter must be callable or undefined");
        }
    }
    if (desc.hasProperty("set")) {
        out.has_set = true;
        const set_v = try getPropertyChain(realm, desc, "set");
        if (!set_v.isUndefined()) {
            out.setter = heap_mod.valueAsFunction(set_v) orelse return throwTypeError(realm, "Object.defineProperty: setter must be callable or undefined");
        }
    }
    if (out.isAccessor() and out.isData()) {
        return throwTypeError(realm, "Object.defineProperty: cannot mix accessor and data fields");
    }
    return out;
}

/// §10.1.6.3 ValidateAndApplyPropertyDescriptor — non-configurable
/// redefine guard. Returns true if the requested change is
/// permitted; false → caller throws TypeError.
fn isCompatibleRedefine(
    cur_is_accessor: bool,
    cur_flags: @import("../object.zig").PropertyFlags,
    cur_value: Value,
    cur_getter: ?*JSFunction,
    cur_setter: ?*JSFunction,
    new_desc: ParsedDescriptor,
) bool {
    // 4. If current.[[Configurable]] is false:
    if (!cur_flags.configurable) {
        // 4.a. desc must not set configurable to true.
        if (new_desc.has_configurable and new_desc.configurable) return false;
        // 4.b. desc must not toggle enumerable.
        if (new_desc.has_enumerable and new_desc.enumerable != cur_flags.enumerable) return false;
        // 4.c. desc must not be a generic descriptor + new_desc.has_value or has_get etc.
        // 5. If !IsGenericDescriptor(Desc):
        if (!new_desc.isGeneric()) {
            // 5.a. If IsDataDescriptor(current) != IsDataDescriptor(Desc):
            if (cur_is_accessor != new_desc.isAccessor()) return false;
            // 6. Else if both data:
            if (!cur_is_accessor and new_desc.isData()) {
                // 6.a. !current.[[Writable]] → desc must not toggle writable to true
                if (!cur_flags.writable) {
                    if (new_desc.has_writable and new_desc.writable) return false;
                    // 6.b. desc must not change value (sameValue).
                    if (new_desc.has_value and !sameValueZero(cur_value, new_desc.value)) return false;
                }
            }
            // 7. Else (both accessor):
            if (cur_is_accessor and new_desc.isAccessor()) {
                // 7.a. desc must not change get / set.
                if (new_desc.has_get and new_desc.getter != cur_getter) return false;
                if (new_desc.has_set and new_desc.setter != cur_setter) return false;
            }
        }
    }
    return true;
}

pub fn objectDefineProperty(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = this_value;
    const target_v = argOr(args, 0, Value.undefined_);
    const key = descriptorKey(realm, argOr(args, 1, Value.undefined_)) catch return error.OutOfMemory;
    const desc_v = argOr(args, 2, Value.undefined_);
    // §10.5.6 Proxy [[DefineOwnProperty]] — dispatch through the
    // handler's `defineProperty` trap before falling back.
    if (heap_mod.valueAsPlainObject(target_v)) |obj_in| {
        if (obj_in.proxy_target) |proxy_target| {
            if (obj_in.proxy_revoked) return throwTypeError(realm, "Cannot perform 'defineProperty' on a revoked proxy");
            const handler = obj_in.proxy_handler orelse return throwTypeError(realm, "Cannot perform 'defineProperty' on a proxy with null handler");
            const trap_v = handler.get("defineProperty");
            // §10.5.6 step 5 — IsCallable check. `undefined` /
            // `null` means "no trap; fall through". Anything else
            // non-callable is a TypeError.
            if (!trap_v.isUndefined() and !trap_v.isNull()) {
                const trap_fn = heap_mod.valueAsFunction(trap_v) orelse return throwTypeError(realm, "Proxy 'defineProperty' trap is not callable");
                const interpreter = @import("../interpreter.zig");
                const key_str = realm.heap.allocateString(key) catch return error.OutOfMemory;
                const trap_args = [_]Value{ heap_mod.taggedObject(proxy_target), Value.fromString(key_str), desc_v };
                const outcome = interpreter.callJSFunction(realm.allocator, realm, trap_fn, heap_mod.taggedObject(handler), &trap_args) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    else => return error.NativeThrew,
                };
                switch (outcome) {
                    .value, .yielded => |v| {
                        if (!intrinsics.toBoolean(v)) return throwTypeError(realm, "'defineProperty' on proxy returned falsy");
                        // §10.5.6 steps 16-19 — invariant guards.
                        // Read the target's current own-descriptor
                        // and compare against the descriptor we
                        // were asked to install. Three failure modes:
                        //   - target lacks the property AND is
                        //     non-extensible → throw.
                        //   - target lacks the property AND the
                        //     descriptor is non-configurable → throw.
                        //   - descriptor is incompatible with the
                        //     existing target descriptor → throw.
                        const target_had = proxy_target.hasOwn(key) or proxy_target.accessors.contains(key);
                        const parsed_for_inv = parseDescriptor(realm, heap_mod.valueAsPlainObject(desc_v) orelse return target_v) catch return target_v;
                        if (!target_had) {
                            if (!proxy_target.extensible) {
                                return throwTypeError(realm, "'defineProperty' on proxy: target is not extensible and trap returned truthy for an absent property");
                            }
                            if (parsed_for_inv.has_configurable and !parsed_for_inv.configurable) {
                                return throwTypeError(realm, "'defineProperty' on proxy: cannot define a non-configurable property absent from the target");
                            }
                        } else {
                            const cur_flags = proxy_target.flagsFor(key);
                            const cur_is_acc = proxy_target.accessors.contains(key);
                            const cur_value: Value = blk: {
                                if (cur_is_acc) break :blk Value.undefined_;
                                if (proxy_target.properties.get(key)) |val| break :blk val;
                                break :blk Value.undefined_;
                            };
                            var cur_getter: ?*JSFunction = null;
                            var cur_setter: ?*JSFunction = null;
                            if (proxy_target.accessors.get(key)) |a| {
                                cur_getter = a.getter;
                                cur_setter = a.setter;
                            }
                            if (!isCompatibleRedefine(cur_is_acc, cur_flags, cur_value, cur_getter, cur_setter, parsed_for_inv)) {
                                return throwTypeError(realm, "'defineProperty' on proxy: trap returned truthy for an incompatible redefine of a non-configurable target property");
                            }
                            // Configurable-flip guard — if the new
                            // descriptor is non-configurable but the
                            // target's current property is configurable,
                            // a fresh `getOwnPropertyDescriptor` on the
                            // target must observe the new flags. Since
                            // we don't actually mutate the target via
                            // the trap, just guard against the
                            // configurable-flip when the new desc
                            // is non-configurable but the target is.
                            if (parsed_for_inv.has_configurable and !parsed_for_inv.configurable and cur_flags.configurable) {
                                return throwTypeError(realm, "'defineProperty' on proxy: cannot flip a configurable target property to non-configurable via the trap");
                            }
                        }
                        return target_v;
                    },
                    .thrown => |ex| {
                        realm.pending_exception = ex;
                        return error.NativeThrew;
                    },
                }
            }
            // Trap absent — recurse on the target.
            const inner_args = [_]Value{ heap_mod.taggedObject(proxy_target), argOr(args, 1, Value.undefined_), desc_v };
            return objectDefineProperty(realm, Value.undefined_, &inner_args);
        }
    }
    const desc = heap_mod.valueAsPlainObject(desc_v) orelse return throwTypeError(realm, "Object.defineProperty descriptor is not an object");

    const parsed = try parseDescriptor(realm, desc);

    if (heap_mod.valueAsPlainObject(target_v)) |target| {
        // Snapshot the current descriptor (or `null` if absent).
        const had_own = target.hasOwn(key) or target.accessors.contains(key);
        const cur_flags = target.flagsFor(key);
        const cur_is_accessor = target.accessors.contains(key);
        // §10.1.6 — current value comes from `properties` first,
        // then from an Array exotic's `elements` for indexed keys
        // (so `defineProperty` sees the slot's actual value, not
        // undefined, when running the non-configurable redefine
        // guard on an already-set index).
        const cur_value: Value = blk_cv: {
            if (cur_is_accessor) break :blk_cv Value.undefined_;
            if (target.properties.get(key)) |v| break :blk_cv v;
            if (target.is_array_exotic) {
                if (ObjMod.JSObject.canonicalIntegerIndex(key)) |idx| {
                    if (target.tryGetIndexedOwn(idx)) |ev| break :blk_cv ev;
                }
            }
            break :blk_cv Value.undefined_;
        };
        var cur_getter: ?*JSFunction = null;
        var cur_setter: ?*JSFunction = null;
        if (target.accessors.get(key)) |a| {
            cur_getter = a.getter;
            cur_setter = a.setter;
        }

        // Non-configurable redefine guard.
        if (had_own and !isCompatibleRedefine(cur_is_accessor, cur_flags, cur_value, cur_getter, cur_setter, parsed)) {
            return throwTypeError(realm, "Object.defineProperty: cannot redefine non-configurable property");
        }

        // Compute the final flags. Missing fields preserve the
        // existing values (§10.1.6.3 step 1 — defaults absorbed).
        const default_for_new: @import("../object.zig").PropertyFlags = if (had_own) cur_flags else .{
            .writable = false,
            .enumerable = false,
            .configurable = false,
        };
        var flags = default_for_new;
        if (parsed.has_writable) flags.writable = parsed.writable;
        if (parsed.has_enumerable) flags.enumerable = parsed.enumerable;
        if (parsed.has_configurable) flags.configurable = parsed.configurable;

        if (parsed.isAccessor()) {
            // Replace any existing data slot — including the
            // Array exotic's packed `elements` slot for indexed
            // keys, otherwise reads via `JSObject.get` would
            // see the (now-stale) element value instead of
            // firing the accessor.
            _ = target.properties.swapRemove(key);
            if (target.is_array_exotic) {
                if (ObjMod.JSObject.canonicalIntegerIndex(key)) |idx| {
                    target.holeIndexed(idx);
                    // §10.4.2.4 ArraySetLength step 3.h — defining
                    // ANY property (data OR accessor) at index P
                    // where P ≥ length sets length to P + 1. The
                    // packed-data path inside `setWithFlags` does
                    // this; the accessor path historically didn't,
                    // so `Object.defineProperty([], "0", {get})`
                    // left `length === 0` and all subsequent
                    // `.map / .forEach / .filter` over-the-accessor
                    // fixtures saw an empty array.
                    const new_len: usize = @as(usize, idx) + 1;
                    if (target.arrayLength() < new_len) {
                        target.ensureElementsLen(realm.allocator, new_len) catch return error.OutOfMemory;
                        target.syncLengthProperty(realm.allocator) catch return error.OutOfMemory;
                    }
                }
            }
            const entry = target.accessors.getOrPut(realm.allocator, key) catch return error.OutOfMemory;
            // Preserve the half not specified in the new desc.
            const new_getter: ?*JSFunction = if (parsed.has_get) parsed.getter else if (cur_is_accessor) cur_getter else null;
            const new_setter: ?*JSFunction = if (parsed.has_set) parsed.setter else if (cur_is_accessor) cur_setter else null;
            entry.value_ptr.* = .{ .getter = new_getter, .setter = new_setter };
            // Accessors don't honor `writable`; clear that bit.
            flags.writable = false;
            target.property_flags.put(realm.allocator, key, flags) catch return error.OutOfMemory;
            return target_v;
        }

        // Data descriptor (or generic — preserves the existing
        // shape).
        if (parsed.isData() or !cur_is_accessor) {
            // Drop any previous accessor.
            _ = target.accessors.swapRemove(key);
            const value: Value = if (parsed.has_value) parsed.value else cur_value;
            target.setWithFlags(realm.allocator, key, value, flags) catch return error.OutOfMemory;
            return target_v;
        }

        // Generic descriptor on an existing accessor — keep the
        // accessor pair, just update flags.
        target.property_flags.put(realm.allocator, key, flags) catch return error.OutOfMemory;
        return target_v;
    }

    if (heap_mod.valueAsFunction(target_v)) |target_fn| {
        // §17 — function objects are ordinary objects too. Mirror
        // the JSObject path: accessor descriptors land in
        // `target_fn.accessors`; data descriptors land in
        // `properties`. The §10.1.6.3 non-configurable redefine
        // guard runs against the snapshotted current shape.
        const had_own = target_fn.hasOwn(key);
        const cur_flags = target_fn.flagsForOwn(key);
        const cur_is_accessor = target_fn.accessors.contains(key);
        const cur_value: Value = if (cur_is_accessor) Value.undefined_ else target_fn.get(key);
        var cur_getter: ?*JSFunction = null;
        var cur_setter: ?*JSFunction = null;
        if (target_fn.accessors.get(key)) |a| {
            cur_getter = a.getter;
            cur_setter = a.setter;
        }
        if (had_own and !isCompatibleRedefine(cur_is_accessor, cur_flags, cur_value, cur_getter, cur_setter, parsed)) {
            return throwTypeError(realm, "Object.defineProperty: cannot redefine non-configurable property");
        }

        const default_for_new: @import("../object.zig").PropertyFlags = if (had_own) cur_flags else .{
            .writable = false,
            .enumerable = false,
            .configurable = false,
        };
        var flags = default_for_new;
        if (parsed.has_writable) flags.writable = parsed.writable;
        if (parsed.has_enumerable) flags.enumerable = parsed.enumerable;
        if (parsed.has_configurable) flags.configurable = parsed.configurable;

        if (parsed.isAccessor()) {
            // Replace any existing data slot.
            _ = target_fn.properties.swapRemove(key);
            const entry = target_fn.accessors.getOrPut(realm.allocator, key) catch return error.OutOfMemory;
            const new_getter: ?*JSFunction = if (parsed.has_get) parsed.getter else if (cur_is_accessor) cur_getter else null;
            const new_setter: ?*JSFunction = if (parsed.has_set) parsed.setter else if (cur_is_accessor) cur_setter else null;
            entry.value_ptr.* = .{ .getter = new_getter, .setter = new_setter };
            // Accessors don't carry a `writable` bit; clear it.
            flags.writable = false;
            const is_default = flags.writable and flags.enumerable and flags.configurable;
            if (is_default) {
                _ = target_fn.property_flags.swapRemove(key);
            } else {
                target_fn.property_flags.put(realm.allocator, key, flags) catch return error.OutOfMemory;
            }
            return target_v;
        }

        if (parsed.isData() or !cur_is_accessor) {
            // Drop any previous accessor.
            _ = target_fn.accessors.swapRemove(key);
            const value: Value = if (parsed.has_value) parsed.value else cur_value;
            target_fn.setWithFlags(realm.allocator, key, value, flags) catch return error.OutOfMemory;
            return target_v;
        }

        // Generic descriptor on an existing accessor — just update flags.
        const is_default = flags.writable and flags.enumerable and flags.configurable;
        if (is_default) {
            _ = target_fn.property_flags.swapRemove(key);
        } else {
            target_fn.property_flags.put(realm.allocator, key, flags) catch return error.OutOfMemory;
        }
        return target_v;
    }

    return throwTypeError(realm, "Object.defineProperty target is not an object");
}

fn objectDefineProperties(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = this_value;
    const target = heap_mod.valueAsPlainObject(argOr(args, 0, Value.undefined_)) orelse return throwTypeError(realm, "Object.defineProperties target is not an object");
    const props = heap_mod.valueAsPlainObject(argOr(args, 1, Value.undefined_)) orelse return throwTypeError(realm, "Object.defineProperties properties is not an object");

    var it = props.properties.iterator();
    while (it.next()) |entry| {
        const key = entry.key_ptr.*;
        if (!props.flagsFor(key).enumerable) continue;
        // §20.1.2.3.1 step 5.b.ii — Get each descriptor through the
        // chain so accessor-backed descriptor slots fire.
        const desc_v = try getPropertyChain(realm, props, key);
        const inner_args = [_]Value{ heap_mod.taggedObject(target), blk: {
            const k_str = realm.heap.allocateString(key) catch return error.OutOfMemory;
            break :blk Value.fromString(k_str);
        }, desc_v };
        _ = try objectDefineProperty(realm, Value.undefined_, &inner_args);
    }
    return heap_mod.taggedObject(target);
}

pub fn objectGetOwnPropertyDescriptor(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = this_value;
    const target = argOr(args, 0, Value.undefined_);
    const key = descriptorKey(realm, argOr(args, 1, Value.undefined_)) catch return error.OutOfMemory;

    // §10.5.5 Proxy [[GetOwnProperty]] — when target is a proxy,
    // dispatch through `handler.getOwnPropertyDescriptor`.
    if (heap_mod.valueAsPlainObject(target)) |obj_in| {
        if (obj_in.proxy_target) |proxy_target| {
            if (obj_in.proxy_revoked) return throwTypeError(realm, "Cannot perform 'getOwnPropertyDescriptor' on a revoked proxy");
            const handler = obj_in.proxy_handler orelse return throwTypeError(realm, "Cannot perform 'getOwnPropertyDescriptor' on a proxy with null handler");
            const trap_v = handler.get("getOwnPropertyDescriptor");
            if (!trap_v.isUndefined() and !trap_v.isNull()) {
                const trap_fn = heap_mod.valueAsFunction(trap_v) orelse return throwTypeError(realm, "Proxy 'getOwnPropertyDescriptor' trap is not callable");
                const interpreter = @import("../interpreter.zig");
                const key_str = realm.heap.allocateString(key) catch return error.OutOfMemory;
                const trap_args = [_]Value{ heap_mod.taggedObject(proxy_target), Value.fromString(key_str) };
                const outcome = interpreter.callJSFunction(realm.allocator, realm, trap_fn, heap_mod.taggedObject(handler), &trap_args) catch |err| switch (err) {
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
                // §10.5.5 step 8 — trap result must be Object or
                // Undefined. (Symbols / numbers / null all reject.)
                if (!result_v.isUndefined() and heap_mod.valueAsPlainObject(result_v) == null) {
                    return throwTypeError(realm, "'getOwnPropertyDescriptor' on proxy must return an Object or undefined");
                }
                // §10.5.5 step 9-17 — invariants.
                const target_had = proxy_target.hasOwn(key) or proxy_target.accessors.contains(key);
                if (result_v.isUndefined()) {
                    // Trap reports "absent". The target's own
                    // non-configurable property MUST also be
                    // absent; otherwise the trap lied.
                    if (target_had) {
                        const tflags = proxy_target.flagsFor(key);
                        if (!tflags.configurable) {
                            return throwTypeError(realm, "'getOwnPropertyDescriptor' on proxy reported undefined for a non-configurable target property");
                        }
                        if (!proxy_target.extensible) {
                            return throwTypeError(realm, "'getOwnPropertyDescriptor' on proxy reported undefined for a present property of a non-extensible target");
                        }
                    }
                    return result_v;
                }
                // Trap returned a descriptor. If it claims
                // non-configurable, the target's current
                // descriptor must (a) exist, and (b) also be
                // non-configurable.
                const result_obj = heap_mod.valueAsPlainObject(result_v).?;
                const parsed_inv = parseDescriptor(realm, result_obj) catch return result_v;
                if (parsed_inv.has_configurable and !parsed_inv.configurable) {
                    if (!target_had) {
                        return throwTypeError(realm, "'getOwnPropertyDescriptor' on proxy reported non-configurable for an absent target property");
                    }
                    const tflags = proxy_target.flagsFor(key);
                    if (tflags.configurable) {
                        return throwTypeError(realm, "'getOwnPropertyDescriptor' on proxy flipped a configurable target property to non-configurable");
                    }
                    // If the trap reported non-configurable +
                    // non-writable data, target's matching field
                    // must agree.
                    if (parsed_inv.isData() and parsed_inv.has_writable and !parsed_inv.writable) {
                        if (tflags.writable) {
                            return throwTypeError(realm, "'getOwnPropertyDescriptor' on proxy reported non-writable for a writable target property");
                        }
                    }
                }
                return result_v;
            }
            // Trap absent — recurse on the target.
            const inner_args = [_]Value{ heap_mod.taggedObject(proxy_target), argOr(args, 1, Value.undefined_) };
            return objectGetOwnPropertyDescriptor(realm, Value.undefined_, &inner_args);
        }
    }

    if (heap_mod.valueAsPlainObject(target)) |obj| {
        // Accessor descriptor first.
        if (obj.accessors.get(key)) |acc| {
            const desc = realm.heap.allocateObject() catch return error.OutOfMemory;
            desc.prototype = realm.intrinsics.object_prototype;
            const get_v: Value = if (acc.getter) |g| heap_mod.taggedFunction(g) else Value.undefined_;
            const set_v: Value = if (acc.setter) |s| heap_mod.taggedFunction(s) else Value.undefined_;
            desc.set(realm.allocator, "get", get_v) catch return error.OutOfMemory;
            desc.set(realm.allocator, "set", set_v) catch return error.OutOfMemory;
            const flags = obj.flagsFor(key);
            desc.set(realm.allocator, "enumerable", Value.fromBool(flags.enumerable)) catch return error.OutOfMemory;
            desc.set(realm.allocator, "configurable", Value.fromBool(flags.configurable)) catch return error.OutOfMemory;
            return heap_mod.taggedObject(desc);
        }

        // Data descriptor.
        if (!obj.hasOwn(key)) return Value.undefined_;
        const value = obj.get(key);
        const flags = obj.flagsFor(key);
        const desc = realm.heap.allocateObject() catch return error.OutOfMemory;
        desc.prototype = realm.intrinsics.object_prototype;
        desc.set(realm.allocator, "value", value) catch return error.OutOfMemory;
        desc.set(realm.allocator, "writable", Value.fromBool(flags.writable)) catch return error.OutOfMemory;
        desc.set(realm.allocator, "enumerable", Value.fromBool(flags.enumerable)) catch return error.OutOfMemory;
        desc.set(realm.allocator, "configurable", Value.fromBool(flags.configurable)) catch return error.OutOfMemory;
        return heap_mod.taggedObject(desc);
    }

    // §17 — built-in functions are also ordinary objects.
    // Without this branch every `verifyProperty(builtin, "name",
    // …)` test falls through to the type-error path.
    if (heap_mod.valueAsFunction(target)) |fn_obj| {
        // Accessor descriptor first — symmetric with the JSObject
        // path above. §6.2.5 PropertyDescriptor: accessor and data
        // descriptors are mutually exclusive shapes.
        if (fn_obj.accessors.get(key)) |acc| {
            const desc = realm.heap.allocateObject() catch return error.OutOfMemory;
            desc.prototype = realm.intrinsics.object_prototype;
            const get_v: Value = if (acc.getter) |g| heap_mod.taggedFunction(g) else Value.undefined_;
            const set_v: Value = if (acc.setter) |s| heap_mod.taggedFunction(s) else Value.undefined_;
            desc.set(realm.allocator, "get", get_v) catch return error.OutOfMemory;
            desc.set(realm.allocator, "set", set_v) catch return error.OutOfMemory;
            const flags = fn_obj.flagsForOwn(key);
            desc.set(realm.allocator, "enumerable", Value.fromBool(flags.enumerable)) catch return error.OutOfMemory;
            desc.set(realm.allocator, "configurable", Value.fromBool(flags.configurable)) catch return error.OutOfMemory;
            return heap_mod.taggedObject(desc);
        }
        if (!fn_obj.hasOwn(key)) return Value.undefined_;
        const value = fn_obj.get(key);
        const flags = fn_obj.flagsForOwn(key);
        const desc = realm.heap.allocateObject() catch return error.OutOfMemory;
        desc.prototype = realm.intrinsics.object_prototype;
        desc.set(realm.allocator, "value", value) catch return error.OutOfMemory;
        desc.set(realm.allocator, "writable", Value.fromBool(flags.writable)) catch return error.OutOfMemory;
        desc.set(realm.allocator, "enumerable", Value.fromBool(flags.enumerable)) catch return error.OutOfMemory;
        desc.set(realm.allocator, "configurable", Value.fromBool(flags.configurable)) catch return error.OutOfMemory;
        return heap_mod.taggedObject(desc);
    }

    return throwTypeError(realm, "Object.getOwnPropertyDescriptor target is not an object");
}

fn objectGetOwnPropertyDescriptors(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = this_value;
    const obj = heap_mod.valueAsPlainObject(argOr(args, 0, Value.undefined_)) orelse return throwTypeError(realm, "Object.getOwnPropertyDescriptors target is not an object");
    const out = realm.heap.allocateObject() catch return error.OutOfMemory;
    out.prototype = realm.intrinsics.object_prototype;
    // §20.1.2.10 — walk OwnPropertyKeys(O), which on an Array
    // exotic surfaces the packed-element indices.
    const keys = try ownPropertyKeysOrdered(realm, obj);
    defer realm.allocator.free(keys);
    for (keys) |key| {
        const k_str = realm.heap.allocateString(key) catch return error.OutOfMemory;
        const inner_args = [_]Value{ heap_mod.taggedObject(obj), Value.fromString(k_str) };
        const desc = try objectGetOwnPropertyDescriptor(realm, Value.undefined_, &inner_args);
        out.set(realm.allocator, k_str.bytes, desc) catch return error.OutOfMemory;
    }
    return heap_mod.taggedObject(out);
}

fn objectGetOwnPropertyNames(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = this_value;
    const target = argOr(args, 0, Value.undefined_);
    // §17 — built-in function objects are ordinary objects too.
    // Without a function path here, every test262 fixture that
    // does `Object.getOwnPropertyNames(builtin)` (e.g.
    // ThrowTypeError/property-order, scoping length+name) raises
    // a TypeError instead of returning ["length", "name", …].
    if (heap_mod.valueAsFunction(target)) |fn_obj| {
        const out = realm.heap.allocateObject() catch return error.OutOfMemory;
        out.prototype = realm.intrinsics.array_prototype;
        out.markAsArrayExotic(realm.allocator) catch return error.OutOfMemory;
        var len: i32 = 0;
        var fit = fn_obj.properties.iterator();
        while (fit.next()) |entry| {
            const key = entry.key_ptr.*;
            if (std.mem.startsWith(u8, key, "__cynic_")) continue;
            if (isSymbolKey(key)) continue;
            var ibuf: [16]u8 = undefined;
            const islice = std.fmt.bufPrint(&ibuf, "{d}", .{len}) catch unreachable;
            const idx_owned = realm.heap.allocateString(islice) catch return error.OutOfMemory;
            const k_owned = realm.heap.allocateString(key) catch return error.OutOfMemory;
            out.set(realm.allocator, idx_owned.bytes, Value.fromString(k_owned)) catch return error.OutOfMemory;
            len += 1;
        }
        out.set(realm.allocator, "length", Value.fromInt32(len)) catch return error.OutOfMemory;
        return heap_mod.taggedObject(out);
    }
    const obj = heap_mod.valueAsPlainObject(target) orelse return throwTypeError(realm, "Object.getOwnPropertyNames target is not an object");
    const keys = try ownPropertyKeysOrdered(realm, obj);
    defer realm.allocator.free(keys);
    const out = realm.heap.allocateObject() catch return error.OutOfMemory;
    out.prototype = realm.intrinsics.array_prototype;
    out.markAsArrayExotic(realm.allocator) catch return error.OutOfMemory;
    var len: i32 = 0;
    for (keys) |key| {
        // §20.1.2.10 — string keys only. Symbol-property keys
        // (Cynic stores them as `@@<name>` for well-known and
        // `<sym:N>` for user-allocated) belong to
        // getOwnPropertySymbols.
        if (isSymbolKey(key)) continue;
        var ibuf: [16]u8 = undefined;
        const islice = std.fmt.bufPrint(&ibuf, "{d}", .{len}) catch unreachable;
        const idx_owned = realm.heap.allocateString(islice) catch return error.OutOfMemory;
        const k_owned = realm.heap.allocateString(key) catch return error.OutOfMemory;
        out.set(realm.allocator, idx_owned.bytes, Value.fromString(k_owned)) catch return error.OutOfMemory;
        len += 1;
    }
    out.set(realm.allocator, "length", Value.fromInt32(len)) catch return error.OutOfMemory;
    return heap_mod.taggedObject(out);
}

/// Cynic flattens symbol property keys into ordinary strings —
/// well-known symbols use the `@@<name>` form (so existing
/// installers can refer to them by literal), and
/// `Symbol(desc)` allocates a unique `<sym:N>` key. This helper
/// is the canonical "is this a symbol-keyed property?" check.
fn isSymbolKey(key: []const u8) bool {
    return std.mem.startsWith(u8, key, "@@") or std.mem.startsWith(u8, key, "<sym:");
}

fn objectGetOwnPropertySymbols(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = this_value;
    const obj = heap_mod.valueAsPlainObject(argOr(args, 0, Value.undefined_)) orelse return throwTypeError(realm, "Object.getOwnPropertySymbols target is not an object");
    const keys = try ownPropertyKeysOrdered(realm, obj);
    defer realm.allocator.free(keys);
    const out = realm.heap.allocateObject() catch return error.OutOfMemory;
    out.prototype = realm.intrinsics.array_prototype;
    out.markAsArrayExotic(realm.allocator) catch return error.OutOfMemory;
    var len: i32 = 0;
    for (keys) |key| {
        if (!isSymbolKey(key)) continue;
        // Recover the JSSymbol pointer from the heap's symbol
        // list by exact prop_key match. Linear scan; the lists
        // tend to be small (handful of well-knowns + however
        // many `Symbol()` the program allocated).
        var match: ?*@import("../symbol.zig").JSSymbol = null;
        for (realm.heap.symbols.items) |sym| {
            if (std.mem.eql(u8, sym.prop_key, key)) {
                match = sym;
                break;
            }
        }
        const sym = match orelse continue;
        var ibuf: [16]u8 = undefined;
        const islice = std.fmt.bufPrint(&ibuf, "{d}", .{len}) catch unreachable;
        const idx_owned = realm.heap.allocateString(islice) catch return error.OutOfMemory;
        out.set(realm.allocator, idx_owned.bytes, heap_mod.taggedSymbol(sym)) catch return error.OutOfMemory;
        len += 1;
    }
    out.set(realm.allocator, "length", Value.fromInt32(len)) catch return error.OutOfMemory;
    return heap_mod.taggedObject(out);
}

// ── Object extensibility + creation (§20.1.2 statics, later) ────────────────

fn objectCreate(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = this_value;
    const proto_v = argOr(args, 0, Value.undefined_);
    const obj = realm.heap.allocateObject() catch return error.OutOfMemory;
    if (proto_v.isNull()) {
        obj.prototype = null;
    } else if (heap_mod.valueAsPlainObject(proto_v)) |p| {
        obj.prototype = p;
    } else if (heap_mod.valueAsFunction(proto_v)) |fn_obj| {
        obj.prototype = fn_obj.prototype;
    } else {
        return throwTypeError(realm, "Object.create prototype must be an Object or null");
    }
    // Optional second arg: properties descriptor.
    if (args.len > 1 and !args[1].isUndefined()) {
        const props = heap_mod.valueAsPlainObject(args[1]) orelse return throwTypeError(realm, "Object.create properties must be an object");
        var it = props.properties.iterator();
        while (it.next()) |entry| {
            const key = entry.key_ptr.*;
            if (!props.flagsFor(key).enumerable) continue;
            const k_str = realm.heap.allocateString(key) catch return error.OutOfMemory;
            // §20.1.2.3.1 ObjectDefineProperties step 5.b.ii — Get
            // each descriptor through the chain so accessor-backed
            // descriptor slots fire.
            const desc_v = try getPropertyChain(realm, props, key);
            const inner = [_]Value{ heap_mod.taggedObject(obj), Value.fromString(k_str), desc_v };
            _ = try objectDefineProperty(realm, Value.undefined_, &inner);
        }
    }
    return heap_mod.taggedObject(obj);
}

fn objectAssign(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = this_value;
    const target = heap_mod.valueAsPlainObject(argOr(args, 0, Value.undefined_)) orelse return throwTypeError(realm, "Object.assign target must be an object");
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const src_v = args[i];
        if (src_v.isUndefined() or src_v.isNull()) continue;
        const src = heap_mod.valueAsPlainObject(src_v) orelse continue;
        // §20.1.2.1 step 5 — `OwnPropertyKeys(from)` includes the
        // Array exotic's packed indexed slots; `ownPropertyKeysOrdered`
        // surfaces them ahead of string keys.
        const keys = try ownPropertyKeysOrdered(realm, src);
        defer realm.allocator.free(keys);
        for (keys) |key| {
            if (std.mem.startsWith(u8, key, "__cynic_")) continue;
            if (!src.flagsFor(key).enumerable) continue;
            // §20.1.2.1 step 5.c.iv — Get(from, nextKey) so accessor
            // getters on the source fire instead of being read past.
            const v = try getPropertyChain(realm, src, key);
            target.set(realm.allocator, key, v) catch return error.OutOfMemory;
        }
    }
    return heap_mod.taggedObject(target);
}

fn objectFreeze(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = this_value;
    const arg = argOr(args, 0, Value.undefined_);
    const obj = heap_mod.valueAsPlainObject(arg) orelse return arg; // §20.1.2.5 — primitives pass through
    obj.extensible = false;
    // §10.1.4.1 SetIntegrityLevel(O, frozen) — mark every own
    // data property `{ writable: false, configurable: false }`
    // and every accessor `{ configurable: false }`.
    var it = obj.properties.iterator();
    while (it.next()) |entry| {
        const key = entry.key_ptr.*;
        const cur = obj.flagsFor(key);
        obj.property_flags.put(realm.allocator, key, .{
            .writable = false,
            .enumerable = cur.enumerable,
            .configurable = false,
        }) catch return error.OutOfMemory;
    }
    var ait = obj.accessors.iterator();
    while (ait.next()) |entry| {
        const key = entry.key_ptr.*;
        const cur = obj.flagsFor(key);
        obj.property_flags.put(realm.allocator, key, .{
            .writable = false, // N/A on accessors; spec says omitted.
            .enumerable = cur.enumerable,
            .configurable = false,
        }) catch return error.OutOfMemory;
    }
    return arg;
}

fn objectIsFrozen(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = realm;
    _ = this_value;
    const arg = argOr(args, 0, Value.undefined_);
    const obj = heap_mod.valueAsPlainObject(arg) orelse return Value.true_; // primitives are frozen
    if (obj.extensible) return Value.false_;
    var it = obj.properties.iterator();
    while (it.next()) |entry| {
        const flags = obj.flagsFor(entry.key_ptr.*);
        if (flags.writable or flags.configurable) return Value.false_;
    }
    // Accessor descriptors only need `configurable: false` to be
    // frozen; `writable` is N/A on accessors.
    var ait = obj.accessors.iterator();
    while (ait.next()) |entry| {
        const flags = obj.flagsFor(entry.key_ptr.*);
        if (flags.configurable) return Value.false_;
    }
    return Value.true_;
}

fn objectSeal(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = this_value;
    const arg = argOr(args, 0, Value.undefined_);
    const obj = heap_mod.valueAsPlainObject(arg) orelse return arg;
    obj.extensible = false;
    // §10.1.4.1 SetIntegrityLevel(O, sealed) — every own property
    // (data + accessor) loses configurability; writable bits
    // stay.
    var it = obj.properties.iterator();
    while (it.next()) |entry| {
        const key = entry.key_ptr.*;
        const cur = obj.flagsFor(key);
        obj.property_flags.put(realm.allocator, key, .{
            .writable = cur.writable,
            .enumerable = cur.enumerable,
            .configurable = false,
        }) catch return error.OutOfMemory;
    }
    var ait = obj.accessors.iterator();
    while (ait.next()) |entry| {
        const key = entry.key_ptr.*;
        const cur = obj.flagsFor(key);
        obj.property_flags.put(realm.allocator, key, .{
            .writable = cur.writable,
            .enumerable = cur.enumerable,
            .configurable = false,
        }) catch return error.OutOfMemory;
    }
    return arg;
}

fn objectIsSealed(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = realm;
    _ = this_value;
    const arg = argOr(args, 0, Value.undefined_);
    const obj = heap_mod.valueAsPlainObject(arg) orelse return Value.true_;
    if (obj.extensible) return Value.false_;
    var it = obj.properties.iterator();
    while (it.next()) |entry| {
        if (obj.flagsFor(entry.key_ptr.*).configurable) return Value.false_;
    }
    var ait = obj.accessors.iterator();
    while (ait.next()) |entry| {
        if (obj.flagsFor(entry.key_ptr.*).configurable) return Value.false_;
    }
    return Value.true_;
}

pub fn objectPreventExtensions(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = this_value;
    const arg = argOr(args, 0, Value.undefined_);
    if (heap_mod.valueAsPlainObject(arg)) |obj| {
        // §10.5.4 Proxy [[PreventExtensions]] — trap dispatch
        // with the proxy-revoked / null-handler guards.
        if (obj.proxy_target) |proxy_target| {
            if (obj.proxy_revoked) return throwTypeError(realm, "Cannot perform 'preventExtensions' on a revoked proxy");
            const handler = obj.proxy_handler orelse return throwTypeError(realm, "Cannot perform 'preventExtensions' on a proxy with null handler");
            const trap_v = handler.get("preventExtensions");
            if (heap_mod.valueAsFunction(trap_v)) |trap_fn| {
                const interpreter = @import("../interpreter.zig");
                const trap_args = [_]Value{heap_mod.taggedObject(proxy_target)};
                const outcome = interpreter.callJSFunction(realm.allocator, realm, trap_fn, heap_mod.taggedObject(handler), &trap_args) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    else => return error.NativeThrew,
                };
                switch (outcome) {
                    .value, .yielded => |v| {
                        if (!intrinsics.toBoolean(v)) {
                            return throwTypeError(realm, "'preventExtensions' on proxy returned falsy");
                        }
                        // §10.5.4 step 8 — invariant: when the
                        // trap reports success, the target must
                        // actually be non-extensible.
                        if (proxy_target.extensible) {
                            return throwTypeError(realm, "'preventExtensions' on proxy reported success but target is still extensible");
                        }
                        return arg;
                    },
                    .thrown => |ex| {
                        realm.pending_exception = ex;
                        return error.NativeThrew;
                    },
                }
            }
            const inner_args = [_]Value{heap_mod.taggedObject(proxy_target)};
            return objectPreventExtensions(realm, Value.undefined_, &inner_args);
        }
        obj.extensible = false;
    }
    return arg;
}

fn objectIsExtensible(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = this_value;
    const arg = argOr(args, 0, Value.undefined_);
    // §20.1.2.16 — when the receiver is not an Object, return
    // `false`. Functions ARE objects (§6.1.7); they're always
    // extensible (Cynic doesn't yet model `Object.preventExtensions`
    // on a JSFunction receiver). Return `true` unconditionally.
    if (heap_mod.valueAsFunction(arg) != null) return Value.true_;
    const obj = heap_mod.valueAsPlainObject(arg) orelse return Value.false_;
    // §10.5.3 Proxy [[IsExtensible]] — trap dispatch with the
    // invariant that the result must match the target's actual
    // extensibility.
    if (obj.proxy_target) |proxy_target| {
        if (obj.proxy_revoked) return throwTypeError(realm, "Cannot perform 'isExtensible' on a revoked proxy");
        const handler = obj.proxy_handler orelse return throwTypeError(realm, "Cannot perform 'isExtensible' on a proxy with null handler");
        const trap_v = handler.get("isExtensible");
        if (heap_mod.valueAsFunction(trap_v)) |trap_fn| {
            const interpreter = @import("../interpreter.zig");
            const trap_args = [_]Value{heap_mod.taggedObject(proxy_target)};
            const outcome = interpreter.callJSFunction(realm.allocator, realm, trap_fn, heap_mod.taggedObject(handler), &trap_args) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return error.NativeThrew,
            };
            switch (outcome) {
                .value, .yielded => |v| {
                    const reported = intrinsics.toBoolean(v);
                    // §10.5.3 step 8 — invariant: trap result
                    // must SameValue target.[[IsExtensible]]().
                    if (reported != proxy_target.extensible) {
                        return throwTypeError(realm, "'isExtensible' on proxy returned a value inconsistent with the target");
                    }
                    return Value.fromBool(reported);
                },
                .thrown => |ex| {
                    realm.pending_exception = ex;
                    return error.NativeThrew;
                },
            }
        }
        const inner_args = [_]Value{heap_mod.taggedObject(proxy_target)};
        return objectIsExtensible(realm, Value.undefined_, &inner_args);
    }
    return Value.fromBool(obj.extensible);
}

fn objectFromEntries(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = this_value;
    const interpreter = @import("../interpreter.zig");
    const iter = interpreter.openIterator(realm.allocator, realm, argOr(args, 0, Value.undefined_)) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return throwTypeError(realm, "Object.fromEntries argument is not iterable"),
    };
    const iter_obj = heap_mod.valueAsPlainObject(iter) orelse return throwTypeError(realm, "Object.fromEntries argument is not iterable");
    const next_v = iter_obj.get("next");
    const next_fn = heap_mod.valueAsFunction(next_v) orelse return throwTypeError(realm, "iterator.next is not callable");

    const out = realm.heap.allocateObject() catch return error.OutOfMemory;
    out.prototype = realm.intrinsics.object_prototype;

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
        // §7.4.5 IteratorComplete / IteratorValue use Get(), so
        // user-supplied iterator results with accessor `done`/`value`
        // slots must fire those getters.
        if (toBoolean(try getPropertyChain(realm, result, "done"))) break;
        const pair_v = try getPropertyChain(realm, result, "value");
        const pair = heap_mod.valueAsPlainObject(pair_v) orelse return throwTypeError(realm, "Object.fromEntries entry must be an object");
        const k = try getPropertyChain(realm, pair, "0");
        const v = try getPropertyChain(realm, pair, "1");
        const key_str = if (k.isString())
            (@as(*JSString, @ptrCast(@alignCast(k.asString())))).bytes
        else blk: {
            const s = stringifyArg(realm, k) catch return error.OutOfMemory;
            break :blk s.bytes;
        };
        out.set(realm.allocator, key_str, v) catch return error.OutOfMemory;
    }
    return heap_mod.taggedObject(out);
}

fn objectSetPrototypeOf(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = this_value;
    const target_v = argOr(args, 0, Value.undefined_);
    const proto_v = argOr(args, 1, Value.undefined_);
    // §20.1.2.20 step 1 — proto arg must be Object or Null.
    if (!proto_v.isNull() and heap_mod.valueAsPlainObject(proto_v) == null and heap_mod.valueAsFunction(proto_v) == null) {
        return throwTypeError(realm, "prototype must be an Object or null");
    }
    if (heap_mod.valueAsPlainObject(target_v)) |obj| {
        // §10.5.2 Proxy [[SetPrototypeOf]] — trap dispatch.
        if (obj.proxy_target) |proxy_target| {
            if (obj.proxy_revoked) return throwTypeError(realm, "Cannot perform 'setPrototypeOf' on a revoked proxy");
            const handler = obj.proxy_handler orelse return throwTypeError(realm, "Cannot perform 'setPrototypeOf' on a proxy with null handler");
            const trap_v = handler.get("setPrototypeOf");
            if (heap_mod.valueAsFunction(trap_v)) |trap_fn| {
                const interpreter = @import("../interpreter.zig");
                const trap_args = [_]Value{ heap_mod.taggedObject(proxy_target), proto_v };
                const outcome = interpreter.callJSFunction(realm.allocator, realm, trap_fn, heap_mod.taggedObject(handler), &trap_args) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    else => return error.NativeThrew,
                };
                switch (outcome) {
                    .value, .yielded => |v| {
                        if (!intrinsics.toBoolean(v)) {
                            return throwTypeError(realm, "'setPrototypeOf' on proxy returned falsy");
                        }
                        return target_v;
                    },
                    .thrown => |ex| {
                        realm.pending_exception = ex;
                        return error.NativeThrew;
                    },
                }
            }
            const inner_args = [_]Value{ heap_mod.taggedObject(proxy_target), proto_v };
            return objectSetPrototypeOf(realm, Value.undefined_, &inner_args);
        }
        if (proto_v.isNull()) {
            obj.prototype = null;
        } else if (heap_mod.valueAsPlainObject(proto_v)) |p| {
            obj.prototype = p;
        } else if (heap_mod.valueAsFunction(proto_v)) |fn_obj| {
            obj.prototype = fn_obj.prototype;
        }
    }
    return target_v;
}

/// §22.1.2.5 Object.groupBy(items, callbackfn) — partition `items`
/// into a null-prototype object keyed by `callbackfn(item, index)`.
/// Each bucket is an Array of the items that produced that key.
fn objectGroupBy(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = this_value;
    const interpreter = @import("../interpreter.zig");
    const items_v = argOr(args, 0, Value.undefined_);
    const cb_v = argOr(args, 1, Value.undefined_);
    const cb = heap_mod.valueAsFunction(cb_v) orelse return throwTypeError(realm, "Object.groupBy callback is not callable");

    const out = realm.heap.allocateObject() catch return error.OutOfMemory;
    out.prototype = null; // null-prototype per spec

    const iter = interpreter.openIterator(realm.allocator, realm, items_v) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return throwTypeError(realm, "Object.groupBy items is not iterable"),
    };
    const iter_obj = heap_mod.valueAsPlainObject(iter) orelse return throwTypeError(realm, "Object.groupBy items is not iterable");
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
        if (toBoolean(try getPropertyChain(realm, result, "done"))) break;
        const item = try getPropertyChain(realm, result, "value");
        const cb_args = [_]Value{ item, Value.fromInt32(@intCast(i)) };
        const key_outcome = interpreter.callJSFunction(realm.allocator, realm, cb, Value.undefined_, &cb_args) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.NativeThrew,
        };
        const key_v = switch (key_outcome) {
            .value, .yielded => |v| v,
            .thrown => return error.NativeThrew,
        };
        const key_str = if (key_v.isString())
            (@as(*JSString, @ptrCast(@alignCast(key_v.asString())))).bytes
        else blk: {
            const s = stringifyArg(realm, key_v) catch return error.OutOfMemory;
            break :blk s.bytes;
        };
        // Look up or create the bucket array.
        var bucket: *JSObject = undefined;
        if (out.properties.get(key_str)) |existing| {
            bucket = heap_mod.valueAsPlainObject(existing) orelse return error.NativeThrew;
        } else {
            bucket = realm.heap.allocateObject() catch return error.OutOfMemory;
            bucket.prototype = realm.intrinsics.array_prototype;
            bucket.markAsArrayExotic(realm.allocator) catch return error.OutOfMemory;
            bucket.set(realm.allocator, "length", Value.fromInt32(0)) catch return error.OutOfMemory;
            out.set(realm.allocator, key_str, heap_mod.taggedObject(bucket)) catch return error.OutOfMemory;
        }
        const cur_len = bucket.get("length");
        const len_i: i32 = if (cur_len.isInt32()) cur_len.asInt32() else 0;
        var idx_buf: [16]u8 = undefined;
        const idx_slice = std.fmt.bufPrint(&idx_buf, "{d}", .{len_i}) catch return error.OutOfMemory;
        // The property bag holds the key by reference, so the
        // bytes must outlive this stack frame — intern via the
        // heap.
        const idx_owned = realm.heap.allocateString(idx_slice) catch return error.OutOfMemory;
        bucket.set(realm.allocator, idx_owned.bytes, item) catch return error.OutOfMemory;
        bucket.set(realm.allocator, "length", Value.fromInt32(len_i + 1)) catch return error.OutOfMemory;
    }
    return heap_mod.taggedObject(out);
}

// ── Object.prototype methods ────────────────────────────────────────────────

fn objectHasOwnProperty(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    // §7.1.19 ToPropertyKey for the lookup — symbol args coerce
    // through their stable `prop_key` slug, primitives via ToString.
    const key = descriptorKey(realm, argOr(args, 0, Value.undefined_)) catch return error.OutOfMemory;
    if (heap_mod.valueAsPlainObject(this_value)) |obj| {
        return Value.fromBool(obj.hasOwn(key));
    }
    if (heap_mod.valueAsFunction(this_value)) |fn_obj| {
        return Value.fromBool(fn_obj.hasOwn(key));
    }
    return Value.false_;
}

/// §20.1.3.4 Object.prototype.propertyIsEnumerable. Returns
/// `true` iff `key` is an own property of the receiver and its
/// [[Enumerable]] attribute is `true`.
fn objectProtoPropertyIsEnumerable(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const key = descriptorKey(realm, argOr(args, 0, Value.undefined_)) catch return error.OutOfMemory;
    if (heap_mod.valueAsPlainObject(this_value)) |obj| {
        if (!obj.hasOwn(key)) return Value.false_;
        return Value.fromBool(obj.flagsFor(key).enumerable);
    }
    if (heap_mod.valueAsFunction(this_value)) |fn_obj| {
        if (!fn_obj.hasOwn(key)) return Value.false_;
        return Value.fromBool(fn_obj.flagsForOwn(key).enumerable);
    }
    return Value.false_;
}

/// §20.1.3.3 Object.prototype.isPrototypeOf. Returns `true` iff
/// `this_value` appears anywhere in `arg`'s prototype chain.
fn objectProtoIsPrototypeOf(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = realm;
    const target_v = argOr(args, 0, Value.undefined_);
    // §20.1.3.4 — walk target's `[[Prototype]]` chain looking
    // for `this`. The target can be a plain Object OR a Function
    // (e.g. `Function.prototype.isPrototypeOf(boundFn)`); the
    // function case used to short-circuit to `false` because
    // `valueAsPlainObject` rejects function values. Seed the
    // walk from `fn.proto` (a `*JSObject`) for callable targets.
    var p: ?*@import("../object.zig").JSObject = blk: {
        if (heap_mod.valueAsPlainObject(target_v)) |o| break :blk o.prototype;
        if (heap_mod.valueAsFunction(target_v)) |fn_obj| break :blk fn_obj.proto;
        return Value.false_;
    };
    const this_obj = heap_mod.valueAsPlainObject(this_value) orelse return Value.false_;
    while (p) |proto| {
        if (proto == this_obj) return Value.true_;
        p = proto.prototype;
    }
    return Value.false_;
}

/// §22.1.3.5 Object.prototype.toString. Spec walk:
/// 1. If receiver is `undefined` → `"[object Undefined]"`.
/// 2. If receiver is `null` → `"[object Null]"`.
/// 3. ToObject the receiver.
/// 4. Pick a built-in tag based on the internal-slot family
/// (`isArray`, `Map`-with-mapdata, `arguments`, etc.).
/// 5. If the receiver has a `Symbol.toStringTag` own- or
/// inherited-string property, override the built-in tag
/// with that string.
/// 6. Format `"[object " + tag + "]"`.
fn objectProtoToString(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = args;
    if (this_value.isUndefined()) {
        const s = realm.heap.allocateString("[object Undefined]") catch return error.OutOfMemory;
        return Value.fromString(s);
    }
    if (this_value.isNull()) {
        const s = realm.heap.allocateString("[object Null]") catch return error.OutOfMemory;
        return Value.fromString(s);
    }

    // Step 4 — built-in default tag. Drives every "[object X]"
    // shape that doesn't go through Symbol.toStringTag.
    const builtin_tag: []const u8 = blk: {
        if (heap_mod.isFunction(this_value)) break :blk "Function";
        if (this_value.isString()) break :blk "String";
        if (this_value.isNumber()) break :blk "Number";
        if (this_value.isBool()) break :blk "Boolean";
        if (heap_mod.isSymbol(this_value)) break :blk "Symbol";
        if (heap_mod.isBigInt(this_value)) break :blk "BigInt";
        if (heap_mod.valueAsPlainObject(this_value)) |obj| {
            // §22.1.3.6 step 4 — pick the built-in tag from the
            // internal slot present on the receiver. Order
            // matters per the spec table.
            if (obj.is_array_exotic) break :blk "Array";
            if (obj.prototype != null and obj.prototype == realm.intrinsics.array_prototype) break :blk "Array";
            if (obj.regex_bytecode != null) break :blk "RegExp";
            if (obj.array_buffer != null) break :blk "Object"; // ArrayBuffer uses @@toStringTag
            if (obj.boxed_primitive) |bp| {
                if (bp.isBool()) break :blk "Boolean";
                if (bp.isInt32() or bp.isDouble()) break :blk "Number";
            }
            if (obj.boxed_string != null) break :blk "String";
            // Date / Error / arguments: rely on @@toStringTag
            // walked in step 5 below. Default falls through.
            break :blk "Object";
        }
        break :blk "Object";
    };

    // Step 5 — Symbol.toStringTag override. Looked up under the
    // synthetic `@@toStringTag` key (well-known-Symbol property
    // identity, later wiring). Prototype chain walked because
    // built-in installations live on the prototype, not the
    // instance.
    const tag_v = lookupToStringTag(realm, this_value);
    var tag_slice: []const u8 = builtin_tag;
    if (tag_v) |v| {
        if (v.isString()) {
            const ts: *JSString = @ptrCast(@alignCast(v.asString()));
            tag_slice = ts.bytes;
        }
    }

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(realm.allocator);
    try buf.appendSlice(realm.allocator, "[object ");
    try buf.appendSlice(realm.allocator, tag_slice);
    try buf.append(realm.allocator, ']');
    const s = realm.heap.allocateString(buf.items) catch return error.OutOfMemory;
    return Value.fromString(s);
}

/// Walk the receiver's prototype chain looking for a string
/// `Symbol.toStringTag` slot (under the synthetic `@@toStringTag`
/// key). Plain objects, functions, and primitive wrappers all
/// route here. `null` means "no override; use built-in tag."
fn lookupToStringTag(realm: *Realm, this_value: Value) ?Value {
    _ = realm;
    if (heap_mod.valueAsPlainObject(this_value)) |obj| {
        const v = obj.get("@@toStringTag");
        if (v.isString()) return v;
        return null;
    }
    if (heap_mod.valueAsFunction(this_value)) |fn_obj| {
        const v = fn_obj.get("@@toStringTag");
        if (v.isString()) return v;
        return null;
    }
    return null;
}

fn objectProtoValueOf(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = realm;
    _ = args;
    return this_value;
}

