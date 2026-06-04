//! `JSGenerator` — runtime state for a `function*` instance.
//!
//! A generator carries its entire frame state across `yield`
//! suspensions. On `gen.next(arg)`:
//! 1. The runtime pushes a frame whose `chunk`, `ip`,
//! `accumulator`, `registers`, `env`, `this_value`,
//! `home_object`, and `argc` are restored from the
//! generator's slots.
//! 2. `accumulator` is overwritten with `arg` so the user's
//! `let x = yield e` reads the sent value.
//! 3. The dispatch loop runs until either a `gen_yield` op
//! (suspends and returns `{value, done: false}`) or a
//! `Return` (completes and returns `{value, done: true}`).
//!
//! Spec anchor: §27.5 GeneratorObjects.

const std = @import("std");

const Value = @import("value.zig").Value;
const Chunk = @import("../bytecode/chunk.zig").Chunk;
const Environment = @import("environment.zig").Environment;
const JSObject = @import("object.zig").JSObject;

/// §27.5.3.7 / §15.5.5 — kind of completion the surrounding
/// generator body should observe when resumed. `yield*` reads
/// this after every inner-loop `gen_yield` so it can forward
/// `received` to the inner iterator's `next` / `return` / `throw`
/// per spec.
pub const ResumeKind = enum(u8) {
    /// Plain `.next(v)` — resume the body with `v` in the
    /// accumulator. Default after a `gen_yield` if nothing else
    /// was injected.
    normal,
    /// `.return(v)` was called while the body was suspended.
    /// `yield*` forwards via `iterator.return(v)`; outside
    /// `yield*` the surrounding return-completion drive runs
    /// finally blocks before the gen settles.
    return_value,
    /// `.throw(e)` was called while the body was suspended.
    /// `yield*` forwards via `iterator.throw(e)`; outside
    /// `yield*` the spec already injected the throw at the yield
    /// site via `unwindThrow` before resume.
    throw_value,
};

pub const GeneratorState = enum(u8) {
    /// Newly allocated; body hasn't run.
    initial,
    /// Yielded; ready to resume.
    suspended,
    /// Currently running (re-entrancy guard for `gen.next()`
    /// called inside the generator's own body).
    executing,
    /// `Return` reached or the body threw uncaught.
    completed,
};

/// §27.6.3 [[AsyncGeneratorState]]. Distinct from `GeneratorState`
/// because async generators have extra transitions (queue-drain
/// entry/exit, await-suspend). Only meaningful when both
/// `is_async = true` and `is_async_generator = true`.
///   • `suspended_start` — fresh, body never resumed
///   • `suspended_yield` — paused on yield, awaiting next request
///   • `suspended_await` — paused on await, microtask will resume
///   • `executing`       — body actively running on behalf of the
///     queue head
///   • `completed`       — body returned / threw uncaught
pub const AsyncGeneratorState = enum(u8) {
    suspended_start,
    suspended_yield,
    suspended_await,
    executing,
    completed,
};

/// §27.6.3.5 AsyncGeneratorRequest [[Completion]] — the kind of
/// completion to inject when the drain resumes the body for this
/// request. `.normal` is `.next(v)`; `.return_value` is `.return(v)`
/// (becomes a return-completion at the yield site); `.throw_value`
/// is `.throw(v)` (becomes a throw-completion at the yield site).
pub const Completion = union(enum) {
    normal: Value,
    return_value: Value,
    throw_value: Value,
};

/// §27.6.3.5 AsyncGeneratorRequest. Each pending `.next` /
/// `.return` / `.throw` call sits here until the drain pops it.
/// `capability_promise` is the [[Capability]].[[Promise]] returned
/// synchronously to user JS; the drain settles it when the body
/// reaches the matching yield / return / throw.
pub const AsyncGeneratorRequest = struct {
    completion: Completion,
    capability_promise: *JSObject,
};

/// Per-generator saved frame. Allocated by the runtime when a
/// `function*` instance is called; freed by mark-sweep when no
/// longer reachable.
///
/// As of later the same shape backs `async function` suspension —
/// `is_async = true` distinguishes the path. On a pending
/// `await`, the runtime saves the frame into the gen, registers
/// the gen as a "waiter" on the awaited Promise, and unwinds.
/// When the Promise settles, a microtask resumes the gen and
/// either continues or settles `result_promise` accordingly.
pub const JSGenerator = struct {
    /// Body's compiled bytecode. Borrowed from the function
    /// template's chunk.
    chunk: *const Chunk,
    /// Resume point. 0 on first call (start of body).
    ip: usize = 0,
    /// Accumulator at last suspension (or the arg sent in via
    /// `gen.next(arg)` just before resume).
    accumulator: Value = Value.undefined_,
    /// Owned register file. Allocated once at `function*` call
    /// time; freed in `deinit`.
    registers: []Value,
    /// Lexical env at last suspension.
    env: ?*Environment,
    this_value: Value = Value.undefined_,
    home_object: ?*JSObject = null,
    home_function: ?*@import("function.zig").JSFunction = null,
    argc: u8 = 0,
    state: GeneratorState = .initial,
    /// Mark color. `gen.mark_color == heap.live_color` means "live
    /// this cycle". See `JSObject.mark_color` for the protocol.
    mark_color: u1 = 0,
    /// Generational-GC age. Fresh allocations start `.young`; a
    /// young generator surviving a `collectYoung` is promoted to
    /// `.mature` and relinked into the mature list.
    generation: @import("heap.zig").Generation = .young,
    /// Set when this generator is in the heap's remembered set as
    /// a known old→young store source.
    in_remembered_set: bool = false,
    /// True when this generator backs an `async function`'s
    /// frame rather than a `function*`. Drives the await /
    /// return / throw paths to settle `result_promise` instead
    /// of yielding `{value, done}` records.
    is_async: bool = false,
    /// True when this generator backs an `async function*`
    /// (not a plain `async function`). Drives the §27.6.3
    /// queue-based drain: each `.next` / `.return` / `.throw`
    /// is buffered into `queue` and processed one at a time by
    /// `asyncGeneratorResumeNext`. Plain async functions
    /// (`is_async = true`, `is_async_generator = false`) settle
    /// `result_promise` directly with no queue.
    is_async_generator: bool = false,
    /// §27.6.3 [[AsyncGeneratorState]]. Only meaningful when
    /// `is_async_generator = true`; the sync-gen / plain-async-fn
    /// paths still drive `state` (above).
    async_state: AsyncGeneratorState = .suspended_start,
    /// §27.6.3.4 [[AsyncGeneratorQueue]]. Buffered requests
    /// drained one at a time by `asyncGeneratorResumeNext`.
    /// The head (index 0) is the request currently being
    /// processed when `async_state` is `.executing` or
    /// `.suspended_await`.
    queue: std.ArrayListUnmanaged(AsyncGeneratorRequest) = .empty,
    /// For async functions only: the Promise the function
    /// returned to its caller. Settled fulfilled when the body
    /// returns normally, rejected when it throws uncaught. The
    /// caller observes settlement either synchronously (body
    /// completed before returning) or via a microtask drain
    /// (body suspended on a pending await).
    result_promise: ?Value = null,
    /// §16.2.1.5.1 [[IsAsync]] — the ModuleRecord whose namespace
    /// this generator's `module_export` ops publish to. For a
    /// top-level-await module body it's the module being
    /// evaluated; for a plain `async function` it's the callee's
    /// `JSFunction.owning_module` (the module the function was
    /// *defined* in). Set by `startAsyncCall`, restored by the
    /// drain so `module_export` finds the right namespace on a
    /// resume that happens after the module body has returned and
    /// unwound `realm.current_module`. Null for async functions
    /// defined outside any module (plain scripts).
    owning_module: ?*@import("module.zig").ModuleRecord = null,
    /// §10.2.5 / §8.3 — the [[Realm]] of the generator (async) function
    /// this generator backs. The resumed body frame's `running_realm`
    /// is set from this so a body's free *global* references resolve
    /// through the function's own global environment, not whichever
    /// realm happens to be running the resume (a cross-realm
    /// `Reflect.construct(otherRealm.GeneratorFunction, …)` or
    /// `otherRealm.eval("(function*(){})")()` invoked from another
    /// realm). Null falls back to the resuming realm (single-realm
    /// case, unchanged). Borrowed pointer — the realm outlives the
    /// generator (child realms are anchored on the parent until
    /// teardown), so it is not a GC root.
    realm: ?*@import("realm.zig").Realm = null,
    /// §27.5.1.3 GeneratorPrototype.return — when set, the next
    /// `resumeGenerator` injects a return-completion at the
    /// yield site so any pending `try { … } finally { … }`
    /// blocks run before settlement. The value is the argument
    /// to `.return(v)`; the resume helper consumes (clears) the
    /// field on entry. Cleared on the way out — a finally that
    /// `throw`s or `return`s replaces the completion outright
    /// (§14.15.3 step 4).
    pending_return: ?Value = null,
    /// §27.5.1.4 GeneratorPrototype.throw — when set, the next
    /// `resumeGenerator` injects a throw-completion at the
    /// yield site so any surrounding `try { … } catch { … }` /
    /// `finally { … }` runs. The value is the argument to
    /// `.throw(e)`. Consumed (cleared) on entry by the resume
    /// helper.
    pending_throw: ?Value = null,
    /// §27.5.3.7 / §15.5.5 — surfaced by the new `gen_resume_kind`
    /// op to the body after every `gen_yield`. The compiler
    /// uses it inside `yield*` to forward the right method
    /// (`next` / `return` / `throw`) to the inner iterator.
    /// Reset to `.normal` after each read.
    resume_kind: ResumeKind = .normal,
    /// §27.6.3.7 step 8.b — when the gen is suspended waiting
    /// for an `Await(resumptionValue.[[Value]])` to settle for
    /// a return-completion, this flag is set. The
    /// `settlePromiseInternal` waiter walk then routes the
    /// resume through `async_gen_return_after_await` instead of
    /// the normal `async_resume` microtask — the body's finally
    /// machinery sees a return-completion with the awaited
    /// value rather than treating it as a plain yield-resume.
    awaiting_return_completion: bool = false,
    /// §14.15.3 step 4 + §27.5.1.3 — when a return-completion
    /// drive lands on a `try { … } finally { F }` and `F`
    /// suspends on a yield, the original return value would
    /// otherwise be lost across the resume. We stash it here so
    /// that the next `resumeGenerator` recognises the synthetic
    /// rethrow at the end of `F` and surfaces the value as a
    /// clean `.value` outcome rather than letting the sentinel
    /// throw escape unchecked. The fixture
    /// `built-ins/AsyncGeneratorPrototype/return/
    /// return-suspendedYield-try-finally.js` exercises this —
    /// `.return('sent-value')` resumes inside the finally,
    /// which `yield 2`s out; the following `.next()` must
    /// surface `{value: 'sent-value', done: true}`.
    pending_return_completion: ?Value = null,
    /// Companion to `resume_kind`. For `.return_value` this is the
    /// `.return(v)` argument; for `.throw_value` it's the
    /// `.throw(e)` argument. The accumulator on resume already
    /// holds the same value (so `let x = yield e` still reads
    /// correctly under normal `.next(v)`), but `yield*` needs it
    /// in a register independent of acc.
    resume_value: Value = Value.undefined_,
    /// §15.5.5 step 7.a.iv — when the body suspended via
    /// `gen_yield_iter_result`, the accumulator already holds a
    /// spec-shaped IteratorResult object. `gen.next()` returns
    /// it verbatim instead of wrapping in a fresh
    /// CreateIterResultObject. Reset to false on each resume.
    yielded_iter_result: bool = false,

    pub fn init(
        allocator: std.mem.Allocator,
        chunk: *const Chunk,
        register_count: u8,
        captured_env: ?*Environment,
        this_value: Value,
    ) !*JSGenerator {
        const regs = try allocator.alloc(Value, register_count);
        @memset(regs, Value.undefined_);
        const g = try allocator.create(JSGenerator);
        g.* = .{
            .chunk = chunk,
            .registers = regs,
            .env = captured_env,
            .this_value = this_value,
        };
        return g;
    }

    pub fn deinit(self: *JSGenerator, allocator: std.mem.Allocator) void {
        allocator.free(self.registers);
        self.queue.deinit(allocator);
        allocator.destroy(self);
    }
};
