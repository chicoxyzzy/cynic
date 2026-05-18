//! §28.2 Proxy — extracted from `intrinsics.zig`. The constructor
//! allocates a fresh exotic object whose `[[ProxyTarget]]` and
//! `[[ProxyHandler]]` slots point at the user-supplied operands.
//! The interpreter's property opcodes (and a few cross-checked
//! built-ins) consult `proxy_target` before falling through to
//! the regular property bag, so traps fire on `get`, `set`,
//! `has`, `deleteProperty`, `apply`, and `construct`.
//!
//! `Proxy.revocable(target, handler)` (§28.2.2.1) returns
//! `{ proxy, revoke }`. The revoke function carries a
//! `[[RevocableProxy]]` slot (`JSFunction.revocable_proxy`);
//! the interpreter's call dispatch recognises it, nulls the
//! proxy's `proxy_target` / `proxy_handler` / `proxy_target_fn`
//! slots, sets `proxy_revoked = true`, and returns `undefined`.

const std = @import("std");

const Realm = @import("../realm.zig").Realm;
const Value = @import("../value.zig").Value;
const NativeError = @import("../function.zig").NativeError;
const heap_mod = @import("../heap.zig");
const intrinsics = @import("../intrinsics.zig");

const installConstructor = intrinsics.installConstructor;
const installNativeMethod = intrinsics.installNativeMethod;
const throwTypeError = intrinsics.throwTypeError;

// ── §28.2 Proxy ─────────────────────────────────────────────────────────────

pub fn install(realm: *Realm) !void {
    const installed = try installConstructor(realm, .{
        .name = "Proxy",
        .ctor = proxyConstructor,
        .arity = 2,
        .set_home_object = false,
    });
    // §28.2 — the Proxy constructor does NOT have a `prototype`
    // property. Proxy exotic objects don't have a [[Prototype]]
    // internal slot that requires initialization (the [[Prototype]]
    // is dictated by the wrapped target). Drop the prototype the
    // generic `installConstructor` set so
    // `'prototype' in Proxy` / `Object.getOwnPropertyDescriptor(Proxy,
    // 'prototype')` match V8 / JSC / SpiderMonkey.
    installed.ctor.prototype = null;
    // §28.2.2.1 Proxy.revocable — static method, length 2.
    try installNativeMethod(realm, installed.ctor, "revocable", proxyRevocable, 2);

    // §28.2.2 — `Proxy` does not have a `prototype` own
    // property (the spec defines Proxy.revocable and no
    // others, and §28.2.2.2 is just `length=2`). The shared
    // `installConstructor` helper above creates one by default
    // for ordinary constructors; drop it so reads return
    // `undefined`. Trips the
    // `class P extends Proxy {}` path (§15.7.14 step 7.g):
    // Get(Proxy, 'prototype') = undefined → not Object / null
    // → TypeError, matching V8 / SpiderMonkey.
    installed.ctor.prototype = null;
}

fn proxyConstructor(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = this_value;
    if (args.len < 2) return throwTypeError(realm, "Proxy requires (target, handler)");
    const handler = heap_mod.valueAsPlainObject(args[1]) orelse return throwTypeError(realm, "Proxy handler must be an object");
    // §10.5.1 ProxyCreate — the spec accepts a revoked proxy as
    // either target or handler at creation time; the resulting
    // proxy will eagerly throw on first internal-method dispatch.
    const proxy = realm.heap.allocateObject() catch return error.OutOfMemory;
    proxy.proxy_handler = handler;
    if (heap_mod.valueAsPlainObject(args[0])) |target| {
        proxy.proxy_target = target;
        proxy.prototype = target.prototype;
        // §10.5 ProxyCreate — propagate callability from the
        // wrapped proxy. Wrapping a revoked-but-once-callable
        // proxy yields another callable proxy.
        if (target.proxy_callable) {
            proxy.proxy_callable = true;
            proxy.prototype = realm.intrinsics.function_prototype;
        }
    } else if (heap_mod.valueAsFunction(args[0])) |target_fn| {
        // Callable target — the proxy is itself callable via
        // `proxy_target_fn`. §10.5.1 ProxyCreate sets the proxy's
        // [[Prototype]] to the target's [[Prototype]]; for a
        // function that's `%Function.prototype%` (held in
        // JSFunction.proto), so `proxy.call` / `.apply` /
        // `.bind` resolve.
        proxy.proxy_target_fn = target_fn;
        proxy.proxy_callable = true;
        proxy.prototype = target_fn.proto orelse realm.intrinsics.function_prototype;
    } else {
        return throwTypeError(realm, "Proxy target must be an object or function");
    }
    return heap_mod.taggedObject(proxy);
}

/// §28.2.2.1 Proxy.revocable(target, handler) — returns a fresh
/// object `{ proxy, revoke }`. The revoke function carries a
/// `[[RevocableProxy]]` slot pointing at `proxy`; the interpreter's
/// call dispatch recognises this and clears the proxy's internal
/// slots when called.
fn proxyRevocable(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = this_value;
    // ProxyCreate(target, handler) — share the constructor body.
    const proxy_v = try proxyConstructor(realm, Value.undefined_, args);
    const proxy_obj = heap_mod.valueAsPlainObject(proxy_v) orelse return throwTypeError(realm, "Proxy.revocable: ProxyCreate failed");

    // §28.2.2.1.1 — the revocation function is anonymous, has
    // length 0, and is not a constructor. The native body itself
    // is a no-op stub; the interpreter inspects `revocable_proxy`
    // before calling it.
    const revoke_fn = realm.heap.allocateFunctionNative(proxyRevokeNoop, 0, "") catch return error.OutOfMemory;
    revoke_fn.proto = realm.intrinsics.function_prototype;
    revoke_fn.has_construct = false;
    revoke_fn.revocable_proxy = proxy_obj;

    const result = realm.heap.allocateObject() catch return error.OutOfMemory;
    result.prototype = realm.intrinsics.object_prototype;
    result.set(realm.allocator, "proxy", proxy_v) catch return error.OutOfMemory;
    result.set(realm.allocator, "revoke", heap_mod.taggedFunction(revoke_fn)) catch return error.OutOfMemory;
    return heap_mod.taggedObject(result);
}

/// Placeholder native body for the revoke function. Never reached:
/// the interpreter dispatch consumes `revocable_proxy != null`
/// before falling through to `native_callback`.
fn proxyRevokeNoop(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = realm;
    _ = this_value;
    _ = args;
    return Value.undefined_;
}

const JSObject = @import("../object.zig").JSObject;
const interpreter = @import("../interpreter.zig");

/// Outcome of a native-side proxy dispatch. `.fallthrough` means
/// the caller should perform the ordinary internal-method action
/// against the returned target (either because no trap was
/// installed, or because the target is itself a proxy and the
/// caller wants to walk further).
pub const NativeProxyOutcome = union(enum) {
    value: Value,
    fallthrough: *JSObject,
};

fn raiseRevoked(realm: *Realm, op: []const u8) NativeError {
    _ = throwTypeError(realm, op) catch {};
    return error.NativeThrew;
}

fn callTrap(realm: *Realm, trap_fn: *@import("../function.zig").JSFunction, handler: *JSObject, args: []const Value) NativeError!Value {
    const outcome = interpreter.callJSFunction(realm.allocator, realm, trap_fn, heap_mod.taggedObject(handler), args) catch |err| switch (err) {
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

/// §10.5.5 [[Get]] (P, Receiver) — native dispatcher for callers
/// that aren't bytecode-driven (Reflect.get, host code).
pub fn nativeProxyGet(realm: *Realm, proxy: *JSObject, key: []const u8, receiver: Value) NativeError!NativeProxyOutcome {
    if (proxy.proxy_revoked) return raiseRevoked(realm, "Cannot perform 'get' on a proxy that has been revoked");
    const target = proxy.proxy_target orelse return .{ .fallthrough = proxy };
    const handler = proxy.proxy_handler orelse return raiseRevoked(realm, "proxy handler slot is null");
    const trap_v = handler.get("get");
    if (trap_v.isUndefined() or trap_v.isNull()) return .{ .fallthrough = target };
    const trap_fn = heap_mod.valueAsFunction(trap_v) orelse return throwTypeError(realm, "Proxy 'get' trap is not callable");
    const key_str = realm.heap.allocateString(key) catch return error.OutOfMemory;
    const args = [_]Value{ heap_mod.taggedObject(target), Value.fromString(key_str), receiver };
    const v = try callTrap(realm, trap_fn, handler, &args);
    // §10.5.5 invariants: non-configurable non-writable data prop
    // must match; non-configurable accessor with undefined get
    // requires trap to return undefined.
    if (target.property_flags.get(key)) |flags| {
        if (target.properties.get(key)) |target_v| {
            if (!flags.configurable and !flags.writable) {
                if (!intrinsics.sameValue(target_v, v)) {
                    return throwTypeError(realm, "proxy 'get' trap returned mismatched value for non-writable non-configurable data property");
                }
            }
        }
    }
    if (target.accessors.get(key)) |acc| {
        const flags = target.flagsFor(key);
        if (!flags.configurable and acc.getter == null) {
            if (!v.isUndefined()) {
                return throwTypeError(realm, "proxy 'get' trap returned non-undefined for non-configurable accessor with no getter");
            }
        }
    }
    return .{ .value = v };
}

/// §10.5.6 [[Set]] (P, V, Receiver) — native dispatcher. Returns
/// the boolean result of the trap (ToBoolean of trap return).
/// Caller is responsible for choosing between strict-throw and
/// non-strict-return-false; this helper itself never throws on a
/// merely-falsy return.
pub fn nativeProxySet(realm: *Realm, proxy: *JSObject, key: []const u8, value: Value, receiver: Value) NativeError!union(enum) { boolean: bool, fallthrough: *JSObject } {
    if (proxy.proxy_revoked) return raiseRevoked(realm, "Cannot perform 'set' on a proxy that has been revoked");
    const target = proxy.proxy_target orelse return .{ .fallthrough = proxy };
    const handler = proxy.proxy_handler orelse return raiseRevoked(realm, "proxy handler slot is null");
    const trap_v = handler.get("set");
    if (trap_v.isUndefined() or trap_v.isNull()) return .{ .fallthrough = target };
    const trap_fn = heap_mod.valueAsFunction(trap_v) orelse return throwTypeError(realm, "Proxy 'set' trap is not callable");
    const key_str = realm.heap.allocateString(key) catch return error.OutOfMemory;
    const args = [_]Value{ heap_mod.taggedObject(target), Value.fromString(key_str), value, receiver };
    const v = try callTrap(realm, trap_fn, handler, &args);
    const arith = @import("../interpreter_arith.zig");
    if (!arith.toBoolean(v)) return .{ .boolean = false };
    // §10.5.6 invariants.
    if (target.property_flags.get(key)) |flags| {
        if (target.properties.get(key)) |target_v| {
            if (!flags.configurable and !flags.writable) {
                if (!intrinsics.sameValue(target_v, value)) {
                    return throwTypeError(realm, "proxy 'set' trap reported success for non-writable non-configurable data property");
                }
            }
        }
    }
    if (target.accessors.get(key)) |acc| {
        const flags = target.flagsFor(key);
        if (!flags.configurable and acc.setter == null) {
            return throwTypeError(realm, "proxy 'set' trap reported success for non-configurable accessor with no setter");
        }
    }
    return .{ .boolean = true };
}

/// §10.5.7 [[HasProperty]] (P) — native dispatcher.
pub fn nativeProxyHas(realm: *Realm, proxy: *JSObject, key: []const u8) NativeError!union(enum) { boolean: bool, fallthrough: *JSObject } {
    if (proxy.proxy_revoked) return raiseRevoked(realm, "Cannot perform 'has' on a proxy that has been revoked");
    const target = proxy.proxy_target orelse return .{ .fallthrough = proxy };
    const handler = proxy.proxy_handler orelse return raiseRevoked(realm, "proxy handler slot is null");
    const trap_v = handler.get("has");
    if (trap_v.isUndefined() or trap_v.isNull()) return .{ .fallthrough = target };
    const trap_fn = heap_mod.valueAsFunction(trap_v) orelse return throwTypeError(realm, "Proxy 'has' trap is not callable");
    const key_str = realm.heap.allocateString(key) catch return error.OutOfMemory;
    const args = [_]Value{ heap_mod.taggedObject(target), Value.fromString(key_str) };
    const v = try callTrap(realm, trap_fn, handler, &args);
    const arith = @import("../interpreter_arith.zig");
    const b = arith.toBoolean(v);
    // §10.5.7 invariants — can't pretend a non-configurable own
    // property doesn't exist, nor an own property of a non-
    // extensible target.
    if (!b) {
        const has_own = target.properties.contains(key) or target.accessors.contains(key);
        if (has_own) {
            const flags = target.flagsFor(key);
            if (!flags.configurable) {
                return throwTypeError(realm, "proxy 'has' trap returned false for non-configurable own property");
            }
            if (!target.extensible) {
                return throwTypeError(realm, "proxy 'has' trap returned false for own property of non-extensible target");
            }
        }
    }
    return .{ .boolean = b };
}

/// §10.5.10 [[Delete]] (P) — native dispatcher.
pub fn nativeProxyDelete(realm: *Realm, proxy: *JSObject, key: []const u8) NativeError!union(enum) { boolean: bool, fallthrough: *JSObject } {
    if (proxy.proxy_revoked) return raiseRevoked(realm, "Cannot perform 'deleteProperty' on a proxy that has been revoked");
    const target = proxy.proxy_target orelse return .{ .fallthrough = proxy };
    const handler = proxy.proxy_handler orelse return raiseRevoked(realm, "proxy handler slot is null");
    const trap_v = handler.get("deleteProperty");
    if (trap_v.isUndefined() or trap_v.isNull()) return .{ .fallthrough = target };
    const trap_fn = heap_mod.valueAsFunction(trap_v) orelse return throwTypeError(realm, "Proxy 'deleteProperty' trap is not callable");
    const key_str = realm.heap.allocateString(key) catch return error.OutOfMemory;
    const args = [_]Value{ heap_mod.taggedObject(target), Value.fromString(key_str) };
    const v = try callTrap(realm, trap_fn, handler, &args);
    const arith = @import("../interpreter_arith.zig");
    const b = arith.toBoolean(v);
    if (b) {
        // §10.5.10 invariants — can't report success for a non-
        // configurable own property, nor for an own property of a
        // non-extensible target (§10.5.10 step 14 added by the
        // `proxy-missing-checks` proposal).
        const has_own = target.properties.contains(key) or target.accessors.contains(key);
        if (has_own) {
            const flags = target.flagsFor(key);
            if (!flags.configurable) {
                return throwTypeError(realm, "proxy 'deleteProperty' trap reported success for non-configurable own property");
            }
            if (!target.extensible) {
                return throwTypeError(realm, "proxy 'deleteProperty' trap reported success for own property of non-extensible target");
            }
        }
    }
    return .{ .boolean = b };
}
