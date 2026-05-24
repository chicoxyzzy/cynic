//! §26.1 WeakRef — a `WeakRef` instance holds a genuinely weak
//! reference to its target. `.deref()` returns the target if still
//! live, else `undefined`. The `[[WeakRefTarget]]` slot
//! (`JSObject.weak_ref_target`) is NOT strong-marked by the major
//! collector: `Heap.collectFull` records every reached WeakRef and,
//! after the mark phase, clears `weak_ref_target` to `undefined` for
//! any WeakRef whose referent did not survive the trace. The minor
//! collector still strong-marks the slot, so a young target merely
//! survives the minor cycle and is handled weakly at the next major
//! cycle — fully conformant, since §26.1 only guarantees a WeakRef
//! *eventually* clears.
//!
//! Spec anchors:
//!   §26.1.1.1 WeakRef ( target )
//!   §26.1.3.2 WeakRef.prototype.deref ( )
//!   §6.2.10   CanBeHeldWeakly
//!   §9.10     KeptAlive / AddToKeptObjects — implemented. Both the
//!             constructor (§26.1.1.1 step 4) and `deref`
//!             (§26.1.4.1 step 2a) pin their target via
//!             `Realm.addToKeptObjects` for the duration of the
//!             current job; `drainMicrotasks` clears the list
//!             between jobs (§9.10.4.2). Matches V8 / JSC /
//!             SpiderMonkey behaviour: `ref.deref()` twice in the
//!             same synchronous block sees the same target both
//!             times even if all other strong references dropped.

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
/// 4. Perform AddToKeptObjects(target). — pins the target alive
///    for the current job (§9.10.4.1).
/// 5. Set weakRef.[[WeakRefTarget]] to target.
/// 6. Return weakRef.
fn weakRefConstructor(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const inst = heap_mod.valueAsPlainObject(this_value) orelse
        return throwTypeError(realm, "WeakRef constructor requires 'new'");
    const target = argOr(args, 0, Value.undefined_);
    if (!canBeHeldWeakly(target))
        return throwTypeError(realm, "WeakRef: target must be an object or non-registered symbol");
    inst.is_weak_ref = true;
    inst.setWeakRefTarget(realm.allocator, target) catch return error.OutOfMemory;
    // §26.1.1.1 step 4 — pin the target across the current job.
    realm.addToKeptObjects(target) catch return error.OutOfMemory;
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
///      a. Perform AddToKeptObjects(target).
///      b. Return target.
///   3. Return undefined.
fn weakRefDeref(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = args;
    const inst = heap_mod.valueAsPlainObject(this_value) orelse
        return throwTypeError(realm, "WeakRef.prototype.deref called on non-object");
    if (!inst.is_weak_ref)
        return throwTypeError(realm, "WeakRef.prototype.deref called on non-WeakRef");
    // §26.1.4.1 — `weak_ref_target` is `undefined` (the engine's
    // ~empty~ sentinel) once the major collector observed the
    // target become unreachable; otherwise it is the live target.
    const target = inst.getWeakRefTarget();
    // §26.1.4.1 step 2a — pin the live target across the current
    // job so a second `deref()` (or any other path that needs the
    // target) sees the same value, even if all other strong refs
    // have dropped. The pin is released at the next job boundary
    // (`drainMicrotasks` → `clearKeptObjects`).
    if (!target.isUndefined()) {
        realm.addToKeptObjects(target) catch return error.OutOfMemory;
    }
    return target;
}
