//! `harden(value)` — recursive deep-freeze, the SES idiom.
//!
//! Native equivalent of the `@endo/ses` reference implementation.
//! Walks every reachable own property + accessor getter/setter +
//! prototype edge from `value` and freezes each via the same
//! mechanism `Object.freeze` uses (`extensible = false`, every
//! own descriptor stamped `writable=false, configurable=false`).
//! A visited set keyed by heap pointer makes the walk cycle-safe.
//!
//! Phase 2 of [docs/ses-alignment.md](../../../docs/ses-alignment.md).
//! Phase 1 (freeze primordials by default) hasn't shipped yet, so
//! `harden(globalThis)` would currently traverse user-added globals
//! too — once Phase 1 lands, the primordial walk is mostly a
//! no-op (already frozen) and `harden(x)` becomes a useful
//! capability-sealing primitive for hardened-JS code.
//!
//! Known gaps (acceptable for the MVP):
//!   - Module Namespace objects can't be made non-extensible per
//!     §9.4.6.6; we skip them silently rather than throw.
//!   - Proxy receivers are frozen by direct slot mutation here,
//!     not through their `preventExtensions` trap. Spec-strict
//!     Proxy.harden would route through the trap; defer.
//!   - Recursion uses the Zig stack; pathological depth would
//!     overflow. Real-world capability graphs are shallow.

const std = @import("std");

const Realm = @import("../realm.zig").Realm;
const Value = @import("../value.zig").Value;
const NativeError = @import("../function.zig").NativeError;
const heap_mod = @import("../heap.zig");
const intrinsics = @import("../intrinsics.zig");

const argOr = intrinsics.argOr;

pub fn install(realm: *Realm) !void {
    const harden_fn = try realm.heap.allocateFunctionNative(hardenNative, 1, "harden");
    try realm.globals.put(realm.allocator, "harden", heap_mod.taggedFunction(harden_fn));
}

/// `harden(value)` — returns `value` after deeply freezing it.
/// Spec-aligned with `@endo/ses`: primitives pass through; objects
/// and functions are frozen and their reachable graph walked.
fn hardenNative(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = this_value;
    const root = argOr(args, 0, Value.undefined_);
    var visited: std.AutoHashMap(usize, void) = .init(realm.allocator);
    defer visited.deinit();
    try hardenWalk(realm, root, &visited);
    return root;
}

fn hardenWalk(realm: *Realm, v: Value, visited: *std.AutoHashMap(usize, void)) NativeError!void {
    // Pointer identity for the visited set. Primitives have no
    // heap identity — bail before doing any work.
    const key: usize = if (heap_mod.valueAsPlainObject(v)) |o|
        @intFromPtr(o)
    else if (heap_mod.valueAsFunction(v)) |f|
        @intFromPtr(f)
    else
        return;

    const gop = visited.getOrPut(key) catch return error.OutOfMemory;
    if (gop.found_existing) return;

    // Freeze + recurse. The freeze itself uses the same per-key
    // descriptor stamping `Object.freeze` (§20.1.2.5) uses;
    // splitting the body across the two heap-kind branches because
    // `JSObject` and `JSFunction` carry their own property bags.
    if (heap_mod.valueAsPlainObject(v)) |obj| {
        // Module namespaces refuse non-extensibility per §9.4.6.6
        // ([[DefineOwnProperty]] rejects flips). Spec harden would
        // walk the bindings anyway; we just bail — exports are
        // already non-configurable by construction.
        if (obj.is_module_namespace) return;
        obj.extensible = false;
        var it = obj.properties.iterator();
        while (it.next()) |e| {
            const k = e.key_ptr.*;
            const cur = obj.flagsFor(k);
            obj.property_flags.put(realm.allocator, k, .{
                .writable = false,
                .enumerable = cur.enumerable,
                .configurable = false,
            }) catch return error.OutOfMemory;
        }
        // Recurse into own data values.
        var rit = obj.properties.iterator();
        while (rit.next()) |e| try hardenWalk(realm, e.value_ptr.*, visited);
        // Recurse into accessor getters / setters.
        if (obj.accessorIterator()) |ait_outer| {
            var ait = ait_outer;
            while (ait.next()) |e| {
                if (e.value_ptr.*.getter) |g| try hardenWalk(realm, heap_mod.taggedFunction(g), visited);
                if (e.value_ptr.*.setter) |s| try hardenWalk(realm, heap_mod.taggedFunction(s), visited);
            }
        }
        // Recurse into the prototype chain.
        if (obj.prototype) |p| try hardenWalk(realm, heap_mod.taggedObject(p), visited);
        return;
    }
    if (heap_mod.valueAsFunction(v)) |fn_obj| {
        fn_obj.extensible = false;
        var fit = fn_obj.properties.iterator();
        while (fit.next()) |e| {
            const k = e.key_ptr.*;
            const cur = fn_obj.flagsForOwn(k);
            fn_obj.property_flags.put(realm.allocator, k, .{
                .writable = false,
                .enumerable = cur.enumerable,
                .configurable = false,
            }) catch return error.OutOfMemory;
        }
        // Recurse into own property values.
        var pit = fn_obj.properties.iterator();
        while (pit.next()) |e| try hardenWalk(realm, e.value_ptr.*, visited);
        // Recurse into the function's `.prototype` and accessor
        // getters / setters.
        if (fn_obj.prototype) |p| try hardenWalk(realm, heap_mod.taggedObject(p), visited);
        var fait = fn_obj.accessors.iterator();
        while (fait.next()) |e| {
            if (e.value_ptr.*.getter) |g| try hardenWalk(realm, heap_mod.taggedFunction(g), visited);
            if (e.value_ptr.*.setter) |s| try hardenWalk(realm, heap_mod.taggedFunction(s), visited);
        }
        // Function's [[Prototype]] (typically Function.prototype,
        // which is a JSObject — the `.proto` slot is typed
        // `?*JSObject` to match).
        if (fn_obj.proto) |p| try hardenWalk(realm, heap_mod.taggedObject(p), visited);
    }
}
