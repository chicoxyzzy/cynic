//! §27 Promise — extracted from `intrinsics.zig`.
//!
//! Cynic implements the spec's Promise / microtask machinery:
//! • `new Promise(executor)` runs the executor immediately;
//! resolve/reject use a bound-function trampoline so the
//! target Promise is captured via `bound_this`.
//! • Settling a Promise stores the state; `.then` ALWAYS
//! schedules its handler as a microtask (on already-settled
//! sources the reaction is queued immediately; on pending
//! sources it's stored on the source and queued at
//! settlement). The queue drains at script end, at `await`
//! boundaries, and on the host's `globalThis.__drainMicrotasks`
//! hook.
//! • Aggregators (`Promise.{all, allSettled, race, any}`) go
//! through §27.2.1.5 NewPromiseCapability and forward each
//! resolved item via `Invoke(nextPromise, "then", « cap.resolve,
//! cap.reject »)` — a microtask schedule, NOT a synchronous
//! settle. That preserves the spec's interleaving with user-
//! installed `.then` reactions and lets `Promise.race` produce
//! the right downstream-`.then` order. User-overridable
//! methods (`Promise.resolve`, `then`) are looked up
//! dynamically per spec; subclassed constructors see their
//! own executor and can intercept settlement.
//!
//! Microtask draining is in `lantern.drainMicrotasks`;
//! suspendable `await` is implemented in `runtime/lantern.zig`
//! via the JSGenerator-backed async-function frame capture.

const std = @import("std");

const Realm = @import("../realm.zig").Realm;
const Value = @import("../value.zig").Value;
const JSString = @import("../string.zig").JSString;
const JSObject = @import("../object.zig").JSObject;
const JSFunction = @import("../function.zig").JSFunction;
const NativeError = @import("../function.zig").NativeError;
const heap_mod = @import("../heap.zig");
const intrinsics = @import("../intrinsics.zig");

const installConstructor = intrinsics.installConstructor;
const installNativeMethod = intrinsics.installNativeMethod;
const installNativeMethodOnProto = intrinsics.installNativeMethodOnProto;
const argOr = intrinsics.argOr;
const throwTypeError = intrinsics.throwTypeError;
const setLength = intrinsics.setLength;
const getPropertyChain = intrinsics.getPropertyChain;

// ── §27 Promise — install constructors, prototype, statics ────────────────

pub fn install(realm: *Realm) !void {
    // `new Promise(executor)` runs the executor immediately and
    // resolves / rejects through bound-function trampolines.
    // `.then` always defers — settled sources queue the reaction
    // as a microtask, pending sources register on the source.
    // Static aggregators (`Promise.{all, allSettled, race, any}`)
    // build a fresh capability via `NewPromiseCapability(C)` and
    // route each item through `Invoke(item, "then", «
    // cap.resolve, cap.reject »)` — a microtask schedule, so
    // downstream `.then` chains see the spec-required order.
    const r = try installConstructor(realm, .{
        .name = "Promise",
        .ctor = promiseConstructor,
        .arity = 1,
        .to_string_tag = "Promise",
    });
    const fn_obj = r.ctor;
    const proto = r.proto;
    // §27.2.3.1 step 2-3 — IsCallable(executor) fires BEFORE
    // OrdinaryCreateFromConstructor (which would trigger a user
    // `prototype` getter on newTarget). Defer the proto lookup
    // so the constructor can validate the executor first; the
    // native callback runs `GetPrototypeFromConstructor` itself
    // after the IsCallable check. Matches the ArrayBuffer /
    // DataView pattern.
    fn_obj.defers_proto_lookup = true;

    try installNativeMethodOnProto(realm, proto, "then", promiseThen, 2);
    try installNativeMethodOnProto(realm, proto, "catch", promiseCatch, 1);
    try installNativeMethodOnProto(realm, proto, "finally", promiseFinally, 1);

    try installNativeMethod(realm, fn_obj, "resolve", promiseResolve, 1);
    try installNativeMethod(realm, fn_obj, "reject", promiseReject, 1);
    try installNativeMethod(realm, fn_obj, "all", promiseAll, 1);
    try installNativeMethod(realm, fn_obj, "allSettled", promiseAllSettled, 1);
    try installNativeMethod(realm, fn_obj, "race", promiseRace, 1);
    try installNativeMethod(realm, fn_obj, "any", promiseAny, 1);
    try installNativeMethod(realm, fn_obj, "try", promiseTry, 1);
    try installNativeMethod(realm, fn_obj, "withResolvers", promiseWithResolvers, 0);

    realm.intrinsics.promise_prototype = proto;

    // §27.2.4.6 — get Promise [ @@species ] returns `this`.
    // The static accessor lives on the constructor (a JSFunction),
    // so we install directly into its `accessors` map; spec flags
    // are `{ enumerable: false, configurable: true }` (no writable
    // on accessors).
    // §27.2.4.6 — the getter's `name` property is
    // `"get [Symbol.species]"`; the `get ` prefix is required by
    // §10.2.10 SetFunctionName for accessor functions.
    const species_getter = try intrinsics.makeNativeFunction(realm, promiseSpeciesGetter, 0, "get [Symbol.species]");
    realm.intrinsics.promise_species_getter = species_getter;
    const sp_entry = try fn_obj.accessors.getOrPut(realm.allocator, "@@species");
    sp_entry.value_ptr.* = .{ .getter = species_getter };
    try fn_obj.property_flags.put(realm.allocator, "@@species", .{
        .writable = false,
        .enumerable = false,
        .configurable = true,
    });

    // `__drainMicrotasks` moved to `Realm.installTestGlobals`
    // (debug-only; not installed on production realms). Inline
    // tests / the test262 harness / the playground all call
    // `installTestGlobals` explicitly after `installBuiltins`.
    // See `Realm.installTestGlobals` in src/runtime/realm.zig.
}

/// §27.2.4.6 `get Promise [ @@species ]`. The spec says "Return
/// the `this` value." Subclasses inherit this getter, so
/// `Foo.prototype[Symbol.species] === Foo` for any
/// `class Foo extends Promise {}`.
fn promiseSpeciesGetter(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = realm;
    _ = args;
    return this_value;
}

pub fn microtaskDrainNative(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = this_value;
    _ = args;
    const lantern = @import("../lantern/interpreter.zig");
    lantern.drainMicrotasks(realm.allocator, realm) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.NativeThrew,
    };
    return Value.undefined_;
}

/// Re-export of the typed `[[PromiseState]]` slot defined in
/// `runtime/object.zig`. The state is stored as an enum field on
/// `JSObject` (`promise_state`), NOT as a property — so a user
/// can't forge a Promise by setting `__cynic_promise_state__` on
/// a plain object.
pub const PromiseState = @import("../object.zig").PromiseState;

pub fn allocatePromise(realm: *Realm, state: PromiseState, value: Value) !Value {
    return allocatePromiseFor(realm, null, state, value);
}

/// Allocate a promise instance whose `[[Prototype]]` is
/// `ctor.prototype` if `ctor` is non-null, else the global
/// `%Promise.prototype%`. Used by `Promise.resolve` /
/// `Promise.reject` / `Promise.all` / etc. to honor the
/// receiver constructor for subclassing
/// (`SubPromise.resolve(x) instanceof SubPromise`).
/// §27.2.1.5 NewPromiseCapability(C). Builds a `{promise,
/// resolve, reject}` triple by calling `C` as a constructor with
/// a closure-shaped executor that captures the resolve/reject
/// arguments. The executor is GetCapabilitiesExecutor (§27.2.1.5.1):
/// it stores the args into the capability and **throws TypeError
/// on a second call**.
///
/// User code reaches this through `Promise.{all, allSettled, race,
/// any, resolve, reject}.call(C, …)` — every aggregator has to
/// build a fresh capability through the constructor, so a
/// subclassed Promise can intercept (or a poisoned constructor
/// can reject before any iteration starts).
pub const PromiseCapability = struct {
    promise: Value,
    resolve: *JSFunction,
    reject: *JSFunction,
};

/// Native impl behind the executor JSFunction. The executor is
/// allocated as a bound function whose `bound_this` is the state
/// JSObject that records the resolve / reject pair; calls dispatch
/// through `bound_target` so `this_value` here is the state.
fn capabilityExecutorImpl(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const state = heap_mod.valueAsPlainObject(this_value) orelse return throwTypeError(realm, "capability executor: state not bound");
    const rec = state.getCapabilityRecord() orelse return throwTypeError(realm, "capability executor: state missing");
    // §27.2.1.5.1 GetCapabilitiesExecutor Functions —
    //   3. If F.[[Capability]].[[Resolve]] is not undefined → TypeError.
    //   4. If F.[[Capability]].[[Reject]]  is not undefined → TypeError.
    //   5/6. Else set them (even to undefined / non-callable —
    //   the callable check belongs to NewPromiseCapability step
    //   7-8, the executor itself doesn't filter).
    if (!rec.resolve.isUndefined()) return throwTypeError(realm, "capability executor: resolve already set");
    if (!rec.reject.isUndefined()) return throwTypeError(realm, "capability executor: reject already set");
    rec.resolve = if (args.len >= 1) args[0] else Value.undefined_;
    rec.reject = if (args.len >= 2) args[1] else Value.undefined_;
    rec.called = true;
    return Value.undefined_;
}

pub fn newPromiseCapability(realm: *Realm, ctor: *JSFunction) NativeError!PromiseCapability {
    if (!ctor.has_construct or ctor.is_arrow) {
        return throwTypeError(realm, "Promise capability: not a constructor");
    }
    // Capture state on a fresh JSObject. Wrapping the executor as
    // a bound function lets the impl pick up the state via
    // `this_value` without needing closures.
    const state = realm.heap.allocateObject() catch return error.OutOfMemory;
    realm.heap.setObjectPrototype(state, realm.intrinsics.object_prototype);
    // Root `state` (and the executor below) across the executor
    // allocations and the user-constructor `constructValue` call —
    // the latter runs arbitrary JS and can GC repeatedly. `state`'s
    // `capability_record` is where the executor stashes resolve/reject,
    // so a swept `state` mid-construct loses the capability and the
    // executor's `bound_this` dangles.
    const cap_sc = realm.heap.openScope() catch return error.OutOfMemory;
    defer cap_sc.close();
    cap_sc.push(heap_mod.taggedObject(state)) catch return error.OutOfMemory;
    const rec = realm.allocator.create(@import("../object.zig").PromiseCapabilityRecord) catch return error.OutOfMemory;
    rec.* = .{};
    try state.setCapabilityRecord(realm.allocator, rec);

    // §27.2.1.5.1 GetCapabilitiesExecutor Functions — anonymous,
    // length 2, non-constructor. Observable when a subclass /
    // poisoned constructor inspects the executor it received.
    const executor_impl = realm.heap.allocateFunctionNative(realm, capabilityExecutorImpl, 2, "") catch return error.OutOfMemory;
    executor_impl.proto = realm.intrinsics.function_prototype;
    executor_impl.has_construct = false;
    cap_sc.push(heap_mod.taggedFunction(executor_impl)) catch return error.OutOfMemory;
    const executor = realm.heap.allocateFunctionNative(realm, boundResolveTrampoline, 2, "") catch return error.OutOfMemory;
    executor.proto = realm.intrinsics.function_prototype;
    executor.has_construct = false;
    cap_sc.push(heap_mod.taggedFunction(executor)) catch return error.OutOfMemory;
    realm.heap.setBoundTarget(executor, executor_impl);
    realm.heap.setBoundThis(executor, heap_mod.taggedObject(state));

    // §27.2.1.5 step 6 — Construct(C, «executor»).
    const interp = @import("../lantern/interpreter.zig");
    const ctor_v = heap_mod.taggedFunction(ctor);
    const construct_outcome = interp.constructValue(realm.allocator, realm, ctor_v, &.{heap_mod.taggedFunction(executor)}, ctor_v) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.NativeThrew,
    };
    const promise_v = switch (construct_outcome) {
        .value, .yielded => |v| v,
        .thrown => |ex| {
            realm.pending_exception = ex;
            return error.NativeThrew;
        },
    };

    // §27.2.1.5 step 7-8 — IsCallable(resolve) / IsCallable(reject).
    const resolve_fn = heap_mod.valueAsFunction(rec.resolve) orelse return throwTypeError(realm, "Promise capability: resolve is not callable");
    const reject_fn = heap_mod.valueAsFunction(rec.reject) orelse return throwTypeError(realm, "Promise capability: reject is not callable");
    return PromiseCapability{ .promise = promise_v, .resolve = resolve_fn, .reject = reject_fn };
}

/// Settle a capability through its resolve function. The resolve
/// function is whatever the user constructor's executor handed
/// us — could be the standard Cynic resolve closure (settles the
/// Promise), could be user-supplied (subclasses).
pub fn capabilityResolve(realm: *Realm, cap: PromiseCapability, value: Value) NativeError!Value {
    const interp = @import("../lantern/interpreter.zig");
    const outcome = interp.callJSFunction(realm.allocator, realm, cap.resolve, Value.undefined_, &.{value}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.NativeThrew,
    };
    switch (outcome) {
        .value, .yielded => return cap.promise,
        .thrown => |ex| {
            realm.pending_exception = ex;
            return error.NativeThrew;
        },
    }
}

pub fn capabilityReject(realm: *Realm, cap: PromiseCapability, reason: Value) NativeError!Value {
    const interp = @import("../lantern/interpreter.zig");
    const outcome = interp.callJSFunction(realm.allocator, realm, cap.reject, Value.undefined_, &.{reason}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.NativeThrew,
    };
    switch (outcome) {
        .value, .yielded => return cap.promise,
        .thrown => |ex| {
            realm.pending_exception = ex;
            return error.NativeThrew;
        },
    }
}

pub fn allocatePromiseFor(
    realm: *Realm,
    ctor: ?*JSFunction,
    state: PromiseState,
    value: Value,
) !Value {
    const obj = try realm.heap.allocateObject();
    if (ctor) |c| {
        if (c.prototype) |p| realm.heap.setObjectPrototype(obj, p);
    }
    if (obj.prototype == null) {
        // §27 — when no caller-supplied constructor is in play we use
        // the intrinsic `%PromisePrototype%` directly. Reading
        // `globals.get("Promise")` would observe a user-mutated global
        // (see test262 language/expressions/dynamic-import/
        // returns-promise.js where `globalThis.Promise` is overridden);
        // engine-internal Promises must keep the intrinsic shape.
        realm.heap.setObjectPrototype(obj, realm.intrinsics.promise_prototype orelse realm.intrinsics.object_prototype);
    }
    // §27.2.3.1 — the spec models `[[PromiseState]]` /
    // `[[PromiseResult]]` as internal slots, NOT properties.
    // We store them as typed JSObject fields so they don't
    // surface in `Object.keys` / `in` / property reads.
    realm.heap.settlePromise(obj, state, value);
    return heap_mod.taggedObject(obj);
}

/// §27.2.4 Promise.* — receiver-as-constructor validation.
/// Throws TypeError if `this_value` isn't a callable
/// constructor. Returns the JSFunction so the caller can use
/// its `.prototype` for the result promise.
fn thisAsPromiseCtor(realm: *Realm, this_value: Value, op_name: []const u8) NativeError!*JSFunction {
    const fn_obj = heap_mod.valueAsFunction(this_value) orelse {
        var buf: [128]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "Promise.{s} called on non-constructor", .{op_name}) catch op_name;
        return throwTypeError(realm, msg);
    };
    if (!fn_obj.has_construct or fn_obj.is_arrow) {
        var buf: [128]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "Promise.{s} called on non-constructor", .{op_name}) catch op_name;
        return throwTypeError(realm, msg);
    }
    return fn_obj;
}

fn promiseStateOf(v: Value) PromiseState {
    const obj = heap_mod.valueAsPlainObject(v) orelse return .none;
    return obj.promise_state;
}

fn promiseValueOf(v: Value) Value {
    const obj = heap_mod.valueAsPlainObject(v) orelse return Value.undefined_;
    return obj.promise_value;
}

fn promiseConstructor(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = this_value; // §27.2.3.1 — OCFC is deferred (see install:
    // `defers_proto_lookup`). The construct path stashes newTarget
    // on `realm.pending_native_new_target`; absence means we were
    // called without `new`.
    const new_target = realm.pending_native_new_target;
    if (new_target.isUndefined()) {
        return throwTypeError(realm, "Promise constructor requires 'new'");
    }
    // §27.2.3.1 step 2 — IsCallable(executor) FIRST. This must
    // throw BEFORE OrdinaryCreateFromConstructor would observe a
    // user-installed `prototype` getter on newTarget. The
    // `get-prototype-abrupt-executor-not-callable` fixture pins
    // this order.
    const executor = heap_mod.valueAsFunction(argOr(args, 0, Value.undefined_)) orelse return throwTypeError(realm, "Promise executor must be a function");

    // §27.2.3.1 step 3 — OrdinaryCreateFromConstructor. Read the
    // prototype off newTarget (may throw from a user getter) and
    // allocate the instance.
    const interp = @import("../lantern/interpreter.zig");
    const proto_lookup = interp.getPrototypeFromConstructorValue(realm.allocator, realm, new_target, realm.intrinsics.promise_prototype, realm) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.NativeThrew,
    };
    const proto: ?*@import("../object.zig").JSObject = switch (proto_lookup) {
        .proto => |p| p,
        .proto_fn => null, // function-valued proto — applied via the parallel slot below
        .thrown => |ex| {
            realm.pending_exception = ex;
            return error.NativeThrew;
        },
    };
    const inst = realm.heap.allocateObject() catch return error.OutOfMemory;
    if (proto_lookup == .proto_fn) realm.heap.setObjectPrototypeFn(inst, proto_lookup.proto_fn) else realm.heap.setObjectPrototype(inst, proto);
    const inst_v = heap_mod.taggedObject(inst);

    // Initial state: pending.
    realm.heap.settlePromise(inst, .pending, Value.undefined_);

    // Resolve / reject capture the target Promise via a
    // bound-function trick: the actual native (impl) takes its
    // target from `this_value`, and we wrap it in a bound
    // function whose `bound_this` IS the target Promise. When
    // user code calls `resolve(v)`, the bind machinery unwraps
    // and calls the impl with `this_value = target_promise`.
    // §27.2.1.3 Promise Resolve/Reject Functions — these are
    // anonymous (`name: ""`) and not constructors (`hasOwn-
    // Property(resolveFn, "prototype") === false`,
    // `new resolveFn()` throws).
    const resolve_impl = realm.heap.allocateFunctionNative(realm, promiseResolveImpl, 1, "") catch return error.OutOfMemory;
    resolve_impl.proto = realm.intrinsics.function_prototype;
    resolve_impl.has_construct = false;
    const resolve_fn = realm.heap.allocateFunctionNative(realm, boundResolveTrampoline, 1, "") catch return error.OutOfMemory;
    resolve_fn.proto = realm.intrinsics.function_prototype;
    resolve_fn.has_construct = false;
    realm.heap.setBoundTarget(resolve_fn, resolve_impl);
    realm.heap.setBoundThis(resolve_fn, inst_v);

    const reject_impl = realm.heap.allocateFunctionNative(realm, promiseRejectImpl, 1, "") catch return error.OutOfMemory;
    reject_impl.proto = realm.intrinsics.function_prototype;
    reject_impl.has_construct = false;
    const reject_fn = realm.heap.allocateFunctionNative(realm, boundResolveTrampoline, 1, "") catch return error.OutOfMemory;
    reject_fn.proto = realm.intrinsics.function_prototype;
    reject_fn.has_construct = false;
    realm.heap.setBoundTarget(reject_fn, reject_impl);
    realm.heap.setBoundThis(reject_fn, inst_v);

    // Run the executor synchronously with (resolve, reject).
    const lantern = @import("../lantern/interpreter.zig");
    const exec_args = [_]Value{ heap_mod.taggedFunction(resolve_fn), heap_mod.taggedFunction(reject_fn) };
    const outcome = lantern.callJSFunction(realm.allocator, realm, executor, Value.undefined_, &exec_args) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.NativeThrew,
    };
    switch (outcome) {
        .value, .yielded => {},
        .thrown => |ex| {
            // §27.2.3.1 step 10 — executor threw. Reject ONLY if the
            // resolving functions haven't already been invoked (e.g.
            // `resolve(thenable); throw …` leaves the Promise pending
            // until the thenable job runs, so the throw is ignored
            // per §27.2.1.3.2 alreadyResolved guard).
            if (!inst.promise_already_resolved) {
                inst.promise_already_resolved = true;
                settlePromise(realm, inst, .rejected, ex) catch return error.OutOfMemory;
            }
        },
    }
    return inst_v;
}

fn settlePromise(realm: *Realm, inst: *@import("../object.zig").JSObject, state: enum { fulfilled, rejected }, value: Value) !void {
    if (inst.promise_state != .pending) return; // already settled
    realm.heap.settlePromise(inst, switch (state) {
        .fulfilled => .fulfilled,
        .rejected => .rejected,
    }, value);
}

/// `resolve(v)` impl. The bound-function trampoline arranges
/// for `this_value` to be the target Promise (set as
/// `bound_this` at promise-constructor time). When user code
/// calls `resolve(42)`, the bind unwrap dispatches into here
/// with the target Promise as `this_value`.
pub const promiseResolveImplExported = promiseResolveImpl;
pub const promiseRejectImplExported = promiseRejectImpl;
pub const boundResolveTrampolineExported = boundResolveTrampoline;
/// Native-callback identity for `Promise.prototype.then` — read by
/// `lantern.isVanillaPromiseChain` to detect a monkey-patched
/// `.then` (which would invalidate the chain-shortcut and require
/// the spec PromiseResolveThenableJob path per §27.2.1.3.2 step 12).
pub const promiseThenExported = promiseThen;
/// `Promise.resolve` static — used by `%AsyncIteratorPrototype%
/// [@@asyncDispose]` to wrap a `return()` result in a same-realm
/// Promise before attaching the unwrap reaction. The receiver
/// must be the built-in `Promise` constructor value (or a
/// subclass) so `thisAsPromiseCtor` accepts it.
pub const promiseResolveExported = promiseResolve;

fn promiseResolveImpl(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const target = heap_mod.valueAsPlainObject(this_value) orelse return Value.undefined_;
    const v = argOr(args, 0, Value.undefined_);
    const interp = @import("../lantern/interpreter.zig");
    // §27.2.1.3.2 Promise Resolve Functions step 2 —
    // alreadyResolved guard. Set TRUE on first call regardless
    // of which path the resolution ultimately settles through.
    if (target.promise_already_resolved) return Value.undefined_;
    target.promise_already_resolved = true;
    if (target.promise_state != .pending) return Value.undefined_;

    // Step 4 — resolution === target → TypeError.
    if (heap_mod.valueAsPlainObject(v)) |v_obj| {
        if (v_obj == target) {
            const ex = intrinsics.newTypeError(realm, "Chaining cycle detected for promise") catch return error.OutOfMemory;
            interp.settlePromiseInternal(realm, target, .rejected, ex) catch return error.OutOfMemory;
            return Value.undefined_;
        }
        // Step 5 — if resolution is not an Object, fulfill (handled
        // by the non-Object fall-through below).
        // Step 7 — Get(resolution, "then"). For a Cynic Promise we
        // already know `.then` is the built-in; chain inline.
        //
        // §27.2.1.3.2 step 11-13 fast-path: vanilla Promise-to-vanilla
        // Promise adoption is observably equivalent to an inline
        // reaction enqueue; subclass or monkey-patched-`then` cases
        // must take the spec path so each `.then` allocates a fresh
        // capability via SpeciesConstructor (§27.2.5.3 species-count
        // fixtures).
        if (v_obj.isPromise()) {
            const interp_mod = @import("../lantern/interpreter.zig");
            if (interp_mod.isVanillaPromiseChainExported(realm, target, v_obj)) {
                chainPromiseToInner(realm, v_obj, target) catch return error.OutOfMemory;
                return Value.undefined_;
            }
            // Fall through to the generic thenable path below — it
            // looks up `then` and enqueues a PromiseResolveThenableJob.
        }
        const then_v = intrinsics.getPropertyChain(realm, v_obj, "then") catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => blk: {
                // §27.2.1.3.2 step 8 — abrupt Get(then) rejects.
                const ex = realm.pending_exception orelse Value.undefined_;
                realm.pending_exception = null;
                interp.settlePromiseInternal(realm, target, .rejected, ex) catch return error.OutOfMemory;
                break :blk Value.undefined_;
            },
        };
        if (target.promise_state != .pending) return Value.undefined_;
        // Step 10 — IsCallable(then) is false → fulfill with v.
        if (heap_mod.valueAsFunction(then_v) == null) {
            interp.settlePromiseInternal(realm, target, .fulfilled, v) catch return error.OutOfMemory;
            return Value.undefined_;
        }
        // Step 11 — enqueue PromiseResolveThenableJob.
        realm.enqueueThenableJob(this_value, v, then_v) catch return error.OutOfMemory;
        return Value.undefined_;
    }
    // Step 5 — non-Object resolution: fulfill.
    interp.settlePromiseInternal(realm, target, .fulfilled, v) catch return error.OutOfMemory;
    return Value.undefined_;
}

/// §27.2.1.3 PromiseResolveThenableJob helper — chain a real
/// Cynic Promise's settlement onto `outer`. Used by both
/// `promiseResolveImpl` (when resolution is itself a Promise)
/// and the aggregator forwarding path.
fn chainPromiseToInner(realm: *Realm, inner: *@import("../object.zig").JSObject, outer: *@import("../object.zig").JSObject) !void {
    const interp = @import("../lantern/interpreter.zig");
    switch (inner.promise_state) {
        .fulfilled => try realm.enqueuePromiseReaction(Value.undefined_, inner.promise_value, heap_mod.taggedObject(outer), false),
        .rejected => try realm.enqueuePromiseReaction(Value.undefined_, inner.promise_value, heap_mod.taggedObject(outer), true),
        .pending => {
            const reactions = try inner.promiseReactionsPtr(realm.allocator);
            try reactions.append(realm.allocator, .{
                .on_fulfilled = Value.undefined_,
                .on_rejected = Value.undefined_,
                .result_promise = heap_mod.taggedObject(outer),
            });
        },
        .none => {
            // Treated as plain object — defensive; shouldn't happen.
            interp.settlePromiseInternal(realm, outer, .fulfilled, heap_mod.taggedObject(inner)) catch return error.OutOfMemory;
        },
    }
}

fn promiseRejectImpl(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const target = heap_mod.valueAsPlainObject(this_value) orelse return Value.undefined_;
    const v = argOr(args, 0, Value.undefined_);
    const interp = @import("../lantern/interpreter.zig");
    // §27.2.1.3.1 Promise Reject Functions step 2 — alreadyResolved
    // guard. Sets the shared flag so a subsequent executor-threw
    // path (or duplicate reject) no-ops.
    if (target.promise_already_resolved) return Value.undefined_;
    target.promise_already_resolved = true;
    interp.settlePromiseInternal(realm, target, .rejected, v) catch return error.OutOfMemory;
    return Value.undefined_;
}

/// Trampoline body for the bound resolve/reject pair. Never
/// invoked directly by user code — the call ops short-circuit
/// bound functions via `bound_target`. Kept here so
/// `callJSFunction` reentry through `boundFunctionTrampoline`
/// (the existing generic) does the right thing if it does.
fn boundResolveTrampoline(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = realm;
    _ = this_value;
    _ = args;
    return Value.undefined_;
}

fn promiseThen(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    // §27.2.5.4 Promise.prototype.then —
    //   1. Let promise be the this value.
    //   2. If IsPromise(promise) is false, throw a TypeError.
    //   3. Let C be ? SpeciesConstructor(promise, %Promise%).
    //   4. Let resultCapability be ? NewPromiseCapability(C).
    //   5. Return PerformPromiseThen(promise, onFulfilled, onRejected, resultCapability).
    const source = heap_mod.valueAsPlainObject(this_value) orelse return throwTypeError(realm, "Promise.prototype.then on non-Promise");
    if (!source.isPromise()) return throwTypeError(realm, "Promise.prototype.then on non-Promise");

    // SpeciesConstructor — read `constructor` from the source.
    // A null/undefined/non-object constructor throws TypeError
    // (§7.3.22 step 3). Then read @@species; null/undefined
    // falls back to %Promise%. A non-constructor S throws.
    const builtin_promise = heap_mod.valueAsFunction(realm.globals.get("Promise") orelse Value.undefined_) orelse return throwTypeError(realm, "Promise.prototype.then: %Promise% missing");
    var c_fn: *JSFunction = builtin_promise;
    const ctor_v = getPropertyChain(realm, source, "constructor") catch return error.NativeThrew;
    if (!ctor_v.isUndefined()) {
        if (heap_mod.valueAsFunction(ctor_v)) |c_obj| {
            // §27.2.4.6 pristine-species short-circuit — the original
            // native getter's body is `return this`, so when the
            // constructor's `@@species` accessor still IS that getter,
            // invoking it through a JS call frame is pure overhead
            // (it ran on every `.then`). A user-replaced getter never
            // matches the stashed intrinsic and takes the full call.
            const species_v = blk: {
                if (c_obj.accessors.get("@@species")) |acc| {
                    if (acc.getter) |g| {
                        if (realm.intrinsics.promise_species_getter == g) break :blk ctor_v;
                    }
                }
                break :blk ctorGetMember(realm, c_obj, "@@species") catch return error.NativeThrew;
            };
            if (!species_v.isUndefined() and !species_v.isNull()) {
                const s_fn = heap_mod.valueAsFunction(species_v) orelse return throwTypeError(realm, "Promise.prototype.then: species is not a constructor");
                if (!s_fn.has_construct or s_fn.is_arrow) return throwTypeError(realm, "Promise.prototype.then: species is not a constructor");
                c_fn = s_fn;
            } else {
                c_fn = c_obj;
            }
        } else {
            return throwTypeError(realm, "Promise.prototype.then: constructor is not an object");
        }
    }

    const on_fulfilled = argOr(args, 0, Value.undefined_);
    const on_rejected = argOr(args, 1, Value.undefined_);
    const on_fulfilled_fn: Value = if (heap_mod.valueAsFunction(on_fulfilled) != null) on_fulfilled else Value.undefined_;
    const on_rejected_fn: Value = if (heap_mod.valueAsFunction(on_rejected) != null) on_rejected else Value.undefined_;

    // Fast path — built-in %Promise%, no subclass: allocate the
    // result promise directly without going through user code.
    if (c_fn == builtin_promise) {
        const value = source.promise_value;
        const result_promise = allocatePromise(realm, .pending, Value.undefined_) catch return error.OutOfMemory;
        switch (source.promise_state) {
            .fulfilled => realm.enqueuePromiseReaction(on_fulfilled_fn, value, result_promise, false) catch return error.OutOfMemory,
            .rejected => realm.enqueuePromiseReaction(on_rejected_fn, value, result_promise, true) catch return error.OutOfMemory,
            else => {
                const reactions = source.promiseReactionsPtr(realm.allocator) catch return error.OutOfMemory;
                reactions.append(realm.allocator, .{
                    .on_fulfilled = on_fulfilled_fn,
                    .on_rejected = on_rejected_fn,
                    .result_promise = result_promise,
                }) catch return error.OutOfMemory;
            },
        }
        return result_promise;
    }

    // Subclass path — NewPromiseCapability(C). The capability's
    // resolve/reject become the settlement edges.
    const cap = try newPromiseCapability(realm, c_fn);
    const value = source.promise_value;
    switch (source.promise_state) {
        .fulfilled => realm.enqueuePromiseReaction(on_fulfilled_fn, value, cap.promise, false) catch return error.OutOfMemory,
        .rejected => realm.enqueuePromiseReaction(on_rejected_fn, value, cap.promise, true) catch return error.OutOfMemory,
        else => {
            const reactions = source.promiseReactionsPtr(realm.allocator) catch return error.OutOfMemory;
            reactions.append(realm.allocator, .{
                .on_fulfilled = on_fulfilled_fn,
                .on_rejected = on_rejected_fn,
                .result_promise = cap.promise,
            }) catch return error.OutOfMemory;
        },
    }
    return cap.promise;
}

fn promiseCatch(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    // §27.2.5.1 Promise.prototype.catch — `return Invoke(this,
    // "then", « undefined, onRejected »)`. §7.3.18 Invoke calls
    // §7.3.2 GetV (which performs ToObject on the receiver for
    // the property lookup), then calls `func` with the ORIGINAL
    // `this_value`. So primitives are object-coercible — null /
    // undefined throw TypeError, everything else gets wrapped
    // just for the lookup.
    const cb = argOr(args, 0, Value.undefined_);
    const this_obj = try intrinsics.toObjectThis(realm, this_value);
    const then_v = getPropertyChain(realm, this_obj, "then") catch return error.NativeThrew;
    const then_fn = heap_mod.valueAsFunction(then_v) orelse return throwTypeError(realm, "Promise.prototype.catch: this.then is not callable");
    const interp = @import("../lantern/interpreter.zig");
    const then_args = [_]Value{ Value.undefined_, cb };
    const outcome = interp.callJSFunction(realm.allocator, realm, then_fn, this_value, &then_args) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.NativeThrew,
    };
    return switch (outcome) {
        .value, .yielded => |v| v,
        .thrown => |ex| {
            realm.pending_exception = ex;
            return error.NativeThrew;
        },
    };
}
/// §27.2.5.3 Promise.prototype.finally(onFinally).
///
/// Three branches:
/// 1. Receiver must be an Object → else TypeError.
/// 2. `onFinally` not callable → `this.then(onFinally, onFinally)`
///    per step 6 (the spec's "Promise.prototype.finally as
///    transparent passthrough"). The non-function then-args are
///    silently dropped by `then`'s own filter.
/// 3. `onFinally` callable → build `thenFinally` / `catchFinally`
///    wrappers that invoke `onFinally`, ignore its result, and
///    propagate the original value / re-throw the reason.
///
/// Cynic shortcut: we don't yet wrap the callback's return value
/// through `Promise.resolve` (§27.2.5.3 step 6.c). Fixtures that
/// expect `finally` to wait on a thenable result still time the
/// resolution one tick early. Tracked in the Promise triage.
/// §7.3.22 SpeciesConstructor(promise, %Promise%). Reads
/// `constructor` from `source`; if undefined fall back to
/// %Promise%. Otherwise reads `@@species` from the constructor;
/// if undefined / null fall back to the constructor itself.
/// Non-constructor results throw TypeError. Used by
/// `Promise.prototype.{then, finally}` to honor user subclasses.
fn promiseSpeciesConstructor(realm: *Realm, source: *JSObject) NativeError!*JSFunction {
    const builtin_promise = heap_mod.valueAsFunction(realm.globals.get("Promise") orelse Value.undefined_) orelse return throwTypeError(realm, "%Promise% missing");
    const ctor_v = getPropertyChain(realm, source, "constructor") catch return error.NativeThrew;
    if (ctor_v.isUndefined()) return builtin_promise;
    const c_obj = heap_mod.valueAsFunction(ctor_v) orelse return throwTypeError(realm, "SpeciesConstructor: constructor is not an object");
    const species_v = ctorGetMember(realm, c_obj, "@@species") catch return error.NativeThrew;
    if (species_v.isUndefined() or species_v.isNull()) return c_obj;
    const s_fn = heap_mod.valueAsFunction(species_v) orelse return throwTypeError(realm, "SpeciesConstructor: species is not a constructor");
    if (!s_fn.has_construct or s_fn.is_arrow) return throwTypeError(realm, "SpeciesConstructor: species is not a constructor");
    return s_fn;
}

fn promiseFinally(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const this_obj = heap_mod.valueAsPlainObject(this_value) orelse return throwTypeError(realm, "Promise.prototype.finally called on non-object");
    const on_finally = argOr(args, 0, Value.undefined_);
    const on_finally_fn = heap_mod.valueAsFunction(on_finally);

    // §27.2.5.3 step 3 — `Let C be ? SpeciesConstructor(promise,
    // %Promise%)`. The thenFinally / catchFinally reactions wrap
    // the callback result via `PromiseResolve(C, …)` so user-
    // subclassed promises see their own constructor called for
    // the wrap. Default to %Promise% when constructor lookup
    // falls back per §7.3.22.
    const C: *JSFunction = try promiseSpeciesConstructor(realm, this_obj);

    // §27.2.5.3 step 4-7 — build the two reaction wrappers when
    // onFinally is callable; otherwise pass through.
    var then_arg: Value = on_finally;
    var catch_arg: Value = on_finally;
    // Root the reaction context + both wrappers across the
    // allocations below AND the `.then` call further down (which
    // allocates a capability before enqueuing the reactions). Until
    // a wrapper lands in a microtask's reaction_handler it is
    // reachable only through unrooted native locals; a mid-`.then`
    // sweep would otherwise enqueue a dangling handler. Opened at
    // function scope so it outlives the `.then` invocation.
    const fin_sc = realm.heap.openScope() catch return error.OutOfMemory;
    defer fin_sc.close();
    if (on_finally_fn != null) {
        const ctx = realm.heap.allocateObject() catch return error.OutOfMemory;
        realm.heap.setObjectPrototype(ctx, realm.intrinsics.object_prototype);
        fin_sc.push(heap_mod.taggedObject(ctx)) catch return error.OutOfMemory;
        try realm.heap.setFinallyCallback(ctx, on_finally_fn);
        try realm.heap.setFinallyConstructor(ctx, C);

        const then_fn = realm.heap.allocateFunctionNative(realm, finallyThenReaction, 1, "") catch return error.OutOfMemory;
        then_fn.proto = realm.intrinsics.function_prototype;
        then_fn.is_arrow = true;
        fin_sc.push(heap_mod.taggedFunction(then_fn)) catch return error.OutOfMemory;
        realm.heap.setCapturedThis(then_fn, heap_mod.taggedObject(ctx));

        const catch_fn = realm.heap.allocateFunctionNative(realm, finallyCatchReaction, 1, "") catch return error.OutOfMemory;
        catch_fn.proto = realm.intrinsics.function_prototype;
        catch_fn.is_arrow = true;
        fin_sc.push(heap_mod.taggedFunction(catch_fn)) catch return error.OutOfMemory;
        realm.heap.setCapturedThis(catch_fn, heap_mod.taggedObject(ctx));

        then_arg = heap_mod.taggedFunction(then_fn);
        catch_arg = heap_mod.taggedFunction(catch_fn);
    }
    // §27.2.5.3 step 8 — Invoke(promise, "then", « thenFinally,
    // catchFinally »). Use the user-visible `.then` so plain
    // thenables (whose prototype installs a custom then) and
    // subclasses dispatch correctly.
    const then_v = getPropertyChain(realm, this_obj, "then") catch return error.NativeThrew;
    const then_fn = heap_mod.valueAsFunction(then_v) orelse return throwTypeError(realm, "Promise.prototype.finally: this.then is not callable");
    const interp = @import("../lantern/interpreter.zig");
    const then_args = [_]Value{ then_arg, catch_arg };
    const outcome = interp.callJSFunction(realm.allocator, realm, then_fn, this_value, &then_args) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.NativeThrew,
    };
    return switch (outcome) {
        .value, .yielded => |v| v,
        .thrown => |ex| {
            realm.pending_exception = ex;
            return error.NativeThrew;
        },
    };
}

/// Step 6 of §27.2.5.3 — onFinally for fulfilled path.
///   a. Let result be ? Call(onFinally).
///   b. Let promise be ? PromiseResolve(C, result).
///   c. Let valueThunk be a new built-in function that returns value.
///   d. Return ? Invoke(promise, "then", « valueThunk »).
///
/// When `result` is a thenable (or rejected Promise), the chain waits
/// for `result` to settle and forwards `value` (or `result`'s rejection
/// reason) — `.finally(() => rejectedPromise)` rejects the .finally
/// outer with the rejected reason, NOT the original fulfilled value.
fn finallyThenReaction(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const value = argOr(args, 0, Value.undefined_);
    const ctx = heap_mod.valueAsPlainObject(this_value) orelse return value;
    const cb = ctx.getFinallyCallback() orelse return value;
    const interp = @import("../lantern/interpreter.zig");
    const cb_outcome = interp.callJSFunction(realm.allocator, realm, cb, Value.undefined_, &.{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.NativeThrew,
    };
    const result = switch (cb_outcome) {
        .value, .yielded => |v| v,
        .thrown => |ex| {
            realm.pending_exception = ex;
            return error.NativeThrew;
        },
    };
    return chainFinallyResult(realm, result, value, false, ctx.getFinallyConstructor());
}

/// Step 7 of §27.2.5.3 — onFinally for rejected path. Same shape as
/// step 6 but the value thunk re-throws `reason` instead of returning
/// `value`.
fn finallyCatchReaction(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const reason = argOr(args, 0, Value.undefined_);
    const ctx = heap_mod.valueAsPlainObject(this_value) orelse {
        realm.pending_exception = reason;
        return error.NativeThrew;
    };
    const cb = ctx.getFinallyCallback() orelse {
        realm.pending_exception = reason;
        return error.NativeThrew;
    };
    const interp = @import("../lantern/interpreter.zig");
    const cb_outcome = interp.callJSFunction(realm.allocator, realm, cb, Value.undefined_, &.{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.NativeThrew,
    };
    const result = switch (cb_outcome) {
        .value, .yielded => |v| v,
        .thrown => |ex| {
            realm.pending_exception = ex;
            return error.NativeThrew;
        },
    };
    return chainFinallyResult(realm, result, reason, true, ctx.getFinallyConstructor());
}

/// Wrap `result` in a Promise (§27.2.4.7 PromiseResolve), then chain
/// a value-thunk that returns `carry` (if `is_throw=false`) or throws
/// `carry` (if `is_throw=true`). Equivalent to the spec's
/// `Invoke(promise, "then", « valueThunk »)`.
///
/// When `result` is not a thenable, the short path returns `carry`
/// directly (or throws for the catch path) — matches the spec's
/// PromiseResolve fast path on a primitive.
fn chainFinallyResult(realm: *Realm, result: Value, carry: Value, is_throw: bool, ctor: ?*JSFunction) NativeError!Value {
    // §27.2.5.3 step 6.b / 7.b — `promise = ? PromiseResolve(C,
    // result)`. PromiseResolve fast-paths when `result` is already
    // a Promise whose constructor IS C: just return result. For
    // plain values (the common `.finally(() => undefined)` case)
    // we still need to allocate so step 6.d / 7.d (`Invoke(promise,
    // "then", « valueThunk »)`) settles via C's reactions, not
    // by the synchronous `carry` shortcut.
    const builtin_promise = heap_mod.valueAsFunction(realm.globals.get("Promise") orelse Value.undefined_);
    const using_default = ctor == null or ctor.? == builtin_promise;
    const result_obj = heap_mod.valueAsPlainObject(result);
    const is_thenable_blk: bool = blk: {
        if (result_obj) |obj| {
            if (obj.isPromise()) break :blk true;
            const then_v = obj.get("then");
            if (heap_mod.valueAsFunction(then_v) != null) break :blk true;
        }
        break :blk false;
    };
    // Fast path: built-in Promise + non-thenable result. Skip the
    // `PromiseResolve(C, result).then(thunk)` chain — the value-
    // thunk's effect is observably equivalent to settling with
    // `carry` directly (microtask scheduling order doesn't matter
    // for a synchronous handler).
    if (using_default and !is_thenable_blk) {
        if (is_throw) {
            realm.pending_exception = carry;
            return error.NativeThrew;
        }
        return carry;
    }

    // Wrap result through PromiseResolve(C, result). When C is the
    // built-in %Promise%, fast-path for already-Promise results;
    // otherwise build a fresh capability via C so subclasses
    // observe their constructor call (§27.2.5.3 species-count
    // fixtures).
    const wrapped = blk: {
        if (using_default) {
            if (result_obj) |obj| if (obj.isPromise()) break :blk result;
            // Default constructor + thenable result: synthesise via
            // PromiseResolveThenableJob.
            const new_p_v = try @import("../lantern/interpreter.zig").wrapInPromise(realm, true, Value.undefined_);
            const new_p = heap_mod.valueAsPlainObject(new_p_v) orelse return error.OutOfMemory;
            new_p.promise_state = .pending;
            new_p.promise_value = Value.undefined_;
            const then_v = if (result_obj) |obj| obj.get("then") else Value.undefined_;
            realm.enqueueThenableJob(new_p_v, result, then_v) catch return error.OutOfMemory;
            break :blk new_p_v;
        }
        // Subclass path — NewPromiseCapability(C) + Resolve(result).
        // PromiseResolve(C, result) per §27.2.4.7: if result is a
        // Promise whose constructor IS C, identity-return; else
        // build a fresh capability via C and resolve(result).
        const C = ctor.?;
        if (result_obj) |obj| {
            if (obj.isPromise()) {
                const result_ctor = heap_mod.valueAsFunction(getPropertyChain(realm, obj, "constructor") catch return error.NativeThrew);
                if (result_ctor != null and result_ctor.? == C) break :blk result;
            }
        }
        const cap = try newPromiseCapability(realm, C);
        // Call cap.resolve(result) so adoption (thenable or plain)
        // routes through the capability's resolve closure.
        const interp_mod = @import("../lantern/interpreter.zig");
        const resolve_args = [_]Value{result};
        const r_outcome = interp_mod.callJSFunction(realm.allocator, realm, cap.resolve, Value.undefined_, &resolve_args) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.NativeThrew,
        };
        switch (r_outcome) {
            .value, .yielded => {},
            .thrown => |ex| {
                realm.pending_exception = ex;
                return error.NativeThrew;
            },
        }
        break :blk cap.promise;
    };

    // Build the value-thunk context (captures `carry` + the throw flag).
    const thunk_ctx = realm.heap.allocateObject() catch return error.OutOfMemory;
    realm.heap.setObjectPrototype(thunk_ctx, realm.intrinsics.object_prototype);
    try realm.heap.setFinallyValue(thunk_ctx, carry);
    const thunk_fn = realm.heap.allocateFunctionNative(
        realm,
        if (is_throw) finallyThrowThunk else finallyReturnThunk,
        0,
        "",
    ) catch return error.OutOfMemory;
    thunk_fn.proto = realm.intrinsics.function_prototype;
    thunk_fn.is_arrow = true;
    realm.heap.setCapturedThis(thunk_fn, heap_mod.taggedObject(thunk_ctx));

    // Invoke(wrapped, "then", « thunk »).
    const wrapped_obj = heap_mod.valueAsPlainObject(wrapped) orelse return error.OutOfMemory;
    const then_v = getPropertyChain(realm, wrapped_obj, "then") catch return error.NativeThrew;
    const then_fn = heap_mod.valueAsFunction(then_v) orelse return error.NativeThrew;
    const interp = @import("../lantern/interpreter.zig");
    const then_args = [_]Value{heap_mod.taggedFunction(thunk_fn)};
    const outcome = interp.callJSFunction(realm.allocator, realm, then_fn, wrapped, &then_args) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.NativeThrew,
    };
    return switch (outcome) {
        .value, .yielded => |v| v,
        .thrown => |ex| {
            realm.pending_exception = ex;
            return error.NativeThrew;
        },
    };
}

/// `() => carry` — value-thunk for the §27.2.5.3 step 6.c return
/// path. Captures the carried fulfilment value via `is_arrow +
/// captured_this`.
fn finallyReturnThunk(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = realm;
    _ = args;
    const ctx = heap_mod.valueAsPlainObject(this_value) orelse return Value.undefined_;
    return ctx.getFinallyValue();
}

/// `() => { throw carry }` — value-thunk for the §27.2.5.3 step 7.c
/// re-throw path. Same context shape as `finallyReturnThunk`.
fn finallyThrowThunk(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = args;
    const ctx = heap_mod.valueAsPlainObject(this_value) orelse {
        realm.pending_exception = Value.undefined_;
        return error.NativeThrew;
    };
    realm.pending_exception = ctx.getFinallyValue();
    return error.NativeThrew;
}

/// §27.2.4.7 Promise.resolve. When the receiver is a subclassed
/// constructor we go through NewPromiseCapability so the user's
/// constructor sees its executor; for the built-in `Promise`
/// constructor we short-circuit through `allocatePromiseFor` and
/// the `v` is already a same-realm Promise pass-through.
fn promiseResolve(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const ctor = try thisAsPromiseCtor(realm, this_value, "resolve");
    const v = argOr(args, 0, Value.undefined_);
    // §27.2.4.7 step 4 — if `v` is already a promise whose
    // constructor is exactly `this`, return it unchanged. We
    // check `v.constructor === ctor` rather than the proper
    // [[Get]]("constructor") chain walk; close enough for the
    // common-case fixtures.
    if (heap_mod.valueAsPlainObject(v)) |maybe| {
        if (promiseStateOf(v) != .none) {
            const c_v = maybe.get("constructor");
            if (heap_mod.valueAsFunction(c_v)) |c| {
                if (c == ctor) return v;
            }
        }
    }
    // For the built-in Promise constructor, the fast path
    // produces an internally-tagged result; for user constructors
    // we go through NewPromiseCapability so the executor's
    // resolve receives `v`. A thenable / Promise resolution must
    // still walk §27.2.1.3.2 — synthesize a pending Promise and
    // route through the spec resolve function.
    const builtin_promise = heap_mod.valueAsFunction(realm.globals.get("Promise") orelse Value.undefined_);
    if (builtin_promise != null and ctor == builtin_promise.?) {
        if (heap_mod.valueAsPlainObject(v)) |_| {
            const pending = allocatePromiseFor(realm, ctor, .pending, Value.undefined_) catch return error.OutOfMemory;
            const target = heap_mod.valueAsPlainObject(pending).?;
            // `promiseResolveImpl` re-enters JS — `Get(v, "then")`
            // runs a user accessor / the thenable job — and can GC.
            // `pending` is a native local the GC can't see; root it
            // across the call so it isn't swept out from under the
            // `return`. gc-threshold=1 repro: `Promise.resolve(
            // poisonedThen)` returned a freed Promise, and the
            // subsequent `.then` segfaulted deref'ing its shape.
            const scope = realm.heap.openScope() catch return error.OutOfMemory;
            defer scope.close();
            scope.push(pending) catch return error.OutOfMemory;
            const resolve_args = [_]Value{v};
            _ = try promiseResolveImpl(realm, heap_mod.taggedObject(target), &resolve_args);
            return pending;
        }
        return allocatePromiseFor(realm, ctor, .fulfilled, v) catch return error.OutOfMemory;
    }
    const cap = try newPromiseCapability(realm, ctor);
    return capabilityResolve(realm, cap, v);
}
fn promiseReject(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const ctor = try thisAsPromiseCtor(realm, this_value, "reject");
    const reason = argOr(args, 0, Value.undefined_);
    const builtin_promise = heap_mod.valueAsFunction(realm.globals.get("Promise") orelse Value.undefined_);
    if (builtin_promise != null and ctor == builtin_promise.?) {
        return allocatePromiseFor(realm, ctor, .rejected, reason) catch return error.OutOfMemory;
    }
    const cap = try newPromiseCapability(realm, ctor);
    return capabilityReject(realm, cap, reason);
}
/// Walk an iterable into an owned []Value list. Mirrors §7.4.2 +
/// §7.4.5 IteratorToList — calls `@@iterator`, steps `next`, and
/// stops on `done: true`. Falls back to array-like `length` +
/// indexed get when the input lacks `@@iterator`. Errors during
/// iterator-protocol resolution surface as `NativeThrew` with the
/// thrown value pinned to `realm.pending_exception` so the
/// aggregator's caller can convert it into a rejected promise
/// rather than re-throw synchronously (§27.2.4.1.1 step 6).
/// §7.4.1 Iterator Records — captures the open iterator + its
/// pre-resolved `next` method. `done` flips true when the iterator
/// reports done OR when an abrupt completion makes IteratorClose
/// the caller's responsibility.
const IteratorRecord = struct {
    iter: *JSObject,
    iter_v: Value,
    next_fn: *JSFunction,
    done: bool = false,
};

/// §7.4.2 GetIterator — open `source_v`'s `@@iterator`. Returns
/// `null` when the source has no iterator method (caller falls
/// back to the array-like path); otherwise an open record the
/// caller must close (or ride to completion). Errors during
/// `@@iterator` invocation, `next` lookup, or shape checks raise
/// `error.NativeThrew` with `realm.pending_exception` set.
fn iteratorOpen(realm: *Realm, source_v: Value) NativeError!?IteratorRecord {
    const interp = @import("../lantern/interpreter.zig");
    // §7.4.2 GetIterator: ToObject the source first so primitive
    // wrappers (`""`, `42`, …) get their prototype's `@@iterator`
    // (e.g. `String.prototype[@@iterator]`). null / undefined
    // remain a TypeError via `toObjectThis`.
    const obj = if (heap_mod.valueAsPlainObject(source_v)) |o|
        o
    else if (source_v.isNull() or source_v.isUndefined())
        return throwTypeError(realm, "Cannot convert null or undefined to object")
    else
        try intrinsics.toObjectThis(realm, source_v);
    const iter_method_v = try getPropertyChain(realm, obj, "@@iterator");
    // §7.3.10 GetMethod — null / undefined both mean "no method"
    // and the caller falls back. A *present, non-callable*
    // @@iterator (e.g. a number) must throw TypeError per
    // GetIterator step 4 (Call on a non-callable).
    // §7.4.2 GetIterator (sync) — null / undefined for the
    // method means "no iterator". For Promise aggregators
    // (`Promise.{all,allSettled,any,race}`), the spec calls
    // GetIterator with no explicit method, so the receiver
    // must have a callable `@@iterator`; null/undefined is
    // a TypeError per the iterator-call step.
    if (iter_method_v.isUndefined() or iter_method_v.isNull()) {
        return throwTypeError(realm, "iterable's @@iterator is null or undefined");
    }
    const iter_method = heap_mod.valueAsFunction(iter_method_v) orelse return throwTypeError(realm, "iterable's @@iterator is not callable");
    const iter_outcome = interp.callJSFunction(realm.allocator, realm, iter_method, source_v, &.{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.NativeThrew,
    };
    const iter_v = switch (iter_outcome) {
        .value, .yielded => |v| v,
        .thrown => |ex| {
            realm.pending_exception = ex;
            return error.NativeThrew;
        },
    };
    const iter_obj = heap_mod.valueAsPlainObject(iter_v) orelse return throwTypeError(realm, "iterator: @@iterator did not return an object");
    const next_v = try getPropertyChain(realm, iter_obj, "next");
    const next_fn = heap_mod.valueAsFunction(next_v) orelse return throwTypeError(realm, "iterator: missing callable 'next'");
    return IteratorRecord{ .iter = iter_obj, .iter_v = iter_v, .next_fn = next_fn };
}

/// §7.4.6 IteratorStep — call `next()`, return null on done OR
/// the yielded value. Sets `rec.done` on done OR abrupt. Per
/// §7.4.7 IteratorComplete / IteratorValue, the `done` and
/// `value` reads go through ordinary [[Get]]; accessor
/// descriptors invoke their getters and an abrupt completion
/// from a getter propagates as a NativeThrew.
fn iteratorStep(realm: *Realm, rec: *IteratorRecord) NativeError!?Value {
    const interp = @import("../lantern/interpreter.zig");
    const result_outcome = interp.callJSFunction(realm.allocator, realm, rec.next_fn, rec.iter_v, &.{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            rec.done = true;
            return error.NativeThrew;
        },
    };
    const result = switch (result_outcome) {
        .value, .yielded => |v| v,
        .thrown => |ex| {
            rec.done = true;
            realm.pending_exception = ex;
            return error.NativeThrew;
        },
    };
    const result_obj = heap_mod.valueAsPlainObject(result) orelse {
        rec.done = true;
        return throwTypeError(realm, "iterator next() did not return an object");
    };
    const arr_helpers = @import("array.zig");
    const done_v = intrinsics.getPropertyChain(realm, result_obj, "done") catch |err| {
        rec.done = true;
        return err;
    };
    if (arr_helpers.toBoolean(done_v)) {
        rec.done = true;
        return null;
    }
    return intrinsics.getPropertyChain(realm, result_obj, "value") catch |err| {
        rec.done = true;
        return err;
    };
}

/// §7.4.10 IteratorClose — invoke `iter.return()` if present.
/// `inner_completion` is the abrupt that we're closing on top
/// of; preserves the original throw if `return` itself throws
/// (per spec, except `return`'s throw replaces normal completion).
/// Caller has already pulled the abrupt into `realm.pending_exception`.
fn iteratorClose(realm: *Realm, rec: *IteratorRecord) void {
    if (rec.done) return;
    rec.done = true;
    const interp = @import("../lantern/interpreter.zig");
    const ret_v = getPropertyChain(realm, rec.iter, "return") catch return;
    const ret_fn = heap_mod.valueAsFunction(ret_v) orelse return;
    const outcome = interp.callJSFunction(realm.allocator, realm, ret_fn, rec.iter_v, &.{}) catch return;
    // Abrupt from `return` is suppressed when we're already
    // unwinding an abrupt completion (which we always are here —
    // close is only called on early exit). The pre-existing
    // `pending_exception` is what propagates.
    _ = outcome;
}

/// Collect every value an iterable yields into a list, with no
/// per-item processing. Used by aggregators that only need to
/// drain (`Promise.allSettled`, etc.) — but **prefer** the
/// `collectAndProcess` shape below when the per-item step can
/// throw, so iterator-close fires on abrupt.
fn collectIterable(realm: *Realm, source_v: Value) NativeError!std.ArrayList(Value) {
    var list: std.ArrayList(Value) = .empty;
    errdefer list.deinit(realm.allocator);

    const obj = heap_mod.valueAsPlainObject(source_v) orelse {
        return throwTypeError(realm, "Promise aggregator requires an iterable");
    };

    if (try iteratorOpen(realm, source_v)) |rec_in| {
        var rec = rec_in;
        // Root the iterator object + `next` method, and every value
        // collected so far, across each `iteratorStep` re-entry —
        // `list` is a native ArrayList the GC does not scan, so a
        // young value already appended would be swept by the next
        // step's allocations under aggressive GC.
        const it_sc = realm.heap.openScope() catch return error.OutOfMemory;
        defer it_sc.close();
        it_sc.push(rec.iter_v) catch return error.OutOfMemory;
        it_sc.push(heap_mod.taggedFunction(rec.next_fn)) catch return error.OutOfMemory;
        const max_iter: usize = 1 << 24;
        var step: usize = 0;
        while (step < max_iter) : (step += 1) {
            const v = iteratorStep(realm, &rec) catch |err| {
                // Iterator close not needed: rec.done is set by step
                // already on an abrupt completion or normal end.
                return err;
            } orelse break;
            try list.append(realm.allocator, v);
            it_sc.push(v) catch return error.OutOfMemory;
        }
        return list;
    }

    // §7.4.2 GetIterator — when there's no callable @@iterator
    // method, the spec calls `Call(undefined, …)` which throws
    // TypeError. The Promise aggregators surface this as a
    // rejection (IfAbruptRejectPromise). No silent fallback to
    // an array-like length walk.
    _ = obj;
    return throwTypeError(realm, "iterable is not iterable");
}

/// §27.2.4.1.2 / §27.2.4.4.1 / etc. — Promise aggregator main
/// loop. Walks the iterable, looking up `constructor.resolve` per
/// item and calling it; the result is forwarded to `process`. If
/// `constructor.resolve` throws OR `process` returns a sentinel
/// short-circuit (race / any), IteratorClose fires before the
/// caller surfaces the abrupt. Without this loop the `Promise.resolve`
/// override that test262 fixtures install never gets a chance to
/// throw, so the iterator (often poisoned to never-finish) burns
/// to the 16M cap.
/// §10.1.8.1 OrdinaryGet variant for a JSFunction receiver. Fires
/// own accessor getters (`Object.defineProperty(Promise, "resolve",
/// { get(){} })`), falls back to the data-bag, then walks the
/// prototype chain like `JSFunction.get`. Used by aggregators
/// that must observe user-overridden `Promise.resolve` per spec.
fn ctorGetMember(realm: *Realm, ctor: *JSFunction, key: []const u8) NativeError!Value {
    if (ctor.accessors.get(key)) |acc| {
        if (acc.getter) |getter| {
            const interp = @import("../lantern/interpreter.zig");
            const outcome = interp.callJSFunction(realm.allocator, realm, getter, heap_mod.taggedFunction(ctor), &.{}) catch |err| switch (err) {
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
    return ctor.get(key);
}

const IterStepAction = enum { continue_, short_circuit };
fn iterateAggregator(
    realm: *Realm,
    ctor: *JSFunction,
    source_v: Value,
    ctx: *anyopaque,
    process: *const fn (ctx: *anyopaque, realm: *Realm, ctor: *JSFunction, idx: usize, resolved: Value) NativeError!IterStepAction,
) NativeError!void {
    const interp = @import("../lantern/interpreter.zig");
    // §7.4.2 GetIterator is delegated to `iteratorOpen` below;
    // it ToObject-coerces primitive sources (so `Promise.any("")`
    // sees `String.prototype[@@iterator]`) and throws TypeError
    // for null / undefined.

    // §27.2.4.1.1 GetPromiseResolve — `Get(promiseConstructor, "resolve")`
    // runs ONCE before the loop. Fixtures count the resolve
    // getter calls and assert it fires exactly once per
    // `Promise.all(iter)` invocation; the per-element lookup is
    // a spec bug.
    const resolve_v = ctorGetMember(realm, ctor, "resolve") catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.NativeThrew,
    };
    const resolve_fn = heap_mod.valueAsFunction(resolve_v) orelse return throwTypeError(realm, "Promise aggregator: resolve is not a function");

    // Root the iterator object + its `next` method AND the once-read
    // `resolve` function for the whole walk. `iteratorStep`, the
    // per-item `resolve` call, and `process` all re-enter JS and can
    // GC; each of these is reachable only through a native record, so
    // without rooting a collection sweeps it and a later dereference
    // (`iteratorClose`, the next `iteratorStep`, or the next
    // `resolve` call) reads freed memory. `resolve` especially: a
    // `get resolve() { return function(){…} }` returns a fresh
    // function reachable through nothing, yet it is the callee on
    // every iteration — root it BEFORE `iteratorOpen`, which itself
    // re-enters JS (via @@iterator) and can GC.
    const it_sc = realm.heap.openScope() catch return error.OutOfMemory;
    defer it_sc.close();
    it_sc.push(resolve_v) catch return error.OutOfMemory;

    // `iteratorOpen` always returns a record or throws — no
    // array-like fallback (spec §7.4.2 only allows GetIterator).
    const rec_in = (try iteratorOpen(realm, source_v)) orelse unreachable;
    var rec = rec_in;
    it_sc.push(rec.iter_v) catch return error.OutOfMemory;
    it_sc.push(heap_mod.taggedFunction(rec.next_fn)) catch return error.OutOfMemory;
    const max_iter: usize = 1 << 24;
    var idx: usize = 0;
    while (idx < max_iter) : (idx += 1) {
        const next_v = iteratorStep(realm, &rec) catch |err| {
            // Step itself flagged abrupt; close is not our job
            // here (rec.done is true).
            return err;
        } orelse return;

        // Root the yielded value and (below) the resolved Promise
        // across the `resolve` call and `process` — both re-enter
        // JS and allocate (`process` builds the per-element resolve/
        // reject closures), and these are bare natives the GC can't
        // otherwise see. Per-iteration scope so the roots don't
        // accumulate across a long iterable.
        const step_sc = realm.heap.openScope() catch return error.OutOfMemory;
        defer step_sc.close();
        step_sc.push(next_v) catch return error.OutOfMemory;

        const r_outcome = interp.callJSFunction(realm.allocator, realm, resolve_fn, heap_mod.taggedFunction(ctor), &.{next_v}) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                iteratorClose(realm, &rec);
                return error.NativeThrew;
            },
        };
        const resolved = switch (r_outcome) {
            .value, .yielded => |v| v,
            .thrown => |ex| {
                iteratorClose(realm, &rec);
                realm.pending_exception = ex;
                return error.NativeThrew;
            },
        };
        step_sc.push(resolved) catch return error.OutOfMemory;

        const action = process(ctx, realm, ctor, idx, resolved) catch |err| {
            iteratorClose(realm, &rec);
            return err;
        };
        if (action == .short_circuit) {
            iteratorClose(realm, &rec);
            return;
        }
    }
}

/// Convert a synchronously-thrown error inside an aggregator into
/// a rejected promise. §27.2.4.1.1 step 6 (the `IfAbruptRejectPromise`
/// macro): when iterator setup fails, surface it as a rejection of
/// the result Promise rather than as a JS-visible throw.
fn aggregatorRejectFromPending(realm: *Realm, ctor: *JSFunction) Value {
    const ex = realm.pending_exception orelse Value.undefined_;
    realm.pending_exception = null;
    return allocatePromiseFor(realm, ctor, .rejected, ex) catch ex;
}

/// Resolve an aggregator input value to a Cynic-tagged Promise.
/// §27.2.4.1.2 step h — "Let nextPromise be Invoke(C, "resolve", «
/// nextValue »)". The aggregator family (`all`, `allSettled`,
/// `race`, `any`) doesn't actually look at user values directly;
/// it pushes them through `Promise.resolve(C, x)` so a thenable
/// gets unwrapped via `.then` and a real Promise rides through
/// unchanged.
///
/// Cynic settles synchronously, so by the time we return the
/// resulting Promise is either fulfilled, rejected, or still
/// pending (the thenable's `.then` deferred the call). Pending
/// inputs from a real thenable will never settle by the time the
/// aggregator wraps up — that's a lossy fast-track, but it's
/// what Cynic's sync-resolution model can promise. The dominant
/// fixture pattern (`{then(r){r(v)}}`-style synchronous
/// thenables) settles before we read the state.
fn resolveInputAsPromise(realm: *Realm, ctor: *JSFunction, v: Value) NativeError!Value {
    // Already a Cynic-tagged Promise of the right ctor — pass through.
    if (heap_mod.valueAsPlainObject(v)) |obj| {
        if (promiseStateOf(v) != .none) {
            const c_v = obj.get("constructor");
            if (heap_mod.valueAsFunction(c_v)) |c| {
                if (c == ctor) return v;
            }
        }
    }

    // Non-promise / cross-ctor: invoke `.then` if it has one,
    // otherwise treat as `Promise.resolve(v)`.
    if (heap_mod.valueAsPlainObject(v)) |obj| {
        const then_v = try getPropertyChain(realm, obj, "then");
        if (heap_mod.valueAsFunction(then_v)) |then_fn| {
            // Allocate a fresh pending Promise and pass bound
            // resolve/reject closures into the thenable's `.then`.
            const target_v = allocatePromiseFor(realm, ctor, .pending, Value.undefined_) catch return error.OutOfMemory;

            // §27.2.1.3 Resolve/Reject Functions — anonymous, non-ctor.
            const resolve_impl = realm.heap.allocateFunctionNative(realm, promiseResolveImpl, 1, "") catch return error.OutOfMemory;
            resolve_impl.proto = realm.intrinsics.function_prototype;
            resolve_impl.has_construct = false;
            const resolve_fn = realm.heap.allocateFunctionNative(realm, boundResolveTrampoline, 1, "") catch return error.OutOfMemory;
            resolve_fn.proto = realm.intrinsics.function_prototype;
            resolve_fn.has_construct = false;
            realm.heap.setBoundTarget(resolve_fn, resolve_impl);
            realm.heap.setBoundThis(resolve_fn, target_v);

            const reject_impl = realm.heap.allocateFunctionNative(realm, promiseRejectImpl, 1, "") catch return error.OutOfMemory;
            reject_impl.proto = realm.intrinsics.function_prototype;
            reject_impl.has_construct = false;
            const reject_fn = realm.heap.allocateFunctionNative(realm, boundResolveTrampoline, 1, "") catch return error.OutOfMemory;
            reject_fn.proto = realm.intrinsics.function_prototype;
            reject_fn.has_construct = false;
            realm.heap.setBoundTarget(reject_fn, reject_impl);
            realm.heap.setBoundThis(reject_fn, target_v);

            const interp = @import("../lantern/interpreter.zig");
            const then_args = [_]Value{ heap_mod.taggedFunction(resolve_fn), heap_mod.taggedFunction(reject_fn) };
            const outcome = interp.callJSFunction(realm.allocator, realm, then_fn, v, &then_args) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return error.NativeThrew,
            };
            switch (outcome) {
                .value, .yielded => {},
                .thrown => |ex| {
                    // §25.6.1.3.1 — thenable's `then` throwing
                    // causes the wrapping Promise to reject.
                    const target = heap_mod.valueAsPlainObject(target_v).?;
                    settlePromise(realm, target, .rejected, ex) catch return error.OutOfMemory;
                },
            }
            return target_v;
        }
    }
    return allocatePromiseFor(realm, ctor, .fulfilled, v) catch return error.OutOfMemory;
}

/// Aggregator kind tag baked into the shared state object so a
/// single set of element-closure natives covers all three.
const AggKind = enum(i32) { all = 0, all_settled = 1, any = 2 };

const k_kind = "__cynic_agg_kind__";
const k_remaining = "__cynic_agg_remaining__";
const k_values = "__cynic_agg_values__";
const k_cap_resolve = "__cynic_agg_cap_resolve__";
const k_cap_reject = "__cynic_agg_cap_reject__";
const k_fulfilled_str = "__cynic_agg_fulfilled_str__";
const k_rejected_str = "__cynic_agg_rejected_str__";
const k_elem_state = "__cynic_elem_state__";
const k_elem_index = "__cynic_elem_index__";
const k_elem_called = "__cynic_elem_called__";

fn allocAggState(realm: *Realm, kind: AggKind, cap: PromiseCapability, values: *JSObject) NativeError!*JSObject {
    const st = realm.heap.allocateObject() catch return error.OutOfMemory;
    realm.heap.setObjectPrototype(st, realm.intrinsics.object_prototype);
    st.set(realm.allocator, k_kind, Value.fromInt32(@intFromEnum(kind))) catch return error.OutOfMemory;
    // Spec starts `remainingElementsCount` at 1 to handle the
    // synchronous-iteration case (decremented once after the
    // loop ends, plus once per element resolution).
    st.set(realm.allocator, k_remaining, Value.fromInt32(1)) catch return error.OutOfMemory;
    st.set(realm.allocator, k_values, heap_mod.taggedObject(values)) catch return error.OutOfMemory;
    st.set(realm.allocator, k_cap_resolve, heap_mod.taggedFunction(cap.resolve)) catch return error.OutOfMemory;
    st.set(realm.allocator, k_cap_reject, heap_mod.taggedFunction(cap.reject)) catch return error.OutOfMemory;
    if (kind == .all_settled) {
        const fulfilled = realm.heap.allocateString("fulfilled") catch return error.OutOfMemory;
        const rejected = realm.heap.allocateString("rejected") catch return error.OutOfMemory;
        st.set(realm.allocator, k_fulfilled_str, Value.fromString(fulfilled)) catch return error.OutOfMemory;
        st.set(realm.allocator, k_rejected_str, Value.fromString(rejected)) catch return error.OutOfMemory;
    }
    return st;
}

/// Allocate the per-item resolve/reject closure pair. Each is a
/// bound function whose `bound_this` is a fresh wrapper carrying
/// `(state, index, alreadyCalled)` so the shared element impl
/// can read the wrapper out of `this_value`.
fn allocElementClosures(realm: *Realm, sc: *heap_mod.HandleScope, state: *JSObject, idx: u32) NativeError!struct { resolve: *JSFunction, reject: *JSFunction } {
    const wrapper = realm.heap.allocateObject() catch return error.OutOfMemory;
    realm.heap.setObjectPrototype(wrapper, realm.intrinsics.object_prototype);
    // Root the wrapper + each closure as it is allocated. Every
    // `allocateFunctionNative` below is a GC point, and until a
    // closure lands in a microtask's reaction_handler (via the
    // caller's `.then`) it is reachable only through unrooted native
    // locals — without `sc` a mid-allocation sweep frees an earlier
    // one and the later `.then` enqueues a dangling handler. The
    // caller keeps `sc` open across `invokeThenWithClosures`.
    sc.push(heap_mod.taggedObject(wrapper)) catch return error.OutOfMemory;
    wrapper.set(realm.allocator, k_elem_state, heap_mod.taggedObject(state)) catch return error.OutOfMemory;
    wrapper.set(realm.allocator, k_elem_index, Value.fromInt32(@intCast(idx))) catch return error.OutOfMemory;
    wrapper.set(realm.allocator, k_elem_called, Value.false_) catch return error.OutOfMemory;

    // §27.2.4.1.{Resolve,Reject} Element Functions — anonymous,
    // length 1, non-constructor.
    const resolve_impl = realm.heap.allocateFunctionNative(realm, aggResolveElement, 1, "") catch return error.OutOfMemory;
    resolve_impl.proto = realm.intrinsics.function_prototype;
    resolve_impl.has_construct = false;
    sc.push(heap_mod.taggedFunction(resolve_impl)) catch return error.OutOfMemory;
    const resolve_fn = realm.heap.allocateFunctionNative(realm, boundResolveTrampoline, 1, "") catch return error.OutOfMemory;
    resolve_fn.proto = realm.intrinsics.function_prototype;
    resolve_fn.has_construct = false;
    sc.push(heap_mod.taggedFunction(resolve_fn)) catch return error.OutOfMemory;
    realm.heap.setBoundTarget(resolve_fn, resolve_impl);
    realm.heap.setBoundThis(resolve_fn, heap_mod.taggedObject(wrapper));

    const reject_impl = realm.heap.allocateFunctionNative(realm, aggRejectElement, 1, "") catch return error.OutOfMemory;
    reject_impl.proto = realm.intrinsics.function_prototype;
    reject_impl.has_construct = false;
    sc.push(heap_mod.taggedFunction(reject_impl)) catch return error.OutOfMemory;
    const reject_fn = realm.heap.allocateFunctionNative(realm, boundResolveTrampoline, 1, "") catch return error.OutOfMemory;
    reject_fn.proto = realm.intrinsics.function_prototype;
    reject_fn.has_construct = false;
    sc.push(heap_mod.taggedFunction(reject_fn)) catch return error.OutOfMemory;
    realm.heap.setBoundTarget(reject_fn, reject_impl);
    realm.heap.setBoundThis(reject_fn, heap_mod.taggedObject(wrapper));

    return .{ .resolve = resolve_fn, .reject = reject_fn };
}

/// §27.2.4.1.2 / §27.2.4.2.1 / §27.2.4.3.1 — element resolve.
/// The per-item closure stores its outcome into the state's
/// values array (at `index`), decrements the remaining count,
/// and settles the cap when the count hits zero. `alreadyCalled`
/// guards against double-firing.
fn aggResolveElement(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const wrapper = heap_mod.valueAsPlainObject(this_value) orelse return Value.undefined_;
    if (toBoolFlag(wrapper.get(k_elem_called))) return Value.undefined_;
    wrapper.set(realm.allocator, k_elem_called, Value.true_) catch return error.OutOfMemory;
    const state = heap_mod.valueAsPlainObject(wrapper.get(k_elem_state)) orelse return Value.undefined_;
    const idx: u32 = @intCast(@max(0, wrapper.get(k_elem_index).asInt32()));
    const value = if (args.len > 0) args[0] else Value.undefined_;
    const kind: AggKind = @enumFromInt(state.get(k_kind).asInt32());

    const values = heap_mod.valueAsPlainObject(state.get(k_values)) orelse return Value.undefined_;

    switch (kind) {
        .all => {
            try setIndexedOnArray(realm, values, idx, value);
        },
        .all_settled => {
            const entry = try buildAllSettledEntry(realm, state, .fulfilled, value);
            try setIndexedOnArray(realm, values, idx, heap_mod.taggedObject(entry));
        },
        .any => {
            // First fulfillment wins — call cap.resolve(value)
            // through the standard interpreter path. Subsequent
            // resolves are silently discarded (cap settle is
            // idempotent; their `alreadyCalled` flags also
            // remain set so reject-element can't fire either).
            return invokeCapResolve(realm, state, value);
        },
    }
    return decrementRemaining(realm, state);
}

/// §27.2.4.1.2 / §27.2.4.2.1 / §27.2.4.3.1 — element reject.
fn aggRejectElement(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const wrapper = heap_mod.valueAsPlainObject(this_value) orelse return Value.undefined_;
    if (toBoolFlag(wrapper.get(k_elem_called))) return Value.undefined_;
    wrapper.set(realm.allocator, k_elem_called, Value.true_) catch return error.OutOfMemory;
    const state = heap_mod.valueAsPlainObject(wrapper.get(k_elem_state)) orelse return Value.undefined_;
    const idx: u32 = @intCast(@max(0, wrapper.get(k_elem_index).asInt32()));
    const reason = if (args.len > 0) args[0] else Value.undefined_;
    const kind: AggKind = @enumFromInt(state.get(k_kind).asInt32());

    switch (kind) {
        .all => {
            // First rejection rejects the whole result.
            return invokeCapReject(realm, state, reason);
        },
        .all_settled => {
            const values = heap_mod.valueAsPlainObject(state.get(k_values)) orelse return Value.undefined_;
            const entry = try buildAllSettledEntry(realm, state, .rejected, reason);
            try setIndexedOnArray(realm, values, idx, heap_mod.taggedObject(entry));
            return decrementRemaining(realm, state);
        },
        .any => {
            // Record reason; if all rejected, reject with
            // AggregateError(reasons).
            const errors = heap_mod.valueAsPlainObject(state.get(k_values)) orelse return Value.undefined_;
            try setIndexedOnArray(realm, errors, idx, reason);
            return decrementRemaining(realm, state);
        },
    }
}

fn buildAllSettledEntry(realm: *Realm, state: *JSObject, settle_kind: enum { fulfilled, rejected }, payload: Value) NativeError!*JSObject {
    const entry = realm.heap.allocateObject() catch return error.OutOfMemory;
    realm.heap.setObjectPrototype(entry, realm.intrinsics.object_prototype);
    const status = state.get(if (settle_kind == .fulfilled) k_fulfilled_str else k_rejected_str);
    const slot = if (settle_kind == .fulfilled) "value" else "reason";
    entry.set(realm.allocator, "status", status) catch return error.OutOfMemory;
    entry.set(realm.allocator, slot, payload) catch return error.OutOfMemory;
    return entry;
}

/// `decrementRemaining` decrements the state's counter and, when
/// it hits zero, fires the cap's resolve with the appropriate
/// payload depending on the aggregator kind.
fn decrementRemaining(realm: *Realm, state: *JSObject) NativeError!Value {
    const cur = state.get(k_remaining).asInt32();
    const next = cur - 1;
    state.set(realm.allocator, k_remaining, Value.fromInt32(next)) catch return error.OutOfMemory;
    if (next != 0) return Value.undefined_;
    const kind: AggKind = @enumFromInt(state.get(k_kind).asInt32());
    const values_v = state.get(k_values);
    switch (kind) {
        .all, .all_settled => return invokeCapResolve(realm, state, values_v),
        .any => {
            // Every input rejected → AggregateError(errors).
            const reasons = heap_mod.valueAsPlainObject(values_v) orelse return Value.undefined_;
            const agg_proto = realm.intrinsics.aggregate_error_prototype orelse realm.intrinsics.error_prototype.?;
            const agg = realm.heap.allocateObject() catch return error.OutOfMemory;
            realm.heap.setObjectPrototype(agg, agg_proto);
            agg.setWithFlags(realm.allocator, "errors", heap_mod.taggedObject(reasons), .{
                .writable = true,
                .enumerable = false,
                .configurable = true,
            }) catch return error.OutOfMemory;
            const msg_str = realm.heap.allocateString("All promises were rejected") catch return error.OutOfMemory;
            agg.set(realm.allocator, "message", Value.fromString(msg_str)) catch return error.OutOfMemory;
            return invokeCapReject(realm, state, heap_mod.taggedObject(agg));
        },
    }
}

fn invokeCapResolve(realm: *Realm, state: *JSObject, value: Value) NativeError!Value {
    const interp = @import("../lantern/interpreter.zig");
    const fn_obj = heap_mod.valueAsFunction(state.get(k_cap_resolve)) orelse return Value.undefined_;
    const outcome = interp.callJSFunction(realm.allocator, realm, fn_obj, Value.undefined_, &.{value}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.NativeThrew,
    };
    switch (outcome) {
        .value, .yielded => return Value.undefined_,
        .thrown => |ex| {
            realm.pending_exception = ex;
            return error.NativeThrew;
        },
    }
}

fn invokeCapReject(realm: *Realm, state: *JSObject, reason: Value) NativeError!Value {
    const interp = @import("../lantern/interpreter.zig");
    const fn_obj = heap_mod.valueAsFunction(state.get(k_cap_reject)) orelse return Value.undefined_;
    const outcome = interp.callJSFunction(realm.allocator, realm, fn_obj, Value.undefined_, &.{reason}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.NativeThrew,
    };
    switch (outcome) {
        .value, .yielded => return Value.undefined_,
        .thrown => |ex| {
            realm.pending_exception = ex;
            return error.NativeThrew;
        },
    }
}

fn setIndexedOnArray(realm: *Realm, arr: *JSObject, idx: u32, v: Value) NativeError!void {
    // `arr` is an aggregator results array (`Promise.all` values,
    // `allSettled` entries, `any` errors) that survives across the
    // whole walk and is promoted to mature. Two GC hazards under
    // aggressive collection:
    //   (1) the index-string allocation below is a GC point that
    //       would sweep a young `v` before it lands — root it;
    //   (2) storing a young `v` into the mature `arr` via the raw
    //       `JSObject.set` (no barrier) is an un-remembered
    //       mature→young edge the next minor GC sweeps (the gc1
    //       remembered-set verifier trips on exactly this).
    const sc = realm.heap.openScope() catch return error.OutOfMemory;
    defer sc.close();
    sc.push(v) catch return error.OutOfMemory;
    var ibuf: [24]u8 = undefined;
    const islice = std.fmt.bufPrint(&ibuf, "{d}", .{idx}) catch unreachable;
    const owned = realm.heap.allocateString(islice) catch return error.OutOfMemory;
    realm.heap.writeBarrier(.{ .object = arr }, v);
    arr.set(realm.allocator, owned.flatBytes(), v) catch return error.OutOfMemory;
}

fn toBoolFlag(v: Value) bool {
    if (v.isBool()) return v.asBool();
    return false;
}

const AggIterCtx = struct {
    state: *JSObject,
    cap: PromiseCapability,
};
fn aggregatorAllProcess(ctx_ptr: *anyopaque, realm: *Realm, ctor: *JSFunction, idx: usize, resolved: Value) NativeError!IterStepAction {
    _ = ctor;
    const ctx: *AggIterCtx = @ptrCast(@alignCast(ctx_ptr));
    // §27.2.4.1.2 step 8.j-l — append `undefined` to values,
    // bump remaining, then `Invoke(nextPromise, "then",
    // « resolveElement, resultCapability.[[Reject]] »)`. The
    // element resolve closure owns per-item index + state via
    // its bound_this wrapper. The reject argument is the shared
    // `resultCapability.[[Reject]]` — every element passes the
    // same function (§27.2.4.1.2 step 8.k) so a thenable that
    // inspects its second argument observes one identity across
    // every input. Promise.allSettled differs here (§27.2.4.2.1
    // step 8.x — `rejectElement` is freshly allocated per item,
    // sharing the `alreadyCalled` slot with `resolveElement`),
    // handled via `aggregatorAllSettledProcess` below.
    const values = heap_mod.valueAsPlainObject(ctx.state.get(k_values)) orelse return .continue_;
    try setIndexedOnArray(realm, values, @intCast(idx), Value.undefined_);
    setLength(realm, values, @intCast(@as(u32, @intCast(idx + 1)))) catch return error.OutOfMemory;
    const cur = ctx.state.get(k_remaining).asInt32();
    ctx.state.set(realm.allocator, k_remaining, Value.fromInt32(cur + 1)) catch return error.OutOfMemory;
    // Keep the element closures rooted across `.then` (which allocates
    // a capability before enqueuing the reaction); markRoots adopts
    // them once the reaction lands in the microtask queue.
    const closures_sc = realm.heap.openScope() catch return error.OutOfMemory;
    defer closures_sc.close();
    const closures = try allocElementClosures(realm, closures_sc, ctx.state, @intCast(idx));
    return invokeThenWithClosures(realm, resolved, closures.resolve, ctx.cap.reject);
}

fn aggregatorAllSettledProcess(ctx_ptr: *anyopaque, realm: *Realm, ctor: *JSFunction, idx: usize, resolved: Value) NativeError!IterStepAction {
    _ = ctor;
    const ctx: *AggIterCtx = @ptrCast(@alignCast(ctx_ptr));
    // §27.2.4.2.1 PerformPromiseAllSettled step 8 — both element
    // closures are per-item and SHARE the `alreadyCalled` slot via
    // the wrapper passed as `bound_this` to both. A thenable that
    // calls `onResolved()` then `onRejected()` (or vice versa) sees
    // the second call no-op.
    const values = heap_mod.valueAsPlainObject(ctx.state.get(k_values)) orelse return .continue_;
    try setIndexedOnArray(realm, values, @intCast(idx), Value.undefined_);
    setLength(realm, values, @intCast(@as(u32, @intCast(idx + 1)))) catch return error.OutOfMemory;
    const cur = ctx.state.get(k_remaining).asInt32();
    ctx.state.set(realm.allocator, k_remaining, Value.fromInt32(cur + 1)) catch return error.OutOfMemory;
    const closures_sc = realm.heap.openScope() catch return error.OutOfMemory;
    defer closures_sc.close();
    const closures = try allocElementClosures(realm, closures_sc, ctx.state, @intCast(idx));
    return invokeThenWithClosures(realm, resolved, closures.resolve, closures.reject);
}

fn aggregatorAnyProcess(ctx_ptr: *anyopaque, realm: *Realm, ctor: *JSFunction, idx: usize, resolved: Value) NativeError!IterStepAction {
    _ = ctor;
    const ctx: *AggIterCtx = @ptrCast(@alignCast(ctx_ptr));
    const errors = heap_mod.valueAsPlainObject(ctx.state.get(k_values)) orelse return .continue_;
    try setIndexedOnArray(realm, errors, @intCast(idx), Value.undefined_);
    setLength(realm, errors, @intCast(@as(u32, @intCast(idx + 1)))) catch return error.OutOfMemory;
    const cur = ctx.state.get(k_remaining).asInt32();
    ctx.state.set(realm.allocator, k_remaining, Value.fromInt32(cur + 1)) catch return error.OutOfMemory;
    const closures_sc = realm.heap.openScope() catch return error.OutOfMemory;
    defer closures_sc.close();
    const closures = try allocElementClosures(realm, closures_sc, ctx.state, @intCast(idx));
    // §27.2.4.3.1 PerformPromiseAny step 8.j —
    //   Perform ? Invoke(nextPromise, "then",
    //     « resultCapability.[[Resolve]], onRejected »).
    // Unlike Promise.all / allSettled, the `resolve` argument is
    // the bare capability resolve — NOT a per-element closure
    // with an alreadyCalled guard. A custom Constructor (test262
    // built-ins/Promise/any/resolve-from-same-thenable.js) whose
    // executor calls `resolve(v)` multiple times must observe each
    // call; a per-element closure would no-op after the first.
    // `onRejected` IS per-element so we can record the reason
    // into the errors list and decide when to AggregateError.
    return invokeThenWithClosures(realm, resolved, ctx.cap.resolve, closures.reject);
}

fn invokeThenWithClosures(realm: *Realm, resolved: Value, resolve_fn: *JSFunction, reject_fn: *JSFunction) NativeError!IterStepAction {
    const interp = @import("../lantern/interpreter.zig");
    const obj = heap_mod.valueAsPlainObject(resolved) orelse return throwTypeError(realm, "Promise aggregator: resolve did not return an object");
    const then_v = try getPropertyChain(realm, obj, "then");
    const then_fn = heap_mod.valueAsFunction(then_v) orelse return throwTypeError(realm, "Promise aggregator: 'then' is not callable");
    const args = [_]Value{ heap_mod.taggedFunction(resolve_fn), heap_mod.taggedFunction(reject_fn) };
    const outcome = interp.callJSFunction(realm.allocator, realm, then_fn, resolved, &args) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.NativeThrew,
    };
    switch (outcome) {
        .value, .yielded => return .continue_,
        .thrown => |ex| {
            realm.pending_exception = ex;
            return error.NativeThrew;
        },
    }
}

fn promiseAll(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const ctor = try thisAsPromiseCtor(realm, this_value, "all");
    const cap = try newPromiseCapability(realm, ctor);
    const values = realm.heap.allocateObject() catch return error.OutOfMemory;
    realm.heap.setObjectPrototype(values, realm.intrinsics.array_prototype);
    values.markAsArrayExotic(realm.allocator) catch return error.OutOfMemory;
    const state = try allocAggState(realm, .all, cap, values);
    // `iterateAggregator` drives `resolveInputAsPromise` / `.then`
    // per input — both re-enter JS and can GC. Root `state` for the
    // whole walk; it holds the values/errors array and the
    // capability closures (and, through the resolve closure's bound
    // `this`, the result promise).
    const agg_scope = realm.heap.openScope() catch return error.OutOfMemory;
    defer agg_scope.close();
    agg_scope.push(heap_mod.taggedObject(state)) catch return error.OutOfMemory;
    var ctx = AggIterCtx{ .state = state, .cap = cap };
    iterateAggregator(realm, ctor, argOr(args, 0, Value.undefined_), &ctx, aggregatorAllProcess) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.NativeThrew => return aggregatorRejectThroughCap(realm, ctor, cap),
    };
    // §27.2.4.1 Promise.all step 8 — `If result is an abrupt
    // completion, then if iteratorRecord.[[Done]] is false, let
    // result be IteratorClose(iterator, result). IfAbruptReject-
    // Promise(result, promiseCapability).`
    //
    // The synchronous-"+1" decrement below can fire `cap.resolve`
    // (when every input settled synchronously) which may throw
    // (subclass executor's resolve closure threw at top level).
    // The iterator is already exhausted at this point — done is
    // true — so IteratorClose is suppressed; we just funnel the
    // abrupt completion through `cap.reject` per the macro.
    _ = decrementRemaining(realm, state) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.NativeThrew => return aggregatorRejectThroughCap(realm, ctor, cap),
    };
    return cap.promise;
}

/// Helpers binding the per-aggregator "resolve/reject through
/// capability OR fast-path" branches into one place. The
/// `null_cap` sentinel is used for the built-in `Promise`
/// constructor where no capability is required.
const NullCap = struct {};
const null_cap: ?PromiseCapability = null;

fn isBuiltinPromise(realm: *Realm, ctor: *JSFunction) bool {
    const builtin = heap_mod.valueAsFunction(realm.globals.get("Promise") orelse Value.undefined_);
    return builtin != null and ctor == builtin.?;
}

fn aggregatorSettleResolve(realm: *Realm, ctor: *JSFunction, cap: ?PromiseCapability, value: Value) NativeError!Value {
    if (cap) |c| return capabilityResolve(realm, c, value);
    return allocatePromiseFor(realm, ctor, .fulfilled, value) catch return error.OutOfMemory;
}

fn aggregatorSettleReject(realm: *Realm, ctor: *JSFunction, cap: ?PromiseCapability, reason: Value) NativeError!Value {
    if (cap) |c| return capabilityReject(realm, c, reason);
    return allocatePromiseFor(realm, ctor, .rejected, reason) catch return error.OutOfMemory;
}

fn aggregatorRejectThroughCap(realm: *Realm, ctor: *JSFunction, cap: ?PromiseCapability) NativeError!Value {
    const ex = realm.pending_exception orelse Value.undefined_;
    realm.pending_exception = null;
    if (cap) |c| return capabilityReject(realm, c, ex);
    return allocatePromiseFor(realm, ctor, .rejected, ex) catch return error.OutOfMemory;
}

/// §27.2.4.2.1 PerformPromiseAllSettled. Per-item callback —
/// every input contributes a `{status, value|reason}` entry,
/// even rejections. Pending inputs (a thenable that hasn't
/// settled by aggregator return) contribute `{status: "fulfilled",
/// value}` since Cynic's sync-resolution model can't observe a
/// later settlement.
const AllSettledCtx = struct {
    out: *JSObject,
    count: u32 = 0,
    fulfilled_str: *@import("../string.zig").JSString,
    rejected_str: *@import("../string.zig").JSString,
};
fn allSettledProcess(ctx_ptr: *anyopaque, realm: *Realm, ctor: *JSFunction, idx: usize, resolved: Value) NativeError!IterStepAction {
    _ = ctor;
    _ = idx;
    const ctx: *AllSettledCtx = @ptrCast(@alignCast(ctx_ptr));
    const entry = realm.heap.allocateObject() catch return error.OutOfMemory;
    realm.heap.setObjectPrototype(entry, realm.intrinsics.object_prototype);
    switch (promiseStateOf(resolved)) {
        .rejected => {
            entry.set(realm.allocator, "status", Value.fromString(ctx.rejected_str)) catch return error.OutOfMemory;
            entry.set(realm.allocator, "reason", promiseValueOf(resolved)) catch return error.OutOfMemory;
        },
        .fulfilled, .pending => {
            entry.set(realm.allocator, "status", Value.fromString(ctx.fulfilled_str)) catch return error.OutOfMemory;
            entry.set(realm.allocator, "value", promiseValueOf(resolved)) catch return error.OutOfMemory;
        },
        .none => {
            entry.set(realm.allocator, "status", Value.fromString(ctx.fulfilled_str)) catch return error.OutOfMemory;
            entry.set(realm.allocator, "value", resolved) catch return error.OutOfMemory;
        },
    }
    var ibuf: [24]u8 = undefined;
    const islice = std.fmt.bufPrint(&ibuf, "{d}", .{ctx.count}) catch unreachable;
    const owned = realm.heap.allocateString(islice) catch return error.OutOfMemory;
    ctx.out.set(realm.allocator, owned.flatBytes(), heap_mod.taggedObject(entry)) catch return error.OutOfMemory;
    ctx.count += 1;
    return .continue_;
}

fn promiseAllSettled(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const ctor = try thisAsPromiseCtor(realm, this_value, "allSettled");
    const cap = try newPromiseCapability(realm, ctor);
    const values = realm.heap.allocateObject() catch return error.OutOfMemory;
    realm.heap.setObjectPrototype(values, realm.intrinsics.array_prototype);
    values.markAsArrayExotic(realm.allocator) catch return error.OutOfMemory;
    const state = try allocAggState(realm, .all_settled, cap, values);
    // `iterateAggregator` drives `resolveInputAsPromise` / `.then`
    // per input — both re-enter JS and can GC. Root `state` for the
    // whole walk; it holds the values/errors array and the
    // capability closures (and, through the resolve closure's bound
    // `this`, the result promise).
    const agg_scope = realm.heap.openScope() catch return error.OutOfMemory;
    defer agg_scope.close();
    agg_scope.push(heap_mod.taggedObject(state)) catch return error.OutOfMemory;
    var ctx = AggIterCtx{ .state = state, .cap = cap };
    iterateAggregator(realm, ctor, argOr(args, 0, Value.undefined_), &ctx, aggregatorAllSettledProcess) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.NativeThrew => return aggregatorRejectThroughCap(realm, ctor, cap),
    };
    // §27.2.4.2 Promise.allSettled step 7 — same IteratorClose-
    // suppressed-on-done IfAbruptRejectPromise as Promise.all.
    // The synchronous-"+1" decrement may call `cap.resolve` which
    // can throw (e.g. a subclass that overrides the resolve
    // closure); funnel through `cap.reject`.
    _ = decrementRemaining(realm, state) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.NativeThrew => return aggregatorRejectThroughCap(realm, ctor, cap),
    };
    return cap.promise;
}

/// §27.2.4.4.1 PerformPromiseRace. Per spec step 4.f-g, each
/// resolved item's settlement is forwarded to the result
/// capability via `.then(cap.resolve, cap.reject)`. That's a
/// microtask schedule, NOT a synchronous settle — which preserves
/// the spec's interleaving with other `.then` reactions and lets
/// downstream `.then` chains observe the right order.
const RaceCtx = struct {
    cap: PromiseCapability,
};
fn raceProcess(ctx_ptr: *anyopaque, realm: *Realm, ctor: *JSFunction, idx: usize, resolved: Value) NativeError!IterStepAction {
    _ = ctor;
    _ = idx;
    const ctx: *RaceCtx = @ptrCast(@alignCast(ctx_ptr));
    // §27.2.4.4.1 step 4.g — `Invoke(nextPromise, "then",
    // « cap.resolve, cap.reject »)`. We must call the
    // user-observable `.then` method through `[[Get]]` so a
    // user override (test262 `invoke-then-error-close.js`
    // installs `promise.then = () => { throw }`) sees the call
    // and IteratorClose can fire on the abrupt.
    return invokeThenForward(realm, resolved, ctx.cap);
}

/// Shared helper for the aggregator microtask path: takes a
/// resolved item and forwards its settlement into the result
/// capability via `Invoke(item, "then", « cap.resolve,
/// cap.reject »)`. Honors user-defined `then` overrides per
/// §27.2.4.x step 4.g. On abrupt completion, sets
/// `realm.pending_exception` and returns `error.NativeThrew`
/// so the surrounding aggregator does IteratorClose.
fn invokeThenForward(realm: *Realm, resolved: Value, cap: PromiseCapability) NativeError!IterStepAction {
    const interp = @import("../lantern/interpreter.zig");
    const obj = heap_mod.valueAsPlainObject(resolved) orelse return throwTypeError(realm, "Promise aggregator: resolve did not return an object");
    const then_v = try getPropertyChain(realm, obj, "then");
    const then_fn = heap_mod.valueAsFunction(then_v) orelse return throwTypeError(realm, "Promise aggregator: 'then' is not callable");
    const then_args = [_]Value{ heap_mod.taggedFunction(cap.resolve), heap_mod.taggedFunction(cap.reject) };
    const outcome = interp.callJSFunction(realm.allocator, realm, then_fn, resolved, &then_args) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.NativeThrew,
    };
    switch (outcome) {
        .value, .yielded => return .continue_,
        .thrown => |ex| {
            realm.pending_exception = ex;
            return error.NativeThrew;
        },
    }
}

fn promiseRace(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const ctor = try thisAsPromiseCtor(realm, this_value, "race");
    // §27.2.4.4 step 2 — always go through NewPromiseCapability.
    // The cap.resolve / cap.reject closures are what we hand to
    // each `.then` call, so we need them populated even for the
    // built-in Promise constructor.
    const cap = try newPromiseCapability(realm, ctor);
    // Root the capability closures + result promise across the
    // walk. Unlike all / allSettled / any, race keeps no `state`
    // object — `cap` lives only in the native `RaceCtx`, which the
    // GC can't scan, so `iterateAggregator`'s re-entries would sweep
    // `cap.resolve` / `cap.reject` / `cap.promise` mid-iteration.
    const agg_scope = realm.heap.openScope() catch return error.OutOfMemory;
    defer agg_scope.close();
    agg_scope.push(heap_mod.taggedFunction(cap.resolve)) catch return error.OutOfMemory;
    agg_scope.push(heap_mod.taggedFunction(cap.reject)) catch return error.OutOfMemory;
    agg_scope.push(cap.promise) catch return error.OutOfMemory;
    var ctx = RaceCtx{ .cap = cap };
    iterateAggregator(realm, ctor, argOr(args, 0, Value.undefined_), &ctx, raceProcess) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.NativeThrew => return aggregatorRejectThroughCap(realm, ctor, cap),
    };
    return cap.promise;
}

fn promiseAny(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const ctor = try thisAsPromiseCtor(realm, this_value, "any");
    const cap = try newPromiseCapability(realm, ctor);
    const errors = realm.heap.allocateObject() catch return error.OutOfMemory;
    realm.heap.setObjectPrototype(errors, realm.intrinsics.array_prototype);
    errors.markAsArrayExotic(realm.allocator) catch return error.OutOfMemory;
    const state = try allocAggState(realm, .any, cap, errors);
    // `iterateAggregator` drives `resolveInputAsPromise` / `.then`
    // per input — both re-enter JS and can GC. Root `state` for the
    // whole walk; it holds the values/errors array and the
    // capability closures (and, through the resolve closure's bound
    // `this`, the result promise).
    const agg_scope = realm.heap.openScope() catch return error.OutOfMemory;
    defer agg_scope.close();
    agg_scope.push(heap_mod.taggedObject(state)) catch return error.OutOfMemory;
    var ctx = AggIterCtx{ .state = state, .cap = cap };
    iterateAggregator(realm, ctor, argOr(args, 0, Value.undefined_), &ctx, aggregatorAnyProcess) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.NativeThrew => return aggregatorRejectThroughCap(realm, ctor, cap),
    };
    // §27.2.4.3 Promise.any step 7 — same IfAbruptRejectPromise
    // shape: a synchronous final decrement that triggers the
    // AggregateError-build-and-`cap.reject` path can throw if
    // the user's cap.reject closure is poisoned. Funnel via
    // cap.reject so the macro semantics hold.
    _ = decrementRemaining(realm, state) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.NativeThrew => return aggregatorRejectThroughCap(realm, ctor, cap),
    };
    return cap.promise;
}

/// §27.2.4.5 Promise.try ( callbackfn, ...args ) — ES2025.
/// Invoke `callbackfn` synchronously with `args`; the returned
/// Promise is rejected with whatever the call throws (including
/// the TypeError raised when `callbackfn` isn't callable) and
/// fulfilled otherwise. If the callback already returns a
/// same-constructor Promise we forward it unchanged so chained
/// `.then` preserves identity.
fn promiseTry(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    // §27.2.4.7 Promise.try ( callbackfn, ...args ) — ES2025
    //   1. Let C be the this value.
    //   2. Let promiseCapability be ? NewPromiseCapability(C).
    //   3. Let status be Completion(Call(callbackfn, undefined, args)).
    //   4. If status is an abrupt completion, then
    //      a. Perform ? Call(promiseCapability.[[Reject]],
    //         undefined, « status.[[Value]] »).
    //   5. Else, Perform ? Call(promiseCapability.[[Resolve]],
    //      undefined, « status.[[Value]] »).
    //   6. Return promiseCapability.[[Promise]].
    //
    // Routing through the capability — rather than allocating a
    // built-in Promise directly — lets `Promise.try.call(Sub, fn)`
    // hand back an instance of `Sub` whose executor saw the real
    // resolve/reject pair, and lets a constructor that throws
    // synchronously propagate that abrupt out (ctx-ctor-throws).
    const ctor = try thisAsPromiseCtor(realm, this_value, "try");
    const cap = try newPromiseCapability(realm, ctor);
    // Root the capability triad across the callback re-entry below.
    // `cap` is a native struct the GC can't scan, and its freshly
    // allocated promise / resolve / reject have no other live
    // reference (the resolve/reject closures only point *back* at the
    // promise) — a GC during the user callback would sweep the whole
    // island, leaving capabilityResolve/Reject to call a freed function
    // ("value is not callable") and the returned promise dangling.
    const scope = realm.heap.openScope() catch return error.OutOfMemory;
    defer scope.close();
    scope.push(cap.promise) catch return error.OutOfMemory;
    scope.push(heap_mod.taggedFunction(cap.resolve)) catch return error.OutOfMemory;
    scope.push(heap_mod.taggedFunction(cap.reject)) catch return error.OutOfMemory;
    const callback = argOr(args, 0, Value.undefined_);
    const callback_fn = heap_mod.valueAsFunction(callback) orelse {
        const ex = intrinsics.newTypeError(realm, "Promise.try requires a function") catch return error.OutOfMemory;
        _ = try capabilityReject(realm, cap, ex);
        return cap.promise;
    };
    const rest_args: []const Value = if (args.len > 1) args[1..] else &[_]Value{};
    const interp = @import("../lantern/interpreter.zig");
    const outcome = interp.callJSFunction(realm.allocator, realm, callback_fn, Value.undefined_, rest_args) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.NativeThrew,
    };
    switch (outcome) {
        .value, .yielded => |v| {
            _ = try capabilityResolve(realm, cap, v);
        },
        .thrown => |ex| {
            _ = try capabilityReject(realm, cap, ex);
        },
    }
    return cap.promise;
}

/// §27.2.4.6 Promise.withResolvers ( ) — ES2025.
/// Returns `{ promise, resolve, reject }` where `resolve` and
/// `reject` settle the bundled `promise`. Mirrors the bound-fn
/// trampoline used by `new Promise(executor)` so settlement goes
/// through the same `promiseResolveImpl` / `promiseRejectImpl`
/// path.
fn promiseWithResolvers(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = args;
    // §27.2.4.6 step 1 — Let C be the this value.
    const ctor = try thisAsPromiseCtor(realm, this_value, "withResolvers");
    // §27.2.4.6 step 2 — Let promiseCapability be ? NewPromiseCapability(C).
    // Route through the shared helper rather than inlining a
    // %Promise%-only construction: NewPromiseCapability runs
    // Construct(C, «executor») and enforces §27.2.1.5 steps 7-8
    // (resolve/reject must be callable). A constructor that never
    // invokes its executor — e.g. `Promise.withResolvers.call(function(){})`
    // — leaves them undefined and must throw a TypeError; a Promise
    // subclass runs its real constructor through this path too.
    const cap = try newPromiseCapability(realm, ctor);
    // `cap` lives only in this native frame (the GC does not scan it),
    // so root the promise + resolving functions across the result-object
    // allocation and property writes below.
    const wr_sc = realm.heap.openScope() catch return error.OutOfMemory;
    defer wr_sc.close();
    wr_sc.push(cap.promise) catch return error.OutOfMemory;
    wr_sc.push(heap_mod.taggedFunction(cap.resolve)) catch return error.OutOfMemory;
    wr_sc.push(heap_mod.taggedFunction(cap.reject)) catch return error.OutOfMemory;

    // §27.2.4.6 steps 3-7 — wrap { promise, resolve, reject } in an
    // ordinary object created from %Object.prototype%.
    const obj = realm.heap.allocateObject() catch return error.OutOfMemory;
    wr_sc.push(heap_mod.taggedObject(obj)) catch return error.OutOfMemory;
    realm.heap.setObjectPrototype(obj, realm.intrinsics.object_prototype);
    obj.set(realm.allocator, "promise", cap.promise) catch return error.OutOfMemory;
    obj.set(realm.allocator, "resolve", heap_mod.taggedFunction(cap.resolve)) catch return error.OutOfMemory;
    obj.set(realm.allocator, "reject", heap_mod.taggedFunction(cap.reject)) catch return error.OutOfMemory;
    return heap_mod.taggedObject(obj);
}
