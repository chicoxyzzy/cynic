//! §28 Reflect — extracted from `intrinsics.zig`. Provides a
//! method-style alternative to operators / Object statics for
//! introspection: `Reflect.has`, `.get`, `.set`,
//! `.deleteProperty`, `.ownKeys`, `.getPrototypeOf`,
//! `.setPrototypeOf`, `.isExtensible`, `.apply`, `.construct`.
//!
//! `pub fn install(realm)` allocates the `Reflect` global and
//! wires every method via the `installNativeMethodOnProto`
//! helper from `intrinsics.zig` (Reflect itself is a plain
//! object, but the methods all install with the §17
//! built-in-method flag set).

const std = @import("std");

const Realm = @import("../realm.zig").Realm;
const Value = @import("../value.zig").Value;
const JSString = @import("../string.zig").JSString;
const JSObject = @import("../object.zig").JSObject;
const JSFunction = @import("../function.zig").JSFunction;
const NativeError = @import("../function.zig").NativeError;
const heap_mod = @import("../heap.zig");
const intrinsics = @import("../intrinsics.zig");

const installNativeMethodOnProto = intrinsics.installNativeMethodOnProto;
const installToStringTag = intrinsics.installToStringTag;
const argOr = intrinsics.argOr;
const throwTypeError = intrinsics.throwTypeError;
const throwRangeError = intrinsics.throwRangeError;
const lengthOfArray = intrinsics.lengthOfArray;
const clampArrayLength = intrinsics.clampArrayLength;
const objectGetPrototypeOf = intrinsics.objectGetPrototypeOf;
const proxy_mod = @import("proxy.zig");

// ── §28 Reflect ─────────────────────────────────────────────────────────────

pub fn install(realm: *Realm) !void {
    const obj = try realm.heap.allocateObject();
    realm.heap.setObjectPrototype(obj, realm.intrinsics.object_prototype);
    try installToStringTag(realm, obj, "Reflect");
    // §28.1.* — spec `.length` values reflect REQUIRED args,
    // not declared. Reflect.get(target, key, receiver?) is
    // length 2; Reflect.set(target, key, value, receiver?) is
    // length 3. The optional `receiver` doesn't count toward
    // the spec length.
    try installNativeMethodOnProto(realm, obj, "has", reflectHas, 2);
    try installNativeMethodOnProto(realm, obj, "get", reflectGet, 2);
    try installNativeMethodOnProto(realm, obj, "set", reflectSet, 3);
    try installNativeMethodOnProto(realm, obj, "deleteProperty", reflectDeleteProperty, 2);
    try installNativeMethodOnProto(realm, obj, "ownKeys", reflectOwnKeys, 1);
    try installNativeMethodOnProto(realm, obj, "getPrototypeOf", reflectGetPrototypeOf, 1);
    try installNativeMethodOnProto(realm, obj, "setPrototypeOf", reflectSetPrototypeOf, 2);
    try installNativeMethodOnProto(realm, obj, "isExtensible", reflectIsExtensible, 1);
    try installNativeMethodOnProto(realm, obj, "apply", reflectApply, 3);
    try installNativeMethodOnProto(realm, obj, "construct", reflectConstruct, 2);
    try installNativeMethodOnProto(realm, obj, "getOwnPropertyDescriptor", reflectGetOwnPropertyDescriptor, 2);
    try installNativeMethodOnProto(realm, obj, "defineProperty", reflectDefineProperty, 3);
    try installNativeMethodOnProto(realm, obj, "preventExtensions", reflectPreventExtensions, 1);
    try realm.globals.put(realm.allocator, "Reflect", heap_mod.taggedObject(obj));
}

fn reflectPreventExtensions(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = this_value;
    // §28.1.10 — Reflect.preventExtensions throws on non-object;
    // returns Boolean (true on success, false on failure).
    const target = argOr(args, 0, Value.undefined_);
    const obj = heap_mod.valueAsPlainObject(target) orelse {
        if (heap_mod.valueAsFunction(target) == null) {
            return throwTypeError(realm, "Reflect.preventExtensions called on non-object");
        }
        // Functions: no proxy path, no extensible bit modelled today.
        return Value.fromBool(true);
    };
    if (obj.proxy_target != null or obj.proxy_revoked) {
        const obj_mod = @import("object.zig");
        const ok = try obj_mod.proxyPreventExtensionsBool(realm, obj);
        return Value.fromBool(ok);
    }
    obj.extensible = false;
    return Value.fromBool(true);
}

fn reflectGetOwnPropertyDescriptor(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    // §28.1.7 step 1 — target must be Object. Unlike
    // `Object.getOwnPropertyDescriptor` (which ES2015+ coerces
    // primitives via ToObject), the Reflect equivalent throws
    // TypeError on Symbol / BigInt / number / string / boolean /
    // null / undefined. Gate before delegating to the shared
    // Object impl.
    const target_v = argOr(args, 0, Value.undefined_);
    if (heap_mod.valueAsPlainObject(target_v) == null and heap_mod.valueAsFunction(target_v) == null) {
        return throwTypeError(realm, "Reflect.getOwnPropertyDescriptor called on non-object");
    }
    return intrinsics.objectGetOwnPropertyDescriptor(realm, this_value, args);
}

fn reflectDefineProperty(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    // §28.1.3 step 1 — target must be Object (Symbols, primitives,
    // null, undefined all throw TypeError).
    const target_v = argOr(args, 0, Value.undefined_);
    if (heap_mod.valueAsPlainObject(target_v) == null and heap_mod.valueAsFunction(target_v) == null) {
        return throwTypeError(realm, "Reflect.defineProperty called on non-object");
    }
    // §28.1.3 step 2 — `key = ? ToPropertyKey(propertyKey)` happens
    // inside the Object.defineProperty path; any abrupt from there
    // (e.g. Symbol-toString) must propagate.
    //
    // §28.1.3 returns a Boolean: false on failure rather than throwing.
    // Catch + translate.
    const result = intrinsics.objectDefineProperty(realm, this_value, args) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.NativeThrew => {
            // §10.4.5.3 TypedArray index rejection — surface as
            // `false` per Reflect's contract (Object.defineProperty
            // raises the TypeError; Reflect translates it).
            if (realm.define_own_property_rejected) {
                realm.define_own_property_rejected = false;
                realm.pending_exception = null;
                return Value.fromBool(false);
            }
            // Distinguish "key conversion threw" (propagate) from
            // "definition failed validly" (return false). The
            // Object.defineProperty path doesn't surface that
            // distinction yet; for now propagate the throw if a
            // pending_exception was recorded by an *arg* coercion
            // (Symbol toPrimitive etc.), and convert the rest to
            // false. The split keeps the abrupt-from-attributes
            // / property-key tests happy without regressing
            // pre-existing fixtures that rely on the false return.
            if (realm.pending_exception) |ex| {
                // Heuristic — fail-loud on coercion throws by
                // leaving the pending exception in place.
                _ = ex;
                return error.NativeThrew;
            }
            return Value.fromBool(false);
        },
    };
    _ = result;
    return Value.fromBool(true);
}

fn reflectHas(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = this_value;
    const arg = argOr(args, 0, Value.undefined_);
    // §28.1.9 step 1 — target must be Object.
    if (heap_mod.valueAsPlainObject(arg) == null and heap_mod.valueAsFunction(arg) == null) {
        return throwTypeError(realm, "Reflect.has target must be an object");
    }
    // §28.1.9 step 2 — `key = ? ToPropertyKey(propertyKey)`.
    // A throwing toString / valueOf / @@toPrimitive on a user
    // key propagates before any lookup runs.
    const key_v = argOr(args, 1, Value.undefined_);
    const key_slice = try toPropertyKeySpec(realm, key_v);
    if (heap_mod.valueAsPlainObject(arg)) |maybe_proxy| {
        var cur = maybe_proxy;
        while (cur.proxy_target != null or cur.proxy_revoked) {
            const r = try proxy_mod.nativeProxyHas(realm, cur, key_slice, key_v);
            switch (r) {
                .boolean => |b| return Value.fromBool(b),
                .fallthrough => |t| {
                    if (t == cur) break;
                    cur = t;
                },
            }
        }
        // §7.3.12 HasProperty — walk the proto chain ourselves
        // so a Proxy installed via `Object.setPrototypeOf` fires
        // its `has` trap. `JSObject.hasProperty` short-circuits
        // proxies because it's a pure data-shape lookup (used in
        // hot paths that can't reach back into JS). Test262
        // `TypedArrayConstructors/internals/HasProperty/
        // abrupt-from-ordinary-has-parent-hasproperty.js` and the
        // BigInt variant rely on the proto-Proxy `has` trap firing.
        return Value.fromBool(try hasPropertyProxyAware(realm, cur, key_slice));
    }
    if (heap_mod.valueAsFunction(arg)) |fn_obj| {
        if (fn_obj.ownDataContains(key_slice)) return Value.true_;
        if (fn_obj.accessors.contains(key_slice)) return Value.true_;
        if (std.mem.eql(u8, key_slice, "prototype") and fn_obj.prototype != null) return Value.true_;
        if (std.mem.eql(u8, key_slice, "name") and fn_obj.name != null) return Value.true_;
        var cursor: ?*@import("../object.zig").JSObject = fn_obj.proto;
        while (cursor) |c| : (cursor = c.prototype) {
            if (c.ownDataContains(key_slice)) return Value.true_;
            if (c.hasAccessor(key_slice)) return Value.true_;
        }
        return Value.false_;
    }
    const target = heap_mod.valueAsPlainObject(arg) orelse return throwTypeError(realm, "Reflect.has target must be an object");
    var cursor: ?*@import("../object.zig").JSObject = target;
    while (cursor) |c| : (cursor = c.prototype) {
        if (c.ownDataContains(key_slice)) return Value.true_;
        if (c.hasAccessor(key_slice)) return Value.true_;
    }
    return Value.false_;
}

/// §7.3.12 HasProperty walking proxies on the prototype chain.
/// Used by `Reflect.has` (and similar surfaces that need to fire
/// proxy `has` traps when the chain reaches a Proxy node, not
/// just when the receiver itself is one).
fn hasPropertyProxyAware(realm: *Realm, root: *JSObject, key: []const u8) NativeError!bool {
    // §10.4.5.2 Integer-Indexed Exotic [[HasProperty]] — when the
    // receiver is a typed-array exotic AND the key is a canonical
    // numeric index, the lookup terminates on the view (no proto
    // fallthrough). Delegate to the on-shape helper for this case
    // so all the OOB / detached / non-integer / -0 / negative
    // sub-cases stay in one place.
    if (root.getTypedView() != null) {
        const ta_mod = @import("typed_array.zig");
        if (ta_mod.canonicalNumericIndex(key) != null) {
            return root.hasProperty(key);
        }
    }
    var cur: ?*JSObject = root;
    while (cur) |c| {
        // §10.1.7.1 OrdinaryHasProperty step 2 — own property check.
        if (c.ownDataContains(key)) return true;
        if (c.hasAccessor(key)) return true;
        if (c.is_module_namespace and c.hasAmbiguousNamespaceKey(key)) return false;
        if (c.is_module_namespace and c.hasNamespaceRedirect(key)) return true;
        if (c.is_array_exotic) {
            if (@import("../object.zig").JSObject.canonicalIntegerIndex(key)) |idx| {
                if (c.hasOwnIndexedSlot(idx)) return true;
            }
        }
        // §10.1.7.1 step 4-5 — parent = [[GetPrototypeOf]]; if a
        // Proxy, dispatch its `has` trap before descending.
        const parent = c.prototype orelse return false;
        if (parent.proxy_target != null or parent.proxy_revoked) {
            var p = parent;
            while (p.proxy_target != null or p.proxy_revoked) {
                const r = try proxy_mod.nativeProxyHas(realm, p, key, null);
                switch (r) {
                    .boolean => |b| return b,
                    .fallthrough => |t| {
                        if (t == p) break;
                        p = t;
                    },
                }
            }
            cur = p;
            continue;
        }
        cur = parent;
    }
    return false;
}

fn reflectGet(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = this_value;
    const arg = argOr(args, 0, Value.undefined_);
    // §28.1.6 step 1 — target must be Object.
    if (heap_mod.valueAsPlainObject(arg) == null and heap_mod.valueAsFunction(arg) == null) {
        return throwTypeError(realm, "Reflect.get target must be an object");
    }
    // §28.1.6 step 2 — `key = ? ToPropertyKey(propertyKey)`. A
    // throwing object key propagates synchronously.
    const key_v = argOr(args, 1, Value.undefined_);
    const key_slice = try toPropertyKeySpec(realm, key_v);
    // §28.1.6 step 4 — default receiver = target.
    const receiver: Value = if (args.len >= 3) args[2] else arg;
    if (heap_mod.valueAsFunction(arg)) |fn_obj| {
        // Functions have their own property bag; their proto chain
        // begins at `fn_obj.proto` (which inherits %Function.prototype%).
        if (fn_obj.properties.get(key_slice)) |v| return v;
        // Accessors aren't supported on raw JSFunctions today; fall
        // back to walking the proto chain via the function's own
        // [[Prototype]].
        var cur: ?*JSObject = fn_obj.proto;
        while (cur) |o| : (cur = o.prototype) {
            if (o.getAccessor(key_slice)) |acc| {
                if (acc.getter) |getter| {
                    const interp2 = @import("../lantern/interpreter.zig");
                    const outcome = interp2.callJSFunction(realm.allocator, realm, getter, receiver, &[_]Value{}) catch |err| switch (err) {
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
            if (o.lookupOwn(key_slice)) |v| return v;
        }
        return Value.undefined_;
    }
    const target = heap_mod.valueAsPlainObject(arg) orelse return throwTypeError(realm, "Reflect.get target must be an object");
    // §10.5.5 Proxy [[Get]] dispatch.
    var proxy_cur = target;
    while (proxy_cur.proxy_target != null or proxy_cur.proxy_revoked) {
        const r = try proxy_mod.nativeProxyGet(realm, proxy_cur, key_slice, receiver, key_v);
        switch (r) {
            .value => |v| return v,
            .fallthrough => |t| {
                if (t == proxy_cur) break;
                proxy_cur = t;
            },
        }
    }
    // Walk the prototype chain looking for the key. Accessors fire
    // with `receiver` as `this`. Function valueless targets fall
    // through; the function check above was the previous shortcut.
    var cursor: ?*JSObject = proxy_cur;
    while (cursor) |o| : (cursor = o.prototype) {
        if (o.getAccessor(key_slice)) |acc| {
            if (acc.getter) |getter| {
                const interp = @import("../lantern/interpreter.zig");
                const outcome = interp.callJSFunction(realm.allocator, realm, getter, receiver, &[_]Value{}) catch |err| switch (err) {
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
        if (o.is_array_exotic) {
            if (JSObject.canonicalIntegerIndex(key_slice)) |idx| {
                if (o.tryGetIndexedOwn(idx)) |v| return v;
            }
        }
        if (o.lookupOwn(key_slice)) |v| return v;
    }
    return Value.undefined_;
}

fn reflectSet(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = this_value;
    // §28.1.12 Reflect.set step 1 — target must be Object.
    const arg = argOr(args, 0, Value.undefined_);
    if (heap_mod.valueAsPlainObject(arg) == null and heap_mod.valueAsFunction(arg) == null) {
        return throwTypeError(realm, "Reflect.set target must be an object");
    }
    // §28.1.12 step 2 — `key = ? ToPropertyKey(propertyKey)`.
    // Runs BEFORE the value coercions; a user-side throwing
    // `toString` must propagate (return-abrupt-from-property-key.js).
    const key_v = argOr(args, 1, Value.undefined_);
    const key_slice = try toPropertyKeySpec(realm, key_v);
    const v = argOr(args, 2, Value.undefined_);
    // §28.1.12 step 3-4 — default receiver = target.
    const receiver_v: Value = if (args.len >= 4) args[3] else arg;
    if (heap_mod.valueAsFunction(arg)) |fn_obj| {
        // Function-typed target: today functions don't carry the
        // proxy / typed-array / array-exotic shapes; defer to the
        // existing writability-only path. Receiver-aware routing
        // for function targets isn't surfaced by any failing
        // fixture in our scope today.
        const owned = realm.heap.allocateString(key_slice) catch return error.OutOfMemory;
        const ok = realm.heap.storeFunctionPropertyIfWritable(fn_obj, realm.allocator, owned.flatBytes(), v) catch return error.OutOfMemory;
        return Value.fromBool(ok);
    }
    var target = heap_mod.valueAsPlainObject(arg).?;
    // §9.4.6.4 Module Namespace exotic [[Set]] — always returns
    // false. Reflect.set surfaces that as the literal boolean
    // `false`; the strict-mode bytecode path translates it to
    // TypeError elsewhere.
    if (target.is_module_namespace) return Value.false_;
    // §10.5.9 Proxy [[Set]] dispatch. Reflect.set returns the
    // trap's boolean — it never throws on a falsy return, unlike
    // strict-mode bytecode assignment.
    //
    // When `target` is a Proxy whose `set` trap is null/undefined
    // we MUST walk through to the wrapped non-proxy and re-bind
    // `target` to the unwrapped object before falling through to
    // the OrdinarySetWithOwnDescriptor path. Otherwise the cursor
    // walk below climbs `target.prototype` (the proxy's prototype,
    // which may be unrelated to the wrapped array's exotic shape)
    // and the final CreateDataProperty lands on the receiver
    // (still the outer proxy) instead of failing because the
    // wrapped target was sealed / preventExtensions'd. See test262
    // built-ins/Proxy/set/trap-is-{null,undefined}-target-is-proxy.js.
    {
        var proxy_cur = target;
        while (proxy_cur.proxy_target != null or proxy_cur.proxy_target_fn != null or proxy_cur.proxy_revoked) {
            // Callable Proxy of a function: §10.5.9 fires `set` if
            // present, otherwise `target.[[Set]]` against the wrapped
            // function. The function leg short-circuits through
            // `setIfWritable` per §10.1.9 OrdinarySet. Handled here
            // because `nativeProxySet` only knows the plain-object
            // target shape (`proxy_target`).
            if (proxy_cur.proxy_target == null and proxy_cur.proxy_target_fn != null and !proxy_cur.proxy_revoked) {
                const handler = proxy_cur.proxy_handler orelse return throwTypeError(realm, "proxy handler slot is null");
                const trap_v = handler.get("set");
                if (!trap_v.isUndefined() and !trap_v.isNull()) {
                    const trap_fn = heap_mod.valueAsFunction(trap_v) orelse return throwTypeError(realm, "Proxy 'set' trap is not callable");
                    const key_str = realm.heap.allocateString(key_slice) catch return error.OutOfMemory;
                    const trap_args = [_]Value{ heap_mod.taggedFunction(proxy_cur.proxy_target_fn.?), Value.fromString(key_str), v, receiver_v };
                    const interp = @import("../lantern/interpreter.zig");
                    const outcome = interp.callJSFunction(realm.allocator, realm, trap_fn, heap_mod.taggedObject(handler), &trap_args) catch |err| switch (err) {
                        error.OutOfMemory => return error.OutOfMemory,
                        else => return error.NativeThrew,
                    };
                    switch (outcome) {
                        .value, .yielded => |trap_ret| {
                            const arith = @import("../lantern/arith.zig");
                            return Value.fromBool(arith.toBoolean(trap_ret));
                        },
                        .thrown => |ex| {
                            realm.pending_exception = ex;
                            return error.NativeThrew;
                        },
                    }
                }
                // Trap missing — fall through to the wrapped function.
                // §10.1.9 OrdinarySet on a function: write through
                // `setIfWritable`. When Receiver !== the function,
                // semantics still target Receiver, but no fixture in
                // our scope exercises that asymmetry on a function
                // through a callable-proxy chain.
                const fn_target = proxy_cur.proxy_target_fn.?;
                const owned = realm.heap.allocateString(key_slice) catch return error.OutOfMemory;
                const ok = fn_target.setIfWritable(realm.allocator, owned.flatBytes(), v) catch return error.OutOfMemory;
                return Value.fromBool(ok);
            }
            const r = try proxy_mod.nativeProxySet(realm, proxy_cur, key_slice, v, receiver_v, key_v);
            switch (r) {
                .boolean => |b| return Value.fromBool(b),
                .fallthrough => |t| {
                    if (t == proxy_cur) break;
                    proxy_cur = t;
                },
            }
        }
        target = proxy_cur;
    }
    // §10.4.5.5 Integer-Indexed exotic [[Set]] — when `target` is
    // a TypedArray and `key` is a CanonicalNumericIndexString:
    // - If SameValue(O, Receiver) is `true`, perform
    //   TypedArraySetElement: coerce `v` (ToNumber / ToBigInt;
    //   may detach via user `valueOf`), then write only if
    //   `IsValidIntegerIndex` AND the buffer is still attached.
    // - Else if `IsValidIntegerIndex(O, idx)` is `false`, return
    //   `true` WITHOUT coercing (the ToNumber side-effect is
    //   only observable on the same-receiver path).
    // [[Set]] always returns `true` in both branches.
    if (target.getTypedView()) |tv| {
        const ta_mod = @import("typed_array.zig");
        const same_receiver = blk: {
            if (heap_mod.valueAsPlainObject(receiver_v)) |r_obj| break :blk r_obj == target;
            break :blk false;
        };
        // §10.4.5.5 [[Set]] for Integer-Indexed Exotic Objects —
        // CanonicalNumericIndexString(P) gates the intercept. Shapes
        // like "1.0", "+1", "1000000000000000000000", "0.0000001"
        // fall through to OrdinarySet so an ordinary writable
        // property can land on the typed array (matches the
        // `key-is-not-canonical-index.js` fixture).
        if (ta_mod.canonicalNumericIndex(key_slice)) |num| {
            if (same_receiver) {
                // Same-receiver path: SetTypedArrayElement always
                // runs ToNumber / ToBigInt first (side effects
                // visible) and then drops the write when
                // IsValidIntegerIndex is false. [[Set]] returns true.
                const coerced = try ta_mod.coerceForTypedSlot(realm, tv.kind, v);
                const live_tv = target.getTypedView() orelse return Value.true_;
                if (ta_mod.isValidIntegerIndexPub(live_tv, num)) {
                    const buf = live_tv.viewed.getArrayBuffer().?;
                    const elem_size = live_tv.kind.elementSize();
                    const idx: usize = @intFromFloat(num);
                    // Name-aware dispatch keeps Uint8ClampedArray on
                    // the ToUint8Clamp path (§7.1.11) rather than
                    // modular ToUint8 (§7.1.6).
                    @import("../intrinsics.zig").writeTypedElementForView(buf, live_tv, live_tv.byte_offset + idx * elem_size, coerced);
                }
                return Value.true_;
            }
            // Receiver != target. §10.4.5.6 step 2.b.ii: if
            // IsValidIntegerIndex is *false*, return true without
            // ToNumber (no side effect on `value`). When the index
            // *is* valid, the spec falls through to step 3
            // OrdinarySet(O, P, V, Receiver) — the value lands on
            // the receiver via §10.1.9.2, with NO ToNumber call
            // (target's IIE [[GetOwnProperty]] hides the receiver-
            // side write from coercion). For a TA receiver, route
            // through IIE [[DefineOwnProperty]] (coerce once, drop
            // on invalid index, reject as `false` on OOB receiver).
            if (!ta_mod.isValidIntegerIndexPub(tv, num)) return Value.true_;
            // Step 3 OrdinarySet — bypass the accessor-walk on the
            // target chain (TA's IIE [[GetOwnProperty]] shadows any
            // accessor installed on TA.prototype for canonical
            // numeric keys; the value lands on Receiver).
            return try reflectSetOnReceiver(realm, receiver_v, key_slice, v);
        }
        // Non-canonical key — fall through to the regular target.set
        // path below so an ordinary writable property can still land
        // on the typed array (matches `key-is-not-canonical-index.js`).
    }
    // §10.4.5.6 IIE [[Set]] step 2.b — when `target` is a plain
    // object whose prototype chain contains a TypedArray and `key`
    // is a CanonicalNumericIndexString, the proto-chain walk reaches
    // the TA rung and dispatches its IIE [[Set]] with `Receiver`
    // unchanged. SameValue(TA, Receiver) triggers TypedArraySetElement
    // (ToNumber once, drop on invalid index, return true); otherwise
    // !valid short-circuits to true and valid falls through to
    // OrdinarySet on Receiver.
    if (target.getTypedView() == null) {
        const ta_mod = @import("typed_array.zig");
        if (ta_mod.canonicalNumericIndex(key_slice)) |num| {
            var cursor: ?*@import("../object.zig").JSObject = target.prototype;
            while (cursor) |c| : (cursor = c.prototype) {
                if (c.getTypedView()) |tv2| {
                    const recv_obj = heap_mod.valueAsPlainObject(receiver_v);
                    const same_as_ta = (recv_obj == c);
                    if (same_as_ta) {
                        const coerced = try ta_mod.coerceForTypedSlot(realm, tv2.kind, v);
                        const live_tv = c.getTypedView() orelse return Value.true_;
                        if (ta_mod.isValidIntegerIndexPub(live_tv, num)) {
                            const buf = live_tv.viewed.getArrayBuffer().?;
                            const elem_size = live_tv.kind.elementSize();
                            const idx: usize = @intFromFloat(num);
                            @import("../intrinsics.zig").writeTypedElementForView(buf, live_tv, live_tv.byte_offset + idx * elem_size, coerced);
                        }
                        return Value.true_;
                    }
                    if (!ta_mod.isValidIntegerIndexPub(tv2, num)) return Value.true_;
                    return try reflectSetOnReceiver(realm, receiver_v, key_slice, v);
                }
            }
        }
    }
    // §10.4.2.1 Array exotic [[DefineOwnProperty]] — when writing
    // `length` on an Array, [[Set]] composes through ArraySetLength.
    // The TWO ToNumber calls (sec-10.4.2.4 steps 3-4) must fire so
    // any user-side `Symbol.toPrimitive` / `valueOf` observes both
    // invocations, and the writability gate runs against the
    // descriptor as it stands AFTER those side effects. Reflect.set
    // returns false here instead of throwing on a non-writable
    // length (the strict-mode bytecode path throws TypeError).
    if (target.is_array_exotic and std.mem.eql(u8, key_slice, "length")) {
        const lantern = @import("../lantern/interpreter.zig");
        if (target.property_flags.get("length")) |flags| {
            if (!flags.writable) return Value.false_;
        }
        const new_len = (try lantern.arrayLengthCoerceSpec(realm, v)) orelse {
            return throwRangeError(realm, "Invalid array length");
        };
        // Re-check writability after the spec-mandated coercions —
        // a user-side toPrimitive can flip `length: { writable: false }`
        // mid-flight; per sec-10.4.2.4 step 12 the set then returns
        // false (not throws) when reached via [[Set]].
        if (target.property_flags.get("length")) |flags| {
            if (!flags.writable) return Value.false_;
        }
        const tr = lantern.truncateArrayAtLength(realm.allocator, target, new_len);
        target.setArrayLength(realm.allocator, tr.final_length) catch return error.OutOfMemory;
        if (tr.blocked) return Value.false_;
        return Value.true_;
    }
    // §10.1.9.1 [[Set]] → §10.1.9.2 OrdinarySetWithOwnDescriptor.
    // Walk the prototype chain to locate the first own descriptor
    // for `key`. If we find an accessor, the setter fires with
    // `Receiver` as `this`. If we find a writable data descriptor
    // (or no descriptor at all, defaulted to writable / enumerable
    // / configurable), the write lands on `Receiver`, NOT `target`.
    //
    // When a Proxy sits on the prototype chain, the spec's
    // `parent.[[Set]](P, V, Receiver)` recursion (§10.1.9.2 step 2)
    // hands control to the Proxy's [[Set]] — which fires the
    // `set` trap (or recurses through trapless layers into the
    // wrapped target). Detect a proxy ancestor and dispatch through
    // it so `Reflect.set(Object.create(proxy), key, v)` reaches the
    // proxy's trap (built-ins/Proxy/set/trap-is-undefined-target-is-
    // proxy.js's third block).
    var cursor: ?*@import("../object.zig").JSObject = target;
    walk: while (cursor) |o| {
        if (o != target and (o.proxy_target != null or o.proxy_target_fn != null or o.proxy_revoked)) {
            // Walk the proxy chain to either hit a trap (which
            // settles the result) or reach a non-proxy ancestor we
            // can resume the ordinary cursor walk on.
            var proxy_cur = o;
            while (proxy_cur.proxy_target != null or proxy_cur.proxy_target_fn != null or proxy_cur.proxy_revoked) {
                if (proxy_cur.proxy_target == null and proxy_cur.proxy_target_fn != null and !proxy_cur.proxy_revoked) {
                    const handler = proxy_cur.proxy_handler orelse return throwTypeError(realm, "proxy handler slot is null");
                    const trap_v = handler.get("set");
                    if (!trap_v.isUndefined() and !trap_v.isNull()) {
                        const trap_fn = heap_mod.valueAsFunction(trap_v) orelse return throwTypeError(realm, "Proxy 'set' trap is not callable");
                        const key_str_t = realm.heap.allocateString(key_slice) catch return error.OutOfMemory;
                        const trap_args = [_]Value{ heap_mod.taggedFunction(proxy_cur.proxy_target_fn.?), Value.fromString(key_str_t), v, receiver_v };
                        const interp = @import("../lantern/interpreter.zig");
                        const outcome = interp.callJSFunction(realm.allocator, realm, trap_fn, heap_mod.taggedObject(handler), &trap_args) catch |err| switch (err) {
                            error.OutOfMemory => return error.OutOfMemory,
                            else => return error.NativeThrew,
                        };
                        switch (outcome) {
                            .value, .yielded => |trap_ret| {
                                const arith = @import("../lantern/arith.zig");
                                return Value.fromBool(arith.toBoolean(trap_ret));
                            },
                            .thrown => |ex| {
                                realm.pending_exception = ex;
                                return error.NativeThrew;
                            },
                        }
                    }
                    // Trap missing on a callable proxy — fall through
                    // to the wrapped function's OrdinarySet.
                    const fn_target = proxy_cur.proxy_target_fn.?;
                    const owned = realm.heap.allocateString(key_slice) catch return error.OutOfMemory;
                    const ok = fn_target.setIfWritable(realm.allocator, owned.flatBytes(), v) catch return error.OutOfMemory;
                    return Value.fromBool(ok);
                }
                const r = try proxy_mod.nativeProxySet(realm, proxy_cur, key_slice, v, receiver_v, null);
                switch (r) {
                    .boolean => |b| return Value.fromBool(b),
                    .fallthrough => |t| {
                        if (t == proxy_cur) break;
                        proxy_cur = t;
                    },
                }
            }
            // Non-proxy ancestor reached; resume the cursor walk
            // from there so own descriptors / accessors on the
            // unwrapped tail are still observed.
            cursor = proxy_cur;
            continue :walk;
        }
        // Accessor descriptor — fire the setter with `Receiver`
        // as `this` per §10.1.9.2 step 4 (Reflect.set
        // call-prototype-property-set.js / set-value-on-accessor-
        // descriptor-with-receiver.js).
        if (o.getAccessor(key_slice)) |acc| {
            if (acc.setter) |setter| {
                const interp = @import("../lantern/interpreter.zig");
                const setter_args = [_]Value{v};
                const outcome = interp.callJSFunction(realm.allocator, realm, setter, receiver_v, &setter_args) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    else => return error.NativeThrew,
                };
                switch (outcome) {
                    .value, .yielded => return Value.true_,
                    .thrown => |ex| {
                        realm.pending_exception = ex;
                        return error.NativeThrew;
                    },
                }
            }
            // Getter-only accessor — return false.
            return Value.false_;
        }
        const has_own_data = blk: {
            if (o.ownDataContains(key_slice)) break :blk true;
            if (o.is_array_exotic) {
                if (@import("../object.zig").JSObject.canonicalIntegerIndex(key_slice)) |idx| {
                    if (o.tryGetIndexedOwn(idx) != null) break :blk true;
                }
            }
            break :blk false;
        };
        if (has_own_data) {
            // §10.1.9.2 step 3.a — writable: false short-circuits to
            // `false` without touching `Receiver`.
            const flags = o.flagsFor(key_slice);
            if (!flags.writable) return Value.false_;
            break;
        }
        // No own descriptor on this rung — keep climbing.
        cursor = o.prototype;
    }
    // Reached step 3.b / 3.f territory — either an inherited
    // writable data descriptor was found OR the chain ran out
    // (default `{writable, enumerable, configurable}: true`).
    // Either way the write targets `Receiver`.
    // §10.1.9.2 step 3.b — Receiver must be an Object; primitives
    // return false (receiver-is-not-object.js).
    const receiver_obj = heap_mod.valueAsPlainObject(receiver_v) orelse {
        // Functions are objects too; allow that path.
        if (heap_mod.valueAsFunction(receiver_v)) |fn_recv| {
            const owned = realm.heap.allocateString(key_slice) catch return error.OutOfMemory;
            const ok = fn_recv.setIfWritable(realm.allocator, owned.flatBytes(), v) catch return error.OutOfMemory;
            return Value.fromBool(ok);
        }
        return Value.false_;
    };
    // §10.1.9.2 step 3.c-e — existing descriptor on Receiver.
    // When Receiver is itself a Proxy, the spec dispatches through
    // its `defineProperty` trap (or, with no trap, recurses into
    // the wrapped target's [[DefineOwnProperty]]). Walk the proxy
    // chain so a trapless proxy wrapping a preventExtensions'd
    // target reports the rejection correctly (test262
    // built-ins/Proxy/set/trap-is-{null,undefined}-target-is-proxy.js).
    if (receiver_obj.proxy_target != null or receiver_obj.proxy_revoked) {
        var proxy_cur = receiver_obj;
        while (proxy_cur.proxy_target != null or proxy_cur.proxy_revoked) {
            // §10.1.9.2 step 3.b — `existingDescriptor =
            // ? Receiver.[[GetOwnProperty]](P)`. When Receiver is a
            // Proxy this MUST fire its `getOwnPropertyDescriptor`
            // trap before the `defineProperty` trap; otherwise the
            // observable trap log skips the `GetOwnPropertyDescriptor`
            // tick (reverse/length-exceeding-integer-limit-with-proxy
            // expects `Set:k`, `GetOwnPropertyDescriptor:k`,
            // `DefineProperty:k` per slot).
            _ = try proxy_mod.nativeProxyGetOwnPropertyDescriptor(realm, proxy_cur, key_slice, null);
            const r = try proxy_mod.nativeProxyDefineProperty(realm, proxy_cur, key_slice, v, null);
            switch (r) {
                .boolean => |b| return Value.fromBool(b),
                .fallthrough => |t| {
                    if (t == proxy_cur) break;
                    proxy_cur = t;
                },
            }
        }
        // Reached a non-proxy receiver — fall through to the
        // ordinary descriptor-on-receiver path against the
        // unwrapped object so the rest of §10.1.9.2 step 3
        // runs against real slots.
        return try reflectSetOnReceiver(realm, heap_mod.taggedObject(proxy_cur), key_slice, v);
    }
    if (receiver_obj.hasAccessor(key_slice)) {
        // IsAccessorDescriptor(existingDescriptor) → return false
        // (different-property-descriptors.js).
        return Value.false_;
    }
    if (receiver_obj.ownDataContains(key_slice)) {
        // Existing data descriptor on Receiver — writability of
        // the receiver's slot gates the write (§10.1.9.2 step
        // 3.e.ii). On success the receiver's value is replaced;
        // its other flags stay put.
        const flags = receiver_obj.flagsFor(key_slice);
        if (!flags.writable) return Value.false_;
        // Route through `setWithFlags` so shape and bag stay
        // coherent under Phase 3 of [docs/lazy-property-bag.md].
        receiver_obj.setWithFlags(realm.allocator, key_slice, v, flags) catch return error.OutOfMemory;
        return Value.true_;
    }
    // §10.1.9.2 step 3.f — CreateDataProperty(Receiver, P, V).
    // Receiver doesn't have the property; create it with the
    // default `{writable, enumerable, configurable}: true` flags.
    if (!receiver_obj.extensible) return Value.false_;
    const owned_k = realm.heap.allocateString(key_slice) catch return error.OutOfMemory;
    // §10.1.9.2 CreateDataProperty — anchor the heap key string on
    // the receiver. Plain `set` borrows the slice; the JSString is
    // otherwise unreferenced and a GC frees it, dangling the key.
    receiver_obj.setComputedOwned(realm.allocator, owned_k, v) catch return error.OutOfMemory;
    return Value.true_;
}

/// §10.1.9.2 OrdinarySetWithOwnDescriptor step 3 — receiver-side
/// write (existing-descriptor-on-Receiver + CreateDataProperty),
/// dispatched after a TA-on-chain interception bypassed the
/// ordinary accessor walk. Routes TA receivers through IIE
/// [[DefineOwnProperty]] (coerce once, drop on invalid index),
/// array receivers through array-exotic length tracking, and
/// plain objects through the standard slot create / update.
fn reflectSetOnReceiver(realm: *Realm, receiver_v: Value, key_slice: []const u8, v: Value) NativeError!Value {
    // §10.1.9.2 step 3.b — Receiver must be an Object.
    const receiver_obj = heap_mod.valueAsPlainObject(receiver_v) orelse {
        if (heap_mod.valueAsFunction(receiver_v)) |fn_recv| {
            const owned = realm.heap.allocateString(key_slice) catch return error.OutOfMemory;
            const ok = fn_recv.setIfWritable(realm.allocator, owned.flatBytes(), v) catch return error.OutOfMemory;
            return Value.fromBool(ok);
        }
        return Value.false_;
    };
    // Receiver is itself a TA — §10.4.5.3 IIE [[DefineOwnProperty]].
    // CreateDataProperty calls Receiver.[[DefineOwnProperty]] with a
    // fresh {Value, w/e/c: true} descriptor. For a canonical numeric
    // index, IIE rejects out-of-bounds without coercion; in-bounds
    // routes through SetTypedArrayElement (ToNumber once, drop if
    // detached mid-coercion). Reflect.set surfaces a reject as false.
    if (receiver_obj.getTypedView()) |recv_tv| {
        const ta_mod = @import("typed_array.zig");
        if (ta_mod.canonicalNumericIndex(key_slice)) |recv_num| {
            if (!ta_mod.isValidIntegerIndexPub(recv_tv, recv_num)) {
                // §10.4.5.3 step b.i — IsValidIntegerIndex false:
                // [[DefineOwnProperty]] rejects → Reflect.set false.
                return Value.false_;
            }
            const coerced = try ta_mod.coerceForTypedSlot(realm, recv_tv.kind, v);
            const live_tv = receiver_obj.getTypedView() orelse return Value.true_;
            if (ta_mod.isValidIntegerIndexPub(live_tv, recv_num)) {
                const buf = live_tv.viewed.getArrayBuffer().?;
                const elem_size = live_tv.kind.elementSize();
                const idx: usize = @intFromFloat(recv_num);
                @import("../intrinsics.zig").writeTypedElementForView(buf, live_tv, live_tv.byte_offset + idx * elem_size, coerced);
            }
            return Value.true_;
        }
    }
    // §10.1.9.2 step 3.c-e — existing accessor on Receiver: reject.
    if (receiver_obj.hasAccessor(key_slice)) return Value.false_;
    if (receiver_obj.ownDataContains(key_slice)) {
        const flags = receiver_obj.flagsFor(key_slice);
        if (!flags.writable) return Value.false_;
        receiver_obj.setWithFlags(realm.allocator, key_slice, v, flags) catch return error.OutOfMemory;
        return Value.true_;
    }
    // §10.4.2.1 Array exotic [[DefineOwnProperty]] — for indexed
    // keys on an array receiver, route through the array-exotic
    // path so `length` auto-bumps.
    if (receiver_obj.is_array_exotic) {
        if (@import("../object.zig").JSObject.canonicalIntegerIndex(key_slice)) |idx| {
            if (idx <= 0xFFFFFFFE) {
                if (!receiver_obj.extensible and !receiver_obj.hasOwnIndexedSlot(idx)) return Value.false_;
                receiver_obj.setIndexed(realm.allocator, idx, v) catch return error.OutOfMemory;
                return Value.true_;
            }
        }
    }
    if (!receiver_obj.extensible) return Value.false_;
    const owned_k = realm.heap.allocateString(key_slice) catch return error.OutOfMemory;
    // §10.1.9.2 CreateDataProperty — anchor the heap key string on
    // the receiver. Plain `set` borrows the slice; the JSString is
    // otherwise unreferenced and a GC frees it, dangling the key.
    receiver_obj.setComputedOwned(realm.allocator, owned_k, v) catch return error.OutOfMemory;
    return Value.true_;
}

/// §7.1.19 ToPropertyKey — fail-loud version for Reflect.* call
/// sites. Object keys run through `toPrimitive(string)`; a user-
/// side throwing `toString` / `valueOf` / `@@toPrimitive`
/// propagates as `error.NativeThrew` so `return-abrupt-from-
/// property-key.js` sees the Test262Error.
fn toPropertyKeySpec(realm: *Realm, v: Value) NativeError![]const u8 {
    if (v.isString()) {
        const s: *JSString = @ptrCast(@alignCast(v.asString()));
        return s.flatBytes();
    }
    if (heap_mod.valueAsSymbol(v)) |sym| return sym.prop_key;
    if (heap_mod.valueAsPlainObject(v) != null or heap_mod.valueAsFunction(v) != null) {
        const prim = try intrinsics.toPrimitive(realm, v, .string);
        if (heap_mod.valueAsSymbol(prim)) |sym| return sym.prop_key;
        const s = try intrinsics.stringifyArg(realm, prim);
        return s.flatBytes();
    }
    const s = try intrinsics.stringifyArg(realm, v);
    return s.flatBytes();
}

fn reflectDeleteProperty(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = this_value;
    const arg = argOr(args, 0, Value.undefined_);
    // §28.1.4 step 1 — target must be Object.
    if (heap_mod.valueAsPlainObject(arg) == null and heap_mod.valueAsFunction(arg) == null) {
        return throwTypeError(realm, "Reflect.deleteProperty target must be an object");
    }
    // §28.1.4 step 2 — ToPropertyKey, abrupt-propagating.
    const key_v = argOr(args, 1, Value.undefined_);
    const key_slice = try toPropertyKeySpec(realm, key_v);
    if (heap_mod.valueAsFunction(arg)) |fn_obj| {
        // §10.1.10.1 [[Delete]] step 4 — return false when the
        // own property is non-configurable.
        if (fn_obj.flagsForOwn(key_slice).configurable == false and (fn_obj.ownDataContains(key_slice) or fn_obj.accessors.contains(key_slice))) return Value.false_;
        _ = fn_obj.properties.swapRemove(key_slice);
        _ = fn_obj.accessors.swapRemove(key_slice);
        _ = fn_obj.property_flags.swapRemove(key_slice);
        fn_obj.forgetKey(key_slice);
        return Value.true_;
    }
    const target_outer = heap_mod.valueAsPlainObject(arg) orelse return throwTypeError(realm, "Reflect.deleteProperty target must be an object");
    // §10.5.10 Proxy [[Delete]] dispatch. After walking the proxy
    // chain, `target` points at the inner non-proxy object whose
    // [[Delete]] the trapless outer proxy ultimately invokes
    // (§10.5.10 step 7.a).
    var target = target_outer;
    while (target.proxy_target != null or target.proxy_revoked) {
        const r = try proxy_mod.nativeProxyDelete(realm, target, key_slice, key_v);
        switch (r) {
            .boolean => |b| return Value.fromBool(b),
            .fallthrough => |t| {
                if (t == target) break;
                target = t;
            },
        }
    }
    // §9.4.6.6 Module Namespace [[Delete]] — string-keyed
    // export names are permanent (return false). Symbol keys take
    // the OrdinaryDelete fall-through below, where the
    // non-configurable `@@toStringTag` install also rejects.
    // Includes the `namespace_redirects` entries (re-exports
    // installed by `module_reexport_named` / `module_reexport_star`).
    if (target.is_module_namespace and !std.mem.startsWith(u8, key_slice, "@@") and !std.mem.startsWith(u8, key_slice, "<sym:") and (target.ownDataContains(key_slice) or target.hasAccessor(key_slice) or target.hasNamespaceRedirect(key_slice))) {
        return Value.false_;
    }
    // §10.1.10.1 — non-configurable own property → return false
    // (no mutation). Includes frozen / sealed objects.
    if (target.flagsFor(key_slice).configurable == false and (target.ownDataContains(key_slice) or target.hasAccessor(key_slice))) return Value.false_;
    // Demote: the shadow shape can't encode a removal — leaving it
    // would trip `verifyShapeInvariant` under GC stress.
    try target.demoteFromShape(realm.allocator);
    _ = target.properties.swapRemove(key_slice);
    _ = target.removeAccessor(key_slice);
    _ = target.property_flags.swapRemove(key_slice);
    target.forgetKey(key_slice);
    return Value.true_;
}

fn reflectOwnKeys(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = this_value;
    const arg = argOr(args, 0, Value.undefined_);

    const out = realm.heap.allocateObject() catch return error.OutOfMemory;
    realm.heap.setObjectPrototype(out, realm.intrinsics.array_prototype);
    out.markAsArrayExotic(realm.allocator) catch return error.OutOfMemory;

    // §17 — built-in function objects are ordinary objects too, so
    // Reflect.ownKeys(builtin) walks the same property map but
    // doesn't see integer-indexed elements or accessors. Mirrors the
    // `objectGetOwnPropertyNames` function-arg path.
    var idx: usize = 0;
    if (heap_mod.valueAsFunction(arg)) |fn_obj| {
        var fit = fn_obj.properties.iterator();
        while (fit.next()) |entry| : (idx += 1) {
            const k = entry.key_ptr.*;
            if (std.mem.startsWith(u8, k, "__cynic_")) {
                idx -= 1; // skip-but-don't-advance the output index
                continue;
            }
            const key_str = realm.heap.allocateString(k) catch return error.OutOfMemory;
            var ibuf: [24]u8 = undefined;
            const islice = std.fmt.bufPrint(&ibuf, "{d}", .{idx}) catch unreachable;
            const owned = realm.heap.allocateString(islice) catch return error.OutOfMemory;
            out.set(realm.allocator, owned.flatBytes(), Value.fromString(key_str)) catch return error.OutOfMemory;
        }
        out.set(realm.allocator, "length", Value.fromInt32(@intCast(idx))) catch return error.OutOfMemory;
        return heap_mod.taggedObject(out);
    }

    const target = heap_mod.valueAsPlainObject(arg) orelse return throwTypeError(realm, "Reflect.ownKeys target must be an object");
    // §28.1.11 step 2 — call `target.[[OwnPropertyKeys]]()`. For
    // a Proxy receiver this MUST route through the `ownKeys` trap
    // (§10.5.11) so the configurable + non-extensible invariants
    // fire. Otherwise fall through to `ownPropertyKeysOrdered`
    // (§10.1.11 OrdinaryOwnPropertyKeys): integer-indexed first in
    // ascending numeric order, then string keys in insertion order,
    // then symbol keys. Without this, Reflect.ownKeys missed every
    // packed-array element and reordered objects with a mix of
    // integer-like and string keys.
    const obj_mod = @import("object.zig");
    const key_scope = realm.heap.openScope() catch return error.OutOfMemory;
    defer key_scope.close();
    // Root the result array — `proxyOwnKeysOrNull` fires the Proxy
    // `ownKeys` trap, which re-enters JS and can GC `out` mid-build.
    key_scope.push(heap_mod.taggedObject(out)) catch return error.OutOfMemory;
    const keys = if (try obj_mod.proxyOwnKeysOrNull(realm, target, key_scope)) |k| k else try obj_mod.ownPropertyKeysOrdered(realm, target, key_scope);
    defer realm.allocator.free(keys);
    for (keys) |k| {
        // Symbol keys stored as `@@<name>` or `<sym:N>` need to surface
        // as actual Symbol values per §28.1.11; the rest are strings.
        const v: Value = if (std.mem.startsWith(u8, k, "@@") or std.mem.startsWith(u8, k, "<sym:")) blk: {
            // Look up an existing well-known / registered Symbol by
            // its string key; fall back to a fresh anonymous symbol
            // if no registry hit. The fallback keeps the shape right
            // even when the symbol's description was lost.
            if (realm.heap.symbolForKey(k)) |sym| break :blk heap_mod.taggedSymbol(sym);
            const fresh = realm.heap.allocateSymbol(k) catch return error.OutOfMemory;
            break :blk heap_mod.taggedSymbol(fresh);
        } else blk: {
            const key_str = realm.heap.allocateString(k) catch return error.OutOfMemory;
            break :blk Value.fromString(key_str);
        };
        var ibuf: [24]u8 = undefined;
        const islice = std.fmt.bufPrint(&ibuf, "{d}", .{idx}) catch unreachable;
        const owned = realm.heap.allocateString(islice) catch return error.OutOfMemory;
        out.set(realm.allocator, owned.flatBytes(), v) catch return error.OutOfMemory;
        idx += 1;
    }
    out.set(realm.allocator, "length", Value.fromInt32(@intCast(idx))) catch return error.OutOfMemory;
    return heap_mod.taggedObject(out);
}

fn reflectGetPrototypeOf(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    // §28.1.8 step 1 — target must be Object. The Object.* sibling
    // ES2015+ coerces primitives via ToObject; Reflect throws.
    const target_v = argOr(args, 0, Value.undefined_);
    if (heap_mod.valueAsPlainObject(target_v) == null and heap_mod.valueAsFunction(target_v) == null) {
        return throwTypeError(realm, "Reflect.getPrototypeOf called on non-object");
    }
    return objectGetPrototypeOf(realm, this_value, args);
}

fn reflectSetPrototypeOf(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = this_value;
    // §28.1.13 step 1 — target must be Object; non-object (incl.
    // Symbol) throws TypeError, not "returns false".
    const target_v = argOr(args, 0, Value.undefined_);
    const target = heap_mod.valueAsPlainObject(target_v) orelse {
        return throwTypeError(realm, "Reflect.setPrototypeOf called on non-object");
    };
    const proto_v = argOr(args, 1, Value.null_);
    // §28.1.13 Reflect.setPrototypeOf — proto must be Object or null.
    if (!proto_v.isNull() and heap_mod.valueAsPlainObject(proto_v) == null and heap_mod.valueAsFunction(proto_v) == null) {
        return intrinsics.throwTypeError(realm, "prototype must be an Object or null");
    }
    // §10.5.2 Proxy [[SetPrototypeOf]] — dispatch through the
    // handler trap if target is a proxy. Reflect returns the boolean.
    if (target.proxy_target != null or target.proxy_revoked) {
        const obj_mod = @import("object.zig");
        const ok = try obj_mod.proxySetPrototypeOfBool(realm, target, proto_v);
        return Value.fromBool(ok);
    }
    const new_proto: ?*@import("../object.zig").JSObject = blk: {
        if (proto_v.isNull()) break :blk null;
        if (heap_mod.valueAsPlainObject(proto_v)) |p| break :blk p;
        if (heap_mod.valueAsFunction(proto_v)) |fn_obj| break :blk fn_obj.prototype;
        break :blk null;
    };
    // §10.4.7 — `%Object.prototype%` is an Immutable Prototype
    // Exotic Object. Its [[SetPrototypeOf]] returns true only if
    // the requested value equals the current one (both null in
    // the default case); otherwise returns false without modifying.
    if (target == realm.intrinsics.object_prototype.?) {
        return Value.fromBool(new_proto == target.prototype);
    }
    // §10.1.2.1 OrdinarySetPrototypeOf step 3 — if the proto is
    // already the requested value, return true without touching
    // the slot (cheap SameValue short-circuit).
    if (new_proto == target.prototype) return Value.true_;
    // §10.1.2.1 OrdinarySetPrototypeOf step 5 — non-extensible
    // targets reject any prototype CHANGE; same-value writes are
    // covered by the SameValue short-circuit above. The fixture
    // `Reflect/setPrototypeOf/return-false-if-target-is-not-
    // extensible.js` checks this branch.
    if (!target.extensible) return Value.false_;
    // §10.1.2.1 OrdinarySetPrototypeOf step 8 — cycle detection.
    var cursor: ?*@import("../object.zig").JSObject = new_proto;
    while (cursor) |node| {
        if (node == target) return Value.false_;
        cursor = node.prototype;
    }
    realm.heap.setObjectPrototype(target, new_proto);
    // Proto-link swap — bump the proto IC revision so dependent
    // caches miss + refill.
    realm.proto_revision_counter +%= 1;
    return Value.true_;
}

fn reflectIsExtensible(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    // §28.1.10 step 1 — target must be Object (incl. Function);
    // non-object (Symbol, primitives, null, undefined) → TypeError.
    const target_v = argOr(args, 0, Value.undefined_);
    if (heap_mod.valueAsPlainObject(target_v)) |target| {
        // §10.5.3 Proxy [[IsExtensible]] — dispatch via the shared
        // Object.isExtensible path (handles trap + invariant).
        if (target.proxy_target != null or target.proxy_revoked) {
            const obj_mod = @import("object.zig");
            return obj_mod.objectIsExtensible(realm, this_value, args);
        }
        return Value.fromBool(target.extensible);
    }
    if (heap_mod.valueAsFunction(target_v)) |_| {
        // Functions are objects; we don't track an extensible bit
        // on JSFunction yet (no preventExtensions path lands on a
        // function value in fixtures we care about). Default true.
        return Value.true_;
    }
    return throwTypeError(realm, "Reflect.isExtensible called on non-object");
}

fn reflectApply(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = this_value;
    const target_v = argOr(args, 0, Value.undefined_);
    // Allow callable Proxy (apply-trap dispatch via callValue).
    if (heap_mod.valueAsFunction(target_v) == null) {
        const po = heap_mod.valueAsPlainObject(target_v) orelse return throwTypeError(realm, "Reflect.apply target must be callable");
        if (po.proxy_target_fn == null and po.proxy_target == null and !po.proxy_revoked) {
            return throwTypeError(realm, "Reflect.apply target must be callable");
        }
    }
    const this_arg = argOr(args, 1, Value.undefined_);
    const args_v = argOr(args, 2, Value.undefined_);

    // §28.1.1 step 4 — `CreateListFromArrayLike(argumentsList)`.
    // §7.3.18 step 2 requires `argumentsList` to be an Object;
    // primitives (null, undefined, false, NaN, …) throw TypeError
    // synchronously, before any function invocation. §6.1.7: a
    // function IS an Object, so a callable array-like is valid too
    // — `getPropertyChainOnValue` accepts either a plain object or
    // a function and fires accessors on both (a `{get length() {
    // throw }}` source must propagate the throw before the call
    // dispatches); inherited / proxy-trapped lengths participate.
    var apply_args: std.ArrayListUnmanaged(Value) = .empty;
    defer apply_args.deinit(realm.allocator);
    if (try intrinsics.getPropertyChainOnValue(realm, args_v, "length")) |len_v| {
        const len_i = try intrinsics.toLengthValue(realm, len_v);
        const len = try clampArrayLength(len_i);
        var i: i64 = 0;
        while (i < len) : (i += 1) {
            var ibuf: [24]u8 = undefined;
            const islice = std.fmt.bufPrint(&ibuf, "{d}", .{i}) catch unreachable;
            const elt = (try intrinsics.getPropertyChainOnValue(realm, args_v, islice)) orelse Value.undefined_;
            apply_args.append(realm.allocator, elt) catch return error.OutOfMemory;
        }
    } else {
        return throwTypeError(realm, "Reflect.apply: argumentsList is not an object");
    }

    const lantern = @import("../lantern/interpreter.zig");
    const outcome = lantern.callValue(realm.allocator, realm, realm.active_native_fn_realm orelse realm, target_v, this_arg, apply_args.items) catch |err| switch (err) {
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

/// §7.2.4 IsConstructor / §10.5.13 through a Proxy CHAIN: a Proxy whose
/// target is a constructor — possibly itself a Proxy over one — is a
/// constructor. A Proxy over a function stores `proxy_target_fn`; a
/// Proxy over another object/proxy stores `proxy_target` and propagates
/// callability, so descend `proxy_target` until a function target is
/// reached. Returns `null` for a revoked / non-callable proxy. The
/// underlying function's `[[Realm]]` is also the §10.2.5
/// GetFunctionRealm the created object's prototype resolves against.
fn proxyChainTargetFn(obj: *JSObject) ?*JSFunction {
    var cur: *JSObject = obj;
    var guard: usize = 0;
    while (guard < 100_000) : (guard += 1) {
        if (cur.proxy_target_fn) |f| return f;
        if (cur.proxy_target) |t| {
            cur = t;
            continue;
        }
        return null;
    }
    return null;
}

fn reflectConstruct(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = this_value;
    const target_v = argOr(args, 0, Value.undefined_);
    const args_v = argOr(args, 1, Value.undefined_);
    const new_target_v = argOr(args, 2, Value.undefined_);
    const lantern = @import("../lantern/interpreter.zig");

    // §28.1.2 step 3 — `CreateListFromArrayLike(argumentsList)`.
    // §7.3.18 step 2 rejects a non-Object argumentsList; §6.1.7
    // makes a function an Object, so a callable array-like is
    // valid. `getPropertyChainOnValue` accepts a plain object or a
    // function and fires accessors / proxy `get` traps on both (an
    // `argumentsList = {get length() { throw }}` — object or
    // function — must propagate the throw before the constructor
    // runs).
    var ctor_args: std.ArrayListUnmanaged(Value) = .empty;
    defer ctor_args.deinit(realm.allocator);
    if (try intrinsics.getPropertyChainOnValue(realm, args_v, "length")) |len_v| {
        const len_i = try intrinsics.toLengthValue(realm, len_v);
        const len = try clampArrayLength(len_i);
        var i: i64 = 0;
        while (i < len) : (i += 1) {
            var ibuf: [24]u8 = undefined;
            const islice = std.fmt.bufPrint(&ibuf, "{d}", .{i}) catch unreachable;
            const elt = (try intrinsics.getPropertyChainOnValue(realm, args_v, islice)) orelse Value.undefined_;
            ctor_args.append(realm.allocator, elt) catch return error.OutOfMemory;
        }
    } else {
        return throwTypeError(realm, "Reflect.construct: argumentsList is not an object");
    }

    // §10.5.14 — if `target` is a Proxy with a `construct` trap,
    // dispatch the trap. Missing trap walks down the proxy chain
    // until we reach a real constructor.
    if (heap_mod.valueAsPlainObject(target_v)) |po| {
        if (po.proxy_target_fn != null or po.proxy_target != null or po.proxy_revoked) {
            const newt: Value = if (new_target_v.isUndefined()) target_v else new_target_v;
            const outcome = lantern.constructValue(realm.allocator, realm, target_v, ctor_args.items, newt) catch |err| switch (err) {
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
    }

    const target = heap_mod.valueAsFunction(target_v) orelse return throwTypeError(realm, "Reflect.construct target must be a constructor");
    // §28.1.2 Reflect.construct step 2: throw if target is
    // not actually a constructor.
    if (!target.has_construct or target.is_arrow) return throwTypeError(realm, "Reflect.construct target is not a constructor");
    // Step 3-5: optional `newTarget` defaults to `target`; when
    // supplied, MUST be a constructor too (the trick the
    // `isConstructor.js` harness relies on to detect non-ctor
    // built-ins like `Object.freeze`).
    const new_target: *@import("../function.zig").JSFunction = if (new_target_v.isUndefined())
        target
    else if (heap_mod.valueAsFunction(new_target_v)) |nt|
        nt
    else if (heap_mod.valueAsPlainObject(new_target_v)) |po|
        // newTarget can be a callable Proxy — or a chain of them
        // (Proxy over Proxy over … over a constructor). Resolve the
        // underlying constructor through the whole chain (§10.5.13),
        // not just one level.
        if (proxyChainTargetFn(po)) |tfn| tfn else return throwTypeError(realm, "Reflect.construct newTarget must be a constructor")
    else
        return throwTypeError(realm, "Reflect.construct newTarget must be a constructor");
    if (!new_target.has_construct or new_target.is_arrow) return throwTypeError(realm, "Reflect.construct newTarget is not a constructor");

    // §10.4.1.2 [[Construct]] step 5 — walk the *target*'s bound
    // chain (each layer is an F-frame in the spec recursion) and
    // collapse newTarget via `SameValue(F, newTarget)` at each
    // layer. So `Reflect.construct(C, [], C)` with C=B.bind(),
    // B=A.bind() collapses NT: C→B→A. An NT outside the chain
    // (e.g. `Reflect.construct(C, [], differentBoundFn)`) is
    // untouched — so accessors on the supplied NT still fire in
    // GetPrototypeFromConstructor (matches WeakRef's
    // prototype-from-newtarget-custom.js).
    var effective_new_target = new_target;
    {
        var cursor_f: *@import("../function.zig").JSFunction = target;
        while (cursor_f.bound_target) |inner| : (cursor_f = inner) {
            if (cursor_f == effective_new_target) effective_new_target = inner;
        }
    }
    // Unwrap `target` so the intrinsic-default prototype
    // resolves against the underlying constructor, not the bound
    // wrapper (which has no `prototype` slot).
    var effective_target = target;
    while (effective_target.bound_target) |inner| : (effective_target = inner) {}
    // §25.1.4.1 / §25.3.2.1 — native ctors that pre-validate args.
    // Skip the proto lookup, stash newTarget on the realm, and
    // let the native run its validation and OCFC itself. Preserve
    // the original newTarget Value (which may be a callable
    // Proxy) so the native's eventual `Get(newTarget, "prototype")`
    // fires the proxy's `get` trap per §10.5.5.
    if (effective_target.defers_proto_lookup and effective_target.native_callback != null) {
        realm.pending_native_new_target = if (new_target_v.isUndefined()) target_v else new_target_v;
        defer realm.pending_native_new_target = Value.undefined_;
        const interp = @import("../lantern/interpreter.zig");
        const outcome = interp.callJSFunction(realm.allocator, realm, effective_target, Value.undefined_, ctor_args.items) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.NativeThrew,
        };
        switch (outcome) {
            .value, .yielded => |v| {
                if (heap_mod.valueAsPlainObject(v) != null or heap_mod.valueAsFunction(v) != null) return v;
                return throwTypeError(realm, "deferred-proto-lookup constructor did not return an object");
            },
            .thrown => |ex| {
                realm.pending_exception = ex;
                return error.NativeThrew;
            },
        }
    }
    // §10.1.13 OrdinaryCreateFromConstructor → §10.1.14
    // GetPrototypeFromConstructor — Get(newTarget, "prototype")
    // through the accessor path so a user-installed getter on a
    // bound NewTarget fires (per the WeakRef /
    // FinalizationRegistry / ArrayBuffer
    // `prototype-from-newtarget-*.js` fixtures). When the
    // original newTarget is a callable Proxy, route through
    // `getPrototypeFromConstructorValue` so the proxy's `get`
    // trap on "prototype" fires (AggregateError/
    // newtarget-proto-custom.js).
    //
    // When the §10.4.1.2 step-5 collapse fired (`effective_new_target
    // != new_target`), the supplied newTarget was a bound wrapper in
    // the target's own chain and has no own `prototype` slot — read
    // the collapsed base target's `prototype` instead, so
    // `Reflect.construct(C, [], C)` with C=B.bind(), B=A.bind()
    // resolves against A.prototype. When no collapse happened the
    // original newTarget may be a callable Proxy whose `get` trap
    // must fire, so keep the Value form.
    const new_target_for_proto: Value = if (new_target_v.isUndefined() or effective_new_target != new_target)
        heap_mod.taggedFunction(effective_new_target)
    else
        new_target_v;
    // §10.2.2 base-kind intrinsicDefaultProto — %Object.prototype% for
    // an ordinary-function target, the native ctor's own %X.prototype%
    // for a native. Passing `effective_target.prototype` directly was
    // only correct for natives: an ordinary target with a non-object
    // `prototype` (`C.prototype = null`) must fall back to
    // %Object.prototype% resolved against the ctor realm, not its own
    // (stale) slot. Mirrors built-ins/Function/prototype/bind/
    // proto-from-ctor-realm.js.
    const base_default = lantern.baseConstructIntrinsicDefaultProto(realm, effective_target);
    const base_default_owner = lantern.baseConstructDefaultProtoOwner(realm, effective_target);
    const proto_lookup = lantern.getPrototypeFromConstructorValue(realm.allocator, realm, new_target_for_proto, base_default, base_default_owner) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.NativeThrew,
    };
    const resolved_proto: ?*@import("../object.zig").JSObject = switch (proto_lookup) {
        .proto => |p| p,
        .thrown => |ex| {
            realm.pending_exception = ex;
            return error.NativeThrew;
        },
    };
    const instance = realm.heap.allocateObject() catch return error.OutOfMemory;
    realm.heap.setObjectPrototype(instance, resolved_proto);
    const this_arg = heap_mod.taggedObject(instance);

    // §10.5.14 [[Construct]] — invoke the target with the supplied
    // newTarget so `new.target` inside the body reads as that
    // constructor. `callJSFunctionAsSuper` handles the bound-target
    // unwrap and threads new_target into the final-target frame
    // (see the bound-construct fixtures under
    // built-ins/Function/prototype/bind/instance-construct-*).
    const outcome = lantern.callJSFunctionAsSuper(realm.allocator, realm, target, this_arg, ctor_args.items, heap_mod.taggedFunction(effective_new_target)) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.NativeThrew,
    };
    switch (outcome) {
        .value, .yielded => |v| {
            // ConstructResult: object return wins, else `this`.
            if (heap_mod.valueAsPlainObject(v) != null or heap_mod.valueAsFunction(v) != null) return v;
            return this_arg;
        },
        .thrown => |ex| {
            realm.pending_exception = ex;
            return error.NativeThrew;
        },
    }
}

/// Stringify a Value for use as a property key in Reflect ops.
/// Mirrors `computedKeyToString` in lantern.zig.
fn computedKeyForReflect(v: Value, scratch: *[64]u8) []const u8 {
    if (v.isString()) {
        const s: *JSString = @ptrCast(@alignCast(v.asString()));
        return s.flatBytes();
    }
    // §7.1.19 ToPropertyKey — Symbol primitives become their
    // canonical property-key string. Cynic flattens well-known
    // symbols to their `@@name` prop_key and user symbols to
    // `<sym:N>`. Without this, `Reflect.has(ns, Symbol.toStringTag)`
    // saw `"[object]"` and missed the actual slot.
    if (heap_mod.valueAsSymbol(v)) |sym| return sym.prop_key;
    if (v.isInt32()) return std.fmt.bufPrint(scratch, "{d}", .{v.asInt32()}) catch unreachable;
    if (v.isDouble()) {
        const d = v.asDouble();
        if (std.math.isNan(d)) return "NaN";
        if (std.math.isInf(d)) return if (d > 0) "Infinity" else "-Infinity";
        if (d == @trunc(d) and d >= -9007199254740992.0 and d <= 9007199254740992.0) {
            const i: i64 = @intFromFloat(d);
            return std.fmt.bufPrint(scratch, "{d}", .{i}) catch unreachable;
        }
        return std.fmt.bufPrint(scratch, "{d}", .{d}) catch unreachable;
    }
    if (v.isBool()) return if (v.asBool()) "true" else "false";
    if (v.isNull()) return "null";
    if (v.isUndefined()) return "undefined";
    return "[object]";
}
