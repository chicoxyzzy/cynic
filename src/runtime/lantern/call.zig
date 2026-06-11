//! Call + construct machinery — extracted from `interpreter.zig` to
//! keep the dispatch-loop file focused.
//!
//! Hosts the call dispatch helpers that the bytecode `Call` /
//! `Construct` / `Super*` opcodes route through, plus the
//! prototype-from-constructor lookup (§9.1.14) and the bound-
//! function unwrap (§10.4.1):
//!
//!   - callValue           (Value-typed call entry)
//!   - callJSFunction      (typed `*JSFunction` entry)
//!   - callJSFunctionAsSuper (super-method call path)
//!   - constructValue      (new-expression entry)
//!   - unwrapBoundCall     (bound function chain unwrap)
//!   - getPrototypeFromConstructor[Value] (§9.1.14)
//!   - startAsyncCall      (async-function invocation)
//!
//! Each entry point re-enters `runFrames` on the caller's stack
//! to drive the new chunk. Native callees fast-path back through
//! `callJSFunction` so they don't bounce off the dispatch loop.

const std = @import("std");

const Value = @import("../value.zig").Value;
const JSString = @import("../string.zig").JSString;
const JSFunction = @import("../function.zig").JSFunction;
const object_mod = @import("../object.zig");
const JSObject = object_mod.JSObject;
const Environment = @import("../environment.zig").Environment;
const heap_mod = @import("../heap.zig");
const intrinsics_mod = @import("../intrinsics.zig");
const Realm = @import("../realm.zig").Realm;
const Chunk = @import("../../bytecode/chunk.zig").Chunk;
const bistromath = @import("../bistromath/bistromath.zig");

// Circular back to interpreter.zig for shared types + the dispatch
// loop entry + a handful of helpers that bracket call/construct.
const lantern = @import("interpreter.zig");
const CallFrame = lantern.CallFrame;
pub const RunError = lantern.RunError;
pub const RunResult = lantern.RunResult;
const runFrames = lantern.runFrames;
const unwindThrow = lantern.unwindThrow;
const consumePendingException = lantern.consumePendingException;
const makeTypeError = lantern.makeTypeError;
const makeRangeError = lantern.makeRangeError;

// Generator + promise hooks invoked by constructValue / startAsyncCall
// when the callee is a generator function, async function, or async
// generator function.
const generator = @import("generator.zig");
const wrapGenerator = generator.wrapGenerator;
const wrapAsyncGenerator = generator.wrapAsyncGenerator;
const promise_mod = @import("promise.zig");
const resumeAsyncFunction = promise_mod.resumeAsyncFunction;

/// Phase 3 SES override-mistake fix — perform the synthetic
/// setter's DefineOwnProperty step on `receiver`.
///
/// The semantics are §7.3.6 CreateDataPropertyOrThrow with the
/// fresh descriptor `{value, writable: true, enumerable: true,
/// configurable: true}`. Two failure modes surface as strict-mode
/// TypeError (per §6.2.5.5 PutValue step 6):
///   • The receiver already has the key as a non-configurable
///     accessor — this is the "user wrote `Array.prototype.foo
///     = …`" case, where dispatch reached us through the
///     prototype's own synthetic accessor and the receiver IS
///     that prototype. Refuse the redefine.
///   • The receiver is non-extensible and doesn't already have
///     an own data slot for the key.
///
/// Otherwise drop the value through with default flags. This is
/// what creates the shadowing own property on a downstream user
/// receiver (`Test262Error.prototype.toString = fn` with
/// receiver `Test262Error.prototype`, not `Object.prototype`).
fn syntheticSetterDispatch(
    realm: *Realm,
    sa: *@import("../function.zig").SyntheticAccessor,
    receiver: Value,
    value: Value,
) RunError!RunResult {
    const flags: object_mod.PropertyFlags = .{
        .writable = true,
        .enumerable = true,
        .configurable = true,
    };
    if (heap_mod.valueAsPlainObject(receiver)) |obj| {
        if (obj.hasAccessor(sa.key)) {
            const cur = obj.flagsFor(sa.key);
            if (!cur.configurable) {
                const ex = try makeTypeError(realm, "Cannot redefine non-configurable property on frozen prototype");
                return .{ .thrown = ex };
            }
        }
        if (!obj.extensible and !obj.ownDataContains(sa.key)) {
            const ex = try makeTypeError(realm, "Cannot add property; object is not extensible");
            return .{ .thrown = ex };
        }
        obj.setWithFlags(realm.allocator, sa.key, value, flags) catch return error.OutOfMemory;
        return .{ .value = Value.undefined_ };
    }
    if (heap_mod.valueAsFunction(receiver)) |fn_obj| {
        if (fn_obj.accessors.contains(sa.key)) {
            const cur = fn_obj.flagsForOwn(sa.key);
            if (!cur.configurable) {
                const ex = try makeTypeError(realm, "Cannot redefine non-configurable property on frozen prototype");
                return .{ .thrown = ex };
            }
        }
        if (!fn_obj.extensible and !fn_obj.ownDataContains(sa.key)) {
            const ex = try makeTypeError(realm, "Cannot add property; function is not extensible");
            return .{ .thrown = ex };
        }
        fn_obj.setWithFlags(realm.allocator, sa.key, value, flags) catch return error.OutOfMemory;
        return .{ .value = Value.undefined_ };
    }
    // Primitive receiver — §10.1.9.1 OrdinarySet step 4 says
    // assignment through a primitive wrapper succeeds-silently
    // when the property would shadow on the wrapper. Cynic
    // doesn't yet box every primitive into its wrapper class on
    // assignment; for now silently no-op, matching the spec's
    // observable end-state (the next read still sees the
    // inherited value because no shadow was created).
    return .{ .value = Value.undefined_ };
}

/// Unwrap a (possibly chained) bound function. Returns the
/// real target plus the effective `this` and args. The caller
/// owns the freshly-allocated `args` slice and must free it.
/// `for_construct = true` skips `bound_this` (per §10.4.1.2 —
/// `new boundFn(...)` ignores the bound `this`).
pub fn unwrapBoundCall(
    allocator: std.mem.Allocator,
    callee: *JSFunction,
    this_value: Value,
    args: []const Value,
    for_construct: bool,
) RunError!struct { target: *JSFunction, this_value: Value, args: []const Value, owns_args: bool } {
    var target = callee;
    var bound_this = this_value;
    var prefix_args: std.ArrayListUnmanaged(Value) = .empty;
    errdefer prefix_args.deinit(allocator);

    while (target.bound_target) |inner_target| {
        if (target.bound_args) |ba| {
            // Bind chain: outer bind's prefix args come BEFORE
            // inner bind's prefix args. Walk from the outermost
            // inward.
            try prefix_args.insertSlice(allocator, 0, ba);
        }
        if (!for_construct) bound_this = target.bound_this;
        target = inner_target;
    }

    if (prefix_args.items.len == 0) {
        return .{ .target = target, .this_value = bound_this, .args = args, .owns_args = false };
    }
    try prefix_args.appendSlice(allocator, args);
    const owned = try prefix_args.toOwnedSlice(allocator);
    return .{ .target = target, .this_value = bound_this, .args = owned, .owns_args = true };
}

/// Reentrant entry point: invoke `callee` with the supplied
/// `this_value` and `args`, and return its completion. Used by
/// natives that need to call back into JS — `Function.prototype.call`,
/// `Function.prototype.apply`, `Array.prototype.map`, etc.
///
/// Native callees short-circuit through their `native_callback`.
/// Bytecode callees get a fresh frame stack and run their body
/// to a `Return` (or uncaught throw). The caller's interpreter
/// session is unaffected — this opens its own dispatch session.
/// §10.5.13 [[Call]] dispatcher that accepts a `Value`. Used by
/// `Function.prototype.{call, apply}`, `Reflect.apply`, and other
/// reflective callers that can receive a Proxy as the callee:
/// they need the `apply` trap fired before the host-side native
/// short-circuit. Returns the same shape as `callJSFunction`.
pub fn callValue(
    allocator: std.mem.Allocator,
    realm: *Realm,
    // §9.4 — the running execution context's Realm: the realm of
    // whatever function is currently executing when this dispatch
    // happens. Used to attribute the §10.5.12 [[Call]]-on-revoked-
    // Proxy TypeError, which the spec throws "in the current Realm"
    // (step 1 ValidateNonRevokedProxy, before any context push).
    // Allocation/trap dispatch still use the active `realm`; only
    // the cross-realm-observable throw reads this. Equal to `realm`
    // in any single-realm program.
    running_realm: *Realm,
    callee_v: Value,
    this_value: Value,
    args: []const Value,
) RunError!RunResult {
    // §10.5.12 Proxy [[Call]] — a proxy exposes a [[Call]] internal
    // method ONLY when its target was callable at creation: §10.5.1
    // ProxyCreate step 3 gates installing [[Call]] on
    // IsCallable(target). `proxy_callable` records that gate (set in
    // proxyConstructor for function / callable-proxy targets, and
    // preserved across revocation). Enter this block only for an
    // object that is BOTH a proxy (a live target slot, or revoked)
    // AND callable. The callability clause excludes a proxy over a
    // non-callable target — `new Proxy({}, { apply() {} })` has no
    // [[Call]], so invoking it must fall through to the ordinary
    // "not a function" TypeError with the `apply` trap never firing.
    // The proxy-identity clause is equally load-bearing:
    // %Function.prototype% also carries `proxy_callable` (its
    // callability marker, so `typeof` reports "function") yet is not
    // a proxy, and must reach the identity check below — not here.
    if (heap_mod.valueAsPlainObject(callee_v)) |po| {
        if ((po.proxy_target_fn != null or po.proxy_target != null or po.proxy_revoked) and po.proxy_callable) {
            if (po.proxy_revoked) {
                // §10.5.12 step 1 ValidateNonRevokedProxy throws in
                // the running execution context's realm — `running_realm`,
                // not the active `realm` (they differ when a function
                // from another realm tail-calls / calls a revoked proxy).
                const ex = try makeTypeError(running_realm, "Cannot perform 'apply' on a proxy that has been revoked");
                return .{ .thrown = ex };
            }
            const target_v: Value = if (po.proxy_target_fn) |tfn|
                heap_mod.taggedFunction(tfn)
            else if (po.proxy_target) |t|
                heap_mod.taggedObject(t)
            else
                return .{ .thrown = try makeTypeError(realm, "proxy target slot is null") };
            const handler = po.proxy_handler orelse return .{ .thrown = try makeTypeError(realm, "proxy handler slot is null") };
            const trap_v = handler.get("apply");
            if (!trap_v.isUndefined() and !trap_v.isNull()) {
                const trap_fn = heap_mod.valueAsFunction(trap_v) orelse return .{ .thrown = try makeTypeError(realm, "proxy 'apply' trap is not callable") };
                // Wrap args in a fresh array.
                const arr = realm.heap.allocateObject() catch return error.OutOfMemory;
                realm.heap.setObjectPrototype(arr, realm.intrinsics.array_prototype);
                arr.markAsArrayExotic(allocator) catch return error.OutOfMemory;
                var i: usize = 0;
                while (i < args.len) : (i += 1) {
                    var ibuf: [24]u8 = undefined;
                    const islice = std.fmt.bufPrint(&ibuf, "{d}", .{i}) catch unreachable;
                    const owned = realm.heap.allocateString(islice) catch return error.OutOfMemory;
                    realm.heap.storeProperty(arr, allocator, owned.flatBytes(), args[i]) catch return error.OutOfMemory;
                }
                realm.heap.storeProperty(arr, allocator, "length", Value.fromInt32(@intCast(args.len))) catch return error.OutOfMemory;
                const trap_args = [_]Value{ target_v, this_value, heap_mod.taggedObject(arr) };
                return callJSFunction(allocator, realm, trap_fn, heap_mod.taggedObject(handler), &trap_args);
            }
            // Trap missing — fall through to target.
            return callValue(allocator, realm, running_realm, target_v, this_value, args);
        }
    }
    // Plain function path.
    if (heap_mod.valueAsFunction(callee_v)) |fn_obj| {
        // §10.2.1 step 2 — `[[Call]]` on a class constructor
        // throws TypeError. The bytecode dispatch op checks this
        // for direct calls; reflective callers
        // (`Function.prototype.{call, apply}`, `Reflect.apply`,
        // and host re-entry) route through here and must surface
        // the same TypeError. Bound wrappers preserve the brand
        // on the inner target; unwrap before checking.
        var target_fn = fn_obj;
        while (target_fn.bound_target) |inner| target_fn = inner;
        if (target_fn.is_class_constructor) {
            return .{ .thrown = try makeTypeError(realm, "Class constructor cannot be invoked without 'new'") };
        }
        return callJSFunction(allocator, realm, fn_obj, this_value, args);
    }
    // §20.2.3 %Function.prototype% [[Call]] — Cynic stores it as a
    // JSObject (not a JSFunction), so reflective callers
    // (`Function.prototype.{call, apply}`, `Reflect.apply`, host
    // re-entry) end up here. The spec answer is "returns undefined
    // regardless of arguments." Mirrors the identity-check guard in
    // the bytecode dispatchers (`.call` / `.call_method` /
    // `.tail_call` / `.tail_call_method` in `interpreter.zig`).
    if (heap_mod.valueAsPlainObject(callee_v)) |po| {
        if (realm.intrinsics.function_prototype == po) {
            return .{ .value = Value.undefined_ };
        }
    }
    return .{ .thrown = try makeTypeError(realm, "value is not callable") };
}

/// §10.1.14 GetPrototypeFromConstructor. Resolves the
/// `[[Prototype]]` to install on a freshly-allocated instance:
///   1. Let proto be Get(constructor, "prototype").
///   2. If Type(proto) is not Object, fall back to the
///      target's own `.prototype` slot (the intrinsic default
///      proto for the constructor — Cynic's analogue of
///      `realm.[[Intrinsics]].[[<intrinsicDefaultProto>]]`).
/// Honors accessor descriptors on the new-target so user-installed
/// `Object.defineProperty(boundFn, "prototype", {get})` fires.
/// Returns `.thrown` when the accessor's getter throws so the
/// caller can propagate the abrupt completion.
pub const ProtoLookup = union(enum) {
    proto: ?*JSObject,
    /// §10.1.14 — `Get(constructor, "prototype")` produced a function:
    /// functions are objects, so the instance's [[Prototype]] is the
    /// function itself (stored on the `prototype_fn` parallel slot).
    proto_fn: *JSFunction,
    thrown: Value,
};

/// Outcome of a single proxy [[Get]] dispatch — either a value
/// (from the trap or the fallthrough read on the target) or a
/// thrown exception value the caller propagates.
const ProxyGetResult = union(enum) {
    value: Value,
    thrown: Value,
};

/// §10.5.5 Proxy [[Get]] (P, Receiver) — minimal dispatcher
/// callable from RunError contexts. Used by constructValue when
/// new_target is itself a proxy: §10.1.14 GetPrototypeFromConstructor
/// step 3 calls `Get(constructor, "prototype")` which must fire
/// the proxy's get trap (a user-installed get trap can revoke the
/// proxy mid-flight, which §10.1.14 step 4.a then observes via
/// GetFunctionRealm). Does NOT enforce the §10.5.5 non-configurable
/// data/accessor invariants — `proxy.nativeProxyGet` carries those
/// for the regular property-opcode dispatch.
fn invokeProxyGetTrap(
    allocator: std.mem.Allocator,
    realm: *Realm,
    proxy: *JSObject,
    key: []const u8,
    receiver: Value,
) RunError!ProxyGetResult {
    if (proxy.proxy_revoked) {
        return .{ .thrown = try makeTypeError(realm, "Cannot perform 'get' on a proxy that has been revoked") };
    }
    const handler = proxy.proxy_handler orelse {
        return .{ .thrown = try makeTypeError(realm, "proxy handler slot is null") };
    };
    const target_v: Value = if (proxy.proxy_target_fn) |tfn|
        heap_mod.taggedFunction(tfn)
    else if (proxy.proxy_target) |t|
        heap_mod.taggedObject(t)
    else
        return .{ .thrown = try makeTypeError(realm, "proxy target slot is null") };
    const trap_v = handler.get("get");
    if (trap_v.isUndefined() or trap_v.isNull()) {
        // §10.5.5 step 6 — trap missing, recurse on the target.
        if (heap_mod.valueAsPlainObject(target_v)) |t_obj| {
            if (t_obj.proxy_target_fn != null or t_obj.proxy_target != null or t_obj.proxy_revoked) {
                return try invokeProxyGetTrap(allocator, realm, t_obj, key, receiver);
            }
            return .{ .value = t_obj.get(key) };
        }
        if (heap_mod.valueAsFunction(target_v)) |t_fn| {
            return .{ .value = t_fn.get(key) };
        }
        return .{ .value = Value.undefined_ };
    }
    const trap_fn = heap_mod.valueAsFunction(trap_v) orelse {
        return .{ .thrown = try makeTypeError(realm, "proxy 'get' trap is not callable") };
    };
    const key_str = realm.heap.allocateString(key) catch return error.OutOfMemory;
    const args = [_]Value{ target_v, Value.fromString(key_str), receiver };
    const outcome = try callJSFunction(allocator, realm, trap_fn, heap_mod.taggedObject(handler), &args);
    switch (outcome) {
        .value, .yielded => |v| return .{ .value = v },
        .thrown => |ex| return .{ .thrown = ex },
    }
}

/// Value-typed counterpart of `getPrototypeFromConstructor` for
/// native constructors with `defers_proto_lookup` set. Resolves
/// the prototype slot from a NewTarget Value that may be a plain
/// JSFunction, a callable Proxy, or — falling back — any other
/// value (in which case the intrinsic default is returned). When
/// NewTarget is a Proxy, `Get(newTarget, "prototype")` dispatches
/// through the proxy's `get` trap per §10.5.5.
pub fn getPrototypeFromConstructorValue(
    allocator: std.mem.Allocator,
    realm: *Realm,
    new_target: Value,
    intrinsic_default: ?*JSObject,
    default_owner_realm: *Realm,
) RunError!ProtoLookup {
    if (heap_mod.valueAsFunction(new_target)) |new_target_fn| {
        return try getPrototypeFromConstructor(allocator, realm, new_target_fn, intrinsic_default, default_owner_realm);
    }
    if (heap_mod.valueAsPlainObject(new_target)) |nt_proxy| {
        if (nt_proxy.proxy_target_fn != null or nt_proxy.proxy_target != null or nt_proxy.proxy_revoked) {
            const get_v = try invokeProxyGetTrap(allocator, realm, nt_proxy, "prototype", new_target);
            switch (get_v) {
                .thrown => |ex| return .{ .thrown = ex },
                .value => |v| {
                    if (heap_mod.valueAsPlainObject(v)) |po| return .{ .proto = po };
                    if (nt_proxy.proxy_revoked or nt_proxy.proxy_handler == null) {
                        return .{ .thrown = try makeTypeError(realm, "Cannot retrieve realm from a revoked Proxy") };
                    }
                    // §10.1.14 GetPrototypeFromConstructor step 4 — the
                    // resolved `prototype` is not an Object, so the default
                    // proto belongs to GetFunctionRealm(newTarget)'s
                    // intrinsics. For a Proxy newTarget that realm is its
                    // target function's (§10.2.5 step 4, recursed through
                    // the chain), not the active realm — mirror the
                    // JSFunction path's remap so a cross-realm proxy
                    // newTarget yields its own realm's intrinsic default
                    // (built-ins/Proxy/get-fn-realm{,-recursive}.js).
                    const ctor_realm = proxyChainFunctionRealm(nt_proxy) orelse realm;
                    return .{ .proto = remapDefaultProtoToCtorRealm(default_owner_realm, ctor_realm, intrinsic_default) };
                },
            }
        }
        return .{ .proto = intrinsic_default };
    }
    return .{ .proto = intrinsic_default };
}

/// §10.1.14 GetPrototypeFromConstructor step 4 — when the resolved
/// `prototype` is not an Object, the spec falls back to the
/// *constructor's* realm's intrinsic: step 4.a runs
/// `GetFunctionRealm(constructor)`, step 4.b reads that realm's
/// intrinsic named `intrinsicDefaultProto`. The caller supplies the
/// concrete fallback object (`intrinsic_default`) plus the realm
/// that *owns* it (`owner` — the realm whose intrinsic table /
/// constructor binding the object was read from). This identifies
/// the object by name in `owner`, then returns the same-named
/// intrinsic of `ctor_realm`.
///
/// `owner` is NOT always the active realm: for a cross-realm
/// `Reflect.construct(R3.Date, [], R1boundNewTarget)`, the fallback
/// proto is read from the *target's* realm (R3.Date.prototype) while
/// the active realm is the caller's — so scanning the active realm
/// would never identify it. Callers thread the owning realm
/// explicitly (see `baseConstructDefaultProtoOwner`).
///
/// Two resolution strategies, in order:
///   1. Typed intrinsic-slot scan — covers every default proto held
///      in an `Intrinsics` field (`array_buffer_prototype`,
///      `promise_prototype`, the Error-family prototypes, …),
///      including lazily-built ones not reachable as globals.
///   2. Global-binding scan — the well-known global constructors
///      whose prototype lives only on the constructor's `.prototype`
///      slot (`Map`, `Number`, `Date`, the concrete TypedArrays, …)
///      have no dedicated `Intrinsics` field, so match the owner
///      realm's constructor binding by name and read the same-named
///      binding from `ctor_realm`.
///
/// Returns `intrinsic_default` unchanged when the realms match (the
/// common single-realm case — a pointer-compare short-circuit) or
/// when no mapping is found (defensive: a non-intrinsic default, or
/// an intrinsic the ctor realm hasn't installed yet).
fn remapDefaultProtoToCtorRealm(
    owner: *Realm,
    ctor_realm: *Realm,
    intrinsic_default: ?*JSObject,
) ?*JSObject {
    if (owner == ctor_realm) return intrinsic_default;
    const default = intrinsic_default orelse return intrinsic_default;

    // (1) Typed intrinsic-slot scan.
    inline for (
        @typeInfo(intrinsics_mod.Intrinsics).@"struct".field_names,
        @typeInfo(intrinsics_mod.Intrinsics).@"struct".field_types,
    ) |field_name, field_type| {
        if (field_type == ?*JSObject) {
            if (@field(owner.intrinsics, field_name)) |p| {
                if (p == default) {
                    return @field(ctor_realm.intrinsics, field_name) orelse intrinsic_default;
                }
            }
        }
    }

    // (2) Global-constructor scan keyed by binding name.
    var it = owner.globals.iterator();
    while (it.next()) |entry| {
        const f = heap_mod.valueAsFunction(entry.value_ptr.*) orelse continue;
        const fp = f.prototype orelse continue;
        if (fp == default) {
            const child_v = ctor_realm.globals.get(entry.key_ptr.*) orelse return intrinsic_default;
            const child_f = heap_mod.valueAsFunction(child_v) orelse return intrinsic_default;
            return child_f.prototype orelse intrinsic_default;
        }
    }

    return intrinsic_default;
}

/// §10.2.5 GetFunctionRealm step 4 — "If obj is a Proxy exotic object,
/// return GetFunctionRealm(obj.[[ProxyTarget]])." Recurse the proxy
/// chain (`proxy_target` for a Proxy-over-object/proxy, `proxy_target_fn`
/// for a Proxy-over-function) to the underlying function and return its
/// [[Realm]]. Returns null when no function target is reachable (a
/// revoked link or a non-function target) — the caller falls back to the
/// active realm, matching `JSFunction.getFunctionRealm`'s null contract.
fn proxyChainFunctionRealm(obj: *JSObject) ?*Realm {
    var cur: *JSObject = obj;
    var guard: usize = 0;
    while (guard < 100_000) : (guard += 1) {
        if (cur.proxy_target_fn) |f| return f.getFunctionRealm();
        if (cur.proxy_target) |t| {
            cur = t;
            continue;
        }
        return null;
    }
    return null;
}

pub fn getPrototypeFromConstructor(
    allocator: std.mem.Allocator,
    realm: *Realm,
    new_target: *JSFunction,
    intrinsic_default: ?*JSObject,
    default_owner_realm: *Realm,
) RunError!ProtoLookup {
    // §10.1.14 step 4 — every non-object fallback below resolves the
    // default prototype against the *constructor's* realm (step 4.a
    // GetFunctionRealm + step 4.b's named intrinsic), not the active
    // realm. The remap identifies `intrinsic_default` by name in the
    // realm that owns it (`default_owner_realm`, threaded by the
    // caller — not necessarily the active realm in a cross-realm
    // construct), then re-resolves it against `ctor_realm`. In the
    // single-realm case this is the unchanged `intrinsic_default`.
    const ctor_realm = new_target.getFunctionRealm() orelse realm;
    const default_proto = remapDefaultProtoToCtorRealm(default_owner_realm, ctor_realm, intrinsic_default);
    // §10.1.8.1 OrdinaryGet step 4 — accessor wins.
    if (new_target.ownAccessor("prototype")) |acc_pair| {
        if (acc_pair.getter) |getter| {
            const recv = heap_mod.taggedFunction(new_target);
            const outcome = try callJSFunction(allocator, realm, getter, recv, &.{});
            switch (outcome) {
                .value, .yielded => |v| {
                    if (heap_mod.valueAsPlainObject(v)) |po| return .{ .proto = po };
                    if (heap_mod.valueAsFunction(v)) |pf| return .{ .proto_fn = pf };
                    return .{ .proto = default_proto };
                },
                .thrown => |ex| return .{ .thrown = ex },
            }
        }
        // Write-only accessor: getter is undefined → ToObject fails → use default.
        return .{ .proto = default_proto };
    }
    // §10.1.14 step 3 — `Get(constructor, "prototype")`. The
    // property bag wins over the dedicated slot so a user
    // assignment of `f.prototype = null` (or any non-Object) is
    // observed — spec says fall back to the intrinsic default
    // when the value isn't an Object.
    if (new_target.properties.get("prototype")) |v| {
        if (heap_mod.valueAsPlainObject(v)) |po| return .{ .proto = po };
        if (heap_mod.valueAsFunction(v)) |pf| return .{ .proto_fn = pf };
        return .{ .proto = default_proto };
    }
    if (new_target.prototype) |p| return .{ .proto = p };
    // No `prototype` at all (arrow, bound without override) — fall back.
    return .{ .proto = default_proto };
}

/// §10.2.2 [[Construct]] base-kind intrinsicDefaultProto for `target`.
/// An ordinary function's constructed object falls back to
/// `%Object.prototype%` (which `getPrototypeFromConstructor` then
/// resolves against the constructor's realm when newTarget.prototype
/// isn't an Object). A native constructor instead carries its own
/// intrinsic default in its `.prototype` slot (Array → %Array.prototype%,
/// Error → %Error.prototype%, …), so passing `t.prototype` reproduces
/// the spec's per-constructor intrinsicDefaultProto generically. A bound
/// function forwards [[Construct]] to its [[BoundTargetFunction]]
/// (§10.4.1.2 step 6), so the relevant kind is the unwrapped base
/// target's, not the bound wrapper's (which has no `prototype`).
///
/// Every [[Construct]] dispatch site must derive its fallback proto
/// through this helper rather than reading `target.prototype` directly
/// — `constructValue` here, `Reflect.construct`, and the interpreter's
/// `new_call` opcode (ordinary + bound). Passing `target.prototype`
/// is only correct for native ctors; for an ordinary function whose
/// `prototype` is non-object (`F.prototype = null`), the spec mandates
/// `%Object.prototype%`, not the function's own (possibly stale) slot.
pub fn baseConstructIntrinsicDefaultProto(realm: *Realm, target: *JSFunction) ?*JSObject {
    var t = target;
    while (t.bound_target) |bt| t = bt;
    // A genuine built-in constructor (Array, Map, Error, …) carries its
    // per-constructor intrinsicDefaultProto in its own `.prototype`
    // slot. The empty function from `new Function()` is native too, but
    // it is an *ordinary* function (§20.2.1.1.1) whose [[Construct]] is
    // the §10.2.2 base kind — its fallback is `%Object.prototype%`, not
    // the fresh ordinary object sitting in its `.prototype` slot.
    if (t.native_callback != null and !t.native_ordinary_function) return t.prototype;
    // The %Object.prototype% fallback belongs to the *target's* realm so
    // the §10.1.14 remap can identify it by name there (a cross-realm
    // ordinary target's fallback isn't owned by the active realm). In
    // the single-realm case this is `realm.intrinsics.object_prototype`.
    return (t.getFunctionRealm() orelse realm).intrinsics.object_prototype;
}

/// Realm that owns the object returned by
/// `baseConstructIntrinsicDefaultProto` for `target` — the realm whose
/// intrinsic table / `.prototype` slot the fallback proto was read
/// from. §10.1.14 step 4 identifies that proto by *name* in this realm
/// before re-resolving it against the constructor's realm, so the two
/// helpers must agree on which (bound-unwrapped) function supplied it.
pub fn baseConstructDefaultProtoOwner(realm: *Realm, target: *JSFunction) *Realm {
    var t = target;
    while (t.bound_target) |bt| t = bt;
    return t.getFunctionRealm() orelse realm;
}

/// §10.5.14 [[Construct]] dispatcher that accepts a `Value`. Used
/// by `Reflect.construct` to handle Proxy receivers — fires the
/// `construct` trap if installed, otherwise falls through to the
/// target's [[Construct]]. The result must be an Object per
/// §10.5.14 step 11.
pub fn constructValue(
    allocator: std.mem.Allocator,
    realm: *Realm,
    callee_v: Value,
    args: []const Value,
    new_target: Value,
) RunError!RunResult {
    if (heap_mod.valueAsPlainObject(callee_v)) |po| {
        if (po.proxy_target_fn != null or po.proxy_target != null or po.proxy_revoked) {
            if (po.proxy_revoked) {
                return .{ .thrown = try makeTypeError(realm, "Cannot perform 'construct' on a proxy that has been revoked") };
            }
            const target_v: Value = if (po.proxy_target_fn) |tfn|
                heap_mod.taggedFunction(tfn)
            else if (po.proxy_target) |t|
                heap_mod.taggedObject(t)
            else
                return .{ .thrown = try makeTypeError(realm, "proxy target slot is null") };
            const handler = po.proxy_handler orelse return .{ .thrown = try makeTypeError(realm, "proxy handler slot is null") };
            const trap_v = handler.get("construct");
            if (!trap_v.isUndefined() and !trap_v.isNull()) {
                const trap_fn = heap_mod.valueAsFunction(trap_v) orelse return .{ .thrown = try makeTypeError(realm, "proxy 'construct' trap is not callable") };
                const arr = realm.heap.allocateObject() catch return error.OutOfMemory;
                realm.heap.setObjectPrototype(arr, realm.intrinsics.array_prototype);
                arr.markAsArrayExotic(allocator) catch return error.OutOfMemory;
                var i: usize = 0;
                while (i < args.len) : (i += 1) {
                    var ibuf: [24]u8 = undefined;
                    const islice = std.fmt.bufPrint(&ibuf, "{d}", .{i}) catch unreachable;
                    const owned = realm.heap.allocateString(islice) catch return error.OutOfMemory;
                    realm.heap.storeProperty(arr, allocator, owned.flatBytes(), args[i]) catch return error.OutOfMemory;
                }
                realm.heap.storeProperty(arr, allocator, "length", Value.fromInt32(@intCast(args.len))) catch return error.OutOfMemory;
                const trap_args = [_]Value{ target_v, heap_mod.taggedObject(arr), new_target };
                const outcome = try callJSFunction(allocator, realm, trap_fn, heap_mod.taggedObject(handler), &trap_args);
                switch (outcome) {
                    .value, .yielded => |v| {
                        if (heap_mod.valueAsPlainObject(v) == null and heap_mod.valueAsFunction(v) == null) {
                            return .{ .thrown = try makeTypeError(realm, "proxy 'construct' trap returned non-object") };
                        }
                        return .{ .value = v };
                    },
                    .thrown => |ex| return .{ .thrown = ex },
                }
            }
            // Trap missing — recurse on the target.
            return constructValue(allocator, realm, target_v, args, new_target);
        }
    }
    const target = heap_mod.valueAsFunction(callee_v) orelse {
        return .{ .thrown = try makeTypeError(realm, "value is not a constructor") };
    };
    if (!target.has_construct or target.is_arrow) {
        return .{ .thrown = try makeTypeError(realm, "value is not a constructor") };
    }
    // §25.1.4.1 / §25.3.2.1 — native ctors that validate args
    // before OrdinaryCreateFromConstructor. Skip the proto lookup
    // here, stash newTarget on the realm, and invoke the native
    // with `this_value = undefined`. The native handles its own
    // OCFC after validation. ConstructResult: object return wins,
    // else TypeError (no fallback `this`, since we never allocated).
    if (target.defers_proto_lookup and target.native_callback != null) {
        realm.pending_native_new_target = new_target;
        defer realm.pending_native_new_target = Value.undefined_;
        const outcome = try callJSFunction(allocator, realm, target, Value.undefined_, args);
        switch (outcome) {
            .value, .yielded => |v| {
                if (heap_mod.valueAsPlainObject(v) != null or heap_mod.valueAsFunction(v) != null) return .{ .value = v };
                return .{ .thrown = try makeTypeError(realm, "deferred-proto-lookup constructor did not return an object") };
            },
            .thrown => |ex| return .{ .thrown = ex },
        }
    }
    // §10.1.14 GetPrototypeFromConstructor on new_target. When
    // new_target is a callable Proxy (not a plain function), the
    // spec's Get(new_target, "prototype") fires the proxy's [[Get]]
    // which dispatches through the handler's `get` trap. If that
    // trap revokes the proxy mid-flight, the subsequent
    // GetFunctionRealm(new_target) sees a revoked handler and
    // throws TypeError (§10.5.2 step 1).
    // §10.2.2 base-kind intrinsicDefaultProto for this construct:
    // %Object.prototype% for an ordinary-function `target`, its own
    // %X.prototype% for a native ctor, the unwrapped base target's for
    // a bound function. Used wherever new_target's `prototype` isn't an
    // Object and we fall back to the intrinsic default (§10.1.14 step 4).
    const base_default = baseConstructIntrinsicDefaultProto(realm, target);
    const base_default_owner = baseConstructDefaultProtoOwner(realm, target);
    var resolved_proto: ?*JSObject = undefined;
    var resolved_proto_fn: ?*JSFunction = null;
    if (heap_mod.valueAsFunction(new_target)) |new_target_fn| {
        const proto_lookup = try getPrototypeFromConstructor(allocator, realm, new_target_fn, base_default, base_default_owner);
        resolved_proto = switch (proto_lookup) {
            .proto => |p| p,
            .proto_fn => |pf| blk: {
                resolved_proto_fn = pf;
                break :blk null;
            },
            .thrown => |ex| return .{ .thrown = ex },
        };
    } else if (heap_mod.valueAsPlainObject(new_target)) |nt_proxy| {
        if (nt_proxy.proxy_target_fn != null or nt_proxy.proxy_target != null or nt_proxy.proxy_revoked) {
            // §10.5.5 Proxy [[Get]] on `prototype`. Run the trap (or
            // fall through to target.prototype). If a user-installed
            // get trap revokes the proxy here, the subsequent
            // GetFunctionRealm(new_target) at step 4.a hits a null
            // handler and throws.
            const get_v = try invokeProxyGetTrap(allocator, realm, nt_proxy, "prototype", new_target);
            switch (get_v) {
                .thrown => |ex| return .{ .thrown = ex },
                .value => |v| {
                    if (heap_mod.valueAsPlainObject(v)) |po| {
                        resolved_proto = po;
                    } else {
                        // §10.1.14 step 4 — proto not an Object; the
                        // spec then calls GetFunctionRealm(new_target).
                        // If the proxy is now revoked, that throws.
                        if (nt_proxy.proxy_revoked or nt_proxy.proxy_handler == null) {
                            return .{ .thrown = try makeTypeError(realm, "Cannot retrieve realm from a revoked Proxy") };
                        }
                        resolved_proto = base_default;
                    }
                },
            }
        } else {
            resolved_proto = base_default;
        }
    } else {
        resolved_proto = base_default;
    }
    const instance = realm.heap.allocateObject() catch return error.OutOfMemory;
    if (resolved_proto_fn) |pf| realm.heap.setObjectPrototypeFn(instance, pf) else realm.heap.setObjectPrototype(instance, resolved_proto);
    const this_arg = heap_mod.taggedObject(instance);
    // §10.2.2 [[Construct]] — body runs with NewTarget bound to
    // `new_target`. The frame must carry it so `new.target`
    // (`lda_new_target`) inside the body reads the species ctor
    // (or whatever the caller of constructValue supplied) rather
    // than `undefined`. The native / generator / async paths don't
    // observe NewTarget through a frame slot, so route them
    // through plain callJSFunction unchanged.
    //
    // For a bound target (chunk == null) we MUST route through
    // `callJSFunctionAsSuper`, not plain `callJSFunction`. The
    // latter unwraps the bound chain with `for_construct=false`,
    // which overrides `this_value` with the bound `[[BoundThis]]`
    // — but §10.4.1.2 [[Construct]] step 4 keeps the freshly
    // allocated `this` (per `OrdinaryCreateFromConstructor`),
    // ignoring `[[BoundThis]]` entirely. Without this branch,
    // `Reflect.construct(Foo.bind(null, 1), [2], SubFoo)` (and
    // its proxy-wrapped equivalents like
    // `built-ins/Proxy/construct/trap-is-undefined-target-is-proxy.js`)
    // sees `this = null` inside Foo's body and a subsequent
    // `this.sum = …` throws "Cannot set properties of non-object".
    if (target.bound_target != null) {
        const outcome = try callJSFunctionAsSuper(allocator, realm, target, this_arg, args, new_target);
        switch (outcome) {
            .value, .yielded => |v| {
                if (heap_mod.valueAsPlainObject(v) != null or heap_mod.valueAsFunction(v) != null) return .{ .value = v };
                return .{ .value = this_arg };
            },
            .thrown => |ex| return .{ .thrown = ex },
        }
    }
    if (target.native_callback != null or target.is_generator or target.is_async or target.chunk == null) {
        // Root the freshly allocated instance across the call — a
        // native constructor that re-enters JS (a user `toString` /
        // `valueOf` during argument coercion) can trigger a GC while
        // `this_arg` is still only a native-stack local. The
        // `native_ctor_roots` stack is allocation-free at steady
        // state, unlike a `HandleScope` per construct.
        realm.heap.pushNativeRoot(this_arg) catch return error.OutOfMemory;
        defer realm.heap.popNativeRoot();
        const outcome = try callJSFunction(allocator, realm, target, this_arg, args);
        switch (outcome) {
            .value, .yielded => |v| {
                if (heap_mod.valueAsPlainObject(v) != null or heap_mod.valueAsFunction(v) != null) return .{ .value = v };
                return .{ .value = this_arg };
            },
            .thrown => |ex| return .{ .thrown = ex },
        }
    }
    const callee_chunk = target.chunk.?;
    var frames: std.ArrayListUnmanaged(CallFrame) = .empty;
    defer {
        for (frames.items) |*f| f.releaseRegisters(realm, allocator);
        frames.deinit(allocator);
    }
    const reg_count = @max(@as(usize, callee_chunk.register_count), args.len);
    var is_stack_alloc = true;
    const regs = realm.allocStackRegisters(reg_count) orelse blk: {
        is_stack_alloc = false;
        break :blk try realm.frame_pool.acquire(allocator, reg_count);
    };
    @memset(regs, Value.undefined_);
    var i: usize = 0;
    while (i < args.len and i < regs.len) : (i += 1) regs[i] = args[i];
    frames.append(allocator, .{
        .chunk = callee_chunk,
        .ip = 0,
        .accumulator = Value.undefined_,
        .registers = regs,
        .env = target.captured_env,
        .this_value = this_arg,
        .is_construct = true,
        .is_derived_ctor = target.constructor_kind == .derived,
        .new_target = new_target,
        .home_object = target.home_object,
        .home_function = target.home_function,
        .super_called_cell = target.super_called_cell,
        .argc = @intCast(@min(args.len, std.math.maxInt(u8))),
        .wrap_return_in_promise = false,
        .running_realm = target.realm,
        .is_stack_alloc = is_stack_alloc,
    }) catch {
        if (is_stack_alloc) {
            realm.freeStackRegisters(regs);
        } else {
            realm.frame_pool.release(allocator, regs);
        }
        return error.OutOfMemory;
    };
    const outcome = try runFrames(allocator, realm, &frames);
    switch (outcome) {
        .value, .yielded => |v| {
            if (heap_mod.valueAsPlainObject(v) != null or heap_mod.valueAsFunction(v) != null) return .{ .value = v };
            return .{ .value = this_arg };
        },
        .thrown => |ex| return .{ .thrown = ex },
    }
}

pub fn callJSFunction(
    allocator: std.mem.Allocator,
    realm: *Realm,
    callee: *JSFunction,
    this_value: Value,
    args: []const Value,
) RunError!RunResult {
    // §10.4.1 — bound functions unwrap to their target, with
    // `this` and prefix-args coming from the bound state.
    if (callee.bound_target != null) {
        const unwrapped = try unwrapBoundCall(allocator, callee, this_value, args, false);
        defer if (unwrapped.owns_args) allocator.free(unwrapped.args);
        return callJSFunction(allocator, realm, unwrapped.target, unwrapped.this_value, unwrapped.args);
    }

    // §3.8.3.6 WrappedFunctionCall — a function returned by
    // `ShadowRealm.prototype.evaluate` (or any cross-boundary
    // crossing) carries its target in `wrapped_target` and its
    // caller realm in `realm`. Each arg/return value crosses the
    // §3.8.3.4 GetWrappedValue filter; abrupt completions are
    // remapped to a TypeError in the caller realm. `this_value`
    // is intentionally ignored per the spec — wrapped calls
    // dispatch with `thisArgument = undefined`.
    if (!callee.wrapped_target.isUndefined()) {
        return try @import("../builtins/shadow_realm.zig").callWrappedFunction(allocator, realm, callee, args);
    }

    // Phase 3 SES override-mistake fix — synthetic accessors
    // installed by `freezePrimordials` short-circuit the native-
    // callback path. The getter returns the captured value
    // verbatim; the setter performs an OrdinaryDefineOwnProperty
    // on the receiver with `{value, writable: true,
    // enumerable: true, configurable: true}` — creating an own
    // data property that shadows the frozen prototype slot.
    if (callee.synth_accessor) |sa| {
        if (sa.is_setter) {
            const incoming = if (args.len > 0) args[0] else Value.undefined_;
            return try syntheticSetterDispatch(realm, sa, this_value, incoming);
        }
        return .{ .value = sa.value };
    }

    if (callee.native_callback) |native| {
        const native_this: Value = if (callee.is_arrow) callee.captured_this else this_value;
        // §10.2.5 — record the callee's realm so a native shared
        // across realms (ShadowRealm.prototype.{evaluate,importValue})
        // can read its own function realm. Save / restore for
        // nested native calls.
        const prior_fn_realm = realm.active_native_fn_realm;
        realm.active_native_fn_realm = callee.realm;
        defer realm.active_native_fn_realm = prior_fn_realm;
        // Record the callee so a native needing per-function state (e.g.
        // a WebAssembly exported function) can recover it; the native
        // signature passes only `this`/`args`, not the callee.
        const prior_fn = realm.active_native_fn;
        realm.active_native_fn = callee;
        defer realm.active_native_fn = prior_fn;
        const result = native(realm, native_this, args) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.NativeThrew => {
                const ex = consumePendingException(realm) orelse try makeTypeError(realm, "native error");
                return .{ .thrown = ex };
            },
        };
        return .{ .value = result };
    }

    const callee_chunk = callee.chunk orelse return error.InvalidOpcode;

    // §27.5 / §27.6 — calling a `function*` or `async function*`
    // from a native allocates a generator wrapper instead of
    // running the body to completion. The async-generator path
    // uses `%AsyncGeneratorPrototype%` so `next`/`return`/`throw`
    // produce Promises.
    if (callee.is_generator) {
        if (callee.is_async)
            return try wrapAsyncGenerator(allocator, realm, callee_chunk, callee.captured_env, this_value, args, callee.home_object, callee.home_function, callee);
        return try wrapGenerator(allocator, realm, callee_chunk, callee.captured_env, this_value, args, callee.home_object, callee.home_function, callee);
    }

    // §27.7 — pure `async function` (no `*`): allocate a fresh
    // `result_promise` plus a backing generator that captures the
    // body's frame state if a pending await suspends. Run the
    // body synchronously up to the first suspension or
    // completion. The caller always sees `result_promise` as
    // the call's return value.
    if (callee.is_async) {
        const callee_this: Value = if (callee.is_arrow) callee.captured_this else this_value;
        return startAsyncCall(allocator, realm, callee_chunk, callee.captured_env, callee_this, args, callee.home_object, callee.home_function, callee.owning_module);
    }

    var frames: std.ArrayListUnmanaged(CallFrame) = .empty;
    defer {
        for (frames.items) |*f| f.releaseRegisters(realm, allocator);
        frames.deinit(allocator);
    }

    const reg_count = @max(@as(usize, callee_chunk.register_count), args.len);
    var is_stack_alloc = true;
    const regs = realm.allocStackRegisters(reg_count) orelse blk: {
        is_stack_alloc = false;
        break :blk try realm.frame_pool.acquire(allocator, reg_count);
    };
    @memset(regs, Value.undefined_);
    var i: usize = 0;
    while (i < args.len and i < regs.len) : (i += 1) {
        regs[i] = args[i];
    }
    const callee_this: Value = if (callee.is_arrow) callee.captured_this else this_value;
    // §13.3.12 — arrows inherit `new.target` from their creation
    // site (captured at MakeFunction time). Non-arrow indirect
    // calls land here without a `[[Construct]]` context, so
    // NewTarget is undefined.
    const callee_new_target: Value = if (callee.is_arrow) callee.captured_new_target else Value.undefined_;
    frames.append(allocator, .{
        .chunk = callee_chunk,
        .ip = 0,
        .accumulator = Value.undefined_,
        .registers = regs,
        .env = callee.captured_env,
        .this_value = callee_this,
        .new_target = callee_new_target,
        .home_object = callee.home_object,
        .home_function = callee.home_function,
        .super_called_cell = callee.super_called_cell,
        .argc = @intCast(@min(args.len, std.math.maxInt(u8))),
        .wrap_return_in_promise = false,
        .owning_module = callee.owning_module,
        .running_realm = callee.realm,
        .is_stack_alloc = is_stack_alloc,
    }) catch {
        if (is_stack_alloc) {
            realm.freeStackRegisters(regs);
        } else {
            realm.frame_pool.release(allocator, regs);
        }
        return error.OutOfMemory;
    };

    // Bistromath (docs/jit.md §4): a hot compiled callee completes
    // without ever entering the dispatch loop; tier-downs and cold
    // chunks fall through to Lantern below. A throw landed by a
    // nested call unwinds against the callee's own handlers first
    // (the frame stays pushed at the faulting ip) and resumes in
    // Lantern when caught.
    switch (try bistromath.tryEnterTop(allocator, realm, &frames)) {
        .not_entered => {},
        .completed => |jit_ret| return .{ .value = jit_ret },
        .threw => |ex| {
            if (!try unwindThrow(allocator, realm, &frames, ex)) {
                return .{ .thrown = ex };
            }
        },
    }
    return runFrames(allocator, realm, &frames);
}

/// Invoke `parent_fn` as the parent constructor of a `super(...)`
/// call. Same shape as `callJSFunction` but seeds the new frame's
/// `new_target` slot from the caller's so a derived class's
/// inherited `new.target` reads correctly inside the parent
/// constructor body.
pub fn callJSFunctionAsSuper(
    allocator: std.mem.Allocator,
    realm: *Realm,
    callee: *JSFunction,
    this_value: Value,
    args: []const Value,
    new_target: Value,
) RunError!RunResult {
    // §10.4.1.2 [[Construct]] on a bound function — walk the
    // bound chain and apply step 5 at each layer:
    //   `If SameValue(F, newTarget) is true, set newTarget to
    //    F.[[BoundTargetFunction]]`.
    // So a `new C()` where C is bound starts with newTarget = C,
    // collapses to target B, then on B collapses to A, etc.
    // An explicit `Reflect.construct(C, args, NT)` where NT is
    // *not* in the chain keeps NT unchanged through the unwrap.
    if (callee.bound_target != null) {
        var effective_nt = new_target;
        var cursor: *JSFunction = callee;
        while (cursor.bound_target) |inner| : (cursor = inner) {
            if (heap_mod.valueAsFunction(effective_nt)) |nt_fn| {
                if (nt_fn == cursor) effective_nt = heap_mod.taggedFunction(inner);
            }
        }
        const unwrapped = try unwrapBoundCall(allocator, callee, this_value, args, true);
        defer if (unwrapped.owns_args) allocator.free(unwrapped.args);
        return callJSFunctionAsSuper(allocator, realm, unwrapped.target, this_value, unwrapped.args, effective_nt);
    }
    // §25.1.4.1 / §25.3.2.1 — native constructor that defers OCFC.
    // From a derived class's `super(...)`, the `this_value` here is
    // the uninitialised derived `this`; the native must allocate
    // its own instance using newTarget's prototype. Stash newTarget
    // on the realm, invoke with `this = undefined`, return whatever
    // the native produced (caller applies ConstructResult).
    if (callee.native_callback != null and callee.defers_proto_lookup) {
        const prior_pnt = realm.pending_native_new_target;
        realm.pending_native_new_target = new_target;
        defer realm.pending_native_new_target = prior_pnt;
        return callJSFunction(allocator, realm, callee, Value.undefined_, args);
    }
    // Native / generator / async paths don't observe new.target
    // via a frame slot — they receive `this` and args directly.
    if (callee.native_callback != null or callee.is_generator or callee.is_async) {
        // Root the caller-allocated instance across the call. A native
        // constructor reached this way (super() / Reflect.construct) can
        // re-enter JS during argument coercion — a user `@@toPrimitive` /
        // `valueOf` — and trigger a GC while `this_value` is only a
        // native-stack local. The normal construct path guards this with
        // `pushNativeRoot`; without the same guard here the instance is
        // swept mid-construct and the native writes through a freed
        // pointer (a use-after-free against the 0xaa-poisoned slot).
        realm.heap.pushNativeRoot(this_value) catch return error.OutOfMemory;
        defer realm.heap.popNativeRoot();
        return callJSFunction(allocator, realm, callee, this_value, args);
    }
    const callee_chunk = callee.chunk orelse return error.InvalidOpcode;

    var frames: std.ArrayListUnmanaged(CallFrame) = .empty;
    defer {
        for (frames.items) |*f| f.releaseRegisters(realm, allocator);
        frames.deinit(allocator);
    }

    const reg_count = @max(@as(usize, callee_chunk.register_count), args.len);
    var is_stack_alloc = true;
    const regs = realm.allocStackRegisters(reg_count) orelse blk: {
        is_stack_alloc = false;
        break :blk try realm.frame_pool.acquire(allocator, reg_count);
    };
    @memset(regs, Value.undefined_);
    var i: usize = 0;
    while (i < args.len and i < regs.len) : (i += 1) regs[i] = args[i];
    frames.append(allocator, .{
        .chunk = callee_chunk,
        .ip = 0,
        .accumulator = Value.undefined_,
        .registers = regs,
        .env = callee.captured_env,
        .this_value = this_value,
        .new_target = new_target,
        // §10.2.1.4 — the parent body runs in construct context
        // for purposes of `new.target`, but we deliberately leave
        // `is_construct = false` so the return-coercion path
        // doesn't second-guess the derived ctor (which performs
        // its own ConstructResult after the super_call returns).
        .home_object = callee.home_object,
        .home_function = callee.home_function,
        .argc = @intCast(@min(args.len, std.math.maxInt(u8))),
        .wrap_return_in_promise = false,
        .owning_module = callee.owning_module,
        .running_realm = callee.realm,
        .is_stack_alloc = is_stack_alloc,
    }) catch {
        if (is_stack_alloc) {
            realm.freeStackRegisters(regs);
        } else {
            realm.frame_pool.release(allocator, regs);
        }
        return error.OutOfMemory;
    };

    return runFrames(allocator, realm, &frames);
}

/// Start a fresh `async function` call: allocate the
/// `result_promise` (pending), allocate the backing
/// `JSGenerator`, and synchronously run the body. The body
/// either completes (settles the result Promise immediately)
/// or hits a pending `await` (saves state, registers a waiter,
/// returns — the result Promise stays pending until the
/// resumption microtask fires).
pub fn startAsyncCall(
    allocator: std.mem.Allocator,
    realm: *Realm,
    chunk: *const @import("../../bytecode/chunk.zig").Chunk,
    captured_env: ?*Environment,
    this_value: Value,
    args: []const Value,
    home_object: ?*JSObject,
    home_function: ?*JSFunction,
    owning_module: ?*@import("../module.zig").ModuleRecord,
) RunError!RunResult {
    // Pre-allocate the Promise so the gen can settle it.
    const promise_obj = realm.heap.allocateObject() catch return error.OutOfMemory;
    realm.heap.setObjectPrototype(promise_obj, if (heap_mod.valueAsFunction(realm.globals.get("Promise") orelse Value.undefined_)) |p|
        p.prototype
    else
        realm.intrinsics.object_prototype);
    realm.heap.settlePromise(promise_obj, .pending, Value.undefined_);
    const result_promise = heap_mod.taggedObject(promise_obj);

    const wanted: usize = @max(@as(usize, chunk.register_count), args.len);
    const reg_count: u8 = @intCast(@min(wanted, std.math.maxInt(u8)));
    const gen = realm.heap.allocateGenerator(chunk, reg_count, captured_env, this_value) catch return error.OutOfMemory;
    gen.is_async = true;
    gen.result_promise = result_promise;
    // §15.7.14 step 31 — async function bodies execute through a
    // backing generator; the resumption frame inherits home_* from
    // gen via the .home_object / .home_function fields on
    // gen. Without copying these, private-name access inside an
    // async method falls through the brand translation and lookup
    // fails. Mirrors how wrapGenerator threads home_* for non-async
    // generators.
    realm.heap.setGeneratorHomeObject(gen, home_object);
    realm.heap.setGeneratorHomeFunction(gen, home_function);
    // §16.2.1.5.1 [[IsAsync]] — capture the module this async
    // body belongs to so deferred resumes can re-thread
    // `realm.current_module` for `module_export`. Two cases feed
    // `owning_module`: an async *module body* passes the module
    // it evaluates as; a plain `async function` passes the
    // callee's `JSFunction.owning_module` (the module it was
    // *defined* in). The latter matters when an async function
    // declared in a module writes one of that module's exported
    // live bindings — the write runs on a microtask resume long
    // after the module body returned and unwound
    // `realm.current_module` back to null, so without this the
    // `module_export` op silently no-ops and the namespace keeps
    // the stale declaration-time value.
    gen.owning_module = owning_module;
    var i: usize = 0;
    while (i < args.len and i < gen.registers.len) : (i += 1) {
        gen.registers[i] = args[i];
    }
    gen.argc = @intCast(@min(args.len, std.math.maxInt(u8)));

    try resumeAsyncFunction(allocator, realm, gen, Value.undefined_, false);
    return .{ .value = result_promise };
}
