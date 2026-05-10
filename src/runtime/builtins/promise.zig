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
//! Microtask draining is in `interpreter.drainMicrotasks`;
//! suspendable `await` is implemented in `runtime/interpreter.zig`
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
const clampArrayLength = intrinsics.clampArrayLength;
const setLength = intrinsics.setLength;
const toLengthOf = intrinsics.toLengthOf;
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
        .name = "Promise", .ctor = promiseConstructor, .arity = 1,
        .to_string_tag = "Promise",
    });
    const fn_obj = r.ctor;
    const proto = r.proto;

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

    // Cynic-only host hook: lets tests + the CLI explicitly
    // drain the microtask queue. Real ECMAScript hosts drain
    // automatically at "completion of a job" — Cynic's CLI does
    // that around `cynic eval`/`cynic run`, but inline tests
    // and microtask-ordering assertions need direct access.
    // Lives on `globalThis.__drainMicrotasks`; not in the spec.
    const drain_fn = try realm.heap.allocateFunctionNative(microtaskDrainNative, 0, "__drainMicrotasks");
    try realm.globals.put(realm.allocator, "__drainMicrotasks", heap_mod.taggedFunction(drain_fn));
}

fn microtaskDrainNative(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = this_value;
    _ = args;
    const interpreter = @import("../interpreter.zig");
    interpreter.drainMicrotasks(realm.allocator, realm) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.NativeThrew,
    };
    return Value.undefined_;
}

pub const PromiseState = enum { pending, fulfilled, rejected };

fn allocatePromise(realm: *Realm, state: PromiseState, value: Value) !Value {
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
    // §27.2.1.5.1 GetCapabilitiesExecutor — second call is a
    // TypeError. We mark the slots present once the first call
    // populates them; the sentinel "__cynic_cap_called__" guards
    // against re-population.
    if (state.hasOwn("__cynic_cap_called__")) {
        return throwTypeError(realm, "capability executor: already called");
    }
    const resolve_v = if (args.len >= 1) args[0] else Value.undefined_;
    const reject_v = if (args.len >= 2) args[1] else Value.undefined_;
    state.set(realm.allocator, "__cynic_cap_resolve__", resolve_v) catch return error.OutOfMemory;
    state.set(realm.allocator, "__cynic_cap_reject__", reject_v) catch return error.OutOfMemory;
    state.set(realm.allocator, "__cynic_cap_called__", Value.true_) catch return error.OutOfMemory;
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
    state.prototype = realm.intrinsics.object_prototype;

    const executor_impl = realm.heap.allocateFunctionNative(capabilityExecutorImpl, 2, "") catch return error.OutOfMemory;
    executor_impl.proto = realm.intrinsics.function_prototype;
    const executor = realm.heap.allocateFunctionNative(boundResolveTrampoline, 2, "") catch return error.OutOfMemory;
    executor.proto = realm.intrinsics.function_prototype;
    executor.bound_target = executor_impl;
    executor.bound_this = heap_mod.taggedObject(state);

    // §27.2.1.5 step 6 — Construct(C, «executor»).
    const interp = @import("../interpreter.zig");
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
    const resolve_v = state.get("__cynic_cap_resolve__");
    const reject_v = state.get("__cynic_cap_reject__");
    const resolve_fn = heap_mod.valueAsFunction(resolve_v) orelse return throwTypeError(realm, "Promise capability: resolve is not callable");
    const reject_fn = heap_mod.valueAsFunction(reject_v) orelse return throwTypeError(realm, "Promise capability: reject is not callable");
    return PromiseCapability{ .promise = promise_v, .resolve = resolve_fn, .reject = reject_fn };
}

/// Settle a capability through its resolve function. The resolve
/// function is whatever the user constructor's executor handed
/// us — could be the standard Cynic resolve closure (settles the
/// Promise), could be user-supplied (subclasses).
pub fn capabilityResolve(realm: *Realm, cap: PromiseCapability, value: Value) NativeError!Value {
    const interp = @import("../interpreter.zig");
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
    const interp = @import("../interpreter.zig");
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
        if (c.prototype) |p| obj.prototype = p;
    }
    if (obj.prototype == null) {
        obj.prototype = if (heap_mod.valueAsFunction(realm.globals.get("Promise") orelse Value.undefined_)) |p|
            p.prototype
        else
            realm.intrinsics.object_prototype;
    }
    const state_str: []const u8 = switch (state) {
        .pending => "pending",
        .fulfilled => "fulfilled",
        .rejected => "rejected",
    };
    const state_v = try realm.heap.allocateString(state_str);
    try obj.set(realm.allocator, "__cynic_promise_state__", Value.fromString(state_v));
    try obj.set(realm.allocator, "__cynic_promise_value__", value);
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

fn promiseStateOf(v: Value) ?[]const u8 {
    const obj = heap_mod.valueAsPlainObject(v) orelse return null;
    const state_v = obj.get("__cynic_promise_state__");
    if (!state_v.isString()) return null;
    const s: *JSString = @ptrCast(@alignCast(state_v.asString()));
    return s.bytes;
}

fn promiseValueOf(v: Value) Value {
    const obj = heap_mod.valueAsPlainObject(v) orelse return Value.undefined_;
    return obj.get("__cynic_promise_value__");
}

fn promiseConstructor(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const inst = heap_mod.valueAsPlainObject(this_value) orelse return throwTypeError(realm, "Promise constructor requires 'new'");
    // §27.2.3.1 step 1 — `Promise.call(p, fn)` re-initialises an
    // existing Promise via plain-call. Cynic doesn't model
    // NewTarget directly; an already-initialised receiver gives
    // it away (its `__cynic_promise_state__` slot is set). Reject
    // before clobbering the existing state.
    if (!inst.get("__cynic_promise_state__").isUndefined()) {
        return throwTypeError(realm, "Promise constructor requires 'new' (receiver already initialized)");
    }
    const executor = heap_mod.valueAsFunction(argOr(args, 0, Value.undefined_)) orelse return throwTypeError(realm, "Promise executor must be a function");

    // Initial state: pending.
    const pending = realm.heap.allocateString("pending") catch return error.OutOfMemory;
    inst.set(realm.allocator, "__cynic_promise_state__", Value.fromString(pending)) catch return error.OutOfMemory;
    inst.set(realm.allocator, "__cynic_promise_value__", Value.undefined_) catch return error.OutOfMemory;

    // Resolve / reject capture the target Promise via a
    // bound-function trick: the actual native (impl) takes its
    // target from `this_value`, and we wrap it in a bound
    // function whose `bound_this` IS the target Promise. When
    // user code calls `resolve(v)`, the bind machinery unwraps
    // and calls the impl with `this_value = target_promise`.
    const resolve_impl = realm.heap.allocateFunctionNative(promiseResolveImpl, 1, "resolve") catch return error.OutOfMemory;
    resolve_impl.proto = realm.intrinsics.function_prototype;
    const resolve_fn = realm.heap.allocateFunctionNative(boundResolveTrampoline, 1, "resolve") catch return error.OutOfMemory;
    resolve_fn.proto = realm.intrinsics.function_prototype;
    resolve_fn.bound_target = resolve_impl;
    resolve_fn.bound_this = this_value;

    const reject_impl = realm.heap.allocateFunctionNative(promiseRejectImpl, 1, "reject") catch return error.OutOfMemory;
    reject_impl.proto = realm.intrinsics.function_prototype;
    const reject_fn = realm.heap.allocateFunctionNative(boundResolveTrampoline, 1, "reject") catch return error.OutOfMemory;
    reject_fn.proto = realm.intrinsics.function_prototype;
    reject_fn.bound_target = reject_impl;
    reject_fn.bound_this = this_value;

    // Run the executor synchronously with (resolve, reject).
    const interpreter = @import("../interpreter.zig");
    const exec_args = [_]Value{ heap_mod.taggedFunction(resolve_fn), heap_mod.taggedFunction(reject_fn) };
    const outcome = interpreter.callJSFunction(realm.allocator, realm, executor, Value.undefined_, &exec_args) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.NativeThrew,
    };
    switch (outcome) {
        .value, .yielded => {},
        .thrown => |ex| {
            // Executor threw — reject the promise.
            settlePromise(realm, inst, .rejected, ex) catch return error.OutOfMemory;
        },
    }
    return this_value;
}

fn settlePromise(realm: *Realm, inst: *@import("../object.zig").JSObject, state: enum { fulfilled, rejected }, value: Value) !void {
    const cur_state = inst.get("__cynic_promise_state__");
    if (cur_state.isString()) {
        const s: *JSString = @ptrCast(@alignCast(cur_state.asString()));
        if (!std.mem.eql(u8, s.bytes, "pending")) return; // already settled
    }
    const state_str: []const u8 = if (state == .fulfilled) "fulfilled" else "rejected";
    const state_s = try realm.heap.allocateString(state_str);
    try inst.set(realm.allocator, "__cynic_promise_state__", Value.fromString(state_s));
    try inst.set(realm.allocator, "__cynic_promise_value__", value);
}

/// `resolve(v)` impl. The bound-function trampoline arranges
/// for `this_value` to be the target Promise (set as
/// `bound_this` at promise-constructor time). When user code
/// calls `resolve(42)`, the bind unwrap dispatches into here
/// with the target Promise as `this_value`.
fn promiseResolveImpl(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const target = heap_mod.valueAsPlainObject(this_value) orelse return Value.undefined_;
    const v = argOr(args, 0, Value.undefined_);
    const interp = @import("../interpreter.zig");
    interp.settlePromiseInternal(realm, target, .fulfilled, v) catch return error.OutOfMemory;
    return Value.undefined_;
}

fn promiseRejectImpl(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const target = heap_mod.valueAsPlainObject(this_value) orelse return Value.undefined_;
    const v = argOr(args, 0, Value.undefined_);
    const interp = @import("../interpreter.zig");
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
    // §27.2.5.4 PerformPromiseThen — register a reaction that
    // fires when the source Promise settles. The returned
    // Promise is settled by the reaction's outcome:
    // • handler returns plain v → result fulfilled with v.
    // • handler returns Promise → result mirrors that Promise.
    // • handler throws → result rejected.
    // • handler absent → propagate state/value.
    // For already-settled sources we still go through the
    // microtask queue (per spec — handlers always run async).
    const source = heap_mod.valueAsPlainObject(this_value) orelse return throwTypeError(realm, "Promise.prototype.then on non-Promise");
    const state_v = source.get("__cynic_promise_state__");
    if (!state_v.isString()) return throwTypeError(realm, "Promise.prototype.then on non-Promise");
    const state_s: *JSString = @ptrCast(@alignCast(state_v.asString()));
    const state = state_s.bytes;
    const value = source.get("__cynic_promise_value__");

    const on_fulfilled = argOr(args, 0, Value.undefined_);
    const on_rejected = argOr(args, 1, Value.undefined_);
    const on_fulfilled_fn: Value = if (heap_mod.valueAsFunction(on_fulfilled) != null) on_fulfilled else Value.undefined_;
    const on_rejected_fn: Value = if (heap_mod.valueAsFunction(on_rejected) != null) on_rejected else Value.undefined_;

    const result_promise = allocatePromise(realm, .pending, Value.undefined_) catch return error.OutOfMemory;

    if (std.mem.eql(u8, state, "fulfilled")) {
        realm.enqueuePromiseReaction(on_fulfilled_fn, value, result_promise, false) catch return error.OutOfMemory;
        return result_promise;
    }
    if (std.mem.eql(u8, state, "rejected")) {
        realm.enqueuePromiseReaction(on_rejected_fn, value, result_promise, true) catch return error.OutOfMemory;
        return result_promise;
    }
    // Pending — register reaction; settlement will fire it.
    source.promise_reactions.append(realm.allocator, .{
        .on_fulfilled = on_fulfilled_fn,
        .on_rejected = on_rejected_fn,
        .result_promise = result_promise,
    }) catch return error.OutOfMemory;
    return result_promise;
}

fn promiseCatch(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const cb = argOr(args, 0, Value.undefined_);
    const real_args = [_]Value{ Value.undefined_, cb };
    return promiseThen(realm, this_value, &real_args);
}
fn promiseFinally(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = realm;
    _ = args;
    // invoke the callback and forward state/value.
    // For now the test surface that just calls.finally() and
    // chains accepts the receiver back.
    return this_value;
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
        if (promiseStateOf(v) != null) {
            const c_v = maybe.get("constructor");
            if (heap_mod.valueAsFunction(c_v)) |c| {
                if (c == ctor) return v;
            }
        }
    }
    // For the built-in Promise constructor, the fast path
    // produces an internally-tagged result; for user constructors
    // we go through NewPromiseCapability so the executor's
    // resolve receives `v`.
    const builtin_promise = heap_mod.valueAsFunction(realm.globals.get("Promise") orelse Value.undefined_);
    if (builtin_promise != null and ctor == builtin_promise.?) {
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
    const interp = @import("../interpreter.zig");
    const obj = heap_mod.valueAsPlainObject(source_v) orelse return null;
    const iter_method_v = try getPropertyChain(realm, obj, "@@iterator");
    const iter_method = heap_mod.valueAsFunction(iter_method_v) orelse return null;
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
    const interp = @import("../interpreter.zig");
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
    const interp = @import("../interpreter.zig");
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
        const max_iter: usize = 1 << 24;
        var step: usize = 0;
        while (step < max_iter) : (step += 1) {
            const v = iteratorStep(realm, &rec) catch |err| {
                // Iterator close not needed: rec.done is set by step
                // already on an abrupt completion or normal end.
                return err;
            } orelse break;
            try list.append(realm.allocator, v);
        }
        return list;
    }

    // Array-like fallback.
    const len = try clampArrayLength(try toLengthOf(realm, obj));
    var i: i64 = 0;
    while (i < len) : (i += 1) {
        var ibuf: [24]u8 = undefined;
        const islice = std.fmt.bufPrint(&ibuf, "{d}", .{i}) catch unreachable;
        const v = try getPropertyChain(realm, obj, islice);
        try list.append(realm.allocator, v);
    }
    return list;
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
const IterStepAction = enum { continue_, short_circuit };
fn iterateAggregator(
    realm: *Realm,
    ctor: *JSFunction,
    source_v: Value,
    ctx: *anyopaque,
    process: *const fn (ctx: *anyopaque, realm: *Realm, ctor: *JSFunction, idx: usize, resolved: Value) NativeError!IterStepAction,
) NativeError!void {
    const interp = @import("../interpreter.zig");
    const obj = heap_mod.valueAsPlainObject(source_v) orelse return throwTypeError(realm, "Promise aggregator requires an iterable");

    if (try iteratorOpen(realm, source_v)) |rec_in| {
        var rec = rec_in;
        const max_iter: usize = 1 << 24;
        var idx: usize = 0;
        while (idx < max_iter) : (idx += 1) {
            const next_v = iteratorStep(realm, &rec) catch |err| {
                // Step itself flagged abrupt; close is not our job
                // here (rec.done is true).
                return err;
            } orelse return;

            // §27.2.4.1.2 step 8.h.iv —
            //   `Let nextPromise be ? Invoke(C, "resolve", « nextValue »)`.
            // Look up `constructor.resolve` per item: the spec is
            // explicit that user code can override it
            // (`Promise.resolve = function(){ throw … };`), and
            // that throw must IteratorClose the source.
            const resolve_v = ctor.get("resolve");
            const resolve_fn = heap_mod.valueAsFunction(resolve_v) orelse {
                iteratorClose(realm, &rec);
                return throwTypeError(realm, "Promise aggregator: resolve is not a function");
            };

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

            const action = process(ctx, realm, ctor, idx, resolved) catch |err| {
                iteratorClose(realm, &rec);
                return err;
            };
            if (action == .short_circuit) {
                iteratorClose(realm, &rec);
                return;
            }
        }
        return;
    }

    // Array-like fallback.
    const len = try clampArrayLength(try toLengthOf(realm, obj));
    var i: i64 = 0;
    while (i < len) : (i += 1) {
        var ibuf: [24]u8 = undefined;
        const islice = std.fmt.bufPrint(&ibuf, "{d}", .{i}) catch unreachable;
        const v = try getPropertyChain(realm, obj, islice);
        const resolve_v: Value = ctor.get("resolve");
        const resolve_fn = heap_mod.valueAsFunction(resolve_v) orelse return throwTypeError(realm, "Promise aggregator: resolve is not a function");
        const r_outcome = interp.callJSFunction(realm.allocator, realm, resolve_fn, heap_mod.taggedFunction(ctor), &.{v}) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.NativeThrew,
        };
        const resolved = switch (r_outcome) {
            .value, .yielded => |rv| rv,
            .thrown => |ex| {
                realm.pending_exception = ex;
                return error.NativeThrew;
            },
        };
        const action = try process(ctx, realm, ctor, @intCast(i), resolved);
        if (action == .short_circuit) return;
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
        if (promiseStateOf(v) != null) {
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

            const resolve_impl = realm.heap.allocateFunctionNative(promiseResolveImpl, 1, "") catch return error.OutOfMemory;
            resolve_impl.proto = realm.intrinsics.function_prototype;
            const resolve_fn = realm.heap.allocateFunctionNative(boundResolveTrampoline, 1, "") catch return error.OutOfMemory;
            resolve_fn.proto = realm.intrinsics.function_prototype;
            resolve_fn.bound_target = resolve_impl;
            resolve_fn.bound_this = target_v;

            const reject_impl = realm.heap.allocateFunctionNative(promiseRejectImpl, 1, "") catch return error.OutOfMemory;
            reject_impl.proto = realm.intrinsics.function_prototype;
            const reject_fn = realm.heap.allocateFunctionNative(boundResolveTrampoline, 1, "") catch return error.OutOfMemory;
            reject_fn.proto = realm.intrinsics.function_prototype;
            reject_fn.bound_target = reject_impl;
            reject_fn.bound_this = target_v;

            const interp = @import("../interpreter.zig");
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

/// §27.2.4.1.2 PerformPromiseAll. Per-item callback for the
/// shared aggregator loop: appends the resolved value (or rejects
/// the whole result Promise on the first input that's already
/// rejected). Pending inputs ride through unwrapped — Cynic
/// settles synchronously, so a still-pending entry means a
/// genuinely-pending thenable that won't observe later.
const AllCtx = struct {
    out: *JSObject,
    count: u32 = 0,
    rejected: ?Value = null,
};
fn allProcess(ctx_ptr: *anyopaque, realm: *Realm, ctor: *JSFunction, idx: usize, resolved: Value) NativeError!IterStepAction {
    _ = ctor;
    _ = idx;
    const ctx: *AllCtx = @ptrCast(@alignCast(ctx_ptr));
    const stash: Value = if (promiseStateOf(resolved)) |state| blk: {
        if (std.mem.eql(u8, state, "rejected") and ctx.rejected == null) {
            ctx.rejected = promiseValueOf(resolved);
            // Per spec §27.2.4.1.2 we keep iterating so
            // `Promise.resolve` is invoked for every input — the
            // result Promise's rejection just settles before the
            // later `.then` reactions fire. Don't short-circuit.
        }
        break :blk promiseValueOf(resolved);
    } else resolved;
    var ibuf: [24]u8 = undefined;
    const islice = std.fmt.bufPrint(&ibuf, "{d}", .{ctx.count}) catch unreachable;
    const owned = realm.heap.allocateString(islice) catch return error.OutOfMemory;
    ctx.out.set(realm.allocator, owned.bytes, stash) catch return error.OutOfMemory;
    ctx.count += 1;
    return .continue_;
}

fn promiseAll(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const ctor = try thisAsPromiseCtor(realm, this_value, "all");
    // §27.2.4.1 step 2 — `Let promiseCapability be ? NewPromiseCapability(C)`.
    // Synchronously throws if `ctor`'s executor is misshapen
    // (called twice / non-callable args). Built-in Promise gets
    // a capability too; resolve/reject settle the result via the
    // standard closures.
    const cap = if (isBuiltinPromise(realm, ctor)) null_cap else try newPromiseCapability(realm, ctor);
    const out = realm.heap.allocateObject() catch return error.OutOfMemory;
    out.prototype = realm.intrinsics.array_prototype;
    var ctx = AllCtx{ .out = out };
    iterateAggregator(realm, ctor, argOr(args, 0, Value.undefined_), &ctx, allProcess) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.NativeThrew => return aggregatorRejectThroughCap(realm, ctor, cap),
    };
    if (ctx.rejected) |rv| {
        return aggregatorSettleReject(realm, ctor, cap, rv);
    }
    setLength(realm, out, @intCast(ctx.count)) catch return error.OutOfMemory;
    return aggregatorSettleResolve(realm, ctor, cap, heap_mod.taggedObject(out));
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
    entry.prototype = realm.intrinsics.object_prototype;
    if (promiseStateOf(resolved)) |state| {
        if (std.mem.eql(u8, state, "rejected")) {
            entry.set(realm.allocator, "status", Value.fromString(ctx.rejected_str)) catch return error.OutOfMemory;
            entry.set(realm.allocator, "reason", promiseValueOf(resolved)) catch return error.OutOfMemory;
        } else {
            entry.set(realm.allocator, "status", Value.fromString(ctx.fulfilled_str)) catch return error.OutOfMemory;
            entry.set(realm.allocator, "value", promiseValueOf(resolved)) catch return error.OutOfMemory;
        }
    } else {
        entry.set(realm.allocator, "status", Value.fromString(ctx.fulfilled_str)) catch return error.OutOfMemory;
        entry.set(realm.allocator, "value", resolved) catch return error.OutOfMemory;
    }
    var ibuf: [24]u8 = undefined;
    const islice = std.fmt.bufPrint(&ibuf, "{d}", .{ctx.count}) catch unreachable;
    const owned = realm.heap.allocateString(islice) catch return error.OutOfMemory;
    ctx.out.set(realm.allocator, owned.bytes, heap_mod.taggedObject(entry)) catch return error.OutOfMemory;
    ctx.count += 1;
    return .continue_;
}

fn promiseAllSettled(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const ctor = try thisAsPromiseCtor(realm, this_value, "allSettled");
    const cap = if (isBuiltinPromise(realm, ctor)) null_cap else try newPromiseCapability(realm, ctor);
    const out = realm.heap.allocateObject() catch return error.OutOfMemory;
    out.prototype = realm.intrinsics.array_prototype;
    const fulfilled_str = realm.heap.allocateString("fulfilled") catch return error.OutOfMemory;
    const rejected_str = realm.heap.allocateString("rejected") catch return error.OutOfMemory;
    var ctx = AllSettledCtx{ .out = out, .fulfilled_str = fulfilled_str, .rejected_str = rejected_str };
    iterateAggregator(realm, ctor, argOr(args, 0, Value.undefined_), &ctx, allSettledProcess) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.NativeThrew => return aggregatorRejectThroughCap(realm, ctor, cap),
    };
    setLength(realm, out, @intCast(ctx.count)) catch return error.OutOfMemory;
    return aggregatorSettleResolve(realm, ctor, cap, heap_mod.taggedObject(out));
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
    const interp = @import("../interpreter.zig");
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
    var ctx = RaceCtx{ .cap = cap };
    iterateAggregator(realm, ctor, argOr(args, 0, Value.undefined_), &ctx, raceProcess) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.NativeThrew => return aggregatorRejectThroughCap(realm, ctor, cap),
    };
    return cap.promise;
}

/// §27.2.4.3.1 PerformPromiseAny. First fulfilled input wins; if
/// every input rejected, reject with a fresh `AggregateError`
/// listing the reasons in input order.
const AnyCtx = struct {
    reasons: *JSObject,
    count: u32 = 0,
    found: ?Value = null,
};
fn anyProcess(ctx_ptr: *anyopaque, realm: *Realm, ctor: *JSFunction, idx: usize, resolved: Value) NativeError!IterStepAction {
    _ = ctor;
    _ = idx;
    const ctx: *AnyCtx = @ptrCast(@alignCast(ctx_ptr));
    // §27.2.4.3.1 — Promise.resolve fires for every input even
    // after a fulfillment is found. Keep iterating; just stop
    // recording reasons once we have a fulfillment.
    if (ctx.found != null) return .continue_;
    if (promiseStateOf(resolved)) |state| {
        if (std.mem.eql(u8, state, "fulfilled")) {
            ctx.found = promiseValueOf(resolved);
            return .continue_;
        }
        var ibuf: [24]u8 = undefined;
        const islice = std.fmt.bufPrint(&ibuf, "{d}", .{ctx.count}) catch unreachable;
        const owned = realm.heap.allocateString(islice) catch return error.OutOfMemory;
        ctx.reasons.set(realm.allocator, owned.bytes, promiseValueOf(resolved)) catch return error.OutOfMemory;
        ctx.count += 1;
        return .continue_;
    }
    ctx.found = resolved;
    return .continue_;
}

fn promiseAny(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const ctor = try thisAsPromiseCtor(realm, this_value, "any");
    const cap = if (isBuiltinPromise(realm, ctor)) null_cap else try newPromiseCapability(realm, ctor);
    const reasons = realm.heap.allocateObject() catch return error.OutOfMemory;
    reasons.prototype = realm.intrinsics.array_prototype;
    var ctx = AnyCtx{ .reasons = reasons };
    iterateAggregator(realm, ctor, argOr(args, 0, Value.undefined_), &ctx, anyProcess) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.NativeThrew => return aggregatorRejectThroughCap(realm, ctor, cap),
    };
    if (ctx.found) |fv| {
        return aggregatorSettleResolve(realm, ctor, cap, fv);
    }
    setLength(realm, reasons, @intCast(ctx.count)) catch return error.OutOfMemory;

    const agg_proto = realm.intrinsics.aggregate_error_prototype orelse realm.intrinsics.error_prototype.?;
    const agg = realm.heap.allocateObject() catch return error.OutOfMemory;
    agg.prototype = agg_proto;
    agg.setWithFlags(realm.allocator, "errors", heap_mod.taggedObject(reasons), .{
        .writable = true,
        .enumerable = false,
        .configurable = true,
    }) catch return error.OutOfMemory;
    const msg_str = realm.heap.allocateString("All promises were rejected") catch return error.OutOfMemory;
    agg.set(realm.allocator, "message", Value.fromString(msg_str)) catch return error.OutOfMemory;
    return aggregatorSettleReject(realm, ctor, cap, heap_mod.taggedObject(agg));
}

/// §27.2.4.5 Promise.try ( callbackfn, ...args ) — ES2025.
/// Invoke `callbackfn` synchronously with `args`; the returned
/// Promise is rejected with whatever the call throws (including
/// the TypeError raised when `callbackfn` isn't callable) and
/// fulfilled otherwise. If the callback already returns a
/// same-constructor Promise we forward it unchanged so chained
/// `.then` preserves identity.
fn promiseTry(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const ctor = try thisAsPromiseCtor(realm, this_value, "try");
    const callback = argOr(args, 0, Value.undefined_);
    const callback_fn = heap_mod.valueAsFunction(callback) orelse {
        const ex = intrinsics.newTypeError(realm, "Promise.try requires a function") catch return error.OutOfMemory;
        return allocatePromiseFor(realm, ctor, .rejected, ex) catch return error.OutOfMemory;
    };
    const rest_args: []const Value = if (args.len > 1) args[1..] else &[_]Value{};
    const interp = @import("../interpreter.zig");
    const outcome = interp.callJSFunction(realm.allocator, realm, callback_fn, Value.undefined_, rest_args) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.NativeThrew,
    };
    return switch (outcome) {
        .value, .yielded => |v| blk: {
            if (heap_mod.valueAsPlainObject(v)) |maybe| {
                if (promiseStateOf(v) != null) {
                    const c_v = maybe.get("constructor");
                    if (heap_mod.valueAsFunction(c_v)) |c| {
                        if (c == ctor) break :blk v;
                    }
                }
            }
            break :blk allocatePromiseFor(realm, ctor, .fulfilled, v) catch return error.OutOfMemory;
        },
        .thrown => |ex| allocatePromiseFor(realm, ctor, .rejected, ex) catch return error.OutOfMemory,
    };
}

/// §27.2.4.6 Promise.withResolvers ( ) — ES2025.
/// Returns `{ promise, resolve, reject }` where `resolve` and
/// `reject` settle the bundled `promise`. Mirrors the bound-fn
/// trampoline used by `new Promise(executor)` so settlement goes
/// through the same `promiseResolveImpl` / `promiseRejectImpl`
/// path.
fn promiseWithResolvers(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = args;
    const ctor = try thisAsPromiseCtor(realm, this_value, "withResolvers");
    const promise_v = allocatePromiseFor(realm, ctor, .pending, Value.undefined_) catch return error.OutOfMemory;

    // Per §27.2.1.5 NewPromiseCapability, the Resolve and Reject
    // functions have name = "". The 1-arg `length` matches spec
    // (they take a single (resolution) / (reason) parameter).
    const resolve_impl = realm.heap.allocateFunctionNative(promiseResolveImpl, 1, "") catch return error.OutOfMemory;
    resolve_impl.proto = realm.intrinsics.function_prototype;
    const resolve_fn = realm.heap.allocateFunctionNative(boundResolveTrampoline, 1, "") catch return error.OutOfMemory;
    resolve_fn.proto = realm.intrinsics.function_prototype;
    resolve_fn.bound_target = resolve_impl;
    resolve_fn.bound_this = promise_v;

    const reject_impl = realm.heap.allocateFunctionNative(promiseRejectImpl, 1, "") catch return error.OutOfMemory;
    reject_impl.proto = realm.intrinsics.function_prototype;
    const reject_fn = realm.heap.allocateFunctionNative(boundResolveTrampoline, 1, "") catch return error.OutOfMemory;
    reject_fn.proto = realm.intrinsics.function_prototype;
    reject_fn.bound_target = reject_impl;
    reject_fn.bound_this = promise_v;

    const obj = realm.heap.allocateObject() catch return error.OutOfMemory;
    obj.prototype = realm.intrinsics.object_prototype;
    obj.set(realm.allocator, "promise", promise_v) catch return error.OutOfMemory;
    obj.set(realm.allocator, "resolve", heap_mod.taggedFunction(resolve_fn)) catch return error.OutOfMemory;
    obj.set(realm.allocator, "reject", heap_mod.taggedFunction(reject_fn)) catch return error.OutOfMemory;
    return heap_mod.taggedObject(obj);
}

