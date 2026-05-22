//! §26.2 FinalizationRegistry — registration of cleanup
//! callbacks tied to weakly-held targets.
//!
//! FinalizationRegistry is genuinely weak. A registered cell's
//! `[[WeakRefTarget]]` / `[[UnregisterToken]]` are weak edges:
//! the major collector (`Heap.collectFull`) does not strong-mark
//! them. When its post-mark weak pass observes a cell whose target
//! did not survive the trace, it enqueues a host job that invokes
//! `cleanupCallback(heldValue)` on the next microtask drain and
//! tombstones the cell. The cleanup callback and each cell's
//! `[[HeldValue]]` ARE strong-marked — they must survive to be
//! passed to the callback. Cleanup never runs synchronously inside
//! GC; §26.2's introductory note also permits an implementation to
//! skip cleanup entirely, so a dropped job (e.g. OOM enqueuing)
//! stays conformant.
//!
//! Spec layout:
//!   §26.2.1 The FinalizationRegistry Constructor
//!   §26.2.2 Properties of the FinalizationRegistry Constructor
//!   §26.2.3 Properties of the FinalizationRegistry Prototype
//!     §26.2.3.2 register(target, heldValue [, unregisterToken])
//!     §26.2.3.3 unregister(unregisterToken)

const std = @import("std");

const Realm = @import("../realm.zig").Realm;
const Value = @import("../value.zig").Value;
const JSObject = @import("../object.zig").JSObject;
const NativeError = @import("../function.zig").NativeError;
const NativeFn = @import("../function.zig").NativeFn;
const heap_mod = @import("../heap.zig");
const ObjMod = @import("../object.zig");
const intrinsics = @import("../intrinsics.zig");

const installConstructor = intrinsics.installConstructor;
const installNativeMethodOnProto = intrinsics.installNativeMethodOnProto;
const argOr = intrinsics.argOr;
const throwTypeError = intrinsics.throwTypeError;
const sameValue = intrinsics.sameValue;

pub fn install(realm: *Realm) !void {
    // §26.2.1.1 — `length` is 1 (cleanupCallback). `to_string_tag`
    // per §26.2.3.5.
    const r = try installConstructor(realm, .{
        .name = "FinalizationRegistry",
        .ctor = finalizationRegistryConstructor,
        .arity = 1,
        .to_string_tag = "FinalizationRegistry",
    });
    _ = r.ctor;
    const proto = r.proto;

    try installNativeMethodOnProto(realm, proto, "register", frRegister, 2);
    try installNativeMethodOnProto(realm, proto, "unregister", frUnregister, 1);
}

/// §6.2.9 CanBeHeldWeakly — true for Objects and for non-registered
/// Symbols (post-ES2023 "Symbols as WeakMap keys"). Registered
/// Symbols (Symbol.for) are reachable from the realm's
/// `symbol_registry` and therefore strongly held; spec excludes
/// them from weak holding.
fn canBeHeldWeakly(v: Value) bool {
    if (heap_mod.isJSObject(v)) return true;
    if (heap_mod.valueAsSymbol(v)) |sym| {
        return !sym.is_registered;
    }
    return false;
}

/// §26.2.1.1 FinalizationRegistry(cleanupCallback). NewTarget is
/// implicitly checked by the dispatcher (`new` vs plain call) —
/// when called as a function, `this_value` isn't a fresh
/// instance and we throw. When called via `new`, the interpreter
/// pre-allocates `this` with the prototype already wired.
fn finalizationRegistryConstructor(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    // §26.2.1.1 step 1 — NewTarget undefined → TypeError. Without
    // NewTarget plumbing here we infer from `this_value` shape:
    // a `new`-call hands a fresh JSObject; a plain call hands
    // undefined (or globalThis under sloppy semantics — but Cynic
    // is strict-only).
    const inst = heap_mod.valueAsPlainObject(this_value) orelse {
        return throwTypeError(realm, "FinalizationRegistry constructor requires 'new'");
    };
    // §26.2.1.1 step 2 — IsCallable(cleanupCallback) is false → TypeError.
    const cb = argOr(args, 0, Value.undefined_);
    if (heap_mod.valueAsFunction(cb) == null) {
        return throwTypeError(realm, "FinalizationRegistry: cleanupCallback is not callable");
    }
    // §26.2.1.1 steps 3-5 — allocate [[Cells]] + [[CleanupCallback]].
    const data = realm.allocator.create(ObjMod.FinalizationData) catch return error.OutOfMemory;
    data.* = .{ .cleanup_callback = cb };
    inst.finalization_cells = data;
    return this_value;
}

fn finalizationDataOf(this_value: Value) ?*ObjMod.FinalizationData {
    const obj = heap_mod.valueAsPlainObject(this_value) orelse return null;
    return obj.finalization_cells;
}

/// §26.2.3.2 FinalizationRegistry.prototype.register
fn frRegister(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    // step 2 — RequireInternalSlot([[Cells]]).
    const data = finalizationDataOf(this_value) orelse {
        return throwTypeError(realm, "FinalizationRegistry.prototype.register called on incompatible receiver");
    };
    const target = argOr(args, 0, Value.undefined_);
    const held_value = argOr(args, 1, Value.undefined_);
    const unregister_token = argOr(args, 2, Value.undefined_);

    // step 3 — CanBeHeldWeakly(target) false → TypeError.
    if (!canBeHeldWeakly(target)) {
        return throwTypeError(realm, "FinalizationRegistry.prototype.register: target cannot be held weakly");
    }
    // step 4 — SameValue(target, heldValue) → TypeError.
    if (sameValue(target, held_value)) {
        return throwTypeError(realm, "FinalizationRegistry.prototype.register: target and heldValue must differ");
    }
    // step 5 — CanBeHeldWeakly(unregisterToken) handling. If false
    // AND the token isn't undefined, throw. If false AND undefined,
    // treat as ~empty~. Otherwise (true), record it.
    var has_token = false;
    var token = Value.undefined_;
    if (canBeHeldWeakly(unregister_token)) {
        has_token = true;
        token = unregister_token;
    } else if (!unregister_token.isUndefined()) {
        return throwTypeError(realm, "FinalizationRegistry.prototype.register: unregisterToken cannot be held weakly");
    }

    // steps 6-7 — append the cell. Linear-scan storage matches
    // `MapData.entries`; revisit when shapes / packed indexed
    // storage land.
    data.cells.append(realm.allocator, .{
        .target = target,
        .held_value = held_value,
        .unregister_token = token,
        .has_token = has_token,
    }) catch return error.OutOfMemory;

    // step 8 — return undefined.
    return Value.undefined_;
}

/// §26.2.3.3 FinalizationRegistry.prototype.unregister
fn frUnregister(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    // step 2 — RequireInternalSlot([[Cells]]).
    const data = finalizationDataOf(this_value) orelse {
        return throwTypeError(realm, "FinalizationRegistry.prototype.unregister called on incompatible receiver");
    };
    const token = argOr(args, 0, Value.undefined_);
    // step 3 — CanBeHeldWeakly(unregisterToken) false → TypeError.
    if (!canBeHeldWeakly(token)) {
        return throwTypeError(realm, "FinalizationRegistry.prototype.unregister: unregisterToken cannot be held weakly");
    }
    // steps 4-6 — sweep cells matching by SameValue on the
    // unregister token (not target — see `unregister-object-token.js`
    // step 5.a in the spec).
    var removed = false;
    for (data.cells.items) |*cell| {
        if (cell.deleted) continue;
        if (!cell.has_token) continue;
        if (sameValue(cell.unregister_token, token)) {
            cell.deleted = true;
            removed = true;
        }
    }
    return Value.fromBool(removed);
}
