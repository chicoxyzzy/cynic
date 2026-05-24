//! Generator + async-generator machinery — extracted from
//! `interpreter.zig` to keep the dispatch-loop file focused.
//!
//! Hosts the `wrapGenerator` / `wrapAsyncGenerator` entry
//! points, the prototype installers (`ensureGeneratorPrototype`,
//! `ensureAsyncIteratorPrototype`, `ensureAsyncGeneratorPrototype`),
//! the native `next` / `return` / `throw` / `Symbol.iterator`
//! callbacks for both flavours, and the async-generator request
//! queue / pump (`asyncGeneratorEnqueue` →
//! `asyncGeneratorResumeNext` → `resumeAsyncGenBody` →
//! `settleAsyncGenRequest`).
//!
//! Three callbacks land back in `interpreter.zig`: `runFrames` to
//! drive a fresh dispatch, `resumeGenerator` to step a suspended
//! generator's body, and `settlePromiseInternal` to honour the
//! Promise capability associated with each async-generator
//! request.

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

// Circular back to interpreter.zig for the dispatch entry points,
// shared types, and the promise-settlement / generator-resume
// hooks the async-generator pump invokes.
const lantern = @import("interpreter.zig");
const CallFrame = lantern.CallFrame;
const RunError = lantern.RunError;
const RunResult = lantern.RunResult;
const runFrames = lantern.runFrames;
const resumeGenerator = lantern.resumeGenerator;
const settlePromiseInternal = lantern.settlePromiseInternal;
const makeTypeError = lantern.makeTypeError;
const unwindThrow = lantern.unwindThrow;

/// Allocate a `JSGenerator` for a `function*` invocation and
/// return an iterator-shaped JSObject pointing at it. The
/// generator's `next` / `return` / `throw` / `[Symbol.iterator]`
/// methods are installed once on the realm's
/// `generator_prototype`; this wrapper inherits from that proto.
pub fn wrapGenerator(
    allocator: std.mem.Allocator,
    realm: *Realm,
    chunk: *const @import("../../bytecode/chunk.zig").Chunk,
    captured_env: ?*Environment,
    this_value: Value,
    args: []const Value,
    home_object: ?*JSObject,
    home_function: ?*JSFunction,
    callee: ?*JSFunction,
) RunError!RunResult {
    // Generator's register file must hold the function body's
    // declared registers AND any extra inbound argument values.
    // Cap at u8 max — over-arity gracefully drops trailing args
    // rather than overflowing the slot count.
    const wanted: usize = @max(@as(usize, chunk.register_count), args.len);
    const reg_count: u8 = @intCast(@min(wanted, std.math.maxInt(u8)));
    const gen = realm.heap.allocateGenerator(
        chunk,
        reg_count,
        captured_env,
        this_value,
    ) catch return error.OutOfMemory;
    // §15.7.14 step 31 — propagate home_* so private-name access
    // inside the generator body translates the brand correctly.
    realm.heap.setGeneratorHomeObject(gen, home_object);
    realm.heap.setGeneratorHomeFunction(gen, home_function);
    // Pre-load argument values into the generator's register
    // file so the function prologue's Ldar / sta_env sequence
    // sees them at indices 0..argc-1.
    var i: usize = 0;
    while (i < args.len and i < gen.registers.len) : (i += 1) {
        gen.registers[i] = args[i];
    }
    gen.argc = @intCast(@min(args.len, std.math.maxInt(u8)));

    const wrapper = realm.heap.allocateObject() catch return error.OutOfMemory;
    // Seed a safe default [[Prototype]] for the duration of the
    // prologue — `resumeGenerator` below runs default-param init
    // which may mutate `callee.prototype` (`function*(a = (g.prototype =
    // null)) {}`). The real wrapper.prototype is rebound after the
    // prologue per the §9.1.14 read below.
    realm.heap.setObjectPrototype(wrapper, ensureGeneratorPrototype(realm) catch return error.OutOfMemory);
    realm.heap.setGeneratorRef(wrapper, gen);

    // The wrapper is the only handle linking the freshly allocated
    // `gen` to anything caller-visible. `resumeGenerator` runs the
    // generator body's prologue eagerly (§10.2.1.4), which can
    // allocate environments / closures / etc. and trip the GC
    // before this function returns — pin the wrapper so the mark
    // walk reaches both it and `gen.generator_ref`.
    const scope = realm.heap.openScope() catch return error.OutOfMemory;
    defer scope.close();
    scope.push(heap_mod.taggedObject(wrapper)) catch return error.OutOfMemory;

    // §10.2.1.4 — run FunctionDeclarationInstantiation eagerly
    // so param destructuring / defaults / RequireObjectCoercible
    // execute (and possibly throw) at call time. `gen_initial_suspend`
    // sits right after the prologue; resumeGenerator drives the
    // chunk to that point, then unwinds. The yielded undefined
    // is discarded; the wrapper is what the caller sees.
    const initial = try resumeGenerator(allocator, realm, gen, Value.undefined_);
    // §15.6.2 EvaluateGeneratorBody — the spec step order is
    // 1) FunctionDeclarationInstantiation, 2) OrdinaryCreateFrom
    // Constructor (which performs §9.1.14 GetPrototypeFromConstructor
    // reading `Get(constructor, "prototype")`), 3) GeneratorStart.
    // Rebind wrapper.prototype AFTER the prologue so a default-
    // param `g.prototype = null` observably routes through the
    // §9.1.14 step-4 intrinsic fallback. Reading the property
    // bag (not the dedicated slot) matters because `g.prototype
    // = null` updates the bag but V8-style keeps the slot.
    const proto_val_g: Value = if (callee) |c| c.get("prototype") else Value.undefined_;
    if (heap_mod.valueAsPlainObject(proto_val_g)) |p| {
        realm.heap.setObjectPrototype(wrapper, p);
    }
    switch (initial) {
        .yielded => return .{ .value = heap_mod.taggedObject(wrapper) },
        .value => return .{ .value = heap_mod.taggedObject(wrapper) },
        .thrown => |ex| return .{ .thrown = ex },
    }
}

/// §27.6 Allocate a wrapper for `async function*` invocation.
/// Mirrors `wrapGenerator` but tags the underlying generator as
/// `is_async = true` so the body's `await` opcode goes through
/// the async-suspend path, and uses `%AsyncGeneratorPrototype%`
/// whose `next`/`return`/`throw` wrap the result in a Promise.
pub fn wrapAsyncGenerator(
    allocator: std.mem.Allocator,
    realm: *Realm,
    chunk: *const @import("../../bytecode/chunk.zig").Chunk,
    captured_env: ?*Environment,
    this_value: Value,
    args: []const Value,
    home_object: ?*JSObject,
    home_function: ?*JSFunction,
    callee: ?*JSFunction,
) RunError!RunResult {
    const wanted: usize = @max(@as(usize, chunk.register_count), args.len);
    const reg_count: u8 = @intCast(@min(wanted, std.math.maxInt(u8)));
    const gen = realm.heap.allocateGenerator(
        chunk,
        reg_count,
        captured_env,
        this_value,
    ) catch return error.OutOfMemory;
    gen.is_async = true;
    // §27.6.3 — this generator backs an `async function*`, so its
    // `.next` / `.return` / `.throw` go through the queue-based
    // drain. `async_state` defaults to `.suspended_start`.
    gen.is_async_generator = true;
    // §15.7.14 step 31 — propagate home_* so private-name access
    // inside the async-generator body translates the brand correctly.
    realm.heap.setGeneratorHomeObject(gen, home_object);
    realm.heap.setGeneratorHomeFunction(gen, home_function);
    var i: usize = 0;
    while (i < args.len and i < gen.registers.len) : (i += 1) {
        gen.registers[i] = args[i];
    }
    gen.argc = @intCast(@min(args.len, std.math.maxInt(u8)));

    const wrapper = realm.heap.allocateObject() catch return error.OutOfMemory;
    // Seed a safe default [[Prototype]] for the duration of the
    // prologue — the §9.1.14 read below rebinds it after default-
    // param evaluation runs (see `wrapGenerator` for the spec
    // rationale).
    realm.heap.setObjectPrototype(wrapper, ensureAsyncGeneratorPrototype(realm) catch return error.OutOfMemory);
    realm.heap.setGeneratorRef(wrapper, gen);

    // Same wrapper-pin rationale as `wrapGenerator`: the eager
    // prologue can allocate and trip the GC before we return.
    const scope = realm.heap.openScope() catch return error.OutOfMemory;
    defer scope.close();
    scope.push(heap_mod.taggedObject(wrapper)) catch return error.OutOfMemory;

    // §27.6.3.1 EvaluateAsyncGeneratorBody — param init runs
    // synchronously and any throw propagates to the call site.
    // Mirror the sync-gen path: drive the chunk to
    // `gen_initial_suspend`, then hand back the wrapper.
    const initial = try resumeGenerator(allocator, realm, gen, Value.undefined_);
    // §27.6.3.2 AsyncGeneratorStart spec step order matches sync
    // generators — rebind wrapper.prototype after FDI runs so a
    // default-param `g.prototype = null` routes through the
    // §9.1.14 step-4 fallback. Property-bag read (not dedicated
    // slot) for the same V8-style-keep reason.
    const proto_val_ag: Value = if (callee) |c| c.get("prototype") else Value.undefined_;
    if (heap_mod.valueAsPlainObject(proto_val_ag)) |p| {
        realm.heap.setObjectPrototype(wrapper, p);
    }
    switch (initial) {
        .yielded => return .{ .value = heap_mod.taggedObject(wrapper) },
        .value => return .{ .value = heap_mod.taggedObject(wrapper) },
        .thrown => |ex| return .{ .thrown = ex },
    }
}

/// Lazily install `%GeneratorPrototype%` on the realm. Has
/// `next` / `return` / `throw` / `[Symbol.iterator]` methods
/// that walk the wrapper's `generator_ref`.
///
/// §27.5.1 — `%GeneratorPrototype%.[[Prototype]]` is
/// `%IteratorPrototype%`, so generator instances inherit the
/// iterator-helpers (`.map` / `.filter` / `.take` / `.drop` /
/// `.toArray` / `.forEach` / …) from the Iterator built-in.
/// We resolve that proto from the realm's `Iterator` global
/// (installed at `installBuiltins` time, before any user code
/// runs that could trigger this lazy-init path); if for some
/// reason it's missing we fall back to `%Object.prototype%`
/// so the generator still works at the protocol level.
/// Look up `%Iterator.prototype%` via the realm's `Iterator`
/// global (installed by `installBuiltins`). Falls back to
/// `%Object.prototype%` if Iterator isn't present (e.g. a realm
/// that only loaded core intrinsics).
fn iteratorPrototypeOrObjectPrototype(realm: *Realm) ?*JSObject {
    return iteratorPrototypeOrObjectPrototypePub(realm);
}

pub fn iteratorPrototypeOrObjectPrototypePub(realm: *Realm) ?*JSObject {
    if (realm.globals.get("Iterator")) |ctor_v| {
        if (heap_mod.valueAsFunction(ctor_v)) |ctor| {
            if (ctor.prototype) |p| return p;
        }
    }
    return realm.intrinsics.object_prototype;
}

pub fn ensureGeneratorPrototype(realm: *Realm) !*JSObject {
    if (realm.intrinsics.generator_prototype) |p| return p;
    const proto = try realm.heap.allocateObject();
    realm.heap.setObjectPrototype(proto, iteratorPrototypeOrObjectPrototype(realm));

    // §27.5.1 — `next` / `return` / `throw` install with the
    // standard §17 built-in-prototype-method descriptor:
    // `{ writable:true, enumerable:false, configurable:true }`.
    try intrinsics_mod.installNativeMethodOnProto(realm, proto, "next", genNext, 1);
    try intrinsics_mod.installNativeMethodOnProto(realm, proto, "return", genReturn, 1);
    try intrinsics_mod.installNativeMethodOnProto(realm, proto, "throw", genThrow, 1);

    // For-of integration: `Symbol.iterator` returns the iterator
    // itself (a generator IS its own iterator per §27.5.1.5).
    // Stored under the well-known-Symbol's stringified key
    // `"@@iterator"`. Our property-access path looks up by
    // string, so this coexists with future Symbol-typed keys.
    const sym_iter_fn = try realm.heap.allocateFunctionNative(genSymbolIterator, 0, "[Symbol.iterator]");
    sym_iter_fn.proto = realm.intrinsics.function_prototype;
    try proto.set(realm.allocator, "@@iterator", heap_mod.taggedFunction(sym_iter_fn));

    // §27.5.1.5 — Generator.prototype[@@toStringTag] === "Generator"
    // so `Object.prototype.toString.call(g)` returns
    // "[object Generator]".
    const tag_str = try realm.heap.allocateString("Generator");
    try proto.setWithFlags(realm.allocator, "@@toStringTag", Value.fromString(tag_str), .{
        .writable = false,
        .enumerable = false,
        .configurable = true,
    });

    realm.intrinsics.generator_prototype = proto;
    return proto;
}

pub fn genResultObject(realm: *Realm, value: Value, done: bool) !Value {
    const obj = try realm.heap.allocateObject();
    realm.heap.setObjectPrototype(obj, realm.intrinsics.object_prototype);
    try obj.set(realm.allocator, "value", value);
    try obj.set(realm.allocator, "done", Value.fromBool(done));
    return heap_mod.taggedObject(obj);
}

/// Lazily install `%AsyncGeneratorPrototype%`. Same shape as the
/// sync generator prototype but the methods produce Promises:
/// • `next()` / `return()` resolve to `{value, done}`.
/// • `throw()` rejects with the thrown value.
/// §27.1.3 %AsyncIteratorPrototype% — the common ancestor of
/// every async iterator (async generators, AsyncFromSyncIterator,
/// user-defined async iterators). Only one property: an
/// `@@asyncIterator` method that returns `this`. This is the
/// hook by which `for await (… of obj)` recognises async
/// iterables.
pub fn ensureAsyncIteratorPrototype(realm: *Realm) !*JSObject {
    if (realm.intrinsics.async_iterator_prototype) |p| return p;
    const proto = try realm.heap.allocateObject();
    realm.heap.setObjectPrototype(proto, realm.intrinsics.object_prototype);
    const sym_iter_fn = try realm.heap.allocateFunctionNative(genSymbolIterator, 0, "[Symbol.asyncIterator]");
    sym_iter_fn.proto = realm.intrinsics.function_prototype;
    try proto.setWithFlags(realm.allocator, "@@asyncIterator", heap_mod.taggedFunction(sym_iter_fn), .{
        .writable = true,
        .enumerable = false,
        .configurable = true,
    });
    realm.intrinsics.async_iterator_prototype = proto;
    return proto;
}

pub fn ensureAsyncGeneratorPrototype(realm: *Realm) !*JSObject {
    if (realm.intrinsics.async_generator_prototype) |p| return p;
    const proto = try realm.heap.allocateObject();
    // §27.6.1 — `%AsyncGeneratorPrototype%.[[Prototype]]` is
    // `%AsyncIteratorPrototype%`. That's where `@@asyncIterator`
    // lives — inheriting it here means `for await (... of asyncGen)`
    // resolves the method through the chain.
    realm.heap.setObjectPrototype(proto, try ensureAsyncIteratorPrototype(realm));

    // §27.6.1 — `next` / `return` / `throw` install with the
    // standard §17 built-in-prototype-method descriptor:
    // `{ writable:true, enumerable:false, configurable:true }`.
    // The old plain `set` left them enumerable, which trips
    // `prop-desc.js` fixtures.
    try intrinsics_mod.installNativeMethodOnProto(realm, proto, "next", asyncGenNext, 1);
    try intrinsics_mod.installNativeMethodOnProto(realm, proto, "return", asyncGenReturn, 1);
    try intrinsics_mod.installNativeMethodOnProto(realm, proto, "throw", asyncGenThrow, 1);

    const tag_str = try realm.heap.allocateString("AsyncGenerator");
    try proto.setWithFlags(realm.allocator, "@@toStringTag", Value.fromString(tag_str), .{
        .writable = false,
        .enumerable = false,
        .configurable = true,
    });

    realm.intrinsics.async_generator_prototype = proto;
    return proto;
}

fn asyncGenNext(realm: *Realm, this_value: Value, args: []const Value) @import("../function.zig").NativeError!Value {
    // §27.6.1.2 step 2 — IfAbruptRejectPromise on the
    // brand-check. `this` must be an async-generator object;
    // anything else turns into Promise.reject(TypeError), NOT a
    // thrown TypeError (the test fixture inspects the rejection
    // reason, so synchronous throws bypass `.then`'s onRejected
    // and trip a different code path).
    const brand_err = asyncGenBrandCheck(realm, this_value, "Async generator method called on a non-async-generator");
    if (brand_err) |ex| return intrinsics_mod.allocatePromiseFor(realm, null, .rejected, ex) catch return error.OutOfMemory;
    const obj = heap_mod.valueAsPlainObject(this_value).?;
    const gen = obj.generator_ref.?;
    const sent: Value = if (args.len > 0) args[0] else Value.undefined_;
    return asyncGenDispatch(realm, gen, .{ .normal = sent });
}

/// §27.6.3.5 AsyncGeneratorEnqueue + §27.6.3.4
/// AsyncGeneratorResumeNext — common path for `.next` / `.return`
/// / `.throw`. Builds the capability Promise, enqueues the
/// request, kicks the drain (only when the gen is currently
/// idle — `suspended_start` or `suspended_yield`), and returns
/// the capability Promise synchronously. The caller (asyncGenNext
/// / asyncGenReturn / asyncGenThrow) hands it back to user JS.
fn asyncGenDispatch(
    realm: *Realm,
    gen: *@import("../generator.zig").JSGenerator,
    completion: @import("../generator.zig").Completion,
) @import("../function.zig").NativeError!Value {
    const cap_promise_v = intrinsics_mod.allocatePromiseFor(realm, null, .pending, Value.undefined_) catch return error.OutOfMemory;
    const cap_promise_obj = heap_mod.valueAsPlainObject(cap_promise_v).?;
    // Pin the capability across any allocations the drain may
    // perform before it lands in the queue. `enqueue` itself
    // allocates one ArrayList slot, but a `resumeNext` triggered
    // by the very first request can allocate the world.
    const scope = realm.heap.openScope() catch return error.OutOfMemory;
    defer scope.close();
    scope.push(cap_promise_v) catch return error.OutOfMemory;

    asyncGeneratorEnqueue(realm, gen, completion, cap_promise_obj) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.NativeThrew,
    };
    return cap_promise_v;
}

/// §27.6.3.5 AsyncGeneratorEnqueue. Append the request to the
/// gen's queue; kick `asyncGeneratorResumeNext` only when the
/// gen is idle (suspended_start / suspended_yield). When the
/// state is executing or suspended_await, the drain will pick
/// the request up the next time the body reaches a safe point
/// (yield / return / throw / await-settle).
fn asyncGeneratorEnqueue(
    realm: *Realm,
    gen: *@import("../generator.zig").JSGenerator,
    completion: @import("../generator.zig").Completion,
    cap_promise: *JSObject,
) RunError!void {
    try gen.queue.append(realm.allocator, .{
        .completion = completion,
        .capability_promise = cap_promise,
    });
    switch (gen.async_state) {
        .suspended_start, .suspended_yield => {
            try asyncGeneratorResumeNext(realm.allocator, realm, gen);
        },
        .executing, .suspended_await, .completed => {
            // executing — re-entrant call from inside the body
            //   (the request-queue-order-state-executing fixture);
            //   body will reach a yield/return/throw and drain
            //   will pick this up.
            // suspended_await — body is parked on a pending
            //   Promise; the resume-microtask will resume the
            //   body and re-enter the drain.
            // completed — a synchronous drain call below settles
            //   the request immediately; but we route through
            //   resumeNext on the next idle tick so we don't
            //   re-enter the JS world from inside an opcode
            //   committee. Spec §27.6.3.4 step 10 covers this:
            //   "If state is completed, Return ! AsyncGenerator
            //   ResumeNext(generator)."
            if (gen.async_state == .completed) {
                try asyncGeneratorResumeNext(realm.allocator, realm, gen);
            }
        },
    }
}

/// §27.6.3.4 AsyncGeneratorResumeNext. The drain: pulls the
/// head request, transitions state, runs the body to its next
/// safe point, settles the request, and loops to the next.
/// Stops when (a) the queue is empty, (b) the body suspended on
/// an await (the resume-microtask continues the drain), or
/// (c) the gen is currently executing (which only happens if
/// the body re-entered via `.next()` inside itself — handled by
/// the outer drain).
pub fn asyncGeneratorResumeNext(
    allocator: std.mem.Allocator,
    realm: *Realm,
    gen: *@import("../generator.zig").JSGenerator,
) RunError!void {
    while (gen.queue.items.len > 0) {
        // Re-entrancy / await guard: if the body is currently
        // running on behalf of an earlier request, stop. The
        // body itself will continue the drain when it reaches a
        // safe point.
        if (gen.async_state == .executing) return;
        if (gen.async_state == .suspended_await) return;

        const req = gen.queue.items[0];

        // §27.6.3.4 steps 8-10: completed generator. Settle the
        // head with done=true (normal/return) or reject (throw).
        //
        // For `.return_value` we route through
        // `awaitForReturnCompletion` first — §27.6.3.5 step 8
        // says completed-state returns go through
        // AsyncGeneratorAwaitReturn, whose step 6 PromiseResolve
        // is observable (a poisoned `constructor` getter on a
        // Promise argument surfaces as a rejection per step 7).
        if (gen.async_state == .completed) {
            switch (req.completion) {
                .normal => {
                    _ = gen.queue.orderedRemove(0);
                    try settleAsyncGenRequest(realm, req.capability_promise, Value.undefined_, true);
                    continue;
                },
                .return_value => |v| {
                    // Leave the request at the head; the await
                    // microtask resumes the drain after the
                    // resolved value is in hand.
                    gen.async_state = .suspended_await;
                    try awaitForReturnCompletion(realm, gen, v);
                    return;
                },
                .throw_value => |ex| {
                    _ = gen.queue.orderedRemove(0);
                    try rejectAsyncGenRequest(realm, req.capability_promise, ex);
                    continue;
                },
            }
        }

        // §27.6.3.7 step 8.b / §27.6.3.4 AsyncGeneratorResumeNext
        // — when a `.return(v)` request is being processed the
        // spec runs `Let awaited be Await(resumptionValue.
        // [[Value]])` BEFORE propagating the return. This
        // applies to BOTH the initial-state path (gen never
        // entered the body) and the suspended-yield path:
        // §27.6.3.6 unwraps the value through Await even when
        // closing the gen without resuming, so
        // `it.return(Promise.resolve('x'))` settles the cap
        // with `{value: 'x', done: true}` rather than the raw
        // Promise (see
        // `built-ins/AsyncGeneratorPrototype/return/
        // return-suspendedStart-promise.js`).
        if (req.completion == .return_value) {
            const v = req.completion.return_value;
            gen.async_state = .suspended_await;
            try awaitForReturnCompletion(realm, gen, v);
            return;
        }

        gen.async_state = .executing;
        const outcome = try resumeAsyncGenBody(allocator, realm, gen, req.completion);

        // The body either yielded (normal value out), returned
        // (completion), threw (rejection), or suspended on an
        // await (async_state was set to .suspended_await by the
        // await opcode itself — leave the request at the head
        // and exit the drain).
        if (gen.async_state == .suspended_await) {
            // Don't pop; don't change state again.
            return;
        }

        switch (outcome) {
            .yielded => |raw| {
                // §27.6.3.6 AsyncGeneratorYield — the syntactic
                // `yield X` is `Await(X); AsyncGeneratorYield(X)`.
                // The Await defers one microtask, so the user
                // can register `.then(cb)` on the capability
                // BEFORE it settles. Pop the head request,
                // park the gen in `suspended_await` (the body
                // is logically mid-step, blocking a subsequent
                // `.next()` from re-kicking the drain), and
                // enqueue a microtask that settles the cap and
                // continues the drain.
                _ = gen.queue.orderedRemove(0);
                gen.async_state = .suspended_await;
                if (isSyncRejectedPromise(raw)) {
                    // §27.6.3.6 with Await rejecting → the
                    // throw propagates as an uncaught
                    // exception inside the body, closing the
                    // gen. Pre-close here so the drain's
                    // follow-on iteration sees state ==
                    // completed and serves remaining requests
                    // with `done:true`.
                    gen.state = .completed;
                    try realm.enqueueAsyncGenYield(
                        gen,
                        req.capability_promise,
                        heap_mod.valueAsPlainObject(raw).?.promise_value,
                        false,
                        true,
                    );
                } else {
                    try realm.enqueueAsyncGenYield(
                        gen,
                        req.capability_promise,
                        raw,
                        false,
                        false,
                    );
                }
                // Stop the drain — the microtask will resume it
                // after settling. Without this, item2/item3
                // would be processed synchronously and their
                // caps would settle before user `.then`
                // registrations had a chance to register.
                return;
            },
            .value => |v| {
                // §27.6.3.1 AsyncGeneratorStart step 4.g —
                // `AsyncGeneratorResolve(generator, resultValue,
                // true)`. Per §27.6.3.6 this calls
                // `Call(promiseCapability.[[Resolve]], …)`
                // *synchronously*; the `.then` reactions are
                // queued as ordinary microtasks at settle time
                // (one tick of latency from the consumer's
                // perspective, no extra tick added by us).
                // `return-undefined-implicit-and-explicit.js`
                // asserts that an explicit `return undefined`
                // ticks one extra time (via §13.10.1 step 3
                // `Await(exprValue)` — emitted in the compiler)
                // while bare `return;` does not. If we
                // unnecessarily route the body's normal
                // completion through `enqueueAsyncGenYield`, both
                // forms add an extra tick and the gap collapses.
                _ = gen.queue.orderedRemove(0);
                gen.state = .completed;
                gen.async_state = .completed;
                try settleAsyncGenRequest(realm, req.capability_promise, v, true);
                continue;
            },
            .thrown => |ex| {
                _ = gen.queue.orderedRemove(0);
                gen.state = .completed;
                gen.async_state = .completed;
                try rejectAsyncGenRequest(realm, req.capability_promise, ex);
                continue;
            },
        }
    }
}

/// Drive the gen body for one step of the drain. Branches on
/// the request's completion kind: normal → resume with sent
/// value; return → drive a return-completion through any
/// surrounding `try { … } finally`; throw → land an exception
/// at the saved yield site.
pub fn resumeAsyncGenBody(
    allocator: std.mem.Allocator,
    realm: *Realm,
    gen: *@import("../generator.zig").JSGenerator,
    completion: @import("../generator.zig").Completion,
) RunError!RunResult {
    switch (completion) {
        .normal => |v| {
            // resumeGenerator handles state == initial (initial
            // suspend) and state == suspended (yield resume).
            return resumeGenerator(allocator, realm, gen, v);
        },
        .return_value => |v| {
            // §27.6.3.3 step 4: if the gen is in suspended_start
            // (never resumed), the body's try/finally machinery
            // hasn't seen any yield yet; just close.
            if (gen.state == .initial) {
                gen.state = .completed;
                return .{ .value = v };
            }
            // Reuse the existing return-completion drive (used
            // by Generator.prototype.return for sync gens).
            gen.pending_return = v;
            return resumeGenerator(allocator, realm, gen, Value.undefined_);
        },
        .throw_value => |v| {
            // §27.6.3.2 — pre-start throw closes the gen and
            // surfaces as a rejection.
            if (gen.state == .initial) {
                gen.state = .completed;
                return .{ .thrown = v };
            }
            // Already-completed gen: just propagate.
            if (gen.state == .completed) {
                return .{ .thrown = v };
            }
            // Inject the throw at the suspended yield site. We
            // build a one-frame stack mirroring `resumeGenerator`
            // and walk `unwindThrow` from `gen.ip` — that lands
            // in any surrounding try/catch (or unwinds the whole
            // body if there isn't one).
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
                .accumulator = Value.undefined_,
                .registers = gen.registers,
                .env = gen.env,
                .this_value = gen.this_value,
                .home_object = gen.home_object,
                .home_function = gen.home_function,
                .argc = gen.argc,
                .generator = gen,
                .owns_registers = false,
            });

            if (!try unwindThrow(allocator, realm, &frames, v)) {
                gen.state = .completed;
                return .{ .thrown = v };
            }
            const result = try runFrames(allocator, realm, &frames);
            if (result == .yielded) {
                gen.state = .suspended;
            } else {
                gen.state = .completed;
            }
            return result;
        },
    }
}

/// Settle an AsyncGeneratorRequest's capability with
/// `{value, done}` — fulfilled completion. Per AGENTS.md
/// "Microtasks are spec-conformant", `settlePromiseInternal`
/// fires reactions via `enqueuePromiseReaction` (deferred);
/// no user code runs synchronously from here.
pub fn settleAsyncGenRequest(
    realm: *Realm,
    cap_promise: *JSObject,
    value: Value,
    done: bool,
) RunError!void {
    const result = genResultObject(realm, value, done) catch return error.OutOfMemory;
    try settlePromiseInternal(realm, cap_promise, .fulfilled, result);
}

/// Settle an AsyncGeneratorRequest's capability with rejection.
pub fn rejectAsyncGenRequest(
    realm: *Realm,
    cap_promise: *JSObject,
    reason: Value,
) RunError!void {
    try settlePromiseInternal(realm, cap_promise, .rejected, reason);
}

/// True iff `v` is a Promise object already in the `rejected`
/// state. Used by async-gen yield's close-on-reject shim.
pub fn isSyncRejectedPromise(v: Value) bool {
    const obj = heap_mod.valueAsPlainObject(v) orelse return false;
    return obj.promise_state == .rejected;
}

/// §27.6.1 — async generators carry a brand on their wrapper
/// JSObject. Tests routinely call `AsyncGeneratorPrototype.X.call(notAGen)`
/// and check that the returned promise rejects with TypeError.
/// Returns the prebuilt TypeError value when `this` fails the
/// check; null when it's a real async generator (caller proceeds
/// with the unwrapped `obj.generator_ref`).
fn asyncGenBrandCheck(realm: *Realm, this_value: Value, msg: []const u8) ?Value {
    const obj = heap_mod.valueAsPlainObject(this_value) orelse {
        return makeTypeError(realm, msg) catch return null;
    };
    const gen = obj.generator_ref orelse {
        return makeTypeError(realm, msg) catch return null;
    };
    if (!gen.is_async) {
        return makeTypeError(realm, msg) catch return null;
    }
    return null;
}

/// §27.6.3.7 step 8.b — schedule `Await(v)` for the
/// return-completion that resumes a suspended async-gen yield.
/// The Await runs through the full PromiseResolve mechanism:
/// Promises chain through the existing waiter machinery,
/// thenables enqueue a PromiseResolveThenableJob, and bare
/// values defer one microtask. In every case the final resume
/// goes through the `async_gen_return_after_await` microtask
/// kind, which feeds the awaited value into
/// `resumeAsyncGenBody(.return_value)` so the body's finally
/// machinery sees a return-completion with the unwrapped value.
fn awaitForReturnCompletion(realm: *Realm, gen: *@import("../generator.zig").JSGenerator, v: Value) !void {
    // For Promise / thenable values the inner await may itself
    // suspend on a pending Promise. To keep the implementation
    // self-contained we don't try to chain waiters at this layer
    // — instead, we always enqueue an `async_gen_return_after
    // _await` microtask carrying `v`. The microtask handler
    // re-routes: if the resolved value is still a thenable /
    // pending Promise (after the first tick of latency), it
    // re-enqueues itself; once it's a bare value, it drives the
    // body's return-completion.
    //
    // Thenables surface the `get then` accessor via the first
    // tick's microtask (when we re-enter `awaitForReturnCompletion`
    // and read `.then`). Pending Promises chain via a
    // sub-microtask. The fixture
    // `yield-return-then-getter-ticks.js` only needs the
    // `get then` access + one extra tick — both fall out of
    // this path.
    if (heap_mod.valueAsPlainObject(v)) |obj| {
        if (obj.isPromise()) {
            // §27.2.4.7 PromiseResolve step 1.a — when the
            // resolution is already a Promise, the spec reads
            // `value.constructor` to honour the species hook.
            // Cynic doesn't actually species-dispatch (we always
            // build a %Promise%), but the read is still
            // observable: a poisoned `constructor` getter throws,
            // and per §27.6.3.7 AsyncGeneratorAwaitReturn step 7 /
            // §27.6.3.8 AsyncGeneratorYield step 13-14 the
            // abrupt completion must surface — closing the
            // request (suspendedStart / completed) or injecting
            // the throw at the suspended yield site
            // (suspendedYield) so the body's `try { yield }
            // catch` can observe it.
            const ctor_v = intrinsics_mod.getPropertyChain(realm, obj, "constructor") catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => {
                    const ex = realm.pending_exception orelse Value.undefined_;
                    realm.pending_exception = null;
                    try realm.enqueueAsyncGenReturnAfterAwait(gen, ex, true);
                    return;
                },
            };
            _ = ctor_v;
            if (obj.promise_state == .pending) {
                // Register the gen as a waiter on the Promise,
                // flagging it so `settlePromiseInternal` routes
                // the resume through
                // `async_gen_return_after_await` (which drives
                // the body's return-completion) rather than the
                // normal `async_resume` (which drives a normal
                // yield-resume).
                gen.awaiting_return_completion = true;
                const waiters = try obj.promiseWaitersPtr(realm.allocator);
                try waiters.append(realm.allocator, gen);
                return;
            }
            try realm.enqueueAsyncGenReturnAfterAwait(gen, obj.promise_value, obj.promise_state == .rejected);
            return;
        }
        // Thenable check — §27.7.5.3 step 1 routes through
        // §27.2.1.3.2 Promise Resolve Functions 9.b: read the
        // `.then` property. The `get then` accessor in the
        // targeted fixture surfaces here.
        const then_v = intrinsics_mod.getPropertyChain(realm, obj, "then") catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                const ex = realm.pending_exception orelse Value.undefined_;
                realm.pending_exception = null;
                try realm.enqueueAsyncGenReturnAfterAwait(gen, ex, true);
                return;
            },
        };
        if (heap_mod.valueAsFunction(then_v) != null) {
            // Callable thenable: §27.2.1.3.2 step 12 enqueues
            // PromiseResolveThenableJob; we then register the
            // gen as a waiter on the synthesised Promise.
            const promise_v = @import("../builtins/promise.zig").allocatePromise(realm, .pending, Value.undefined_) catch return error.OutOfMemory;
            const promise_obj = heap_mod.valueAsPlainObject(promise_v) orelse return error.OutOfMemory;
            try realm.enqueueThenableJob(promise_v, v, then_v);
            gen.awaiting_return_completion = true;
            const waiters = try promise_obj.promiseWaitersPtr(realm.allocator);
            try waiters.append(realm.allocator, gen);
            return;
        }
        // Non-callable `.then` (or thenable with falsy `.then`):
        // §27.2.1.3.2 step 9-10 fall through to FulfillPromise
        // with the resolution as-is. The targeted
        // `yield-return-then-getter-ticks.js` fixture exercises
        // this — we've fired the `get then` accessor above; now
        // defer one tick and propagate the thenable as the
        // return value.
        try realm.enqueueAsyncGenReturnAfterAwait(gen, v, false);
        return;
    }
    try realm.enqueueAsyncGenReturnAfterAwait(gen, v, false);
}

/// §27.6.3.6 AsyncGeneratorYield — produce the next() promise.
/// If `raw` is already-settled, unwrap synchronously. If pending,
/// register a reaction so the outer promise settles when `raw`
/// does, with the value transformed into an iterator result.
pub fn wrapAsyncGenResult(realm: *Realm, raw: Value, done: bool) @import("../function.zig").NativeError!Value {
    // §27.6.1.6 AsyncFromSyncIteratorContinuation steps 3-9.
    // step 3: valueWrapper = PromiseResolve(%Promise%, value).
    //   - value is a same-realm Promise → valueWrapper IS value.
    //   - value is a non-Promise        → valueWrapper is a fresh
    //                                     already-fulfilled Promise.
    // step 5-6: onFulfilled = the value-unwrap closure that builds
    //   CreateIterResultObject(v, done).
    // step 9: PerformPromiseThen(valueWrapper, onFulfilled, ...).
    //
    // PerformPromiseThen ALWAYS schedules the reaction as a job —
    // even when valueWrapper is already settled there is no
    // synchronous fast path. So `next()` returns a *pending*
    // capability Promise and the `{value, done}` unwrap is
    // observable exactly one tick later. The fixture
    // `for-await-of/ticks-with-sync-iter-resolved-promise-and-
    // constructor-lookup.js` counts on that tick.
    const outer = intrinsics_mod.allocatePromiseFor(realm, null, .pending, Value.undefined_) catch return error.OutOfMemory;
    const wrap_fn = realm.heap.allocateFunctionNative(
        if (done) iterResultDoneTrue else iterResultDoneFalse,
        1,
        "asyncGenYield",
    ) catch return error.OutOfMemory;
    wrap_fn.has_construct = false;
    const wrap_v = heap_mod.taggedFunction(wrap_fn);
    const settled = unwrapSettledPromise(raw);
    switch (settled) {
        .fulfilled => |v| {
            // valueWrapper already fulfilled → queue the unwrap
            // reaction as a job (one tick of latency).
            try realm.enqueuePromiseReaction(wrap_v, v, outer, false);
        },
        .rejected => |ex| {
            // valueWrapper rejected, onRejected is undefined here
            // (the close-on-rejection branch is handled by
            // `wrapAsyncGenResultWithClose`) → the rejection
            // propagates to the capability Promise, still deferred
            // one tick per PerformPromiseThen.
            try realm.enqueuePromiseReaction(Value.undefined_, ex, outer, true);
        },
        .pending => |inner_obj| {
            // valueWrapper still pending → register the unwrap
            // reaction; it fires when the inner Promise settles.
            const reactions = inner_obj.promiseReactionsPtr(realm.allocator) catch return error.OutOfMemory;
            reactions.append(realm.allocator, .{
                .on_fulfilled = wrap_v,
                .on_rejected = Value.undefined_,
                .result_promise = outer,
            }) catch return error.OutOfMemory;
        },
        .none => {
            // value is not a Promise → PromiseResolve made a fresh
            // already-fulfilled valueWrapper; PerformPromiseThen
            // then defers the unwrap one tick.
            try realm.enqueuePromiseReaction(wrap_v, raw, outer, false);
        },
    }
    return outer;
}

fn iterResultDoneFalse(realm: *Realm, this_value: Value, args: []const Value) @import("../function.zig").NativeError!Value {
    _ = this_value;
    const v = if (args.len > 0) args[0] else Value.undefined_;
    return genResultObject(realm, v, false) catch return error.OutOfMemory;
}
fn iterResultDoneTrue(realm: *Realm, this_value: Value, args: []const Value) @import("../function.zig").NativeError!Value {
    _ = this_value;
    const v = if (args.len > 0) args[0] else Value.undefined_;
    return genResultObject(realm, v, true) catch return error.OutOfMemory;
}

const SettledOutcome = union(enum) {
    none,
    fulfilled: Value,
    rejected: Value,
    pending: *JSObject,
};

/// Classify `v` as a Promise: `none` if not, otherwise return
/// the inner state. `pending` carries the promise object so the
/// caller can register a reaction.
fn unwrapSettledPromise(v: Value) SettledOutcome {
    const obj = heap_mod.valueAsPlainObject(v) orelse return .none;
    return switch (obj.promise_state) {
        .fulfilled => .{ .fulfilled = obj.promise_value },
        .rejected => .{ .rejected = obj.promise_value },
        .pending => .{ .pending = obj },
        .none => .none,
    };
}

fn asyncGenReturn(realm: *Realm, this_value: Value, args: []const Value) @import("../function.zig").NativeError!Value {
    // §27.6.1.3 step 2 — IfAbruptRejectPromise on brand check.
    if (asyncGenBrandCheck(realm, this_value, "AsyncGenerator.prototype.return called on non-async-generator")) |ex| {
        return intrinsics_mod.allocatePromiseFor(realm, null, .rejected, ex) catch return error.OutOfMemory;
    }
    const obj = heap_mod.valueAsPlainObject(this_value).?;
    const gen = obj.generator_ref.?;
    const ret_v: Value = if (args.len > 0) args[0] else Value.undefined_;
    return asyncGenDispatch(realm, gen, .{ .return_value = ret_v });
}

fn asyncGenThrow(realm: *Realm, this_value: Value, args: []const Value) @import("../function.zig").NativeError!Value {
    // §27.6.1.4 step 2 — IfAbruptRejectPromise on brand check.
    if (asyncGenBrandCheck(realm, this_value, "AsyncGenerator.prototype.throw called on non-async-generator")) |ex| {
        return intrinsics_mod.allocatePromiseFor(realm, null, .rejected, ex) catch return error.OutOfMemory;
    }
    const obj = heap_mod.valueAsPlainObject(this_value).?;
    const gen = obj.generator_ref.?;
    const ex_v: Value = if (args.len > 0) args[0] else Value.undefined_;
    return asyncGenDispatch(realm, gen, .{ .throw_value = ex_v });
}

/// §27.5.1 — Generator.prototype.{next,return,throw} require
/// `this` to have a real `[[GeneratorState]]` slot. Cynic
/// tracks it via `obj.generator_ref` (which must point at a
/// non-async generator). Wrong-receiver → TypeError per spec.
fn genBrandCheckTypeError(realm: *Realm, this_value: Value, msg: []const u8) ?@import("../function.zig").NativeError {
    const obj = heap_mod.valueAsPlainObject(this_value) orelse {
        const ex = intrinsics_mod.newTypeError(realm, msg) catch return error.OutOfMemory;
        realm.pending_exception = ex;
        return error.NativeThrew;
    };
    const gen = obj.generator_ref orelse {
        const ex = intrinsics_mod.newTypeError(realm, msg) catch return error.OutOfMemory;
        realm.pending_exception = ex;
        return error.NativeThrew;
    };
    if (gen.is_async) {
        const ex = intrinsics_mod.newTypeError(realm, msg) catch return error.OutOfMemory;
        realm.pending_exception = ex;
        return error.NativeThrew;
    }
    return null;
}

fn genNext(realm: *Realm, this_value: Value, args: []const Value) @import("../function.zig").NativeError!Value {
    if (genBrandCheckTypeError(realm, this_value, "Generator method called on non-generator")) |err| return err;
    const obj = heap_mod.valueAsPlainObject(this_value).?;
    const gen = obj.generator_ref.?;
    const sent: Value = if (args.len > 0) args[0] else Value.undefined_;
    const outcome = resumeGenerator(realm.allocator, realm, gen, sent) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.NativeThrew,
    };
    switch (outcome) {
        .yielded => |v| {
            // §15.5.5 step 7.a.iv — when sync `yield*` parked
            // via `gen_yield_iter_result`, the inner iterator's
            // result object is yielded out verbatim. Otherwise
            // wrap as CreateIterResultObject(value, false).
            if (gen.yielded_iter_result) {
                gen.yielded_iter_result = false;
                return v;
            }
            return genResultObject(realm, v, false) catch return error.OutOfMemory;
        },
        .value => |v| return genResultObject(realm, v, true) catch return error.OutOfMemory,
        .thrown => |ex| {
            realm.pending_exception = ex;
            return error.NativeThrew;
        },
    }
}

fn genReturn(realm: *Realm, this_value: Value, args: []const Value) @import("../function.zig").NativeError!Value {
    if (genBrandCheckTypeError(realm, this_value, "Generator.prototype.return called on non-generator")) |err| return err;
    const obj = heap_mod.valueAsPlainObject(this_value).?;
    const gen = obj.generator_ref.?;
    const arg: Value = if (args.len > 0) args[0] else Value.undefined_;
    // §27.5.1.3 step 1 → §27.5.1.2 GeneratorValidate step 5 — a
    // re-entrant `iter.return(...)` from inside the generator
    // body itself observes state == .executing and must throw
    // TypeError. The body's own unwind will mark the generator
    // completed when the propagated TypeError reaches the body
    // tail (§27.5.3.10 step 4.d), so no state edit is needed
    // here.
    if (gen.state == .executing) {
        const ex = makeTypeError(realm, "Generator is already running") catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.NativeThrew,
        };
        realm.pending_exception = ex;
        return error.NativeThrew;
    }
    // §27.5.1.3 step 3 — if the generator is suspended, drive a
    // return-completion through any pending `try { … } finally`
    // blocks. `initial` / `completed` skip the body re-entry:
    // the spec calls GeneratorResumeAbrupt only if the generator
    // is suspended at a yield (steps 3.b / 3.c). For the initial
    // state, the body has never run, so there can be no
    // surviving finally to honour; for completed, we're a no-op.
    if (gen.state == .suspended) {
        gen.pending_return = arg;
        const outcome = resumeGenerator(realm.allocator, realm, gen, Value.undefined_) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.NativeThrew,
        };
        switch (outcome) {
            // Finally body completed normally — surface the
            // original return-completion value.
            .value => |v| return genResultObject(realm, v, true) catch return error.OutOfMemory,
            // Finally body threw or `return`ed with its own
            // value — §14.15.3 step 4 (abrupt finally replaces
            // the outer completion outright). For a thrown
            // finally we surface that throw to the caller.
            .thrown => |ex| {
                realm.pending_exception = ex;
                return error.NativeThrew;
            },
            // Finally body yielded again (e.g. `try { yield }
            // finally { yield }`). Spec allows it; surface as
            // `{value, done:false}`. If the inner `yield*`
            // delegated via `gen_yield_iter_result`, pass the
            // iter result through unchanged (§15.5.5 7.a.iv).
            .yielded => |v| {
                if (gen.yielded_iter_result) {
                    gen.yielded_iter_result = false;
                    return v;
                }
                return genResultObject(realm, v, false) catch return error.OutOfMemory;
            },
        }
    }
    gen.state = .completed;
    return genResultObject(realm, arg, true) catch return error.OutOfMemory;
}

fn genThrow(realm: *Realm, this_value: Value, args: []const Value) @import("../function.zig").NativeError!Value {
    if (genBrandCheckTypeError(realm, this_value, "Generator.prototype.throw called on non-generator")) |err| return err;
    const obj = heap_mod.valueAsPlainObject(this_value).?;
    const gen = obj.generator_ref.?;
    const arg: Value = if (args.len > 0) args[0] else Value.undefined_;
    // §27.5.1.4 GeneratorResumeAbrupt(throw). State machine:
    //   • .initial   → close and rethrow
    //   • .completed → just rethrow
    //   • .executing → "Generator is already running"
    //   • .suspended → inject throw at the yield site so any
    //     surrounding `try { yield } catch` / `finally` runs.
    if (gen.state == .initial) {
        gen.state = .completed;
        realm.pending_exception = arg;
        return error.NativeThrew;
    }
    if (gen.state == .completed) {
        realm.pending_exception = arg;
        return error.NativeThrew;
    }
    if (gen.state == .executing) {
        const ex = makeTypeError(realm, "Generator is already running") catch return error.OutOfMemory;
        realm.pending_exception = ex;
        return error.NativeThrew;
    }
    gen.pending_throw = arg;
    const outcome = resumeGenerator(realm.allocator, realm, gen, Value.undefined_) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.NativeThrew,
    };
    switch (outcome) {
        .yielded => |v| {
            // §15.5.5 7.a.iv inner-iter result pass-through.
            if (gen.yielded_iter_result) {
                gen.yielded_iter_result = false;
                return v;
            }
            return genResultObject(realm, v, false) catch return error.OutOfMemory;
        },
        .value => |v| return genResultObject(realm, v, true) catch return error.OutOfMemory,
        .thrown => |ex| {
            realm.pending_exception = ex;
            return error.NativeThrew;
        },
    }
}

fn genSymbolIterator(realm: *Realm, this_value: Value, args: []const Value) @import("../function.zig").NativeError!Value {
    _ = realm;
    _ = args;
    return this_value;
}
