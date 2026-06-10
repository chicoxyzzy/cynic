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
//! Phase 1 (freeze primordials at realm init) is also shipped —
//! `intrinsics.freezePrimordials` reuses `hardenWalk` directly,
//! so the deep-freeze shape stays in lockstep between user-
//! invoked `harden(value)` and the engine's startup freeze pass.
//! `harden(globalThis)` after init is mostly a no-op walk
//! because every reachable intrinsic is already frozen; the
//! visited set short-circuits the redundant freezes.
//!
//! Known gaps (acceptable for the MVP):
//!   - Module Namespace objects can't be made non-extensible per
//!     §9.4.6.6; we skip them silently rather than throw.
//!   - Proxy receivers are frozen by direct slot mutation here,
//!     not through their `preventExtensions` trap. Spec-strict
//!     Proxy.harden would route through the trap; defer.
//!   - Recursion uses the Zig stack; pathological depth would
//!     overflow. Real-world capability graphs are shallow.
//!   - Array-exotic indexed slots (§10.4.2) live in
//!     `obj.elements`, not `obj.properties`, so the bag-only
//!     walk below misses them. The root array becomes non-
//!     extensible and the *values* at each slot freeze
//!     transitively (good), but `a[0] = …` doesn't throw on
//!     a hardened array because the slot's flags weren't
//!     stamped. `Object.freeze` handles this via
//!     `lowerArrayIndexedFlags` (in builtins/object.zig) which
//!     demotes each indexed slot into the bag with
//!     `{writable: false, configurable: false}`. Wire that into
//!     the array branch when extending. Test
//!     `harden on Array reaches nested values but not indexed
//!     slots (known gap)` pins the current behaviour.

const std = @import("std");

const Realm = @import("../realm.zig").Realm;
const Value = @import("../value.zig").Value;
const NativeError = @import("../function.zig").NativeError;
const heap_mod = @import("../heap.zig");
const intrinsics = @import("../intrinsics.zig");

const argOr = intrinsics.argOr;

/// Freeze a single intrinsic prototype that's being lazily
/// allocated AFTER the realm's initial `freezePrimordials` pass.
/// Several iterator prototypes (`%ArrayIteratorPrototype%`,
/// `%StringIteratorPrototype%`, the wrap-for-valid and
/// async-from-sync variants) don't exist at init time — they're
/// created the first time user code calls `[][Symbol.iterator]()`
/// etc. The init freeze pass walks `realm.intrinsics.*` for them,
/// finds null, and skips. Without this hook, lazy prototypes
/// land as fresh `extensible: true` objects under a hardened
/// realm, leaving a supply-chain hole (monkey-patch
/// `%ArrayIteratorPrototype%.next`).
///
/// Idempotent: re-calling on a frozen prototype short-circuits
/// via the visited set in `hardenWalk`. Cheap to call from
/// every `ensure*Prototype` cold path.
pub fn freezeLazyIntrinsic(realm: *Realm, obj: *@import("../object.zig").JSObject) NativeError!void {
    if (!realm.hardened) return;
    var visited: std.AutoHashMap(usize, void) = .init(realm.allocator);
    defer visited.deinit();
    try hardenWalk(realm, heap_mod.taggedObject(obj), &visited);
}

pub fn install(realm: *Realm) !void {
    const harden_fn = try realm.heap.allocateFunctionNative(realm, hardenNative, 1, "harden");
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

/// Recursive deep-freeze. Public so the Phase 1 SES freeze pass
/// (`intrinsics.freezePrimordials`) can reuse the same walker
/// on the intrinsic graph + globalThis at realm init — the
/// freeze shape is identical to user-invoked `harden(value)`,
/// and a second walker would just drift over time.
pub fn hardenWalk(realm: *Realm, v: Value, visited: *std.AutoHashMap(usize, void)) NativeError!void {
    // Native-stack guard. `harden()` deep-freezes by recursing over
    // the object graph (`hardenWalk` → each property value →
    // `hardenWalk`). The `visited` set breaks cycles, but a deep
    // ACYCLIC graph (`let o={}; for(…) o={a:o}; harden(o)`) still
    // recurses on depth — bound it so a deep structure throws the
    // RangeError V8 / @endo give for stack-exhausting deep-freeze
    // rather than crashing.
    if (@import("../../stack_guard.zig").nearLimit()) {
        const ex = intrinsics.newRangeError(realm, "Maximum call stack size exceeded") catch return error.OutOfMemory;
        realm.pending_exception = ex;
        return error.NativeThrew;
    }
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
        // §23.1.4 — an array exotic's virtual `length` carries its
        // [[Writable]] in the dedicated bit (it has no bag entry for
        // the flag walk below to catch); freezing must clear it or
        // `push` on a hardened array could still grow length.
        if (obj.is_array_exotic) obj.array_length_writable = false;
        // Shape-mode write fast path (Phase 3 of
        // [docs/lazy-property-bag.md]) stores the live descriptor
        // attrs in the shape entry, NOT in `property_flags`. Shapes
        // are immutable transition nodes — flipping a slot to
        // non-writable in place would corrupt every other object
        // sharing the shape. The cheap, correct fix is to demote
        // out of shape mode before stamping: `demoteFromShape`
        // back-fills `properties` + `property_flags` from the
        // shape chain and clears the shape pointer, so subsequent
        // `flagsFor` lookups consult `property_flags` (the source
        // of truth in dict mode) and see the locked attrs harden
        // is about to install. The object now reads + writes
        // through the dictionary-mode path, which is fine: a
        // hardened object can never gain new properties so it
        // won't benefit from further shape transitions anyway.
        obj.demoteFromShape(realm.allocator) catch return error.OutOfMemory;
        var it = obj.iterOwnNamedKeys();
        while (it.next()) |e| {
            const k = e.key_ptr.*;
            const cur = obj.flagsFor(k);
            obj.property_flags.put(realm.allocator, k, .{
                .writable = false,
                .enumerable = cur.enumerable,
                .configurable = false,
            }) catch return error.OutOfMemory;
        }
        // Accessor descriptors need their own flag stamp — the
        // data-property loop above only touches keys in
        // `iterOwnNamedKeys()` (data half). Without this, a freshly
        // installed accessor like `Array.prototype[Symbol.iterator]`
        // keeps its install-time `configurable: true` and
        // `Object.isFrozen(obj)` returns false. Mirrors
        // `Object.freeze` (§7.3.20 SetIntegrityLevel) which stamps
        // both halves.
        if (obj.accessorIterator()) |ait_outer_pre| {
            var ait_pre = ait_outer_pre;
            while (ait_pre.next()) |e| {
                const k = e.key_ptr.*;
                const cur = obj.flagsFor(k);
                obj.property_flags.put(realm.allocator, k, .{
                    .writable = false, // N/A on accessors; spec says omitted.
                    .enumerable = cur.enumerable,
                    .configurable = false,
                }) catch return error.OutOfMemory;
            }
        }
        // Recurse into own data values.
        var rit = obj.iterOwnNamedKeys();
        while (rit.next()) |e| try hardenWalk(realm, e.value_ptr.*, visited);
        // Recurse into array indexed slots. `iterOwnNamedKeys`
        // skips these — they live in `obj.elements` /
        // `obj.sparse_elements` per the array-exotic layout, not
        // in the named-property bag. The harden contract is
        // "deep-freeze every reachable value," and an array of
        // user-mutable objects would otherwise let a hardened
        // `arr` still contain a writable `arr[0]`. The indexed
        // SLOTS' flags are still not stamped (the known gap
        // pinned in `tests/ses/harden_array_indexed_gap.js`);
        // this only recurses into the VALUES so transitive
        // freezing actually reaches them.
        if (obj.is_array_exotic) {
            for (obj.elements.items) |elem| try hardenWalk(realm, elem, visited);
            var sit = obj.sparse_elements.iterator();
            while (sit.next()) |e| try hardenWalk(realm, e.value_ptr.*, visited);
        }
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
        // Accessor descriptors — every constructor with an
        // `@@species` getter (`Array`, `Map`, `Set`, `Promise`,
        // `RegExp`, the typed-array constructors, …) installs it
        // with `configurable: true` per §22.x. Without stamping
        // `configurable: false` here, `Object.isFrozen(Array)`
        // returns false because the species accessor still reports
        // `configurable`. Mirrors the JSObject branch above and
        // `Object.freeze`'s accessor sweep.
        var fait_pre = fn_obj.accessors.iterator();
        while (fait_pre.next()) |e| {
            const k = e.key_ptr.*;
            const cur = fn_obj.flagsForOwn(k);
            fn_obj.property_flags.put(realm.allocator, k, .{
                .writable = false, // N/A on accessors; spec says omitted.
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
