//! Promise + async-function/async-generator resumption — extracted
//! from `interpreter.zig` to keep the dispatch-loop file focused.
//!
//! Hosts the microtask drainer (`drainMicrotasks`), the Promise
//! capability + reaction plumbing (`settlePromiseInternal`,
//! `resolvePromiseWithValue`, `wrapInPromise`), and the
//! resumption hooks that pump suspended async bodies on each
//! settled await: `resumeAsyncFunction`, `resumeAsyncGeneratorOnSettle`,
//! and `resumeGenerator`.
//!
//! Callbacks back into interpreter.zig: `callJSFunction`,
//! `callJSFunctionAsSuper`, `unwindThrow`, `runFrames` — every
//! resumption ultimately re-enters the dispatch loop.

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
const shared_data_block = @import("../shared_data_block.zig");
const Chunk = @import("../../bytecode/chunk.zig").Chunk;
const module_mod = @import("../module.zig");

// Circular back to interpreter.zig for the dispatch entry points,
// shared types, and the call machinery the resumers re-enter.
const lantern = @import("interpreter.zig");
const CallFrame = lantern.CallFrame;
const RunError = lantern.RunError;
const RunResult = lantern.RunResult;
const runFrames = lantern.runFrames;
const callJSFunction = lantern.callJSFunction;
const callJSFunctionAsSuper = lantern.callJSFunctionAsSuper;
const callValue = lantern.callValue;
const constructValue = lantern.constructValue;
const unwindThrow = lantern.unwindThrow;
const consumePendingException = lantern.consumePendingException;
const makeTypeError = lantern.makeTypeError;
const makeRangeError = lantern.makeRangeError;
const loadModule = lantern.loadModule;

// Generator+async-gen helpers used by the async-gen task pump
// inside drainMicrotasks. Live in `generator.zig`.
const generator = @import("generator.zig");
const asyncGeneratorResumeNext = generator.asyncGeneratorResumeNext;
const resumeAsyncGenBody = generator.resumeAsyncGenBody;
const settleAsyncGenRequest = generator.settleAsyncGenRequest;
const rejectAsyncGenRequest = generator.rejectAsyncGenRequest;
const isSyncRejectedPromise = generator.isSyncRejectedPromise;
const genResultObject = generator.genResultObject;

/// Wrap `value` in a Promise — used by the Return op when the
/// frame's `wrap_return_in_promise` flag is set: `async function`
/// bodies `return v` into `Promise.resolve(v)`, uncaught throws
/// into `Promise.reject(...)`. Spec §27.7 AsyncFunctionStart:
/// an async function always returns a Promise; the body's normal
/// completion fulfils it, an abrupt completion rejects it. The
/// state lives in the typed `[[PromiseState]]` slot, not a
/// property — so the Promise can't be forged from JS.
pub fn wrapInPromise(realm: *Realm, fulfilled: bool, value: Value) !Value {
    const obj = try realm.heap.allocateObject();
    realm.heap.setObjectPrototype(obj, realm.intrinsics.promise_prototype);
    realm.heap.settlePromise(obj, if (fulfilled) .fulfilled else .rejected, value);
    return heap_mod.taggedObject(obj);
}

/// Drain the realm's microtask queue: invoke each queued
/// callback with its argument. Re-entered from `await` opcode
/// sites + at every external boundary (the CLI / test262
/// runner). Microtasks queued during draining run before this
/// call returns (FIFO), matching §9.4.
/// §25.4.1.4 host-driven TriggerTimeout / wake: settle every pending
/// async waiter whose deadline passed or that a cross-agent `notify`
/// woke — resolve its Promise "ok" (woken) or "timed-out" and free the
/// block node. Returns whether any fired so a drain loop re-runs to
/// propagate the resolutions. A no-op (one length check) when nothing is
/// pending. Driven from `drainMicrotasks` (so a main-agent poll loop's
/// timeout fires) and from the test262 agent pool's idle loop.
pub fn fireExpiredAsyncWaits(allocator: std.mem.Allocator, realm: *Realm) RunError!bool {
    if (realm.pending_async_waits.items.len == 0) return false;
    const now = shared_data_block.monoNowMs();
    const scope = realm.heap.openScope() catch return error.OutOfMemory;
    defer scope.close();
    var fired = false;
    var i: usize = 0;
    while (i < realm.pending_async_waits.items.len) {
        const entry = realm.pending_async_waits.items[i];
        if (entry.node.woken.load(.acquire) or now >= entry.deadline_ms) {
            _ = realm.pending_async_waits.orderedRemove(i);
            const ok = entry.block.settleAndFreeAsyncWaiter(entry.node);
            const resolve_fn = heap_mod.valueAsFunction(entry.resolve) orelse continue;
            const str = realm.heap.allocateString(if (ok) "ok" else "timed-out") catch return error.OutOfMemory;
            const arg = Value.fromString(str);
            scope.push(arg) catch {};
            _ = try callJSFunction(allocator, realm, resolve_fn, Value.undefined_, &.{arg});
            fired = true;
        } else {
            i += 1;
        }
    }
    return fired;
}

pub fn drainMicrotasks(allocator: std.mem.Allocator, realm: *Realm) RunError!void {
    // §9.10.4.2 ClearKeptObjects — the synchronous block that
    // queued whatever's about to drain just ended; release any
    // §9.10 [[KeptAlive]] entries the `WeakRef` constructor /
    // `deref` pinned during it, so the queued microtask (each its
    // own job per §9.5.5) starts with an empty keep-alive list.
    // Without this, a `WeakRef.prototype.deref` that pinned its
    // target in a top-level script would keep the target alive
    // through every microtask, observably different from V8 / JSC /
    // SpiderMonkey.
    realm.clearKeptObjects();
    while (realm.microtask_queue.items.len > 0) {
        // Host-drive any §25.4.1.4 waitAsync timeout/wake whose moment
        // arrived during this drain (e.g. a main-agent `setTimeout` poll
        // loop keeps the queue non-empty while real time advances toward
        // the wait's deadline).
        _ = fireExpiredAsyncWaits(allocator, realm) catch {};
        // §16.2.1.10 EvaluateImportCall — a deferred dynamic-import
        // job (`.module_import`) must not run while a synchronous
        // module-graph DFS is still in progress (`module_load_depth
        // > 0`). `module_link_complete` drains the queue mid-DFS to
        // settle async-module dependencies; if it ran a queued
        // `import()` job there, that job would observe a sibling
        // module mid-evaluation and "preempt DFS order". Skip past
        // any `.module_import` tasks at the front and pick the first
        // non-import task instead; the import jobs stay queued and
        // run once the outermost evaluation has finished (depth 0).
        var idx: usize = 0;
        if (realm.module_load_depth > 0) {
            while (idx < realm.microtask_queue.items.len and
                realm.microtask_queue.items[idx].kind == .module_import) : (idx += 1)
            {}
            // Nothing but deferred import jobs left — stop draining;
            // they'll run when the DFS unwinds to depth 0.
            if (idx >= realm.microtask_queue.items.len) break;
        }
        const task = realm.microtask_queue.orderedRemove(idx);
        // §9.10.4.2 ClearKeptObjects between microtasks — each
        // microtask is its own job per §9.5.5, so any §9.10
        // [[KeptAlive]] entries the previous task pinned via
        // `WeakRef.prototype.deref` are released before the next
        // task runs. `defer` fires whether this iteration falls
        // through naturally or via one of the `continue`s in the
        // switch arms below.
        defer realm.clearKeptObjects();
        switch (task.kind) {
            .callback => {
                const callback = heap_mod.valueAsFunction(task.callback) orelse continue;
                const args = [_]Value{task.arg};
                const outcome = try callJSFunction(allocator, realm, callback, Value.undefined_, &args);
                switch (outcome) {
                    .value, .yielded => {},
                    .thrown => {
                        // Spec: an unhandled rejection from a microtask
                        // becomes a HostPromiseRejectionTracker call.
                        // We just discard for now; user-installed
                        // promise-rejection-tracking is later.
                    },
                }
            },
            .async_resume => {
                const gen = task.async_gen orelse continue;
                if (gen.is_async_generator) {
                    // §27.6.3.4 — body suspended on an await for
                    // the head request. Resume the body with the
                    // settled value (or throw), then continue the
                    // drain so the next request (if any) gets
                    // picked up after the body yields / returns
                    // / throws.
                    try resumeAsyncGeneratorOnSettle(allocator, realm, gen, task.arg, task.async_throws);
                } else {
                    try resumeAsyncFunction(allocator, realm, gen, task.arg, task.async_throws);
                }
            },
            .async_gen_return_after_await => {
                // §27.6.3.7 step 8.b — the awaited return-value is
                // ready. Drive the body's return-completion at the
                // suspended yield site. `task.arg` carries the
                // already-Awaited value (the await mechanism
                // unwrapped any Promise / thenable before queueing
                // this task).
                const gen = task.async_gen orelse continue;
                // If the gen body is already closed, settle the
                // head `.return_value` request with the awaited
                // value (§27.6.3.7 step 10 — AsyncGenerator
                // CompleteStep on a normal Await result).
                // Re-dispatching through `asyncGeneratorResumeNext`
                // would loop: the completed-state branch routes
                // back through `awaitForReturnCompletion`.
                if (gen.state == .completed) {
                    gen.async_state = .completed;
                    if (gen.queue.items.len > 0) {
                        const req = gen.queue.orderedRemove(0);
                        if (task.async_throws) {
                            try rejectAsyncGenRequest(realm, req.capability_promise, task.arg);
                        } else {
                            try settleAsyncGenRequest(realm, req.capability_promise, task.arg, true);
                        }
                    }
                    try asyncGeneratorResumeNext(allocator, realm, gen);
                    continue;
                }
                if (task.async_throws) {
                    // Awaiting the return-value rejected (e.g.
                    // the user passed a rejected Promise as the
                    // .return() argument, or a poisoned
                    // `constructor` getter on a Promise made
                    // PromiseResolve abrupt). Spec path
                    // branches on state:
                    //
                    //   • suspendedYield — §27.6.3.8 step 13-14:
                    //     the abrupt Await surfaces as a throw
                    //     completion at the yield site so the
                    //     body's `try { yield } catch (e)` can
                    //     observe it.
                    //
                    //   • suspendedStart / completed — §27.6.3.7
                    //     AsyncGeneratorAwaitReturn step 7:
                    //     close the gen, reject the request,
                    //     drain.
                    if (gen.state == .suspended) {
                        if (gen.queue.items.len == 0) continue;
                        const req = gen.queue.items[0];
                        gen.async_state = .executing;
                        const outcome = resumeAsyncGenBody(allocator, realm, gen, .{ .throw_value = task.arg }) catch |err| {
                            return err;
                        };
                        if (gen.async_state == .suspended_await) {
                            // Body re-suspended on another
                            // await inside a catch / finally —
                            // leave the request and let the
                            // resume microtask continue.
                            continue;
                        }
                        _ = gen.queue.orderedRemove(0);
                        switch (outcome) {
                            .yielded => |raw| {
                                gen.async_state = .suspended_await;
                                if (isSyncRejectedPromise(raw)) {
                                    gen.state = .completed;
                                    try realm.enqueueAsyncGenYield(gen, req.capability_promise, heap_mod.valueAsPlainObject(raw).?.promise_value, false, true);
                                } else {
                                    try realm.enqueueAsyncGenYield(gen, req.capability_promise, raw, false, false);
                                }
                            },
                            .value => |v| {
                                gen.state = .completed;
                                gen.async_state = .completed;
                                try settleAsyncGenRequest(realm, req.capability_promise, v, true);
                                try asyncGeneratorResumeNext(allocator, realm, gen);
                            },
                            .thrown => |ex| {
                                gen.state = .completed;
                                gen.async_state = .completed;
                                try rejectAsyncGenRequest(realm, req.capability_promise, ex);
                                try asyncGeneratorResumeNext(allocator, realm, gen);
                            },
                        }
                        continue;
                    }
                    if (gen.queue.items.len > 0) {
                        const req = gen.queue.orderedRemove(0);
                        gen.state = .completed;
                        gen.async_state = .completed;
                        try rejectAsyncGenRequest(realm, req.capability_promise, task.arg);
                    }
                    try asyncGeneratorResumeNext(allocator, realm, gen);
                    continue;
                }
                if (gen.queue.items.len == 0) continue;
                const req = gen.queue.items[0];
                gen.async_state = .executing;
                const outcome = resumeAsyncGenBody(allocator, realm, gen, .{ .return_value = task.arg }) catch |err| {
                    return err;
                };
                if (gen.async_state == .suspended_await) {
                    // Body re-suspended on another await inside a
                    // `finally` — leave the request and let the
                    // resume microtask continue.
                    continue;
                }
                _ = gen.queue.orderedRemove(0);
                switch (outcome) {
                    .yielded => |raw| {
                        gen.async_state = .suspended_await;
                        if (isSyncRejectedPromise(raw)) {
                            gen.state = .completed;
                            try realm.enqueueAsyncGenYield(gen, req.capability_promise, heap_mod.valueAsPlainObject(raw).?.promise_value, false, true);
                        } else {
                            try realm.enqueueAsyncGenYield(gen, req.capability_promise, raw, false, false);
                        }
                    },
                    .value => |v| {
                        gen.state = .completed;
                        gen.async_state = .completed;
                        try settleAsyncGenRequest(realm, req.capability_promise, v, true);
                        try asyncGeneratorResumeNext(allocator, realm, gen);
                    },
                    .thrown => |ex| {
                        gen.state = .completed;
                        gen.async_state = .completed;
                        try rejectAsyncGenRequest(realm, req.capability_promise, ex);
                        try asyncGeneratorResumeNext(allocator, realm, gen);
                    },
                }
            },
            .async_gen_yield => {
                // §27.6.3.6 AsyncGeneratorYield — the deferred
                // half of `Await(value); CompleteStep(...)`.
                // Settle the capability and continue the drain.
                // If the body had completed (.value / .thrown
                // outcome) we left state at suspended_await so
                // the drain wouldn't run early; flip to
                // completed before resuming so the drain
                // settles any buffered follow-on requests with
                // `done: true`.
                const gen = task.async_gen orelse continue;
                const cap = task.agy_cap_promise orelse continue;
                // §27.6.3.7 step 7.b.vi (`yield*` delegation) and
                // §27.6.3.6 AsyncGeneratorYield — the spec settles
                // the request capability with `{value, done}` where
                // `value` is whatever the body passed to Yield.
                // `Yield` itself does NOT Await — for plain
                // `yield X` in an async gen the compiler emits an
                // explicit `Await(X)` before `gen_yield` (§27.6.3.6
                // Promise-of-Promise unwrap lives in that step's
                // microtask, not here), and for `yield* iter` the
                // value comes from the inner iter's already-Awaited
                // step result, which intentionally surfaces a
                // Promise as the consumer-facing `.value` (see
                // yield-star-promise-not-unwrapped.js). So we
                // settle the capability with `task.arg` as-is.
                const settle_value = task.arg;
                const settle_reject = task.agy_reject;
                if (settle_reject) {
                    settlePromiseInternal(realm, cap, .rejected, settle_value) catch return error.OutOfMemory;
                } else {
                    const result = genResultObject(realm, settle_value, task.agy_done) catch return error.OutOfMemory;
                    settlePromiseInternal(realm, cap, .fulfilled, result) catch return error.OutOfMemory;
                }
                // §27.6.3 — body's GeneratorState reflects
                // completion; sync async_state if the underlying
                // generator already moved on.
                if (gen.state == .completed) {
                    gen.async_state = .completed;
                } else if (gen.async_state == .suspended_await) {
                    // Yield-Await fired; resume the drain with
                    // a logical `suspended_yield` (the body is
                    // parked at the yield, ready for the next
                    // request).
                    gen.async_state = .suspended_yield;
                }
                try asyncGeneratorResumeNext(allocator, realm, gen);
            },
            .promise_reaction => {
                try runPromiseReaction(allocator, realm, task.reaction_handler, task.arg, task.reaction_result, task.reaction_was_rejected);
            },
            .thenable_job => {
                try runThenableJob(allocator, realm, task.reaction_result, task.arg, task.reaction_handler);
            },
            .module_import => {
                try runModuleImportJob(
                    allocator,
                    realm,
                    task.callback,
                    task.reaction_result,
                    task.module_import_base,
                    task.module_import_attribute_type,
                );
            },
        }
    }
}

/// §13.3.10 / §16.2.1.10 EvaluateImportCall — the deferred
/// dynamic-import job. Runs `loadModule` (parse + link +
/// §16.2.1.5 InnerModuleEvaluation) for `specifier` and settles
/// `result_promise` with the module namespace, or rejects it
/// with the load/evaluation error. Deferring this to a job
/// means a module already in the importer's static graph has
/// been evaluated by the synchronous DFS before this runs, so
/// the dynamic import only observes it.
fn runModuleImportJob(
    allocator: std.mem.Allocator,
    realm: *Realm,
    specifier_v: Value,
    result_promise: Value,
    base_url: ?[]const u8,
    attribute_type: ?[]const u8,
) RunError!void {
    // `enqueueModuleImport` duped the attribute slice into queue-
    // owned memory (the enqueuing opcode's copy is long gone by
    // now). This job is its sole consumer, so free it here on
    // every exit path. `loadModule` only ever copies the slice
    // (the §16.2.1.4 cache key is an independent `allocPrint`), so
    // releasing it after the load is safe.
    defer if (attribute_type) |t| realm.allocator.free(t);
    const promise_obj = heap_mod.valueAsPlainObject(result_promise) orelse return;
    if (!specifier_v.isString()) {
        const ex = try makeTypeError(realm, "import specifier is not a string");
        try settlePromiseInternal(realm, promise_obj, .rejected, ex);
        return;
    }
    const spec_str: *JSString = @ptrCast(@alignCast(specifier_v.asString()));

    // Pin the specifier + result Promise across the load (the
    // module body re-enters JS and may trigger GC).
    const scope = realm.heap.openScope() catch return error.OutOfMemory;
    defer scope.close();
    scope.push(specifier_v) catch return error.OutOfMemory;
    scope.push(result_promise) catch return error.OutOfMemory;

    const outcome = loadModule(allocator, realm, spec_str.flatBytes(), base_url, attribute_type) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            const ex = try makeTypeError(realm, "module load failed");
            try settlePromiseInternal(realm, promise_obj, .rejected, ex);
            return;
        },
    };
    if (outcome.threw) {
        try settlePromiseInternal(realm, promise_obj, .rejected, outcome.value);
        return;
    }

    // §16.2.1.11 ContinueDynamicImport — the import() Promise
    // settles with the namespace once the module's evaluation
    // Promise settles. Sync modules are already `.evaluated` so
    // `outcome.value` is the final namespace. An async module
    // (top-level await) holds a pending `evaluation_promise`;
    // per spec the import() Promise must mirror its settlement —
    // hook a reaction onto it rather than draining inline (a
    // drain here would settle nested import jobs inner-first,
    // breaking the per-call ordering two `import()`s of the same
    // waiting module rely on).
    if (outcome.mr) |dep_mr| {
        if (dep_mr.state == .evaluating_async) {
            if (heap_mod.valueAsPlainObject(dep_mr.evaluation_promise)) |eval_p| {
                if (eval_p.isPromise()) {
                    // The namespace object identity is stable from
                    // allocation; resolve it once and chain it on
                    // fulfilment via a bound `return-this` handler
                    // so the import() Promise fulfils with the
                    // namespace (not the body's completion value),
                    // and rejects straight through on rejection.
                    const ns_obj = module_mod.getModuleNamespace(realm, dep_mr) catch return error.OutOfMemory;
                    const ns_value = heap_mod.taggedObject(ns_obj);
                    const fulfill_handler = makeReturnThisHandler(realm, ns_value) catch return error.OutOfMemory;
                    switch (eval_p.promise_state) {
                        .fulfilled => try realm.enqueuePromiseReaction(fulfill_handler, eval_p.promise_value, result_promise, false),
                        .rejected => try realm.enqueuePromiseReaction(Value.undefined_, eval_p.promise_value, result_promise, true),
                        .pending => {
                            const reactions = try eval_p.promiseReactionsPtr(realm.allocator);
                            try reactions.append(realm.allocator, .{
                                .on_fulfilled = fulfill_handler,
                                .on_rejected = Value.undefined_,
                                .result_promise = result_promise,
                            });
                        },
                        .none => try settlePromiseInternal(realm, promise_obj, .fulfilled, ns_value),
                    }
                    return;
                }
            }
            // Async module without a usable evaluation Promise —
            // fall through and resolve with the partial namespace.
            try settlePromiseInternal(realm, promise_obj, .fulfilled, outcome.value);
            return;
        } else if (dep_mr.state == .errored) {
            try settlePromiseInternal(realm, promise_obj, .rejected, dep_mr.error_value);
            return;
        }
    }
    // Sync module — `outcome.value` is the final namespace.
    try settlePromiseInternal(realm, promise_obj, .fulfilled, outcome.value);
}

/// Build a bound native function that, when invoked, returns the
/// captured `value` regardless of its argument. Used by the
/// deferred dynamic-import job (§16.2.1.11) as the `onFulfilled`
/// reaction on an async module's evaluation Promise: the reaction
/// fires with the module body's completion value, but the
/// import() Promise must fulfil with the module *namespace*, so
/// the handler discards its argument and returns the captured
/// namespace. Implemented as a bound function (`bound_this` =
/// the value, `bound_target` = a `this`-returning native) so no
/// per-call closure state is needed.
fn makeReturnThisHandler(realm: *Realm, value: Value) !Value {
    const impl = try realm.heap.allocateFunctionNative(realm, returnThisValueNative, 1, "");
    impl.proto = realm.intrinsics.function_prototype;
    impl.has_construct = false;
    const bound = try realm.heap.allocateFunctionNative(realm, returnThisValueNative, 1, "");
    bound.proto = realm.intrinsics.function_prototype;
    bound.has_construct = false;
    realm.heap.setBoundTarget(bound, impl);
    realm.heap.setBoundThis(bound, value);
    return heap_mod.taggedFunction(bound);
}

/// Native body for `makeReturnThisHandler` — returns the
/// receiver. As a bound function with `bound_this` set, the
/// dispatch substitutes the captured value for `this_value`.
fn returnThisValueNative(realm: *Realm, this_value: Value, args: []const Value) @import("../function.zig").NativeError!Value {
    _ = realm;
    _ = args;
    return this_value;
}

/// §27.2.1.3 PromiseResolveThenableJob — call
/// `thenAction.call(thenable, resolveFn, rejectFn)` where
/// resolveFn/rejectFn settle `outer_promise`. An abrupt
/// completion from the then invocation rejects `outer_promise`
/// with the thrown value (unless `outer_promise` is already
/// settled — the bound trampoline guards that).
fn runThenableJob(
    allocator: std.mem.Allocator,
    realm: *Realm,
    outer_promise: Value,
    thenable: Value,
    then_fn_v: Value,
) RunError!void {
    const outer_obj = heap_mod.valueAsPlainObject(outer_promise) orelse return;
    const then_fn = heap_mod.valueAsFunction(then_fn_v) orelse {
        try settlePromiseInternal(realm, outer_obj, .fulfilled, thenable);
        return;
    };
    // Pin outer + thenable across the call.
    const scope = realm.heap.openScope() catch return error.OutOfMemory;
    defer scope.close();
    scope.push(outer_promise) catch return error.OutOfMemory;
    scope.push(thenable) catch return error.OutOfMemory;
    scope.push(then_fn_v) catch return error.OutOfMemory;

    // Build bound-trampoline resolve/reject pair targeting outer_promise.
    // §27.2.1.3 Promise Resolve/Reject Functions are anonymous (`name: ""`),
    // length 1, and NOT constructors (`hasOwnProperty(resolveFn, "prototype")
    // === false`; `new resolveFn()` throws). The matching pair installed by
    // the executor (`builtins/promise.zig` `newPromiseCapability`) already
    // stamps `has_construct = false`; this thenable-job path must too,
    // otherwise a thenable that does `then(resolve, reject) { resolve(reject); }`
    // surfaces a constructor-flagged reject to user code (test262 catches it
    // via `isConstructor(reject)` from `harness/isConstructor.js`, which
    // tries `Reflect.construct(function(){}, [], reject)`).
    const promise_mod = @import("../builtins/promise.zig");
    const resolve_impl = realm.heap.allocateFunctionNative(realm, promise_mod.promiseResolveImplExported, 1, "") catch return error.OutOfMemory;
    resolve_impl.proto = realm.intrinsics.function_prototype;
    resolve_impl.has_construct = false;
    const resolve_fn = realm.heap.allocateFunctionNative(realm, promise_mod.boundResolveTrampolineExported, 1, "") catch return error.OutOfMemory;
    resolve_fn.proto = realm.intrinsics.function_prototype;
    resolve_fn.has_construct = false;
    realm.heap.setBoundTarget(resolve_fn, resolve_impl);
    realm.heap.setBoundThis(resolve_fn, outer_promise);

    const reject_impl = realm.heap.allocateFunctionNative(realm, promise_mod.promiseRejectImplExported, 1, "") catch return error.OutOfMemory;
    reject_impl.proto = realm.intrinsics.function_prototype;
    reject_impl.has_construct = false;
    const reject_fn = realm.heap.allocateFunctionNative(realm, promise_mod.boundResolveTrampolineExported, 1, "") catch return error.OutOfMemory;
    reject_fn.proto = realm.intrinsics.function_prototype;
    reject_fn.has_construct = false;
    realm.heap.setBoundTarget(reject_fn, reject_impl);
    realm.heap.setBoundThis(reject_fn, outer_promise);

    // §27.2.2.2 NewPromiseResolveThenableJob creates a FRESH pair of
    // resolving functions (CreateResolvingFunctions) with their own
    // [[AlreadyResolved]] = false. Cynic models [[AlreadyResolved]] as a
    // single promise-level flag, which the ORIGINAL resolve function
    // already set true before enqueuing this job — so without resetting
    // it the job's resolve(v) would no-op and the promise would never
    // settle. The original pair has already fired; the job's pair (these
    // trampolines) gets the clean slate the spec mandates. The
    // exception-after-resolve guard below re-reads the flag, which the
    // job's resolve sets true again if the thenable resolved first.
    outer_obj.promise_already_resolved = false;
    const args = [_]Value{ heap_mod.taggedFunction(resolve_fn), heap_mod.taggedFunction(reject_fn) };
    const outcome = callJSFunction(allocator, realm, then_fn, thenable, &args) catch |err| switch (err) {
        else => return err,
    };
    switch (outcome) {
        .value, .yielded => {},
        .thrown => |ex| {
            // §27.2.1.3 step 6 — call rejectFn(reason). The
            // trampolines guard against double-settlement, so if
            // user code already resolved/rejected this is a
            // no-op.
            // §27.2.1.3 alreadyResolved guard — `then` may have
            // already invoked resolve(thenable) (which leaves the
            // outer Promise pending until a nested job runs); the
            // subsequent throw must NOT reject. `exception-after-
            // resolve-in-thenable-job.js`.
            if (!outer_obj.promise_already_resolved) {
                outer_obj.promise_already_resolved = true;
                try settlePromiseInternal(realm, outer_obj, .rejected, ex);
            }
        },
    }
}

/// §27.2.1.4 PromiseReactionJob — invoke `handler` (or
/// propagate when absent) with `value`, settle `result_promise`
/// based on the outcome.
///
/// no handler & fulfilled → result resolved with value.
/// no handler & rejected → result rejected with value.
/// handler fulfilled → result resolved with handler(value).
/// handler rejected → result rejected with thrown value.
/// handler returns Promise → result mirrors that Promise.
fn runPromiseReaction(
    allocator: std.mem.Allocator,
    realm: *Realm,
    handler: Value,
    value: Value,
    result_promise: Value,
    was_rejected: bool,
) RunError!void {
    const result_obj = heap_mod.valueAsPlainObject(result_promise) orelse return;

    // The microtask was orderedRemove'd from the queue before
    // dispatch — `result_promise` and `value` no longer have a
    // queue-based root. The handler call below can re-enter JS
    // (and trigger GC). Pin them through a HandleScope so the
    // sub-Promise we're about to settle stays alive for the
    // handler return + settle.
    const scope = realm.heap.openScope() catch return error.OutOfMemory;
    defer scope.close();
    scope.push(result_promise) catch return error.OutOfMemory;
    scope.push(value) catch return error.OutOfMemory;
    scope.push(handler) catch return error.OutOfMemory;

    // No handler for this state — propagate value/state to result.
    if (handler.isUndefined() or heap_mod.valueAsFunction(handler) == null) {
        if (was_rejected) {
            try settlePromiseInternal(realm, result_obj, .rejected, value);
        } else {
            try settlePromiseInternal(realm, result_obj, .fulfilled, value);
        }
        return;
    }

    const handler_fn = heap_mod.valueAsFunction(handler).?;
    const args = [_]Value{value};
    const outcome = callJSFunction(allocator, realm, handler_fn, Value.undefined_, &args) catch |err| switch (err) {
        else => return err,
    };
    switch (outcome) {
        .value, .yielded => |v| {
            // §27.2.1.3.2 Promise Resolve Functions — route the
            // handler's return value through the full thenable-
            // resolution flow so a non-Promise thenable also
            // gets unwrapped (real Promise → chain; thenable →
            // PromiseResolveThenableJob; non-Object → fulfill).
            try resolvePromiseWithValue(realm, result_obj, v);
        },
        .thrown => |ex| {
            try settlePromiseInternal(realm, result_obj, .rejected, ex);
        },
    }
}

/// §27.2.1.3.2 Promise Resolve Functions, run with the
/// receiver-promise pinned. Used by `runPromiseReaction` and
/// other internal settlement paths where the value is *not*
/// flowing through the user-callable resolve trampoline.
pub fn resolvePromiseWithValue(realm: *Realm, target: *JSObject, v: Value) !void {
    if (target.promise_state != .pending) return;
    if (heap_mod.valueAsPlainObject(v)) |v_obj| {
        if (v_obj == target) {
            const intrinsics = @import("../intrinsics.zig");
            const ex = intrinsics.newTypeError(realm, "Chaining cycle detected for promise") catch return error.OutOfMemory;
            try settlePromiseInternal(realm, target, .rejected, ex);
            return;
        }
        if (v_obj.isPromise()) {
            // §27.2.1.3.2 step 11-13 — when `v` is a Promise, the spec
            // queues a PromiseResolveThenableJob that invokes
            // `v.then(resolveFn, rejectFn)`. Each `.then` call allocates
            // a fresh NewPromiseCapability via SpeciesConstructor, which
            // is observable when `v` (or `target`) is a user subclass of
            // Promise, or when `Promise.prototype.then` has been
            // monkey-patched. For vanilla Promise-to-vanilla-Promise
            // adoption the count is unobservable and the inline
            // reaction shortcut (`chainPromiseToInner`) is the
            // equivalent fast path — that's the hot `await` /
            // chain case so we keep the shortcut there.
            if (isVanillaPromiseChain(realm, target, v_obj)) {
                try chainPromiseToInner(realm, v_obj, target);
                return;
            }
            const intrinsics2 = @import("../intrinsics.zig");
            const then_v2 = intrinsics2.getPropertyChain(realm, v_obj, "then") catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => {
                    const ex = realm.pending_exception orelse Value.undefined_;
                    realm.pending_exception = null;
                    try settlePromiseInternal(realm, target, .rejected, ex);
                    return;
                },
            };
            if (target.promise_state != .pending) return;
            if (heap_mod.valueAsFunction(then_v2) == null) {
                try settlePromiseInternal(realm, target, .fulfilled, v);
                return;
            }
            try realm.enqueueThenableJob(heap_mod.taggedObject(target), v, then_v2);
            return;
        }
        const intrinsics = @import("../intrinsics.zig");
        const then_v = intrinsics.getPropertyChain(realm, v_obj, "then") catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                const ex = realm.pending_exception orelse Value.undefined_;
                realm.pending_exception = null;
                try settlePromiseInternal(realm, target, .rejected, ex);
                return;
            },
        };
        if (target.promise_state != .pending) return;
        if (heap_mod.valueAsFunction(then_v) == null) {
            try settlePromiseInternal(realm, target, .fulfilled, v);
            return;
        }
        try realm.enqueueThenableJob(heap_mod.taggedObject(target), v, then_v);
        return;
    }
    try settlePromiseInternal(realm, target, .fulfilled, v);
}

/// Fast-path predicate for §27.2.1.3.2 Promise Resolve Functions —
/// when both `target` and `v_obj` are vanilla Promise instances (their
/// immediate prototype is the realm's %PromisePrototype%) AND the
/// prototype's `then` slot still holds the built-in `Promise.prototype.
/// then` (matched by native callback pointer), the spec-mandated
/// `.then` invocation is observably equivalent to an inline
/// reaction enqueue — keep the `chainPromiseToInner` shortcut.
/// Subclasses and monkey-patched `Promise.prototype.then` need the
/// spec path so each `.then` allocation surfaces (§27.2.5.3
/// species-count fixtures).
pub const isVanillaPromiseChainExported = isVanillaPromiseChain;

fn isVanillaPromiseChain(realm: *Realm, target: *JSObject, v_obj: *JSObject) bool {
    const proto = realm.intrinsics.promise_prototype orelse return false;
    if (target.prototype != proto) return false;
    if (v_obj.prototype != proto) return false;
    // §27.2.1.3.2 step 7 — Get(resolution, "then") is observable.
    // An own `then` (data or accessor) on the inner Promise must
    // route through the generic thenable path so user code sees
    // the call. test262
    // built-ins/Promise/prototype/then/resolve-*-cstm-then.js
    // exercise this: a Promise instance with `.then = fn` set
    // directly.
    if (v_obj.hasOwn("then")) return false;
    // Inspect %PromisePrototype%.then — if it's not the original
    // built-in `promiseThen`, the user replaced it and the spec's
    // `.then` invocation is observable.
    const then_v = proto.get("then");
    const then_fn = heap_mod.valueAsFunction(then_v) orelse return false;
    const promise_mod = @import("../builtins/promise.zig");
    const cb = then_fn.native_callback orelse return false;
    if (cb != promise_mod.promiseThenExported) return false;
    return true;
}

/// Chain `outer`'s settlement to `inner`'s — when `inner`
/// settles, `outer` settles the same way with the same value.
/// Implemented by registering a no-handler reaction on `inner`
/// pointing at `outer`. Spec §27.2.1.3 PromiseResolveThenableJob.
fn chainPromiseToInner(realm: *Realm, inner: *JSObject, outer: *JSObject) !void {
    switch (inner.promise_state) {
        .fulfilled => {
            try realm.enqueuePromiseReaction(Value.undefined_, inner.promise_value, heap_mod.taggedObject(outer), false);
            return;
        },
        .rejected => {
            try realm.enqueuePromiseReaction(Value.undefined_, inner.promise_value, heap_mod.taggedObject(outer), true);
            return;
        },
        .pending, .none => {},
    }
    // Pending — register a no-handler reaction so settlement propagates.
    const reactions = try inner.promiseReactionsPtr(realm.allocator);
    try reactions.append(realm.allocator, .{
        .on_fulfilled = Value.undefined_,
        .on_rejected = Value.undefined_,
        .result_promise = heap_mod.taggedObject(outer),
    });
}

/// Re-enter `runFrames` to resume a suspended `async function`
/// generator with `sent_value` (the awaited Promise's settled
/// value, or — when `throws_in` is true — the rejection that
/// should be thrown inside the resumed frame).
///
/// The body either runs to a Return (settles `gen.result_promise`
/// fulfilled), throws uncaught (settles rejected), or hits another
/// pending `await` and re-suspends. In all three cases the
/// caller's view (the result Promise the async call returned) is
/// what changes — the resume itself doesn't communicate up to
/// any user code besides via Promise settlement.
pub fn resumeAsyncFunction(
    allocator: std.mem.Allocator,
    realm: *Realm,
    gen: *@import("../generator.zig").JSGenerator,
    sent_value: Value,
    throws_in: bool,
) RunError!void {
    if (gen.state == .completed) return;
    if (gen.state == .executing) return; // re-entrancy guard
    gen.state = .executing;

    // §16.2.1.5.1 [[IsAsync]] modules — restore the owning
    // module so `module_export` on resume finds the right
    // namespace. The original frame ran with
    // `realm.current_module = mr`, but the synchronous
    // suspend popped back to its caller and (eventually)
    // unwound the harness's `defer realm.current_module = …`.
    // The drain that calls into here happens with whatever
    // current_module the host had set; for an async-module
    // resume we need to thread it back through gen.
    const saved_module = realm.current_module;
    if (gen.owning_module) |om| realm.current_module = om;
    defer realm.current_module = saved_module;

    var frames: std.ArrayListUnmanaged(CallFrame) = .empty;
    defer {
        for (frames.items) |*f| if (f.owns_registers) realm.frame_pool.release(allocator, f.registers);
        frames.deinit(allocator);
    }

    try frames.append(allocator, .{
        .chunk = gen.chunk,
        .ip = gen.ip,
        .accumulator = sent_value,
        .registers = gen.registers,
        .env = gen.env,
        .this_value = gen.this_value,
        .home_object = gen.home_object,
        .home_function = gen.home_function,
        .argc = gen.argc,
        .generator = gen,
        // §8.3 — see `JSGenerator.realm`.
        .running_realm = gen.realm,
        .owns_registers = false,
    });

    // Rejected await: throw `sent_value` at the resume point.
    // unwindThrow walks the live frame stack looking for a
    // catch handler; if none, the async-wrap path settles the
    // result Promise as rejected.
    if (throws_in) {
        if (!try unwindThrow(allocator, realm, &frames, sent_value)) {
            // No handler — settle result promise as rejected.
            if (gen.result_promise) |rp| {
                if (heap_mod.valueAsPlainObject(rp)) |rp_obj| {
                    settlePromiseInternal(realm, rp_obj, .rejected, sent_value) catch return error.OutOfMemory;
                }
            }
            gen.state = .completed;
            return;
        }
    }

    const result = try runFrames(allocator, realm, &frames);
    switch (result) {
        .value, .yielded => |v| {
            if (result == .yielded) {
                gen.state = .suspended;
                return;
            }
            // Normal completion — settle the result Promise.
            // §27.7.5.1 step 3.d — `await`-style adoption: if `v`
            // is itself a thenable (Promise), chain so the outer
            // mirrors the inner's settlement rather than resolving
            // *with* the inner Promise as a value. Without this,
            // `async f() { return innerPromise; }` exposes a
            // Promise<Promise<T>> to consumers.
            if (gen.result_promise) |rp| {
                if (heap_mod.valueAsPlainObject(rp)) |rp_obj| {
                    if (heap_mod.valueAsPlainObject(v)) |v_obj| {
                        if (v_obj.isPromise()) {
                            chainPromiseToInner(realm, v_obj, rp_obj) catch return error.OutOfMemory;
                            gen.state = .completed;
                            return;
                        }
                    }
                    settlePromiseInternal(realm, rp_obj, .fulfilled, v) catch return error.OutOfMemory;
                }
            }
            gen.state = .completed;
        },
        .thrown => |ex| {
            if (gen.result_promise) |rp| {
                if (heap_mod.valueAsPlainObject(rp)) |rp_obj| {
                    settlePromiseInternal(realm, rp_obj, .rejected, ex) catch return error.OutOfMemory;
                }
            }
            gen.state = .completed;
        },
    }
}

/// Async-generator counterpart to `resumeAsyncFunction`. The body
/// was suspended on an `await`; the settled value is delivered
/// either as the awaited value (normal) or thrown at the await
/// point (rejected). On the body's next safe point (yield /
/// return / throw / re-await), the head request is settled and
/// the drain continues to any queued follow-ups.
pub fn resumeAsyncGeneratorOnSettle(
    allocator: std.mem.Allocator,
    realm: *Realm,
    gen: *@import("../generator.zig").JSGenerator,
    sent_value: Value,
    throws_in: bool,
) RunError!void {
    // Defensive: if the gen completed while the microtask was
    // queued (unlikely but possible if a user-installed reaction
    // closed it), there's nothing to resume — but the queue may
    // still have follow-on requests to settle.
    if (gen.state == .completed) {
        gen.async_state = .completed;
        try asyncGeneratorResumeNext(allocator, realm, gen);
        return;
    }
    if (gen.state == .executing) return; // re-entrancy guard

    // The drain previously parked us in `suspended_await`; now
    // we're running again.
    gen.async_state = .executing;
    gen.state = .executing;

    var frames: std.ArrayListUnmanaged(CallFrame) = .empty;
    defer {
        for (frames.items) |*f| if (f.owns_registers) realm.frame_pool.release(allocator, f.registers);
        frames.deinit(allocator);
    }

    try frames.append(allocator, .{
        .chunk = gen.chunk,
        .ip = gen.ip,
        .accumulator = sent_value,
        .registers = gen.registers,
        .env = gen.env,
        .this_value = gen.this_value,
        .home_object = gen.home_object,
        .home_function = gen.home_function,
        .argc = gen.argc,
        .generator = gen,
        // §8.3 — see `JSGenerator.realm`.
        .running_realm = gen.realm,
        .owns_registers = false,
    });

    if (throws_in) {
        if (!try unwindThrow(allocator, realm, &frames, sent_value)) {
            // No handler — body unwinds; settle head request as
            // rejected and continue drain.
            gen.state = .completed;
            gen.async_state = .completed;
            if (gen.queue.items.len > 0) {
                const req = gen.queue.orderedRemove(0);
                try rejectAsyncGenRequest(realm, req.capability_promise, sent_value);
            }
            try asyncGeneratorResumeNext(allocator, realm, gen);
            return;
        }
    }

    const result = try runFrames(allocator, realm, &frames);

    // Re-suspend on another await — the await opcode set
    // async_state = .suspended_await for us; just sync state.
    if (gen.async_state == .suspended_await) {
        gen.state = .suspended;
        return;
    }

    if (gen.queue.items.len == 0) {
        // Shouldn't happen — if we were running, there was a head
        // request. Defensive: just record state and return.
        if (result == .yielded) {
            gen.state = .suspended;
            gen.async_state = .suspended_yield;
        } else {
            gen.state = .completed;
            gen.async_state = .completed;
        }
        return;
    }

    const req = gen.queue.orderedRemove(0);
    switch (result) {
        .yielded => |v| {
            // §27.6.3.6 AsyncGeneratorYield — `Await(value);
            // CompleteStep(...)`. The Await deferred one
            // microtask ALREADY (the `await_` opcode emitted by
            // `compileYield` for async gens). CompleteStep
            // settles the cap synchronously per spec; routing
            // through `enqueueAsyncGenYield` adds a spurious
            // extra tick that breaks
            // `yield-return-then-getter-ticks.js` (the
            // return-completion's `Await(.then)` must fire BEFORE
            // the next user microtask, not after it).
            if (isSyncRejectedPromise(v)) {
                gen.state = .completed;
                gen.async_state = .completed;
                try rejectAsyncGenRequest(realm, req.capability_promise, heap_mod.valueAsPlainObject(v).?.promise_value);
                try asyncGeneratorResumeNext(allocator, realm, gen);
                return;
            }
            gen.state = .suspended;
            gen.async_state = .suspended_yield;
            try settleAsyncGenRequest(realm, req.capability_promise, v, false);
            try asyncGeneratorResumeNext(allocator, realm, gen);
            return;
        },
        .value => |v| {
            // §27.6.3.1 AsyncGeneratorStart step 4.g —
            // AsyncGeneratorResolve synchronously, same as the
            // sync drain path in `asyncGeneratorResumeNext`.
            // Routing through `enqueueAsyncGenYield` would add a
            // spurious extra tick that breaks the tick-count
            // assertions in `return-undefined-implicit-and-
            // explicit.js`.
            gen.state = .completed;
            gen.async_state = .completed;
            try settleAsyncGenRequest(realm, req.capability_promise, v, true);
            try asyncGeneratorResumeNext(allocator, realm, gen);
        },
        .thrown => |ex| {
            gen.state = .completed;
            gen.async_state = .completed;
            try rejectAsyncGenRequest(realm, req.capability_promise, ex);
            try asyncGeneratorResumeNext(allocator, realm, gen);
        },
    }
}

/// Internal version of `settlePromise` used by the runtime to
/// transition a Promise from pending → fulfilled/rejected and
/// fire any registered async waiters. The exposed
/// `intrinsics.settlePromise` calls into this; keeping a
/// runtime-side mirror lets `resumeAsyncFunction` settle without
/// pulling in the full intrinsics module.
pub fn settlePromiseInternal(
    realm: *Realm,
    inst: *JSObject,
    state: enum { fulfilled, rejected },
    value: Value,
) !void {
    if (inst.promise_state != .pending) return; // already settled
    realm.heap.settlePromise(inst, switch (state) {
        .fulfilled => .fulfilled,
        .rejected => .rejected,
    }, value);

    // Fire async-await waiters as resume microtasks. Pull the
    // list out of the extension and swap in an empty one so any
    // recursive call paths don't trip over the iteration.
    var w_iter: std.ArrayListUnmanaged(*@import("../generator.zig").JSGenerator) = .empty;
    if (inst.promiseWaitersPtr(realm.allocator) catch null) |waiters| {
        w_iter = waiters.*;
        waiters.* = .empty;
    }
    defer w_iter.deinit(realm.allocator);
    for (w_iter.items) |w_gen| {
        // §27.6.3.7 step 8.b — when the gen was suspended on
        // an Await driving a `.return(v)` completion (rather
        // than the usual await of a yielded value), the resume
        // must propagate as a return-completion at the saved
        // yield site, NOT as a normal yield-resume. Consume
        // the flag and route through the dedicated microtask.
        if (w_gen.awaiting_return_completion) {
            w_gen.awaiting_return_completion = false;
            try realm.enqueueAsyncGenReturnAfterAwait(w_gen, value, state == .rejected);
        } else {
            try realm.enqueueAsyncResume(w_gen, value, state == .rejected);
        }
    }

    // Fire user-level `.then` reactions. Snapshot the list out of
    // the extension and swap an empty one in so recursive paths
    // don't trip on it.
    var r_iter: std.ArrayListUnmanaged(@import("../object.zig").PromiseReaction) = .empty;
    if (inst.promiseReactionsPtr(realm.allocator) catch null) |reactions| {
        r_iter = reactions.*;
        reactions.* = .empty;
    }
    defer r_iter.deinit(realm.allocator);
    for (r_iter.items) |r| {
        const handler = if (state == .fulfilled) r.on_fulfilled else r.on_rejected;
        try realm.enqueuePromiseReaction(handler, value, r.result_promise, state == .rejected);
    }
}

/// Resume a suspended generator (or start an initial one).
/// Pushes a frame whose state is restored from `gen`, sets the
/// accumulator to `sent_value` (so `let x = yield e` reads
/// `sent_value` after resume), and runs the dispatch loop until
/// either another `gen_yield` (returns `.yielded`) or `Return`
/// (returns `.value`).
pub fn resumeGenerator(
    allocator: std.mem.Allocator,
    realm: *Realm,
    gen: *@import("../generator.zig").JSGenerator,
    sent_value: Value,
) RunError!RunResult {
    if (gen.state == .completed) {
        // §27.5.1.3 step 4 — a Return on an already-completed
        // generator still must reflect the supplied value in
        // the result iterator record. `genReturn`'s fast path
        // handles that; here we model the spec's "return
        // undefined" path for `next()` on a completed gen.
        if (gen.pending_return) |v| {
            gen.pending_return = null;
            return .{ .value = v };
        }
        return .{ .value = Value.undefined_ };
    }
    if (gen.state == .executing) {
        const ex = try makeTypeError(realm, "Generator is already running");
        return .{ .thrown = ex };
    }
    gen.state = .executing;

    var frames: std.ArrayListUnmanaged(CallFrame) = .empty;
    defer {
        for (frames.items) |*f| if (f.owns_registers) realm.frame_pool.release(allocator, f.registers);
        frames.deinit(allocator);
    }

    try frames.append(allocator, .{
        .chunk = gen.chunk,
        .ip = gen.ip,
        .accumulator = sent_value,
        .registers = gen.registers,
        .env = gen.env,
        .this_value = gen.this_value,
        .home_object = gen.home_object,
        .home_function = gen.home_function,
        .argc = gen.argc,
        .generator = gen,
        // §8.3 — see `JSGenerator.realm`.
        .running_realm = gen.realm,
        .owns_registers = false,
    });

    // §27.5.1.4 GeneratorResumeAbrupt(throw). Mirrors the
    // async-gen `.throw_value` path: walk `unwindThrow` from the
    // saved yield site so any surrounding `try { yield } catch`
    // / `finally` runs. If no handler is in range the body is
    // unwound to the top and the throw escapes the generator.
    // Surfaces the kind via `resume_kind` so any `yield*` loop
    // currently parked at the saved gen_yield observes throw_value
    // when its resume_kind op fires and can forward to the inner
    // iterator's `throw` per §15.5.5.
    if (gen.pending_throw) |ex_val| {
        gen.pending_throw = null;
        gen.resume_kind = .throw_value;
        gen.resume_value = ex_val;
        if (!try unwindThrow(allocator, realm, &frames, ex_val)) {
            gen.state = .completed;
            return .{ .thrown = ex_val };
        }
        const result = try runFrames(allocator, realm, &frames);
        if (result == .yielded) {
            gen.state = .suspended;
        } else {
            gen.state = .completed;
        }
        return result;
    }

    // §27.5.1.3 step 3 — return-completion drive. Inject an
    // unwind at the yield site so any `try { yield } finally
    // { F }` runs F. We remember the return value across the
    // dispatch loop so the synth-finally's terminal `throw_`
    // round-tripping our sentinel surfaces as a clean `.value`.
    var return_completion_val: ?Value = null;
    if (gen.pending_return) |return_val| {
        gen.pending_return = null;
        return_completion_val = return_val;
        // Mark the unwind as a return-completion so user
        // `catch (e) { … }` clauses are skipped while we walk
        // *to* the next finally. `unwindThrow` clears the flag
        // the moment it lands on a finally handler.
        realm.gen_return_completion = return_val;
        if (!try unwindThrow(allocator, realm, &frames, return_val)) {
            // No `finally` handler in range — the suspended
            // yield is bare. Drop the flag, complete the
            // generator, surface the return value.
            realm.gen_return_completion = null;
            gen.state = .completed;
            return .{ .value = return_val };
        }
    } else if (gen.pending_return_completion) |saved_val| {
        // §14.15.3 step 4 — a prior `.return(v)` drove the body
        // into a `finally { … }`, but the finally `yield`ed
        // before completing. The body resumes here from that
        // yield; consume the stashed value so the finally's
        // synthetic `throw_` round-trip is recognised and the
        // outcome surfaces as `.value = saved_val`.
        gen.pending_return_completion = null;
        return_completion_val = saved_val;
    }

    const result = try runFrames(allocator, realm, &frames);
    // §14.15.3 step 4 — if we were driving a return-completion
    // through a finally and the finally completed normally,
    // its synth handler's terminal `throw_` rethrows the saved
    // sentinel value. We recognise that round-trip by
    // bit-equality with the value we put in and surface as a
    // clean `.value`. If the finally instead threw a different
    // value (or `return`ed / `break`ed with a value), that
    // abrupt completion replaces the outer return-completion.
    if (return_completion_val) |return_val| {
        // The flag should already be cleared (unwindThrow drops
        // it on finally entry); defensive belt-and-braces here.
        realm.gen_return_completion = null;
        switch (result) {
            .thrown => |ex| {
                gen.state = .completed;
                if (valuesIdentical(ex, return_val)) {
                    return .{ .value = return_val };
                }
                return .{ .thrown = ex };
            },
            .value => |v| {
                // §14.15.3 step 4 — the finally block executed
                // its own abrupt `return X` (or `break` with a
                // labelled value reaching the function tail). The
                // finally's completion replaces the outer return-
                // completion outright — surface its value, NOT the
                // saved `return_val`. Empty / naturally-completing
                // finally blocks come back through the `.thrown`
                // arm above (the synth-rethrow round-trip) where
                // `valuesIdentical(ex, return_val)` restores the
                // saved value.
                gen.state = .completed;
                return .{ .value = v };
            },
            .yielded => |v| {
                // §14.15.3 step 4 — the finally body itself
                // yielded before completing. Stash the saved
                // return value so the next resume recognises
                // the synthetic rethrow at the end of the
                // finally and surfaces a clean `.value`.
                gen.pending_return_completion = return_val;
                gen.state = .suspended;
                return .{ .yielded = v };
            },
        }
    }
    if (result == .yielded) {
        gen.state = .suspended;
    } else {
        gen.state = .completed;
    }
    return result;
}

/// Bit-equal comparison on Value's NaN-boxed payload. Sharper
/// than SameValueZero — distinguishes `NaN` from `-NaN` and
/// `+0` from `-0`. Used at internal sentinel boundaries (e.g.
/// the return-completion rethrow round-trip) to recognise
/// "this is the exact same Value we just put in" without
/// allocating a wrapper object.
fn valuesIdentical(a: Value, b: Value) bool {
    return a.bits == b.bits;
}
