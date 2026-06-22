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
    // §20.1.1.1 step 1 — `If NewTarget is neither undefined nor the
    // active function (Object), return ? OrdinaryCreateFromConstructor(
    // NewTarget, "%Object.prototype%")`. In Cynic, a subclass
    // `class O extends Object { … }; new O(v)` arrives with
    // `this_value` pre-allocated against `O.prototype` (not
    // `%Object.prototype%`) — that pre-allocated instance IS the
    // §10.1.14-derived object the spec asks for. Return it instead
    // of falling through to step 3's box-the-arg path (which would
    // discard the subclass identity). The interpreter's construct
    // path already builds `this_value` via `getPrototypeFromConstructor`.
    //
    // The native callback can't observe NewTarget directly (the
    // non-deferred construct path doesn't stash it on the realm),
    // so the discriminator is structural: fire only when `this_value`
    // is an Object-derived instance *of this realm* — its
    // [[Prototype]] chain must reach this realm's %Object.prototype%
    // (every `extends Object` subclass does, since `O.prototype`'s
    // proto is %Object.prototype%). A plain *method* call such as
    // `other.Object(v)` passes the member base as `this_value` — e.g.
    // another realm's `globalThis`, whose chain bottoms out at the
    // *other* realm's %Object.prototype%, never this one's. The
    // earlier `proto != %Object.prototype%` check alone mistook that
    // foreign receiver for a subclass `this` and returned it verbatim,
    // so `other.Object(0n)` yielded the child global instead of a
    // BigInt wrapper and the parent `BigInt.prototype.valueOf` brand
    // check threw (built-ins/BigInt/prototype/valueOf/cross-realm.js).
    if (realm.intrinsics.object_prototype) |obj_proto| {
        if (heap_mod.valueAsPlainObject(this_value)) |this_obj| {
            if (this_obj.prototype != null and this_obj.prototype != obj_proto) {
                var cursor: ?*JSObject = this_obj.prototype;
                while (cursor) |c| : (cursor = c.prototype) {
                    if (c == obj_proto) return this_value;
                }
            }
        }
    }
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
        // §7.1.18 ToObject runs in the current Realm Record — the
        // realm of the running Object native, not the realm whose
        // dispatch loop invoked it. `parentRealm.eval("other.Object(
        // other.BigInt(100n))")` must mint the wrapper from the
        // OTHER realm's %BigInt.prototype% so a `toJSON` installed
        // there is on the wrapper's chain.
        const run_realm = realm.active_native_fn_realm orelse realm;
        const w = try intrinsics.toObjectThis(run_realm, arg);
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
    const run_realm = realm.active_native_fn_realm orelse realm;
    const obj = run_realm.heap.allocateObject() catch return error.OutOfMemory;
    run_realm.heap.setObjectPrototype(obj, run_realm.intrinsics.object_prototype);
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
        // §20.1.3.5 — Object.prototype.toLocaleString( reserved1,
        // reserved2 ). The two reserved params are vestigial host
        // hooks for Intl and don't count toward `.length`, so arity
        // is 0. Per spec the entire body is `Return ? Invoke(O,
        // "toString")` — dispatch back through the receiver's
        // `toString` so subclasses overriding `toString` also
        // override `toLocaleString`.
        try installNativeMethodOnProto(realm, obj_proto, "toLocaleString", objectProtoToLocaleString, 0);
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
    // §6.1.7 — an "array index" is a string whose canonical
    // numeric value is in the inclusive range [+0, 2^32 - 2].
    // 2^32 - 1 ("4294967295") is reserved as the array-length
    // upper bound and is NOT an index — it round-trips as a
    // named property, not a slot in the integer-key partition.
    if (s.len == 0) return null;
    if (s.len > 10) return null; // u32 max is 10 digits
    if (s[0] == '0' and s.len > 1) return null; // no leading zero
    var n: u64 = 0;
    for (s) |c| {
        if (c < '0' or c > '9') return null;
        n = n * 10 + (c - '0');
        if (n > 0xFFFFFFFE) return null;
    }
    return @intCast(n);
}

/// Linear scan of `obj.own_key_order` — used by the
/// `ownPropertyKeysOrdered` fallback walks to dedupe entries
/// that were already emitted via the unified order list. The
/// list is bounded by the object's own-key count; a hash set
/// would win only on pathologically large objects, and Cynic
/// doesn't currently profile any.
fn orderListContains(obj: *const JSObject, key: []const u8) bool {
    return obj.ownKeyOrderContains(key);
}

/// §10.1.11 OrdinaryOwnPropertyKeys ordering. Returns own
/// property keys in spec order: integer-indexed in ascending
/// numeric order, then string keys in unified-insertion order
/// (data + accessor merged), then (eventually) symbol keys.
/// Skips internal `__cynic_*` slots. Caller owns the returned
/// slice (allocated via `realm.allocator`).
/// Walk `obj`'s own keys in §10.1.11 spec order. The returned
/// slice is `realm.allocator`-owned (free it); the *string-key*
/// entries borrow bytes from `obj`'s own property maps (stable
/// while `obj` is reachable). Integer-index keys are synthesised
/// fresh — the JSStrings backing them are pushed onto `key_scope`
/// so they survive the caller's (possibly re-entrant) use of the
/// list. `key_scope` must stay open for as long as the caller
/// reads the returned slice.
pub fn ownPropertyKeysOrdered(
    realm: *Realm,
    obj: *JSObject,
    key_scope: *@import("../heap.zig").HandleScope,
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
                // Root the synthesised index key on the caller's
                // scope so it survives a GC sweep while the caller
                // iterates the returned key list (which re-enters JS).
                key_scope.push(Value.fromString(owned)) catch return error.OutOfMemory;
                integer_keys.append(realm.allocator, .{ .idx = idx, .key = owned.flatBytes() }) catch return error.OutOfMemory;
            }
        } else {
            var ei: u32 = 0;
            while (ei < obj.elements.items.len) : (ei += 1) {
                if (JSObject.isElementHole(obj.elements.items[ei])) continue;
                var ibuf: [16]u8 = undefined;
                const ks = std.fmt.bufPrint(&ibuf, "{d}", .{ei}) catch continue;
                const owned = realm.heap.allocateString(ks) catch return error.OutOfMemory;
                key_scope.push(Value.fromString(owned)) catch return error.OutOfMemory;
                integer_keys.append(realm.allocator, .{ .idx = ei, .key = owned.flatBytes() }) catch return error.OutOfMemory;
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
    if (obj.getTypedView()) |tv| {
        const live_len: u32 = blk: {
            const buf = tv.viewed.getArrayBuffer() orelse break :blk 0;
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
            key_scope.push(Value.fromString(owned)) catch return error.OutOfMemory;
            integer_keys.append(realm.allocator, .{ .idx = ti, .key = owned.flatBytes() }) catch return error.OutOfMemory;
        }
    }
    // §10.1.11 OrdinaryOwnPropertyKeys — the spec walks String
    // keys in ascending chronological order of property creation,
    // which is *unified* across data and accessor descriptors:
    // installing `a` as accessor, then `b` as data, then
    // redefining `a` keeps the slot in chronological order
    // `[a, b]`. `own_key_order` carries that unified list for
    // every key inserted through the user-visible
    // `recordKey` paths (object literal data/accessor, `[[Set]]`,
    // `Object.defineProperty`). Walk it first so the order is
    // authoritative; then sweep `properties` / `accessors` for
    // any leftover keys not in the list (built-in proto
    // installation that bypasses the helpers — those keys exist
    // in the maps but were never recorded). The map iteration
    // order is itself insertion-ordered, so the leftover sweep
    // is deterministic.
    //
    // §23.1.4 — an array exotic's `length` is a VIRTUAL own
    // property (synthesized, never in `own_key_order` or the bag).
    // It is created at array birth, before any user-added string
    // key, so it sorts first among the string keys (§10.1.11.1
    // chronological order). Static slice — no allocation, no
    // rooting.
    if (obj.is_array_exotic) {
        string_keys.append(realm.allocator, "length") catch return error.OutOfMemory;
    }
    var key_iter = obj.ownKeyOrderIterator();
    while (key_iter.next()) |k| {
        if (std.mem.startsWith(u8, k, "__cynic_")) continue;
        // The order list refuses integer-index keys at recordKey
        // time, so they never appear here. The guards stay
        // defensive in case a future code path adds one.
        if (obj.getTypedView() != null) {
            if (canonicalIntegerIndex(k)) |_| continue;
        }
        if (canonicalIntegerIndex(k)) |i| {
            integer_keys.append(realm.allocator, .{ .idx = i, .key = k }) catch return error.OutOfMemory;
            continue;
        }
        // Confirm the key is still live (not deleted) — the
        // delete paths call `forgetKey` so this is normally
        // redundant, but a missed delete site would surface as
        // a phantom key here. Trust the maps as the source of
        // truth for liveness.
        if (!obj.ownDataContains(k) and !obj.hasAccessor(k)) continue;
        string_keys.append(realm.allocator, k) catch return error.OutOfMemory;
    }
    // Fallback: pick up any `properties` keys not already in the
    // order list (built-in installation paths that don't call
    // `recordKey`). The map's own insertion order applies here.
    var it = obj.iterOwnNamedKeys();
    while (it.next()) |entry| {
        const k = entry.key_ptr.*;
        if (std.mem.startsWith(u8, k, "__cynic_")) continue;
        if (obj.getTypedView() != null) {
            if (canonicalIntegerIndex(k)) |_| continue;
        }
        // Already counted above?
        if (orderListContains(obj, k)) continue;
        if (canonicalIntegerIndex(k)) |i| {
            integer_keys.append(realm.allocator, .{ .idx = i, .key = k }) catch return error.OutOfMemory;
        } else {
            string_keys.append(realm.allocator, k) catch return error.OutOfMemory;
        }
    }
    // Same fallback for `accessors`.
    if (obj.accessorIterator()) |ait_outer| {
        var ait = ait_outer;
        while (ait.next()) |entry| {
            const k = entry.key_ptr.*;
            if (std.mem.startsWith(u8, k, "__cynic_")) continue;
            if (obj.ownDataContains(k)) continue; // already counted
            if (obj.getTypedView() != null) {
                if (canonicalIntegerIndex(k)) |_| continue;
            }
            if (orderListContains(obj, k)) continue;
            if (canonicalIntegerIndex(k)) |i| {
                integer_keys.append(realm.allocator, .{ .idx = i, .key = k }) catch return error.OutOfMemory;
            } else {
                string_keys.append(realm.allocator, k) catch return error.OutOfMemory;
            }
        }
    }
    // §15.2.1.18 GetModuleNamespace step 3.c — re-export redirect
    // keys (`namespace_redirects[K]`) are part of the namespace's
    // [[Exports]] internal slot and appear in
    // [[OwnPropertyKeys]]. Ambiguous keys are filtered out (per
    // step 3.c.ii — they're dropped from the exported names).
    if (obj.is_module_namespace) {
        if (obj.namespaceRedirectIterator()) |rit_outer| {
            var rit = rit_outer;
            while (rit.next()) |entry| {
                const k = entry.key_ptr.*;
                if (obj.ownDataContains(k)) continue;
                if (obj.hasAccessor(k)) continue;
                if (obj.hasAmbiguousNamespaceKey(k)) continue;
                if (canonicalIntegerIndex(k)) |i| {
                    integer_keys.append(realm.allocator, .{ .idx = i, .key = k }) catch return error.OutOfMemory;
                } else {
                    string_keys.append(realm.allocator, k) catch return error.OutOfMemory;
                }
            }
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

/// §7.3.2 Get(handler, P) for proxy-trap fetches. When `handler`
/// is itself a Proxy, dispatch through `nativeProxyGet` so the
/// outer handler's `get` trap fires (test262
/// built-ins/Object/keys/property-traps-order-with-proxied-array.js
/// uses `new Proxy(target, new Proxy({}, {get(t, pk) {…}}))`).
/// Otherwise fall through to `getPropertyChain`, which walks the
/// prototype chain and invokes accessor getters — so a handler
/// that defines `ownKeys` as a getter (test262
/// built-ins/Object/keys/proxy-keys.js) is observed.
pub fn getHandlerProperty(realm: *Realm, handler: *JSObject, key: []const u8) NativeError!Value {
    if (handler.proxy_target != null or handler.proxy_revoked) {
        const proxy_mod = @import("proxy.zig");
        var cur = handler;
        while (true) {
            const outcome = try proxy_mod.nativeProxyGet(realm, cur, key, heap_mod.taggedObject(handler), null);
            switch (outcome) {
                .value => |v| return v,
                .fallthrough => |t| {
                    if (t == cur) return Value.undefined_;
                    if (t.proxy_target != null or t.proxy_revoked) {
                        cur = t;
                        continue;
                    }
                    return getPropertyChain(realm, t, key);
                },
            }
        }
    }
    return getPropertyChain(realm, handler, key);
}

/// §10.5.5 [[Get]] on a possibly-Proxy receiver. When `obj` is a
/// Proxy, dispatch through `nativeProxyGet` (and walk a Proxy of
/// Proxy chain), so the user-installed `get` trap observes the
/// read — §7.3.2 Get is the spec's per-key fetch in
/// EnumerableOwnProperties (§7.3.21) and friends, and a Proxy
/// receiver must see each `get`. Otherwise fall through to
/// `getPropertyChain` which fires accessor getters along the
/// prototype chain.
///
/// The `receiver` parameter is the original Value the caller is
/// reading from — for a Proxy, the spec calls the trap with
/// `Receiver` = the outermost proxy, so this function threads
/// that through (test262 Object/{values,entries,
/// getOwnPropertyDescriptors}/observable-operations.js verify the
/// trap was called with `proxy === receiver`).
pub fn getPropertyValue(realm: *Realm, obj: *JSObject, key: []const u8, receiver: Value) NativeError!Value {
    if (obj.proxy_target != null or obj.proxy_revoked) {
        const proxy_mod = @import("proxy.zig");
        var cur = obj;
        while (true) {
            const outcome = try proxy_mod.nativeProxyGet(realm, cur, key, receiver, null);
            switch (outcome) {
                .value => |v| return v,
                .fallthrough => |t| {
                    if (t == cur) return Value.undefined_;
                    if (t.proxy_target != null or t.proxy_revoked) {
                        cur = t;
                        continue;
                    }
                    return getPropertyChain(realm, t, key);
                },
            }
        }
    }
    return getPropertyChain(realm, obj, key);
}

/// §10.5.11 Proxy [[OwnPropertyKeys]] — when `obj` is a proxy
/// with an `ownKeys` handler trap, call it and convert the
/// returned Array into a `[]const []const u8` slice. The caller
/// owns the slice and frees it via `realm.allocator`. Returns
/// `null` when no trap fires; the caller falls back to walking
/// the target's own keys directly.
pub fn proxyOwnKeysOrNull(
    realm: *Realm,
    obj: *JSObject,
    key_scope: *@import("../heap.zig").HandleScope,
) NativeError!?[]const []const u8 {
    if (obj.proxy_target == null and !obj.proxy_revoked) return null;
    // §10.5.11 step 2 — revoked proxy throws TypeError.
    if (obj.proxy_revoked) return throwTypeError(realm, "Cannot perform 'ownKeys' on a revoked proxy");
    const proxy_target = obj.proxy_target.?;
    const handler = obj.proxy_handler orelse return throwTypeError(realm, "Cannot perform 'ownKeys' on a proxy with null handler");
    // §10.5.11 step 5 — `Let trap be ? GetMethod(handler, "ownKeys")`.
    // §7.3.11 GetMethod chains through §7.3.10 Get which fires
    // accessor getters AND nested-Proxy handler `get` traps.
    // `getHandlerProperty` walks the proxy chain when the handler
    // is itself a Proxy, then falls through to `getPropertyChain`
    // (which fires accessor getters) on the inner plain object.
    // Without this, a fixture like
    // `new Proxy([], new Proxy({}, {get(t, pk) { log.push(pk) }}))`
    // reads `handler.get("ownKeys")` directly and the inner trap
    // never logs (test262 built-ins/Object/keys/proxy-keys.js,
    // /property-traps-order-with-proxied-array.js).
    const trap_v = try getHandlerProperty(realm, handler, "ownKeys");
    // §10.5.11 step 5 — trap is `undefined` / `null` → fall back
    // to target.[[OwnPropertyKeys]]. When the target is itself a
    // Proxy, recurse so the inner trap fires (proxy-of-proxy
    // chain — value-object-proxy nested). Anything else
    // non-callable is a TypeError per IsCallable.
    if (trap_v.isUndefined() or trap_v.isNull()) {
        if (proxy_target.proxy_target != null or proxy_target.proxy_revoked) {
            return try proxyOwnKeysOrNull(realm, proxy_target, key_scope);
        }
        return try ownPropertyKeysOrdered(realm, proxy_target, key_scope);
    }
    const trap_fn = heap_mod.valueAsFunction(trap_v) orelse return throwTypeError(realm, "Proxy 'ownKeys' trap is not callable");
    const lantern = @import("../lantern/interpreter.zig");
    const trap_args = [_]Value{heap_mod.taggedObject(proxy_target)};
    const outcome = lantern.callJSFunction(realm.allocator, realm, trap_fn, heap_mod.taggedObject(handler), &trap_args) catch |err| switch (err) {
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
    // §7.3.18 CreateListFromArrayLike step 4 — `Let len be ?
    // LengthOfArrayLike(obj)`, which is §7.3.19 ToLength(Get(obj,
    // "length")). Use `toLengthOf` (which calls `getPropertyChain`
    // and then ToLength) so a `length` accessor on the trap result
    // is observed (test262 built-ins/Object/keys/proxy-keys.js
    // defines `get length() { log.push(...) }`).
    const len = try intrinsics.toLengthOf(realm, result);
    var out: std.ArrayListUnmanaged([]const u8) = .empty;
    // `out`'s backing buffer is freed on every error path via this
    // `errdefer`; the success path calls `toOwnedSlice` below which
    // transfers ownership and zeroes the list, so the deferred deinit
    // is a no-op.
    errdefer out.deinit(realm.allocator);
    var seen: std.StringArrayHashMapUnmanaged(void) = .empty;
    defer seen.deinit(realm.allocator);
    var i: i64 = 0;
    while (i < len) : (i += 1) {
        var ibuf: [24]u8 = undefined;
        const islice = std.fmt.bufPrint(&ibuf, "{d}", .{i}) catch unreachable;
        // §7.3.18 step 6.b — `Let next be ? Get(obj, ! ToString(F(index)))`.
        // Accessor getters on the index keys must fire — the test262
        // fixture above also defines `get 0() { … }` etc.
        const k_v = try getPropertyChain(realm, result, islice);
        // §10.5.11 step 8 — CreateListFromArrayLike rejects any
        // entry that isn't a String or Symbol. Numbers / booleans /
        // null / undefined → TypeError.
        const key_str = if (k_v.isString()) blk: {
            // The key string lives in the trap-result array, which
            // is unrooted once this function returns. Root it on the
            // caller's scope so the returned slice survives the
            // caller's (re-entrant) iteration.
            const ks: *JSString = @ptrCast(@alignCast(k_v.asString()));
            key_scope.push(Value.fromString(ks)) catch return error.OutOfMemory;
            break :blk ks.flatBytes();
        } else if (heap_mod.valueAsSymbol(k_v)) |sym|
            // Cynic flattens symbol property keys into the
            // sym.prop_key string (`@@<wellknown>` / `<sym:N>`).
            // The caller (Reflect.ownKeys / getOwnPropertySymbols)
            // re-resolves a JSSymbol from that key via
            // `heap.symbolForKey`, so the round-trip is lossless.
            sym.prop_key
        else
            return throwTypeError(realm, "'ownKeys' on proxy returned a non-String, non-Symbol entry");
        // §10.5.11 step 9 — duplicate keys → TypeError.
        const entry = seen.getOrPut(realm.allocator, key_str) catch return error.OutOfMemory;
        if (entry.found_existing) return throwTypeError(realm, "'ownKeys' on proxy returned duplicate entries");
        out.append(realm.allocator, key_str) catch return error.OutOfMemory;
    }
    // §10.5.11 — trap-result invariants.
    //
    // Step 17 (always applies, regardless of extensibility): every
    // non-configurable own key of the target must appear in the
    // trap's result. Drop one and the proxy is lying about what's
    // permanently there.
    //
    // Steps 19-21 (non-extensible target only): the trap result
    // must list every target own key AND nothing else. A
    // non-extensible target's key set is frozen, so the proxy
    // can't add or remove from it.
    const target_keys = try ownPropertyKeysOrdered(realm, proxy_target, key_scope);
    defer realm.allocator.free(target_keys);
    for (target_keys) |tk| {
        if (!proxy_target.flagsFor(tk).configurable) {
            if (!seen.contains(tk)) {
                return throwTypeError(realm, "'ownKeys' on proxy omitted a non-configurable target key");
            }
        }
    }
    if (!proxy_target.extensible) {
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
        realm.heap.setObjectPrototype(result, realm.intrinsics.array_prototype);
        result.markAsArrayExotic(realm.allocator) catch return error.OutOfMemory;
        // Root the result array — it is built across a loop whose
        // `allocateString` calls can trigger a GC sweep.
        const fscope = realm.heap.openScope() catch return error.OutOfMemory;
        defer fscope.close();
        fscope.push(heap_mod.taggedObject(result)) catch return error.OutOfMemory;
        var idx: usize = 0;
        var fit = fn_obj.properties.iterator();
        while (fit.next()) |entry| {
            const key = entry.key_ptr.*;
            if (std.mem.startsWith(u8, key, "__cynic_")) continue;
            if (isSymbolKey(key)) continue;
            if (!fn_obj.flagsForOwn(key).enumerable) continue;
            var ibuf: [16]u8 = undefined;
            const islice = std.fmt.bufPrint(&ibuf, "{d}", .{idx}) catch unreachable;
            const idx_owned = realm.heap.allocateString(islice) catch return error.OutOfMemory;
            // Allocate the value string last so no GC-triggering
            // allocation runs between it and the store.
            const key_owned = realm.heap.allocateString(key) catch return error.OutOfMemory;
            result.set(realm.allocator, idx_owned.flatBytes(), Value.fromString(key_owned)) catch return error.OutOfMemory;
            idx += 1;
        }
        result.set(realm.allocator, "length", Value.fromInt32(@intCast(idx))) catch return error.OutOfMemory;
        return heap_mod.taggedObject(result);
    }
    const obj = heap_mod.valueAsPlainObject(arg) orelse return throwTypeError(realm, "Object.keys called on non-object");
    const key_scope = realm.heap.openScope() catch return error.OutOfMemory;
    defer key_scope.close();
    const keys = if (try proxyOwnKeysOrNull(realm, obj, key_scope)) |k| k else try ownPropertyKeysOrdered(realm, obj, key_scope);
    defer realm.allocator.free(keys);
    const result = realm.heap.allocateObject() catch return error.OutOfMemory;
    realm.heap.setObjectPrototype(result, realm.intrinsics.array_prototype);
    result.markAsArrayExotic(realm.allocator) catch return error.OutOfMemory;
    // Root the source and the result array — the loop below re-enters
    // JS through the proxy `getOwnPropertyDescriptor` trap, and each
    // `allocateString` is a GC safepoint.
    const scope = realm.heap.openScope() catch return error.OutOfMemory;
    defer scope.close();
    scope.push(arg) catch return error.OutOfMemory;
    scope.push(heap_mod.taggedObject(result)) catch return error.OutOfMemory;
    var idx: usize = 0;
    const is_proxy = obj.proxy_target != null or obj.proxy_revoked;
    for (keys) |key| {
        // §7.3.21 EnumerableOwnProperties step 4.a.i calls
        // O.[[GetOwnProperty]](key) to read the descriptor — on a
        // module namespace, that invokes [[Get]] (§9.4.6.7) which
        // throws ReferenceError on a TDZ-Hole-seeded binding. Run
        // the throw probe before the enumerable check so the spec
        // ordering matches (descriptor fetch ⇒ enumerable read).
        if (obj.is_module_namespace and !std.mem.startsWith(u8, key, "@@") and !std.mem.startsWith(u8, key, "<sym:")) {
            _ = try @import("../module.zig").namespaceGetThrowingOnHole(realm, obj, key);
        }
        // §20.1.2.18 / §7.3.21 — `kind = "key"` filters to string
        // keys (Symbol keys live in `Object.getOwnPropertySymbols`).
        // Cynic flattens symbols into `@@<name>` / `<sym:N>`; filter
        // both forms so neither leaks into `Object.keys`.
        if (isSymbolKey(key)) continue;
        // §7.3.21 step 4.a.i — `Let desc be ? O.[[GetOwnProperty]](key)`.
        // For a Proxy this fires the `getOwnPropertyDescriptor`
        // trap and runs the §10.5.5 invariant checks. The trap
        // may override the enumerable bit relative to the target's
        // own descriptor (test262 built-ins/Object/keys/proxy-keys.js),
        // and it may legitimately report `false` for a non-
        // enumerable target prop the trap chose to surface
        // (test262 …/proxy-non-enumerable-prop-invariant-3.js). For
        // a plain object we keep the direct flag read — it's the
        // ordinary [[GetOwnProperty]] result.
        const enumerable = if (is_proxy) blk: {
            const key_str = realm.heap.allocateString(key) catch return error.OutOfMemory;
            const desc_args = [_]Value{ heap_mod.taggedObject(obj), Value.fromString(key_str) };
            const desc_v = try objectGetOwnPropertyDescriptor(realm, Value.undefined_, &desc_args);
            // step 4.a.ii — desc undefined → skip key (proxy reported
            // it absent).
            if (desc_v.isUndefined()) continue;
            const desc_obj = heap_mod.valueAsPlainObject(desc_v) orelse continue;
            const enum_v = desc_obj.get("enumerable");
            break :blk enum_v.isBool() and enum_v.asBool();
        } else obj.flagsFor(key).enumerable;
        if (!enumerable) continue;
        var ibuf: [16]u8 = undefined;
        const islice = std.fmt.bufPrint(&ibuf, "{d}", .{idx}) catch unreachable;
        const owned = realm.heap.allocateString(islice) catch return error.OutOfMemory;
        // Allocate the value string last so no GC-triggering
        // allocation runs between it and the store into `result`.
        const key_str = realm.heap.allocateString(key) catch return error.OutOfMemory;
        result.set(realm.allocator, owned.flatBytes(), Value.fromString(key_str)) catch return error.OutOfMemory;
        idx += 1;
    }
    result.set(realm.allocator, "length", Value.fromInt32(@intCast(idx))) catch return error.OutOfMemory;
    return heap_mod.taggedObject(result);
}

fn enumerableOwnPropertyHelperToObject(realm: *Realm, raw: Value, name: []const u8) NativeError!Value {
    // §7.1.18 ToObject — covers primitives including Symbol /
    // BigInt (§19.4 / §21.2). Without the wider check Object.values
    // on a Symbol primitive falls through to the non-object error
    // path instead of returning `[]` (test262
    // built-ins/Object/values/primitive-symbols.js).
    if (raw.isInt32() or raw.isDouble() or raw.isString() or raw.isBool() or
        heap_mod.isSymbol(raw) or heap_mod.isBigInt(raw))
    {
        return heap_mod.taggedObject(try intrinsics.toObjectThis(realm, raw));
    }
    if (raw.isNull() or raw.isUndefined()) {
        return throwTypeError(realm, name);
    }
    return raw;
}

/// §7.3.21 EnumerableOwnPropertyNames(O, kind). Walks the
/// receiver's own keys in spec order, fires
/// `[[GetOwnProperty]]` per key (so a Proxy
/// `getOwnPropertyDescriptor` trap and any data-accessor lookup
/// run), filters to enumerable string keys, and invokes
/// `[[Get]]` only for keys that pass the descriptor filter.
///
/// Caller owns the returned slice (allocated via
/// `realm.allocator`). Each entry's `key_str` is a heap-allocated
/// JSString. `value` is the result of `[[Get]]` on the source key.
pub const KeyValuePair = struct {
    key_str: *JSString,
    value: Value,
};

pub fn enumerableOwnPropertyKeyValues(
    realm: *Realm,
    obj: *JSObject,
    scope: *@import("../heap.zig").HandleScope,
) NativeError![]KeyValuePair {
    // §7.3.21 step 2 — `Let ownKeys be ? O.[[OwnPropertyKeys]]()`.
    // Route through `proxyOwnKeysOrNull` so a Proxy's `ownKeys`
    // trap fires when present.
    const key_scope = realm.heap.openScope() catch return error.OutOfMemory;
    defer key_scope.close();
    const keys = if (try proxyOwnKeysOrNull(realm, obj, key_scope)) |k| k else try ownPropertyKeysOrdered(realm, obj, key_scope);
    defer realm.allocator.free(keys);

    var out: std.ArrayListUnmanaged(KeyValuePair) = .empty;
    errdefer out.deinit(realm.allocator);

    for (keys) |key| {
        // §7.3.21 step 3.a.i — String keys only. Symbols (Cynic
        // flattens to `@@<name>` / `<sym:N>`) are routed via
        // `Object.getOwnPropertySymbols` and never appear here.
        if (isSymbolKey(key)) continue;

        // §7.3.21 step 3.a.ii — `Let desc be ? O.[[GetOwnProperty]](key)`.
        // For a Proxy, `objectGetOwnPropertyDescriptor` fires the
        // `getOwnPropertyDescriptor` trap. For a plain object, the
        // call reads the live descriptor — so a getter that
        // deletes a future key, or flips a future key to non-
        // enumerable, is visible on this iteration (test262
        // built-ins/Object/values/getter-removing-future-key.js,
        // /getter-making-future-key-nonenumerable.js).
        const key_v = blk: {
            const s = realm.heap.allocateString(key) catch return error.OutOfMemory;
            break :blk Value.fromString(s);
        };
        // Root the key string before `objectGetOwnPropertyDescriptor`
        // re-enters JS — a GC there would otherwise free it.
        scope.push(key_v) catch return error.OutOfMemory;
        const desc_args = [_]Value{ heap_mod.taggedObject(obj), key_v };
        const desc_v = try objectGetOwnPropertyDescriptor(realm, Value.undefined_, &desc_args);
        // step 3.a.iii — desc undefined → skip (key disappeared
        // since `[[OwnPropertyKeys]]` snapshotted them).
        if (desc_v.isUndefined()) continue;
        const desc_obj = heap_mod.valueAsPlainObject(desc_v) orelse continue;
        // step 3.a.iv — `If desc.[[Enumerable]] is true`. Read the
        // `enumerable` field of the descriptor object the proxy /
        // intrinsic returned, not the live flag map — the trap may
        // have overridden it.
        const enum_v = desc_obj.get("enumerable");
        if (!enum_v.isBool() or !enum_v.asBool()) continue;
        // step 3.a.v — `Let value be ? Get(O, key)`. Re-read via
        // the spec-correct accessor chain so a Proxy `get` trap or
        // an inherited getter fires. For a Proxy receiver, route
        // through `getPropertyValue` so the user-installed `get`
        // trap observes the read (test262
        // built-ins/Object/values/observable-operations.js,
        // /entries/observable-operations.js).
        const value = try getPropertyValue(realm, obj, key, heap_mod.taggedObject(obj));
        const key_str = @as(*JSString, @ptrCast(@alignCast(key_v.asString())));
        // The pairs accumulate in a non-GC list across a loop that
        // re-enters JS (the GOPD trap, `getPropertyValue`); root each
        // key string and value on the caller-supplied scope so a mid-
        // loop sweep can't collect already-gathered entries.
        scope.push(Value.fromString(key_str)) catch return error.OutOfMemory;
        scope.push(value) catch return error.OutOfMemory;
        out.append(realm.allocator, .{ .key_str = key_str, .value = value }) catch return error.OutOfMemory;
    }

    return out.toOwnedSlice(realm.allocator) catch return error.OutOfMemory;
}

/// Shared §17 walk for `Object.values` / `Object.entries` over a
/// function object. JSFunction's property bag carries the
/// installed `length` / `name` (and any user `fn.x = …` writes);
/// emit each enumerable own data key per spec ordering, then
/// build the result Array.
const FunctionEnumKind = enum { value, entry };

fn functionEnumerableOwnValues(
    realm: *Realm,
    fn_obj: *@import("../function.zig").JSFunction,
    kind: FunctionEnumKind,
) NativeError!Value {
    const result = realm.heap.allocateObject() catch return error.OutOfMemory;
    realm.heap.setObjectPrototype(result, realm.intrinsics.array_prototype);
    result.markAsArrayExotic(realm.allocator) catch return error.OutOfMemory;
    // Root the result array — it is built across `allocateString`
    // GC safepoints.
    const scope = realm.heap.openScope() catch return error.OutOfMemory;
    defer scope.close();
    scope.push(heap_mod.taggedObject(result)) catch return error.OutOfMemory;
    var idx: usize = 0;
    var fit = fn_obj.properties.iterator();
    while (fit.next()) |entry| {
        const key = entry.key_ptr.*;
        if (std.mem.startsWith(u8, key, "__cynic_")) continue;
        if (isSymbolKey(key)) continue;
        if (!fn_obj.flagsForOwn(key).enumerable) continue;
        const value = entry.value_ptr.*;
        var ibuf: [16]u8 = undefined;
        const islice = std.fmt.bufPrint(&ibuf, "{d}", .{idx}) catch unreachable;
        const idx_owned = realm.heap.allocateString(islice) catch return error.OutOfMemory;
        switch (kind) {
            .value => {
                result.set(realm.allocator, idx_owned.flatBytes(), value) catch return error.OutOfMemory;
            },
            .entry => {
                const pair = realm.heap.allocateObject() catch return error.OutOfMemory;
                realm.heap.setObjectPrototype(pair, realm.intrinsics.array_prototype);
                pair.markAsArrayExotic(realm.allocator) catch return error.OutOfMemory;
                scope.push(heap_mod.taggedObject(pair)) catch return error.OutOfMemory;
                const key_owned = realm.heap.allocateString(key) catch return error.OutOfMemory;
                pair.set(realm.allocator, "0", Value.fromString(key_owned)) catch return error.OutOfMemory;
                pair.set(realm.allocator, "1", value) catch return error.OutOfMemory;
                pair.set(realm.allocator, "length", Value.fromInt32(2)) catch return error.OutOfMemory;
                result.set(realm.allocator, idx_owned.flatBytes(), heap_mod.taggedObject(pair)) catch return error.OutOfMemory;
            },
        }
        idx += 1;
    }
    result.set(realm.allocator, "length", Value.fromInt32(@intCast(idx))) catch return error.OutOfMemory;
    return heap_mod.taggedObject(result);
}

fn objectValues(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = this_value;
    const raw = argOr(args, 0, Value.undefined_);
    // §20.1.2.21 step 1 — `Let obj be ? ToObject(O)`.
    const coerced = try enumerableOwnPropertyHelperToObject(realm, raw, "Object.values called on null or undefined");
    // §17 — Function objects are also ordinary objects; walk their
    // enumerable own data properties directly (the JSFunction heap
    // struct isn't a JSObject so `enumerableOwnPropertyKeyValues`
    // can't accept it).
    if (heap_mod.valueAsFunction(coerced)) |fn_obj| {
        return functionEnumerableOwnValues(realm, fn_obj, .value);
    }
    const obj = heap_mod.valueAsPlainObject(coerced) orelse return throwTypeError(realm, "Object.values called on non-object");
    // Root the source, the gathered pairs and the result array
    // across the re-entrant enumeration (GOPD traps / getters).
    const scope = realm.heap.openScope() catch return error.OutOfMemory;
    defer scope.close();
    scope.push(coerced) catch return error.OutOfMemory;
    // §20.1.2.21 step 2 — `Let nameList be ?
    // EnumerableOwnPropertyNames(obj, value)`.
    const pairs = try enumerableOwnPropertyKeyValues(realm, obj, scope);
    defer realm.allocator.free(pairs);
    // step 3 — `Return CreateArrayFromList(nameList)`.
    const result = realm.heap.allocateObject() catch return error.OutOfMemory;
    realm.heap.setObjectPrototype(result, realm.intrinsics.array_prototype);
    result.markAsArrayExotic(realm.allocator) catch return error.OutOfMemory;
    scope.push(heap_mod.taggedObject(result)) catch return error.OutOfMemory;
    var idx: usize = 0;
    for (pairs) |p| {
        var ibuf: [16]u8 = undefined;
        const islice = std.fmt.bufPrint(&ibuf, "{d}", .{idx}) catch unreachable;
        const owned = realm.heap.allocateString(islice) catch return error.OutOfMemory;
        result.set(realm.allocator, owned.flatBytes(), p.value) catch return error.OutOfMemory;
        idx += 1;
    }
    result.set(realm.allocator, "length", Value.fromInt32(@intCast(idx))) catch return error.OutOfMemory;
    return heap_mod.taggedObject(result);
}

fn objectEntries(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = this_value;
    const raw = argOr(args, 0, Value.undefined_);
    // §20.1.2.5 step 1 — `Let obj be ? ToObject(O)`.
    const coerced = try enumerableOwnPropertyHelperToObject(realm, raw, "Object.entries called on null or undefined");
    // §17 — Function objects participate in `Object.entries` too;
    // walk the function bag directly because JSFunction isn't a
    // JSObject (test262
    // built-ins/Object/entries/order-after-define-property-with-function.js).
    if (heap_mod.valueAsFunction(coerced)) |fn_obj| {
        return functionEnumerableOwnValues(realm, fn_obj, .entry);
    }
    const obj = heap_mod.valueAsPlainObject(coerced) orelse return throwTypeError(realm, "Object.entries called on non-object");
    // Root the source, gathered pairs and the result array across
    // the re-entrant enumeration (GOPD traps / getters).
    const scope = realm.heap.openScope() catch return error.OutOfMemory;
    defer scope.close();
    scope.push(coerced) catch return error.OutOfMemory;
    // step 2 — `Let nameList be ?
    // EnumerableOwnPropertyNames(obj, key+value)`.
    const pairs = try enumerableOwnPropertyKeyValues(realm, obj, scope);
    defer realm.allocator.free(pairs);
    // step 3 — `Return CreateArrayFromList(nameList)`.
    const result = realm.heap.allocateObject() catch return error.OutOfMemory;
    realm.heap.setObjectPrototype(result, realm.intrinsics.array_prototype);
    result.markAsArrayExotic(realm.allocator) catch return error.OutOfMemory;
    scope.push(heap_mod.taggedObject(result)) catch return error.OutOfMemory;
    var idx: usize = 0;
    for (pairs) |p| {
        const pair = realm.heap.allocateObject() catch return error.OutOfMemory;
        realm.heap.setObjectPrototype(pair, realm.intrinsics.array_prototype);
        pair.markAsArrayExotic(realm.allocator) catch return error.OutOfMemory;
        scope.push(heap_mod.taggedObject(pair)) catch return error.OutOfMemory;
        pair.set(realm.allocator, "0", Value.fromString(p.key_str)) catch return error.OutOfMemory;
        pair.set(realm.allocator, "1", p.value) catch return error.OutOfMemory;
        pair.set(realm.allocator, "length", Value.fromInt32(2)) catch return error.OutOfMemory;
        var ibuf: [16]u8 = undefined;
        const islice = std.fmt.bufPrint(&ibuf, "{d}", .{idx}) catch unreachable;
        const owned = realm.heap.allocateString(islice) catch return error.OutOfMemory;
        result.set(realm.allocator, owned.flatBytes(), heap_mod.taggedObject(pair)) catch return error.OutOfMemory;
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
    // matching `<Type>.prototype`. Without this,
    // `Object.getPrototypeOf(0)` throws instead of returning
    // `Number.prototype`, and `Object.getPrototypeOf(Symbol())`
    // misses `Symbol.prototype` (built-ins/Symbol/constructor.js).
    const arg = if (raw.isInt32() or raw.isDouble() or raw.isString() or raw.isBool() or heap_mod.isSymbol(raw) or heap_mod.isBigInt(raw)) blk: {
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
                const lantern = @import("../lantern/interpreter.zig");
                const trap_args = [_]Value{heap_mod.taggedObject(proxy_target)};
                const outcome = lantern.callJSFunction(realm.allocator, realm, trap_fn, heap_mod.taggedObject(handler), &trap_args) catch |err| switch (err) {
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
        if (obj.prototype_fn) |pf| return heap_mod.taggedFunction(pf);
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
    // §20.1.2.13 Object.hasOwn ( O, P )
    //   1. Let obj be ? ToObject(O).  Functions, primitives, and
    //      Proxies all coerce; only null/undefined throw TypeError.
    //   2. Let key be ? ToPropertyKey(P).
    //   3. Return ? HasOwnProperty(obj, key).
    const o = argOr(args, 0, Value.undefined_);
    if (o.isNull() or o.isUndefined()) {
        return throwTypeError(realm, "Object.hasOwn called on null or undefined");
    }
    // §7.1.19 ToPropertyKey — surfaces user-side ToPrimitive throws.
    const key = (try descriptorKey(realm, argOr(args, 1, Value.undefined_))).key;
    if (heap_mod.valueAsPlainObject(o)) |obj| {
        // §9.4.6 module namespace [[GetOwnProperty]] materialises a
        // binding via [[Get]]; a TDZ-Hole export rethrows ReferenceError.
        if (obj.is_module_namespace and obj.hasOwn(key) and !std.mem.startsWith(u8, key, "@@") and !std.mem.startsWith(u8, key, "<sym:")) {
            _ = try @import("../module.zig").namespaceGetThrowingOnHole(realm, obj, key);
        }
        // §7.3.13 HasOwnProperty composes [[GetOwnProperty]]; for a
        // Proxy that fires the `getOwnPropertyDescriptor` trap
        // (§10.5.5). Reuse Object.getOwnPropertyDescriptor which
        // walks the proxy chain and enforces target invariants.
        if (obj.proxy_target != null or obj.proxy_revoked) {
            const probe_args = [_]Value{ o, argOr(args, 1, Value.undefined_) };
            const desc_v = try objectGetOwnPropertyDescriptor(realm, Value.undefined_, &probe_args);
            return Value.fromBool(!desc_v.isUndefined());
        }
        return Value.fromBool(obj.hasOwn(key));
    }
    if (heap_mod.valueAsFunction(o)) |fn_obj| {
        return Value.fromBool(fn_obj.hasOwn(key));
    }
    // §7.1.18 ToObject for string primitives boxes to String wrapper.
    if (o.isString()) {
        const s: *@import("../string.zig").JSString = @ptrCast(@alignCast(o.asString()));
        if (std.mem.eql(u8, key, "length")) return Value.true_;
        const i = std.fmt.parseInt(usize, key, 10) catch return Value.false_;
        return Value.fromBool(i < s.flatBytes().len);
    }
    return Value.false_;
}

// ── Property descriptors (§20.1.2) ──────────────────────────────────────────

/// §7.1.19 ToPropertyKey result, paired with a GC anchor. `key`
/// is the slice to use against the property maps; `anchor`, when
/// non-null, is the heap-allocated JSString backing that slice —
/// callers that *store* the key (defineProperty) must append it
/// to the receiver's `key_anchors` so a GC sweep can't free the
/// slice. A null `anchor` means the slice is stable on its own
/// (a Symbol's `prop_key` slug).
const DescKey = struct { key: []const u8, anchor: ?*JSString };

fn descriptorKey(realm: *Realm, v: Value) NativeError!DescKey {
    if (v.isString()) {
        const s: *JSString = @ptrCast(@alignCast(v.asString()));
        return .{ .key = s.flatBytes(), .anchor = s };
    }
    // Symbols use their stable `prop_key` slug (`@@iterator` for
    // well-known, `<sym:N>` for user-allocated). The interpreter's
    // computed-key path stringifies via the same slug, so
    // `Object.defineProperty(o, sym, ...)` and `o[sym]` resolve
    // to the same slot.
    if (heap_mod.valueAsSymbol(v)) |sym| return .{ .key = sym.prop_key, .anchor = null };
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
        if (heap_mod.valueAsSymbol(prim)) |sym| return .{ .key = sym.prop_key, .anchor = null };
        const s = try stringifyArg(realm, prim);
        return .{ .key = s.flatBytes(), .anchor = s };
    }
    const s = try stringifyArg(realm, v);
    return .{ .key = s.flatBytes(), .anchor = s };
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
    // existing-property check below handles them. Redirect-only
    // entries (`namespace_redirects`) installed by re-exports
    // are also "own" per §15.2.1.16.3 ResolveExport.
    const had_own = target.ownDataContains(key) or target.hasNamespaceRedirect(key);
    if (!had_own) return false;
    if (target.hasAmbiguousNamespaceKey(key)) return false;
    // Accessor descriptor against a data slot → reject.
    if (parsed.isAccessor()) return false;
    const cur_flags = target.flagsFor(key);
    if (parsed.has_configurable and parsed.configurable != cur_flags.configurable) {
        if (parsed.configurable) return false;
    }
    if (parsed.has_enumerable and parsed.enumerable != cur_flags.enumerable) {
        return false;
    }
    if (parsed.has_writable and parsed.writable != cur_flags.writable) {
        return false;
    }
    if (parsed.has_value) {
        // §9.4.6.8 step 5 — SameValue against the current binding.
        // For redirect entries we resolve through the chain so the
        // SameValue applies to the source's value, not a Hole/empty.
        const cur_value = blk: {
            if (target.lookupOwn(key)) |v| break :blk v;
            if (target.getNamespaceRedirect(key)) |r| {
                const resolved = @import("../module.zig").resolveRedirectChain(r.target_ns, r.target_key) catch return false;
                break :blk resolved.ns.get(resolved.key);
            }
            return false;
        };
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

/// SetterThatIgnoresPrototypeProperties(O, home, p, v) — the shared
/// abstract operation behind accessor setters that must write an OWN
/// property and never consult the inherited accessor on `home` (which
/// would recurse). Backs `Iterator.prototype.constructor` /
/// `[Symbol.toStringTag]` and `Error.prototype.stack`.
///   1. If O is not an Object → TypeError.
///   2. If SameValue(O, home) → TypeError (emulates assigning to a
///      non-writable data property on `home`).
///   3. Let desc be ? O.[[GetOwnProperty]](p).
///   4. If desc is undefined → ? CreateDataPropertyOrThrow(O, p, v).
///   5. Else → ? Set(O, p, v, true).
///
/// Steps 3 / 4 route through the proxy-aware `objectGetOwnPropertyDescriptor`
/// / `objectDefineProperty`, so Proxy `getOwnPropertyDescriptor` /
/// `defineProperty` traps fire and any object kind (function, array,
/// ordinary) takes an own data property. Step 5 handles the own-DATA
/// case; an own-accessor [[Set]] (which must invoke the accessor's
/// setter) and cross-realm `home` resolution remain tracked residuals.
pub fn setterThatIgnoresPrototypeProperties(realm: *Realm, this_value: Value, home: *JSObject, key: []const u8, v: Value) NativeError!void {
    // step 1 — §6.1.7 Type(O) is Object (excludes Symbol / BigInt).
    if (!heap_mod.isJSObject(this_value)) {
        return throwTypeError(realm, "SetterThatIgnoresPrototypeProperties: receiver is not an object");
    }
    // step 2 — SameValue(O, home).
    if (heap_mod.valueAsPlainObject(this_value)) |po| {
        if (po == home) return throwTypeError(realm, "Cannot assign to a non-writable accessor property on its home prototype");
    }
    const key_str = realm.heap.allocateString(key) catch return error.OutOfMemory;
    const key_v = Value.fromString(key_str);
    // Pin everything held across the proxy-trap re-entries below.
    const scope = realm.heap.openScope() catch return error.OutOfMemory;
    defer scope.close();
    scope.push(this_value) catch return error.OutOfMemory;
    scope.push(key_v) catch return error.OutOfMemory;
    scope.push(v) catch return error.OutOfMemory;
    // step 3 — [[GetOwnProperty]] (fires the Proxy gOPD trap).
    const own_desc = try objectGetOwnPropertyDescriptor(realm, Value.undefined_, &.{ this_value, key_v });
    if (own_desc.isUndefined()) {
        // step 4 — CreateDataPropertyOrThrow via [[DefineOwnProperty]]
        // (fires the Proxy defineProperty trap; a false return / non-
        // extensible target surfaces as a TypeError, which is exactly
        // what Object.defineProperty raises and we propagate).
        const desc_obj = realm.heap.allocateObject() catch return error.OutOfMemory;
        if (realm.intrinsics.object_prototype) |op| realm.heap.setObjectPrototype(desc_obj, op);
        scope.push(heap_mod.taggedObject(desc_obj)) catch return error.OutOfMemory;
        const data_flags: ObjMod.PropertyFlags = .{ .writable = true, .enumerable = true, .configurable = true };
        desc_obj.setWithFlags(realm.allocator, "value", v, data_flags) catch return error.OutOfMemory;
        desc_obj.setWithFlags(realm.allocator, "writable", Value.fromBool(true), data_flags) catch return error.OutOfMemory;
        desc_obj.setWithFlags(realm.allocator, "enumerable", Value.fromBool(true), data_flags) catch return error.OutOfMemory;
        desc_obj.setWithFlags(realm.allocator, "configurable", Value.fromBool(true), data_flags) catch return error.OutOfMemory;
        _ = try objectDefineProperty(realm, Value.undefined_, &.{ this_value, key_v, heap_mod.taggedObject(desc_obj) });
        return;
    }
    // step 5 — ? Set(O, p, v, true). Routes through §7.3.4 Set, which
    // fires the Proxy `set` trap (throwing on a falsy return), invokes
    // an own accessor's setter, and throws on a writability / getter-
    // only violation.
    const obj = heap_mod.valueAsPlainObject(this_value) orelse {
        // A function receiver with a pre-existing own property is not
        // reached by any current fixture.
        return throwTypeError(realm, "SetterThatIgnoresPrototypeProperties: own-property update unsupported on this receiver");
    };
    try @import("array.zig").setOrThrow(realm, obj, key, key_str, v);
}

pub fn objectDefineProperty(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = this_value;
    const target_v = argOr(args, 0, Value.undefined_);
    // §7.1.19 ToPropertyKey on the property-name argument — may
    // throw if a user-side `toString` / `valueOf` returns a non-
    // primitive (the §7.1.1.1 OrdinaryToPrimitive throw). Don't
    // swallow that as OOM; surface the TypeError back to JS.
    const dk = try descriptorKey(realm, argOr(args, 1, Value.undefined_));
    const key = dk.key;
    const desc_v = argOr(args, 2, Value.undefined_);
    // Pin the target, the descriptor object, and the heap-allocated
    // key string across the descriptor parse and any proxy trap —
    // all re-enter JS and can trigger a GC sweep. When this native
    // is invoked from another native (`Object.defineProperties`,
    // `defineFromFunctionProps`) the argument slice is a bare Zig
    // stack array, not a rooted interpreter frame, so without this
    // the key / target could be collected mid-call.
    const dp_scope = realm.heap.openScope() catch return error.OutOfMemory;
    defer dp_scope.close();
    dp_scope.push(target_v) catch return error.OutOfMemory;
    dp_scope.push(desc_v) catch return error.OutOfMemory;
    if (dk.anchor) |ks| dp_scope.push(Value.fromString(ks)) catch return error.OutOfMemory;
    // §10.5.6 Proxy [[DefineOwnProperty]] — dispatch through the
    // handler's `defineProperty` trap before falling back.
    if (heap_mod.valueAsPlainObject(target_v)) |obj_in| {
        if (obj_in.proxy_target != null or obj_in.proxy_target_fn != null or obj_in.proxy_revoked) {
            if (obj_in.proxy_revoked) return throwTypeError(realm, "Cannot perform 'defineProperty' on a revoked proxy");
            // Build the target value for the trap and the
            // proxy_target object pointer (for invariant checks).
            // For a callable-target proxy, the value is the
            // function; there's no plain-object target so the
            // invariant guards (which expect property bags) skip.
            const proxy_target_v: Value = if (obj_in.proxy_target) |t|
                heap_mod.taggedObject(t)
            else if (obj_in.proxy_target_fn) |tfn|
                heap_mod.taggedFunction(tfn)
            else
                unreachable;
            const proxy_target_obj: ?*@import("../object.zig").JSObject = obj_in.proxy_target;
            const handler = obj_in.proxy_handler orelse return throwTypeError(realm, "Cannot perform 'defineProperty' on a proxy with null handler");
            const trap_v = try intrinsics.getPropertyChain(realm, handler, "defineProperty");
            // §10.5.6 step 5 — IsCallable check. `undefined` /
            // `null` means "no trap; fall through". Anything else
            // non-callable is a TypeError.
            if (!trap_v.isUndefined() and !trap_v.isNull()) {
                const trap_fn = heap_mod.valueAsFunction(trap_v) orelse return throwTypeError(realm, "Proxy 'defineProperty' trap is not callable");
                const lantern = @import("../lantern/interpreter.zig");
                // §10.5.6 step 7 — pass the property key as a Symbol
                // when the slot is symbol-keyed (Cynic flattens
                // symbols into `@@<name>` / `<sym:N>` slugs internally
                // — the trap, per §6.1.7.1, must receive a Symbol
                // Value). Plain string keys round-trip as Strings
                // (test262 built-ins/Object/seal/proxy-no-ownkeys-returned-keys-order.js,
                // built-ins/Object/defineProperties/proxy-no-ownkeys-returned-keys-order.js).
                const key_v = if ((std.mem.startsWith(u8, key, "@@") or std.mem.startsWith(u8, key, "<sym:")) and realm.heap.symbolForKey(key) != null)
                    heap_mod.taggedSymbol(realm.heap.symbolForKey(key).?)
                else blk_key: {
                    const key_str = realm.heap.allocateString(key) catch return error.OutOfMemory;
                    break :blk_key Value.fromString(key_str);
                };
                const trap_args = [_]Value{ proxy_target_v, key_v, desc_v };
                const outcome = lantern.callJSFunction(realm.allocator, realm, trap_fn, heap_mod.taggedObject(handler), &trap_args) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    else => return error.NativeThrew,
                };
                switch (outcome) {
                    .value, .yielded => |v| {
                        if (!intrinsics.toBoolean(v)) {
                            // Signal `Reflect.defineProperty` to
                            // translate this into a `false` return
                            // rather than re-raising the TypeError;
                            // `Object.defineProperty` still throws.
                            realm.define_own_property_rejected = true;
                            return throwTypeError(realm, "'defineProperty' on proxy returned falsy");
                        }
                        // §10.5.6 steps 16-19 — invariant guards
                        // only fire for plain-object targets (the
                        // callable-target case is subsumed by
                        // JSFunction's own [[DefineOwnProperty]]
                        // semantics; in particular, redefining
                        // `prototype` on a function is governed by
                        // §10.2.4 not the proxy invariant set).
                        if (proxy_target_obj) |proxy_target| {
                            const target_had = proxy_target.hasOwn(key) or proxy_target.hasAccessor(key);
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
                                const cur_is_acc = proxy_target.hasAccessor(key);
                                const cur_value: Value = blk: {
                                    if (cur_is_acc) break :blk Value.undefined_;
                                    if (proxy_target.lookupOwn(key)) |val| break :blk val;
                                    break :blk Value.undefined_;
                                };
                                var cur_getter: ?*JSFunction = null;
                                var cur_setter: ?*JSFunction = null;
                                if (proxy_target.getAccessor(key)) |a| {
                                    cur_getter = a.getter;
                                    cur_setter = a.setter;
                                }
                                if (!isCompatibleRedefine(cur_is_acc, cur_flags, cur_value, cur_getter, cur_setter, parsed_for_inv)) {
                                    return throwTypeError(realm, "'defineProperty' on proxy: trap returned truthy for an incompatible redefine of a non-configurable target property");
                                }
                                if (parsed_for_inv.has_configurable and !parsed_for_inv.configurable and cur_flags.configurable) {
                                    return throwTypeError(realm, "'defineProperty' on proxy: cannot flip a configurable target property to non-configurable via the trap");
                                }
                                // §10.5.6 step 16.c (proxy-missing-checks) —
                                // target is non-configurable + writable; the
                                // new descriptor cannot flip writable to false.
                                if (!cur_flags.configurable and cur_flags.writable and !cur_is_acc and parsed_for_inv.isData()) {
                                    if (parsed_for_inv.has_writable and !parsed_for_inv.writable) {
                                        return throwTypeError(realm, "'defineProperty' on proxy: cannot flip a writable non-configurable target property to non-writable via the trap");
                                    }
                                }
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
            // §10.5.6 step 7.a — Trap absent: recurse on the target.
            const inner_args = [_]Value{ proxy_target_v, argOr(args, 1, Value.undefined_), desc_v };
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
            realm.heap.setObjectPrototype(w, fn_obj.proto);
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
        if (target.getTypedView() != null) {
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
                    .reject => {
                        realm.define_own_property_rejected = true;
                        return throwTypeError(realm, "Invalid TypedArray index descriptor");
                    },
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
            const arith = @import("../lantern/arith.zig");
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
        const had_own = target.hasOwn(key) or target.hasAccessor(key);
        const cur_flags = target.flagsFor(key);
        const cur_is_accessor = target.hasAccessor(key);
        // §10.1.6 — current value comes from `properties` first,
        // then from an Array exotic's `elements` for indexed keys
        // (so `defineProperty` sees the slot's actual value, not
        // undefined, when running the non-configurable redefine
        // guard on an already-set index).
        const cur_value: Value = blk_cv: {
            if (cur_is_accessor) break :blk_cv Value.undefined_;
            if (target.lookupOwn(key)) |v| break :blk_cv v;
            if (target.is_array_exotic) {
                if (ObjMod.JSObject.canonicalIntegerIndex(key)) |idx| {
                    if (target.tryGetIndexedOwn(idx)) |ev| break :blk_cv ev;
                }
            }
            break :blk_cv Value.undefined_;
        };
        var cur_getter: ?*JSFunction = null;
        var cur_setter: ?*JSFunction = null;
        if (target.getAccessor(key)) |a| {
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
            // The shadow shape only models data properties, so an
            // accessor install demotes — otherwise the property
            // removal below would leave the shape claiming a data
            // slot whose value the IC would still serve.
            try target.demoteFromShape(realm.allocator);
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
                    }
                }
            }
            const entry = target.getOrPutAccessor(realm.allocator, key) catch return error.OutOfMemory;
            if (!entry.found_existing) entry.value_ptr.* = .{};
            // Preserve the half not specified in the new desc.
            const new_getter: ?*JSFunction = if (parsed.has_get) parsed.getter else if (cur_is_accessor) cur_getter else null;
            const new_setter: ?*JSFunction = if (parsed.has_set) parsed.setter else if (cur_is_accessor) cur_setter else null;
            realm.heap.setAccessorGetter(.{ .object = target }, entry.value_ptr, new_getter);
            realm.heap.setAccessorSetter(.{ .object = target }, entry.value_ptr, new_setter);
            // Installing an accessor on an object that may be a
            // proto for other receivers invalidates any cached
            // `sta_property` transition IC whose chain-clean
            // check happened BEFORE this defineProperty. The
            // existing `proto_revision_counter` is the broadest-
            // useful invalidation signal we already have — every
            // IC that snapshots it (proto-load read IC,
            // transition write IC) refills on the next call.
            // Defining a non-accessor descriptor doesn't need
            // the bump because the IC's shape-comparison already
            // catches own-data additions.
            realm.proto_revision_counter +%= 1;
            // Accessors don't honor `writable`; clear that bit.
            flags.writable = false;
            target.property_flags.put(realm.allocator, key, flags) catch return error.OutOfMemory;
            // §10.1.11 — record this as an own key for enumeration
            // order. The matching `properties.swapRemove(key)` above
            // does NOT call `forgetKey` because data→accessor
            // conversion preserves the original insertion slot.
            _ = target.recordKey(realm.allocator, key) catch return error.OutOfMemory;
            // The accessors map borrows the `key` slice; anchor the
            // heap-allocated key JSString so a GC sweep can't free
            // it. Symbol keys (null anchor) are stable on their own.
            // Anchored even on a redefine: a data→accessor conversion
            // stores a freshly stringified key slice.
            if (dk.anchor) |ks| {
                target.anchorKey(realm.allocator, ks) catch return error.OutOfMemory;
                target.markNonPristine();
            }
            return target_v;
        }

        // Data descriptor (or generic — preserves the existing
        // shape).
        if (parsed.isData() or !cur_is_accessor) {
            // Drop any previous accessor.
            _ = target.removeAccessor(key);
            const value: Value = if (parsed.has_value) parsed.value else cur_value;
            target.setWithFlags(realm.allocator, key, value, flags) catch return error.OutOfMemory;
            // Anchor the heap key string when it landed in the
            // named-property bag (an array-exotic integer index goes
            // to `elements` and needs no anchor).
            if (target.ownDataContains(key)) {
                if (dk.anchor) |ks| {
                    target.anchorKey(realm.allocator, ks) catch return error.OutOfMemory;
                    target.markNonPristine();
                }
            }
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
                const lantern = @import("../lantern/interpreter.zig");
                const trunc = lantern.truncateArrayAtLength(realm.allocator, target, new_len);
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
            if (!entry.found_existing) entry.value_ptr.* = .{};
            const new_getter: ?*JSFunction = if (parsed.has_get) parsed.getter else if (cur_is_accessor) cur_getter else null;
            const new_setter: ?*JSFunction = if (parsed.has_set) parsed.setter else if (cur_is_accessor) cur_setter else null;
            realm.heap.setAccessorGetter(.{ .function = target_fn }, entry.value_ptr, new_getter);
            realm.heap.setAccessorSetter(.{ .function = target_fn }, entry.value_ptr, new_setter);
            // Invalidate IC cells — see the matching bump on the
            // object-target accessor-install path above.
            realm.proto_revision_counter +%= 1;
            // Accessors don't carry a `writable` bit; clear it.
            flags.writable = false;
            const is_default = flags.writable and flags.enumerable and flags.configurable;
            if (is_default) {
                _ = target_fn.property_flags.swapRemove(key);
            } else {
                target_fn.property_flags.put(realm.allocator, key, flags) catch return error.OutOfMemory;
            }
            // §10.1.11 — track function objects' own keys too.
            _ = target_fn.recordKey(realm.allocator, key) catch return error.OutOfMemory;
            // Anchor the borrowed heap key string on the function.
            if (dk.anchor) |ks| target_fn.anchorKey(realm.allocator, ks) catch return error.OutOfMemory;
            return target_v;
        }

        if (parsed.isData() or !cur_is_accessor) {
            // Drop any previous accessor.
            _ = target_fn.accessors.swapRemove(key);
            const value: Value = if (parsed.has_value) parsed.value else cur_value;
            target_fn.setWithFlags(realm.allocator, key, value, flags) catch return error.OutOfMemory;
            if (target_fn.ownDataContains(key)) {
                if (dk.anchor) |ks| target_fn.anchorKey(realm.allocator, ks) catch return error.OutOfMemory;
            }
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
    // `null` / `undefined` throw; primitives box into wrappers.
    // Boolean / Number / Symbol / BigInt wrappers carry no extra
    // enumerable own keys, so iteration is a no-op. A non-empty
    // primitive String wraps into a String exotic whose indexed-
    // character own properties ARE enumerable per §22.1.4.4, so
    // each character flows into ToPropertyDescriptor which throws
    // on a non-object descObj
    // (`built-ins/Object/create/properties-arg-to-object-non-empty-string.js`).
    // Functions are Objects per §17 and must be walked directly so
    // user-installed getter / data props see `this === fn`
    // (`built-ins/Object/create/15.2.3.5-4-5.js`); the JSFunction
    // heap struct can't pose as `*JSObject` for `getPropertyChain`
    // so the function case routes through `defineFromFunctionProps`.
    const props_v = argOr(args, 1, Value.undefined_);
    if (props_v.isNull() or props_v.isUndefined()) {
        return throwTypeError(realm, "Object.defineProperties properties is not an object");
    }
    if (heap_mod.valueAsFunction(props_v)) |props_fn| {
        return defineFromFunctionProps(realm, target, props_fn);
    }
    const props: *@import("../object.zig").JSObject = blk_props: {
        if (heap_mod.valueAsPlainObject(props_v)) |o| break :blk_props o;
        // §7.1.18 ToObject for non-null/non-undefined primitives.
        break :blk_props try intrinsics.toObjectThis(realm, props_v);
    };
    // Root the target and the props object across the key loop —
    // each `objectDefineProperty` call re-enters JS (descriptor
    // getters / proxy traps) and allocates.
    const dps_scope = realm.heap.openScope() catch return error.OutOfMemory;
    defer dps_scope.close();
    dps_scope.push(heap_mod.taggedObject(target)) catch return error.OutOfMemory;
    dps_scope.push(heap_mod.taggedObject(props)) catch return error.OutOfMemory;

    // §20.1.2.3.1 step 3 — `Let keys be ? props.[[OwnPropertyKeys]]()`.
    // For a Proxy `props` this fires the `ownKeys` trap (test262
    // built-ins/Object/defineProperties/proxy-no-ownkeys-returned-keys-order.js).
    // ownPropertyKeysOrdered walks in spec order (integer-indexed
    // ascending, then string-keyed in insertion order); accessor-
    // backed keys are included so their getters fire per step 5.b.ii.
    const props_is_proxy = props.proxy_target != null or props.proxy_revoked;
    const keys = if (try proxyOwnKeysOrNull(realm, props, dps_scope)) |k| k else try ownPropertyKeysOrdered(realm, props, dps_scope);
    defer realm.allocator.free(keys);
    for (keys) |key| {
        // §20.1.2.3.1 step 5.a — `Let propDesc be ? props.[[GetOwnProperty]](nextKey)`,
        // step 5.b — only iterate when `propDesc.[[Enumerable]]` is true.
        // For a Proxy receiver, dispatch through the
        // `getOwnPropertyDescriptor` trap and read the descriptor's
        // `enumerable` field — the trap may have overridden it.
        if (props_is_proxy) {
            const key_str = realm.heap.allocateString(key) catch return error.OutOfMemory;
            const desc_args = [_]Value{ heap_mod.taggedObject(props), Value.fromString(key_str) };
            const desc_v = try objectGetOwnPropertyDescriptor(realm, Value.undefined_, &desc_args);
            if (desc_v.isUndefined()) continue;
            const desc_obj = heap_mod.valueAsPlainObject(desc_v) orelse continue;
            const enum_v = desc_obj.get("enumerable");
            if (!enum_v.isBool() or !enum_v.asBool()) continue;
        } else {
            if (!props.flagsFor(key).enumerable) continue;
        }
        // §20.1.2.3.1 step 5.b.ii — `Let descObj be ? Get(props, nextKey)`.
        // Route through `getPropertyValue` so a Proxy `get` trap fires.
        // When `props` holds an accessor, `descObj` is a fresh value
        // reachable through nothing — root it (and the freshly
        // allocated key string) before `objectDefineProperty`
        // re-enters JS / allocates, or an allocation-pressure GC frees
        // them mid-define (use-after-free).
        const desc_v = try getPropertyValue(realm, props, key, heap_mod.taggedObject(props));
        dps_scope.push(desc_v) catch return error.OutOfMemory;
        const k_str = realm.heap.allocateString(key) catch return error.OutOfMemory;
        dps_scope.push(Value.fromString(k_str)) catch return error.OutOfMemory;
        const inner_args = [_]Value{ heap_mod.taggedObject(target), Value.fromString(k_str), desc_v };
        _ = try objectDefineProperty(realm, Value.undefined_, &inner_args);
    }
    return heap_mod.taggedObject(target);
}

/// §20.1.2.3.1 ObjectDefineProperties when `Properties` is a
/// Function object. JSFunction and JSObject are distinct heap
/// structs in Cynic, so we can't pass the function through the
/// JSObject-typed `getPropertyChain`; walk its `properties` /
/// `accessors` bags directly and fire getters with the original
/// function as the receiver (so user code that observes `this`
/// inside the getter sees the function, not a wrapper).
fn defineFromFunctionProps(
    realm: *Realm,
    target: *@import("../object.zig").JSObject,
    props_fn: *@import("../function.zig").JSFunction,
) NativeError!Value {
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    defer seen.deinit(realm.allocator);
    // Root the receiver and the Properties function across the loop.
    // `allocateString` (every iteration) and the accessor getter
    // (`callJSFunction`) each allocate, so under allocation-pressure
    // GC an unrooted `target` would be swept before
    // `objectDefineProperty` consumes it — a use-after-free that
    // segfaults when the getter re-enters JS
    // (`built-ins/Object/create/15.2.3.5-4-5.js`: a Function
    // `Properties` whose accessor getter returns a fresh object).
    // Rooting `props_fn` also keeps its property / accessor bags —
    // and the borrowed `key` slices into them — alive across the loop.
    const scope = realm.heap.openScope() catch return error.OutOfMemory;
    defer scope.close();
    scope.push(heap_mod.taggedObject(target)) catch return error.OutOfMemory;
    scope.push(heap_mod.taggedFunction(props_fn)) catch return error.OutOfMemory;
    var pit = props_fn.properties.iterator();
    while (pit.next()) |entry| {
        const key = entry.key_ptr.*;
        _ = seen.put(realm.allocator, key, {}) catch return error.OutOfMemory;
        // No explicit flags entry ⇒ default to a writable /
        // enumerable / configurable data descriptor (the same
        // default JSObject.flagsFor returns for an unknown key).
        // A user `fn.prop = …` write doesn't pin flags, so the
        // spec-default applies.
        const flags = props_fn.property_flags.get(key) orelse @import("../object.zig").PropertyFlags{};
        if (!flags.enumerable) continue;
        const k_str = realm.heap.allocateString(key) catch return error.OutOfMemory;
        // `desc_v` is a data value already reachable through the
        // rooted `props_fn`; root only the freshly-allocated key
        // string across `objectDefineProperty`'s re-entry.
        scope.push(Value.fromString(k_str)) catch return error.OutOfMemory;
        const desc_v = entry.value_ptr.*;
        const inner = [_]Value{ heap_mod.taggedObject(target), Value.fromString(k_str), desc_v };
        _ = try objectDefineProperty(realm, Value.undefined_, &inner);
    }
    var ait = props_fn.accessors.iterator();
    while (ait.next()) |entry| {
        const key = entry.key_ptr.*;
        if (seen.contains(key)) continue;
        const flags = props_fn.property_flags.get(key) orelse continue;
        if (!flags.enumerable) continue;
        const k_str = realm.heap.allocateString(key) catch return error.OutOfMemory;
        // Root the key string before the getter runs — the getter
        // allocates and can GC.
        scope.push(Value.fromString(k_str)) catch return error.OutOfMemory;
        var desc_v: Value = Value.undefined_;
        if (entry.value_ptr.getter) |getter| {
            const lantern = @import("../lantern/interpreter.zig");
            const outcome = lantern.callJSFunction(realm.allocator, realm, getter, heap_mod.taggedFunction(props_fn), &.{}) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return error.NativeThrew,
            };
            desc_v = switch (outcome) {
                .value, .yielded => |v| v,
                .thrown => |ex| {
                    realm.pending_exception = ex;
                    return error.NativeThrew;
                },
            };
        }
        // The getter's result is a fresh value reachable through
        // nothing yet — root it across `objectDefineProperty`, which
        // re-enters JS and allocates.
        scope.push(desc_v) catch return error.OutOfMemory;
        const inner = [_]Value{ heap_mod.taggedObject(target), Value.fromString(k_str), desc_v };
        _ = try objectDefineProperty(realm, Value.undefined_, &inner);
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
    const dk = try descriptorKey(realm, argOr(args, 1, Value.undefined_));
    const key = dk.key;
    // Pin the target and the borrowed key slice across the proxy
    // `getOwnPropertyDescriptor` trap re-entry below — a mid-trap
    // GC would otherwise free the key's backing JSString (leaving
    // the post-trap `hasOwn(key)` invariant checks reading freed
    // memory) or collect a freshly boxed primitive target.
    const scope = realm.heap.openScope() catch return error.OutOfMemory;
    defer scope.close();
    scope.push(target) catch return error.OutOfMemory;
    if (dk.anchor) |ks| scope.push(Value.fromString(ks)) catch return error.OutOfMemory;

    // §10.5.5 Proxy [[GetOwnProperty]] — when target is a proxy,
    // dispatch through `handler.getOwnPropertyDescriptor`. Walks
    // the chain so a trapless outer proxy whose target is itself
    // a proxy forwards to the inner proxy's trap (§10.5.5 step 7.a
    // recurses into target.[[GetOwnProperty]]).
    if (heap_mod.valueAsPlainObject(target)) |obj_chain_root| {
        var cursor = obj_chain_root;
        while (cursor.proxy_target != null or cursor.proxy_target_fn != null or cursor.proxy_revoked) {
            if (cursor.proxy_revoked) return throwTypeError(realm, "Cannot perform 'getOwnPropertyDescriptor' on a revoked proxy");
            const handler = cursor.proxy_handler orelse return throwTypeError(realm, "Cannot perform 'getOwnPropertyDescriptor' on a proxy with null handler");
            // Build a Value for the proxy target — plain-object
            // target lives in `proxy_target`, callable target in
            // `proxy_target_fn`.
            const target_value: Value = if (cursor.proxy_target) |t|
                heap_mod.taggedObject(t)
            else if (cursor.proxy_target_fn) |tfn|
                heap_mod.taggedFunction(tfn)
            else
                unreachable;
            const trap_v = try getHandlerProperty(realm, handler, "getOwnPropertyDescriptor");
            if (trap_v.isUndefined() or trap_v.isNull()) {
                // §10.5.5 step 7.a — fall through to target.
                // [[GetOwnProperty]]. If target itself is a proxy,
                // loop; otherwise recurse to the non-proxy path.
                if (cursor.proxy_target) |proxy_target| {
                    if (proxy_target.proxy_target != null or proxy_target.proxy_target_fn != null or proxy_target.proxy_revoked) {
                        cursor = proxy_target;
                        continue;
                    }
                }
                const inner_args = [_]Value{ target_value, argOr(args, 1, Value.undefined_) };
                return objectGetOwnPropertyDescriptor(realm, Value.undefined_, &inner_args);
            }
            {
                const trap_fn = heap_mod.valueAsFunction(trap_v) orelse return throwTypeError(realm, "Proxy 'getOwnPropertyDescriptor' trap is not callable");
                const lantern = @import("../lantern/interpreter.zig");
                // §10.5.5 step 7 — invoke trap with the original
                // property key. Symbol-keyed properties must be
                // passed back as the Symbol primitive (not the
                // flattened `<sym:N>` string the prop bag uses
                // internally), so user traps see the same value
                // they were given via `ownKeys`.
                const key_value: Value = if (isSymbolKey(key))
                    if (realm.heap.symbolForKey(key)) |sym| heap_mod.taggedSymbol(sym) else Value.fromString(realm.heap.allocateString(key) catch return error.OutOfMemory)
                else
                    Value.fromString(realm.heap.allocateString(key) catch return error.OutOfMemory);
                const trap_args = [_]Value{ target_value, key_value };
                const outcome = lantern.callJSFunction(realm.allocator, realm, trap_fn, heap_mod.taggedObject(handler), &trap_args) catch |err| switch (err) {
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
                // Root the trap result — `parseDescriptor` below can
                // re-enter JS through descriptor-field getters.
                scope.push(result_v) catch return error.OutOfMemory;
                // §10.5.5 step 8 — trap result must be Object or
                // Undefined. (Symbols / numbers / null all reject.)
                if (!result_v.isUndefined() and heap_mod.valueAsPlainObject(result_v) == null) {
                    return throwTypeError(realm, "'getOwnPropertyDescriptor' on proxy must return an Object or undefined");
                }
                // §10.5.5 step 9-17 — invariants only fire when the
                // target is a plain object (callable-target invariants
                // are subsumed by JSFunction's own ordinary [[GetOwnProperty]]).
                if (cursor.proxy_target) |proxy_target| {
                    const target_had = proxy_target.hasOwn(key) or proxy_target.hasAccessor(key);
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
                    // §10.5.5 step 17 — when the target lacks the
                    // property AND is non-extensible, the trap MUST
                    // report undefined. A descriptor return here is
                    // an invariant violation.
                    if (!target_had and !proxy_target.extensible) {
                        return throwTypeError(realm, "'getOwnPropertyDescriptor' on proxy returned a descriptor for an absent property of a non-extensible target");
                    }
                    // §10.5.5 steps 16-18 — IsCompatiblePropertyDescriptor
                    // (extensibleTarget, resultDesc, targetDesc). When the
                    // target owns the property, the trap's descriptor must be
                    // compatible with the target's current one. Reuse the
                    // shared §10.1.6.3 ValidateAndApplyPropertyDescriptor
                    // guard `isCompatibleRedefine`: against a non-configurable
                    // target property it rejects a trap that claims
                    // `configurable: true`, toggles `enumerable`, flips
                    // data<->accessor, or mutates a non-writable data slot's
                    // value/writable. (The configurable→non-configurable and
                    // writable specials below are §10.5.5 steps 19-21, which
                    // that guard does not cover.)
                    if (target_had) {
                        const t_flags = proxy_target.flagsFor(key);
                        const t_is_acc = proxy_target.hasAccessor(key);
                        const t_value = proxy_target.lookupOwn(key) orelse Value.undefined_;
                        var t_getter: ?*JSFunction = null;
                        var t_setter: ?*JSFunction = null;
                        if (proxy_target.getAccessor(key)) |acc| {
                            t_getter = acc.getter;
                            t_setter = acc.setter;
                        }
                        if (!isCompatibleRedefine(t_is_acc, t_flags, t_value, t_getter, t_setter, parsed_inv)) {
                            return throwTypeError(realm, "'getOwnPropertyDescriptor' on proxy returned a descriptor incompatible with the non-configurable target property");
                        }
                    }
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
                }
                return result_v;
            }
        }
    }

    if (heap_mod.valueAsPlainObject(target)) |obj| {
        // §10.4.5.2 Integer-Indexed Exotic Object [[GetOwnProperty]]
        if (obj.getTypedView() != null) {
            const ta = @import("typed_array.zig");
            if (ta.canonicalNumericIndex(key)) |num| {
                if (ta.typedArrayGetOwnPropertyValue(realm, obj, num)) |v| {
                    const desc = realm.heap.allocateObject() catch return error.OutOfMemory;
                    realm.heap.setObjectPrototype(desc, realm.intrinsics.object_prototype);
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
        if (obj.getAccessor(key)) |acc| {
            const desc = realm.heap.allocateObject() catch return error.OutOfMemory;
            realm.heap.setObjectPrototype(desc, realm.intrinsics.object_prototype);
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
        // §9.4.6.4 Module Namespace [[GetOwnProperty]] step 4 —
        // `Let value be ? O.[[Get]](P, O)` materialises the
        // descriptor's `[[Value]]` via the exotic [[Get]], which
        // routes string keys through GetBindingValue(N, true) and
        // throws ReferenceError on the source TDZ-Hole. Symbol
        // keys (and Cynic's flattened `@@toStringTag`) bypass via
        // §9.4.6.7 step 2.
        const value = if (obj.is_module_namespace and !std.mem.startsWith(u8, key, "@@") and !std.mem.startsWith(u8, key, "<sym:"))
            try @import("../module.zig").namespaceGetThrowingOnHole(realm, obj, key)
        else
            obj.get(key);
        const flags = obj.flagsFor(key);
        const desc = realm.heap.allocateObject() catch return error.OutOfMemory;
        realm.heap.setObjectPrototype(desc, realm.intrinsics.object_prototype);
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
            realm.heap.setObjectPrototype(desc, realm.intrinsics.object_prototype);
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
        realm.heap.setObjectPrototype(desc, realm.intrinsics.object_prototype);
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
    // §17 — Function objects are also ordinary objects; walk their
    // own keys directly (the JSFunction heap struct isn't a JSObject
    // so the plain-object path below can't accept it). Each key
    // routes through the singular GOPD, which handles functions.
    if (heap_mod.valueAsFunction(target)) |fn_obj| {
        const fout = realm.heap.allocateObject() catch return error.OutOfMemory;
        realm.heap.setObjectPrototype(fout, realm.intrinsics.object_prototype);
        const fscope = realm.heap.openScope() catch return error.OutOfMemory;
        defer fscope.close();
        fscope.push(target) catch return error.OutOfMemory;
        fscope.push(heap_mod.taggedObject(fout)) catch return error.OutOfMemory;
        var fit = fn_obj.properties.iterator();
        while (fit.next()) |entry| {
            const key = entry.key_ptr.*;
            if (std.mem.startsWith(u8, key, "__cynic_")) continue;
            const k_str = realm.heap.allocateString(key) catch return error.OutOfMemory;
            const key_arg: Value = if (isSymbolKey(key))
                if (realm.heap.symbolForKey(key)) |sym| heap_mod.taggedSymbol(sym) else Value.fromString(k_str)
            else
                Value.fromString(k_str);
            const inner_args = [_]Value{ target, key_arg };
            const desc = try objectGetOwnPropertyDescriptor(realm, Value.undefined_, &inner_args);
            if (desc.isUndefined()) continue;
            fout.set(realm.allocator, k_str.flatBytes(), desc) catch return error.OutOfMemory;
            if (fout.ownDataContains(k_str.flatBytes())) {
                fout.anchorKey(realm.allocator, k_str) catch return error.OutOfMemory;
                fout.markNonPristine();
            }
        }
        return heap_mod.taggedObject(fout);
    }
    const obj = heap_mod.valueAsPlainObject(target) orelse return throwTypeError(realm, "Object.getOwnPropertyDescriptors target is not an object");
    const out = realm.heap.allocateObject() catch return error.OutOfMemory;
    realm.heap.setObjectPrototype(out, realm.intrinsics.object_prototype);
    // Root the source and the result across the re-entrant loop
    // (proxy GOPD traps, plus `allocateString` GC safepoints).
    const scope = realm.heap.openScope() catch return error.OutOfMemory;
    defer scope.close();
    scope.push(target) catch return error.OutOfMemory;
    scope.push(heap_mod.taggedObject(out)) catch return error.OutOfMemory;
    // §20.1.2.10 step 2 — `Let ownKeys be ? O.[[OwnPropertyKeys]]()`.
    // For a Proxy this fires the `ownKeys` trap (test262
    // built-ins/Object/getOwnPropertyDescriptors/observable-operations.js
    // and /proxy-no-ownkeys-returned-keys-order.js). On an Array
    // exotic ownPropertyKeysOrdered surfaces the packed-element
    // indices.
    const key_scope = realm.heap.openScope() catch return error.OutOfMemory;
    defer key_scope.close();
    const keys = if (try proxyOwnKeysOrNull(realm, obj, key_scope)) |k| k else try ownPropertyKeysOrdered(realm, obj, key_scope);
    defer realm.allocator.free(keys);
    for (keys) |key| {
        // §20.1.2.10 step 4 — `Let desc be ? obj.[[GetOwnProperty]](key)`,
        // step 5 — `Let descriptor be FromPropertyDescriptor(desc)`.
        // FromPropertyDescriptor returns undefined when desc is
        // undefined; the spec's CreateDataPropertyOrThrow then skips
        // (§7.3.4 wraps CreateDataProperty which only fires for
        // non-undefined `descriptor`). Filter the undefined case so
        // a Proxy `getOwnPropertyDescriptor` trap that returns
        // `undefined` doesn't surface a `key: undefined` slot
        // (test262 built-ins/Object/getOwnPropertyDescriptors/proxy-undefined-descriptor.js).
        const k_str = realm.heap.allocateString(key) catch return error.OutOfMemory;
        // Symbol-keyed properties must be passed back as a Symbol
        // primitive (Cynic flattens to `<sym:N>` internally), so
        // `objectGetOwnPropertyDescriptor`'s ToPropertyKey resolves
        // to the same slot the `ownKeys` walk produced.
        const key_arg: Value = if (isSymbolKey(key))
            if (realm.heap.symbolForKey(key)) |sym| heap_mod.taggedSymbol(sym) else Value.fromString(k_str)
        else
            Value.fromString(k_str);
        const inner_args = [_]Value{ heap_mod.taggedObject(obj), key_arg };
        const desc = try objectGetOwnPropertyDescriptor(realm, Value.undefined_, &inner_args);
        if (desc.isUndefined()) continue;
        out.set(realm.allocator, k_str.flatBytes(), desc) catch return error.OutOfMemory;
        // `out` borrows the `k_str` slice as the property key; anchor
        // the heap string so a later sweep can't free it.
        if (out.ownDataContains(k_str.flatBytes())) {
            out.anchorKey(realm.allocator, k_str) catch return error.OutOfMemory;
            out.markNonPristine();
        }
    }
    return heap_mod.taggedObject(out);
}

fn objectGetOwnPropertyNames(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = this_value;
    const raw = argOr(args, 0, Value.undefined_);
    // §20.1.2.10 step 1 — `Let obj be ? ToObject(O)`. ES2015+
    // primitive-coerces the arg. Symbol and BigInt primitives
    // also coerce to a wrapper with no own string keys, so they
    // return `[]` (test262 `non-object-argument-valid.js`).
    // null/undefined still throw via `toObjectThis`.
    const target = if (raw.isInt32() or raw.isDouble() or raw.isString() or raw.isBool() or heap_mod.isSymbol(raw) or heap_mod.isBigInt(raw))
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
        realm.heap.setObjectPrototype(out, realm.intrinsics.array_prototype);
        out.markAsArrayExotic(realm.allocator) catch return error.OutOfMemory;
        // Root the result array — built across `allocateString` GC
        // safepoints.
        const fscope = realm.heap.openScope() catch return error.OutOfMemory;
        defer fscope.close();
        fscope.push(heap_mod.taggedObject(out)) catch return error.OutOfMemory;
        var len: i32 = 0;
        // §10.2.4 — built-in constructors expose `prototype` as
        // an own property; the slot is dedicated (`fn_obj.prototype`)
        // and doesn't appear in the property bag iteration. The
        // §10.1.11 OrdinaryOwnPropertyKeys partition still applies
        // to functions: integer-index keys first (ascending
        // numeric), then string keys in insertion order.
        const has_dedicated_prototype = fn_obj.prototype != null and !fn_obj.ownDataContains("prototype");

        // Partition the bag's keys into integer / string sections.
        const FnKeyEntry = struct { idx: u32, key: []const u8 };
        var fn_int_keys: std.ArrayListUnmanaged(FnKeyEntry) = .empty;
        defer fn_int_keys.deinit(realm.allocator);
        var fn_str_keys: std.ArrayListUnmanaged([]const u8) = .empty;
        defer fn_str_keys.deinit(realm.allocator);
        var fit = fn_obj.properties.iterator();
        while (fit.next()) |entry| {
            const key = entry.key_ptr.*;
            if (std.mem.startsWith(u8, key, "__cynic_")) continue;
            if (isSymbolKey(key)) continue;
            if (canonicalIntegerIndex(key)) |i| {
                fn_int_keys.append(realm.allocator, .{ .idx = i, .key = key }) catch return error.OutOfMemory;
            } else {
                fn_str_keys.append(realm.allocator, key) catch return error.OutOfMemory;
            }
        }
        std.mem.sort(FnKeyEntry, fn_int_keys.items, {}, struct {
            fn lessThan(_: void, a: FnKeyEntry, b: FnKeyEntry) bool {
                return a.idx < b.idx;
            }
        }.lessThan);

        // 1) Integer-indexed keys in ascending order.
        for (fn_int_keys.items) |e| {
            var ibuf: [16]u8 = undefined;
            const islice = std.fmt.bufPrint(&ibuf, "{d}", .{len}) catch unreachable;
            const idx_owned = realm.heap.allocateString(islice) catch return error.OutOfMemory;
            const k_owned = realm.heap.allocateString(e.key) catch return error.OutOfMemory;
            out.set(realm.allocator, idx_owned.flatBytes(), Value.fromString(k_owned)) catch return error.OutOfMemory;
            len += 1;
        }

        // 2) String keys in insertion order, with `prototype`
        // synthesised from the dedicated slot inserted right after
        // `name` (matching SetFunctionLength / OrdinaryFunctionCreate
        // step 11 ordering: length, name, prototype, then methods).
        var emitted_prototype = false;
        for (fn_str_keys.items) |key| {
            var ibuf: [16]u8 = undefined;
            const islice = std.fmt.bufPrint(&ibuf, "{d}", .{len}) catch unreachable;
            const idx_owned = realm.heap.allocateString(islice) catch return error.OutOfMemory;
            const k_owned = realm.heap.allocateString(key) catch return error.OutOfMemory;
            out.set(realm.allocator, idx_owned.flatBytes(), Value.fromString(k_owned)) catch return error.OutOfMemory;
            len += 1;
            if (!emitted_prototype and has_dedicated_prototype and std.mem.eql(u8, key, "name")) {
                var ibuf2: [16]u8 = undefined;
                const islice2 = std.fmt.bufPrint(&ibuf2, "{d}", .{len}) catch unreachable;
                const idx2 = realm.heap.allocateString(islice2) catch return error.OutOfMemory;
                const k2 = realm.heap.allocateString("prototype") catch return error.OutOfMemory;
                out.set(realm.allocator, idx2.flatBytes(), Value.fromString(k2)) catch return error.OutOfMemory;
                len += 1;
                emitted_prototype = true;
            }
        }
        // Edge case: `delete fn.name` removed the marker — surface
        // prototype at the end so the slot still appears.
        if (!emitted_prototype and has_dedicated_prototype) {
            var ibuf: [16]u8 = undefined;
            const islice = std.fmt.bufPrint(&ibuf, "{d}", .{len}) catch unreachable;
            const idx_owned = realm.heap.allocateString(islice) catch return error.OutOfMemory;
            const k_owned = realm.heap.allocateString("prototype") catch return error.OutOfMemory;
            out.set(realm.allocator, idx_owned.flatBytes(), Value.fromString(k_owned)) catch return error.OutOfMemory;
            len += 1;
        }
        out.set(realm.allocator, "length", Value.fromInt32(len)) catch return error.OutOfMemory;
        return heap_mod.taggedObject(out);
    }
    const obj = heap_mod.valueAsPlainObject(target) orelse return throwTypeError(realm, "Object.getOwnPropertyNames target is not an object");
    // §20.1.2.10 step 2 — `keys be ? O.[[OwnPropertyKeys]]()`. For
    // a Proxy receiver this MUST go through the `ownKeys` trap so
    // the §10.5.11 invariants (target keys + reported keys must
    // agree on configurable + non-extensible) fire before we
    // filter to strings. Mirrors `objectGetOwnPropertySymbols`.
    const key_scope = realm.heap.openScope() catch return error.OutOfMemory;
    defer key_scope.close();
    const keys = if (try proxyOwnKeysOrNull(realm, obj, key_scope)) |k| k else try ownPropertyKeysOrdered(realm, obj, key_scope);
    defer realm.allocator.free(keys);
    const out = realm.heap.allocateObject() catch return error.OutOfMemory;
    realm.heap.setObjectPrototype(out, realm.intrinsics.array_prototype);
    out.markAsArrayExotic(realm.allocator) catch return error.OutOfMemory;
    const scope = realm.heap.openScope() catch return error.OutOfMemory;
    defer scope.close();
    scope.push(target) catch return error.OutOfMemory;
    scope.push(heap_mod.taggedObject(out)) catch return error.OutOfMemory;
    var len: i32 = 0;
    for (keys) |key| {
        // §20.1.2.10 — string keys only. Symbol-property keys
        // (Cynic stores them as `@@<name>` for well-known and
        // `<sym:N>` for user-allocated) belong to
        // getOwnPropertySymbols.
        if (isSymbolKey(key)) continue;
        var ibuf: [16]u8 = undefined;
        const islice = std.fmt.bufPrint(&ibuf, "{d}", .{len}) catch unreachable;
        // `key` borrows the JSString buffer of an existing property
        // entry. The `allocateString` below can trigger GC; if that
        // GC reclaims `key`'s JSString and the next slab allocation
        // returns the same address, `realm.heap.allocateString(key)`
        // sees src == dst and panics on the @memcpy. Dupe onto the
        // realm allocator (not the GC heap) so the bytes survive any
        // intervening collection.
        const key_anchor = realm.allocator.dupe(u8, key) catch return error.OutOfMemory;
        defer realm.allocator.free(key_anchor);
        const idx_owned = realm.heap.allocateString(islice) catch return error.OutOfMemory;
        const k_owned = realm.heap.allocateString(key_anchor) catch return error.OutOfMemory;
        out.set(realm.allocator, idx_owned.flatBytes(), Value.fromString(k_owned)) catch return error.OutOfMemory;
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
pub fn isSymbolKey(key: []const u8) bool {
    return std.mem.startsWith(u8, key, "@@") or std.mem.startsWith(u8, key, "<sym:");
}

fn objectGetOwnPropertySymbols(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = this_value;
    const raw = argOr(args, 0, Value.undefined_);
    // §20.1.2.11 step 1 — `Let obj be ? ToObject(O)`. ES2015+
    // primitive-coerces the arg; primitive wrappers expose no
    // own symbol keys, so they return `[]` (test262
    // `non-object-argument-valid.js`). Function objects also
    // satisfy ToObject (they're ordinary objects per §6.1.7);
    // their property bag is the source of any symbol keys.
    const target = if (raw.isInt32() or raw.isDouble() or raw.isString() or raw.isBool() or heap_mod.isSymbol(raw) or heap_mod.isBigInt(raw))
        heap_mod.taggedObject(try intrinsics.toObjectThis(realm, raw))
    else
        raw;
    if (heap_mod.valueAsFunction(target)) |fn_obj| {
        const out = realm.heap.allocateObject() catch return error.OutOfMemory;
        realm.heap.setObjectPrototype(out, realm.intrinsics.array_prototype);
        out.markAsArrayExotic(realm.allocator) catch return error.OutOfMemory;
        const fscope = realm.heap.openScope() catch return error.OutOfMemory;
        defer fscope.close();
        fscope.push(heap_mod.taggedObject(out)) catch return error.OutOfMemory;
        var flen: i32 = 0;
        var fit = fn_obj.properties.iterator();
        while (fit.next()) |entry| {
            const key = entry.key_ptr.*;
            if (!isSymbolKey(key)) continue;
            const sym = realm.heap.symbolForKey(key) orelse continue;
            var ibuf: [16]u8 = undefined;
            const islice = std.fmt.bufPrint(&ibuf, "{d}", .{flen}) catch unreachable;
            const idx_owned = realm.heap.allocateString(islice) catch return error.OutOfMemory;
            out.set(realm.allocator, idx_owned.flatBytes(), heap_mod.taggedSymbol(sym)) catch return error.OutOfMemory;
            flen += 1;
        }
        out.set(realm.allocator, "length", Value.fromInt32(flen)) catch return error.OutOfMemory;
        return heap_mod.taggedObject(out);
    }
    const obj = heap_mod.valueAsPlainObject(target) orelse return throwTypeError(realm, "Object.getOwnPropertySymbols target is not an object");
    // §20.1.2.11 step 2 — `keys be ? O.[[OwnPropertyKeys]]()`. For
    // a Proxy receiver this MUST go through the `ownKeys` trap so
    // the invariants (target keys + reported keys must agree on
    // configurable+non-extensible) fire before we filter to
    // symbols. Mirrors `objectGetOwnPropertyNames` line 381.
    const key_scope = realm.heap.openScope() catch return error.OutOfMemory;
    defer key_scope.close();
    const keys = if (try proxyOwnKeysOrNull(realm, obj, key_scope)) |k| k else try ownPropertyKeysOrdered(realm, obj, key_scope);
    defer realm.allocator.free(keys);
    const out = realm.heap.allocateObject() catch return error.OutOfMemory;
    realm.heap.setObjectPrototype(out, realm.intrinsics.array_prototype);
    out.markAsArrayExotic(realm.allocator) catch return error.OutOfMemory;
    const scope = realm.heap.openScope() catch return error.OutOfMemory;
    defer scope.close();
    scope.push(target) catch return error.OutOfMemory;
    scope.push(heap_mod.taggedObject(out)) catch return error.OutOfMemory;
    var len: i32 = 0;
    for (keys) |key| {
        if (!isSymbolKey(key)) continue;
        // Recover the JSSymbol pointer from the heap's symbol
        // lists by exact prop_key match (linear scan over young +
        // mature; the lists tend to be small).
        const sym = realm.heap.symbolForKey(key) orelse continue;
        var ibuf: [16]u8 = undefined;
        const islice = std.fmt.bufPrint(&ibuf, "{d}", .{len}) catch unreachable;
        const idx_owned = realm.heap.allocateString(islice) catch return error.OutOfMemory;
        out.set(realm.allocator, idx_owned.flatBytes(), heap_mod.taggedSymbol(sym)) catch return error.OutOfMemory;
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
        realm.heap.setObjectPrototype(obj, null);
    } else if (heap_mod.valueAsPlainObject(proto_v)) |p| {
        realm.heap.setObjectPrototype(obj, p);
    } else if (heap_mod.valueAsFunction(proto_v)) |fn_obj| {
        // §10.2 — a function IS an object and can be a prototype;
        // the chain hops through the function's own properties and
        // on into %Function.prototype%.
        realm.heap.setObjectPrototypeFn(obj, fn_obj);
    } else {
        return throwTypeError(realm, "Object.create prototype must be an Object or null");
    }
    // §20.1.2.2 Object.create step 3 — `If Properties is not
    // undefined, then Return ? ObjectDefineProperties(obj, Properties)`.
    // Delegate to the shared `Object.defineProperties` path so the
    // spec's `Let props be ? ToObject(Properties)` (step 2 of
    // §20.1.2.3.1 ObjectDefineProperties) fires the TypeError for
    // `null`, and primitive-string wrappers' own enumerable indexed
    // characters get walked into ToPropertyDescriptor (which throws
    // on the first non-object descObj — `Object.create({}, 'h')`
    // sees descObj === 'h' for the first index).
    if (args.len > 1 and !args[1].isUndefined()) {
        // Root the freshly allocated object across
        // `objectDefineProperties`, which re-enters JS (descriptor
        // getters) and allocates — a GC there would otherwise sweep
        // `obj`, held only on the Zig stack.
        const scope = realm.heap.openScope() catch return error.OutOfMemory;
        defer scope.close();
        scope.push(heap_mod.taggedObject(obj)) catch return error.OutOfMemory;
        const dp_args = [_]Value{ heap_mod.taggedObject(obj), args[1] };
        _ = try objectDefineProperties(realm, Value.undefined_, &dp_args);
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
    const lantern = @import("../lantern/interpreter.zig");
    const allocator = realm.allocator;
    const key = key_string.flatBytes();
    // §10.1.9.2 — accessor descriptor on the receiver or its
    // proto chain wins. A getter-only accessor (no `set`) is a
    // TypeError under strict-mode Set.
    if (lantern.lookupAccessor(target, key)) |acc| {
        if (acc.setter) |setter| {
            const setter_args = [_]Value{value};
            const outcome = lantern.callJSFunction(allocator, realm, setter, heap_mod.taggedObject(target), &setter_args) catch |err| switch (err) {
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
    const had_entry = target.ownDataContains(key);
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
        // §10.4.2.4 ArraySetLength — an Array exotic's "length"
        // write is NOT a plain data update: shrinking it must
        // delete the indexed slots beyond the new length, growing
        // it must reserve holes. A bare `properties.put` bypasses
        // the truncate and leaves stale element data behind, so a
        // later index write past the old (smaller) length resurrects
        // the dropped values (Object/assign/target-Array fixture
        // observes this via `Object.assign(target, {length: 1})`).
        if (target.is_array_exotic and std.mem.eql(u8, key, "length")) {
            // §10.4.2.4 ArraySetLength — coerce to uint32 via §7.1.6
            // ToUint32, then truncate / grow the indexed backing,
            // then sync the `length` property.
            const arith = @import("../lantern/arith.zig");
            const new_len: u32 = arith.toUint32(value);
            const tr = lantern.truncateArrayAtLength(allocator, target, new_len);
            target.setArrayLength(allocator, tr.final_length) catch return error.OutOfMemory;
            if (tr.blocked) {
                return throwTypeError(realm, "Cannot delete non-configurable array index");
            }
            return;
        }
        // Route through `setWithFlags` — shape and bag stay
        // coherent under Phase 3 of [docs/lazy-property-bag.md].
        target.setWithFlags(allocator, key, value, flags) catch return error.OutOfMemory;
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
    // Root the receiver across every source's key loop — each source
    // fires accessor getters (`getPropertyChain`) and strict setters
    // (`assignSetOrThrow`) that re-enter JS and allocate, so an
    // unrooted `target` would be swept by an allocation-pressure GC
    // and the next `assignSetOrThrow` would write through freed memory.
    const target_scope = realm.heap.openScope() catch return error.OutOfMemory;
    defer target_scope.close();
    target_scope.push(heap_mod.taggedObject(target)) catch return error.OutOfMemory;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const src_v = args[i];
        // §20.1.2.1 step 4.a — `if nextSource is undefined or null, skip`.
        // All other primitives (and Functions) ToObject and contribute
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
        // §20.1.2.1 step 4.a.ii — `keys = ? from.[[OwnPropertyKeys]]()`.
        // Route through `proxyOwnKeysOrNull` so a Proxy's `ownKeys`
        // trap fires with the §10.5.11 invariants enforced. Falls
        // back to the ordinary keys when `src` isn't a proxy.
        const key_scope = realm.heap.openScope() catch return error.OutOfMemory;
        defer key_scope.close();
        const keys = if (try proxyOwnKeysOrNull(realm, src, key_scope)) |k| k else try ownPropertyKeysOrdered(realm, src, key_scope);
        defer realm.allocator.free(keys);
        const src_value: Value = heap_mod.taggedObject(src);
        for (keys) |key| {
            if (std.mem.startsWith(u8, key, "__cynic_")) continue;
            // §20.1.2.1 step 4.a.iii.1 — `desc = ? from.[[GetOwnProperty]](nextKey)`.
            // For a Proxy this fires `getOwnPropertyDescriptor`; for
            // a plain object it returns the own descriptor (or
            // undefined when the key vanished between OwnPropertyKeys
            // and now). Use objectGetOwnPropertyDescriptor so the
            // Proxy invariants and abrupt completions propagate.
            const key_string = realm.heap.allocateString(key) catch return error.OutOfMemory;
            // Root the key string across the descriptor lookup, the
            // getter, and the strict setter below — all re-enter JS /
            // allocate and would otherwise free it mid-copy.
            key_scope.push(Value.fromString(key_string)) catch return error.OutOfMemory;
            const desc_args = [_]Value{ src_value, Value.fromString(key_string) };
            const desc_v = try objectGetOwnPropertyDescriptor(realm, Value.undefined_, &desc_args);
            // §20.1.2.1 step 4.a.iii.2 — only act when `desc` is not
            // undefined AND `desc.[[Enumerable]]` is true.
            if (desc_v.isUndefined()) continue;
            const desc_obj = heap_mod.valueAsPlainObject(desc_v) orelse continue;
            const enum_v = desc_obj.get("enumerable");
            if (!intrinsics.toBoolean(enum_v)) continue;
            // §20.1.2.1 step 4.a.iii.2.a — `propValue = ? Get(from, nextKey)`.
            // This fires accessor getters AND Proxy `get` traps; the
            // proxy chain must dispatch via the handler so e.g. an
            // `ownKeys`-spoofing handler observes the read.
            const v = blk_v: {
                var cur_get: *JSObject = src;
                while (cur_get.proxy_target != null or cur_get.proxy_revoked) {
                    const proxy_mod = @import("proxy.zig");
                    const r = try proxy_mod.nativeProxyGet(realm, cur_get, key, src_value, null);
                    switch (r) {
                        .value => |val| break :blk_v val,
                        .fallthrough => |t| {
                            if (t == cur_get) break;
                            cur_get = t;
                        },
                    }
                }
                break :blk_v try getPropertyChain(realm, cur_get, key);
            };
            // The getter's result is reachable through nothing yet —
            // root it across the strict setter's re-entry / allocation.
            key_scope.push(v) catch return error.OutOfMemory;
            // §20.1.2.1 step 4.a.iii.2.b — `Set(to, nextKey, propValue, true)`.
            // Strict-mode Set per §10.1.9 throws TypeError on any
            // failure (non-extensible + new key, non-writable own
            // data, getter-only accessor, setter throw).
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
    const key_scope = realm.heap.openScope() catch return error.OutOfMemory;
    defer key_scope.close();
    const keys = (try proxyOwnKeysOrNull(realm, target, key_scope)) orelse try ownPropertyKeysOrdered(realm, target, key_scope);
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
        realm.heap.setObjectPrototype(desc_obj, realm.intrinsics.object_prototype);
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
    const key_scope = realm.heap.openScope() catch return error.OutOfMemory;
    defer key_scope.close();
    const keys = (try proxyOwnKeysOrNull(realm, target_obj, key_scope)) orelse try ownPropertyKeysOrdered(realm, target_obj, key_scope);
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
    // §20.1.2.5 step 1 — If Type(O) is not Object, return O. The
    // Function-object path (§6.1.7) mirrors the JSObject path
    // below: drop `extensible` and stamp w=false/c=false on every
    // own property.
    if (heap_mod.valueAsFunction(arg)) |fn_obj| {
        fn_obj.extensible = false;
        var fit = fn_obj.properties.iterator();
        while (fit.next()) |entry| {
            const key = entry.key_ptr.*;
            const cur = fn_obj.flagsForOwn(key);
            fn_obj.property_flags.put(realm.allocator, key, .{
                .writable = false,
                .enumerable = cur.enumerable,
                .configurable = false,
            }) catch return error.OutOfMemory;
        }
        var fait = fn_obj.accessors.iterator();
        while (fait.next()) |entry| {
            const key = entry.key_ptr.*;
            const cur = fn_obj.flagsForOwn(key);
            fn_obj.property_flags.put(realm.allocator, key, .{
                .writable = false,
                .enumerable = cur.enumerable,
                .configurable = false,
            }) catch return error.OutOfMemory;
        }
        return arg;
    }
    const obj = heap_mod.valueAsPlainObject(arg) orelse return arg; // §20.1.2.5 — primitives pass through
    // §9.4.6.8 Module Namespace Exotic [[DefineOwnProperty]] — a
    // module namespace's exported data bindings ship with
    // `{w:true, e:true, c:false}`. `SetIntegrityLevel(O, "frozen")`
    // (§7.3.20) calls `DefinePropertyOrThrow(O, k,
    // {configurable: false, writable: false})` on each own key; the
    // exotic accepts a redefine only when it SameValue-matches the
    // existing descriptor, so flipping `writable` to false rejects
    // and `DefinePropertyOrThrow` raises TypeError. The fixture
    // (`namespace/internals/define-own-property.js`) asserts
    // `Object.freeze(ns)` throws and `desc.writable` survives as
    // `true`. Short-circuit here so we don't run the loop below
    // (which would lower the flags in-place and silently succeed).
    if (obj.is_module_namespace) {
        realm.define_own_property_rejected = true;
        return throwTypeError(realm, "Cannot freeze module namespace");
    }
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
    if (obj.getTypedView()) |tv| {
        if (tv.viewed.getArrayBufferMaxByteLength() != null) {
            return throwTypeError(realm, "Cannot freeze TypedArray backed by resizable buffer");
        }
    }
    obj.extensible = false;
    // §10.4.2 — for Array exotic objects, indexed elements live
    // in `obj.elements` (or `sparse_elements`) and default to
    // `{w:true, e:true, c:true}`. SetIntegrityLevel(O, frozen)
    // must lower them to `{w:false, e:true, c:false}`; promote
    // each present indexed slot into `property_flags` keyed by
    // the canonical index string so subsequent `flagsFor` reads
    // see the override. Same dance for `seal` (configurable
    // only).
    try freezeArrayIndexedSlots(realm, obj);
    // §23.1.4 — the array exotic's virtual `length` carries its
    // [[Writable]] in the dedicated bit, not in `property_flags`;
    // freezing must clear it or `push` past the frozen length
    // would still extend. (Seal leaves writability alone, and
    // `length` is already non-configurable, so seal needs nothing.)
    if (obj.is_array_exotic) obj.array_length_writable = false;
    // §10.1.4.1 SetIntegrityLevel(O, frozen) — mark every own
    // data property `{ writable: false, configurable: false }`
    // and every accessor `{ configurable: false }`. The shape
    // encodes per-key attrs on the transition node, so flipping
    // them via `property_flags.put` alone wouldn't be observed
    // by `flagsFor` (shape-first under Phase 3 of
    // [docs/lazy-property-bag.md]). Demote to dictionary mode
    // first so subsequent reads pick up the bag overrides —
    // frozen objects don't take further writes, so losing the
    // shape costs nothing.
    obj.demoteFromShape(realm.allocator) catch return error.OutOfMemory;
    var it = obj.iterOwnNamedKeys();
    while (it.next()) |entry| {
        const key = entry.key_ptr.*;
        const cur = obj.flagsFor(key);
        obj.property_flags.put(realm.allocator, key, .{
            .writable = false,
            .enumerable = cur.enumerable,
            .configurable = false,
        }) catch return error.OutOfMemory;
    }
    if (obj.accessorIterator()) |ait_outer| {
        var ait = ait_outer;
        while (ait.next()) |entry| {
            const key = entry.key_ptr.*;
            const cur = obj.flagsFor(key);
            obj.property_flags.put(realm.allocator, key, .{
                .writable = false, // N/A on accessors; spec says omitted.
                .enumerable = cur.enumerable,
                .configurable = false,
            }) catch return error.OutOfMemory;
        }
    }
    return arg;
}

/// Promote Array-exotic indexed elements to the named-property
/// bag with `{w:false, e:true, c:false}` (frozen) or
/// `{w:true, e:true, c:false}` (sealed). Required because
/// indexed slots default to `{w,e,c}=true` and the spec wants
/// per-index descriptor overrides after SetIntegrityLevel. The
/// `is_sealed` flag selects between the two patterns.
fn lowerArrayIndexedFlags(realm: *Realm, obj: *JSObject, sealed_only: bool) NativeError!void {
    if (!obj.is_array_exotic) return;
    const flags: ObjMod.PropertyFlags = .{
        .writable = sealed_only,
        .enumerable = true,
        .configurable = false,
    };
    // §10.4.2 — `setWithFlags` with a non-default descriptor
    // demotes the indexed slot to the property bag (and holes
    // the original `elements[idx]`) so the override flags
    // survive lookups via `flagsFor`. Snapshot the indices first
    // so we don't iterate while mutating.
    var indices: std.ArrayListUnmanaged(u32) = .empty;
    defer indices.deinit(realm.allocator);
    if (obj.is_sparse) {
        var sit = obj.sparse_elements.iterator();
        while (sit.next()) |entry| {
            if (JSObject.isElementHole(entry.value_ptr.*)) continue;
            try indices.append(realm.allocator, entry.key_ptr.*);
        }
    } else {
        var i: u32 = 0;
        while (i < obj.elements.items.len) : (i += 1) {
            if (JSObject.isElementHole(obj.elements.items[i])) continue;
            try indices.append(realm.allocator, i);
        }
    }
    for (indices.items) |idx| {
        var ibuf: [16]u8 = undefined;
        const ks = std.fmt.bufPrint(&ibuf, "{d}", .{idx}) catch continue;
        const ks_owned = realm.heap.allocateString(ks) catch return error.OutOfMemory;
        // Read the current value via the public getter so we
        // pull from either the packed elements or a previously-
        // bag-promoted slot.
        const v = obj.getIndexed(idx);
        obj.setWithFlags(realm.allocator, ks_owned.flatBytes(), v, flags) catch return error.OutOfMemory;
        // The non-default descriptor demotes the slot into the
        // named-property bag, which borrows the `ks_owned` slice;
        // anchor the heap key string so a GC sweep can't dangle it.
        if (obj.ownDataContains(ks_owned.flatBytes())) {
            obj.anchorKey(realm.allocator, ks_owned) catch return error.OutOfMemory;
            obj.markNonPristine();
        }
    }
}

fn freezeArrayIndexedSlots(realm: *Realm, obj: *JSObject) NativeError!void {
    try lowerArrayIndexedFlags(realm, obj, false);
}

fn sealArrayIndexedSlots(realm: *Realm, obj: *JSObject) NativeError!void {
    try lowerArrayIndexedFlags(realm, obj, true);
}

fn objectIsFrozen(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = this_value;
    const arg = argOr(args, 0, Value.undefined_);
    // §6.1.7 — function objects are ordinary objects. After
    // `Object.freeze(fn)` they must report `isFrozen === true`.
    // `%ThrowTypeError%` ships pre-frozen (§10.2.4).
    if (heap_mod.valueAsFunction(arg)) |fn_obj| {
        if (realm.intrinsics.throw_type_error) |tt| {
            if (fn_obj == tt) return Value.true_;
        }
        if (fn_obj.extensible) return Value.false_;
        var fit = fn_obj.properties.iterator();
        while (fit.next()) |entry| {
            const flags = fn_obj.flagsForOwn(entry.key_ptr.*);
            if (flags.writable or flags.configurable) return Value.false_;
        }
        var fait = fn_obj.accessors.iterator();
        while (fait.next()) |entry| {
            if (fn_obj.flagsForOwn(entry.key_ptr.*).configurable) return Value.false_;
        }
        return Value.true_;
    }
    const obj = heap_mod.valueAsPlainObject(arg) orelse return Value.true_; // primitives are frozen
    if (obj.proxy_target != null or obj.proxy_revoked) {
        return testIntegrityLevelViaProxy(realm, arg, obj, true);
    }
    if (obj.extensible) return Value.false_;
    // §10.4.2 — Array exotic indexed elements default to all-
    // true. A present indexed slot that's NOT been lowered into
    // the property bag is still writable+configurable, so the
    // array can't be frozen.
    if (hasUnlockedIndexedElements(obj)) return Value.false_;
    var it = obj.iterOwnNamedKeys();
    while (it.next()) |entry| {
        const flags = obj.flagsFor(entry.key_ptr.*);
        if (flags.writable or flags.configurable) return Value.false_;
    }
    // Accessor descriptors only need `configurable: false` to be
    // frozen; `writable` is N/A on accessors.
    if (obj.accessorIterator()) |ait_outer| {
        var ait = ait_outer;
        while (ait.next()) |entry| {
            const flags = obj.flagsFor(entry.key_ptr.*);
            if (flags.configurable) return Value.false_;
        }
    }
    return Value.true_;
}

fn objectSeal(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = this_value;
    const arg = argOr(args, 0, Value.undefined_);
    // §20.1.2.20 step 1 — If Type(O) is not Object, return O. For
    // Function objects (§6.1.7) we have to seal too: drop
    // `extensible` and loop the own properties stamping
    // configurable=false. Mirrors the JSObject path below.
    if (heap_mod.valueAsFunction(arg)) |fn_obj| {
        fn_obj.extensible = false;
        var fit = fn_obj.properties.iterator();
        while (fit.next()) |entry| {
            const key = entry.key_ptr.*;
            const cur = fn_obj.flagsForOwn(key);
            fn_obj.property_flags.put(realm.allocator, key, .{
                .writable = cur.writable,
                .enumerable = cur.enumerable,
                .configurable = false,
            }) catch return error.OutOfMemory;
        }
        var fait = fn_obj.accessors.iterator();
        while (fait.next()) |entry| {
            const key = entry.key_ptr.*;
            const cur = fn_obj.flagsForOwn(key);
            fn_obj.property_flags.put(realm.allocator, key, .{
                .writable = cur.writable,
                .enumerable = cur.enumerable,
                .configurable = false,
            }) catch return error.OutOfMemory;
        }
        return arg;
    }
    const obj = heap_mod.valueAsPlainObject(arg) orelse return arg;
    if (obj.proxy_target != null or obj.proxy_revoked) {
        return setIntegrityLevelViaProxy(realm, arg, obj, false);
    }
    obj.extensible = false;
    // §10.4.2 — Array exotic indexed elements default to all-
    // true; lower to `{w:true, e:true, c:false}` for sealed.
    try sealArrayIndexedSlots(realm, obj);
    // §10.1.4.1 SetIntegrityLevel(O, sealed) — every own property
    // (data + accessor) loses configurability; writable bits
    // stay. Demote shape first so the `property_flags` bag is
    // authoritative — see the matching note in `objectFreeze`.
    obj.demoteFromShape(realm.allocator) catch return error.OutOfMemory;
    var it = obj.iterOwnNamedKeys();
    while (it.next()) |entry| {
        const key = entry.key_ptr.*;
        const cur = obj.flagsFor(key);
        obj.property_flags.put(realm.allocator, key, .{
            .writable = cur.writable,
            .enumerable = cur.enumerable,
            .configurable = false,
        }) catch return error.OutOfMemory;
    }
    if (obj.accessorIterator()) |ait_outer| {
        var ait = ait_outer;
        while (ait.next()) |entry| {
            const key = entry.key_ptr.*;
            const cur = obj.flagsFor(key);
            obj.property_flags.put(realm.allocator, key, .{
                .writable = cur.writable,
                .enumerable = cur.enumerable,
                .configurable = false,
            }) catch return error.OutOfMemory;
        }
    }
    return arg;
}

fn objectIsSealed(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = this_value;
    const arg = argOr(args, 0, Value.undefined_);
    // §6.1.7 — function objects are ordinary objects. After
    // `Object.seal(fn)` they must report `isSealed === true`.
    // `%ThrowTypeError%` ships pre-sealed (§10.2.4).
    if (heap_mod.valueAsFunction(arg)) |fn_obj| {
        if (realm.intrinsics.throw_type_error) |tt| {
            if (fn_obj == tt) return Value.true_;
        }
        if (fn_obj.extensible) return Value.false_;
        var fit = fn_obj.properties.iterator();
        while (fit.next()) |entry| {
            if (fn_obj.flagsForOwn(entry.key_ptr.*).configurable) return Value.false_;
        }
        var fait = fn_obj.accessors.iterator();
        while (fait.next()) |entry| {
            if (fn_obj.flagsForOwn(entry.key_ptr.*).configurable) return Value.false_;
        }
        return Value.true_;
    }
    const obj = heap_mod.valueAsPlainObject(arg) orelse return Value.true_;
    if (obj.proxy_target != null or obj.proxy_revoked) {
        return testIntegrityLevelViaProxy(realm, arg, obj, false);
    }
    if (obj.extensible) return Value.false_;
    // §10.4.2 — Array exotic indexed slots default to all-true;
    // an array with raw indexed elements isn't sealed.
    if (hasUnlockedIndexedElements(obj)) return Value.false_;
    var it = obj.iterOwnNamedKeys();
    while (it.next()) |entry| {
        if (obj.flagsFor(entry.key_ptr.*).configurable) return Value.false_;
    }
    if (obj.accessorIterator()) |ait_outer| {
        var ait = ait_outer;
        while (ait.next()) |entry| {
            if (obj.flagsFor(entry.key_ptr.*).configurable) return Value.false_;
        }
    }
    return Value.true_;
}

/// `true` iff `obj` is an Array exotic with at least one
/// present indexed slot whose descriptor hasn't been lowered
/// into the property bag. Indexed slots in `obj.elements` /
/// `obj.sparse_elements` default to `{w,e,c} = true` (per
/// §10.4.2) — `isSealed` / `isFrozen` must observe that as
/// "not sealed" until SetIntegrityLevel promotes the slots.
fn hasUnlockedIndexedElements(obj: *JSObject) bool {
    if (!obj.is_array_exotic) return false;
    if (obj.is_sparse) {
        var sit = obj.sparse_elements.iterator();
        while (sit.next()) |entry| {
            if (JSObject.isElementHole(entry.value_ptr.*)) continue;
            var ibuf: [16]u8 = undefined;
            const ks = std.fmt.bufPrint(&ibuf, "{d}", .{entry.key_ptr.*}) catch return true;
            // Slot present and not yet promoted into the bag.
            if (!obj.ownDataContains(ks)) return true;
        }
        return false;
    }
    var i: u32 = 0;
    while (i < obj.elements.items.len) : (i += 1) {
        if (JSObject.isElementHole(obj.elements.items[i])) continue;
        var ibuf: [16]u8 = undefined;
        const ks = std.fmt.bufPrint(&ibuf, "{d}", .{i}) catch return true;
        if (!obj.ownDataContains(ks)) return true;
    }
    return false;
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
    const lantern = @import("../lantern/interpreter.zig");
    const trap_args = [_]Value{heap_mod.taggedObject(proxy_target)};
    const outcome = lantern.callJSFunction(realm.allocator, realm, trap_fn, heap_mod.taggedObject(handler), &trap_args) catch |err| switch (err) {
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
    // §9.4.6.3 [[IsExtensible]] for a Module Namespace exotic
    // always returns `false` — irrespective of whether
    // `getModuleNamespace` has finalised the brand bag yet.
    // A cycle that re-enters the entry module observes the
    // partial namespace mid-evaluation; the spec still requires
    // [[IsExtensible]] = false there.
    if (obj.is_module_namespace) return Value.false_;
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
            const lantern = @import("../lantern/interpreter.zig");
            const trap_args = [_]Value{heap_mod.taggedObject(proxy_target)};
            const outcome = lantern.callJSFunction(realm.allocator, realm, trap_fn, heap_mod.taggedObject(handler), &trap_args) catch |err| switch (err) {
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
    const lantern = @import("../lantern/interpreter.zig");
    const iter = lantern.openIterator(realm.allocator, realm, argOr(args, 0, Value.undefined_)) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return throwTypeError(realm, "Object.fromEntries argument is not iterable"),
    };
    const iter_obj = heap_mod.valueAsPlainObject(iter) orelse return throwTypeError(realm, "Object.fromEntries argument is not iterable");
    // Root the iterator BEFORE allocating `out`: `allocateObject`
    // GCs under allocation pressure and would otherwise sweep the
    // freshly-opened, still-unrooted iterator — the first loop
    // step's `next_fn` call would then dereference poison.
    const scope = realm.heap.openScope() catch return error.OutOfMemory;
    defer scope.close();
    scope.push(iter) catch return error.OutOfMemory;
    const next_v = iter_obj.get("next");
    const next_fn = heap_mod.valueAsFunction(next_v) orelse return throwTypeError(realm, "iterator.next is not callable");

    const out = realm.heap.allocateObject() catch return error.OutOfMemory;
    realm.heap.setObjectPrototype(out, realm.intrinsics.object_prototype);
    // Root the result across the iteration loop — every `next()` /
    // accessor read re-enters JS and allocates.
    scope.push(heap_mod.taggedObject(out)) catch return error.OutOfMemory;
    const scope_base = scope.handles.items.len;

    const max_iter: i64 = 1 << 24;
    var i: i64 = 0;
    while (i < max_iter) : (i += 1) {
        // §7.4.2 IteratorNext — throwing `next()` does NOT close;
        // the iterator is already "done" per §7.4.6 step 6.b.
        const step = lantern.callJSFunction(realm.allocator, realm, next_fn, iter, &.{}) catch |err| switch (err) {
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
        // §7.4.2 step 3 — result must be Object. NOT a close case:
        // the spec returns ? IteratorNext throw, which surfaces
        // without invoking return.
        const result = heap_mod.valueAsPlainObject(result_v) orelse return throwTypeError(realm, "iterator next result is not an object");
        // Root the result object across the `done` / `value` reads —
        // either can be an accessor (evaluation-order.js) that
        // re-enters JS and GCs, freeing this still-unrooted object.
        scope.push(result_v) catch return error.OutOfMemory;
        // §7.4.5 IteratorComplete uses Get() — a throwing
        // `get done()` IS a close case per §7.4.6.
        const done_v = getPropertyChain(realm, result, "done") catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                invokeFromEntriesReturn(realm, iter_obj, iter);
                return error.NativeThrew;
            },
        };
        if (toBoolean(done_v)) break;
        // §7.4.4 IteratorValue — throwing `get value()` closes.
        const pair_v = getPropertyChain(realm, result, "value") catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                invokeFromEntriesReturn(realm, iter_obj, iter);
                return error.NativeThrew;
            },
        };
        // §20.1.2.6 step (AddEntriesFromIterable) — if entry is
        // not Object, IteratorClose with TypeError completion.
        const pair = heap_mod.valueAsPlainObject(pair_v) orelse {
            invokeFromEntriesReturn(realm, iter_obj, iter);
            return throwTypeError(realm, "Object.fromEntries entry must be an object");
        };
        // Root the entry object — its `get '0'` / `get '1'` accessors
        // (evaluation-order.js) re-enter JS, and `pair` is read twice.
        scope.push(pair_v) catch return error.OutOfMemory;
        // §7.3.5 Get — accessor getters on key/value can throw;
        // close the iterator on throw.
        const k = getPropertyChain(realm, pair, "0") catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                invokeFromEntriesReturn(realm, iter_obj, iter);
                return error.NativeThrew;
            },
        };
        // Root `k` BEFORE reading "1": a `get '1'` accessor re-enters
        // JS and GCs, and `k` (an object key whose `toString` runs
        // later in `propertyKeyForFromEntries`) is otherwise unrooted
        // between the two reads — evaluation-order.js freed it here,
        // then ToString dereferenced poison.
        scope.push(k) catch return error.OutOfMemory;
        const v = getPropertyChain(realm, pair, "1") catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                invokeFromEntriesReturn(realm, iter_obj, iter);
                return error.NativeThrew;
            },
        };
        // Root the value across `propertyKeyForFromEntries` — its
        // ToString re-enters JS (the key's `toString`) and a GC there
        // would otherwise collect `v` before it is stored into `out`.
        scope.push(v) catch return error.OutOfMemory;
        // §7.1.19 ToPropertyKey — Symbol keys preserve as Symbol
        // (Cynic stores them as `<sym:N>` / `@@<name>`); other
        // values coerce to String via ToString. A throwing
        // ToString (e.g. `Symbol → @@toPrimitive` overrides) is
        // a close case.
        const key_slot = propertyKeyForFromEntries(realm, k) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                invokeFromEntriesReturn(realm, iter_obj, iter);
                return error.NativeThrew;
            },
        };
        // §20.1.2.6 — CreateDataPropertyOrThrow installs as
        // `{w:true, e:true, c:true}` (the bag default).
        out.set(realm.allocator, key_slot.key, v) catch return error.OutOfMemory;
        // Anchor the heap key string so the borrowed slice survives.
        if (key_slot.anchor) |ks| {
            if (out.ownDataContains(key_slot.key)) {
                out.anchorKey(realm.allocator, ks) catch return error.OutOfMemory;
                out.markNonPristine();
            }
        }
        // `v` is now reachable via `out`; drop the per-iteration
        // handles so the scope can't grow unboundedly.
        scope.handles.shrinkRetainingCapacity(scope_base);
    }
    return heap_mod.taggedObject(out);
}

/// §7.4.6 IteratorClose specialised for `Object.fromEntries` —
/// invoke `iter.return()` if present; suppress a throw from
/// `return` itself (step 7: "If completion is throw, return
/// completion"). The pre-existing pending exception is what
/// propagates upward.
fn invokeFromEntriesReturn(realm: *Realm, iter_obj: *JSObject, iter_v: Value) void {
    const lantern = @import("../lantern/interpreter.zig");
    const ret_v = intrinsics.getPropertyChain(realm, iter_obj, "return") catch return;
    if (ret_v.isUndefined() or ret_v.isNull()) return;
    const ret_fn = heap_mod.valueAsFunction(ret_v) orelse return;
    const saved_ex = realm.pending_exception;
    const outcome = lantern.callJSFunction(realm.allocator, realm, ret_fn, iter_v, &.{}) catch {
        realm.pending_exception = saved_ex;
        return;
    };
    realm.pending_exception = saved_ex;
    _ = outcome;
}

/// §7.1.19 ToPropertyKey for `Object.fromEntries` — preserves
/// Symbol keys (Cynic flattens to `<sym:N>` / `@@<name>`) and
/// ToString-coerces the rest. Returns a slice valid for the
/// realm's lifetime (heap-allocated JSString.flatBytes()).
fn propertyKeyForFromEntries(realm: *Realm, k: Value) NativeError!DescKey {
    // Symbol primitive — Cynic stores as a `*JSSymbol` whose
    // `prop_key` is the `<sym:N>` / `@@<descr>` slot key.
    if (heap_mod.valueAsSymbol(k)) |sym| {
        return .{ .key = sym.prop_key, .anchor = null };
    }
    if (k.isString()) {
        const s: *JSString = @ptrCast(@alignCast(k.asString()));
        return .{ .key = s.flatBytes(), .anchor = s };
    }
    const s = try stringifyArg(realm, k);
    return .{ .key = s.flatBytes(), .anchor = s };
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
    // §7.3.11 GetMethod — uses [[Get]] which fires accessors. A
    // handler installed with `Object.defineProperty(h, "trapName",
    // {get})` must run that getter (which may throw).
    const trap_v = try intrinsics.getPropertyChain(realm, handler, "setPrototypeOf");
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
    const lantern = @import("../lantern/interpreter.zig");
    const trap_args = [_]Value{ heap_mod.taggedObject(proxy_target), proto_v };
    const outcome = lantern.callJSFunction(realm.allocator, realm, trap_fn, heap_mod.taggedObject(handler), &trap_args) catch |err| switch (err) {
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
        const new_proto: ?*@import("../object.zig").JSObject = heap_mod.valueAsPlainObject(proto_v);
        const new_proto_fn: ?*@import("../function.zig").JSFunction = heap_mod.valueAsFunction(proto_v);
        // §10.4.7 — `%Object.prototype%` is an Immutable Prototype
        // Exotic Object: [[SetPrototypeOf]] only succeeds if the
        // new value SameValue's the current one. Object.setPrototypeOf
        // then translates the `false` return into TypeError.
        if (obj == realm.intrinsics.object_prototype.?) {
            if (new_proto != obj.prototype or new_proto_fn != obj.prototype_fn) {
                return throwTypeError(realm, "Immutable prototype object cannot have its prototype set");
            }
            return target_v;
        }
        // §10.1.2.1 OrdinarySetPrototypeOf step 3 — when
        // `extensible` is false the new prototype MUST SameValue
        // the current one; otherwise return false and let
        // Object.setPrototypeOf rethrow. Module Namespace exotics
        // §9.4.6.1 Module Namespace exotics are always non-extensible
        // with prototype === null, irrespective of whether the
        // `extensible` slot has been finalised yet during a cycle.
        // Treat `is_module_namespace` as the authoritative
        // IsExtensible-false signal here so a `Object.setPrototypeOf
        // (ns, anything)` always rejects per the spec.
        if (!obj.extensible or obj.is_module_namespace) {
            if (new_proto != obj.prototype or new_proto_fn != obj.prototype_fn) {
                return throwTypeError(realm, "Cannot set prototype on non-extensible object");
            }
            return target_v;
        }
        // Cycle check walks through function links too: a function
        // node itself can't equal `obj` (different heap types), but
        // the chain continues through its `proto`.
        var cursor: ?*@import("../object.zig").JSObject = new_proto orelse if (new_proto_fn) |pf| pf.proto else null;
        while (cursor) |node| {
            if (node == obj) {
                return throwTypeError(realm, "cyclic __proto__ value");
            }
            cursor = node.prototype orelse if (node.prototype_fn) |pf| pf.proto else null;
        }
        if (new_proto_fn) |pf| {
            realm.heap.setObjectPrototypeFn(obj, pf);
        } else {
            realm.heap.setObjectPrototype(obj, new_proto);
        }
        // §10.1.2.1 — every cached IC cell that resolved through
        // the prototype chain may now point at a stale link. Bump
        // the revision counter so all proto-load cells miss + refill
        // on their next access.
        realm.proto_revision_counter +%= 1;
    } else if (heap_mod.valueAsFunction(target_v)) |target_fn| {
        // §10.1.2.1 OrdinarySetPrototypeOf on a JSFunction target.
        // Cynic stores the function's [[Prototype]] edge on
        // `static_parent` (function-typed) and `proto`
        // (JSObject-typed) — write to both so subsequent walks via
        // either slot pick up the new value. This unblocks
        // `Object.setPrototypeOf(C, X)` retargeting `super(...)`
        // from inside a class extending C (the GetSuperConstructor
        // walk reads `static_parent`).
        const new_static_parent: ?*@import("../function.zig").JSFunction =
            heap_mod.valueAsFunction(proto_v);
        const new_proto_obj: ?*@import("../object.zig").JSObject = blk: {
            if (proto_v.isNull()) break :blk null;
            if (heap_mod.valueAsPlainObject(proto_v)) |p| break :blk p;
            // For a function-typed proto, point `proto` at the
            // parent function's own prototype object so property
            // lookups through the proto chain still resolve. The
            // function identity itself lives on `static_parent`.
            if (heap_mod.valueAsFunction(proto_v)) |fn_obj| break :blk fn_obj.prototype;
            break :blk null;
        };
        target_fn.static_parent = new_static_parent;
        target_fn.proto = new_proto_obj;
        // Function-target [[Prototype]] swap — bump the proto IC
        // revision so dependent caches miss + refill.
        realm.proto_revision_counter +%= 1;
    }
    return target_v;
}

/// §22.1.2.5 Object.groupBy(items, callbackfn) — partition `items`
/// into a null-prototype object keyed by `callbackfn(item, index)`.
/// Each bucket is an Array of the items that produced that key.
fn objectGroupBy(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = this_value;
    const lantern = @import("../lantern/interpreter.zig");
    const items_v = argOr(args, 0, Value.undefined_);
    const cb_v = argOr(args, 1, Value.undefined_);
    const cb = heap_mod.valueAsFunction(cb_v) orelse return throwTypeError(realm, "Object.groupBy callback is not callable");

    // Open the root scope FIRST: `openIterator` and every allocation
    // below GC under pressure, so the iterator and the result object
    // must be rooted before any sweep can reach them while unrooted.
    // (Allocating `out` before `openIterator` while `out` was still
    // unrooted let the iterator allocation's sweep free the half-built
    // result.)
    const scope = realm.heap.openScope() catch return error.OutOfMemory;
    defer scope.close();

    const iter = lantern.openIterator(realm.allocator, realm, items_v) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return throwTypeError(realm, "Object.groupBy items is not iterable"),
    };
    scope.push(iter) catch return error.OutOfMemory;
    const iter_obj = heap_mod.valueAsPlainObject(iter) orelse return throwTypeError(realm, "Object.groupBy items is not iterable");
    const next_v = iter_obj.get("next");
    const next_fn = heap_mod.valueAsFunction(next_v) orelse return throwTypeError(realm, "iterator.next is not callable");

    const out = realm.heap.allocateObject() catch return error.OutOfMemory;
    realm.heap.setObjectPrototype(out, null); // null-prototype per spec
    scope.push(heap_mod.taggedObject(out)) catch return error.OutOfMemory;
    const loop_base = scope.handles.items.len;

    const max_iter: i64 = 1 << 24;
    var i: i64 = 0;
    while (i < max_iter) : (i += 1) {
        // §23.1 GroupBy step 6.b — `Let next be ? IteratorStep(iteratorRecord)`.
        // A user `next` that throws (test262
        // built-ins/Object/groupBy/iterator-next-throws.js) must
        // propagate the original throw value; record the exception
        // on the realm so the JS `assert.throws(Test262Error, …)`
        // catches it instead of a synthetic TypeError.
        const step = lantern.callJSFunction(realm.allocator, realm, next_fn, iter, &.{}) catch |err| switch (err) {
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
        if (toBoolean(try getPropertyChain(realm, result, "done"))) break;
        const item = try getPropertyChain(realm, result, "value");
        // Root `item` across the grouping callback AND the bucket /
        // index-string allocations below — `callJSFunction`,
        // `allocateObject`, and `allocateString` all GC, and `item`
        // is only linked into the rooted `out` (via its bucket) at
        // the very end of the iteration.
        scope.push(item) catch return error.OutOfMemory;
        const cb_args = [_]Value{ item, Value.fromInt32(@intCast(i)) };
        // §23.1 GroupBy step 6.e — `Let key be Completion(Call(callbackfn, …))`.
        // A user callback throw (test262
        // built-ins/Object/groupBy/callback-throws.js) must surface
        // intact — register the exception on the realm.
        const key_outcome = lantern.callJSFunction(realm.allocator, realm, cb, Value.undefined_, &cb_args) catch |err| switch (err) {
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
        // Root the raw key across `stringifyArg` — an object-valued
        // key re-enters JS through its `toString`, and `key_v` is the
        // receiver of that call.
        scope.push(key_v) catch return error.OutOfMemory;
        const key_js: *JSString = if (key_v.isString())
            @ptrCast(@alignCast(key_v.asString()))
        else
            try stringifyArg(realm, key_v);
        // Root the key string: `key_str` borrows its WTF-8 bytes, and
        // the new-bucket branch's `allocateObject` GCs before `out`
        // borrows the slice (and anchors `key_js`) — without rooting,
        // that sweep would free `key_js` and `key_str` would dangle.
        scope.push(Value.fromString(key_js)) catch return error.OutOfMemory;
        const key_str = key_js.flatBytes();
        // Look up or create the bucket array.
        var bucket: *JSObject = undefined;
        if (out.lookupOwn(key_str)) |existing| {
            bucket = heap_mod.valueAsPlainObject(existing) orelse return error.NativeThrew;
        } else {
            bucket = realm.heap.allocateObject() catch return error.OutOfMemory;
            // Root the fresh bucket before the next `allocateString`
            // GC: it is only linked into `out` at the `out.set` below.
            scope.push(heap_mod.taggedObject(bucket)) catch return error.OutOfMemory;
            realm.heap.setObjectPrototype(bucket, realm.intrinsics.array_prototype);
            bucket.markAsArrayExotic(realm.allocator) catch return error.OutOfMemory;
            bucket.set(realm.allocator, "length", Value.fromInt32(0)) catch return error.OutOfMemory;
            out.set(realm.allocator, key_str, heap_mod.taggedObject(bucket)) catch return error.OutOfMemory;
            // `out` borrows the key slice; anchor the heap string.
            out.anchorKey(realm.allocator, key_js) catch return error.OutOfMemory;
            out.markNonPristine();
        }
        const cur_len = bucket.get("length");
        const len_i: i32 = if (cur_len.isInt32()) cur_len.asInt32() else 0;
        var idx_buf: [16]u8 = undefined;
        const idx_slice = std.fmt.bufPrint(&idx_buf, "{d}", .{len_i}) catch return error.OutOfMemory;
        // The property bag holds the key by reference, so the
        // bytes must outlive this stack frame — intern via the
        // heap.
        const idx_owned = realm.heap.allocateString(idx_slice) catch return error.OutOfMemory;
        bucket.set(realm.allocator, idx_owned.flatBytes(), item) catch return error.OutOfMemory;
        bucket.set(realm.allocator, "length", Value.fromInt32(len_i + 1)) catch return error.OutOfMemory;
        // Per-iteration handles (item, key, bucket) are now reachable
        // through the rooted `out`; drop them so the scope can't grow
        // unboundedly across a long iterable.
        scope.handles.shrinkRetainingCapacity(loop_base);
    }
    return heap_mod.taggedObject(out);
}

// ── Object.prototype methods ────────────────────────────────────────────────

fn objectHasOwnProperty(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    // §20.1.3.2 step 1 — `ToPropertyKey(V)` runs BEFORE `ToObject(this)`,
    // so a coercion throw from the argument propagates even when the
    // receiver is null/undefined. Use `try` instead of swallowing as
    // OutOfMemory.
    const key = (try descriptorKey(realm, argOr(args, 0, Value.undefined_))).key;
    // §20.1.3.2 step 2 — `ToObject(this)` throws on null / undefined.
    if (this_value.isNull() or this_value.isUndefined()) {
        return throwTypeError(realm, "Object.prototype.hasOwnProperty called on null or undefined");
    }
    if (heap_mod.valueAsPlainObject(this_value)) |obj| {
        // §20.1.3.2 step 3 routes through §7.3.11 HasOwnProperty →
        // §9.4.6.4 [[GetOwnProperty]] on a module namespace, which
        // calls [[Get]] to materialise the descriptor's [[Value]]
        // and throws ReferenceError if the binding is uninit
        // (§9.4.6.7 step 13 / §8.1.1.1.6). Surface the throw here
        // for the in-namespace exported string keys.
        if (obj.is_module_namespace and obj.hasOwn(key) and !std.mem.startsWith(u8, key, "@@") and !std.mem.startsWith(u8, key, "<sym:")) {
            _ = try @import("../module.zig").namespaceGetThrowingOnHole(realm, obj, key);
        }
        // §7.3.13 HasOwnProperty composes [[GetOwnProperty]]. For a
        // Proxy that dispatches the `getOwnPropertyDescriptor` trap
        // (§10.5.5); we reuse Object.getOwnPropertyDescriptor which
        // already walks the proxy chain and enforces the invariants.
        // Callable proxies (`new Proxy(fn, …)`) carry their target
        // in `proxy_target_fn`, not `proxy_target`, so include it —
        // otherwise `hasOwnProperty` on a callable proxy skips the
        // trap and reads the (empty) wrapper object directly.
        if (obj.proxy_target != null or obj.proxy_target_fn != null or obj.proxy_revoked) {
            const probe_args = [_]Value{ this_value, argOr(args, 0, Value.undefined_) };
            const desc_v = try objectGetOwnPropertyDescriptor(realm, Value.undefined_, &probe_args);
            return Value.fromBool(!desc_v.isUndefined());
        }
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
        return Value.fromBool(i < s.flatBytes().len);
    }
    return Value.false_;
}

/// §20.1.3.4 Object.prototype.propertyIsEnumerable. Returns
/// `true` iff `key` is an own property of the receiver and its
/// [[Enumerable]] attribute is `true`.
fn objectProtoPropertyIsEnumerable(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    // §20.1.3.4 step 2 — `Let O be ? ToObject(this value)`. Null
    // and undefined throw TypeError BEFORE ToPropertyKey runs on
    // the argument (Sputnik S15.2.4.7_A12 / _A13 encode the
    // order). Boxed primitives wrap to their matching wrapper.
    if (this_value.isNull() or this_value.isUndefined()) {
        return throwTypeError(realm, "Object.prototype.propertyIsEnumerable called on null or undefined");
    }
    const key = (try descriptorKey(realm, argOr(args, 0, Value.undefined_))).key;
    if (heap_mod.valueAsPlainObject(this_value)) |obj| {
        // §20.1.3.4 step 3 composes `O.[[GetOwnProperty]](P)`. For a
        // Proxy that dispatches the `getOwnPropertyDescriptor` trap
        // and returns the descriptor (or undefined). Reuse the
        // already-spec-faithful entry point. Include `proxy_target_fn`
        // so a callable proxy routes through the trap too.
        if (obj.proxy_target != null or obj.proxy_target_fn != null or obj.proxy_revoked) {
            const probe_args = [_]Value{ this_value, argOr(args, 0, Value.undefined_) };
            const desc_v = try objectGetOwnPropertyDescriptor(realm, Value.undefined_, &probe_args);
            if (desc_v.isUndefined()) return Value.false_;
            const desc_obj = heap_mod.valueAsPlainObject(desc_v) orelse return Value.false_;
            const enum_v = desc_obj.get("enumerable");
            const arith = @import("../lantern/arith.zig");
            return Value.fromBool(arith.toBoolean(enum_v));
        }
        if (!obj.hasOwn(key)) return Value.false_;
        // §20.1.3.4 step 3 calls O.[[GetOwnProperty]](P) to read
        // the descriptor — on a module namespace, the §9.4.6.4
        // exotic invokes [[Get]] (§9.4.6.7) which throws
        // ReferenceError on a TDZ-Hole-seeded binding. Mirror that
        // throw before we report enumerability.
        if (obj.is_module_namespace and !std.mem.startsWith(u8, key, "@@") and !std.mem.startsWith(u8, key, "<sym:")) {
            _ = try @import("../module.zig").namespaceGetThrowingOnHole(realm, obj, key);
        }
        return Value.fromBool(obj.flagsFor(key).enumerable);
    }
    if (heap_mod.valueAsFunction(this_value)) |fn_obj| {
        if (!fn_obj.hasOwn(key)) return Value.false_;
        return Value.fromBool(fn_obj.flagsForOwn(key).enumerable);
    }
    return Value.false_;
}

/// §20.1.3.3 Object.prototype.isPrototypeOf. Spec walk:
/// 1. If Type(V) is not Object, return false.
/// 2. Let O be ? ToObject(this value).
/// 3. Repeat: V = V.[[GetPrototypeOf]](); if V is null return
///    false; if SameValue(O, V) return true.
///
/// The step-2 ToObject is what throws TypeError for `.call(null, …)`
/// and `.call(undefined, …)` — and it must happen AFTER step 1
/// rejects non-object args (Sputnik ordering tests rely on this).
/// Step 3 dispatches through `objectGetPrototypeOf`, so Proxy
/// `getPrototypeOf` traps fire correctly.
fn objectProtoIsPrototypeOf(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const target_v = argOr(args, 0, Value.undefined_);
    // Step 1 — V must be an Object (plain or callable). A primitive
    // here returns false BEFORE step 2's ToObject sees `this`, so
    // `Object.prototype.isPrototypeOf.call(null, 42)` returns false,
    // not TypeError (Sputnik fixtures encode this ordering).
    if (heap_mod.valueAsPlainObject(target_v) == null and heap_mod.valueAsFunction(target_v) == null) {
        return Value.false_;
    }
    // Step 2 — ToObject(this). Throws for null / undefined.
    const this_obj_v = blk: {
        if (this_value.isUndefined() or this_value.isNull()) {
            return intrinsics.throwTypeError(realm, "Object.prototype.isPrototypeOf called on null or undefined");
        }
        if (heap_mod.valueAsPlainObject(this_value)) |_| break :blk this_value;
        if (heap_mod.valueAsFunction(this_value)) |_| break :blk this_value;
        // Boxed primitive — wrap.
        const w = try intrinsics.toObjectThis(realm, this_value);
        break :blk heap_mod.taggedObject(w);
    };
    // Step 3 — walk via [[GetPrototypeOf]] so Proxy traps fire.
    var current = target_v;
    while (true) {
        const next_args = [_]Value{current};
        const proto_v = try objectGetPrototypeOf(realm, Value.undefined_, &next_args);
        if (proto_v.isNull()) return Value.false_;
        if (intrinsics.sameValue(this_obj_v, proto_v)) return Value.true_;
        current = proto_v;
    }
}

/// §20.1.3.6 Object.prototype.toString. Spec walk:
/// 1. If receiver is `undefined` → `"[object Undefined]"`.
/// 2. If receiver is `null` → `"[object Null]"`.
/// 3. Let O be ! ToObject(this value).
/// 4. Let isArray be ? IsArray(O).
/// 5-14. Pick `builtinTag` based on the receiver's internal-
/// slot family (`isArray`, `[[Call]]`, `[[ErrorData]]`, …) or
/// `"Object"`.
/// 15. Let tag be ? Get(O, @@toStringTag).
/// 16. If Type(tag) is not String, set tag to builtinTag.
/// 17. Return the string-concatenation of "[object ", tag, "]".
///
/// Two spec details that matter for §7.2.2 IsArray and
/// §10.5 Proxy: a revoked Proxy on the IsArray chain throws
/// TypeError before step 5 (test262 `proxy-revoked.js`), and a
/// Proxy whose target is callable carries `[[Call]]` so the
/// builtinTag is `"Function"` (test262 `proxy-function.js`).
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

    // Step 4 + builtinTag — per §20.1.3.6 the spec ToObject's
    // `this value` first, then picks the tag from the wrapper's
    // internal slot. Cynic short-circuits the wrapping for
    // String / Number / Boolean primitives (their wrappers carry
    // [[StringData]] / [[NumberData]] / [[BooleanData]] — so the
    // slot wins step 4 and short-circuiting is observably
    // equivalent for the default case). Symbol and BigInt
    // primitives are different: their wrappers have NO listed
    // internal slot, so step 4 produces "Object" and the final
    // tag is determined by step 15's @@toStringTag walk on
    // Symbol.prototype / BigInt.prototype. User code that
    // deletes the @@toStringTag must see "[object Object]" —
    // short-circuiting them here breaks that observability.
    const builtin_tag: []const u8 = blk: {
        if (heap_mod.isFunction(this_value)) break :blk "Function";
        if (this_value.isString()) break :blk "String";
        if (this_value.isNumber()) break :blk "Number";
        if (this_value.isBool()) break :blk "Boolean";
        if (heap_mod.valueAsPlainObject(this_value)) |obj| {
            // §7.2.2 IsArray with Proxy unwrap (step 4 of the
            // toString algorithm). A revoked Proxy on the walk
            // throws TypeError; a Proxy wrapping an Array Exotic
            // reports `true`. Done first so the throw fires
            // before any other slot probe.
            if (try isArrayWithProxyUnwrap(realm, obj)) break :blk "Array";
            // §22.1.3.6 step 4 — pick the built-in tag from the
            // internal slot present on the receiver. Order
            // matters per the spec table.
            if (obj.prototype != null and obj.prototype == realm.intrinsics.array_prototype) break :blk "Array";
            // §20.2.3 — %Function.prototype% is itself a Function
            // exotic object whose [[Class]] is "Function".
            // Cynic stashes it as a JSObject (not a JSFunction)
            // for now (see intrinsics.zig); recognise it here so
            // `Object.prototype.toString.call(Function.prototype)`
            // returns "[object Function]" per Sputnik S15.3.4_A1.
            if (obj == realm.intrinsics.function_prototype) break :blk "Function";
            // §10.4.4 / §22.1.3.6 step 4 "Arguments" case.
            if (obj.is_arguments_exotic) break :blk "Arguments";
            // §10.5 Proxy — when the wrapped target is callable
            // the spec sets `[[Call]]` on the proxy itself
            // (§10.5.1 ProxyCreate). Test262 expects
            // `Object.prototype.toString.call(new Proxy(fn, {}))`
            // → `"[object Function]"`.
            if (isCallableProxy(obj)) break :blk "Function";
            // §20.1.3.6 — a RegExp instance ([[RegExpMatcher]]).
            // Brand on `regexp_source` (the [[OriginalSource]] slot
            // set at RegExpInitialize), not on a compiled-matcher
            // slot: the matcher is lazy and engine-specific (Perlex
            // vs libregexp), so keying off it misclassifies regexes
            // the native engine owns.
            if (obj.regexp_source != null) break :blk "RegExp";
            if (obj.getArrayBuffer() != null) break :blk "Object"; // ArrayBuffer uses @@toStringTag
            if (obj.getBoxedPrimitive()) |bp| {
                if (bp.isBool()) break :blk "Boolean";
                if (bp.isInt32() or bp.isDouble()) break :blk "Number";
            }
            if (obj.getBoxedString() != null) break :blk "String";
            // §20.5.3 / §22.1.3.6 — objects with the [[ErrorData]]
            // internal slot tag as "Error". The `<X>Error.prototype`
            // objects intentionally don't have this slot (per
            // `built-ins/NativeErrors/<X>/prototype/not-error-object.js`)
            // so the bare prototype falls through to "Object".
            if (obj.has_error_data) break :blk "Error";
            // §20.1.3.6 step 14 — `[[DateValue]]` (Cynic's `date_ms`
            // slot) drives the "Date" tag. Doing this from the slot
            // rather than a `Date.prototype[@@toStringTag]` entry
            // lets user code install an own toStringTag on a Date
            // instance (the inherited descriptor would otherwise be
            // writable:false and block the assignment per §10.1.9.2;
            // `built-ins/Object/prototype/toString/symbol-tag-override-instances.js`).
            if (obj.getDateMs() != null) break :blk "Date";
            break :blk "Object";
        }
        break :blk "Object";
    };

    // Step 15 — `Let tag be ? Get(O, @@toStringTag)`. The lookup
    // can run user-installed accessors (test262
    // `get-symbol-tag-err.js` throws from the getter); use the
    // accessor-aware path so the exception propagates.
    const tag_v = try lookupToStringTag(realm, this_value);
    var tag_slice: []const u8 = builtin_tag;
    if (tag_v) |v| {
        if (v.isString()) {
            const ts: *JSString = @ptrCast(@alignCast(v.asString()));
            tag_slice = ts.flatBytes();
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

/// §20.1.3.5 Object.prototype.toLocaleString ( [ reserved1 [ ,
/// reserved2 ] ] ). Per spec the entire body is
/// `Return ? Invoke(O, "toString")` — dispatch back through the
/// receiver's `toString` so subclasses overriding `toString`
/// also override `toLocaleString`. The receiver is forwarded as
/// the `this` value; for primitive thisValues the spec wraps
/// only as part of the inner `Get` so user-installed accessors
/// see the primitive directly.
pub fn objectProtoToLocaleString(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = args;
    // §7.3.18 Invoke step 2 — `func = ? GetV(V, P)`. GetV
    // ToObject's primitives so the prototype-installed
    // `toString` resolves, but the receiver remains the
    // primitive.
    const func = try getVProperty(realm, this_value, "toString");
    const fn_obj = heap_mod.valueAsFunction(func) orelse
        return throwTypeError(realm, "Object.prototype.toLocaleString: toString is not callable");
    const interp = @import("../lantern/interpreter.zig");
    const outcome = interp.callJSFunction(realm.allocator, realm, fn_obj, this_value, &[_]Value{}) catch |err| switch (err) {
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

/// §7.3.3 GetV(V, P) — `Let O be ? ToObject(V); return ? O.
/// [[Get]](P, V)`. Used here so a primitive receiver resolves
/// its prototype-installed `toString` (or a user-defined
/// accessor on `<Wrapper>.prototype`) with the primitive as
/// receiver — per spec the third arg to [[Get]] is `V` (the
/// original primitive), so a getter in strict mode sees
/// `typeof this === "boolean"`, not `"object"` (test262
/// `primitive_this_value_getter.js`).
fn getVProperty(realm: *Realm, v: Value, key: []const u8) NativeError!Value {
    if (heap_mod.valueAsPlainObject(v)) |obj| return getPropertyWithReceiver(realm, obj, key, v);
    if (heap_mod.valueAsFunction(v)) |fn_obj| {
        if (fn_obj.ownAccessor(key)) |acc| {
            if (acc.getter) |getter| {
                const interp = @import("../lantern/interpreter.zig");
                const outcome = interp.callJSFunction(realm.allocator, realm, getter, v, &[_]Value{}) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    else => return error.NativeThrew,
                };
                switch (outcome) {
                    .value, .yielded => |rv| return rv,
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
    // Primitives — ToObject reaches `<Type>.prototype` via the
    // matching global constructor. Use the prototype as the
    // starting point of the chain walk but keep the primitive
    // as the accessor receiver so user `get`-functions in
    // strict mode observe the primitive's type.
    const proto: ?*JSObject = blk: {
        if (v.isString()) {
            const ctor_v = realm.globals.get("String") orelse break :blk null;
            const ctor = heap_mod.valueAsFunction(ctor_v) orelse break :blk null;
            break :blk ctor.prototype;
        }
        if (v.isNumber()) {
            const ctor_v = realm.globals.get("Number") orelse break :blk null;
            const ctor = heap_mod.valueAsFunction(ctor_v) orelse break :blk null;
            break :blk ctor.prototype;
        }
        if (v.isBool()) {
            const ctor_v = realm.globals.get("Boolean") orelse break :blk null;
            const ctor = heap_mod.valueAsFunction(ctor_v) orelse break :blk null;
            break :blk ctor.prototype;
        }
        if (heap_mod.valueAsSymbol(v)) |_| {
            const ctor_v = realm.globals.get("Symbol") orelse break :blk null;
            const ctor = heap_mod.valueAsFunction(ctor_v) orelse break :blk null;
            break :blk ctor.prototype;
        }
        if (heap_mod.valueAsBigInt(v)) |_| {
            const ctor_v = realm.globals.get("BigInt") orelse break :blk null;
            const ctor = heap_mod.valueAsFunction(ctor_v) orelse break :blk null;
            break :blk ctor.prototype;
        }
        break :blk null;
    };
    if (proto) |p| return getPropertyWithReceiver(realm, p, key, v);
    return Value.undefined_;
}

/// §10.1.8 OrdinaryGet(O, P, Receiver) — like `getPropertyChain`
/// but passes a caller-supplied receiver into accessor `get`
/// invocations. Used by `getVProperty` so primitive receivers
/// can read inherited accessors with the primitive (not its
/// wrapper) as `this`.
fn getPropertyWithReceiver(realm: *Realm, obj: *JSObject, key: []const u8, receiver: Value) NativeError!Value {
    var cur: ?*JSObject = obj;
    while (cur) |o| {
        if (o.getAccessor(key)) |acc| {
            if (acc.getter) |getter| {
                const interp = @import("../lantern/interpreter.zig");
                const outcome = interp.callJSFunction(realm.allocator, realm, getter, receiver, &[_]Value{}) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    else => return error.NativeThrew,
                };
                switch (outcome) {
                    .value, .yielded => |rv| return rv,
                    .thrown => |ex| {
                        realm.pending_exception = ex;
                        return error.NativeThrew;
                    },
                }
            }
            return Value.undefined_;
        }
        if (o.lookupOwn(key)) |val| return val;
        cur = o.prototype;
    }
    return Value.undefined_;
}

/// §7.2.2 IsArray with Proxy unwrap (mirror of the helper in
/// `builtins/array.zig`). Walks `proxy_target` until a non-
/// proxy is reached; a revoked proxy on the walk throws
/// TypeError per §7.2.2 step 3.a.
fn isArrayWithProxyUnwrap(realm: *Realm, obj: *JSObject) NativeError!bool {
    var cur = obj;
    while (true) {
        if (cur.proxy_revoked) {
            return throwTypeError(realm, "Cannot perform 'IsArray' on a proxy that has been revoked");
        }
        if (cur.proxy_target) |t| {
            cur = t;
            continue;
        }
        return cur.is_array_exotic;
    }
}

/// §10.5 Proxy — `[[Call]]` is exposed iff the wrapped target
/// was callable at ProxyCreate (§10.5.1 step 7). `proxy_callable`
/// records that decision and is preserved across proxy-over-
/// proxy wrapping plus revocation, so the toString builtinTag
/// stays "Function" even after a revoke.
fn isCallableProxy(obj: *JSObject) bool {
    return obj.proxy_callable;
}

/// Walk the receiver's prototype chain looking for a string
/// `Symbol.toStringTag` slot (under the synthetic `@@toStringTag`
/// key). Plain objects, functions, and primitive wrappers all
/// route here. `null` means "no override; use built-in tag."
/// Uses `getPropertyChain` so accessor `@@toStringTag` getters
/// fire (per test262 `get-symbol-tag-err.js`); an exception
/// thrown by the getter propagates via `error.NativeThrew`.
fn lookupToStringTag(realm: *Realm, this_value: Value) NativeError!?Value {
    if (heap_mod.valueAsPlainObject(this_value)) |obj| {
        // §10.5.5 [[Get]] on a Proxy forwards to the target's
        // [[Get]] when no `get` trap is installed; Cynic only
        // stamps the wrapped function's `proto` into the proxy
        // at construction time, so walk the proxy chain to find
        // the most concrete target's @@toStringTag (e.g. for a
        // Proxy-over-Proxy-over-`function*`, the inner-most
        // generator-function's prototype carries the
        // "GeneratorFunction" tag).
        var cur = obj;
        while (true) {
            if (cur.proxy_revoked) {
                return throwTypeError(realm, "Cannot perform '[[Get]]' on a proxy that has been revoked");
            }
            if (cur.proxy_target) |t| {
                cur = t;
                continue;
            }
            if (cur.proxy_target_fn) |fn_target| {
                const v = fn_target.get("@@toStringTag");
                if (v.isString()) return v;
                return null;
            }
            break;
        }
        const v = try getPropertyChain(realm, cur, "@@toStringTag");
        if (v.isString()) return v;
        return null;
    }
    if (heap_mod.valueAsFunction(this_value)) |fn_obj| {
        const v = fn_obj.get("@@toStringTag");
        if (v.isString()) return v;
        return null;
    }
    // §20.1.3.6 step 3 + step 15 — primitive receivers `ToObject`
    // to their wrapper whose [[Prototype]] is the matching
    // constructor's `.prototype`. Boolean / Number / String
    // wrappers have a default builtinTag from the boxed-slot
    // check, but user code can install a `@@toStringTag` on
    // `Boolean.prototype` / `Number.prototype` / `String.prototype`
    // and that string must override the builtinTag
    // (test262 `symbol-tag-override-primitives.js`). Symbol /
    // BigInt wrappers have NO listed internal slot, so the
    // builtinTag is "Object" and the @@toStringTag walk on
    // Symbol.prototype / BigInt.prototype produces the
    // "[object Symbol]" / "[object BigInt]" rendering.
    const proto_for_primitive: ?*JSObject = blk: {
        if (this_value.isString()) {
            const ctor_v = realm.globals.get("String") orelse break :blk null;
            const ctor = heap_mod.valueAsFunction(ctor_v) orelse break :blk null;
            break :blk ctor.prototype;
        }
        if (this_value.isNumber()) {
            const ctor_v = realm.globals.get("Number") orelse break :blk null;
            const ctor = heap_mod.valueAsFunction(ctor_v) orelse break :blk null;
            break :blk ctor.prototype;
        }
        if (this_value.isBool()) {
            const ctor_v = realm.globals.get("Boolean") orelse break :blk null;
            const ctor = heap_mod.valueAsFunction(ctor_v) orelse break :blk null;
            break :blk ctor.prototype;
        }
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
        const v = try getPropertyChain(realm, proto, "@@toStringTag");
        if (v.isString()) return v;
    }
    return null;
}

fn objectProtoValueOf(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = args;
    // §20.1.3.7 Object.prototype.valueOf — Return ? ToObject(this value).
    // Wraps primitives (booleans, numbers, strings) into their wrapper
    // objects and throws TypeError on null/undefined. `toObjectThis` is
    // a no-op pass-through for plain objects, so `({}).valueOf() === ({})`
    // still holds when the receiver is already an object.
    return heap_mod.taggedObject(try intrinsics.toObjectThis(realm, this_value));
}
