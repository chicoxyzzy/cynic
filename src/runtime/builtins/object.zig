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
const throwRangeError = intrinsics.throwRangeError;
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
    // §20.1.1.1 step 3a — `Object(value)` returns the value
    // unchanged only when Type(value) is Object (§6.1.7).
    // `Value.isObject` is the *heap-tag* predicate which also
    // covers Symbol and BigInt (both are heap-allocated
    // primitives, §6.1.5 / §6.1.6.2). Use `isJSObject` so those
    // primitives fall through to the ToObject wrapper path.
    if (heap_mod.isJSObject(arg)) {
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
    // §10.4.5.7 [[OwnPropertyKeys]] for Integer-Indexed Exotic
    // Objects — every index in [0, [[ArrayLength]]) is an own
    // String-keyed property in ascending numeric order, ahead of
    // the ordinary property keys. Length-tracking views over a
    // resizable ArrayBuffer report against the current live
    // length; a fixed-length view past the buffer's current
    // bound reports zero indices (per §10.4.5.13
    // IsValidIntegerIndex's IsTypedArrayOutOfBounds gate).
    if (obj.typed_view) |tv| {
        const live_len: u32 = blk: {
            const buf = tv.viewed.array_buffer orelse break :blk 0;
            const elem_size = tv.kind.elementSize();
            if (tv.length_tracking) {
                if (tv.byte_offset > buf.len) break :blk 0;
                break :blk @intCast((buf.len - tv.byte_offset) / elem_size);
            }
            if (tv.byte_offset + tv.length * elem_size > buf.len) break :blk 0;
            break :blk @intCast(tv.length);
        };
        var ti: u32 = 0;
        while (ti < live_len) : (ti += 1) {
            var ibuf: [16]u8 = undefined;
            const ks = std.fmt.bufPrint(&ibuf, "{d}", .{ti}) catch continue;
            const owned = realm.heap.allocateString(ks) catch return error.OutOfMemory;
            integer_keys.append(realm.allocator, .{ .idx = ti, .key = owned.bytes }) catch return error.OutOfMemory;
        }
    }
    var it = obj.properties.iterator();
    while (it.next()) |entry| {
        const k = entry.key_ptr.*;
        if (std.mem.startsWith(u8, k, "__cynic_")) continue;
        // §10.4.5.7 — for typed arrays, the integer-index slots
        // are already pulled from the live view above; any
        // matching keys lingering in `properties` (e.g. from a
        // historical bypass-set) must NOT be reported twice and
        // are also NOT eligible to land in the ordinary keys
        // bucket (the spec says integer-indexed keys live only
        // in the prefix). Drop them.
        if (obj.typed_view != null) {
            if (canonicalIntegerIndex(k)) |_| continue;
        }
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
        if (obj.typed_view != null) {
            if (canonicalIntegerIndex(k)) |_| continue;
        }
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

    // §9.4.6.12 Module Namespace [[OwnPropertyKeys]] — the spec
    // returns `sortedExports ++ symbolKeys` where `sortedExports`
    // is the export list ordered as if sorted via
    // `Array.prototype.sort(undefined)`, i.e. lexicographic by
    // UTF-16 code unit. The `@@toStringTag` symbol-keyed entry
    // (Cynic's flattened `@@toStringTag` key) follows the
    // exports. We sort the *string* portion here; symbol keys
    // (`@@*` / `<sym:*>`) get partitioned out by the callers
    // (getOwnPropertyNames vs getOwnPropertySymbols) and the
    // symbol slot naturally lands last in the combined slice.
    if (obj.is_module_namespace) {
        const Lt = struct {
            fn lessThan(_: void, a: []const u8, b: []const u8) bool {
                return std.mem.lessThan(u8, a, b);
            }
        };
        // Split string_keys into "real" exports vs symbol keys so
        // sort doesn't put `@@toStringTag` between two letters.
        var real_keys: std.ArrayListUnmanaged([]const u8) = .empty;
        defer real_keys.deinit(realm.allocator);
        var sym_keys: std.ArrayListUnmanaged([]const u8) = .empty;
        defer sym_keys.deinit(realm.allocator);
        for (string_keys.items) |k| {
            if (std.mem.startsWith(u8, k, "@@") or std.mem.startsWith(u8, k, "<sym:")) {
                sym_keys.append(realm.allocator, k) catch return error.OutOfMemory;
            } else {
                real_keys.append(realm.allocator, k) catch return error.OutOfMemory;
            }
        }
        std.mem.sort([]const u8, real_keys.items, {}, Lt.lessThan);
        // Re-merge: exports (sorted) first, then symbol keys.
        string_keys.clearRetainingCapacity();
        for (real_keys.items) |k| string_keys.append(realm.allocator, k) catch return error.OutOfMemory;
        for (sym_keys.items) |k| string_keys.append(realm.allocator, k) catch return error.OutOfMemory;
    }

    // §7.3.21 OrdinaryOwnPropertyKeys final ordering — integer
    // indices first (already sorted), then String keys in insertion
    // order, then Symbol keys in insertion order. Cynic flattens
    // Symbols to `@@<name>` / `<sym:N>` prop_keys; partition the
    // string slot accordingly so a typed array (or any object
    // with mixed string + symbol keys) reports the spec order.
    var ord_str: std.ArrayListUnmanaged([]const u8) = .empty;
    defer ord_str.deinit(realm.allocator);
    var ord_sym: std.ArrayListUnmanaged([]const u8) = .empty;
    defer ord_sym.deinit(realm.allocator);
    for (string_keys.items) |k| {
        if (std.mem.startsWith(u8, k, "@@") or std.mem.startsWith(u8, k, "<sym:")) {
            ord_sym.append(realm.allocator, k) catch return error.OutOfMemory;
        } else {
            ord_str.append(realm.allocator, k) catch return error.OutOfMemory;
        }
    }
    const total = integer_keys.items.len + ord_str.items.len + ord_sym.items.len;
    const out = realm.allocator.alloc([]const u8, total) catch return error.OutOfMemory;
    var i: usize = 0;
    for (integer_keys.items) |e| {
        out[i] = e.key;
        i += 1;
    }
    for (ord_str.items) |k| {
        out[i] = k;
        i += 1;
    }
    for (ord_sym.items) |k| {
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
    if (obj.proxy_target == null and !obj.proxy_revoked) return null;
    // §10.5.11 step 2 — revoked proxy throws TypeError.
    if (obj.proxy_revoked) return throwTypeError(realm, "Cannot perform 'ownKeys' on a revoked proxy");
    const proxy_target = obj.proxy_target.?;
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
            const s = try stringifyArg(realm, k_v);
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
    const raw = argOr(args, 0, Value.undefined_);
    // §20.1.2.18 step 1 — `Let obj be ? ToObject(O)`. ES2015+
    // accepts primitives. Coerce non-object, non-function args
    // through `toObjectThis` so `Object.keys(0)` returns `[]`
    // instead of throwing.
    const arg = if (raw.isInt32() or raw.isDouble() or raw.isString() or raw.isBool()) blk: {
        const w = try intrinsics.toObjectThis(realm, raw);
        break :blk heap_mod.taggedObject(w);
    } else raw;
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
    const raw = argOr(args, 0, Value.undefined_);
    // §20.1.2.21 step 1 — ToObject; primitives coerce.
    const coerced = if (raw.isInt32() or raw.isDouble() or raw.isString() or raw.isBool())
        heap_mod.taggedObject(try intrinsics.toObjectThis(realm, raw))
    else
        raw;
    const obj = heap_mod.valueAsPlainObject(coerced) orelse return throwTypeError(realm, "Object.values called on non-object");
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
    const raw = argOr(args, 0, Value.undefined_);
    const coerced = if (raw.isInt32() or raw.isDouble() or raw.isString() or raw.isBool())
        heap_mod.taggedObject(try intrinsics.toObjectThis(realm, raw))
    else
        raw;
    const obj = heap_mod.valueAsPlainObject(coerced) orelse return throwTypeError(realm, "Object.entries called on non-object");
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
    const raw = argOr(args, 0, Value.undefined_);
    // §20.1.2.13 step 1 — `Let obj be ? ToObject(O)`. ES2015+
    // accepts primitives; the wrapper's [[Prototype]] is the
    // matching `<Type>.prototype`. Without this, `Object.getPrototypeOf(0)`
    // throws instead of returning `Number.prototype`.
    const arg = if (raw.isInt32() or raw.isDouble() or raw.isString() or raw.isBool()) blk: {
        const w = try intrinsics.toObjectThis(realm, raw);
        break :blk heap_mod.taggedObject(w);
    } else raw;
    // §10.5.1 Proxy [[GetPrototypeOf]] — dispatch through the
    // handler's `getPrototypeOf` trap before falling back.
    if (heap_mod.valueAsPlainObject(arg)) |obj| {
        if (obj.proxy_target != null or obj.proxy_revoked) {
            if (obj.proxy_revoked) return throwTypeError(realm, "Cannot perform 'getPrototypeOf' on a revoked proxy");
            const proxy_target = obj.proxy_target.?;
            const handler = obj.proxy_handler orelse return throwTypeError(realm, "Cannot perform 'getPrototypeOf' on a proxy with null handler");
            const trap_v = handler.get("getPrototypeOf");
            // §10.5.1 step 5 — GetMethod: undefined/null → no trap.
            // A non-callable, non-nullish value throws TypeError.
            if (!trap_v.isUndefined() and !trap_v.isNull()) {
                const trap_fn = heap_mod.valueAsFunction(trap_v) orelse return throwTypeError(realm, "Proxy 'getPrototypeOf' trap is not callable");
                const interpreter = @import("../interpreter.zig");
                const trap_args = [_]Value{heap_mod.taggedObject(proxy_target)};
                const outcome = interpreter.callJSFunction(realm.allocator, realm, trap_fn, heap_mod.taggedObject(handler), &trap_args) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    else => return error.NativeThrew,
                };
                const handler_proto = switch (outcome) {
                    .value, .yielded => |v| v,
                    .thrown => |ex| {
                        realm.pending_exception = ex;
                        return error.NativeThrew;
                    },
                };
                // §10.5.1 step 7 — trap result must be Object or Null.
                if (!handler_proto.isNull() and heap_mod.valueAsPlainObject(handler_proto) == null and heap_mod.valueAsFunction(handler_proto) == null) {
                    return throwTypeError(realm, "'getPrototypeOf' on proxy must return an object or null");
                }
                // §10.5.1 step 9-12 — non-extensible target invariant:
                // handlerProto must SameValue target.[[GetPrototypeOf]]().
                if (!proxy_target.extensible) {
                    const target_proto_args = [_]Value{heap_mod.taggedObject(proxy_target)};
                    const target_proto = try objectGetPrototypeOf(realm, Value.undefined_, &target_proto_args);
                    if (!intrinsics.sameValue(handler_proto, target_proto)) {
                        return throwTypeError(realm, "'getPrototypeOf' on proxy returned a prototype different from the target's prototype on a non-extensible target");
                    }
                }
                return handler_proto;
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
    // §7.1.19 ToPropertyKey:
    //   1. key = ToPrimitive(arg, hint "string")
    //   2. If key is Symbol, return key
    //   3. Return ToString(key)
    // The split matters when a user wrapper's `valueOf` returns
    // a Symbol — stringifyArg alone would throw "cannot convert
    // Symbol to string" instead of using the returned Symbol as
    // the key. Run ToPrimitive first, then dispatch.
    if (heap_mod.valueAsPlainObject(v) != null) {
        const prim = try intrinsics.toPrimitive(realm, v, .string);
        if (heap_mod.valueAsSymbol(prim)) |sym| return sym.prop_key;
        const s = try stringifyArg(realm, prim);
        return s.bytes;
    }
    const s = try stringifyArg(realm, v);
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

/// §9.4.6.8 Module Namespace Exotic [[DefineOwnProperty]] —
/// return `true` only if the new descriptor SameValue-matches the
/// existing exported binding (incl. the `@@toStringTag` slot).
/// Spec steps:
///   1. If Type(P) is Symbol — handled by OrdinaryDefineOwnProperty.
///      For Cynic the `@@toStringTag` flattened-symbol path falls
///      through here too.
///   2. current = O.[[GetOwnProperty]](P). If undefined, return false.
///   3. If Desc.[[Configurable]] present and true, return false.
///   4. If Desc.[[Enumerable]] present and false, return false.
///   5. If Desc is accessor descriptor, return false.
///   6. If Desc.[[Writable]] present and false, return false.
///   7. If Desc.[[Value]] present, return SameValue(Desc.[[Value]],
///      current.[[Value]]).
///   8. Return true.
fn moduleNamespaceDefineOwnProperty(
    target: *@import("../object.zig").JSObject,
    key: []const u8,
    parsed: ParsedDescriptor,
) bool {
    // Symbol-keyed properties: the only ones present on a module
    // namespace are the `@@toStringTag` slot (and any well-known
    // symbol caller may try to add — those land here too). The
    // existing-property check below handles them.
    const had_own = target.properties.contains(key);
    if (!had_own) return false;
    // Accessor descriptor against a data slot → reject.
    if (parsed.isAccessor()) return false;
    const cur_flags = target.flagsFor(key);
    if (parsed.has_configurable and parsed.configurable != cur_flags.configurable) {
        // exported bindings are c:false; toString tag too. Any
        // attempt to set c:true is a reject (cur is false).
        if (parsed.configurable) return false;
    }
    if (parsed.has_enumerable and parsed.enumerable != cur_flags.enumerable) {
        // exported bindings are e:true; toString tag is e:false.
        return false;
    }
    if (parsed.has_writable and parsed.writable != cur_flags.writable) {
        // exported bindings are w:true; toString tag is w:false.
        return false;
    }
    if (parsed.has_value) {
        const cur_value = target.properties.get(key) orelse return false;
        if (!@import("../intrinsics.zig").sameValue(parsed.value, cur_value)) return false;
    }
    return true;
}

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
                    // 6.b. desc must not change value (SameValue —
                    // §7.2.10 distinguishes +0 from -0 and NaN from NaN,
                    // unlike SameValueZero).
                    if (new_desc.has_value and !intrinsics.sameValue(cur_value, new_desc.value)) return false;
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
        if (obj_in.proxy_target != null or obj_in.proxy_revoked) {
            if (obj_in.proxy_revoked) return throwTypeError(realm, "Cannot perform 'defineProperty' on a revoked proxy");
            const proxy_target = obj_in.proxy_target.?;
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
    // §6.2.5.5 ToPropertyDescriptor step 1 — Obj must be an Object.
    // Functions are Objects, so route them through a JSObject
    // wrapper that mirrors the function's own data properties and
    // inherits from `%Function.prototype%` (so descriptor field
    // lookups walk the function's [[Prototype]] chain per spec).
    const desc: *@import("../object.zig").JSObject = blk_desc: {
        if (heap_mod.valueAsPlainObject(desc_v)) |o| break :blk_desc o;
        if (heap_mod.valueAsFunction(desc_v)) |fn_obj| {
            const w = realm.heap.allocateObject() catch return error.OutOfMemory;
            w.prototype = fn_obj.proto;
            var fit = fn_obj.properties.iterator();
            while (fit.next()) |entry| {
                w.set(realm.allocator, entry.key_ptr.*, entry.value_ptr.*) catch return error.OutOfMemory;
            }
            break :blk_desc w;
        }
        return throwTypeError(realm, "Object.defineProperty descriptor is not an object");
    };

    var parsed = try parseDescriptor(realm, desc);

    if (heap_mod.valueAsPlainObject(target_v)) |target| {
        // §9.4.6.8 Module Namespace Exotic [[DefineOwnProperty]] —
        // succeed only if the new descriptor matches the existing
        // one byte-for-byte (per spec: not configurable, not
        // enumerable false, not accessor, not writable false,
        // value SameValue with current). Reject otherwise.
        // Object.defineProperty translates the reject into TypeError;
        // Reflect.defineProperty surfaces the boolean.
        if (target.is_module_namespace) {
            const ns_ok = moduleNamespaceDefineOwnProperty(target, key, parsed);
            if (!ns_ok) {
                realm.define_own_property_rejected = true;
                return throwTypeError(realm, "Cannot redefine property of module namespace");
            }
            return target_v;
        }
        // §10.4.5.3 Integer-Indexed Exotic Object [[DefineOwnProperty]]
        if (target.typed_view != null) {
            const ta = @import("typed_array.zig");
            if (ta.canonicalNumericIndex(key)) |num| {
                const res = try ta.typedArrayDefineOwnProperty(
                    realm,
                    target,
                    num,
                    parsed.has_value,
                    parsed.value,
                    parsed.isAccessor(),
                    parsed.has_configurable,
                    parsed.configurable,
                    parsed.has_enumerable,
                    parsed.enumerable,
                    parsed.has_writable,
                    parsed.writable,
                );
                switch (res) {
                    .applied => return target_v,
                    .reject => { realm.define_own_property_rejected = true; return throwTypeError(realm, "Invalid TypedArray index descriptor"); },
                }
            }
        }
        // §10.4.2.1 Array exotic [[DefineOwnProperty]] — when the
        // receiver is an Array and the key is "length", route the
        // request through §10.4.2.4 ArraySetLength. Per spec:
        // 1. newLen = ? ToUint32(Desc.[[Value]]);
        // 2. numberLen = ? ToNumber(Desc.[[Value]]);
        // 3. If newLen != numberLen, throw RangeError.
        // ToNumber on an Object fires ToPrimitive(value, "number")
        // which calls `valueOf` / `toString` — those can throw, or
        // return a value that fails the SameValueZero check.
        // We then replace parsed.value with the canonical numeric
        // so the descriptor that lands stores the coerced length.
        var array_length_new: ?u32 = null;
        if (target.is_array_exotic and std.mem.eql(u8, key, "length") and parsed.has_value) {
            const arith = @import("../interpreter_arith.zig");
            // §10.4.2.4 ArraySetLength runs ToNumber TWICE on the
            // descriptor value — once via ToUint32 (step 3) and once
            // standalone (step 4) — then SameValueZero-compares the
            // results to reject non-uint32 inputs (NaN, Infinity,
            // fractional, negative, ≥ 2³²). Both observably invoke
            // `valueOf` / `toString` on Object values; user code can
            // (and test262 does) install side-effecting hooks that
            // mutate the descriptor in between (e.g. flipping
            // `length: { writable: false }`), so we MUST call them
            // both — collapsing into one call hides spec-mandated
            // observability.
            const prim1 = try intrinsics.toPrimitive(realm, parsed.value, .number);
            if (heap_mod.valueAsSymbol(prim1) != null) {
                return throwTypeError(realm, "Cannot convert a Symbol value to a number");
            }
            const num1 = arith.toNumber(prim1);
            const prim2 = try intrinsics.toPrimitive(realm, parsed.value, .number);
            if (heap_mod.valueAsSymbol(prim2) != null) {
                return throwTypeError(realm, "Cannot convert a Symbol value to a number");
            }
            const num2 = arith.toNumber(prim2);
            // §7.1.6 ToUint32 short-cuts NaN / ±Infinity / ±0 to 0;
            // the post-step SameValueZero check then catches the
            // mismatch and raises RangeError per §10.4.2.4 step 3.d.
            if (std.math.isNan(num1) or std.math.isInf(num1)) {
                return throwRangeError(realm, "Invalid array length");
            }
            // Spec-faithful ToUint32: trunc toward zero, then mod 2³².
            // We then SameValueZero-compare against `num2` (the
            // second ToNumber). A non-integer or out-of-range
            // `num1` produces a `new_len` that diverges from `num2`
            // and triggers RangeError below.
            if (num1 < 0 or @trunc(num1) != num1 or num1 > @as(f64, @floatFromInt(std.math.maxInt(u32)))) {
                return throwRangeError(realm, "Invalid array length");
            }
            const new_len: u32 = @intFromFloat(num1);
            // §10.4.2.4 step 5 — SameValueZero(newLen, numberLen).
            // After the two ToNumber calls we have all the
            // observable side effects; mismatching numbers (e.g.
            // valueOf returned different values on the two calls)
            // throw RangeError.
            if (@as(f64, @floatFromInt(new_len)) != num2) {
                return throwRangeError(realm, "Invalid array length");
            }
            array_length_new = new_len;
            // 0..2^31-1 fits in the int32 NaN-boxed tag; anything
            // larger (including the §10.4.2.4 step 3.c boundary
            // values 2^32 - 2 and 2^32 - 1) MUST land as a double,
            // otherwise the `@intCast(i32)` traps.
            parsed.value = if (new_len <= std.math.maxInt(i32))
                Value.fromInt32(@intCast(new_len))
            else
                Value.fromDouble(@floatFromInt(new_len));
        }
        // §10.4.2.1 Array exotic [[DefineOwnProperty]] step 4 —
        // when the key is an integer index P and P ≥ length and
        // length is non-writable, return false (→ TypeError under
        // Object.defineProperty). This guards both shrinking
        // (forbidden) and growing (also forbidden) when length
        // has been frozen via
        // `Object.defineProperty(arr, "length", {writable:false})`.
        if (target.is_array_exotic and !std.mem.eql(u8, key, "length")) {
            if (ObjMod.JSObject.canonicalIntegerIndex(key)) |idx| {
                const len_flags = target.flagsFor("length");
                if (!len_flags.writable) {
                    const cur_len: u64 = target.arrayLength();
                    if (@as(u64, idx) >= cur_len) {
                        realm.define_own_property_rejected = true;
                        return throwTypeError(realm, "Cannot define index past the length of a non-writable-length array");
                    }
                }
            }
        }

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

        // Non-configurable redefine guard. §28.1.3 wants
        // Reflect.defineProperty to return `false` here while
        // Object.defineProperty throws — the flag lets the catch
        // in `reflectDefineProperty` translate.
        if (had_own and !isCompatibleRedefine(cur_is_accessor, cur_flags, cur_value, cur_getter, cur_setter, parsed)) {
            realm.define_own_property_rejected = true;
            return throwTypeError(realm, "Object.defineProperty: cannot redefine non-configurable property");
        }

        // §10.1.6.3 ValidateAndApplyPropertyDescriptor step 2:
        // when no current descriptor exists, the object must be
        // [[Extensible]] — otherwise return false (with Throw=true
        // this surfaces as a TypeError). Reflect.defineProperty
        // observes the boolean instead; mark the rejected flag so
        // its catch can translate.
        if (!had_own and !target.extensible) {
            realm.define_own_property_rejected = true;
            return throwTypeError(realm, "Object.defineProperty: object is not extensible");
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
            // §10.4.2.4 ArraySetLength step 16-17 — when the
            // receiver is an Array and the key is "length", a
            // shrink truncates indexed slots ≥ newLen. Walks
            // descending; a non-configurable element stops the
            // walk and sets length to that index + 1, returning
            // false (→ TypeError per §10.4.2.4 step 17.b.ii).
            // `truncateArrayAtLength` folds promoted-into-
            // `properties` indices into the descending walk so a
            // `Object.defineProperty(arr, "<idx>", {configurable:false})`
            // earlier in the script blocks the truncation here.
            // Done AFTER the property update so the length
            // property already reads as `newLen`.
            if (array_length_new) |new_len| {
                const interpreter = @import("../interpreter.zig");
                const trunc = interpreter.truncateArrayAtLength(realm.allocator, target, new_len);
                if (trunc.blocked) {
                    // Restore length to the floor and throw.
                    const restore: Value = if (trunc.final_length <= std.math.maxInt(i32))
                        Value.fromInt32(@intCast(trunc.final_length))
                    else
                        Value.fromDouble(@floatFromInt(trunc.final_length));
                    target.setWithFlags(realm.allocator, key, restore, flags) catch return error.OutOfMemory;
                    return throwTypeError(realm, "Cannot redefine length: non-configurable element prevents truncation");
                }
            }
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
            // §28.1.3 — Reflect.defineProperty returns false for the
            // spec's `[[DefineOwnProperty]]` rejection; Object.
            // defineProperty turns the same rejection into TypeError.
            // Set the flag so Reflect.defineProperty's catch can
            // translate.
            realm.define_own_property_rejected = true;
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
    // §20.1.2.3.1 step 2 — `props = ? ToObject(Properties)`.
    // Boolean / Number / String primitives box into wrappers with
    // no extra enumerable own keys (becomes a no-op iteration).
    // Function objects flow through unchanged (functions are
    // Objects per §17). `null` / `undefined` throw.
    const props_v = argOr(args, 1, Value.undefined_);
    const props: *@import("../object.zig").JSObject = blk_props: {
        if (heap_mod.valueAsPlainObject(props_v)) |o| break :blk_props o;
        if (props_v.isNull() or props_v.isUndefined()) {
            return throwTypeError(realm, "Object.defineProperties properties is not an object");
        }
        // §7.1.18 ToObject for primitives + function objects.
        // Symbols / BigInts box into wrappers with no own enumerable
        // keys; same with Function (its own keys like `length` /
        // `name` are non-enumerable).
        break :blk_props try intrinsics.toObjectThis(realm, props_v);
    };

    // §20.1.2.3.1 ObjectDefineProperties — walk OwnPropertyKeys in
    // spec order (integer-indexed ascending, then string-keyed in
    // insertion order). This includes accessor-backed keys, whose
    // getters must fire per step 5.b.ii.
    const keys = try ownPropertyKeysOrdered(realm, props);
    defer realm.allocator.free(keys);
    for (keys) |key| {
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
    const raw_target = argOr(args, 0, Value.undefined_);
    // §20.1.2.7 step 1 — `Let obj be ? ToObject(O)`. ES2015+
    // primitive-coerces the argument (ES5 threw TypeError for
    // non-object O). String primitives become a String exotic
    // wrapper with own indexed-character and `length` descriptors
    // per §10.4.3, so `Object.getOwnPropertyDescriptor('foo', '0')`
    // returns `{value: 'f', writable: false, enumerable: true,
    // configurable: false}`. Null / undefined still throw via
    // `toObjectThis`.
    const target = if (raw_target.isInt32() or raw_target.isDouble() or raw_target.isString() or raw_target.isBool() or heap_mod.isSymbol(raw_target) or heap_mod.isBigInt(raw_target))
        heap_mod.taggedObject(try intrinsics.toObjectThis(realm, raw_target))
    else
        raw_target;
    // §20.1.2.7 step 2 — `Let key be ? ToPropertyKey(P)`. Runs
    // after ToObject so a poisoned ToPropertyKey side-effect
    // can't fire when the target would already have thrown.
    const key = try descriptorKey(realm, argOr(args, 1, Value.undefined_));

    // §10.5.5 Proxy [[GetOwnProperty]] — when target is a proxy,
    // dispatch through `handler.getOwnPropertyDescriptor`.
    if (heap_mod.valueAsPlainObject(target)) |obj_in| {
        if (obj_in.proxy_target != null or obj_in.proxy_revoked) {
            if (obj_in.proxy_revoked) return throwTypeError(realm, "Cannot perform 'getOwnPropertyDescriptor' on a revoked proxy");
            const proxy_target = obj_in.proxy_target.?;
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
        // §10.4.5.2 Integer-Indexed Exotic Object [[GetOwnProperty]]
        if (obj.typed_view != null) {
            const ta = @import("typed_array.zig");
            if (ta.canonicalNumericIndex(key)) |num| {
                if (ta.typedArrayGetOwnPropertyValue(realm, obj, num)) |v| {
                    const desc = realm.heap.allocateObject() catch return error.OutOfMemory;
                    desc.prototype = realm.intrinsics.object_prototype;
                    desc.set(realm.allocator, "value", v) catch return error.OutOfMemory;
                    desc.set(realm.allocator, "writable", Value.fromBool(true)) catch return error.OutOfMemory;
                    desc.set(realm.allocator, "enumerable", Value.fromBool(true)) catch return error.OutOfMemory;
                    desc.set(realm.allocator, "configurable", Value.fromBool(true)) catch return error.OutOfMemory;
                    return heap_mod.taggedObject(desc);
                }
                return Value.undefined_;
            }
        }
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
    const raw = argOr(args, 0, Value.undefined_);
    // §20.1.2.8 step 1 — `Let obj be ? ToObject(O)`. ES2015+
    // primitive-coerces the arg (string primitives become a
    // String exotic wrapper with indexed-character descriptors
    // per §10.4.3). Mirrors `getOwnPropertyDescriptor`.
    const target = if (raw.isInt32() or raw.isDouble() or raw.isString() or raw.isBool() or heap_mod.isSymbol(raw) or heap_mod.isBigInt(raw))
        heap_mod.taggedObject(try intrinsics.toObjectThis(realm, raw))
    else
        raw;
    const obj = heap_mod.valueAsPlainObject(target) orelse return throwTypeError(realm, "Object.getOwnPropertyDescriptors target is not an object");
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
    const raw = argOr(args, 0, Value.undefined_);
    // §20.1.2.10 step 1 — `Let obj be ? ToObject(O)`. ES2015+
    // primitive-coerces the arg.
    const target = if (raw.isInt32() or raw.isDouble() or raw.isString() or raw.isBool())
        heap_mod.taggedObject(try intrinsics.toObjectThis(realm, raw))
    else
        raw;
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
    // §20.1.2.11 step 2 — `keys be ? O.[[OwnPropertyKeys]]()`. For
    // a Proxy receiver this MUST go through the `ownKeys` trap so
    // the invariants (target keys + reported keys must agree on
    // configurable+non-extensible) fire before we filter to
    // symbols. Mirrors `objectGetOwnPropertyNames` line 381.
    const keys = if (try proxyOwnKeysOrNull(realm, obj)) |k| k else try ownPropertyKeysOrdered(realm, obj);
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
        // §20.1.2.2 Object.create step 3 → ObjectDefineProperties:
        // walk OwnPropertyKeys in spec order; include accessor-backed
        // own keys so step 5.b.ii getters fire.
        const keys = try ownPropertyKeysOrdered(realm, props);
        defer realm.allocator.free(keys);
        for (keys) |key| {
            if (!props.flagsFor(key).enumerable) continue;
            const k_str = realm.heap.allocateString(key) catch return error.OutOfMemory;
            const desc_v = try getPropertyChain(realm, props, key);
            const inner = [_]Value{ heap_mod.taggedObject(obj), Value.fromString(k_str), desc_v };
            _ = try objectDefineProperty(realm, Value.undefined_, &inner);
        }
    }
    return heap_mod.taggedObject(obj);
}

/// §20.1.2.1 step 3.b — `Set(to, nextKey, propValue, true)`. The
/// `true` Throw argument means a failed [[Set]] surfaces as
/// TypeError, not a silent drop. Per §10.1.9.2
/// OrdinarySetWithOwnDescriptor:
///   • An own accessor (own or inherited) routes through its
///     setter; a getter-only accessor returns false → TypeError.
///   • An own data property with `writable: false` returns false
///     → TypeError ("assignment to read-only property").
///   • No own descriptor + receiver is non-extensible →
///     CreateDataProperty fails → TypeError.
///   • Otherwise write succeeds.
/// Keeps the `key` slice anchored on the target via `setComputedOwned`
/// so the JSString backing the property name survives GC.
fn assignSetOrThrow(
    realm: *Realm,
    target: *JSObject,
    key_string: *JSString,
    value: Value,
) NativeError!void {
    const interpreter = @import("../interpreter.zig");
    const allocator = realm.allocator;
    const key = key_string.bytes;
    // §10.1.9.2 — accessor descriptor on the receiver or its
    // proto chain wins. A getter-only accessor (no `set`) is a
    // TypeError under strict-mode Set.
    if (interpreter.lookupAccessor(target, key)) |acc| {
        if (acc.setter) |setter| {
            const setter_args = [_]Value{value};
            const outcome = interpreter.callJSFunction(allocator, realm, setter, heap_mod.taggedObject(target), &setter_args) catch |err| switch (err) {
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
        return throwTypeError(realm, "Cannot set property which has only a getter");
    }
    const had_entry = target.properties.contains(key);
    const had_indexed = blk_idx: {
        if (target.is_array_exotic) {
            if (JSObject.canonicalIntegerIndex(key)) |idx| break :blk_idx target.hasOwnIndexedSlot(idx);
        }
        break :blk_idx false;
    };
    if (had_entry) {
        // §10.1.9.2 step 3.a — non-writable own data → TypeError
        // under strict Set.
        const flags = target.flagsFor(key);
        if (!flags.writable) {
            return throwTypeError(realm, "Cannot assign to read-only property");
        }
        target.properties.put(allocator, key, value) catch return error.OutOfMemory;
        return;
    }
    if (!had_indexed and !target.extensible) {
        // §10.1.9.2 step 2.b / §10.1.6.3 ValidateAndApplyPropertyDescriptor —
        // creating a new property on a non-extensible receiver
        // fails; strict-mode Set surfaces that as TypeError.
        return throwTypeError(realm, "Cannot add property, object is not extensible");
    }
    target.setComputedOwned(allocator, key_string, value) catch return error.OutOfMemory;
}

fn objectAssign(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = this_value;
    // §20.1.2.1 step 1 — `target = ? ToObject(target)`. Primitives
    // (numbers, strings, booleans) box into wrappers; undefined /
    // null throw. The wrapper itself is what gets returned.
    const target_v = argOr(args, 0, Value.undefined_);
    const target = try intrinsics.toObjectThis(realm, target_v);
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const src_v = args[i];
        // Step 5.a — `if nextSource is undefined or null, skip`. All
        // other primitives (and Functions) ToObject and contribute
        // their enumerable own keys.
        if (src_v.isUndefined() or src_v.isNull()) continue;
        const src = heap_mod.valueAsPlainObject(src_v) orelse blk_src: {
            // String wrappers expose indexed character own properties
            // (e.g. `"1a2c3"` → "0":"1","1":"a",…). Functions /
            // Number / Boolean ToObject into wrappers with no
            // enumerable own keys, which is the spec-correct no-op.
            const o = intrinsics.toObjectThis(realm, src_v) catch continue;
            break :blk_src o;
        };
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
            // §20.1.2.1 step 5.c.iv.2.b — `Set(to, nextKey, propValue, true)`.
            // Strict-mode Set per §10.1.9 throws TypeError on any
            // failure (non-extensible + new key, non-writable own
            // data, getter-only accessor, setter throw).
            const key_string = realm.heap.allocateString(key) catch return error.OutOfMemory;
            try assignSetOrThrow(realm, target, key_string, v);
        }
    }
    return heap_mod.taggedObject(target);
}

/// §7.3.20 SetIntegrityLevel(O, level) driven through the public
/// [[X]] methods so a Proxy receiver observes every operation
/// (`preventExtensions`, `ownKeys`, `getOwnPropertyDescriptor`,
/// `defineProperty`) via its handler traps. The fast inline path
/// in `objectFreeze` / `objectSeal` bypasses this entirely for
/// plain objects — only Proxies pay the dispatch cost.
fn setIntegrityLevelViaProxy(realm: *Realm, target_v: Value, target: *JSObject, frozen: bool) NativeError!Value {
    // §7.3.20 step 2 — `status = ? O.[[PreventExtensions]]()`.
    const status = try proxyPreventExtensionsBool(realm, target);
    if (!status) {
        // §20.1.2.5 / §20.1.2.20 — SetIntegrityLevel returning false
        // from the wrapped operation surfaces as TypeError on the
        // public Object.{freeze,seal} call.
        return throwTypeError(realm, if (frozen) "Object.freeze: Proxy preventExtensions returned false" else "Object.seal: Proxy preventExtensions returned false");
    }
    // §7.3.20 step 4 — `keys = ? O.[[OwnPropertyKeys]]()`.
    const keys = (try proxyOwnKeysOrNull(realm, target)) orelse try ownPropertyKeysOrdered(realm, target);
    defer realm.allocator.free(keys);

    for (keys) |key| {
        // Build the descriptor we want to install. For sealed: just
        // configurable=false. For frozen: configurable=false +
        // writable=false on data properties; configurable=false
        // alone on accessors (writable is N/A there).
        var is_accessor: bool = false;
        if (frozen) {
            // §7.3.20 step 6.b — `currentDesc = ? O.[[GetOwnProperty]](k)`.
            // The Proxy trap dispatch lives inside `objectGetOwnPropertyDescriptor`.
            const key_str = realm.heap.allocateString(key) catch return error.OutOfMemory;
            const cd_args = [_]Value{ target_v, Value.fromString(key_str) };
            const cur_desc_v = try objectGetOwnPropertyDescriptor(realm, Value.undefined_, &cd_args);
            // §7.3.20 step 6.b.i — only act if currentDesc is not undefined.
            if (cur_desc_v.isUndefined()) continue;
            const cur_desc = heap_mod.valueAsPlainObject(cur_desc_v) orelse continue;
            // Accessor descriptor iff `get` or `set` are set.
            is_accessor = cur_desc.hasOwn("get") or cur_desc.hasOwn("set");
        }
        const desc_obj = realm.heap.allocateObject() catch return error.OutOfMemory;
        desc_obj.prototype = realm.intrinsics.object_prototype;
        desc_obj.set(realm.allocator, "configurable", Value.false_) catch return error.OutOfMemory;
        if (frozen and !is_accessor) {
            desc_obj.set(realm.allocator, "writable", Value.false_) catch return error.OutOfMemory;
        }
        // §7.3.20 step 6.b.iv — DefinePropertyOrThrow. Routed through
        // the Proxy's `defineProperty` trap inside `objectDefineProperty`.
        const key_str = realm.heap.allocateString(key) catch return error.OutOfMemory;
        const dp_args = [_]Value{ target_v, Value.fromString(key_str), heap_mod.taggedObject(desc_obj) };
        _ = try objectDefineProperty(realm, Value.undefined_, &dp_args);
    }
    return target_v;
}

/// §7.3.21 TestIntegrityLevel(O, level) driven through the public
/// [[IsExtensible]] / [[OwnPropertyKeys]] / [[GetOwnProperty]]
/// methods so a Proxy receiver observes every operation via its
/// handler traps. Plain-object callers use the inline fast path
/// in `objectIsFrozen` / `objectIsSealed`.
fn testIntegrityLevelViaProxy(realm: *Realm, target_v: Value, target: *JSObject, frozen: bool) NativeError!Value {
    _ = target;
    // §7.3.21 step 2 — `extensible = ? O.[[IsExtensible]]()`.
    const ext_args = [_]Value{target_v};
    const ext_v = try objectIsExtensible(realm, Value.undefined_, &ext_args);
    if (intrinsics.toBoolean(ext_v)) return Value.false_;
    // §7.3.21 step 4 — `keys = ? O.[[OwnPropertyKeys]]()`. Read
    // through the trap so the invariants fire.
    const target_obj = heap_mod.valueAsPlainObject(target_v) orelse return Value.true_;
    const keys = (try proxyOwnKeysOrNull(realm, target_obj)) orelse try ownPropertyKeysOrdered(realm, target_obj);
    defer realm.allocator.free(keys);
    for (keys) |key| {
        const key_str = realm.heap.allocateString(key) catch return error.OutOfMemory;
        const cd_args = [_]Value{ target_v, Value.fromString(key_str) };
        const cur_desc_v = try objectGetOwnPropertyDescriptor(realm, Value.undefined_, &cd_args);
        // §7.3.21 step 5.a — only inspect when currentDesc is not undefined.
        if (cur_desc_v.isUndefined()) continue;
        const cur_desc = heap_mod.valueAsPlainObject(cur_desc_v) orelse continue;
        // Configurable must be false. For frozen data descriptors,
        // writable must also be false. Accessor descriptors (`get` /
        // `set` set) skip the writable check — §7.3.21 step 5.a.ii.
        const cfg_v = cur_desc.get("configurable");
        if (intrinsics.toBoolean(cfg_v)) return Value.false_;
        if (frozen) {
            const is_accessor = cur_desc.hasOwn("get") or cur_desc.hasOwn("set");
            if (!is_accessor) {
                const w_v = cur_desc.get("writable");
                if (intrinsics.toBoolean(w_v)) return Value.false_;
            }
        }
    }
    return Value.true_;
}

fn objectFreeze(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = this_value;
    const arg = argOr(args, 0, Value.undefined_);
    const obj = heap_mod.valueAsPlainObject(arg) orelse return arg; // §20.1.2.5 — primitives pass through
    // §10.5 Proxy receivers — every integrity-level effect MUST be
    // observable through the handler traps. Drive SetIntegrityLevel
    // via the public [[X]] methods instead of mutating the proxy's
    // own slots directly.
    if (obj.proxy_target != null or obj.proxy_revoked) {
        return setIntegrityLevelViaProxy(realm, arg, obj, true);
    }
    // §10.4.5.4 IntegerIndexedExoticObject [[PreventExtensions]] —
    // returns false when IsTypedArrayFixedLength(O) is false, which
    // covers every length-tracking view AND every fixed-length
    // view whose backing ArrayBuffer is resizable (§25.1.4.4 chains
    // through IsFixedLengthArrayBuffer). SetIntegrityLevel(O,
    // frozen) then throws TypeError. Only TAs backed by genuinely
    // fixed-length ArrayBuffers can be frozen.
    if (obj.typed_view) |tv| {
        if (tv.viewed.array_buffer_max_byte_length != null) {
            return throwTypeError(realm, "Cannot freeze TypedArray backed by resizable buffer");
        }
    }
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
    _ = this_value;
    const arg = argOr(args, 0, Value.undefined_);
    // Function objects are Objects too (§10.2) — they have own
    // properties (`name`, `length`, `prototype`, user-set) and are
    // extensible by default. Cynic doesn't yet plumb an
    // `extensible` flag through `JSFunction`, so a freshly-built
    // built-in is never frozen. Return false so
    // `Object.isFrozen(TypeError)` doesn't lie. The one exception
    // is `%ThrowTypeError%` (§10.2.4) which the spec mandates is
    // frozen — we hard-code that singleton match here.
    if (heap_mod.valueAsFunction(arg)) |fn_obj| {
        if (realm.intrinsics.throw_type_error) |tt| {
            if (fn_obj == tt) return Value.true_;
        }
        return Value.false_;
    }
    const obj = heap_mod.valueAsPlainObject(arg) orelse return Value.true_; // primitives are frozen
    if (obj.proxy_target != null or obj.proxy_revoked) {
        return testIntegrityLevelViaProxy(realm, arg, obj, true);
    }
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
    if (obj.proxy_target != null or obj.proxy_revoked) {
        return setIntegrityLevelViaProxy(realm, arg, obj, false);
    }
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
    _ = this_value;
    const arg = argOr(args, 0, Value.undefined_);
    // Same Function-as-Object carve-out as `objectIsFrozen` — a
    // built-in / user-declared function is extensible and has
    // mutable own properties. `%ThrowTypeError%` is the one
    // pre-sealed singleton.
    if (heap_mod.valueAsFunction(arg)) |fn_obj| {
        if (realm.intrinsics.throw_type_error) |tt| {
            if (fn_obj == tt) return Value.true_;
        }
        return Value.false_;
    }
    const obj = heap_mod.valueAsPlainObject(arg) orelse return Value.true_;
    if (obj.proxy_target != null or obj.proxy_revoked) {
        return testIntegrityLevelViaProxy(realm, arg, obj, false);
    }
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

/// §10.5.4 Proxy [[PreventExtensions]] — shared bool helper.
/// Returns the boolean status (`Reflect.preventExtensions` surfaces
/// it directly; `Object.preventExtensions` throws on `false`).
pub fn proxyPreventExtensionsBool(realm: *Realm, obj: *JSObject) NativeError!bool {
    if (obj.proxy_revoked) return throwTypeError(realm, "Cannot perform 'preventExtensions' on a revoked proxy");
    const proxy_target = obj.proxy_target.?;
    const handler = obj.proxy_handler orelse return throwTypeError(realm, "Cannot perform 'preventExtensions' on a proxy with null handler");
    const trap_v = handler.get("preventExtensions");
    if (trap_v.isUndefined() or trap_v.isNull()) {
        // Trap absent — forward to target.[[PreventExtensions]].
        if (proxy_target.proxy_target != null or proxy_target.proxy_revoked) {
            return try proxyPreventExtensionsBool(realm, proxy_target);
        }
        proxy_target.extensible = false;
        return true;
    }
    const trap_fn = heap_mod.valueAsFunction(trap_v) orelse return throwTypeError(realm, "Proxy 'preventExtensions' trap is not callable");
    const interpreter = @import("../interpreter.zig");
    const trap_args = [_]Value{heap_mod.taggedObject(proxy_target)};
    const outcome = interpreter.callJSFunction(realm.allocator, realm, trap_fn, heap_mod.taggedObject(handler), &trap_args) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.NativeThrew,
    };
    const truthy = switch (outcome) {
        .value, .yielded => |v| intrinsics.toBoolean(v),
        .thrown => |ex| {
            realm.pending_exception = ex;
            return error.NativeThrew;
        },
    };
    if (!truthy) return false;
    // §10.5.4 step 8 — invariant: trap reported success ⇒ target
    // must be non-extensible. Use `IsExtensible` rather than the
    // raw flag so a nested proxy target dispatches correctly.
    const ext_args = [_]Value{heap_mod.taggedObject(proxy_target)};
    const ext_v = try objectIsExtensible(realm, Value.undefined_, &ext_args);
    if (intrinsics.toBoolean(ext_v)) {
        return throwTypeError(realm, "'preventExtensions' on proxy reported success but target is still extensible");
    }
    return true;
}

pub fn objectPreventExtensions(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = this_value;
    const arg = argOr(args, 0, Value.undefined_);
    if (heap_mod.valueAsPlainObject(arg)) |obj| {
        if (obj.proxy_target != null or obj.proxy_revoked) {
            const ok = try proxyPreventExtensionsBool(realm, obj);
            if (!ok) return throwTypeError(realm, "'preventExtensions' on proxy returned falsy");
            return arg;
        }
        obj.extensible = false;
    } else if (heap_mod.valueAsFunction(arg)) |fn_obj| {
        // §6.1.7 — function objects are ordinary objects, so
        // preventExtensions applies. Needed for the
        // `nonextensible-applies-to-private` (ES2022) static-private
        // case: `Object.preventExtensions(Ctor)` followed by
        // `static #x = …` must trip §7.3.32 PrivateFieldAdd step 1.
        fn_obj.extensible = false;
    }
    return arg;
}

pub fn objectIsExtensible(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = this_value;
    const arg = argOr(args, 0, Value.undefined_);
    // §20.1.2.16 — when the receiver is not an Object, return
    // `false`. Functions ARE objects (§6.1.7) — return their
    // `extensible` slot (default `true`, flipped by
    // `Object.preventExtensions(fn)`).
    if (heap_mod.valueAsFunction(arg)) |fn_obj| return if (fn_obj.extensible) Value.true_ else Value.false_;
    const obj = heap_mod.valueAsPlainObject(arg) orelse return Value.false_;
    // §10.5.3 Proxy [[IsExtensible]] — trap dispatch with the
    // invariant that the result must match the target's actual
    // extensibility.
    if (obj.proxy_target != null or obj.proxy_revoked) {
        if (obj.proxy_revoked) return throwTypeError(realm, "Cannot perform 'isExtensible' on a revoked proxy");
        const proxy_target = obj.proxy_target.?;
        const handler = obj.proxy_handler orelse return throwTypeError(realm, "Cannot perform 'isExtensible' on a proxy with null handler");
        const trap_v = handler.get("isExtensible");
        // §10.5.3 step 5 — GetMethod: non-callable non-nullish → TypeError.
        if (!trap_v.isUndefined() and !trap_v.isNull()) {
            const trap_fn = heap_mod.valueAsFunction(trap_v) orelse return throwTypeError(realm, "Proxy 'isExtensible' trap is not callable");
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
            const s = try stringifyArg(realm, k);
            break :blk s.bytes;
        };
        out.set(realm.allocator, key_str, v) catch return error.OutOfMemory;
    }
    return heap_mod.taggedObject(out);
}

/// §10.5.2 Proxy [[SetPrototypeOf]] (V) — shared helper used by
/// `Object.setPrototypeOf` (translates `false` → TypeError) and
/// `Reflect.setPrototypeOf` (returns the boolean). Returns the
/// boolean status. Throws TypeError on revoked / null handler /
/// non-callable trap / non-extensible invariant violation.
pub fn proxySetPrototypeOfBool(realm: *Realm, obj: *JSObject, proto_v: Value) NativeError!bool {
    if (obj.proxy_revoked) return throwTypeError(realm, "Cannot perform 'setPrototypeOf' on a revoked proxy");
    const proxy_target = obj.proxy_target.?;
    const handler = obj.proxy_handler orelse return throwTypeError(realm, "Cannot perform 'setPrototypeOf' on a proxy with null handler");
    const trap_v = handler.get("setPrototypeOf");
    // §10.5.2 step 6 — GetMethod: undefined/null falls through.
    if (trap_v.isUndefined() or trap_v.isNull()) {
        // Recurse on the target as if [[SetPrototypeOf]] called directly.
        if (proxy_target.proxy_target != null or proxy_target.proxy_revoked) {
            return try proxySetPrototypeOfBool(realm, proxy_target, proto_v);
        }
        const inner_args = [_]Value{ heap_mod.taggedObject(proxy_target), proto_v };
        _ = try objectSetPrototypeOf(realm, Value.undefined_, &inner_args);
        // objectSetPrototypeOf returns target_v on success; throws on
        // failure (cycle / immutable proto).
        return true;
    }
    const trap_fn = heap_mod.valueAsFunction(trap_v) orelse return throwTypeError(realm, "Proxy 'setPrototypeOf' trap is not callable");
    const interpreter = @import("../interpreter.zig");
    const trap_args = [_]Value{ heap_mod.taggedObject(proxy_target), proto_v };
    const outcome = interpreter.callJSFunction(realm.allocator, realm, trap_fn, heap_mod.taggedObject(handler), &trap_args) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.NativeThrew,
    };
    const boolean_result = switch (outcome) {
        .value, .yielded => |v| intrinsics.toBoolean(v),
        .thrown => |ex| {
            realm.pending_exception = ex;
            return error.NativeThrew;
        },
    };
    if (!boolean_result) return false;
    // §10.5.2 step 11-15 — `extensibleTarget = ? IsExtensible(target)`.
    // The target may itself be a proxy, in which case its isExtensible
    // trap fires (and ordering is observable).
    const ext_args = [_]Value{heap_mod.taggedObject(proxy_target)};
    const ext_v = try objectIsExtensible(realm, Value.undefined_, &ext_args);
    if (!intrinsics.toBoolean(ext_v)) {
        // Non-extensible target — the new prototype must SameValue
        // target.[[GetPrototypeOf]]().
        const target_proto_args = [_]Value{heap_mod.taggedObject(proxy_target)};
        const target_proto = try objectGetPrototypeOf(realm, Value.undefined_, &target_proto_args);
        if (!intrinsics.sameValue(proto_v, target_proto)) {
            return throwTypeError(realm, "'setPrototypeOf' on proxy reported success but the new prototype differs from the target's prototype on a non-extensible target");
        }
    }
    return true;
}

pub fn objectSetPrototypeOf(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = this_value;
    const target_v = argOr(args, 0, Value.undefined_);
    const proto_v = argOr(args, 1, Value.undefined_);
    // §20.1.2.20 step 1 — proto arg must be Object or Null.
    if (!proto_v.isNull() and heap_mod.valueAsPlainObject(proto_v) == null and heap_mod.valueAsFunction(proto_v) == null) {
        return throwTypeError(realm, "prototype must be an Object or null");
    }
    if (heap_mod.valueAsPlainObject(target_v)) |obj| {
        // §10.5.2 Proxy [[SetPrototypeOf]] — trap dispatch.
        if (obj.proxy_target != null or obj.proxy_revoked) {
            const ok = try proxySetPrototypeOfBool(realm, obj, proto_v);
            if (!ok) return throwTypeError(realm, "'setPrototypeOf' on proxy returned falsy");
            return target_v;
        }
        // §10.1.2.1 OrdinarySetPrototypeOf step 8 — if proto is
        // already in obj's chain (or *is* obj), accepting would
        // create a cycle and every subsequent chain walk would
        // spin. Spec says return false, which Object.setPrototypeOf
        // turns into TypeError.
        const new_proto: ?*@import("../object.zig").JSObject = blk: {
            if (proto_v.isNull()) break :blk null;
            if (heap_mod.valueAsPlainObject(proto_v)) |p| break :blk p;
            if (heap_mod.valueAsFunction(proto_v)) |fn_obj| break :blk fn_obj.prototype;
            break :blk null;
        };
        // §10.4.7 — `%Object.prototype%` is an Immutable Prototype
        // Exotic Object: [[SetPrototypeOf]] only succeeds if the
        // new value SameValue's the current one. Object.setPrototypeOf
        // then translates the `false` return into TypeError.
        if (obj == realm.intrinsics.object_prototype.?) {
            if (new_proto != obj.prototype) {
                return throwTypeError(realm, "Immutable prototype object cannot have its prototype set");
            }
            return target_v;
        }
        // §10.1.2.1 OrdinarySetPrototypeOf step 3 — when
        // `extensible` is false the new prototype MUST SameValue
        // the current one; otherwise return false and let
        // Object.setPrototypeOf rethrow. Module Namespace exotics
        // are always non-extensible with `prototype === null`,
        // so any non-null target is rejected.
        if (!obj.extensible) {
            if (new_proto != obj.prototype) {
                return throwTypeError(realm, "Cannot set prototype on non-extensible object");
            }
            return target_v;
        }
        var cursor: ?*@import("../object.zig").JSObject = new_proto;
        while (cursor) |node| {
            if (node == obj) {
                return throwTypeError(realm, "cyclic __proto__ value");
            }
            cursor = node.prototype;
        }
        obj.prototype = new_proto;
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
            const s = try stringifyArg(realm, key_v);
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
    // §20.1.3.2 step 1 — `ToPropertyKey(V)` runs BEFORE `ToObject(this)`,
    // so a coercion throw from the argument propagates even when the
    // receiver is null/undefined. Use `try` instead of swallowing as
    // OutOfMemory.
    const key = try descriptorKey(realm, argOr(args, 0, Value.undefined_));
    // §20.1.3.2 step 2 — `ToObject(this)` throws on null / undefined.
    if (this_value.isNull() or this_value.isUndefined()) {
        return throwTypeError(realm, "Object.prototype.hasOwnProperty called on null or undefined");
    }
    if (heap_mod.valueAsPlainObject(this_value)) |obj| {
        return Value.fromBool(obj.hasOwn(key));
    }
    if (heap_mod.valueAsFunction(this_value)) |fn_obj| {
        return Value.fromBool(fn_obj.hasOwn(key));
    }
    // Primitives (string, number, etc.) ToObject-coerce; the spec
    // result is "did the boxed wrapper have key as own?". For
    // string primitives we still consult the indexed view.
    if (this_value.isString()) {
        const s: *@import("../string.zig").JSString = @ptrCast(@alignCast(this_value.asString()));
        // Numeric indices that fall within the string look like own.
        if (std.mem.eql(u8, key, "length")) return Value.true_;
        const i = std.fmt.parseInt(usize, key, 10) catch return Value.false_;
        return Value.fromBool(i < s.bytes.len);
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
pub fn objectProtoToString(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = args;
    if (this_value.isUndefined()) {
        const s = realm.heap.allocateString("[object Undefined]") catch return error.OutOfMemory;
        return Value.fromString(s);
    }
    if (this_value.isNull()) {
        const s = realm.heap.allocateString("[object Null]") catch return error.OutOfMemory;
        return Value.fromString(s);
    }

    // Step 4 — built-in default tag. Per §20.1.3.6 the spec
    // ToObject's `this value` first, then picks the tag from
    // the wrapper's internal slot. Cynic short-circuits the
    // wrapping for String / Number / Boolean primitives (their
    // wrappers carry [[StringData]] / [[NumberData]] /
    // [[BooleanData]] — so the slot wins step 4 and short-
    // circuiting is observably equivalent for the default case).
    // Symbol and BigInt primitives are different: their wrappers
    // have NO listed internal slot, so step 4 produces "Object"
    // and the final tag is determined by step 5's @@toStringTag
    // walk on Symbol.prototype / BigInt.prototype. User code that
    // deletes the @@toStringTag must see "[object Object]" — short-
    // circuiting them here breaks that observability.
    const builtin_tag: []const u8 = blk: {
        if (heap_mod.isFunction(this_value)) break :blk "Function";
        if (this_value.isString()) break :blk "String";
        if (this_value.isNumber()) break :blk "Number";
        if (this_value.isBool()) break :blk "Boolean";
        if (heap_mod.valueAsPlainObject(this_value)) |obj| {
            // §22.1.3.6 step 4 — pick the built-in tag from the
            // internal slot present on the receiver. Order
            // matters per the spec table.
            if (obj.is_array_exotic) break :blk "Array";
            if (obj.prototype != null and obj.prototype == realm.intrinsics.array_prototype) break :blk "Array";
            // §10.4.4 / §22.1.3.6 step 4 "Arguments" case.
            if (obj.is_arguments_exotic) break :blk "Arguments";
            if (obj.regex_bytecode != null) break :blk "RegExp";
            if (obj.array_buffer != null) break :blk "Object"; // ArrayBuffer uses @@toStringTag
            if (obj.boxed_primitive) |bp| {
                if (bp.isBool()) break :blk "Boolean";
                if (bp.isInt32() or bp.isDouble()) break :blk "Number";
            }
            if (obj.boxed_string != null) break :blk "String";
            // §20.5.3 / §22.1.3.6 — objects with the [[ErrorData]]
            // internal slot tag as "Error". The `<X>Error.prototype`
            // objects intentionally don't have this slot (per
            // `built-ins/NativeErrors/<X>/prototype/not-error-object.js`)
            // so the bare prototype falls through to "Object".
            if (obj.has_error_data) break :blk "Error";
            // Date / arguments: rely on @@toStringTag walked in
            // step 5 below. Default falls through.
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
    // §20.1.3.6 step 3 + step 14 — primitive receivers `ToObject`
    // to their wrapper whose [[Prototype]] is the matching
    // constructor's `.prototype`. Symbol / BigInt wrappers have no
    // dedicated builtinTag slot, so the spec's "[object Symbol]" /
    // "[object BigInt]" rendering comes from `@@toStringTag` on
    // Symbol.prototype / BigInt.prototype. Mirror that here so a
    // user-side `delete Symbol.prototype[Symbol.toStringTag]` is
    // observable as "[object Object]". Reach the prototype via
    // the global constructor since `realm.intrinsics` doesn't
    // pin Symbol / BigInt protos directly.
    const proto_for_primitive: ?*JSObject = blk: {
        if (heap_mod.valueAsSymbol(this_value)) |_| {
            const ctor_v = realm.globals.get("Symbol") orelse break :blk null;
            const ctor = heap_mod.valueAsFunction(ctor_v) orelse break :blk null;
            break :blk ctor.prototype;
        }
        if (heap_mod.valueAsBigInt(this_value)) |_| {
            const ctor_v = realm.globals.get("BigInt") orelse break :blk null;
            const ctor = heap_mod.valueAsFunction(ctor_v) orelse break :blk null;
            break :blk ctor.prototype;
        }
        break :blk null;
    };
    if (proto_for_primitive) |proto| {
        const v = proto.get("@@toStringTag");
        if (v.isString()) return v;
    }
    return null;
}

fn objectProtoValueOf(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = realm;
    _ = args;
    return this_value;
}

