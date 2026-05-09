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
        .name = "Proxy", .ctor = proxyConstructor, .arity = 2,
        .set_home_object = false,
    });
    // §28.2.2.1 Proxy.revocable — static method, length 2.
    try installNativeMethod(realm, installed.ctor, "revocable", proxyRevocable, 2);
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
