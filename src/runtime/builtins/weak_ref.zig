//! §26.1 WeakRef — a `WeakRef` instance holds a weak-ish reference
//! to its target. `.deref()` returns the target if still live, else
//! `undefined`. Cynic's WeakRef is a strong-ref impl (the target is
//! marked as a GC root via `JSObject.weak_ref_target`); this matches
//! the spec's observable behaviour given that test262 has no
//! `$262.gc()` triggers in this folder, and mirrors the strong-ref
//! WeakMap / WeakSet implementations in `collections.zig`. True
//! GC weakness is later, alongside the FinalizationRegistry work.
//!
//! Spec anchors:
//!   §26.1.1.1 WeakRef ( target )
//!   §26.1.3.2 WeakRef.prototype.deref ( )
//!   §6.2.10   CanBeHeldWeakly
//!   §9.10     KeptAlive / AddToKeptObjects (no-op here, see above)

const std = @import("std");

const Realm = @import("../realm.zig").Realm;
const Value = @import("../value.zig").Value;
const NativeError = @import("../function.zig").NativeError;
const heap_mod = @import("../heap.zig");
const intrinsics = @import("../intrinsics.zig");

const installConstructor = intrinsics.installConstructor;
const installNativeMethodOnProto = intrinsics.installNativeMethodOnProto;
const throwTypeError = intrinsics.throwTypeError;
const argOr = intrinsics.argOr;

// ── §26.1 WeakRef ─────────────────────────────────────────────────────────

pub fn install(realm: *Realm) !void {
    const r = try installConstructor(realm, .{
        .name = "WeakRef",
        .ctor = weakRefConstructor,
        .arity = 1,
        .to_string_tag = "WeakRef",
    });
    _ = r.ctor;
    const proto = r.proto;

    try installNativeMethodOnProto(realm, proto, "deref", weakRefDeref, 0);
}

/// §6.2.10 CanBeHeldWeakly — true iff `v` is an Object, or a Symbol
/// that was not registered via `Symbol.for(k)`. Functions count as
/// Objects for this predicate (callable target wrapping is allowed).
fn canBeHeldWeakly(v: Value) bool {
    if (heap_mod.valueAsPlainObject(v) != null) return true;
    if (heap_mod.valueAsFunction(v) != null) return true;
    if (heap_mod.valueAsSymbol(v)) |sym| return !sym.is_registered;
    return false;
}

/// §26.1.1.1 WeakRef ( target )
/// 1. If NewTarget is undefined, throw a TypeError exception.
///    — handled by `is_class_constructor: true` on the installed
///    constructor (interpreter rejects call without `new`).
/// 2. If CanBeHeldWeakly(target) is false, throw a TypeError.
/// 3. Let weakRef be ? OrdinaryCreateFromConstructor(NewTarget,
///    "%WeakRefPrototype%", « [[WeakRefTarget]] »).
///    — the interpreter's `new` dispatch allocates `this_value`
///    with the right `[[Prototype]]` (NewTarget's `prototype`
///    property, falling back to %WeakRefPrototype%).
/// 4. Perform AddToKeptObjects(target). — strong-ref impl: no-op.
/// 5. Set weakRef.[[WeakRefTarget]] to target.
/// 6. Return weakRef.
fn weakRefConstructor(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const inst = heap_mod.valueAsPlainObject(this_value) orelse
        return throwTypeError(realm, "WeakRef constructor requires 'new'");
    const target = argOr(args, 0, Value.undefined_);
    if (!canBeHeldWeakly(target))
        return throwTypeError(realm, "WeakRef: target must be an object or non-registered symbol");
    inst.is_weak_ref = true;
    inst.weak_ref_target = target;
    return this_value;
}

/// §26.1.3.2 WeakRef.prototype.deref ( )
/// 1. Let weakRef be the this value.
/// 2. Perform ? RequireInternalSlot(weakRef, [[WeakRefTarget]]).
/// 3. Return WeakRefDeref(weakRef).
///
/// §26.1.4.1 WeakRefDeref(weakRef):
///   1. Let target be weakRef.[[WeakRefTarget]].
///   2. If target is not empty:
///      a. Perform AddToKeptObjects(target).  (no-op here)
///      b. Return target.
///   3. Return undefined.
fn weakRefDeref(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = args;
    const inst = heap_mod.valueAsPlainObject(this_value) orelse
        return throwTypeError(realm, "WeakRef.prototype.deref called on non-object");
    if (!inst.is_weak_ref)
        return throwTypeError(realm, "WeakRef.prototype.deref called on non-WeakRef");
    // Strong-ref impl: target is never empty after construction.
    return inst.weak_ref_target;
}
