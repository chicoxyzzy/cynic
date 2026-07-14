//! §27.4 AsyncDisposableStack — ES2026 explicit-resource-management.
//!
//! Async sibling of `DisposableStack`. `.use()` accepts either
//! `Symbol.asyncDispose` (preferred) or `Symbol.dispose`
//! (fallback per §9.5.2 GetDisposeMethod step 1.a / 1.b) and
//! `.disposeAsync()` returns a Promise that fulfils once the
//! LIFO walk has AWAITED every disposer. A mid-disposal throw
//! becomes the in-flight rejection; a subsequent disposer's
//! throw wraps the pair as `new SuppressedError(<new throw>,
//! <previous throw>)` (§9.5.4 step 2.b.iv-vi).
//!
//! The walk is driven by a `.then` chain across the snapshotted
//! resource records — one reaction per resource — terminated by
//! a `finalize` reaction that settles the outer Promise. Each
//! step's onFulfilled / onRejected resolves via the bound-`this`
//! pattern: the bound trampoline's `bound_target` is the inner
//! native impl, `bound_this` is the AsyncDisposableStack. The
//! per-walk state (snapshot, cursor, in-flight pending throw,
//! outer Promise) lives on `JSObjectExtension.async_dispose_walk`,
//! NOT as `__cynic_*` keys on the user-visible stack instance
//! (see AGENTS.md's "no engine state on user-visible objects"
//! rule). The slot is GC-traced by `Heap.markRoots`.
//!
//! Brand discrimination from sync `DisposableStack` lives in
//! the `disposable_state` enum's `.async_*` variants — a single
//! 8-bit slot doubles as kind + lifecycle tag, so an attempted
//! `Object.setPrototypeOf` can't flip the brand.

const std = @import("std");

const Realm = @import("../realm.zig").Realm;
const Value = @import("../value.zig").Value;
const JSString = @import("../string.zig").JSString;
const JSObject = @import("../object.zig").JSObject;
const JSFunction = @import("../function.zig").JSFunction;
const NativeError = @import("../function.zig").NativeError;
const NativeFn = @import("../function.zig").NativeFn;
const heap_mod = @import("../heap.zig");
const intrinsics = @import("../intrinsics.zig");
const object_mod = @import("../object.zig");
const DisposableState = object_mod.DisposableState;
const DisposableHint = object_mod.DisposableHint;
const DisposableResource = object_mod.DisposableResource;
const AsyncDisposeWalk = object_mod.AsyncDisposeWalk;

const promise_mod = @import("promise.zig");

const setNonEnumerable = intrinsics.setNonEnumerable;
const installConstructor = intrinsics.installConstructor;
const installNativeMethodOnProto = intrinsics.installNativeMethodOnProto;
const installNativeGetter = intrinsics.installNativeGetter;
const installToStringTag = intrinsics.installToStringTag;
const throwTypeError = intrinsics.throwTypeError;
const throwReferenceError = intrinsics.throwReferenceError;

pub fn install(realm: *Realm) !void {
    // §27.4.1 AsyncDisposableStack — constructor + prototype.
    // `length` is 0; the constructor is `new`-only (§27.4.1.1
    // step 1 — IsCallable(NewTarget) === false ⇒ TypeError).
    const r = try installConstructor(realm, .{
        .name = "AsyncDisposableStack",
        .ctor = asyncDisposableStackConstructor,
        .arity = 0,
        .is_class = true,
        .set_home_object = true,
        .to_string_tag = "AsyncDisposableStack",
    });
    const fn_obj = r.ctor;
    const proto = r.proto;

    // §27.4.3.{2,3,4,5,7} — prototype methods. `disposeAsync` is
    // installed first so the `Symbol.asyncDispose` alias can
    // reference the same callable.
    try installNativeMethodOnProto(realm, proto, "disposeAsync", asyncDisposableStackDisposeAsync, 0);
    try installNativeMethodOnProto(realm, proto, "use", asyncDisposableStackUse, 1);
    try installNativeMethodOnProto(realm, proto, "adopt", asyncDisposableStackAdopt, 2);
    try installNativeMethodOnProto(realm, proto, "defer", asyncDisposableStackDefer, 1);
    try installNativeMethodOnProto(realm, proto, "move", asyncDisposableStackMove, 0);
    // §27.4.3.1 AsyncDisposableStack.prototype.disposed — accessor.
    try installNativeGetter(realm, proto, "disposed", asyncDisposableStackDisposedGetter);

    // §27.4.3.6 AsyncDisposableStack.prototype[@@asyncDispose] —
    // the spec sets this to the SAME function object as
    // `disposeAsync`. Install one allocation, then alias under
    // the well-known-symbol key (mirrors the §27.3.3.6
    // `[@@dispose]` alias on DisposableStack.prototype).
    //
    // §27.4.3 deliberately does NOT install `[@@dispose]` on the
    // async prototype — an `AsyncDisposableStack` used in a
    // sync `using` binding must trip the `GetDisposeMethod(V,
    // sync-dispose)` TypeError per §9.5.2 step 1.b.
    const dispose_fn_v = proto.lookupOwn("disposeAsync") orelse Value.undefined_;
    try proto.setWithFlags(realm.allocator, "@@asyncDispose", dispose_fn_v, .{
        .writable = true,
        .enumerable = false,
        .configurable = true,
    });

    realm.intrinsics.async_disposable_stack_constructor = fn_obj;
    realm.intrinsics.async_disposable_stack_prototype = proto;
}

// §27.4.1.1 AsyncDisposableStack ( ) — constructor body. Throws
// TypeError when invoked without `new` (no [[Call]]); on `new`,
// initialises the freshly-allocated `this` with
// `[[AsyncDisposableState]] = "pending"` and
// `[[DisposeCapability]] = «»`.
fn asyncDisposableStackConstructor(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = args;
    // §27.4.1.1 step 1 — when called without `new`, `this_value`
    // is the global object (or undefined under strict). The
    // interpreter passes a fresh JSObject (proto =
    // AsyncDisposableStack.prototype) only on a real `new`
    // dispatch, so the non-object case is the plain-call signal —
    // throw TypeError per the §27.4.1.1 step 1 NewTarget check.
    const instance = heap_mod.valueAsPlainObject(this_value) orelse {
        return throwTypeError(realm, "AsyncDisposableStack constructor requires 'new'");
    };
    // §27.4.1.1 step 4-5 — set [[AsyncDisposableState]] = "pending"
    // and [[DisposeCapability]] = a fresh empty DisposeCapability
    // Record. Both live on the JSObjectExtension typed slots; the
    // extension's resource list is already `.empty` from
    // getOrCreateExtension's zero-init.
    try instance.setDisposableState(realm.allocator, .async_pending);
    return heap_mod.taggedObject(instance);
}

/// §27.4.3.x `RequireInternalSlot(O, [[AsyncDisposableState]])` —
/// the brand check shared by every prototype method. Throws
/// TypeError when the receiver isn't an `AsyncDisposableStack` —
/// either its extension never had `disposable_state` set
/// (plain object) OR the slot carries the sync DisposableStack
/// brand (§27.3) instead.
fn requireAsyncDisposableStack(realm: *Realm, this_value: Value) NativeError!*JSObject {
    const obj = heap_mod.valueAsPlainObject(this_value) orelse {
        return throwTypeError(realm, "AsyncDisposableStack method called on non-object");
    };
    const state = obj.getDisposableState() orelse {
        return throwTypeError(realm, "AsyncDisposableStack method called on incompatible receiver");
    };
    if (!state.isAsync()) {
        return throwTypeError(realm, "AsyncDisposableStack method called on incompatible receiver");
    }
    return obj;
}

// §27.4.3.7 AsyncDisposableStack.prototype.use ( value ).
//   1. Let O be the this value.
//   2. Perform ? RequireInternalSlot(O, [[AsyncDisposableState]]).
//   3. If O.[[AsyncDisposableState]] is "disposed", throw ReferenceError.
//   4. Perform ? AddDisposableResource(O, value, async-dispose).
//   5. Return value.
fn asyncDisposableStackUse(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const stack = try requireAsyncDisposableStack(realm, this_value);
    if (stack.getDisposableState().?.isDisposed()) {
        return throwReferenceError(realm, "AsyncDisposableStack.prototype.use: stack is disposed");
    }
    const value = if (args.len > 0) args[0] else Value.undefined_;
    try addAsyncDisposableResource(realm, stack, value);
    return value;
}

// §27.4.3.2 AsyncDisposableStack.prototype.adopt ( value, onDispose ).
//   1-2. RequireInternalSlot.
//   3. If state is "disposed", throw ReferenceError.
//   4. If IsCallable(onDispose) is false, throw TypeError.
//   5. Let closure be a new Abstract Closure with no parameters
//      that captures value and onDispose and performs:
//        Return ? Call(onDispose, undefined, « value »).
//   6. Let F = CreateBuiltinFunction(closure, 0, "", « »).
//   7. Perform ? AddDisposableResource(O, undefined, async-dispose, F).
//   8. Return value.
//
// Cynic implements the closure as a bound function: target is
// `onDispose`, captured `this` is undefined, prefix args are
// `[value]`. Calling the bound function with no args ⇒
// `onDispose.call(undefined, value)`, matching the spec closure.
// The async walk awaits the bound function's return value if
// it's a thenable.
fn asyncDisposableStackAdopt(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const stack = try requireAsyncDisposableStack(realm, this_value);
    if (stack.getDisposableState().?.isDisposed()) {
        return throwReferenceError(realm, "AsyncDisposableStack.prototype.adopt: stack is disposed");
    }
    const value = if (args.len > 0) args[0] else Value.undefined_;
    const on_dispose_v = if (args.len > 1) args[1] else Value.undefined_;
    const on_dispose = heap_mod.valueAsFunction(on_dispose_v) orelse {
        return throwTypeError(realm, "AsyncDisposableStack.prototype.adopt: onDispose is not callable");
    };

    // §27.4.3.2 step 5-6 — build the wrapper closure as a bound
    // function. `bound_this = undefined`, prefix args `[value]`.
    const wrapper = realm.heap.allocateFunctionNative(realm, boundAdoptTrampoline, 0, "") catch return error.OutOfMemory;
    wrapper.proto = realm.intrinsics.function_prototype;
    wrapper.has_construct = false;
    realm.heap.setBoundTarget(wrapper, on_dispose);
    realm.heap.setBoundThis(wrapper, Value.undefined_);
    const args_slice = realm.allocator.alloc(Value, 1) catch return error.OutOfMemory;
    args_slice[0] = value;
    realm.heap.setBoundArgs(wrapper, args_slice);

    // §27.4.3.2 step 7 — AddDisposableResource with V = undefined,
    // hint = async-dispose, method = the wrapper.
    const ext_list = try stack.disposableResourcesPtr(realm.allocator);
    ext_list.append(realm.allocator, .{
        .resource = Value.undefined_,
        .hint = .async_dispose,
        .dispose_method = heap_mod.taggedFunction(wrapper),
    }) catch return error.OutOfMemory;
    return value;
}

// The bound function's native body is never reached — the call
// dispatch checks `bound_target` first and re-enters
// `callJSFunction` with the unwrapped target + prefix args.
// Provide a no-op stub so the allocation succeeds.
fn boundAdoptTrampoline(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = realm;
    _ = this_value;
    _ = args;
    return Value.undefined_;
}

// §27.4.3.3 AsyncDisposableStack.prototype.defer ( onDispose ).
//   1-2. RequireInternalSlot.
//   3. If state is "disposed", throw ReferenceError.
//   4. If IsCallable(onDispose) is false, throw TypeError.
//   5. Perform ? AddDisposableResource(O, undefined, async-dispose, onDispose).
//   6. Return undefined.
fn asyncDisposableStackDefer(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const stack = try requireAsyncDisposableStack(realm, this_value);
    if (stack.getDisposableState().?.isDisposed()) {
        return throwReferenceError(realm, "AsyncDisposableStack.prototype.defer: stack is disposed");
    }
    const on_dispose_v = if (args.len > 0) args[0] else Value.undefined_;
    if (heap_mod.valueAsFunction(on_dispose_v) == null) {
        return throwTypeError(realm, "AsyncDisposableStack.prototype.defer: onDispose is not callable");
    }
    const ext_list = try stack.disposableResourcesPtr(realm.allocator);
    ext_list.append(realm.allocator, .{
        .resource = Value.undefined_,
        .hint = .async_dispose,
        .dispose_method = on_dispose_v,
    }) catch return error.OutOfMemory;
    return Value.undefined_;
}

// §27.4.3.1 get AsyncDisposableStack.prototype.disposed.
//   1-2. RequireInternalSlot.
//   3. Return true iff state is "disposed".
fn asyncDisposableStackDisposedGetter(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = args;
    const stack = try requireAsyncDisposableStack(realm, this_value);
    return Value.fromBool(stack.getDisposableState().?.isDisposed());
}

// §27.4.3.5 AsyncDisposableStack.prototype.move ( ).
//   1-2. RequireInternalSlot.
//   3. If state is "disposed", throw ReferenceError.
//   4. Let newAsyncDisposableStack be ? OrdinaryCreateFromConstructor(
//        %AsyncDisposableStack%, "%AsyncDisposableStack.prototype%",
//        « [[AsyncDisposableState]], [[DisposeCapability]] »).
//   5. Set newAsyncDisposableStack.[[AsyncDisposableState]] to "pending".
//   6. Set newAsyncDisposableStack.[[DisposeCapability]] to O.[[DisposeCapability]].
//   7. Set O.[[DisposeCapability]] to a new empty DisposeCapability.
//   8. Set O.[[AsyncDisposableState]] to "disposed".
//   9. Return newAsyncDisposableStack.
fn asyncDisposableStackMove(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = args;
    const stack = try requireAsyncDisposableStack(realm, this_value);
    if (stack.getDisposableState().?.isDisposed()) {
        return throwReferenceError(realm, "AsyncDisposableStack.prototype.move: stack is disposed");
    }
    // §27.4.3.5 step 4 — allocate a fresh instance with our
    // prototype. OrdinaryCreateFromConstructor isn't reachable
    // from here without the user-facing NewTarget; reach the
    // realm-pinned prototype directly (mirrors the §27.3.3.5
    // move() pattern).
    const new_stack = realm.heap.allocateObject() catch return error.OutOfMemory;
    const proto = realm.intrinsics.async_disposable_stack_prototype.?;
    realm.heap.setObjectPrototype(new_stack, proto);
    try new_stack.setDisposableState(realm.allocator, .async_pending);

    // Move (don't copy) the resource list. Walk the source list
    // and append into the destination; then clear the source.
    if (stack.disposableResourcesConst()) |src_list| {
        const dst_list = try new_stack.disposableResourcesPtr(realm.allocator);
        dst_list.ensureUnusedCapacity(realm.allocator, src_list.items.len) catch return error.OutOfMemory;
        for (src_list.items) |rec| dst_list.appendAssumeCapacity(rec);
    }
    // Clear the source list and flip the source to "disposed".
    if (stack.extension) |ext| ext.disposable_resources.clearRetainingCapacity();
    try stack.setDisposableState(realm.allocator, .async_disposed);
    return heap_mod.taggedObject(new_stack);
}

// §27.4.3.4 AsyncDisposableStack.prototype.disposeAsync ( ).
//   1. Let O be the this value.
//   2. Let promiseCapability be ! NewPromiseCapability(%Promise%).
//   3. If O does not have an [[AsyncDisposableState]] internal slot,
//      perform ! Call(promiseCapability.[[Reject]], undefined,
//      « a newly created TypeError object ») and return
//      promiseCapability.[[Promise]].
//   4. If O.[[AsyncDisposableState]] is "disposed",
//      perform ! Call(promiseCapability.[[Resolve]], undefined,
//      « undefined ») and return promiseCapability.[[Promise]].
//   5. Set O.[[AsyncDisposableState]] to "disposed".
//   6. Let result be Completion(DisposeResources(
//        O.[[DisposeCapability]], NormalCompletion(undefined))).
//   7. IfAbruptRejectPromise(result, promiseCapability).
//   8. Perform ! Call(promiseCapability.[[Resolve]], undefined,
//      « undefined »).
//   9. Return promiseCapability.[[Promise]].
//
// Cynic departs from the spec-letter capability allocation in
// favour of `allocatePromiseFor(realm, null, .pending, …)` (the
// engine-internal Promise allocator); both routes settle the same
// observable shape and the latter avoids a same-realm capability
// double-construct. The DisposeResources walk is implemented
// inline as a `.then`-chain across the snapshot — each disposer
// fires from its own microtask, so a thenable-returning disposer
// is awaited before the next one starts (§9.5.4 hint = async).
fn asyncDisposableStackDisposeAsync(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = args;
    // §27.4.3.4 step 3 (above-spec IfAbruptRejectPromise variant):
    // an incompatible receiver yields a Promise rejected with
    // TypeError, NOT a synchronous throw. Mirrors how the
    // async-iterator [@@asyncDispose] propagates GetMethod abrupts.
    const obj = heap_mod.valueAsPlainObject(this_value) orelse {
        const ex_v = try makeTypeError(realm, "AsyncDisposableStack.prototype.disposeAsync called on non-object");
        return promise_mod.allocatePromiseFor(realm, null, .rejected, ex_v) catch return error.OutOfMemory;
    };
    const state = obj.getDisposableState() orelse {
        const ex_v = try makeTypeError(realm, "AsyncDisposableStack.prototype.disposeAsync called on incompatible receiver");
        return promise_mod.allocatePromiseFor(realm, null, .rejected, ex_v) catch return error.OutOfMemory;
    };
    if (!state.isAsync()) {
        const ex_v = try makeTypeError(realm, "AsyncDisposableStack.prototype.disposeAsync called on incompatible receiver");
        return promise_mod.allocatePromiseFor(realm, null, .rejected, ex_v) catch return error.OutOfMemory;
    }
    // §27.4.3.4 step 4 — already disposed: fulfilled-with-undefined.
    if (state.isDisposed()) {
        return promise_mod.allocatePromiseFor(realm, null, .fulfilled, Value.undefined_) catch return error.OutOfMemory;
    }
    // §27.4.3.4 step 5 — flip state BEFORE walking so a disposer
    // calling `.use()` / `.defer()` on the same stack trips the
    // §27.4.3.7 step 3 ReferenceError (matches the sync §27.3.3.4
    // ordering).
    try obj.setDisposableState(realm.allocator, .async_disposed);

    // §27.4.3.4 step 6 — DisposeResources with hint = async-dispose.
    return startAsyncDisposeWalk(realm, obj);
}

/// Begin the §9.5.4 DisposeResources walk for hint = async-dispose.
/// Allocates the outer Promise + the snapshot, builds the `.then`
/// chain that pumps one disposer per microtask, and returns the
/// outer Promise to the caller. The outer settles only after the
/// last reaction in the chain runs (`finalizeImpl`).
///
/// Public so the `dispose_stack_async` opcode (emitted at the
/// scope-exit of a block containing `await using` declarations)
/// can share the chain machinery. The opcode passes the in-flight
/// throw (mode 1) via `startAsyncDisposeWalkWithExisting`; the
/// public bare entry forwards with no existing throw.
pub fn startAsyncDisposeWalkPublic(realm: *Realm, stack: *JSObject) NativeError!Value {
    return startAsyncDisposeWalk(realm, stack);
}

/// Variant that seeds the walk's `pending_error` with an
/// in-flight throw (the `mode == 1` throw-completion arm of the
/// `dispose_stack_async` opcode). A disposer's own throw wraps
/// it via SuppressedError per §9.5.4 step 2.b.iv-vi; a clean
/// walk lets the original throw surface (the caller re-throws
/// it after the outer Promise settles).
pub fn startAsyncDisposeWalkWithExisting(realm: *Realm, stack: *JSObject, existing_throw: Value) NativeError!Value {
    const outer = try startAsyncDisposeWalk(realm, stack);
    if (stack.extension) |ext| {
        if (ext.async_dispose_walk) |walk| {
            // Seed pending_error for SuppressedError wrapping, but
            // mark it as externally provided. The walk uses
            // pending_error as the "suppressed" half when a
            // disposer throws; if NO disposer throws, the outer
            // Promise must fulfil with undefined (the caller's
            // throw-handler arm re-throws the original — settling
            // the Promise as rejected would re-throw twice). The
            // `external_seed` flag tells `finalizeSettle` to
            // clear pending_error before settling iff no disposer
            // contributed.
            walk.pending_error = existing_throw;
            walk.has_pending_error = true;
            walk.external_seed_only = true;
            // Card-marking barrier: a (possibly young) seeded error now
            // lives in the walk on a (possibly mature) stack.
            stack.noteInternalSlotWrite();
        }
    }
    return outer;
}

fn startAsyncDisposeWalk(realm: *Realm, stack: *JSObject) NativeError!Value {
    // Allocate the outer result Promise (pending). `allocatePromiseFor`
    // with `ctor = null` falls through to %Promise.prototype% — the
    // observable shape user code reads through
    // `disposeAsync() instanceof Promise`.
    const outer = promise_mod.allocatePromiseFor(realm, null, .pending, Value.undefined_) catch return error.OutOfMemory;

    // Snapshot the resource list onto the walk state. `.move()`-style
    // transfer: the source list is cleared so re-entry during
    // disposal (a disposer calling `.use()` on a NEW stack and
    // immediately moving from THIS one) sees the empty list. The
    // walk owns the records until the chain finalizes.
    const ext = stack.getOrCreateExtension(realm.allocator) catch return error.OutOfMemory;
    const walk = realm.allocator.create(AsyncDisposeWalk) catch return error.OutOfMemory;
    walk.* = .{
        .resources = .empty,
        .cursor = 0,
        .pending_error = Value.undefined_,
        .has_pending_error = false,
        .outer = outer,
    };
    if (ext.disposable_resources.items.len > 0) {
        walk.resources.ensureUnusedCapacity(realm.allocator, ext.disposable_resources.items.len) catch return error.OutOfMemory;
        for (ext.disposable_resources.items) |rec| walk.resources.appendAssumeCapacity(rec);
        walk.cursor = @intCast(ext.disposable_resources.items.len);
    }
    ext.disposable_resources.clearRetainingCapacity();
    // Replace any prior walk (idempotent disposeAsync on a stack
    // whose first walk has already been allocated would otherwise
    // leak the old walk's snapshot). The disposed-state guard
    // upstream means a SECOND disposeAsync on the same stack
    // doesn't enter this path; the assignment is defensive.
    if (ext.async_dispose_walk) |old| old.deinit(realm.allocator);
    ext.async_dispose_walk = walk;
    // Card-marking barrier: the walk snapshot holds (possibly young)
    // disposable resources; remember a mature stack so the next minor
    // cycle scans them. See `Heap.rememberTypedSlotWrite`.
    stack.noteInternalSlotWrite();

    // Fast path — empty resource list: no chain to build. Fulfill
    // outer immediately. `settlePromiseInternal` flushes any
    // reactions a user already registered between this call and
    // the synchronous return (rare for an empty stack, but a
    // `disposeAsync().then(...)` chain attached IMMEDIATELY can
    // still register a reaction before we return).
    if (walk.resources.items.len == 0) {
        if (heap_mod.valueAsPlainObject(outer)) |o| {
            const lpromise = @import("../lantern/promise.zig");
            lpromise.settlePromiseInternal(realm, o, .fulfilled, Value.undefined_) catch return error.OutOfMemory;
        }
        // The walk struct is no longer needed; drop it.
        ext.async_dispose_walk = null;
        walk.deinit(realm.allocator);
        return outer;
    }

    // Allocate the bound trampolines: step_fulfilled,
    // step_rejected, finalize_fulfilled, finalize_rejected. Each
    // carries `bound_this = stack` so the inner impl recovers
    // the walk state through the stack's extension. The two
    // finalize variants differ in one beat — the rejected
    // variant stashes its `args[0]` rejection before settling
    // the outer Promise. Without it the LAST disposer's throw
    // would slip through (no `step_rejected` step exists
    // between the last disposer's `.then` and the finalize
    // `.then`).
    const step_f = try allocateStepBound(realm, stack, asyncStepFulfilledImpl, "");
    const step_r = try allocateStepBound(realm, stack, asyncStepRejectedImpl, "");
    const finalize_f = try allocateStepBound(realm, stack, asyncFinalizeFulfilledImpl, "");
    const finalize_r = try allocateStepBound(realm, stack, asyncFinalizeRejectedImpl, "");

    // Seed the chain with `Promise.resolve(undefined)`. The first
    // .then's onFulfilled fires once microtasks drain.
    const builtin_promise = realm.globals.get("Promise") orelse Value.undefined_;
    const seed_args = [_]Value{Value.undefined_};
    var current = promise_mod.promiseResolveExported(realm, builtin_promise, &seed_args) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.NativeThrew,
    };

    // Build one .then(step_f, step_r) per snapshotted resource —
    // but ONLY for records with a real `dispose_method`. Ghost
    // records (`method == undefined`, appended for `await using x
    // = null` / `await using x = undefined` per §9.5.3 step 1.b)
    // contribute nothing to the chain except a needsAwait
    // marker. §9.5.4 step 4 requires a SINGLE `Await(undefined)`
    // at the end iff `needsAwait` is true and `hasAwaited` is
    // false; the seed `.then(finalize)` reaction below is that
    // single await. Adding a per-ghost step would settle the
    // outer Promise one microtask too late and break the spec-
    // mandated ordering (`built-ins/AsyncDisposableStack/
    // prototype/disposeAsync/explicit-await-for-{null,undefined}
    // .js`).
    var real_steps: u32 = 0;
    var cursor: u32 = walk.cursor;
    while (cursor > 0) : (cursor -= 1) {
        const rec = walk.resources.items[cursor - 1];
        if (!rec.dispose_method.isUndefined()) real_steps += 1;
    }
    var remaining: u32 = real_steps;
    while (remaining > 0) : (remaining -= 1) {
        const then_args = [_]Value{ heap_mod.taggedFunction(step_f), heap_mod.taggedFunction(step_r) };
        current = promise_mod.promiseThenExported(realm, current, &then_args) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.NativeThrew,
        };
    }
    // Terminal reaction: settle the outer Promise. Both branches
    // (fulfilled / rejected from the last step) go to finalize —
    // the inner impl reads `pending_error` to decide which way
    // outer settles. The seed → finalize hop is also what
    // implements §9.5.4 step 4's `Await(undefined)` when ALL
    // records are ghosts: the chain has zero step .thens, so the
    // seed.then(finalize) reaction is the single mandated
    // microtask hop.
    const final_then_args = [_]Value{ heap_mod.taggedFunction(finalize_f), heap_mod.taggedFunction(finalize_r) };
    _ = promise_mod.promiseThenExported(realm, current, &final_then_args) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.NativeThrew,
    };
    return outer;
}

/// Allocate the bound-trampoline pair used by every `.then`
/// reaction in the async-dispose chain. The OUTER bound function
/// is what `.then` invokes; the call dispatch unwraps it to the
/// INNER impl with `this = stack` (the captured `bound_this`).
/// The outer's `name` is `""` to match §17 anonymous closures.
fn allocateStepBound(
    realm: *Realm,
    stack: *JSObject,
    impl: NativeFn,
    name: []const u8,
) NativeError!*JSFunction {
    const inner = realm.heap.allocateFunctionNative(realm, impl, 1, name) catch return error.OutOfMemory;
    inner.proto = realm.intrinsics.function_prototype;
    inner.has_construct = false;
    const outer = realm.heap.allocateFunctionNative(realm, boundAdoptTrampoline, 1, name) catch return error.OutOfMemory;
    outer.proto = realm.intrinsics.function_prototype;
    outer.has_construct = false;
    realm.heap.setBoundTarget(outer, inner);
    realm.heap.setBoundThis(outer, heap_mod.taggedObject(stack));
    return outer;
}

/// §9.5.4 step 2.b — onFulfilled reaction for one disposer step.
/// `this_value` is the stack (bound). Invoke `resources[--cursor]`'s
/// dispose method; return its return value so a thenable is awaited
/// by the next `.then` reaction in the chain.
fn asyncStepFulfilledImpl(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = args;
    const stack = heap_mod.valueAsPlainObject(this_value) orelse return Value.undefined_;
    return runNextDisposer(realm, stack);
}

/// §9.5.4 step 2.b — onRejected reaction for one disposer step.
/// Merges the previous step's rejection into `pending_error`
/// (wrapping via SuppressedError when one is already in flight),
/// then proceeds with the next disposer just like the fulfilled
/// path.
fn asyncStepRejectedImpl(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const stack = heap_mod.valueAsPlainObject(this_value) orelse return Value.undefined_;
    const ext = stack.extension orelse return Value.undefined_;
    const walk = ext.async_dispose_walk orelse return Value.undefined_;
    const reason = if (args.len > 0) args[0] else Value.undefined_;
    // §9.5.4 step 2.b.iv-vi — if a pending throw is already in
    // flight, the new rejection becomes [[Error]] of a fresh
    // SuppressedError whose [[Suppressed]] is the prior throw.
    if (walk.has_pending_error) {
        const wrapped = makeSuppressedError(realm, reason, walk.pending_error) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
        };
        walk.pending_error = wrapped;
    } else {
        walk.pending_error = reason;
        walk.has_pending_error = true;
    }
    // A disposer contributed — clear the external-seed marker so
    // `finalizeSettle` propagates the (possibly wrapped) throw.
    walk.external_seed_only = false;
    // Card-marking barrier: a (possibly young) pending error now lives
    // in the walk on a (possibly mature) stack.
    stack.noteInternalSlotWrite();
    return runNextDisposer(realm, stack);
}

/// Advance the cursor by one and invoke the disposer at
/// `resources[cursor]`. Returns:
///   - the disposer's return value (possibly a thenable) on
///     normal completion;
///   - `error.NativeThrew` with `realm.pending_exception` set on
///     a synchronous throw — the next `.then`'s onRejected
///     (`asyncStepRejectedImpl`) catches and stashes.
fn runNextDisposer(realm: *Realm, stack: *JSObject) NativeError!Value {
    const ext = stack.extension orelse return Value.undefined_;
    const walk = ext.async_dispose_walk orelse return Value.undefined_;
    // The chain only emits one .then(step) per REAL (non-ghost)
    // resource. Each step here must therefore advance past any
    // intervening ghost records (the LIFO-walk equivalent of
    // skipping null/undefined slots) until it lands on the next
    // real one. Ghost records are appended for `await using x =
    // null/undefined` per §9.5.3 step 1.b; they contribute only
    // to the `needsAwait = true` semantics §9.5.4 step 3.f, which
    // the chain's terminal `.then(finalize)` reaction already
    // satisfies as a single microtask hop.
    while (walk.cursor > 0) {
        walk.cursor -= 1;
        const rec = walk.resources.items[walk.cursor];
        if (rec.dispose_method.isUndefined()) continue;
        const method_fn = heap_mod.valueAsFunction(rec.dispose_method) orelse continue;
        const lantern = @import("../lantern/interpreter.zig");
        const outcome = lantern.callJSFunction(realm.allocator, realm, method_fn, rec.resource, &.{}) catch |err| switch (err) {
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
    return Value.undefined_;
}

/// Terminal-fulfilled reaction — invoked when the last step
/// `.then` fulfilled (no LAST disposer threw OR the LAST step_r
/// recovered into a normal completion). Settles outer with
/// `pending_error` if one's in flight (from an EARLIER step_r),
/// fulfilled-with-undefined otherwise.
fn asyncFinalizeFulfilledImpl(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    _ = args;
    return finalizeSettle(realm, this_value);
}

/// Terminal-rejected reaction — invoked when the LAST disposer
/// threw and no step_r reaction sat between it and the finalize.
/// Stash `args[0]` (with SuppressedError wrapping if a prior
/// throw is already in flight) before settling — same beat as
/// `asyncStepRejectedImpl`, minus the cursor advance.
fn asyncFinalizeRejectedImpl(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
    const stack = heap_mod.valueAsPlainObject(this_value) orelse return Value.undefined_;
    const ext = stack.extension orelse return Value.undefined_;
    const walk = ext.async_dispose_walk orelse return Value.undefined_;
    const reason = if (args.len > 0) args[0] else Value.undefined_;
    // §9.5.4 step 2.b.iv-vi — same wrapping rule as step_rejected.
    if (walk.has_pending_error) {
        const wrapped = makeSuppressedError(realm, reason, walk.pending_error) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
        };
        walk.pending_error = wrapped;
    } else {
        walk.pending_error = reason;
        walk.has_pending_error = true;
    }
    // Same as step_rejected — a disposer contributed.
    walk.external_seed_only = false;
    // Card-marking barrier: a (possibly young) pending error now lives
    // in the walk on a (possibly mature) stack.
    stack.noteInternalSlotWrite();
    return finalizeSettle(realm, this_value);
}

/// Common settle epilogue: outer rejected with `pending_error` if
/// any, fulfilled-with-undefined otherwise. Frees the walk struct
/// once outer is settled.
fn finalizeSettle(realm: *Realm, this_value: Value) NativeError!Value {
    const stack = heap_mod.valueAsPlainObject(this_value) orelse return Value.undefined_;
    const ext = stack.extension orelse return Value.undefined_;
    const walk = ext.async_dispose_walk orelse return Value.undefined_;

    const outer_obj = heap_mod.valueAsPlainObject(walk.outer) orelse return Value.undefined_;
    // `settlePromiseInternal` is the "settle + fire reactions" path —
    // raw `Heap.settlePromise` only updates the typed slot and would
    // leave any user `.then(success, fail)` reaction stranded on the
    // pending queue (the chain in `startAsyncDisposeWalk` is internal,
    // but user code can `disposeAsync().then(...)` between the
    // synchronous return and the first microtask drain).
    const lpromise = @import("../lantern/promise.zig");
    // When `external_seed_only` is still set, `pending_error`
    // was provided by the caller (mode 1 of `dispose_stack_async`)
    // and NO disposer threw. The outer Promise must fulfil with
    // undefined — the surrounding bytecode re-throws the original.
    // A disposer throw clears `external_seed_only` so the (possibly
    // wrapped) pending_error becomes the rejection.
    const propagate_pending = walk.has_pending_error and !walk.external_seed_only;
    if (propagate_pending) {
        lpromise.settlePromiseInternal(realm, outer_obj, .rejected, walk.pending_error) catch return error.OutOfMemory;
    } else {
        lpromise.settlePromiseInternal(realm, outer_obj, .fulfilled, Value.undefined_) catch return error.OutOfMemory;
    }
    // Drop the walk — resources are exhausted and the outer
    // Promise is now settled. Clearing here lets GC reclaim the
    // snapshot + pending throw on the next minor cycle.
    ext.async_dispose_walk = null;
    walk.deinit(realm.allocator);
    return Value.undefined_;
}

/// Build `new SuppressedError(error, suppressed)` per §20.5.x.
/// Mirrors the §27.3 sync helper — kept local to the async file
/// so the §27.4 walk doesn't reach into §27.3's private namespace.
fn makeSuppressedError(realm: *Realm, err_v: Value, suppressed_v: Value) !Value {
    const proto = realm.intrinsics.suppressed_error_prototype.?;
    const instance = try realm.heap.allocateObject();
    realm.heap.setObjectPrototype(instance, proto);
    instance.brand.has_error_data = true;
    try instance.setWithFlags(realm.allocator, "error", err_v, .{
        .writable = true,
        .enumerable = false,
        .configurable = true,
    });
    try instance.setWithFlags(realm.allocator, "suppressed", suppressed_v, .{
        .writable = true,
        .enumerable = false,
        .configurable = true,
    });
    return heap_mod.taggedObject(instance);
}

/// Build a fresh TypeError instance — used by the
/// IfAbruptRejectPromise paths that surface a brand-check failure
/// as a rejected Promise rather than a synchronous throw.
fn makeTypeError(realm: *Realm, msg: []const u8) NativeError!Value {
    return intrinsics.newTypeError(realm, msg) catch return error.OutOfMemory;
}

// §9.5.3 AddDisposableResource(disposable, V, hint = async-dispose).
//   Conceptual signature with an optional `method` for the
//   §27.4.3.2 .adopt() flow — used by `asyncDisposableStackAdopt`
//   inline since the wrapper construction is mostly bound-fn
//   bookkeeping. The bare form below is the §27.4.3.7 .use()
//   path: derive `method` from `GetDisposeMethod(V, async-dispose)`.
fn addAsyncDisposableResource(realm: *Realm, stack: *JSObject, value: Value) NativeError!void {
    // §9.5.3 step 1 — `.use(null)` / `.use(undefined)` on an
    // ASYNC stack appends a "ghost" record with empty method.
    // §9.5.4 step 3.f then sets `needsAwait = true` so the
    // disposeAsync Promise crosses at least one microtask
    // boundary (matches `await null` / `await undefined`).
    // test262 `built-ins/AsyncDisposableStack/prototype/
    // disposeAsync/explicit-await-for-{null,undefined}.js`.
    if (value.isUndefined() or value.isNull()) {
        const ext_list = try stack.disposableResourcesPtr(realm.allocator);
        ext_list.append(realm.allocator, .{
            .resource = Value.undefined_,
            .hint = .async_dispose,
            .dispose_method = Value.undefined_,
        }) catch return error.OutOfMemory;
        return;
    }

    // §9.5.2 GetDisposeMethod(V, async-dispose):
    //   1.a. Let method be ? GetMethod(V, @@asyncDispose).
    //   1.b. If method is undefined,
    //        Let method be ? GetMethod(V, @@dispose).
    //        Then ASYNC-WRAP: invoke and Promise.resolve the
    //        return value. The wrap is performed implicitly by
    //        the .then-chain in startAsyncDisposeWalk — the sync
    //        method's return value flows through .then which
    //        Promise.resolves it.
    const resource_obj = heap_mod.valueAsPlainObject(value) orelse {
        return throwTypeError(realm, "AsyncDisposableStack.prototype.use: value is not an object");
    };
    var hint: DisposableHint = .async_dispose;
    var method_v = try intrinsics.getPropertyChain(realm, resource_obj, "@@asyncDispose");
    if (method_v.isUndefined() or method_v.isNull()) {
        method_v = try intrinsics.getPropertyChain(realm, resource_obj, "@@dispose");
        hint = .sync_dispose;
    }
    if (method_v.isUndefined() or method_v.isNull()) {
        return throwTypeError(realm, "AsyncDisposableStack.prototype.use: value has no Symbol.asyncDispose or Symbol.dispose method");
    }
    if (heap_mod.valueAsFunction(method_v) == null) {
        return throwTypeError(realm, "AsyncDisposableStack.prototype.use: dispose method is not callable");
    }
    const ext_list = try stack.disposableResourcesPtr(realm.allocator);
    ext_list.append(realm.allocator, .{
        .resource = value,
        .hint = hint,
        .dispose_method = method_v,
    }) catch return error.OutOfMemory;
}
