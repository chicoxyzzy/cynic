//! §28.2 Proxy — extracted from `intrinsics.zig`. The constructor
//! allocates a fresh exotic object whose `[[ProxyTarget]]` and
//! `[[ProxyHandler]]` slots point at the user-supplied operands.
//! The interpreter's property opcodes (and a few cross-checked
//! built-ins) consult `proxy_target` before falling through to
//! the regular property bag, so traps fire on `get`, `set`,
//! `has`, and `deleteProperty`.

const std = @import("std");

const Realm = @import("../realm.zig").Realm;
const Value = @import("../value.zig").Value;
const NativeError = @import("../function.zig").NativeError;
const heap_mod = @import("../heap.zig");
const intrinsics = @import("../intrinsics.zig");

const installConstructor = intrinsics.installConstructor;
const throwTypeError = intrinsics.throwTypeError;

// ── §28.2 Proxy ─────────────────────────────────────────────────────────────

pub fn install(realm: *Realm) !void {
    _ = try installConstructor(realm, .{
        .name = "Proxy", .ctor = proxyConstructor, .arity = 2,
        .set_home_object = false,
    });
}

fn proxyConstructor(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = this_value;
    if (args.len < 2) return throwTypeError(realm, "Proxy requires (target, handler)");
    const handler = heap_mod.valueAsPlainObject(args[1]) orelse return throwTypeError(realm, "Proxy handler must be an object");
    const proxy = realm.heap.allocateObject() catch return error.OutOfMemory;
    proxy.proxy_handler = handler;
    if (heap_mod.valueAsPlainObject(args[0])) |target| {
        proxy.proxy_target = target;
        proxy.prototype = target.prototype;
    } else if (heap_mod.valueAsFunction(args[0])) |target_fn| {
        // Callable target — the proxy is itself callable via
        // `proxy_target_fn`. Inherit the function's prototype
        // chain so e.g. `proxy.bind` resolves.
        proxy.proxy_target_fn = target_fn;
        proxy.prototype = target_fn.prototype;
    } else {
        return throwTypeError(realm, "Proxy target must be an object or function");
    }
    return heap_mod.taggedObject(proxy);
}

