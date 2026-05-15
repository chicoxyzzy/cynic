//! Switch-dispatched bytecode interpreter — Cynic's T0 tier.
//!
//! Reads a `Chunk` produced by the bytecode compiler and runs it
//! against a `Realm`'s heap. The dispatch loop is a single
//! `while` + `switch (op)` — clean, portable, branch-predictor-
//! friendly enough for an interpreter at this stage. Computed-
//! goto / threaded dispatch is a known optimisation (V8 Ignition,
//! JSC LLInt) — applied later, behind a configuration flag.
//!
//! Numeric arithmetic uses an int32 fast path when both operands
//! are Smis and the result also fits. Mixed-type and overflow
//! paths fall back to f64 doubles, matching the spec's Number
//! semantics (§6.1.6.1). String concatenation in `+` is the only
//! non-numeric arithmetic shortcut later supports — every other
//! operator coerces non-numbers via `ToNumber`.

const std = @import("std");

const Value = @import("value.zig").Value;
const JSString = @import("string.zig").JSString;
const JSFunction = @import("function.zig").JSFunction;
const object_mod = @import("object.zig");
const JSObject = object_mod.JSObject;
const Environment = @import("environment.zig").Environment;
const heap_mod = @import("heap.zig");
const intrinsics_mod = @import("intrinsics.zig");
const Realm = @import("realm.zig").Realm;
const Op = @import("../bytecode/op.zig").Op;
const Chunk = @import("../bytecode/chunk.zig").Chunk;
const Handler = @import("../bytecode/chunk.zig").Handler;
const parser_mod = @import("../parser/parser.zig");
const compiler_mod = @import("../bytecode/compiler.zig");

// Arithmetic / coercion helpers live in `interpreter_arith.zig`.
// Pull every fn the dispatch loop calls into local aliases so
// callsites stay short.
const arith = @import("interpreter_arith.zig");
const StringSlice = arith.StringSlice;
const toBoolean = arith.toBoolean;
const toNumber = arith.toNumber;
const toInt32 = arith.toInt32;
const toUint32 = arith.toUint32;
const bigintArith = arith.bigintArith;
const numericBinary = arith.numericBinary;
const bitwiseBinary = arith.bitwiseBinary;
const unaryNegate = arith.unaryNegate;
const unaryBitNot = arith.unaryBitNot;
const unaryToNumber = arith.unaryToNumber;
const addValues = arith.addValues;
const valueToOwnedString = arith.valueToOwnedString;
const strictEq = arith.strictEq;
const looseEq = arith.looseEq;
const relational = arith.relational;
const typeOf = arith.typeOf;
const NumericOp = arith.NumericOp;
const BigIntOp = arith.BigIntOp;
const BitwiseOp = arith.BitwiseOp;
const RelOp = arith.RelOp;

/// Cap on simultaneously-active call frames. A runaway recursion
/// trips `RangeError("Maximum call stack size exceeded")`. The
/// number is comfortably below where Zig's own stack would also
/// blow up — we keep dispatch on the host stack but bound the
/// per-call allocation work.
const max_call_frames: usize = 1024;

pub const CallFrame = struct {
    chunk: *const Chunk,
    ip: usize,
    accumulator: Value,
    /// Owned register file — used for anonymous expression
    /// temporaries and for receiving call arguments before the
    /// callee's prologue copies them into env slots.
    registers: []Value,
    /// Lexical environment for named bindings. `null` until the
    /// frame's `MakeEnvironment` instruction runs (the very
    /// first opcode the compiler emits for any function /
    /// script).
    env: ?*Environment,
    /// `this` binding for the current call (§9.1.1.3). Top-level
    /// strict scripts have `this = undefined` (§9.4.7). Regular
    /// function calls receive whatever the caller passed (in
    /// strict mode that's whatever they explicitly bound or
    /// undefined). Constructor calls (`new`) receive the freshly
    /// allocated instance. Arrow functions inherit lexically —
    /// the compiler doesn't emit `LdaThis` for them; they read
    /// the captured frame's binding indirectly.
    this_value: Value,
    /// True if this frame was entered via `new f(args)`. The
    /// `Return` opcode uses it to coerce the result: if the
    /// constructor returned an object, that wins; otherwise the
    /// freshly allocated `this` does (§13.3.5.1.1).
    is_construct: bool = false,
    /// §13.3.12 NewTarget — the constructor function that was
    /// originally invoked via `new` for this call chain.
    /// `undefined` for plain calls. Set on frame entry from the
    /// `new_call` opcode's site; preserved across `super(...)`
    /// hops so the derived constructor sees the original
    /// `new.target` even though `super()` invokes the parent
    /// constructor.
    new_target: Value = Value.undefined_,
    /// `[[ConstructorKind]] === derived` (§10.2.1) — set when
    /// the callee is the constructor of a `class C extends …`.
    /// On the `Return` op, a derived constructor that produces
    /// a non-Object, non-undefined value throws TypeError per
    /// §10.2.1.4 step 14 (instead of falling back to `this`,
    /// which is the base-class behavior).
    is_derived_ctor: bool = false,
    /// §10.2.1.4 — `[[ThisBindingStatus]]` for derived class
    /// constructors. `false` on entry; flipped by any `super(...)`
    /// op. If the constructor body falls off the end (returns
    /// undefined) with this still false, a ReferenceError is
    /// thrown per §10.2.1.4 step 5 / §10.2.1.3 step 11.
    super_called: bool = false,
    /// `[[HomeObject]]` (§10.2.5) of the function executing in
    /// this frame. Set on entry from the callee's
    /// `JSFunction.home_object`. `super_get` / `super_call`
    /// resolve through the home object's `[[Prototype]]`.
    home_object: ?*JSObject = null,
    /// `[[HomeObject]]` for static methods (where the home is the
    /// class constructor function). Mutually exclusive with
    /// `home_object` — when this is set, super lookups walk
    /// `home_function.proto`.
    home_function: ?*JSFunction = null,
    /// Number of arguments the caller actually passed. Recorded
    /// at frame-push time so a synthesised
    /// `class B extends A {}` default constructor (which lowers
    /// to `super_call_forward`) can replay the caller's full
    /// arg list without parsing rest params.
    argc: u8 = 0,
    /// The generator that owns this frame, if running a
    /// `function*` body. Set on resume; null for ordinary
    /// frames. When `gen_yield` fires, the dispatch loop saves
    /// state into this generator and unwinds the loop.
    generator: ?*@import("generator.zig").JSGenerator = null,
    /// Whether `Return` should free `registers`. Generators own
    /// their register file separately, so the dispatch loop
    /// must not free it on Return.
    owns_registers: bool = true,
    /// Set on calls to `async function` bodies. The Return op
    /// wraps the returned value in `Promise.resolve(...)` and
    /// uncaught throws in `Promise.reject(...)` so the caller
    /// observes a Promise — the spec's §27.7 AsyncFunctionStart.
    wrap_return_in_promise: bool = false,
};

pub const RunError = error{
    OutOfMemory,
    /// An opcode byte didn't match any known variant. Indicates a
    /// corrupted chunk or compiler bug; should never happen in
    /// production, surfaced as a hard error here.
    InvalidOpcode,
};

/// Outcome of running a chunk. `.value` is the normal-completion
/// path (the value left in the accumulator at `Return`).
/// `.thrown` is an uncaught exception — the value was raised via
/// `Throw` and not handled by any active try/catch. The caller
/// (CLI, test harness, future built-ins) decides what to do.
pub const RunResult = union(enum) {
    value: Value,
    thrown: Value,
    /// The session was suspended by a `gen_yield`. The caller
    /// (typically `gen.next()`) reads the yielded value, then
    /// either returns `{value, done: false}` to its own caller
    /// or — on `await` — schedules a microtask to resume.
    yielded: Value,
};

pub const EvaluateError = error{
    OutOfMemory,
    ParseError,
    CompileError,
    InvalidOpcode,
};

/// Evaluate `source` as a Script body against `realm`. Parses,
/// compiles, and executes — internal arena holds the AST and
/// chunk for the call's lifetime; the runtime side-effects on
/// `realm.globals`, `realm.heap`, etc. persist past return.
///
/// This is the entry point Cynic offers external code: `cynic
/// run a.js b.js`, the test262 harness loader, and a future REPL
/// all build on it. Multiple calls share the realm — top-level
/// `var` / `let` / `function` bindings declared by an earlier
/// call are visible to later calls (later §16.1.6
/// ScriptEvaluation semantics).
///
/// `.value` / `.yielded` carries the script's completion value;
/// `.thrown` carries an uncaught exception. The caller decides
/// whether a throw is the test's expected outcome — the function
/// itself returns the `RunResult` rather than mapping `.thrown`
/// to a Zig error.
pub fn evaluateScript(
    allocator: std.mem.Allocator,
    realm: *Realm,
    source: []const u8,
) EvaluateError!RunResult {
    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    const program = parser_mod.parseScript(aa, source, null) catch return error.ParseError;
    // The chunk is owned by the realm so that any `JSFunction`
    // declared by this script (which keeps a pointer into the
    // chunk's `function_templates`) outlives the call and stays
    // callable from later `evaluateScript` invocations against
    // the same realm. Heap-allocated so its address is stable
    // across `script_chunks` array growth.
    const chunk_ptr = try realm.allocator.create(Chunk);
    chunk_ptr.* = compiler_mod.compileScriptAsChunk(realm.allocator, realm, &program, source, null) catch {
        realm.allocator.destroy(chunk_ptr);
        return error.CompileError;
    };
    try realm.script_chunks.append(realm.allocator, chunk_ptr);
    // (chunk constants pinned inside `compileScriptAsChunk`)
    return run(allocator, realm, chunk_ptr);
}

/// Run `chunk` to completion. Allocates per-frame register
/// files; the host's `allocator` owns them and they're freed on
/// each `Return` (or on overall run shutdown).
pub fn run(allocator: std.mem.Allocator, realm: *Realm, chunk: *const Chunk) RunError!RunResult {
    var frames: std.ArrayListUnmanaged(CallFrame) = .empty;
    defer {
        for (frames.items) |*f| if (f.owns_registers) allocator.free(f.registers);
        frames.deinit(allocator);
    }

    // Top-level frame. `env` is left null; the script's leading
    // `MakeEnvironment` instruction is the one that allocates it.
    //
    // §10.4.7 — top-level `this` resolves through the
    // global / module Environment Record:
    //   • Module → undefined.
    //   • Script (strict or sloppy) → the global object. Strict
    //     mode only changes `this` for *function* calls; the
    //     script-body `this` is always GlobalThis (§9.3.4).
    // We tell scripts apart from modules by inspecting
    // `realm.current_module`, which `loadModule` sets before
    // delegating to `run`.
    const top_level_this: Value = blk: {
        if (realm.current_module != null) break :blk Value.undefined_;
        if (realm.globals.get("globalThis")) |gt| break :blk gt;
        break :blk Value.undefined_;
    };
    {
        const main_regs = try allocator.alloc(Value, chunk.register_count);
        @memset(main_regs, Value.undefined_);
        try frames.append(allocator, .{
            .chunk = chunk,
            .ip = 0,
            .accumulator = Value.undefined_,
            .registers = main_regs,
            .env = null,
            .this_value = top_level_this,
            .home_object = null,
            .argc = 0,
        });
    }

    return runFrames(allocator, realm, &frames);
}

/// Allocate a `JSGenerator` for a `function*` invocation and
/// return an iterator-shaped JSObject pointing at it. The
/// generator's `next` / `return` / `throw` / `[Symbol.iterator]`
/// methods are installed once on the realm's
/// `generator_prototype`; this wrapper inherits from that proto.
pub fn wrapGenerator(
    allocator: std.mem.Allocator,
    realm: *Realm,
    chunk: *const @import("../bytecode/chunk.zig").Chunk,
    captured_env: ?*Environment,
    this_value: Value,
    args: []const Value,
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
    // Pre-load argument values into the generator's register
    // file so the function prologue's Ldar / sta_env sequence
    // sees them at indices 0..argc-1.
    var i: usize = 0;
    while (i < args.len and i < gen.registers.len) : (i += 1) {
        gen.registers[i] = args[i];
    }
    gen.argc = @intCast(@min(args.len, std.math.maxInt(u8)));

    const wrapper = realm.heap.allocateObject() catch return error.OutOfMemory;
    wrapper.prototype = ensureGeneratorPrototype(realm) catch return error.OutOfMemory;
    wrapper.generator_ref = gen;

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
    chunk: *const @import("../bytecode/chunk.zig").Chunk,
    captured_env: ?*Environment,
    this_value: Value,
    args: []const Value,
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
    var i: usize = 0;
    while (i < args.len and i < gen.registers.len) : (i += 1) {
        gen.registers[i] = args[i];
    }
    gen.argc = @intCast(@min(args.len, std.math.maxInt(u8)));

    const wrapper = realm.heap.allocateObject() catch return error.OutOfMemory;
    wrapper.prototype = ensureAsyncGeneratorPrototype(realm) catch return error.OutOfMemory;
    wrapper.generator_ref = gen;

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
    proto.prototype = iteratorPrototypeOrObjectPrototype(realm);

    const next_fn = try realm.heap.allocateFunctionNative(genNext, 1, "next");
    next_fn.proto = realm.intrinsics.function_prototype;
    try proto.set(realm.allocator, "next", heap_mod.taggedFunction(next_fn));

    const return_fn = try realm.heap.allocateFunctionNative(genReturn, 1, "return");
    return_fn.proto = realm.intrinsics.function_prototype;
    try proto.set(realm.allocator, "return", heap_mod.taggedFunction(return_fn));

    const throw_fn = try realm.heap.allocateFunctionNative(genThrow, 1, "throw");
    throw_fn.proto = realm.intrinsics.function_prototype;
    try proto.set(realm.allocator, "throw", heap_mod.taggedFunction(throw_fn));

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

fn genResultObject(realm: *Realm, value: Value, done: bool) !Value {
    const obj = try realm.heap.allocateObject();
    obj.prototype = realm.intrinsics.object_prototype;
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
    proto.prototype = realm.intrinsics.object_prototype;
    const sym_iter_fn = try realm.heap.allocateFunctionNative(genSymbolIterator, 0, "[Symbol.asyncIterator]");
    sym_iter_fn.proto = realm.intrinsics.function_prototype;
    try proto.setWithFlags(realm.allocator, "@@asyncIterator", heap_mod.taggedFunction(sym_iter_fn), .{
        .writable = true, .enumerable = false, .configurable = true,
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
    proto.prototype = try ensureAsyncIteratorPrototype(realm);

    const next_fn = try realm.heap.allocateFunctionNative(asyncGenNext, 1, "next");
    next_fn.proto = realm.intrinsics.function_prototype;
    try proto.set(realm.allocator, "next", heap_mod.taggedFunction(next_fn));

    const return_fn = try realm.heap.allocateFunctionNative(asyncGenReturn, 1, "return");
    return_fn.proto = realm.intrinsics.function_prototype;
    try proto.set(realm.allocator, "return", heap_mod.taggedFunction(return_fn));

    const throw_fn = try realm.heap.allocateFunctionNative(asyncGenThrow, 1, "throw");
    throw_fn.proto = realm.intrinsics.function_prototype;
    try proto.set(realm.allocator, "throw", heap_mod.taggedFunction(throw_fn));

    const tag_str = try realm.heap.allocateString("AsyncGenerator");
    try proto.setWithFlags(realm.allocator, "@@toStringTag", Value.fromString(tag_str), .{
        .writable = false,
        .enumerable = false,
        .configurable = true,
    });

    realm.intrinsics.async_generator_prototype = proto;
    return proto;
}

fn asyncGenNext(realm: *Realm, this_value: Value, args: []const Value) @import("function.zig").NativeError!Value {
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
    const outcome = resumeGenerator(realm.allocator, realm, gen, sent) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.NativeThrew,
    };
    switch (outcome) {
        .yielded => |raw| {
            // §27.6.3.6 AsyncGeneratorYield — `yield X` does
            // `Await(X)` first; if Await rejects, the rejection
            // propagates inside the gen body as a throw, which
            // (uncaught) closes the gen. Approximate the closed
            // tail by transitioning state to .completed when the
            // yielded value is a synchronously-rejected promise.
            // Subsequent `.next()` calls then return
            // `{done: true, value: undefined}` per §27.6.3.2
            // step 5. The full Await-propagation rework (so
            // try/catch around yield observes the rejection)
            // is deferred.
            if (isSyncRejectedPromise(raw)) gen.state = .completed;
            return wrapAsyncGenResult(realm, raw, false);
        },
        .value => |raw| return wrapAsyncGenResult(realm, raw, true),
        .thrown => |ex| return intrinsics_mod.allocatePromiseFor(realm, null, .rejected, ex) catch return error.OutOfMemory,
    }
}

/// True iff `v` is a Promise object already in the `rejected`
/// state. Used by async-gen yield's close-on-reject shim.
fn isSyncRejectedPromise(v: Value) bool {
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

/// §27.6.3.6 AsyncGeneratorYield — produce the next() promise.
/// If `raw` is already-settled, unwrap synchronously. If pending,
/// register a reaction so the outer promise settles when `raw`
/// does, with the value transformed into an iterator result.
pub fn wrapAsyncGenResult(realm: *Realm, raw: Value, done: bool) @import("function.zig").NativeError!Value {
    const settled = unwrapSettledPromise(raw);
    switch (settled) {
        .fulfilled => |v| {
            const result = genResultObject(realm, v, done) catch return error.OutOfMemory;
            return intrinsics_mod.allocatePromiseFor(realm, null, .fulfilled, result) catch return error.OutOfMemory;
        },
        .rejected => |ex| {
            return intrinsics_mod.allocatePromiseFor(realm, null, .rejected, ex) catch return error.OutOfMemory;
        },
        .pending => |inner_obj| {
            // Build the outer pending promise. Register a
            // reaction on the inner promise that transforms the
            // resolved value into `{value, done}`.
            const outer = intrinsics_mod.allocatePromiseFor(realm, null, .pending, Value.undefined_) catch return error.OutOfMemory;
            const wrap_fn = realm.heap.allocateFunctionNative(
                if (done) iterResultDoneTrue else iterResultDoneFalse,
                1,
                "asyncGenYield",
            ) catch return error.OutOfMemory;
            wrap_fn.has_construct = false;
            inner_obj.promise_reactions.append(realm.allocator, .{
                .on_fulfilled = heap_mod.taggedFunction(wrap_fn),
                .on_rejected = Value.undefined_,
                .result_promise = outer,
            }) catch return error.OutOfMemory;
            return outer;
        },
        .none => {
            const result = genResultObject(realm, raw, done) catch return error.OutOfMemory;
            return intrinsics_mod.allocatePromiseFor(realm, null, .fulfilled, result) catch return error.OutOfMemory;
        },
    }
}

fn iterResultDoneFalse(realm: *Realm, this_value: Value, args: []const Value) @import("function.zig").NativeError!Value {
    _ = this_value;
    const v = if (args.len > 0) args[0] else Value.undefined_;
    return genResultObject(realm, v, false) catch return error.OutOfMemory;
}
fn iterResultDoneTrue(realm: *Realm, this_value: Value, args: []const Value) @import("function.zig").NativeError!Value {
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

fn asyncGenReturn(realm: *Realm, this_value: Value, args: []const Value) @import("function.zig").NativeError!Value {
    // §27.6.1.3 step 2 — IfAbruptRejectPromise on brand check.
    if (asyncGenBrandCheck(realm, this_value, "AsyncGenerator.prototype.return called on non-async-generator")) |ex| {
        return intrinsics_mod.allocatePromiseFor(realm, null, .rejected, ex) catch return error.OutOfMemory;
    }
    const obj = heap_mod.valueAsPlainObject(this_value).?;
    const gen = obj.generator_ref.?;
    gen.state = .completed;
    const ret_v: Value = if (args.len > 0) args[0] else Value.undefined_;
    const result = genResultObject(realm, ret_v, true) catch return error.OutOfMemory;
    return intrinsics_mod.allocatePromiseFor(realm, null, .fulfilled, result) catch return error.OutOfMemory;
}

fn asyncGenThrow(realm: *Realm, this_value: Value, args: []const Value) @import("function.zig").NativeError!Value {
    // §27.6.1.4 step 2 — IfAbruptRejectPromise on brand check.
    if (asyncGenBrandCheck(realm, this_value, "AsyncGenerator.prototype.throw called on non-async-generator")) |ex| {
        return intrinsics_mod.allocatePromiseFor(realm, null, .rejected, ex) catch return error.OutOfMemory;
    }
    const ex: Value = if (args.len > 0) args[0] else Value.undefined_;
    return intrinsics_mod.allocatePromiseFor(realm, null, .rejected, ex) catch return error.OutOfMemory;
}

/// §27.5.1 — Generator.prototype.{next,return,throw} require
/// `this` to have a real `[[GeneratorState]]` slot. Cynic
/// tracks it via `obj.generator_ref` (which must point at a
/// non-async generator). Wrong-receiver → TypeError per spec.
fn genBrandCheckTypeError(realm: *Realm, this_value: Value, msg: []const u8) ?@import("function.zig").NativeError {
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

fn genNext(realm: *Realm, this_value: Value, args: []const Value) @import("function.zig").NativeError!Value {
    if (genBrandCheckTypeError(realm, this_value, "Generator method called on non-generator")) |err| return err;
    const obj = heap_mod.valueAsPlainObject(this_value).?;
    const gen = obj.generator_ref.?;
    const sent: Value = if (args.len > 0) args[0] else Value.undefined_;
    const outcome = resumeGenerator(realm.allocator, realm, gen, sent) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.NativeThrew,
    };
    switch (outcome) {
        .yielded => |v| return genResultObject(realm, v, false) catch return error.OutOfMemory,
        .value => |v| return genResultObject(realm, v, true) catch return error.OutOfMemory,
        .thrown => |ex| {
            realm.pending_exception = ex;
            return error.NativeThrew;
        },
    }
}

fn genReturn(realm: *Realm, this_value: Value, args: []const Value) @import("function.zig").NativeError!Value {
    if (genBrandCheckTypeError(realm, this_value, "Generator.prototype.return called on non-generator")) |err| return err;
    const obj = heap_mod.valueAsPlainObject(this_value).?;
    const gen = obj.generator_ref.?;
    gen.state = .completed;
    return genResultObject(realm, if (args.len > 0) args[0] else Value.undefined_, true) catch return error.OutOfMemory;
}

fn genThrow(realm: *Realm, this_value: Value, args: []const Value) @import("function.zig").NativeError!Value {
    if (genBrandCheckTypeError(realm, this_value, "Generator.prototype.throw called on non-generator")) |err| return err;
    realm.pending_exception = if (args.len > 0) args[0] else Value.undefined_;
    return error.NativeThrew;
}

fn genSymbolIterator(realm: *Realm, this_value: Value, args: []const Value) @import("function.zig").NativeError!Value {
    _ = realm;
    _ = args;
    return this_value;
}

pub const IterError = error{
    OutOfMemory,
    NotIterable,
    InvalidOpcode,
    /// Iterator-setup observed user code (an accessor getter, a
    /// `next` method call, etc.) that threw. The thrown value
    /// lives in `realm.pending_exception`; the caller must
    /// propagate it instead of synthesising "value is not
    /// iterable" TypeError. §27.1.4.3 GetIterator step 1.a
    /// (`GetMethod` throws) and step 1.b.i (sync fallback
    /// throws) both surface here.
    Propagated,
};

/// §7.4.1 GetIterator. Produce an iterator object for an
/// iterable. Tries the `@@iterator` method first; falls back to
/// an array-like length+index walk so existing arrays / strings
/// still iterate without forcing every host to install a real
/// `@@iterator` on `Array.prototype` / `String.prototype`. The
/// fallback is observably correct (returns `{value, done}` from
/// `.next()`) for the test262 surface that just calls `for-of`
/// over arrays.
/// §27.1.4.3 GetIterator(obj, async) — async variant. Prefers
/// `@@asyncIterator`; if absent, falls back to the sync
/// `@@iterator` (or the array-like-length walk). The for-await
/// step path awaits each `.next()` result, so a sync iterator
/// produces a resolved promise per step automatically via the
/// `await_` opcode.
pub fn openAsyncIterator(
    _: std.mem.Allocator,
    realm: *Realm,
    iterable: Value,
) IterError!Value {
    if (heap_mod.valueAsPlainObject(iterable)) |obj| {
        // §27.1.4.3 step 1.a — GetMethod(obj, @@asyncIterator).
        // Use `getPropertyChain` (accessor-aware); a thrown getter
        // propagates as `Propagated` so the caller hands the
        // user's exception value back instead of synthesising
        // "not async iterable".
        const iter_fn_v = intrinsics_mod.getPropertyChain(realm, obj, "@@asyncIterator") catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.Propagated,
        };
        // §27.1.4.3 step 1.b — method is undefined → fall through
        // to the sync iterator. A callable (function) goes through
        // the async branch.
        if (!iter_fn_v.isUndefined() and !iter_fn_v.isNull()) {
            const iter_fn = heap_mod.valueAsFunction(iter_fn_v) orelse return error.NotIterable;
            const result = callJSFunction(realm.allocator, realm, iter_fn, iterable, &.{}) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return error.InvalidOpcode,
            };
            switch (result) {
                .value, .yielded => |v| {
                    // §7.4.2 GetIteratorDirect step 3 — the
                    // returned value must be an Object.
                    if (heap_mod.valueAsPlainObject(v) == null) return error.NotIterable;
                    return v;
                },
                .thrown => |ex| {
                    realm.pending_exception = ex;
                    return error.Propagated;
                },
            }
        }
    }
    // §27.1.4.3 step 1.b — fall back to sync `@@iterator`,
    // then wrap with §27.6.1.1 CreateAsyncFromSyncIterator so
    // each `.next()` / `.return()` / `.throw()` returns a fresh
    // Promise per §27.6.1.{2,3,4}.
    const sync_iter = try openIterator(realm.allocator, realm, iterable);
    const afsi = @import("builtins/async_iterator.zig");
    return afsi.createAsyncFromSyncIterator(realm, sync_iter) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
    };
}

pub fn openIterator(
    _: std.mem.Allocator,
    realm: *Realm,
    iterable: Value,
) IterError!Value {
    // 1. If iterable carries `@@iterator`, invoke it with the
    // iterable as `this`. The well-known-symbol key is
    // represented by the literal string `"@@iterator"` until
    // Symbol becomes a Value-tag primitive.
    if (heap_mod.valueAsPlainObject(iterable)) |obj| {
        // §7.4.2 GetIterator — accessor-aware so a `get
        // [Symbol.iterator]() { throw … }` style fixture
        // propagates the user exception instead of being
        // squashed to "not iterable".
        const iter_fn_v = intrinsics_mod.getPropertyChain(realm, obj, "@@iterator") catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.Propagated,
        };
        if (!iter_fn_v.isUndefined() and !iter_fn_v.isNull()) {
            const iter_fn = heap_mod.valueAsFunction(iter_fn_v) orelse return error.NotIterable;
            const result = callJSFunction(realm.allocator, realm, iter_fn, iterable, &.{}) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return error.InvalidOpcode,
            };
            switch (result) {
                .value, .yielded => |v| {
                    if (heap_mod.valueAsPlainObject(v) == null) return error.NotIterable;
                    return v;
                },
                .thrown => |ex| {
                    realm.pending_exception = ex;
                    return error.Propagated;
                },
            }
        }
    }

    // 2. Array-like fallback. Builds a plain object with a
    // `next` method that walks `iterable[i]` for `i` in
    // `0..length`. The cursor + target live on the typed
    // `array_like_iter` slot (hidden from JS), mirroring the
    // spec's [[IteratedObject]] + [[NextIndex]] internal slots.
    const has_length = if (heap_mod.valueAsPlainObject(iterable)) |o|
        o.hasOwn("length") or (o.prototype != null and !o.get("length").isUndefined())
    else
        iterable.isString();
    if (!has_length) return error.NotIterable;

    const iter = realm.heap.allocateObject() catch return error.OutOfMemory;
    iter.prototype = realm.intrinsics.object_prototype;
    const state = realm.allocator.create(object_mod.ArrayLikeIterState) catch return error.OutOfMemory;
    state.* = .{ .target = iterable };
    iter.array_like_iter = state;
    const next_fn = realm.heap.allocateFunctionNative(arrayLikeIterNext, 0, "next") catch return error.OutOfMemory;
    next_fn.proto = realm.intrinsics.function_prototype;
    iter.set(realm.allocator, "next", heap_mod.taggedFunction(next_fn)) catch return error.OutOfMemory;
    return heap_mod.taggedObject(iter);
}

/// §14.7.5.6 EnumerateObjectProperties. Walks the object's
/// own + inherited enumerable string-keyed properties
/// (deduplicated, prototype-chain-ordered) and produces an
/// iterator over the snapshot. `null` / `undefined` yield an
/// empty iterator.
///
/// Now (later) consults each property's
/// `PropertyFlags.enumerable` — built-in proto methods install
/// with `enumerable: false`, so user-level for-in correctly
/// skips `Array.prototype.push`, `Object.prototype.toString`,
/// etc. Cynic-internal sentinel properties (those whose name
/// starts with `__cynic_`) are also skipped.
pub fn openForInIterator(
    _: std.mem.Allocator,
    realm: *Realm,
    obj_v: Value,
) RunError!Value {
    const arr = realm.heap.allocateObject() catch return error.OutOfMemory;
    arr.prototype = realm.intrinsics.array_prototype;
    arr.markAsArrayExotic(realm.allocator) catch return error.OutOfMemory;
    var seen: std.StringArrayHashMapUnmanaged(void) = .empty;
    defer seen.deinit(realm.allocator);

    var len: i32 = 0;
    // §10.1.11 — for-in over a Function receiver (e.g. a class
    // constructor with static fields) walks its own properties
    // first, then climbs `proto`. Mirror the JSObject branch
    // below for the function representation.
    if (heap_mod.valueAsFunction(obj_v)) |fn_obj| {
        var fit = fn_obj.properties.iterator();
        while (fit.next()) |entry| {
            const key = entry.key_ptr.*;
            if (std.mem.startsWith(u8, key, "__cynic_")) continue;
            if (!fn_obj.flagsForOwn(key).enumerable) continue;
            const gop = seen.getOrPut(realm.allocator, key) catch return error.OutOfMemory;
            if (gop.found_existing) continue;
            var ibuf: [16]u8 = undefined;
            const islice = std.fmt.bufPrint(&ibuf, "{d}", .{len}) catch unreachable;
            const idx_owned = realm.heap.allocateString(islice) catch return error.OutOfMemory;
            const key_owned = realm.heap.allocateString(key) catch return error.OutOfMemory;
            arr.set(realm.allocator, idx_owned.bytes, Value.fromString(key_owned)) catch return error.OutOfMemory;
            len += 1;
        }
        // Function's [[Prototype]] is typically %Function.prototype%
        // — its inherited methods are all non-enumerable, so we
        // can skip walking the chain. Test fixtures that probe
        // for inherited keys via for-in expect none.
    } else if (heap_mod.valueAsPlainObject(obj_v)) |start_obj| {
        var current: ?*JSObject = start_obj;
        while (current) |cur| {
            // §10.1.11 — within each level, integer-indexed
            // keys come first in ascending numeric order, then
            // string keys in insertion order. Symbol keys
            // would sort last.
            const KeyEntry = struct { idx: u32, key: []const u8 };
            var int_keys: std.ArrayListUnmanaged(KeyEntry) = .empty;
            defer int_keys.deinit(realm.allocator);
            var str_keys: std.ArrayListUnmanaged([]const u8) = .empty;
            defer str_keys.deinit(realm.allocator);

            // §10.4.2 Array exotic — packed elements are own
            // integer-indexed properties for §14.7.5.6
            // EnumerateObjectProperties / `for-in` / `Object.keys`.
            // Holes (slot == hole sentinel) are either absent
            // (sparse) or descriptor-flag-demoted to the named-
            // property bag; the property-bag walker below picks
            // up the latter, so we skip them here either way.
            if (cur.is_array_exotic) {
                if (cur.is_sparse) {
                    var sit = cur.sparse_elements.iterator();
                    while (sit.next()) |entry| {
                        if (@import("object.zig").JSObject.isElementHole(entry.value_ptr.*)) continue;
                        const idx = entry.key_ptr.*;
                        var ibuf: [16]u8 = undefined;
                        const ks = std.fmt.bufPrint(&ibuf, "{d}", .{idx}) catch continue;
                        const key_owned_str = realm.heap.allocateString(ks) catch return error.OutOfMemory;
                        int_keys.append(realm.allocator, .{ .idx = idx, .key = key_owned_str.bytes }) catch return error.OutOfMemory;
                    }
                } else {
                    var ei: u32 = 0;
                    while (ei < cur.elements.items.len) : (ei += 1) {
                        if (@import("object.zig").JSObject.isElementHole(cur.elements.items[ei])) continue;
                        var ibuf: [16]u8 = undefined;
                        const ks = std.fmt.bufPrint(&ibuf, "{d}", .{ei}) catch continue;
                        const key_owned_str = realm.heap.allocateString(ks) catch return error.OutOfMemory;
                        int_keys.append(realm.allocator, .{ .idx = ei, .key = key_owned_str.bytes }) catch return error.OutOfMemory;
                    }
                }
            }

            // §14.7.5.6 EnumerateObjectProperties — at each level
            // we shadow non-enumerable own keys against the
            // prototype chain. So we collect all own keys (to
            // populate `seen`) but only emit the enumerable ones.
            // `shadow_only` carries own-but-non-enumerable names so
            // they get added to `seen` after emission without ever
            // being yielded themselves.
            var shadow_only: std.ArrayListUnmanaged([]const u8) = .empty;
            defer shadow_only.deinit(realm.allocator);
            var it = cur.properties.iterator();
            while (it.next()) |entry| {
                const key = entry.key_ptr.*;
                if (std.mem.startsWith(u8, key, "__cynic_")) continue;
                if (!cur.flagsFor(key).enumerable) {
                    shadow_only.append(realm.allocator, key) catch return error.OutOfMemory;
                    continue;
                }
                if (canonicalIntegerIndexInterp(key)) |i| {
                    int_keys.append(realm.allocator, .{ .idx = i, .key = key }) catch return error.OutOfMemory;
                } else {
                    str_keys.append(realm.allocator, key) catch return error.OutOfMemory;
                }
            }
            // Accessor descriptors are still own properties for
            // §14.7.5.6 EnumerateObjectProperties — they show up
            // in `for-in` and `Object.keys` alongside data slots.
            var ait = cur.accessors.iterator();
            while (ait.next()) |entry| {
                const key = entry.key_ptr.*;
                if (std.mem.startsWith(u8, key, "__cynic_")) continue;
                if (!cur.flagsFor(key).enumerable) {
                    shadow_only.append(realm.allocator, key) catch return error.OutOfMemory;
                    continue;
                }
                if (canonicalIntegerIndexInterp(key)) |i| {
                    int_keys.append(realm.allocator, .{ .idx = i, .key = key }) catch return error.OutOfMemory;
                } else {
                    str_keys.append(realm.allocator, key) catch return error.OutOfMemory;
                }
            }
            std.mem.sort(KeyEntry, int_keys.items, {}, struct {
                fn lessThan(_: void, a: KeyEntry, b: KeyEntry) bool {
                    return a.idx < b.idx;
                }
            }.lessThan);

            for (int_keys.items) |e| {
                if (seen.contains(e.key)) continue;
                seen.put(realm.allocator, e.key, {}) catch return error.OutOfMemory;
                var ibuf: [16]u8 = undefined;
                const islice = std.fmt.bufPrint(&ibuf, "{d}", .{len}) catch unreachable;
                const idx_owned = realm.heap.allocateString(islice) catch return error.OutOfMemory;
                const key_owned = realm.heap.allocateString(e.key) catch return error.OutOfMemory;
                arr.set(realm.allocator, idx_owned.bytes, Value.fromString(key_owned)) catch return error.OutOfMemory;
                len += 1;
            }
            for (str_keys.items) |key| {
                if (seen.contains(key)) continue;
                seen.put(realm.allocator, key, {}) catch return error.OutOfMemory;
                var ibuf: [16]u8 = undefined;
                const islice = std.fmt.bufPrint(&ibuf, "{d}", .{len}) catch unreachable;
                const idx_owned = realm.heap.allocateString(islice) catch return error.OutOfMemory;
                const key_owned = realm.heap.allocateString(key) catch return error.OutOfMemory;
                arr.set(realm.allocator, idx_owned.bytes, Value.fromString(key_owned)) catch return error.OutOfMemory;
                len += 1;
            }
            // §14.7.5.6 — own-but-non-enumerable names shadow
            // prototype-side enumerable names of the same key.
            // Add them to `seen` so the upper levels skip them.
            for (shadow_only.items) |key| {
                _ = seen.getOrPut(realm.allocator, key) catch return error.OutOfMemory;
            }
            current = cur.prototype;
        }
    }
    arr.set(realm.allocator, "length", Value.fromInt32(len)) catch return error.OutOfMemory;

    // Wrap the snapshot in an array-like iterator. The for-of
    // emit path only reads `.next()` so we can reuse the
    // synthesised array-like iterator from `openIterator`'s
    // fallback branch. The array always has `.length`, so
    // NotIterable is impossible here.
    return openIterator(realm.allocator, realm, heap_mod.taggedObject(arr)) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidOpcode,
    };
}

/// `next()` for the synthesised array-like iterator. Reads
/// `[[IteratedObject]][idx]`, increments `idx`, returns
/// `{value, done}`. Done when `idx >= length`. Iterator state
/// lives on the typed `array_like_iter` slot (hidden from JS).
///
/// Strings get per-codepoint walking per §22.1.5.1
/// `String.prototype[@@iterator]` — `idx` is the byte offset
/// into the WTF-8 backing storage, advanced by the length of
/// the leading-byte's encoded sequence. The yielded value is
/// a fresh string containing exactly the codepoint's bytes
/// (1 byte for ASCII, 4 bytes for an astral codepoint, 3 bytes
/// for a lone surrogate stored as WTF-8). Done when `idx >=
/// bytes.len`.
fn arrayLikeIterNext(realm: *Realm, this_value: Value, args: []const Value) @import("function.zig").NativeError!Value {
    _ = args;
    const iter_obj = heap_mod.valueAsPlainObject(this_value) orelse return error.NativeThrew;
    const state = iter_obj.array_like_iter orelse return error.NativeThrew;
    const target = state.target;
    const idx: u32 = state.idx;

    const result = realm.heap.allocateObject() catch return error.OutOfMemory;
    result.prototype = realm.intrinsics.object_prototype;

    if (target.isString()) {
        const s: *@import("string.zig").JSString = @ptrCast(@alignCast(target.asString()));
        const start: usize = idx;
        if (start >= s.bytes.len) {
            result.set(realm.allocator, "value", Value.undefined_) catch return error.OutOfMemory;
            result.set(realm.allocator, "done", Value.true_) catch return error.OutOfMemory;
            state.done = true;
            return heap_mod.taggedObject(result);
        }
        const b0 = s.bytes[start];
        // Decode the leading-byte width — UTF-8 (and WTF-8) sequence
        // lengths are 1/2/3/4 by the high bits of b0. We accept
        // anything well-formed AND lone-surrogate 3-byte sequences
        // (0xED 0xA0..0xBF 0x80..0xBF). Malformed bytes fall back
        // to single-byte advance so we don't loop forever.
        var width: usize = 1;
        if (b0 < 0x80) {
            width = 1;
        } else if (b0 & 0xE0 == 0xC0) {
            width = 2;
        } else if (b0 & 0xF0 == 0xE0) {
            width = 3;
        } else if (b0 & 0xF8 == 0xF0) {
            width = 4;
        }
        if (start + width > s.bytes.len) width = 1;
        const sub = realm.heap.allocateString(s.bytes[start .. start + width]) catch return error.OutOfMemory;
        result.set(realm.allocator, "value", Value.fromString(sub)) catch return error.OutOfMemory;
        result.set(realm.allocator, "done", Value.false_) catch return error.OutOfMemory;
        state.idx = idx + @as(u32, @intCast(width));
        return heap_mod.taggedObject(result);
    }

    // Length: from `target.length` if it's an object.
    var length: i32 = 0;
    if (heap_mod.valueAsPlainObject(target)) |obj| {
        const len_v = obj.get("length");
        if (len_v.isInt32()) length = len_v.asInt32() else if (len_v.isDouble()) length = @intFromFloat(len_v.asDouble());
    }

    if (@as(i64, idx) >= length) {
        result.set(realm.allocator, "value", Value.undefined_) catch return error.OutOfMemory;
        result.set(realm.allocator, "done", Value.true_) catch return error.OutOfMemory;
        state.done = true;
        return heap_mod.taggedObject(result);
    }

    var elem: Value = Value.undefined_;
    if (heap_mod.valueAsPlainObject(target)) |obj| {
        var ibuf: [16]u8 = undefined;
        const islice = std.fmt.bufPrint(&ibuf, "{d}", .{idx}) catch unreachable;
        elem = obj.get(islice);
    }
    result.set(realm.allocator, "value", elem) catch return error.OutOfMemory;
    result.set(realm.allocator, "done", Value.false_) catch return error.OutOfMemory;
    state.idx = idx + 1;
    return heap_mod.taggedObject(result);
}

/// §16.2.1.5 module load. Resolves `specifier` via the host
/// loader, fetches+caches+evaluates the target module, and
/// returns its exports namespace as a Value. Cycles return
/// the partial in-progress namespace (matches V8 / SM
/// behaviour). later — top-level await is not yet a
/// suspension point; `await` inside a module body still uses
/// the synchronous unwrap from later. Errored modules
/// re-throw on subsequent loads.
/// §16.2.1.5 load outcome — pair a Value with a flag telling the
/// caller whether it's the module namespace (`threw = false`) or
/// an exception (`threw = true`). Without the flag, TypeError
/// objects (e.g. "module not found") would tunnel through the
/// `valueAsPlainObject != null` check and be misclassified as
/// successful namespaces — fixtures under
/// `language/expressions/dynamic-import/catch/*` rely on the
/// rejected-Promise path firing for missing-file and errored-
/// module specifiers.
pub const LoadModuleOutcome = struct {
    value: Value,
    threw: bool,
};

pub fn loadModule(
    allocator: std.mem.Allocator,
    realm: *Realm,
    specifier: []const u8,
    base_url: ?[]const u8,
) RunError!LoadModuleOutcome {
    const ModuleRecord = @import("module.zig").ModuleRecord;
    const loader = realm.module_loader orelse {
        const ex = try makeTypeError(realm, "no module loader installed");
        return .{ .value = ex, .threw = true };
    };

    const result = loader(realm, specifier, base_url) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.ModuleNotFound => return .{ .value = try makeTypeError(realm, "module not found"), .threw = true },
        error.ModuleLoadError => return .{ .value = try makeTypeError(realm, "module load failed"), .threw = true },
    };

    // Cache lookup.
    if (realm.modules.get(result.url)) |mr| {
        switch (mr.state) {
            .uninstantiated, .evaluated => return .{ .value = heap_mod.taggedObject(mr.exports), .threw = false },
            .evaluating => return .{ .value = heap_mod.taggedObject(mr.exports), .threw = false }, // cycle: partial ns
            .errored => return .{ .value = mr.error_value, .threw = true },
        }
    }

    // Allocate the record + namespace BEFORE running the body
    // so cycles can find the in-progress namespace.
    const ns = realm.heap.allocateObject() catch return error.OutOfMemory;
    ns.prototype = realm.intrinsics.object_prototype;
    const mr = ModuleRecord.init(realm.allocator, result.url, ns) catch return error.OutOfMemory;
    mr.state = .evaluating;
    realm.modules.put(realm.allocator, result.url, mr) catch return error.OutOfMemory;

    // Parse + compile.
    var arena_state: std.heap.ArenaAllocator = .init(allocator);
    defer arena_state.deinit();
    const parse_arena = arena_state.allocator();

    const program = parser_mod.parseModule(parse_arena, result.source, null) catch {
        mr.state = .errored;
        const ex = makeTypeError(realm, "module parse error") catch return error.OutOfMemory;
        mr.error_value = ex;
        return .{ .value = ex, .threw = true };
    };

    mr.chunk = compiler_mod.compileModuleAsChunk(realm.allocator, realm, &program, result.source, null, result.url) catch {
        mr.state = .errored;
        const ex = makeTypeError(realm, "module compile error") catch return error.OutOfMemory;
        mr.error_value = ex;
        return .{ .value = ex, .threw = true };
    };
    // (chunk constants pinned inside `compileModuleAsChunk`)

    // Run the module body. JSFunctions declared inside this
    // chunk hold non-owning pointers into mr.chunk; the chunk
    // stays pinned for the realm's lifetime.
    realm.current_module = mr;
    defer realm.current_module = null;

    const outcome = run(allocator, realm, &mr.chunk.?) catch |err| {
        mr.state = .errored;
        return err;
    };
    switch (outcome) {
        .value, .yielded => {
            mr.state = .evaluated;
            return .{ .value = heap_mod.taggedObject(mr.exports), .threw = false };
        },
        .thrown => |ex| {
            mr.state = .errored;
            mr.error_value = ex;
            return .{ .value = ex, .threw = true };
        },
    }
}

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
    obj.prototype = realm.intrinsics.promise_prototype;
    obj.settlePromise(if (fulfilled) .fulfilled else .rejected, value);
    return heap_mod.taggedObject(obj);
}

/// Drain the realm's microtask queue: invoke each queued
/// callback with its argument. Re-entered from `await` opcode
/// sites + at every external boundary (the CLI / test262
/// runner). Microtasks queued during draining run before this
/// call returns (FIFO), matching §9.4.
pub fn drainMicrotasks(allocator: std.mem.Allocator, realm: *Realm) RunError!void {
    while (realm.microtask_queue.items.len > 0) {
        const task = realm.microtask_queue.orderedRemove(0);
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
                try resumeAsyncFunction(allocator, realm, gen, task.arg, task.async_throws);
            },
            .promise_reaction => {
                try runPromiseReaction(allocator, realm, task.reaction_handler, task.arg, task.reaction_result, task.reaction_was_rejected);
            },
            .thenable_job => {
                try runThenableJob(allocator, realm, task.reaction_result, task.arg, task.reaction_handler);
            },
        }
    }
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
    const promise_mod = @import("builtins/promise.zig");
    const resolve_impl = realm.heap.allocateFunctionNative(promise_mod.promiseResolveImplExported, 1, "") catch return error.OutOfMemory;
    resolve_impl.proto = realm.intrinsics.function_prototype;
    const resolve_fn = realm.heap.allocateFunctionNative(promise_mod.boundResolveTrampolineExported, 1, "") catch return error.OutOfMemory;
    resolve_fn.proto = realm.intrinsics.function_prototype;
    resolve_fn.bound_target = resolve_impl;
    resolve_fn.bound_this = outer_promise;

    const reject_impl = realm.heap.allocateFunctionNative(promise_mod.promiseRejectImplExported, 1, "") catch return error.OutOfMemory;
    reject_impl.proto = realm.intrinsics.function_prototype;
    const reject_fn = realm.heap.allocateFunctionNative(promise_mod.boundResolveTrampolineExported, 1, "") catch return error.OutOfMemory;
    reject_fn.proto = realm.intrinsics.function_prototype;
    reject_fn.bound_target = reject_impl;
    reject_fn.bound_this = outer_promise;

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
            if (outer_obj.promise_state == .pending) {
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
            const intrinsics = @import("intrinsics.zig");
            const ex = intrinsics.newTypeError(realm, "Chaining cycle detected for promise") catch return error.OutOfMemory;
            try settlePromiseInternal(realm, target, .rejected, ex);
            return;
        }
        if (v_obj.isPromise()) {
            try chainPromiseToInner(realm, v_obj, target);
            return;
        }
        const intrinsics = @import("intrinsics.zig");
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
    try inner.promise_reactions.append(realm.allocator, .{
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
    gen: *@import("generator.zig").JSGenerator,
    sent_value: Value,
    throws_in: bool,
) RunError!void {
    if (gen.state == .completed) return;
    if (gen.state == .executing) return; // re-entrancy guard
    gen.state = .executing;

    var frames: std.ArrayListUnmanaged(CallFrame) = .empty;
    defer {
        for (frames.items) |*f| if (f.owns_registers) allocator.free(f.registers);
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
    inst.settlePromise(switch (state) {
        .fulfilled => .fulfilled,
        .rejected => .rejected,
    }, value);

    // Fire async-await waiters as resume microtasks.
    const waiters = inst.promise_waiters;
    inst.promise_waiters = .empty;
    var w_iter = waiters;
    defer w_iter.deinit(realm.allocator);
    for (w_iter.items) |w_gen| {
        try realm.enqueueAsyncResume(w_gen, value, state == .rejected);
    }

    // Fire user-level `.then` reactions.
    const reactions = inst.promise_reactions;
    inst.promise_reactions = .empty;
    var r_iter = reactions;
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
    gen: *@import("generator.zig").JSGenerator,
    sent_value: Value,
) RunError!RunResult {
    if (gen.state == .completed) {
        return .{ .value = Value.undefined_ };
    }
    if (gen.state == .executing) {
        const ex = try makeTypeError(realm, "Generator is already running");
        return .{ .thrown = ex };
    }
    gen.state = .executing;

    var frames: std.ArrayListUnmanaged(CallFrame) = .empty;
    defer {
        for (frames.items) |*f| if (f.owns_registers) allocator.free(f.registers);
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
        .owns_registers = false,
    });

    const result = try runFrames(allocator, realm, &frames);
    if (result == .yielded) {
        gen.state = .suspended;
    } else {
        gen.state = .completed;
    }
    return result;
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
    callee_v: Value,
    this_value: Value,
    args: []const Value,
) RunError!RunResult {
    // Proxy of fn — dispatch through `apply` trap if present;
    // otherwise unwrap to the target function.
    if (heap_mod.valueAsPlainObject(callee_v)) |po| {
        if (po.proxy_target_fn != null or po.proxy_target != null or po.proxy_revoked) {
            if (po.proxy_revoked) {
                const ex = try makeTypeError(realm, "Cannot perform 'apply' on a proxy that has been revoked");
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
                arr.prototype = realm.intrinsics.array_prototype;
                arr.markAsArrayExotic(allocator) catch return error.OutOfMemory;
                var i: usize = 0;
                while (i < args.len) : (i += 1) {
                    var ibuf: [24]u8 = undefined;
                    const islice = std.fmt.bufPrint(&ibuf, "{d}", .{i}) catch unreachable;
                    const owned = realm.heap.allocateString(islice) catch return error.OutOfMemory;
                    arr.set(allocator, owned.bytes, args[i]) catch return error.OutOfMemory;
                }
                arr.set(allocator, "length", Value.fromInt32(@intCast(args.len))) catch return error.OutOfMemory;
                const trap_args = [_]Value{ target_v, this_value, heap_mod.taggedObject(arr) };
                return callJSFunction(allocator, realm, trap_fn, heap_mod.taggedObject(handler), &trap_args);
            }
            // Trap missing — fall through to target.
            return callValue(allocator, realm, target_v, this_value, args);
        }
    }
    // Plain function path.
    if (heap_mod.valueAsFunction(callee_v)) |fn_obj| {
        return callJSFunction(allocator, realm, fn_obj, this_value, args);
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
    thrown: Value,
};

pub fn getPrototypeFromConstructor(
    allocator: std.mem.Allocator,
    realm: *Realm,
    new_target: *JSFunction,
    intrinsic_default: ?*JSObject,
) RunError!ProtoLookup {
    // §10.1.8.1 OrdinaryGet step 4 — accessor wins.
    if (new_target.ownAccessor("prototype")) |acc_pair| {
        if (acc_pair.getter) |getter| {
            const recv = heap_mod.taggedFunction(new_target);
            const outcome = try callJSFunction(allocator, realm, getter, recv, &.{});
            switch (outcome) {
                .value, .yielded => |v| {
                    if (heap_mod.valueAsPlainObject(v)) |po| return .{ .proto = po };
                    return .{ .proto = intrinsic_default };
                },
                .thrown => |ex| return .{ .thrown = ex },
            }
        }
        // Write-only accessor: getter is undefined → ToObject fails → use default.
        return .{ .proto = intrinsic_default };
    }
    // Data property — read the dedicated slot first (mirrors
    // `JSFunction.get("prototype")`).
    if (new_target.prototype) |p| return .{ .proto = p };
    // No `prototype` at all (arrow, bound without override) — fall back.
    return .{ .proto = intrinsic_default };
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
                arr.prototype = realm.intrinsics.array_prototype;
                arr.markAsArrayExotic(allocator) catch return error.OutOfMemory;
                var i: usize = 0;
                while (i < args.len) : (i += 1) {
                    var ibuf: [24]u8 = undefined;
                    const islice = std.fmt.bufPrint(&ibuf, "{d}", .{i}) catch unreachable;
                    const owned = realm.heap.allocateString(islice) catch return error.OutOfMemory;
                    arr.set(allocator, owned.bytes, args[i]) catch return error.OutOfMemory;
                }
                arr.set(allocator, "length", Value.fromInt32(@intCast(args.len))) catch return error.OutOfMemory;
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
    const new_target_fn: *JSFunction = if (heap_mod.valueAsFunction(new_target)) |nt| nt else target;
    // §10.1.14 GetPrototypeFromConstructor — Get(new_target,
    // "prototype") so user-installed accessors on a NewTarget
    // (e.g. `Object.defineProperty(boundFn, "prototype", {get})`)
    // fire. Falls back to the target's own `.prototype` slot when
    // the resolved value isn't an Object (Cynic's analogue of the
    // spec's intrinsicDefaultProto).
    const proto_lookup = try getPrototypeFromConstructor(allocator, realm, new_target_fn, target.prototype);
    const resolved_proto: ?*JSObject = switch (proto_lookup) {
        .proto => |p| p,
        .thrown => |ex| return .{ .thrown = ex },
    };
    const instance = realm.heap.allocateObject() catch return error.OutOfMemory;
    instance.prototype = resolved_proto;
    const this_arg = heap_mod.taggedObject(instance);
    const outcome = try callJSFunction(allocator, realm, target, this_arg, args);
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

    if (callee.native_callback) |native| {
        const native_this: Value = if (callee.is_arrow) callee.captured_this else this_value;
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
            return try wrapAsyncGenerator(allocator, realm, callee_chunk, callee.captured_env, this_value, args);
        return try wrapGenerator(allocator, realm, callee_chunk, callee.captured_env, this_value, args);
    }

    // §27.7 — pure `async function` (no `*`): allocate a fresh
    // `result_promise` plus a backing generator that captures the
    // body's frame state if a pending await suspends. Run the
    // body synchronously up to the first suspension or
    // completion. The caller always sees `result_promise` as
    // the call's return value.
    if (callee.is_async) {
        const callee_this: Value = if (callee.is_arrow) callee.captured_this else this_value;
        return startAsyncCall(allocator, realm, callee_chunk, callee.captured_env, callee_this, args);
    }

    var frames: std.ArrayListUnmanaged(CallFrame) = .empty;
    defer {
        for (frames.items) |*f| if (f.owns_registers) allocator.free(f.registers);
        frames.deinit(allocator);
    }

    const regs = try allocator.alloc(Value, @max(@as(usize, callee_chunk.register_count), args.len));
    @memset(regs, Value.undefined_);
    var i: usize = 0;
    while (i < args.len and i < regs.len) : (i += 1) {
        regs[i] = args[i];
    }
    const callee_this: Value = if (callee.is_arrow) callee.captured_this else this_value;
    try frames.append(allocator, .{
        .chunk = callee_chunk,
        .ip = 0,
        .accumulator = Value.undefined_,
        .registers = regs,
        .env = callee.captured_env,
        .this_value = callee_this,
        .home_object = callee.home_object,
        .home_function = callee.home_function,
        .argc = @intCast(@min(args.len, std.math.maxInt(u8))),
        .wrap_return_in_promise = false,
    });

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
    // Native / generator / async paths don't observe new.target
    // via a frame slot — they receive `this` and args directly.
    if (callee.native_callback != null or callee.is_generator or callee.is_async) {
        return callJSFunction(allocator, realm, callee, this_value, args);
    }
    const callee_chunk = callee.chunk orelse return error.InvalidOpcode;

    var frames: std.ArrayListUnmanaged(CallFrame) = .empty;
    defer {
        for (frames.items) |*f| if (f.owns_registers) allocator.free(f.registers);
        frames.deinit(allocator);
    }

    const regs = try allocator.alloc(Value, @max(@as(usize, callee_chunk.register_count), args.len));
    @memset(regs, Value.undefined_);
    var i: usize = 0;
    while (i < args.len and i < regs.len) : (i += 1) regs[i] = args[i];
    try frames.append(allocator, .{
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
    });

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
    chunk: *const @import("../bytecode/chunk.zig").Chunk,
    captured_env: ?*Environment,
    this_value: Value,
    args: []const Value,
) RunError!RunResult {
    // Pre-allocate the Promise so the gen can settle it.
    const promise_obj = realm.heap.allocateObject() catch return error.OutOfMemory;
    promise_obj.prototype = if (heap_mod.valueAsFunction(realm.globals.get("Promise") orelse Value.undefined_)) |p|
        p.prototype
    else
        realm.intrinsics.object_prototype;
    promise_obj.settlePromise(.pending, Value.undefined_);
    const result_promise = heap_mod.taggedObject(promise_obj);

    const wanted: usize = @max(@as(usize, chunk.register_count), args.len);
    const reg_count: u8 = @intCast(@min(wanted, std.math.maxInt(u8)));
    const gen = realm.heap.allocateGenerator(chunk, reg_count, captured_env, this_value) catch return error.OutOfMemory;
    gen.is_async = true;
    gen.result_promise = result_promise;
    var i: usize = 0;
    while (i < args.len and i < gen.registers.len) : (i += 1) {
        gen.registers[i] = args[i];
    }
    gen.argc = @intCast(@min(args.len, std.math.maxInt(u8)));

    try resumeAsyncFunction(allocator, realm, gen, Value.undefined_, false);
    return .{ .value = result_promise };
}

fn runFrames(
    allocator: std.mem.Allocator,
    realm: *Realm,
    frames: *std.ArrayListUnmanaged(CallFrame),
) RunError!RunResult {
    // Register this dispatch's frame stack with the realm so
    // `collectGarbage` can walk OUR frames as roots in addition
    // to any outer (parent) `runFrames` stack. Without this,
    // a child dispatch (e.g. a native callback re-entering JS,
    // a `for-of` driving a generator's `next()`) collects
    // values that the parent's registers still point at. The
    // append-then-defer sequence is paired so a failed append
    // doesn't leave a phantom pop running.
    try realm.frame_stacks.append(realm.allocator, frames);
    defer {
        // Pop our own entry — locating by pointer in case some
        // pathological re-entrant path nested without us seeing it.
        const stacks = &realm.frame_stacks;
        if (stacks.items.len > 0 and stacks.items[stacks.items.len - 1] == frames) {
            _ = stacks.pop();
        } else {
            var i: usize = stacks.items.len;
            while (i > 0) {
                i -= 1;
                if (stacks.items[i] == frames) {
                    _ = stacks.swapRemove(i);
                    break;
                }
            }
        }
    }
    while (frames.items.len > 0) {
        // Allocation-pressure GC — when the heap counter has
        // climbed past its threshold, run a stop-the-world
        // mark-sweep. Roots come from the realm (globals,
        // intrinsics, microtask queue, modules) plus every
        // nested `runFrames` stack registered above. Stop-the-
        // world means we never run mid-opcode, so pointers
        // natives hold across a sub-call stay stable; the
        // check at dispatch top is the natural safe point.
        if (realm.heap.allocs_since_gc >= realm.heap.gc_threshold or
            realm.heap.bytes_since_gc >= realm.heap.gc_byte_threshold)
        {
            realm.collectGarbage();
        }
        // Cooperative step budget — saturating decrement, then
        // unwind a synthetic `RangeError` when the budget hits
        // zero. The default budget is huge (maxInt(u64)) so
        // ordinary hosts never see this; the test262 harness
        // dials it down per-test so a `while(true){}` fixture
        // can't wedge the whole sweep. The check sits before
        // opcode dispatch — every re-entry into `runFrames`
        // (native call → JS callback → ...) ticks too.
        if (realm.step_budget == 0) {
            const ex = try makeRangeError(realm, "interpreter step budget exhausted");
            return .{ .thrown = ex };
        }
        // Cooperative interrupt — host-side watchdog flips
        // `realm.interrupt` from another thread; the dispatch
        // loop notices on the next tick and unwinds with
        // `RangeError("execution interrupted")`. Same shape as
        // V8's `Isolate::TerminateExecution`, JSC's
        // `Watchdog::fire`, and `JS_SetInterruptCallback` on
        // SpiderMonkey / QuickJS.
        if (realm.interrupt.load(.acquire)) {
            realm.clearInterrupt();
            const ex = try makeRangeError(realm, "execution interrupted");
            return .{ .thrown = ex };
        }
        realm.step_budget -|= 1;
        var f = &frames.items[frames.items.len - 1];
        const local_chunk = f.chunk;
        const code = local_chunk.code;
        if (f.ip >= code.len) return error.InvalidOpcode;
        const op_byte = code[f.ip];
        f.ip += 1;
        const op: Op = std.enums.fromInt(Op, op_byte) orelse return error.InvalidOpcode;

        // Bind locals so the existing opcode bodies can stay
        // unchanged below. Any control-flow change to `ip` /
        // `acc` / `registers` writes back to the frame at the
        // end of each iteration via a `defer`-style update.
        var ip: usize = f.ip;
        var acc: Value = f.accumulator;
        var registers: []Value = f.registers;

        // Helper to commit register / acc / ip changes into the
        // current frame at the end of dispatch. We can't use a
        // `defer` here because `Call` and `Return` swap which
        // frame is "current" — those branches save state
        // explicitly before mutating `frames`.
        var committed = false;
        defer if (!committed) {
            // Default: just sync `ip` / `acc` back into the top
            // frame (registers are aliased into the slice so
            // mutations are already visible).
            if (frames.items.len > 0) {
                frames.items[frames.items.len - 1].ip = ip;
                frames.items[frames.items.len - 1].accumulator = acc;
            }
        };

        switch (op) {
            // ── Loads ───────────────────────────────────────────────────
            .lda_undefined => acc = Value.undefined_,
            .lda_null => acc = Value.null_,
            .lda_true => acc = Value.true_,
            .lda_false => acc = Value.false_,
            .lda_smi => {
                acc = Value.fromInt32(readI32(code, ip));
                ip += 4;
            },
            .lda_constant => {
                const k = readU16(code, ip);
                ip += 2;
                acc = local_chunk.constants[k];
            },
            .ldar => {
                const r = code[ip];
                ip += 1;
                acc = registers[r];
            },
            .star => {
                const r = code[ip];
                ip += 1;
                registers[r] = acc;
            },
            .mov => {
                const src = code[ip];
                const dst = code[ip + 1];
                ip += 2;
                registers[dst] = registers[src];
            },
            .lda_hole => acc = Value.hole_,

            // ── Arithmetic — `acc = reg <op> acc` ───────────────────────
            // Per §13.15.4 ApplyStringOrNumericBinaryOperator the
            // helpers handle ToPrimitive / ToNumeric themselves —
            // user `valueOf` / `toString` / `Symbol.toPrimitive`
            // bodies can throw, BigInt+Number is a TypeError, etc.
            // A null return means an exception is pending; spill
            // the frame and unwind.
            .add => {
                const r = code[ip];
                ip += 1;
                if (try addValues(realm, registers[r], acc)) |res| acc = res else {
                    const ex = realm.pending_exception orelse try makeTypeError(realm, "ToPrimitive failed");
                    realm.pending_exception = null;
                    f.ip = ip; f.accumulator = acc; committed = true;
                    if (!try unwindThrow(allocator, realm, frames, ex)) return .{ .thrown = ex };
                    continue;
                }
            },
            .sub => {
                const r = code[ip];
                ip += 1;
                if (try numericBinary(realm, .sub, registers[r], acc)) |res| acc = res else {
                    const ex = realm.pending_exception orelse try makeTypeError(realm, "ToPrimitive failed");
                    realm.pending_exception = null;
                    f.ip = ip; f.accumulator = acc; committed = true;
                    if (!try unwindThrow(allocator, realm, frames, ex)) return .{ .thrown = ex };
                    continue;
                }
            },
            .mul => {
                const r = code[ip];
                ip += 1;
                if (try numericBinary(realm, .mul, registers[r], acc)) |res| acc = res else {
                    const ex = realm.pending_exception orelse try makeTypeError(realm, "ToPrimitive failed");
                    realm.pending_exception = null;
                    f.ip = ip; f.accumulator = acc; committed = true;
                    if (!try unwindThrow(allocator, realm, frames, ex)) return .{ .thrown = ex };
                    continue;
                }
            },
            .div => {
                const r = code[ip];
                ip += 1;
                if (try numericBinary(realm, .div, registers[r], acc)) |res| acc = res else {
                    const ex = realm.pending_exception orelse try makeTypeError(realm, "ToPrimitive failed");
                    realm.pending_exception = null;
                    f.ip = ip; f.accumulator = acc; committed = true;
                    if (!try unwindThrow(allocator, realm, frames, ex)) return .{ .thrown = ex };
                    continue;
                }
            },
            .mod => {
                const r = code[ip];
                ip += 1;
                if (try numericBinary(realm, .mod, registers[r], acc)) |res| acc = res else {
                    const ex = realm.pending_exception orelse try makeTypeError(realm, "ToPrimitive failed");
                    realm.pending_exception = null;
                    f.ip = ip; f.accumulator = acc; committed = true;
                    if (!try unwindThrow(allocator, realm, frames, ex)) return .{ .thrown = ex };
                    continue;
                }
            },
            .pow => {
                const r = code[ip];
                ip += 1;
                if (try numericBinary(realm, .pow, registers[r], acc)) |res| acc = res else {
                    const ex = realm.pending_exception orelse try makeTypeError(realm, "ToPrimitive failed");
                    realm.pending_exception = null;
                    f.ip = ip; f.accumulator = acc; committed = true;
                    if (!try unwindThrow(allocator, realm, frames, ex)) return .{ .thrown = ex };
                    continue;
                }
            },

            // ── Bitwise — both operands are ToInt32-coerced ─────────────
            .bit_and => {
                const r = code[ip];
                ip += 1;
                if (try bitwiseBinary(realm, .bit_and, registers[r], acc)) |res| acc = res else {
                    const ex = realm.pending_exception orelse try makeTypeError(realm, "ToPrimitive failed");
                    realm.pending_exception = null;
                    f.ip = ip; f.accumulator = acc; committed = true;
                    if (!try unwindThrow(allocator, realm, frames, ex)) return .{ .thrown = ex };
                    continue;
                }
            },
            .bit_or => {
                const r = code[ip];
                ip += 1;
                if (try bitwiseBinary(realm, .bit_or, registers[r], acc)) |res| acc = res else {
                    const ex = realm.pending_exception orelse try makeTypeError(realm, "ToPrimitive failed");
                    realm.pending_exception = null;
                    f.ip = ip; f.accumulator = acc; committed = true;
                    if (!try unwindThrow(allocator, realm, frames, ex)) return .{ .thrown = ex };
                    continue;
                }
            },
            .bit_xor => {
                const r = code[ip];
                ip += 1;
                if (try bitwiseBinary(realm, .bit_xor, registers[r], acc)) |res| acc = res else {
                    const ex = realm.pending_exception orelse try makeTypeError(realm, "ToPrimitive failed");
                    realm.pending_exception = null;
                    f.ip = ip; f.accumulator = acc; committed = true;
                    if (!try unwindThrow(allocator, realm, frames, ex)) return .{ .thrown = ex };
                    continue;
                }
            },
            .shl => {
                const r = code[ip];
                ip += 1;
                if (try bitwiseBinary(realm, .shl, registers[r], acc)) |res| acc = res else {
                    const ex = realm.pending_exception orelse try makeTypeError(realm, "ToPrimitive failed");
                    realm.pending_exception = null;
                    f.ip = ip; f.accumulator = acc; committed = true;
                    if (!try unwindThrow(allocator, realm, frames, ex)) return .{ .thrown = ex };
                    continue;
                }
            },
            .shr => {
                const r = code[ip];
                ip += 1;
                if (try bitwiseBinary(realm, .shr, registers[r], acc)) |res| acc = res else {
                    const ex = realm.pending_exception orelse try makeTypeError(realm, "ToPrimitive failed");
                    realm.pending_exception = null;
                    f.ip = ip; f.accumulator = acc; committed = true;
                    if (!try unwindThrow(allocator, realm, frames, ex)) return .{ .thrown = ex };
                    continue;
                }
            },
            .shr_u => {
                const r = code[ip];
                ip += 1;
                if (try bitwiseBinary(realm, .shr_u, registers[r], acc)) |res| acc = res else {
                    const ex = realm.pending_exception orelse try makeTypeError(realm, "ToPrimitive failed");
                    realm.pending_exception = null;
                    f.ip = ip; f.accumulator = acc; committed = true;
                    if (!try unwindThrow(allocator, realm, frames, ex)) return .{ .thrown = ex };
                    continue;
                }
            },

            // ── Unary on accumulator ────────────────────────────────────
            .negate => {
                if (try unaryNegate(realm, acc)) |res| acc = res else {
                    const ex = realm.pending_exception orelse try makeTypeError(realm, "ToPrimitive failed");
                    realm.pending_exception = null;
                    f.ip = ip; f.accumulator = acc; committed = true;
                    if (!try unwindThrow(allocator, realm, frames, ex)) return .{ .thrown = ex };
                    continue;
                }
            },
            .bit_not => {
                if (try unaryBitNot(realm, acc)) |res| acc = res else {
                    const ex = realm.pending_exception orelse try makeTypeError(realm, "ToPrimitive failed");
                    realm.pending_exception = null;
                    f.ip = ip; f.accumulator = acc; committed = true;
                    if (!try unwindThrow(allocator, realm, frames, ex)) return .{ .thrown = ex };
                    continue;
                }
            },
            .logical_not => acc = Value.fromBool(!toBoolean(acc)),
            .to_number => {
                if (try unaryToNumber(realm, acc)) |res| acc = res else {
                    const ex = realm.pending_exception orelse try makeTypeError(realm, "ToPrimitive failed");
                    realm.pending_exception = null;
                    f.ip = ip; f.accumulator = acc; committed = true;
                    if (!try unwindThrow(allocator, realm, frames, ex)) return .{ .thrown = ex };
                    continue;
                }
            },
            .typeof_ => acc = try typeOf(realm, acc),

            // ── Comparison ──────────────────────────────────────────────
            // §7.2.14 IsLooselyEqual / §7.2.13 IsLessThan call
            // ToPrimitive on object operands. Strict equality
            // skips primitive coercion entirely (object-vs-anything
            // is identity / false).
            .eq => {
                const r = code[ip];
                ip += 1;
                // §7.2.14 IsLooselyEqual — ToPrimitive only fires
                // when exactly one side is Object (steps 11/12).
                // Object-vs-Object falls through to strictEq
                // (reference equality) inside `looseEq`.
                const lhs_v = registers[r];
                const rhs_v = acc;
                const lhs = try coerceForCompareEq(allocator, realm, frames, f, ip, lhs_v, rhs_v);
                if (lhs == .uncaught) return .{ .thrown = lhs.uncaught };
                if (lhs == .handled) {
                    committed = true;
                    continue;
                }
                const rhs = try coerceForCompareEq(allocator, realm, frames, f, ip, rhs_v, lhs.ok);
                if (rhs == .uncaught) return .{ .thrown = rhs.uncaught };
                if (rhs == .handled) {
                    committed = true;
                    continue;
                }
                acc = Value.fromBool(looseEq(lhs.ok, rhs.ok));
            },
            .strict_eq => {
                const r = code[ip];
                ip += 1;
                acc = Value.fromBool(strictEq(registers[r], acc));
            },
            .neq => {
                const r = code[ip];
                ip += 1;
                const lhs_v = registers[r];
                const rhs_v = acc;
                const lhs = try coerceForCompareEq(allocator, realm, frames, f, ip, lhs_v, rhs_v);
                if (lhs == .uncaught) return .{ .thrown = lhs.uncaught };
                if (lhs == .handled) {
                    committed = true;
                    continue;
                }
                const rhs = try coerceForCompareEq(allocator, realm, frames, f, ip, rhs_v, lhs.ok);
                if (rhs == .uncaught) return .{ .thrown = rhs.uncaught };
                if (rhs == .handled) {
                    committed = true;
                    continue;
                }
                acc = Value.fromBool(!looseEq(lhs.ok, rhs.ok));
            },
            .strict_neq => {
                const r = code[ip];
                ip += 1;
                acc = Value.fromBool(!strictEq(registers[r], acc));
            },
            .lt => {
                const r = code[ip];
                ip += 1;
                const lhs = try coerceForCompare(allocator, realm, frames, f, ip, registers[r], .number);
                if (lhs == .uncaught) return .{ .thrown = lhs.uncaught };
                if (lhs == .handled) {
                    committed = true;
                    continue;
                }
                const rhs = try coerceForCompare(allocator, realm, frames, f, ip, acc, .number);
                if (rhs == .uncaught) return .{ .thrown = rhs.uncaught };
                if (rhs == .handled) {
                    committed = true;
                    continue;
                }
                acc = relational(.lt, lhs.ok, rhs.ok);
            },
            .gt => {
                const r = code[ip];
                ip += 1;
                const lhs = try coerceForCompare(allocator, realm, frames, f, ip, registers[r], .number);
                if (lhs == .uncaught) return .{ .thrown = lhs.uncaught };
                if (lhs == .handled) {
                    committed = true;
                    continue;
                }
                const rhs = try coerceForCompare(allocator, realm, frames, f, ip, acc, .number);
                if (rhs == .uncaught) return .{ .thrown = rhs.uncaught };
                if (rhs == .handled) {
                    committed = true;
                    continue;
                }
                acc = relational(.gt, lhs.ok, rhs.ok);
            },
            .le => {
                const r = code[ip];
                ip += 1;
                const lhs = try coerceForCompare(allocator, realm, frames, f, ip, registers[r], .number);
                if (lhs == .uncaught) return .{ .thrown = lhs.uncaught };
                if (lhs == .handled) {
                    committed = true;
                    continue;
                }
                const rhs = try coerceForCompare(allocator, realm, frames, f, ip, acc, .number);
                if (rhs == .uncaught) return .{ .thrown = rhs.uncaught };
                if (rhs == .handled) {
                    committed = true;
                    continue;
                }
                acc = relational(.le, lhs.ok, rhs.ok);
            },
            .ge => {
                const r = code[ip];
                ip += 1;
                const lhs = try coerceForCompare(allocator, realm, frames, f, ip, registers[r], .number);
                if (lhs == .uncaught) return .{ .thrown = lhs.uncaught };
                if (lhs == .handled) {
                    committed = true;
                    continue;
                }
                const rhs = try coerceForCompare(allocator, realm, frames, f, ip, acc, .number);
                if (rhs == .uncaught) return .{ .thrown = rhs.uncaught };
                if (rhs == .handled) {
                    committed = true;
                    continue;
                }
                acc = relational(.ge, lhs.ok, rhs.ok);
            },

            // ── Control flow ────────────────────────────────────────────
            .jmp => {
                const off = readI16(code, ip);
                ip += 2;
                ip = applyOffset(ip, off);
            },
            .jmp_if_false => {
                const off = readI16(code, ip);
                ip += 2;
                if (!toBoolean(acc)) ip = applyOffset(ip, off);
            },
            .jmp_if_true => {
                const off = readI16(code, ip);
                ip += 2;
                if (toBoolean(acc)) ip = applyOffset(ip, off);
            },
            .jmp_if_nullish => {
                const off = readI16(code, ip);
                ip += 2;
                if (acc.isNull() or acc.isUndefined()) ip = applyOffset(ip, off);
            },

            // ── Functions / calls ───────────────────────────────────────
            .make_function => {
                const k = readU16(code, ip);
                ip += 2;
                if (k >= local_chunk.function_templates.len) return error.InvalidOpcode;
                const tmpl = &local_chunk.function_templates[k];
                const fn_obj = realm.heap.allocateFunction(
                    &tmpl.chunk,
                    tmpl.param_count,
                    tmpl.name,
                    tmpl.is_arrow,
                    f.env,
                ) catch return error.OutOfMemory;
                // §15.7.7 FunctionLength — override `f.length`
                // from total-params (what allocateFunction
                // installed by default) to the spec count
                // produced by the compiler. `function f(a, b=1, c)`
                // exposes `f.length === 1`, not 3.
                if (tmpl.spec_length != tmpl.param_count) {
                    fn_obj.properties.put(allocator, "length", Value.fromInt32(tmpl.spec_length)) catch return error.OutOfMemory;
                }
                // §15.3 Arrow functions capture lexical `this` at
                // creation. Non-arrow `make_function` ignores this
                // slot — `this` comes from the call site.
                if (tmpl.is_arrow) fn_obj.captured_this = f.this_value;
                fn_obj.is_generator = tmpl.is_generator;
                fn_obj.is_async = tmpl.is_async;
                // §27.3.5 / §27.4.5 — `function*(){}.prototype` /
                // `async function*(){}.prototype` is an ordinary
                // object whose `[[Prototype]]` is `%GeneratorPrototype%`
                // / `%AsyncGeneratorPrototype%`, with NO own
                // `constructor` property. `allocateFunction` always
                // installs `constructor` for non-arrows — undo for
                // the generator variants and rewire the proto chain.
                if (tmpl.is_generator) {
                    if (fn_obj.prototype) |proto| {
                        _ = proto.properties.swapRemove("constructor");
                        _ = proto.property_flags.swapRemove("constructor");
                        proto.prototype = if (tmpl.is_async)
                            ensureAsyncGeneratorPrototype(realm) catch realm.intrinsics.object_prototype
                        else
                            ensureGeneratorPrototype(realm) catch realm.intrinsics.object_prototype;
                    }
                } else if (fn_obj.prototype) |proto| {
                    // §10.2.4 — a regular function's `.prototype`
                    // object inherits from `%Object.prototype%`.
                    // `allocateFunction` couldn't set this without
                    // the realm in scope, so wire it here.
                    if (proto.prototype == null) {
                        proto.prototype = realm.intrinsics.object_prototype;
                    }
                }
                // §20.2.3.5 — borrow the template's source slice
                // for `Function.prototype.toString`. The slice
                // borrows from the chunk's source, which is
                // pinned for the lifetime of the realm.
                fn_obj.source = tmpl.source;
                // Wire the function's own [[Prototype]] to the
                // appropriate %FunctionPrototype% — async-generator,
                // generator, async-function, or plain — so
                // `Object.getPrototypeOf(f).constructor` reads the
                // right intrinsic constructor.
                fn_obj.proto = if (tmpl.is_generator and tmpl.is_async)
                    realm.intrinsics.async_generator_function_prototype orelse realm.intrinsics.function_prototype
                else if (tmpl.is_generator)
                    realm.intrinsics.generator_function_prototype orelse realm.intrinsics.function_prototype
                else if (tmpl.is_async)
                    realm.intrinsics.async_function_prototype orelse realm.intrinsics.function_prototype
                else
                    realm.intrinsics.function_prototype;
                acc = heap_mod.taggedFunction(fn_obj);
            },
            .call => {
                const r_callee = code[ip];
                const argc = code[ip + 1];
                ip += 2;

                const callee_v = registers[r_callee];
                // §10.5.13 callable Proxy [[Call]] — if the callee
                // is a proxy, route through `callValue` which
                // handles the apply trap and chained proxies.
                if (heap_mod.valueAsPlainObject(callee_v)) |po| {
                    if (po.proxy_target_fn != null or po.proxy_target != null or po.proxy_revoked) {
                        const args_start = @as(usize, r_callee) + 1;
                        const args_slice = registers[args_start .. args_start + argc];
                        const cresult = try callValue(allocator, realm, callee_v, Value.undefined_, args_slice);
                        switch (cresult) {
                            .value, .yielded => |v| {
                                acc = v;
                                continue;
                            },
                            .thrown => |ex| {
                                f.ip = ip;
                                f.accumulator = acc;
                                committed = true;
                                if (!try unwindThrow(allocator, realm, frames, ex)) {
                                    return .{ .thrown = ex };
                                }
                                continue;
                            },
                        }
                    }
                }
                const callee_fn = heap_mod.valueAsFunction(callee_v) orelse {
                    const ex = try makeTypeError(realm, "value is not callable");
                    f.ip = ip;
                    f.accumulator = acc;
                    committed = true;
                    if (!try unwindThrow(allocator, realm, frames, ex)) {
                        return .{ .thrown = ex };
                    }
                    continue;
                };

                // §15.7.14 step 1 — class constructors are not
                // callable without `new`; reject with TypeError.
                if (callee_fn.is_class_constructor) {
                    const ex = try makeTypeError(realm, "Class constructor cannot be invoked without 'new'");
                    f.ip = ip;
                    f.accumulator = acc;
                    committed = true;
                    if (!try unwindThrow(allocator, realm, frames, ex)) {
                        return .{ .thrown = ex };
                    }
                    continue;
                }

                // §28.2.2.1.1 — revocation function. Calling it
                // clears the captured proxy's internal slots.
                // First call returns undefined and clears the slot;
                // subsequent calls no-op (slot is null).
                if (callee_fn.revocable_proxy) |rp| {
                    rp.proxy_target = null;
                    rp.proxy_handler = null;
                    rp.proxy_target_fn = null;
                    rp.proxy_revoked = true;
                    callee_fn.revocable_proxy = null;
                    acc = Value.undefined_;
                    continue;
                }

                // §10.4.1 — bound functions unwrap and re-enter
                // through `callJSFunction` (which builds a fresh
                // frame stack with the concatenated args). Plain
                // calls pass `this = undefined` (strict).
                if (callee_fn.bound_target != null) {
                    const args_start = @as(usize, r_callee) + 1;
                    const result = try callJSFunction(allocator, realm, callee_fn, Value.undefined_, registers[args_start .. args_start + argc]);
                    switch (result) {
                        .value, .yielded => |v| acc = v,
                        .thrown => |ex| {
                            f.ip = ip;
                            f.accumulator = acc;
                            committed = true;
                            if (!try unwindThrow(allocator, realm, frames, ex)) {
                                return .{ .thrown = ex };
                            }
                            continue;
                        },
                    }
                    continue;
                }

                // §27.5 / §27.6 — calling a `function*` or
                // `async function*` allocates a generator wrapper
                // instead of running the body. Async-generator
                // gets the Promise-wrapping prototype.
                if (callee_fn.is_generator) {
                    const callee_chunk = callee_fn.chunk orelse return error.InvalidOpcode;
                    const args_start = @as(usize, r_callee) + 1;
                    const wrap_result = if (callee_fn.is_async)
                        try wrapAsyncGenerator(allocator, realm, callee_chunk, callee_fn.captured_env, Value.undefined_, registers[args_start .. args_start + argc])
                    else
                        try wrapGenerator(allocator, realm, callee_chunk, callee_fn.captured_env, Value.undefined_, registers[args_start .. args_start + argc]);
                    switch (wrap_result) {
                        .value, .yielded => |v| acc = v,
                        .thrown => |ex| {
                            f.ip = ip;
                            f.accumulator = acc;
                            committed = true;
                            if (!try unwindThrow(allocator, realm, frames, ex)) {
                                return .{ .thrown = ex };
                            }
                            continue;
                        },
                    }
                    continue;
                }

                // Native fast path — no frame, no register file,
                // no env. The host fn reads args directly from the
                // caller's register file and returns a value.
                // Plain `Call` passes `this = undefined` (strict).
                if (callee_fn.native_callback) |native| {
                    const args_start = @as(usize, r_callee) + 1;
                    const args = registers[args_start .. args_start + argc];
                    const native_this: Value = Value.undefined_;
                    const result = native(realm, native_this, args) catch |err| switch (err) {
                        error.OutOfMemory => return error.OutOfMemory,
                        error.NativeThrew => {
                            // native fns throw by leaving
                            // an exception value on a future
                            // realm.pending_throw slot. Stub for
                            // now: synthesise a generic message.
                            const ex = consumePendingException(realm) orelse try makeTypeError(realm, "native error");
                            f.ip = ip;
                            f.accumulator = acc;
                            committed = true;
                            if (!try unwindThrow(allocator, realm, frames, ex)) {
                                return .{ .thrown = ex };
                            }
                            continue;
                        },
                    };
                    acc = result;
                    continue;
                }

                // §27.7 — async function call. Start fresh, run the
                // body in its own re-entry of `runFrames`, settle the
                // result Promise on completion / throw, leave us
                // with the result Promise in `acc`.
                if (callee_fn.is_async) {
                    const callee_chunk = callee_fn.chunk orelse return error.InvalidOpcode;
                    const args_start = @as(usize, r_callee) + 1;
                    const callee_this: Value = if (callee_fn.is_arrow) callee_fn.captured_this else Value.undefined_;
                    const outcome = try startAsyncCall(allocator, realm, callee_chunk, callee_fn.captured_env, callee_this, registers[args_start .. args_start + argc]);
                    switch (outcome) {
                        .value, .yielded => |v| acc = v,
                        .thrown => |ex| {
                            f.ip = ip;
                            f.accumulator = acc;
                            committed = true;
                            if (!try unwindThrow(allocator, realm, frames, ex)) {
                                return .{ .thrown = ex };
                            }
                            continue;
                        },
                    }
                    continue;
                }

                if (frames.items.len >= max_call_frames) {
                    const ex = try makeRangeError(realm, "Maximum call stack size exceeded");
                    f.ip = ip;
                    f.accumulator = acc;
                    committed = true;
                    if (!try unwindThrow(allocator, realm, frames, ex)) {
                        return .{ .thrown = ex };
                    }
                    continue;
                }

                const callee_chunk = callee_fn.chunk orelse return error.InvalidOpcode;
                const callee_regs = try allocator.alloc(Value, @max(@as(usize, callee_chunk.register_count), @as(usize, argc)));
                @memset(callee_regs, Value.undefined_);
                var i: u8 = 0;
                while (i < argc and @as(usize, i) < callee_regs.len) : (i += 1) {
                    callee_regs[i] = registers[r_callee + 1 + i];
                }

                f.ip = ip;
                f.accumulator = acc;
                committed = true;

                // §15.3.4 — arrow functions read `this` from their
                // creation site (captured at MakeFunction time).
                // Regular plain calls in strict mode start with
                // `this = undefined` (§10.2.1.2); `Function.prototype
                //.call`/`apply` override that.
                const callee_this: Value = if (callee_fn.is_arrow)
                    callee_fn.captured_this
                else
                    Value.undefined_;

                frames.append(allocator, .{
                    .chunk = callee_chunk,
                    .ip = 0,
                    .accumulator = Value.undefined_,
                    .registers = callee_regs,
                    .env = callee_fn.captured_env,
                    .this_value = callee_this,
                    .home_object = callee_fn.home_object,
                    .home_function = callee_fn.home_function,
                    .argc = argc,
                    .wrap_return_in_promise = false,
                }) catch {
                    allocator.free(callee_regs);
                    return error.OutOfMemory;
                };
            },

            .call_method => {
                const r_recv = code[ip];
                const r_callee = code[ip + 1];
                const argc = code[ip + 2];
                ip += 3;

                const callee_v = registers[r_callee];
                // §10.5.13 callable Proxy [[Call]] — route through
                // `callValue` (handles apply trap + chained proxies).
                if (heap_mod.valueAsPlainObject(callee_v)) |po| {
                    if (po.proxy_target_fn != null or po.proxy_target != null or po.proxy_revoked) {
                        const args_start = @as(usize, r_callee) + 1;
                        const args_slice = registers[args_start .. args_start + argc];
                        const cresult = try callValue(allocator, realm, callee_v, registers[r_recv], args_slice);
                        switch (cresult) {
                            .value, .yielded => |v| {
                                acc = v;
                                continue;
                            },
                            .thrown => |ex| {
                                f.ip = ip;
                                f.accumulator = acc;
                                committed = true;
                                if (!try unwindThrow(allocator, realm, frames, ex)) {
                                    return .{ .thrown = ex };
                                }
                                continue;
                            },
                        }
                    }
                }
                const callee_fn = heap_mod.valueAsFunction(callee_v) orelse {
                    const ex = try makeTypeError(realm, "value is not callable");
                    f.ip = ip;
                    f.accumulator = acc;
                    committed = true;
                    if (!try unwindThrow(allocator, realm, frames, ex)) {
                        return .{ .thrown = ex };
                    }
                    continue;
                };

                const recv = registers[r_recv];

                // §28.2.2.1.1 — revocation function. See `.call`.
                if (callee_fn.revocable_proxy) |rp| {
                    rp.proxy_target = null;
                    rp.proxy_handler = null;
                    rp.proxy_target_fn = null;
                    rp.proxy_revoked = true;
                    callee_fn.revocable_proxy = null;
                    acc = Value.undefined_;
                    continue;
                }

                // §10.4.1 — bound functions unwrap. `this = recv`
                // is overridden by the bound `this` inside
                // `unwrapBoundCall`.
                if (callee_fn.bound_target != null) {
                    const args_start = @as(usize, r_callee) + 1;
                    const result = try callJSFunction(allocator, realm, callee_fn, recv, registers[args_start .. args_start + argc]);
                    switch (result) {
                        .value, .yielded => |v| acc = v,
                        .thrown => |ex| {
                            f.ip = ip;
                            f.accumulator = acc;
                            committed = true;
                            if (!try unwindThrow(allocator, realm, frames, ex)) {
                                return .{ .thrown = ex };
                            }
                            continue;
                        },
                    }
                    continue;
                }

                // §27.5 / §27.6 — calling a `function*` or
                // `async function*` allocates a generator wrapper
                // instead of running the body. Methods on a `class`
                // body marked `*g()` or `async *g()` flow through
                // here too.
                if (callee_fn.is_generator) {
                    const callee_chunk = callee_fn.chunk orelse return error.InvalidOpcode;
                    const args_start = @as(usize, r_callee) + 1;
                    const wrap_result = if (callee_fn.is_async)
                        try wrapAsyncGenerator(allocator, realm, callee_chunk, callee_fn.captured_env, recv, registers[args_start .. args_start + argc])
                    else
                        try wrapGenerator(allocator, realm, callee_chunk, callee_fn.captured_env, recv, registers[args_start .. args_start + argc]);
                    switch (wrap_result) {
                        .value, .yielded => |v| acc = v,
                        .thrown => |ex| {
                            f.ip = ip;
                            f.accumulator = acc;
                            committed = true;
                            if (!try unwindThrow(allocator, realm, frames, ex)) {
                                return .{ .thrown = ex };
                            }
                            continue;
                        },
                    }
                    continue;
                }

                // Native fast path — no frame, no register file.
                // §13.3.6 — `obj.method()` binds `this = obj`.
                if (callee_fn.native_callback) |native| {
                    const args_start = @as(usize, r_callee) + 1;
                    const args = registers[args_start .. args_start + argc];
                    const native_this: Value = recv;
                    const result = native(realm, native_this, args) catch |err| switch (err) {
                        error.OutOfMemory => return error.OutOfMemory,
                        error.NativeThrew => {
                            const ex = consumePendingException(realm) orelse try makeTypeError(realm, "native error");
                            f.ip = ip;
                            f.accumulator = acc;
                            committed = true;
                            if (!try unwindThrow(allocator, realm, frames, ex)) {
                                return .{ .thrown = ex };
                            }
                            continue;
                        },
                    };
                    acc = result;
                    continue;
                }

                if (callee_fn.is_async) {
                    const callee_chunk = callee_fn.chunk orelse return error.InvalidOpcode;
                    const args_start = @as(usize, r_callee) + 1;
                    const callee_this: Value = if (callee_fn.is_arrow) callee_fn.captured_this else recv;
                    const outcome = try startAsyncCall(allocator, realm, callee_chunk, callee_fn.captured_env, callee_this, registers[args_start .. args_start + argc]);
                    switch (outcome) {
                        .value, .yielded => |v| acc = v,
                        .thrown => |ex| {
                            f.ip = ip;
                            f.accumulator = acc;
                            committed = true;
                            if (!try unwindThrow(allocator, realm, frames, ex)) {
                                return .{ .thrown = ex };
                            }
                            continue;
                        },
                    }
                    continue;
                }

                if (frames.items.len >= max_call_frames) {
                    const ex = try makeRangeError(realm, "Maximum call stack size exceeded");
                    f.ip = ip;
                    f.accumulator = acc;
                    committed = true;
                    if (!try unwindThrow(allocator, realm, frames, ex)) {
                        return .{ .thrown = ex };
                    }
                    continue;
                }

                const callee_chunk = callee_fn.chunk orelse return error.InvalidOpcode;
                const callee_regs = try allocator.alloc(Value, @max(@as(usize, callee_chunk.register_count), @as(usize, argc)));
                @memset(callee_regs, Value.undefined_);
                var ai: u8 = 0;
                while (ai < argc and @as(usize, ai) < callee_regs.len) : (ai += 1) {
                    callee_regs[ai] = registers[r_callee + 1 + ai];
                }

                f.ip = ip;
                f.accumulator = acc;
                committed = true;

                // Arrow functions ignore the dynamic `this` — they
                // use their captured one. Non-arrow methods see
                // `this = recv`.
                const callee_this: Value = if (callee_fn.is_arrow)
                    callee_fn.captured_this
                else
                    recv;

                frames.append(allocator, .{
                    .chunk = callee_chunk,
                    .ip = 0,
                    .accumulator = Value.undefined_,
                    .registers = callee_regs,
                    .env = callee_fn.captured_env,
                    .this_value = callee_this,
                    .home_object = callee_fn.home_object,
                    .home_function = callee_fn.home_function,
                    .argc = argc,
                    .wrap_return_in_promise = false,
                }) catch {
                    allocator.free(callee_regs);
                    return error.OutOfMemory;
                };
            },

            .new_call => {
                const r_callee = code[ip];
                const argc = code[ip + 1];
                ip += 2;

                const callee_v = registers[r_callee];
                // §10.5.14 callable Proxy [[Construct]] — if a
                // construct trap is installed, dispatch through
                // the handler. Missing trap recurses into the
                // target via `constructValue` (which handles
                // chained proxies).
                if (heap_mod.valueAsPlainObject(callee_v)) |po| {
                    if (po.proxy_target_fn != null or po.proxy_target != null or po.proxy_revoked) {
                        const args_start = @as(usize, r_callee) + 1;
                        const args_slice = registers[args_start .. args_start + argc];
                        const cresult = try constructValue(allocator, realm, callee_v, args_slice, callee_v);
                        switch (cresult) {
                            .value, .yielded => |v| {
                                acc = v;
                                continue;
                            },
                            .thrown => |ex| {
                                f.ip = ip;
                                f.accumulator = acc;
                                committed = true;
                                if (!try unwindThrow(allocator, realm, frames, ex)) {
                                    return .{ .thrown = ex };
                                }
                                continue;
                            },
                        }
                    }
                }
                var resolved_v = callee_v;
                if (heap_mod.valueAsPlainObject(callee_v)) |po| {
                    if (po.proxy_target_fn) |target_fn| resolved_v = heap_mod.taggedFunction(target_fn);
                }
                const callee_fn = heap_mod.valueAsFunction(resolved_v) orelse {
                    const ex = try makeTypeError(realm, "value is not a constructor");
                    f.ip = ip;
                    f.accumulator = acc;
                    committed = true;
                    if (!try unwindThrow(allocator, realm, frames, ex)) {
                        return .{ .thrown = ex };
                    }
                    continue;
                };
                if (callee_fn.is_arrow) {
                    const ex = try makeTypeError(realm, "arrow functions are not constructors");
                    f.ip = ip;
                    f.accumulator = acc;
                    committed = true;
                    if (!try unwindThrow(allocator, realm, frames, ex)) {
                        return .{ .thrown = ex };
                    }
                    continue;
                }
                // §17 — built-in non-constructor methods don't
                // implement [[Construct]]. `new Object.keys()`,
                // `new Promise.all([])`, `new Reflect.has(...)`
                // all throw TypeError per the standard built-in
                // function-objects clause.
                if (!callee_fn.has_construct) {
                    const ex = try makeTypeError(realm, "function is not a constructor");
                    f.ip = ip;
                    f.accumulator = acc;
                    committed = true;
                    if (!try unwindThrow(allocator, realm, frames, ex)) {
                        return .{ .thrown = ex };
                    }
                    continue;
                }

                // §10.4.1.2 — `new boundFn(...)` constructs the
                // bound target with the concatenated args; the
                // bound `this` is ignored. Unwrap and re-enter
                // construct path on the real target. later
                // routes through `callJSFunction` for the
                // bound-function case (which won't apply
                // ConstructResult); to keep `new` semantics
                // correct we resolve the target first then fall
                // through to the normal `new_call` machinery
                // below by mutating `callee_fn`.
                var resolved_callee = callee_fn;
                var bound_args_owned: ?[]const Value = null;
                defer if (bound_args_owned) |ba| allocator.free(ba);
                if (callee_fn.bound_target != null) {
                    const args_start = @as(usize, r_callee) + 1;
                    const unwrapped = try unwrapBoundCall(allocator, callee_fn, Value.undefined_, registers[args_start .. args_start + argc], true);
                    resolved_callee = unwrapped.target;
                    if (unwrapped.owns_args) {
                        bound_args_owned = unwrapped.args;
                    }
                    // We can't directly extend the in-register
                    // arg slice; instead, re-enter `callJSFunction`
                    // with the constructor-flavour by allocating a
                    // synthetic instance and forcing the call.
                    // §10.1.14 GetPrototypeFromConstructor on the
                    // *bound* function (callee_fn — that's
                    // NewTarget per §10.4.1.2 step 5), so accessors
                    // on the bound function fire.
                    const proto_lookup = try getPrototypeFromConstructor(allocator, realm, callee_fn, resolved_callee.prototype);
                    const resolved_proto: ?*JSObject = switch (proto_lookup) {
                        .proto => |p| p,
                        .thrown => |ex| {
                            f.ip = ip;
                            f.accumulator = acc;
                            committed = true;
                            if (!try unwindThrow(allocator, realm, frames, ex)) {
                                return .{ .thrown = ex };
                            }
                            continue;
                        },
                    };
                    const inst = realm.heap.allocateObject() catch return error.OutOfMemory;
                    inst.prototype = resolved_proto;
                    const this_v = heap_mod.taggedObject(inst);
                    // §10.4.1.2 [[Construct]] step 5 — for a
                    // `new C()` where C is bound, the original
                    // newTarget *is* C, so the spec's
                    // `SameValue(F, newTarget)` collapses it to
                    // target. After fully unwrapping the bind
                    // chain, the new_target seen inside the
                    // target body is the unwrapped target itself
                    // — so `new.target` reads as `A` for
                    // `new A.bind().bind()()`.
                    const result = try callJSFunctionAsSuper(allocator, realm, resolved_callee, this_v, unwrapped.args, heap_mod.taggedFunction(resolved_callee));
                    switch (result) {
                        .value, .yielded => |v| {
                            // ConstructResult per §13.3.5.1.1.
                            if (heap_mod.valueAsPlainObject(v) != null or
                                heap_mod.valueAsFunction(v) != null)
                            {
                                acc = v;
                            } else {
                                acc = this_v;
                            }
                        },
                        .thrown => |ex| {
                            f.ip = ip;
                            f.accumulator = acc;
                            committed = true;
                            if (!try unwindThrow(allocator, realm, frames, ex)) {
                                return .{ .thrown = ex };
                            }
                            continue;
                        },
                    }
                    continue;
                }

                // §13.3.5.1.1 OrdinaryCallBindThis with NewTarget=callee.
                // §10.1.14 GetPrototypeFromConstructor — read
                // `prototype` through the accessor path so a
                // user-installed getter on the constructor fires.
                const proto_lookup_main = try getPrototypeFromConstructor(allocator, realm, callee_fn, callee_fn.prototype);
                const resolved_proto_main: ?*JSObject = switch (proto_lookup_main) {
                    .proto => |p| p,
                    .thrown => |ex| {
                        f.ip = ip;
                        f.accumulator = acc;
                        committed = true;
                        if (!try unwindThrow(allocator, realm, frames, ex)) {
                            return .{ .thrown = ex };
                        }
                        continue;
                    },
                };
                const instance = realm.heap.allocateObject() catch return error.OutOfMemory;
                instance.prototype = resolved_proto_main;
                const this_value = heap_mod.taggedObject(instance);

                // Native fast path — same calling shape as `Call`,
                // but with the implicit instance allocated above.
                // a way to flag a native as a true
                // constructor (i.e. it returns the instance). For
                // later, treat native callees as plain calls
                // and ignore the construct path.
                if (callee_fn.native_callback) |native| {
                    const args_start = @as(usize, r_callee) + 1;
                    const args = registers[args_start .. args_start + argc];
                    // For native constructors, `this` is the freshly
                    // allocated instance (the §13.3.5.1.1 fallback).
                    const native_this: Value = this_value;
                    const result = native(realm, native_this, args) catch |err| switch (err) {
                        error.OutOfMemory => return error.OutOfMemory,
                        error.NativeThrew => {
                            const ex = consumePendingException(realm) orelse try makeTypeError(realm, "native error");
                            f.ip = ip;
                            f.accumulator = acc;
                            committed = true;
                            if (!try unwindThrow(allocator, realm, frames, ex)) {
                                return .{ .thrown = ex };
                            }
                            continue;
                        },
                    };
                    // §13.3.5.1.1 ConstructResult: object > this.
                    if (heap_mod.valueAsPlainObject(result) != null or
                        heap_mod.valueAsFunction(result) != null)
                    {
                        acc = result;
                    } else {
                        acc = this_value;
                    }
                    continue;
                }

                if (frames.items.len >= max_call_frames) {
                    const ex = try makeRangeError(realm, "Maximum call stack size exceeded");
                    f.ip = ip;
                    f.accumulator = acc;
                    committed = true;
                    if (!try unwindThrow(allocator, realm, frames, ex)) {
                        return .{ .thrown = ex };
                    }
                    continue;
                }

                const callee_chunk = callee_fn.chunk orelse return error.InvalidOpcode;
                const callee_regs = try allocator.alloc(Value, @max(@as(usize, callee_chunk.register_count), @as(usize, argc)));
                @memset(callee_regs, Value.undefined_);
                var ai: u8 = 0;
                while (ai < argc and @as(usize, ai) < callee_regs.len) : (ai += 1) {
                    callee_regs[ai] = registers[r_callee + 1 + ai];
                }

                f.ip = ip;
                f.accumulator = acc;
                committed = true;

                frames.append(allocator, .{
                    .chunk = callee_chunk,
                    .ip = 0,
                    .accumulator = Value.undefined_,
                    .registers = callee_regs,
                    .env = callee_fn.captured_env,
                    .this_value = this_value,
                    .is_construct = true,
                    .is_derived_ctor = callee_fn.constructor_kind == .derived,
                    .new_target = heap_mod.taggedFunction(callee_fn),
                    .home_object = callee_fn.home_object,
                    .home_function = callee_fn.home_function,
                    .argc = argc,
                }) catch {
                    allocator.free(callee_regs);
                    return error.OutOfMemory;
                };
            },

            .lda_this => {
                acc = f.this_value;
            },

            .lda_new_target => {
                acc = f.new_target;
            },

            .instanceof_ => {
                const r = code[ip];
                ip += 1;
                const lhs = registers[r];
                const rhs = acc;
                // §13.10.2 InstanceofOperator step 1 — target must
                // be an Object (plain object OR function both
                // qualify; Symbols / primitives throw TypeError).
                const rhs_obj_opt: ?*JSObject = heap_mod.valueAsPlainObject(rhs);
                const rhs_fn_opt: ?*JSFunction = heap_mod.valueAsFunction(rhs);
                if (rhs_obj_opt == null and rhs_fn_opt == null) {
                    const ex = try makeTypeError(realm, "Right-hand side of instanceof is not an object");
                    f.ip = ip;
                    f.accumulator = acc;
                    committed = true;
                    if (!try unwindThrow(allocator, realm, frames, ex)) {
                        return .{ .thrown = ex };
                    }
                    continue;
                }
                // §13.10.2 step 2 — `GetMethod(target, @@hasInstance)`.
                // Walks the prototype chain. If present and not null /
                // undefined, invoke it as the handler.
                const hi_v: Value = if (rhs_obj_opt) |o| o.get("@@hasInstance") else if (rhs_fn_opt) |fn_obj| fn_obj.get("@@hasInstance") else Value.undefined_;
                if (heap_mod.valueAsFunction(hi_v)) |hi_fn| {
                    const hi_args = [_]Value{lhs};
                    const outcome = try callJSFunction(allocator, realm, hi_fn, rhs, &hi_args);
                    switch (outcome) {
                        .value, .yielded => |v| {
                            acc = Value.fromBool(v.toBooleanPrimitive());
                            continue;
                        },
                        .thrown => |ex| {
                            f.ip = ip;
                            f.accumulator = acc;
                            committed = true;
                            if (!try unwindThrow(allocator, realm, frames, ex)) {
                                return .{ .thrown = ex };
                            }
                            continue;
                        },
                    }
                }
                // §13.10.2 step 4 — without an @@hasInstance handler,
                // target must be callable (i.e. a JSFunction).
                const rhs_fn = rhs_fn_opt orelse {
                    const ex = try makeTypeError(realm, "Right-hand side of instanceof is not callable");
                    f.ip = ip;
                    f.accumulator = acc;
                    committed = true;
                    if (!try unwindThrow(allocator, realm, frames, ex)) {
                        return .{ .thrown = ex };
                    }
                    continue;
                };
                // §7.3.20 OrdinaryHasInstance — unwrap bound
                // targets (step 1) and look up `Get(C, "prototype")`
                // (step 5) so a user-assigned `f.prototype = {…}`
                // shadowing the auto-allocated slot is honored.
                var target_fn = rhs_fn;
                while (target_fn.bound_target) |inner| target_fn = inner;
                const target_proto_v = target_fn.get("prototype");
                const target_proto: ?*JSObject = heap_mod.valueAsPlainObject(target_proto_v);
                if (target_proto == null) {
                    // Step 6.b — non-Object prototype TypeErrors;
                    // but legacy fixtures expect `false` for the
                    // never-set case, so distinguish via the slot.
                    if (target_fn.prototype == null) {
                        acc = Value.fromBool(false);
                    } else {
                        const ex = try makeTypeError(realm, "Function has non-object prototype in instanceof check");
                        f.ip = ip;
                        f.accumulator = acc;
                        committed = true;
                        if (!try unwindThrow(allocator, realm, frames, ex)) {
                            return .{ .thrown = ex };
                        }
                        continue;
                    }
                } else if (heap_mod.valueAsPlainObject(lhs)) |lhs_obj| {
                    var cursor: ?*JSObject = lhs_obj.prototype;
                    var found = false;
                    while (cursor) |p| : (cursor = p.prototype) {
                        if (p == target_proto.?) {
                            found = true;
                            break;
                        }
                    }
                    acc = Value.fromBool(found);
                } else if (heap_mod.valueAsFunction(lhs)) |lhs_fn| {
                    // §10.2 — functions are objects; their proto
                    // chain seeds from the `JSFunction.proto` slot
                    // (a `*JSObject`). Without this branch,
                    // `function*g(){} instanceof GeneratorFunction`
                    // was always false because the LHS was filtered
                    // out by `valueAsPlainObject`.
                    var cursor: ?*JSObject = lhs_fn.proto;
                    var found = false;
                    while (cursor) |p| : (cursor = p.prototype) {
                        if (p == target_proto.?) {
                            found = true;
                            break;
                        }
                    }
                    acc = Value.fromBool(found);
                } else {
                    // Non-object LHS is never an instance.
                    acc = Value.fromBool(false);
                }
            },

            .object_rest_from => {
                const r_src = code[ip];
                const r_excl = code[ip + 1];
                ip += 2;
                const src_v = registers[r_src];
                const excl_v = registers[r_excl];
                const out_obj = realm.heap.allocateObject() catch return error.OutOfMemory;
                out_obj.prototype = realm.intrinsics.object_prototype;
                if (heap_mod.valueAsPlainObject(src_v)) |src_obj| {
                    // Build a quick lookup of excluded keys by
                    // walking the array argument.
                    var excluded: std.ArrayListUnmanaged([]const u8) = .empty;
                    defer excluded.deinit(allocator);
                    if (heap_mod.valueAsPlainObject(excl_v)) |excl_arr| {
                        const len_v = excl_arr.get("length");
                        const len_i: i64 = if (len_v.isInt32()) len_v.asInt32() else 0;
                        var ibuf: [24]u8 = undefined;
                        var i: i64 = 0;
                        while (i < len_i) : (i += 1) {
                            const islice = std.fmt.bufPrint(&ibuf, "{d}", .{i}) catch unreachable;
                            const k_v = excl_arr.get(islice);
                            if (k_v.isString()) {
                                const ks: *JSString = @ptrCast(@alignCast(k_v.asString()));
                                excluded.append(allocator, ks.bytes) catch return error.OutOfMemory;
                            }
                        }
                    }
                    var it = src_obj.properties.iterator();
                    while (it.next()) |entry| {
                        const k = entry.key_ptr.*;
                        if (std.mem.startsWith(u8, k, "__cynic_")) continue;
                        const flags = src_obj.flagsFor(k);
                        if (!flags.enumerable) continue;
                        var skip = false;
                        for (excluded.items) |ek| {
                            if (std.mem.eql(u8, ek, k)) {
                                skip = true;
                                break;
                            }
                        }
                        if (skip) continue;
                        out_obj.set(allocator, k, entry.value_ptr.*) catch return error.OutOfMemory;
                    }
                }
                acc = heap_mod.taggedObject(out_obj);
            },

            .array_rest_from => {
                const r = code[ip];
                const start = code[ip + 1];
                ip += 2;
                const src_v = registers[r];
                // Read length from source (best-effort: 0 on
                // non-array-shaped sources, matching `slice`).
                var len_i: i64 = 0;
                if (heap_mod.valueAsPlainObject(src_v)) |src_obj| {
                    const len_v = src_obj.get("length");
                    if (len_v.isInt32()) len_i = len_v.asInt32() else if (len_v.isDouble()) {
                        const d = len_v.asDouble();
                        if (!std.math.isNan(d) and !std.math.isInf(d) and d >= 0) {
                            len_i = @intFromFloat(d);
                        }
                    }
                }
                const out_obj = realm.heap.allocateObject() catch return error.OutOfMemory;
                out_obj.prototype = realm.intrinsics.array_prototype;
                out_obj.markAsArrayExotic(allocator) catch return error.OutOfMemory;
                var i: i64 = start;
                var out_idx: i64 = 0;
                var ibuf: [24]u8 = undefined;
                while (i < len_i) : ({
                    i += 1;
                    out_idx += 1;
                }) {
                    const src_obj = heap_mod.valueAsPlainObject(src_v) orelse break;
                    const src_islice = std.fmt.bufPrint(&ibuf, "{d}", .{i}) catch unreachable;
                    const elem = src_obj.get(src_islice);
                    var obuf: [24]u8 = undefined;
                    const out_islice = std.fmt.bufPrint(&obuf, "{d}", .{out_idx}) catch unreachable;
                    const owned = realm.heap.allocateString(out_islice) catch return error.OutOfMemory;
                    out_obj.set(allocator, owned.bytes, elem) catch return error.OutOfMemory;
                }
                out_obj.set(allocator, "length", Value.fromInt32(@intCast(out_idx))) catch return error.OutOfMemory;
                acc = heap_mod.taggedObject(out_obj);
            },

            .iter_close => {
                const r = code[ip];
                const mode = code[ip + 1];
                ip += 2;
                const iter_v = registers[r];
                if (heap_mod.valueAsPlainObject(iter_v)) |iter_obj| {
                    // §7.4.6 IteratorClose step 4 — only run when
                    // `iteratorRecord.[[Done]]` is false. Cynic
                    // tracks this on the iter object itself via
                    // the `__cynic_iter_done__` slot that
                    // `iter_step` maintains.
                    if (iter_obj.properties.get("__cynic_iter_done__")) |dv| {
                        if (toBoolean(dv)) continue;
                    }
                    const ret_v = iter_obj.get("return");
                    if (heap_mod.valueAsFunction(ret_v)) |ret_fn| {
                        // §7.4.6 IteratorClose — completion-type
                        // dispatch. `mode == 1` ⇒ the surrounding
                        // completion is `throw`: per step 7, the
                        // outer throw wins, so swallow any inner
                        // throw from `return()` and skip the
                        // non-Object check (step 9 only runs when
                        // completion is not throw). `mode == 0` ⇒
                        // `normal` / `return` / `break`: an inner
                        // throw from `return()` propagates
                        // (step 8), and a non-Object return value
                        // throws TypeError (step 9).
                        const saved_acc = acc;
                        const outcome = try callJSFunction(allocator, realm, ret_fn, iter_v, &.{});
                        if (mode == 1) {
                            // Throw-completion path: discard
                            // whatever `return()` produced.
                            if (realm.pending_exception != null) realm.pending_exception = null;
                            acc = saved_acc;
                        } else {
                            switch (outcome) {
                                .thrown => |ex| {
                                    // §7.4.6 step 8 — propagate.
                                    if (realm.pending_exception != null) realm.pending_exception = null;
                                    f.ip = ip;
                                    f.accumulator = acc;
                                    committed = true;
                                    if (!try unwindThrow(allocator, realm, frames, ex)) {
                                        return .{ .thrown = ex };
                                    }
                                    continue;
                                },
                                .value, .yielded => |v| {
                                    // §7.4.6 step 9 — non-Object
                                    // return value ⇒ TypeError.
                                    const is_object =
                                        heap_mod.valueAsPlainObject(v) != null or
                                        heap_mod.valueAsFunction(v) != null;
                                    if (!is_object) {
                                        const ex = try makeTypeError(realm, "Iterator result is not an object");
                                        f.ip = ip;
                                        f.accumulator = acc;
                                        committed = true;
                                        if (!try unwindThrow(allocator, realm, frames, ex)) {
                                            return .{ .thrown = ex };
                                        }
                                        continue;
                                    }
                                    acc = saved_acc;
                                },
                            }
                        }
                    }
                }
            },

            .in_op => {
                const r = code[ip];
                ip += 1;
                const obj_v = acc;
                // §13.10.1 — RHS must be an object; otherwise TypeError.
                const obj_in = heap_mod.valueAsPlainObject(obj_v) orelse {
                    const ex = try makeTypeError(realm, "Cannot use 'in' operator to search non-object");
                    f.ip = ip;
                    f.accumulator = acc;
                    committed = true;
                    if (!try unwindThrow(allocator, realm, frames, ex)) {
                        return .{ .thrown = ex };
                    }
                    continue;
                };
                // §7.1.19 ToPropertyKey on the LHS.
                const key_v = switch (try coerceToPropertyKey(allocator, realm, frames, f, ip, registers[r])) {
                    .ok => |v| v,
                    .handled => {
                        committed = true;
                        continue;
                    },
                    .uncaught => |ex| return .{ .thrown = ex },
                };
                var key_buf: [64]u8 = undefined;
                const key_slice = computedKeyToString(key_v, &key_buf);
                // §10.5.7 Proxy [[HasProperty]] dispatch.
                var obj = obj_in;
                if (obj.proxy_target != null or obj.proxy_revoked) {
                    const r2 = try proxyHasTrap(allocator, realm, frames, f, ip, obj, key_slice);
                    switch (r2) {
                        .value => |v| {
                            acc = v;
                            continue;
                        },
                        .fallthrough => |t| obj = t,
                        .handled => {
                            committed = true;
                            continue;
                        },
                        .uncaught => |ex| return .{ .thrown = ex },
                    }
                }
                // Walk own + prototype chain.
                var cursor: ?*JSObject = obj;
                var found = false;
                while (cursor) |c| : (cursor = c.prototype) {
                    if (c.properties.contains(key_slice) or c.accessors.contains(key_slice)) {
                        found = true;
                        break;
                    }
                }
                acc = Value.fromBool(found);
            },

            // ── Class definition + super ───────────────────────
            .make_class => {
                const k = readU16(code, ip);
                ip += 2;
                if (k >= local_chunk.class_templates.len) return error.InvalidOpcode;
                const tmpl = &local_chunk.class_templates[k];
                const heritage: ?Value = if (tmpl.has_heritage) acc else null;
                const class_mod = @import("class.zig");
                acc = class_mod.buildClass(realm, tmpl, f.env, heritage) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    error.HeritageNotConstructor => blk: {
                        const ex = try makeTypeError(realm, "Class extends value is not a constructor");
                        f.ip = ip;
                        f.accumulator = acc;
                        committed = true;
                        if (!try unwindThrow(allocator, realm, frames, ex)) {
                            return .{ .thrown = ex };
                        }
                        break :blk Value.undefined_;
                    },
                    error.Propagated => blk: {
                        // §13.2.5.5 step 1.b — class-element key
                        // (or initializer / ToPrimitive coercion)
                        // threw. The value lives in
                        // `realm.pending_exception`; surface it
                        // into the frame stack.
                        const ex = realm.pending_exception orelse try makeTypeError(realm, "Class definition threw");
                        realm.pending_exception = null;
                        f.ip = ip;
                        f.accumulator = acc;
                        committed = true;
                        if (!try unwindThrow(allocator, realm, frames, ex)) {
                            return .{ .thrown = ex };
                        }
                        break :blk Value.undefined_;
                    },
                };
                if (committed) continue;
            },

            .super_get => {
                const k = readU16(code, ip);
                ip += 2;
                if (k >= local_chunk.constants.len) return error.InvalidOpcode;
                const key_v = local_chunk.constants[k];
                if (!key_v.isString()) return error.InvalidOpcode;
                const key_s: *JSString = @ptrCast(@alignCast(key_v.asString()));
                // §13.3.7 static-method form — home is the class
                // constructor (a JSFunction); super walks
                // `ctor.static_parent` which is the parent class.
                if (f.home_function) |hf| {
                    if (hf.static_parent) |parent_fn| {
                        // §10.1.8.1 OrdinaryGet — accessor descriptor
                        // wins; getter fires with `this` =
                        // f.this_value (the current class).
                        if (parent_fn.accessors.get(key_s.bytes)) |acc_pair| {
                            if (acc_pair.getter) |getter| {
                                const outcome = try callJSFunction(allocator, realm, getter, f.this_value, &.{});
                                switch (outcome) {
                                    .value, .yielded => |v| acc = v,
                                    .thrown => |ex| {
                                        f.ip = ip;
                                        f.accumulator = acc;
                                        committed = true;
                                        if (!try unwindThrow(allocator, realm, frames, ex)) {
                                            return .{ .thrown = ex };
                                        }
                                        continue;
                                    },
                                }
                            } else {
                                acc = Value.undefined_;
                            }
                        } else {
                            acc = parent_fn.get(key_s.bytes);
                        }
                    } else {
                        acc = Value.undefined_;
                    }
                    continue;
                }
                const home = f.home_object orelse {
                    const ex = try makeTypeError(realm, "super used outside a method");
                    f.ip = ip;
                    f.accumulator = acc;
                    committed = true;
                    if (!try unwindThrow(allocator, realm, frames, ex)) {
                        return .{ .thrown = ex };
                    }
                    continue;
                };
                const parent_proto = home.prototype orelse {
                    acc = Value.undefined_;
                    continue;
                };
                // §10.1.8 OrdinaryGet via super reference — the
                // accessor descriptor wins, and getters fire with
                // `this` bound to the caller's `this_value` (§9.1.6
                // step 5: Receiver = the active method's `this`,
                // not the parent prototype).
                if (lookupAccessor(parent_proto, key_s.bytes)) |acc_pair| {
                    if (acc_pair.getter) |getter| {
                        const outcome = try callJSFunction(allocator, realm, getter, f.this_value, &.{});
                        switch (outcome) {
                            .value, .yielded => |v| acc = v,
                            .thrown => |ex| {
                                f.ip = ip;
                                f.accumulator = acc;
                                committed = true;
                                if (!try unwindThrow(allocator, realm, frames, ex)) {
                                    return .{ .thrown = ex };
                                }
                                continue;
                            },
                        }
                    } else {
                        acc = Value.undefined_;
                    }
                    continue;
                }
                acc = parent_proto.get(key_s.bytes);
            },

            .super_get_computed => {
                if (f.home_function) |hf| {
                    const key_v_static = switch (try coerceToPropertyKey(allocator, realm, frames, f, ip, acc)) {
                        .ok => |v| v,
                        .handled => {
                            committed = true;
                            continue;
                        },
                        .uncaught => |ex| return .{ .thrown = ex },
                    };
                    var key_buf_s: [64]u8 = undefined;
                    const key_slice_s = computedKeyToString(key_v_static, &key_buf_s);
                    if (hf.static_parent) |parent_fn| {
                        acc = parent_fn.get(key_slice_s);
                    } else {
                        acc = Value.undefined_;
                    }
                    continue;
                }
                const home = f.home_object orelse {
                    const ex = try makeTypeError(realm, "super used outside a method");
                    f.ip = ip;
                    f.accumulator = acc;
                    committed = true;
                    if (!try unwindThrow(allocator, realm, frames, ex)) {
                        return .{ .thrown = ex };
                    }
                    continue;
                };
                const parent_proto = home.prototype orelse {
                    acc = Value.undefined_;
                    continue;
                };
                // §7.1.19 ToPropertyKey on the bracket key.
                const key_v = switch (try coerceToPropertyKey(allocator, realm, frames, f, ip, acc)) {
                    .ok => |v| v,
                    .handled => {
                        committed = true;
                        continue;
                    },
                    .uncaught => |ex| return .{ .thrown = ex },
                };
                var key_buf: [64]u8 = undefined;
                const key_slice = computedKeyToString(key_v, &key_buf);
                if (lookupAccessor(parent_proto, key_slice)) |acc_pair| {
                    if (acc_pair.getter) |getter| {
                        const outcome = try callJSFunction(allocator, realm, getter, f.this_value, &.{});
                        switch (outcome) {
                            .value, .yielded => |v| acc = v,
                            .thrown => |ex| {
                                f.ip = ip;
                                f.accumulator = acc;
                                committed = true;
                                if (!try unwindThrow(allocator, realm, frames, ex)) {
                                    return .{ .thrown = ex };
                                }
                                continue;
                            },
                        }
                    } else {
                        acc = Value.undefined_;
                    }
                    continue;
                }
                acc = parent_proto.get(key_slice);
            },

            .super_set => {
                // §13.3.7 — `super.<key> = registers[r_value]`.
                // Walk `home.[[Prototype]]` for an accessor; if a
                // setter is found, call it with `this = f.this_value`.
                // Otherwise, define the property on `this` (the
                // §10.1.9.2 OrdinarySetWithOwnDescriptor receiver
                // path, simplified). The new value is left in
                // `acc` so the surrounding assignment-expression
                // result is correct (§13.15.2 step 5).
                const k = readU16(code, ip);
                const r_value = code[ip + 2];
                ip += 3;
                if (k >= local_chunk.constants.len) return error.InvalidOpcode;
                const key_v = local_chunk.constants[k];
                if (!key_v.isString()) return error.InvalidOpcode;
                const key_s: *JSString = @ptrCast(@alignCast(key_v.asString()));
                const value = registers[r_value];
                // §13.3.7 static-method form — `this` is the
                // current class; super setter dispatch reads the
                // parent JSFunction's `accessors` map.
                if (f.home_function) |hf| {
                    if (hf.static_parent) |parent_fn| {
                        if (parent_fn.accessors.get(key_s.bytes)) |acc_pair| {
                            if (acc_pair.setter) |setter| {
                                const args_one = [_]Value{value};
                                const outcome = try callJSFunction(allocator, realm, setter, f.this_value, &args_one);
                                switch (outcome) {
                                    .value, .yielded => {},
                                    .thrown => |ex| {
                                        f.ip = ip;
                                        f.accumulator = acc;
                                        committed = true;
                                        if (!try unwindThrow(allocator, realm, frames, ex)) {
                                            return .{ .thrown = ex };
                                        }
                                        continue;
                                    },
                                }
                                acc = value;
                                continue;
                            }
                        }
                    }
                    // Fall back to writing on `this` (the
                    // current constructor, since this is static).
                    if (heap_mod.valueAsFunction(f.this_value)) |this_fn| {
                        this_fn.set(allocator, key_s.bytes, value) catch return error.OutOfMemory;
                    } else if (heap_mod.valueAsPlainObject(f.this_value)) |this_obj| {
                        this_obj.set(allocator, key_s.bytes, value) catch return error.OutOfMemory;
                    }
                    acc = value;
                    continue;
                }
                const home = f.home_object orelse {
                    const ex = try makeTypeError(realm, "super used outside a method");
                    f.ip = ip;
                    f.accumulator = acc;
                    committed = true;
                    if (!try unwindThrow(allocator, realm, frames, ex)) {
                        return .{ .thrown = ex };
                    }
                    continue;
                };
                const parent_proto = home.prototype;
                var did_setter = false;
                if (parent_proto) |p| {
                    if (lookupAccessor(p, key_s.bytes)) |acc_pair| {
                        if (acc_pair.setter) |setter| {
                            const args_one = [_]Value{value};
                            const outcome = try callJSFunction(allocator, realm, setter, f.this_value, &args_one);
                            switch (outcome) {
                                .value, .yielded => {},
                                .thrown => |ex| {
                                    f.ip = ip;
                                    f.accumulator = acc;
                                    committed = true;
                                    if (!try unwindThrow(allocator, realm, frames, ex)) {
                                        return .{ .thrown = ex };
                                    }
                                    continue;
                                },
                            }
                            did_setter = true;
                        }
                    }
                }
                if (!did_setter) {
                    // Fall back to a plain `this[key] = value`
                    // write per §10.1.9.2 — the receiver is the
                    // current `this`, not the parent prototype.
                    if (heap_mod.valueAsPlainObject(f.this_value)) |this_obj| {
                        this_obj.set(allocator, key_s.bytes, value) catch return error.OutOfMemory;
                    }
                }
                acc = value;
            },

            .super_set_computed => {
                // §13.3.7 — `super[key] = value`. `r_key` holds
                // the key after ToPropertyKey, `r_value` the
                // value to write. Same dispatch shape as
                // `super_set`.
                const r_key = code[ip];
                const r_value = code[ip + 1];
                ip += 2;
                const key_v = registers[r_key];
                const value = registers[r_value];
                const home = f.home_object orelse {
                    const ex = try makeTypeError(realm, "super used outside a method");
                    f.ip = ip;
                    f.accumulator = acc;
                    committed = true;
                    if (!try unwindThrow(allocator, realm, frames, ex)) {
                        return .{ .thrown = ex };
                    }
                    continue;
                };
                var key_buf: [64]u8 = undefined;
                const key_slice = computedKeyToString(key_v, &key_buf);
                const parent_proto = home.prototype;
                var did_setter = false;
                if (parent_proto) |p| {
                    if (lookupAccessor(p, key_slice)) |acc_pair| {
                        if (acc_pair.setter) |setter| {
                            const args_one = [_]Value{value};
                            const outcome = try callJSFunction(allocator, realm, setter, f.this_value, &args_one);
                            switch (outcome) {
                                .value, .yielded => {},
                                .thrown => |ex| {
                                    f.ip = ip;
                                    f.accumulator = acc;
                                    committed = true;
                                    if (!try unwindThrow(allocator, realm, frames, ex)) {
                                        return .{ .thrown = ex };
                                    }
                                    continue;
                                },
                            }
                            did_setter = true;
                        }
                    }
                }
                if (!did_setter) {
                    if (heap_mod.valueAsPlainObject(f.this_value)) |this_obj| {
                        this_obj.set(allocator, key_slice, value) catch return error.OutOfMemory;
                    }
                }
                acc = value;
            },

            .init_instance_fields => {
                // §15.7.10 InitializeInstanceElements. Reads the
                // executing fn's home_object (= class prototype),
                // installs each private method binding on the
                // instance, then runs each field initializer.
                const home = f.home_object orelse return error.InvalidOpcode;
                if (home.private_method_inits) |inits| {
                    if (heap_mod.valueAsPlainObject(f.this_value)) |inst| {
                        for (inits) |entry| {
                            if (entry.init_fn) |fn_obj| {
                                switch (entry.accessor_kind) {
                                    .none => {
                                        inst.private_properties.put(allocator, entry.name, heap_mod.taggedFunction(fn_obj)) catch return error.OutOfMemory;
                                        // §7.3.30 PrivateSet step 4 — methods are read-only.
                                        inst.private_methods.put(allocator, entry.name, {}) catch return error.OutOfMemory;
                                    },
                                    .getter => {
                                        const ent = inst.private_accessors.getOrPut(allocator, entry.name) catch return error.OutOfMemory;
                                        if (!ent.found_existing) ent.value_ptr.* = .{};
                                        ent.value_ptr.*.getter = fn_obj;
                                    },
                                    .setter => {
                                        const ent = inst.private_accessors.getOrPut(allocator, entry.name) catch return error.OutOfMemory;
                                        if (!ent.found_existing) ent.value_ptr.* = .{};
                                        ent.value_ptr.*.setter = fn_obj;
                                    },
                                }
                            }
                        }
                    }
                }
                if (home.instance_field_inits) |inits| {
                    for (inits) |entry| {
                        var v: Value = Value.undefined_;
                        if (entry.init_fn) |init_fn| {
                            const outcome = try callJSFunction(allocator, realm, init_fn, f.this_value, &.{});
                            switch (outcome) {
                                .value, .yielded => |val| v = val,
                                .thrown => |ex| {
                                    f.ip = ip;
                                    f.accumulator = acc;
                                    committed = true;
                                    if (!try unwindThrow(allocator, realm, frames, ex)) {
                                        return .{ .thrown = ex };
                                    }
                                    break;
                                },
                            }
                        }
                        if (heap_mod.valueAsPlainObject(f.this_value)) |inst| {
                            if (entry.is_private) {
                                inst.private_properties.put(allocator, entry.name, v) catch return error.OutOfMemory;
                            } else {
                                inst.set(allocator, entry.name, v) catch return error.OutOfMemory;
                            }
                        }
                    }
                    if (committed) continue;
                }
            },

            .lda_private => {
                const k = readU16(code, ip);
                ip += 2;
                if (k >= local_chunk.constants.len) return error.InvalidOpcode;
                const key_v = local_chunk.constants[k];
                if (!key_v.isString()) return error.InvalidOpcode;
                const key_s: *JSString = @ptrCast(@alignCast(key_v.asString()));
                // §15.7 — `class C { static #x = …; static M() { return C.#x; } }`
                // routes the read through the constructor's
                // private slots when the receiver is the class
                // function itself.
                if (heap_mod.valueAsFunction(acc)) |fn_recv| {
                    if (fn_recv.private_accessors.get(key_s.bytes)) |pa| {
                        if (pa.getter) |getter| {
                            const outcome = try callJSFunction(allocator, realm, getter, acc, &.{});
                            switch (outcome) {
                                .value, .yielded => |v| acc = v,
                                .thrown => |ex| {
                                    f.ip = ip;
                                    f.accumulator = acc;
                                    committed = true;
                                    if (!try unwindThrow(allocator, realm, frames, ex)) {
                                        return .{ .thrown = ex };
                                    }
                                    continue;
                                },
                            }
                        } else {
                            // §10.1.8.1 PrivateFieldGet step 6.b —
                            // accessor without [[Get]] throws TypeError.
                            const ex = try makeTypeError(realm, "Cannot read from private accessor with no getter");
                            f.ip = ip;
                            f.accumulator = acc;
                            committed = true;
                            if (!try unwindThrow(allocator, realm, frames, ex)) {
                                return .{ .thrown = ex };
                            }
                        }
                        continue;
                    }
                    if (fn_recv.private_properties.get(key_s.bytes)) |v| {
                        acc = v;
                        continue;
                    }
                    const ex = try makeTypeError(realm, "Cannot read private field — brand check failed");
                    f.ip = ip;
                    f.accumulator = acc;
                    committed = true;
                    if (!try unwindThrow(allocator, realm, frames, ex)) {
                        return .{ .thrown = ex };
                    }
                    continue;
                }
                const recv = heap_mod.valueAsPlainObject(acc) orelse {
                    const ex = try makeTypeError(realm, "Cannot read private field on non-object");
                    f.ip = ip;
                    f.accumulator = acc;
                    committed = true;
                    if (!try unwindThrow(allocator, realm, frames, ex)) {
                        return .{ .thrown = ex };
                    }
                    continue;
                };
                // §15.7 — private accessor descriptors win over
                // data slots on read. A read of a write-only
                // accessor (`set #x` without `get #x`) throws
                // TypeError per §10.1.8.1 PrivateFieldGet step 6.b.
                if (recv.private_accessors.get(key_s.bytes)) |pa| {
                    if (pa.getter) |getter| {
                        const outcome = try callJSFunction(allocator, realm, getter, heap_mod.taggedObject(recv), &.{});
                        switch (outcome) {
                            .value, .yielded => |v| acc = v,
                            .thrown => |ex| {
                                f.ip = ip;
                                f.accumulator = acc;
                                committed = true;
                                if (!try unwindThrow(allocator, realm, frames, ex)) {
                                    return .{ .thrown = ex };
                                }
                                continue;
                            },
                        }
                    } else {
                        const ex = try makeTypeError(realm, "Cannot read from private accessor with no getter");
                        f.ip = ip;
                        f.accumulator = acc;
                        committed = true;
                        if (!try unwindThrow(allocator, realm, frames, ex)) {
                            return .{ .thrown = ex };
                        }
                        continue;
                    }
                } else if (recv.private_properties.get(key_s.bytes)) |v| {
                    acc = v;
                } else {
                    const ex = try makeTypeError(realm, "Cannot read private field — brand check failed");
                    f.ip = ip;
                    f.accumulator = acc;
                    committed = true;
                    if (!try unwindThrow(allocator, realm, frames, ex)) {
                        return .{ .thrown = ex };
                    }
                    continue;
                }
            },

            .gen_yield => {
                // §27.5.3.7 GeneratorYield — save the frame
                // state into the generator and unwind the
                // dispatch loop with `.yielded`. The caller
                // (gen.next()) reads the value, returns
                // `{value, done: false}` to JS land. Resume
                // re-pushes the frame with `acc = sent_value`.
                const gen = f.generator orelse return error.InvalidOpcode;
                gen.ip = ip;
                gen.accumulator = Value.undefined_;
                gen.env = f.env;
                gen.this_value = f.this_value;
                gen.home_object = f.home_object;
                gen.home_function = f.home_function;
                gen.argc = f.argc;
                f.ip = ip;
                f.accumulator = acc;
                committed = true;
                return .{ .yielded = acc };
            },

            .gen_initial_suspend => {
                // §10.2.1.4 / §27.5.4.2 / §27.6.3.2 — emitted
                // between the param prologue and the body of
                // every `function*` / `async function*`.
                // `wrapGenerator` / `wrapAsyncGenerator` run the
                // chunk eagerly so the param destructuring etc.
                // executes at call time; this op saves the
                // frame and unwinds. The wrapper drops the
                // yielded value on the floor — first `.next()`
                // resumes here with `acc = sent_value`.
                const gen = f.generator orelse return error.InvalidOpcode;
                gen.ip = ip;
                gen.accumulator = Value.undefined_;
                gen.env = f.env;
                gen.this_value = f.this_value;
                gen.home_object = f.home_object;
                gen.home_function = f.home_function;
                gen.argc = f.argc;
                f.ip = ip;
                f.accumulator = acc;
                committed = true;
                return .{ .yielded = Value.undefined_ };
            },

            .await_ => {
                // §27.5.3.8 Await. Three paths:
                // • acc isn't a Promise → leave as-is (spec
                // says wrap in `Promise.resolve(v)` and
                // immediately resume; equivalent for the
                // synchronous-fast-path observers we care
                // about).
                // • acc is a settled Promise → unwrap (acc =
                // value for fulfilled, throw for rejected).
                // • acc is a pending Promise → save the frame
                // into the surrounding async generator,
                // register the gen as a waiter on the
                // awaited Promise, and unwind via
                // `.yielded`. The resumption microtask
                // re-enters `runFrames` with the settled
                // value (or throws inside the resumed frame
                // for rejections).
                const v = acc;
                drainMicrotasks(allocator, realm) catch return error.OutOfMemory;
                if (heap_mod.valueAsPlainObject(v)) |obj| {
                    if (obj.isPromise()) {
                        if (obj.promise_state == .fulfilled) {
                            acc = obj.promise_value;
                        } else if (obj.promise_state == .rejected) {
                            const ex = obj.promise_value;
                            f.ip = ip;
                            f.accumulator = acc;
                            committed = true;
                            if (!try unwindThrow(allocator, realm, frames, ex)) {
                                return .{ .thrown = ex };
                            }
                            continue;
                        } else {
                            // Pending — only suspendable inside
                            // an async generator. Without one
                            // (e.g. a top-level `await` outside
                            // a function), fall through and let
                            // the caller see the Promise back.
                            if (f.generator) |gen| {
                                if (gen.is_async) {
                                    // Save frame state into the gen and unwind.
                                    gen.ip = ip;
                                    gen.accumulator = Value.undefined_;
                                    gen.env = f.env;
                                    gen.this_value = f.this_value;
                                    gen.home_object = f.home_object;
                                    gen.home_function = f.home_function;
                                    gen.argc = f.argc;
                                    f.ip = ip;
                                    f.accumulator = Value.undefined_;
                                    committed = true;
                                    obj.promise_waiters.append(realm.allocator, gen) catch return error.OutOfMemory;
                                    return .{ .yielded = Value.undefined_ };
                                }
                            }
                        }
                    }
                }
                // Non-Promise: pass through unchanged.
            },

            .iter_open => {
                // §7.4.1 GetIterator. Produce an iterator object
                // for the iterable in `acc`. Three paths:
                // 1. `acc.@@iterator` is a function → call it
                // with `this = acc`, return its result.
                // 2. `acc` is array-like (has `.length`) →
                // synthesise an iterator that walks
                // `length` + numeric-index. Backwards-
                // compatible with later for-of.
                // 3. Otherwise → TypeError. Note: strings carry
                // a `length` slot and route through (2).
                const iterable = acc;
                const new_iter = openIterator(allocator, realm, iterable) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    error.NotIterable, error.Propagated => |e| {
                        const ex = if (e == error.Propagated and realm.pending_exception != null) blk: {
                            const px = realm.pending_exception.?;
                            realm.pending_exception = null;
                            break :blk px;
                        } else try makeTypeError(realm, "value is not iterable");
                        f.ip = ip;
                        f.accumulator = acc;
                        committed = true;
                        if (!try unwindThrow(allocator, realm, frames, ex)) {
                            return .{ .thrown = ex };
                        }
                        continue;
                    },
                    error.InvalidOpcode => return error.InvalidOpcode,
                };
                acc = new_iter;
            },

            .async_iter_open => {
                const iterable = acc;
                const new_iter = openAsyncIterator(allocator, realm, iterable) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    error.NotIterable, error.Propagated => |e| {
                        const ex = if (e == error.Propagated and realm.pending_exception != null) blk: {
                            const px = realm.pending_exception.?;
                            realm.pending_exception = null;
                            break :blk px;
                        } else try makeTypeError(realm, "value is not async iterable");
                        f.ip = ip;
                        f.accumulator = acc;
                        committed = true;
                        if (!try unwindThrow(allocator, realm, frames, ex)) {
                            return .{ .thrown = ex };
                        }
                        continue;
                    },
                    error.InvalidOpcode => return error.InvalidOpcode,
                };
                acc = new_iter;
            },

            .iter_step => {
                // §7.4.4 IteratorStep — step the iter in `r_iter`,
                // produce its next value (or `undefined` on done)
                // in `acc`, and stash the boolean `done` in
                // `r_done`. Reads `.done` / `.value` through the
                // accessor-aware path (§7.4.7) so poisoned-iter
                // getters fire.
                const r_iter = code[ip];
                const r_done = code[ip + 1];
                ip += 2;
                const iter_v = registers[r_iter];
                const iter_obj = heap_mod.valueAsPlainObject(iter_v) orelse {
                    acc = Value.undefined_;
                    registers[r_done] = Value.true_;
                    continue;
                };
                // Cynic-internal `__cynic_iter_done__` short-circuit:
                // once the iter has surfaced `done: true` we stop
                // calling `.next()` so subsequent pattern slots
                // bind to `undefined` without re-entering the
                // generator / iterator body.
                if (iter_obj.properties.get("__cynic_iter_done__")) |dv| {
                    if (toBoolean(dv)) {
                        acc = Value.undefined_;
                        registers[r_done] = Value.true_;
                        continue;
                    }
                }
                const next_v = intrinsics_mod.getPropertyChain(realm, iter_obj, "next") catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    else => {
                        const ex = consumePendingException(realm) orelse try makeTypeError(realm, "iterator.next read failed");
                        f.ip = ip;
                        f.accumulator = acc;
                        committed = true;
                        if (!try unwindThrow(allocator, realm, frames, ex)) {
                            return .{ .thrown = ex };
                        }
                        continue;
                    },
                };
                const next_fn = heap_mod.valueAsFunction(next_v) orelse {
                    const ex = try makeTypeError(realm, "iterator.next is not callable");
                    f.ip = ip;
                    f.accumulator = acc;
                    committed = true;
                    if (!try unwindThrow(allocator, realm, frames, ex)) {
                        return .{ .thrown = ex };
                    }
                    continue;
                };
                const outcome = callJSFunction(allocator, realm, next_fn, iter_v, &.{}) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    else => return error.InvalidOpcode,
                };
                const result_v = switch (outcome) {
                    .value, .yielded => |v| v,
                    .thrown => |ex| {
                        // Mark done so an `iter_close` after the
                        // pattern walk doesn't re-enter `.return()`
                        // — §7.4.10 step 5 swallows the second
                        // throw.
                        iter_obj.set(allocator, "__cynic_iter_done__", Value.true_) catch {};
                        f.ip = ip;
                        f.accumulator = acc;
                        committed = true;
                        if (!try unwindThrow(allocator, realm, frames, ex)) {
                            return .{ .thrown = ex };
                        }
                        continue;
                    },
                };
                if (heap_mod.valueAsPlainObject(result_v)) |result_obj| {
                    const done_v = intrinsics_mod.getPropertyChain(realm, result_obj, "done") catch |err| switch (err) {
                        error.OutOfMemory => return error.OutOfMemory,
                        else => {
                            iter_obj.set(allocator, "__cynic_iter_done__", Value.true_) catch {};
                            const ex = consumePendingException(realm) orelse try makeTypeError(realm, "iterator result .done read failed");
                            f.ip = ip;
                            f.accumulator = acc;
                            committed = true;
                            if (!try unwindThrow(allocator, realm, frames, ex)) {
                                return .{ .thrown = ex };
                            }
                            continue;
                        },
                    };
                    if (toBoolean(done_v)) {
                        iter_obj.set(allocator, "__cynic_iter_done__", Value.true_) catch return error.OutOfMemory;
                        acc = Value.undefined_;
                        registers[r_done] = Value.true_;
                        continue;
                    }
                    const value_v = intrinsics_mod.getPropertyChain(realm, result_obj, "value") catch |err| switch (err) {
                        error.OutOfMemory => return error.OutOfMemory,
                        else => {
                            iter_obj.set(allocator, "__cynic_iter_done__", Value.true_) catch {};
                            const ex = consumePendingException(realm) orelse try makeTypeError(realm, "iterator result .value read failed");
                            f.ip = ip;
                            f.accumulator = acc;
                            committed = true;
                            if (!try unwindThrow(allocator, realm, frames, ex)) {
                                return .{ .thrown = ex };
                            }
                            continue;
                        },
                    };
                    acc = value_v;
                    registers[r_done] = Value.false_;
                } else {
                    // §7.4.4 step 5 — `next()` result is not an
                    // object → TypeError. Mark done so the
                    // pattern walk's trailing `iter_close` no-ops.
                    iter_obj.set(allocator, "__cynic_iter_done__", Value.true_) catch return error.OutOfMemory;
                    const ex = try makeTypeError(realm, "iterator result is not an object");
                    f.ip = ip;
                    f.accumulator = acc;
                    committed = true;
                    if (!try unwindThrow(allocator, realm, frames, ex)) {
                        return .{ .thrown = ex };
                    }
                    continue;
                }
            },

            .for_in_open => {
                // §14.7.5.6 — snapshot the object's own + inherited
                // string keys into a fresh array iterator. `null` /
                // `undefined` produce an empty iterator.
                if (acc.isNull() or acc.isUndefined()) {
                    const empty = realm.heap.allocateObject() catch return error.OutOfMemory;
                    empty.prototype = realm.intrinsics.array_prototype;
                    empty.markAsArrayExotic(allocator) catch return error.OutOfMemory;
                    empty.set(allocator, "length", Value.fromInt32(0)) catch return error.OutOfMemory;
                    acc = openIterator(allocator, realm, heap_mod.taggedObject(empty)) catch return error.OutOfMemory;
                } else {
                    acc = openForInIterator(allocator, realm, acc) catch return error.OutOfMemory;
                }
            },

            .pop_env => {
                // §14.7.5.6 step 8 — restore the outer env after
                // a per-iteration env has served its body. The
                // popped env stays alive only through any closures
                // captured during the iteration; for the frame, we
                // walk one level up the parent chain.
                if (f.env) |cur_env| {
                    f.env = cur_env.parent;
                }
            },

            .module_load => {
                const k = readU16(code, ip);
                ip += 2;
                if (k >= local_chunk.constants.len) return error.InvalidOpcode;
                const spec_v = local_chunk.constants[k];
                if (!spec_v.isString()) return error.InvalidOpcode;
                const spec_s: *JSString = @ptrCast(@alignCast(spec_v.asString()));
                const outcome = loadModule(allocator, realm, spec_s.bytes, local_chunk.base_url) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    else => return error.InvalidOpcode,
                };
                if (outcome.threw) {
                    f.ip = ip;
                    f.accumulator = acc;
                    committed = true;
                    if (!try unwindThrow(allocator, realm, frames, outcome.value)) {
                        return .{ .thrown = outcome.value };
                    }
                    continue;
                }
                acc = outcome.value;
            },

            .dynamic_import => {
                // §13.3.10 dynamic `import(specifier)`. Specifier
                // is in `acc`. Result becomes a Promise in `acc` —
                // fulfilled with the namespace on success,
                // rejected with the TypeError on load failure.
                // Loader is synchronous in Cynic's setup; observation
                // still goes through the microtask queue via `.then`
                // / `await`, so async semantics are preserved at
                // the observation layer.
                const promise_mod = @import("builtins/promise.zig");
                if (!acc.isString()) {
                    // §13.3.10.1 step 6 calls ToString(specifier),
                    // but the failure case (Symbol / object with
                    // throwing toString) becomes a rejected
                    // Promise per "any abrupt completion → reject"
                    // (step 9). For now we reject on non-string
                    // outright; ToString refinement is a follow-up.
                    const ex = try makeTypeError(realm, "import specifier must be a string");
                    acc = try promise_mod.allocatePromiseFor(realm, null, .rejected, ex);
                } else {
                    const spec_s: *JSString = @ptrCast(@alignCast(acc.asString()));
                    const outcome = loadModule(allocator, realm, spec_s.bytes, local_chunk.base_url) catch |err| switch (err) {
                        error.OutOfMemory => return error.OutOfMemory,
                        else => return error.InvalidOpcode,
                    };
                    if (outcome.threw) {
                        acc = try promise_mod.allocatePromiseFor(realm, null, .rejected, outcome.value);
                    } else {
                        acc = try promise_mod.allocatePromiseFor(realm, null, .fulfilled, outcome.value);
                    }
                }
            },

            .module_export => {
                const k = readU16(code, ip);
                ip += 2;
                if (k >= local_chunk.constants.len) return error.InvalidOpcode;
                const name_v = local_chunk.constants[k];
                if (!name_v.isString()) return error.InvalidOpcode;
                const name_s: *JSString = @ptrCast(@alignCast(name_v.asString()));
                if (realm.current_module) |mr| {
                    mr.exports.set(realm.allocator, name_s.bytes, acc) catch return error.OutOfMemory;
                }
                // No-op outside module context (e.g. running
                // module-shaped code as a script for tests).
            },

            .lda_arguments => {
                // §10.4.4 — synthesise an array-like with numeric-
                // index entries and a `.length` slot. We don't
                // model the §10.4.4.6 mapped-vs-unmapped distinction
                // (mapped requires sloppy mode, which Cynic doesn't
                // implement); strict-mode unmapped is a plain
                // object whose [[Prototype]] is %Object.prototype%
                // (§10.4.4.7 step 5). Earlier code chained it to
                // %Array.prototype% for ergonomic
                // `Array.prototype.X.call(arguments, …)`, but
                // (a) the call form already works through
                // ToObject + indexed access, and (b) the wrong
                // chain made `arguments[N] = v` trigger Array
                // exotic auto-length-extend.
                const obj = realm.heap.allocateObject() catch return error.OutOfMemory;
                obj.prototype = realm.intrinsics.object_prototype;
                var i: u8 = 0;
                while (i < f.argc) : (i += 1) {
                    var ibuf: [16]u8 = undefined;
                    const islice = std.fmt.bufPrint(&ibuf, "{d}", .{i}) catch unreachable;
                    const owned = realm.heap.allocateString(islice) catch return error.OutOfMemory;
                    obj.set(allocator, owned.bytes, registers[i]) catch return error.OutOfMemory;
                }
                // §10.4.4.6 step 8 — `length` is `{ writable: true,
                // enumerable: false, configurable: true }`. Default
                // `set` lands at all-true, so `Object.keys(arguments)`
                // surfaced "length" as an enumerable own key.
                obj.setWithFlags(allocator, "length", Value.fromInt32(@intCast(f.argc)), .{
                    .writable = true, .enumerable = false, .configurable = true,
                }) catch return error.OutOfMemory;
                // §10.4.4.7 step 5 — strict-mode unmapped arguments
                // installs a `callee` accessor whose [[Get]] and
                // [[Set]] are both %ThrowTypeError%. Cynic is
                // strict-only, so every `arguments` object lands
                // here. The thrower function is a per-realm
                // singleton (§10.2.4); reuse it from intrinsics.
                if (realm.intrinsics.throw_type_error) |thrower| {
                    const entry = obj.accessors.getOrPut(allocator, "callee") catch return error.OutOfMemory;
                    entry.value_ptr.* = .{ .getter = thrower, .setter = thrower };
                    obj.property_flags.put(allocator, "callee", .{
                        .writable = false,
                        .enumerable = false,
                        .configurable = false,
                    }) catch return error.OutOfMemory;
                }
                acc = heap_mod.taggedObject(obj);
            },

            .rest_args_from => {
                // §15.2.4 — collect the trailing args into a real
                // Array (not an array-like). Slot `start` is the
                // first arg index past the named non-rest params.
                const start = code[ip];
                ip += 1;
                const obj = realm.heap.allocateObject() catch return error.OutOfMemory;
                obj.prototype = realm.intrinsics.array_prototype;
                obj.markAsArrayExotic(allocator) catch return error.OutOfMemory;
                var len: i32 = 0;
                if (start < f.argc) {
                    var i: u8 = start;
                    while (i < f.argc) : (i += 1) {
                        var ibuf: [16]u8 = undefined;
                        const islice = std.fmt.bufPrint(&ibuf, "{d}", .{len}) catch unreachable;
                        const owned = realm.heap.allocateString(islice) catch return error.OutOfMemory;
                        obj.set(allocator, owned.bytes, registers[i]) catch return error.OutOfMemory;
                        len += 1;
                    }
                }
                obj.set(allocator, "length", Value.fromInt32(len)) catch return error.OutOfMemory;
                acc = heap_mod.taggedObject(obj);
            },

            .def_accessor => {
                const k = readU16(code, ip);
                const r_obj = code[ip + 2];
                const is_setter = code[ip + 3] != 0;
                ip += 4;
                if (k >= local_chunk.constants.len) return error.InvalidOpcode;
                const key_v = local_chunk.constants[k];
                if (!key_v.isString()) return error.InvalidOpcode;
                const key_s: *JSString = @ptrCast(@alignCast(key_v.asString()));
                const obj = heap_mod.valueAsPlainObject(registers[r_obj]) orelse return error.InvalidOpcode;
                const fn_obj = heap_mod.valueAsFunction(acc) orelse return error.InvalidOpcode;
                const entry = obj.accessors.getOrPut(allocator, key_s.bytes) catch return error.OutOfMemory;
                if (!entry.found_existing) entry.value_ptr.* = .{};
                if (is_setter) {
                    entry.value_ptr.*.setter = fn_obj;
                } else {
                    entry.value_ptr.*.getter = fn_obj;
                }
            },

            .def_computed_accessor => {
                // Computed-key counterpart of `def_accessor` — the
                // key is the value in `r_key`, coerced via §7.1.19
                // ToPropertyKey (toPrimitive(string) for objects,
                // then computedKeyToString to format the primitive).
                // §13.2.5 PropertyDefinitionEvaluation: ComputedPropertyName.
                const r_obj = code[ip];
                const r_key = code[ip + 1];
                const is_setter = code[ip + 2] != 0;
                ip += 3;
                const key_v = switch (try coerceToPropertyKey(allocator, realm, frames, f, ip, registers[r_key])) {
                    .ok => |v| v,
                    .handled => {
                        committed = true;
                        continue;
                    },
                    .uncaught => |ex| return .{ .thrown = ex },
                };
                var key_buf: [64]u8 = undefined;
                const key_slice = computedKeyToString(key_v, &key_buf);
                const obj = heap_mod.valueAsPlainObject(registers[r_obj]) orelse return error.InvalidOpcode;
                const fn_obj = heap_mod.valueAsFunction(acc) orelse return error.InvalidOpcode;
                const owned = realm.heap.allocateString(key_slice) catch return error.OutOfMemory;
                const entry = obj.accessors.getOrPut(allocator, owned.bytes) catch return error.OutOfMemory;
                if (!entry.found_existing) entry.value_ptr.* = .{};
                if (is_setter) {
                    entry.value_ptr.*.setter = fn_obj;
                } else {
                    entry.value_ptr.*.getter = fn_obj;
                }
            },

            .set_home => {
                // §10.2.5 set [[HomeObject]] for an object-literal
                // method. acc holds the freshly-built JSFunction;
                // `r_obj` holds the enclosing object. `super` lookup
                // walks `home_object.[[Prototype]]` so this is what
                // makes `super.x()` from inside `{ method(){} }`
                // resolve against `Object.getPrototypeOf(obj)`.
                const r_obj = code[ip];
                ip += 1;
                if (heap_mod.valueAsFunction(acc)) |fn_obj| {
                    if (heap_mod.valueAsPlainObject(registers[r_obj])) |home| {
                        fn_obj.home_object = home;
                    }
                }
            },

            .set_proto_literal => {
                // §B.3.1 — only Object / Null actually mutate
                // `[[Prototype]]`; any other value is a silent no-op.
                // The computed form `{ ["__proto__"]: v }` reaches
                // `sta_property` instead, so this path is the
                // strictly-non-computed literal.
                const r_obj = code[ip];
                ip += 1;
                const obj = heap_mod.valueAsPlainObject(registers[r_obj]) orelse return error.InvalidOpcode;
                if (acc.isNull()) {
                    obj.prototype = null;
                } else if (heap_mod.valueAsPlainObject(acc)) |p| {
                    obj.prototype = p;
                }
                // else: no-op; do not throw.
            },

            .set_fn_name_from => {
                // §15.5.6.4 SetFunctionName for computed property
                // keys. Only applies to anonymous function-likes
                // (functions / classes whose .name is currently
                // empty); a named expression keeps its name.
                const r_key = code[ip];
                const prefix_kind = code[ip + 1];
                ip += 2;
                const fn_obj = heap_mod.valueAsFunction(acc) orelse continue;
                // Already named — Annex-B-style nested fix-up
                // doesn't override.
                const cur_name = fn_obj.get("name");
                if (cur_name.isString()) {
                    const cs: *JSString = @ptrCast(@alignCast(cur_name.asString()));
                    // For accessors the spec adds the prefix even
                    // when the underlying function had no name,
                    // and we always emit those with the empty
                    // template — so only the "no prefix" path
                    // honours an existing non-empty name.
                    if (cs.bytes.len != 0 and prefix_kind == 0) continue;
                }
                const prefix: []const u8 = switch (prefix_kind) {
                    1 => "get ",
                    2 => "set ",
                    else => "",
                };
                const key_v = registers[r_key];
                // §15.5.6.4 step 4 — Symbol receivers wrap the
                // description in brackets; description-less
                // symbols produce the empty string for the
                // suffix portion.
                if (heap_mod.valueAsSymbol(key_v)) |sym| {
                    const suffix: []const u8 = if (sym.description) |d| d else "";
                    const final = if (sym.description != null)
                        std.fmt.allocPrint(realm.allocator, "{s}[{s}]", .{ prefix, suffix }) catch return error.OutOfMemory
                    else
                        std.fmt.allocPrint(realm.allocator, "{s}", .{prefix}) catch return error.OutOfMemory;
                    defer realm.allocator.free(final);
                    const owned = realm.heap.allocateString(final) catch return error.OutOfMemory;
                    fn_obj.set(realm.allocator, "name", Value.fromString(owned)) catch return error.OutOfMemory;
                    continue;
                }
                var key_buf: [64]u8 = undefined;
                const key_slice = computedKeyToString(key_v, &key_buf);
                const final = std.fmt.allocPrint(realm.allocator, "{s}{s}", .{ prefix, key_slice }) catch return error.OutOfMemory;
                defer realm.allocator.free(final);
                const owned = realm.heap.allocateString(final) catch return error.OutOfMemory;
                fn_obj.set(realm.allocator, "name", Value.fromString(owned)) catch return error.OutOfMemory;
            },

            .sta_private => {
                const k = readU16(code, ip);
                const r_obj = code[ip + 2];
                ip += 3;
                if (k >= local_chunk.constants.len) return error.InvalidOpcode;
                const key_v = local_chunk.constants[k];
                if (!key_v.isString()) return error.InvalidOpcode;
                const key_s: *JSString = @ptrCast(@alignCast(key_v.asString()));
                // §15.7 static private — receiver is the class
                // constructor function. Mirror the JSObject path
                // (accessor wins, then data, then brand-check
                // failure).
                if (heap_mod.valueAsFunction(registers[r_obj])) |fn_recv| {
                    if (fn_recv.private_accessors.get(key_s.bytes)) |pa| {
                        if (pa.setter) |setter| {
                            const args_one = [_]Value{acc};
                            const outcome = try callJSFunction(allocator, realm, setter, registers[r_obj], &args_one);
                            switch (outcome) {
                                .value, .yielded => {},
                                .thrown => |ex| {
                                    f.ip = ip;
                                    f.accumulator = acc;
                                    committed = true;
                                    if (!try unwindThrow(allocator, realm, frames, ex)) {
                                        return .{ .thrown = ex };
                                    }
                                    continue;
                                },
                            }
                        } else {
                            const ex = try makeTypeError(realm, "Cannot write to private accessor with no setter");
                            f.ip = ip;
                            f.accumulator = acc;
                            committed = true;
                            if (!try unwindThrow(allocator, realm, frames, ex)) {
                                return .{ .thrown = ex };
                            }
                            continue;
                        }
                    } else if (!fn_recv.private_properties.contains(key_s.bytes)) {
                        const ex = try makeTypeError(realm, "Cannot write private field — brand check failed");
                        f.ip = ip;
                        f.accumulator = acc;
                        committed = true;
                        if (!try unwindThrow(allocator, realm, frames, ex)) {
                            return .{ .thrown = ex };
                        }
                        continue;
                    } else if (fn_recv.private_methods.contains(key_s.bytes)) {
                        // §7.3.30 PrivateSet step 4 — methods aren't writable.
                        const ex = try makeTypeError(realm, "Cannot assign to private method");
                        f.ip = ip;
                        f.accumulator = acc;
                        committed = true;
                        if (!try unwindThrow(allocator, realm, frames, ex)) {
                            return .{ .thrown = ex };
                        }
                        continue;
                    } else {
                        fn_recv.private_properties.put(allocator, key_s.bytes, acc) catch return error.OutOfMemory;
                    }
                    continue;
                }
                const recv = heap_mod.valueAsPlainObject(registers[r_obj]) orelse {
                    const ex = try makeTypeError(realm, "Cannot write private field on non-object");
                    f.ip = ip;
                    f.accumulator = acc;
                    committed = true;
                    if (!try unwindThrow(allocator, realm, frames, ex)) {
                        return .{ .thrown = ex };
                    }
                    continue;
                };
                // §15.7 — private accessor descriptors win over
                // data slots on write. A write to a read-only
                // accessor (`get #x` without `set #x`) throws
                // TypeError per §10.1.9.1 step 6.b.
                if (recv.private_accessors.get(key_s.bytes)) |pa| {
                    if (pa.setter) |setter| {
                        const args_one = [_]Value{acc};
                        const outcome = try callJSFunction(allocator, realm, setter, heap_mod.taggedObject(recv), &args_one);
                        switch (outcome) {
                            .value, .yielded => {},
                            .thrown => |ex| {
                                f.ip = ip;
                                f.accumulator = acc;
                                committed = true;
                                if (!try unwindThrow(allocator, realm, frames, ex)) {
                                    return .{ .thrown = ex };
                                }
                                continue;
                            },
                        }
                    } else {
                        const ex = try makeTypeError(realm, "Cannot write to private accessor with no setter");
                        f.ip = ip;
                        f.accumulator = acc;
                        committed = true;
                        if (!try unwindThrow(allocator, realm, frames, ex)) {
                            return .{ .thrown = ex };
                        }
                        continue;
                    }
                } else if (!recv.private_properties.contains(key_s.bytes)) {
                    const ex = try makeTypeError(realm, "Cannot write private field — brand check failed");
                    f.ip = ip;
                    f.accumulator = acc;
                    committed = true;
                    if (!try unwindThrow(allocator, realm, frames, ex)) {
                        return .{ .thrown = ex };
                    }
                    continue;
                } else if (recv.private_methods.contains(key_s.bytes)) {
                    // §7.3.30 PrivateSet step 4 — methods aren't writable.
                    const ex = try makeTypeError(realm, "Cannot assign to private method");
                    f.ip = ip;
                    f.accumulator = acc;
                    committed = true;
                    if (!try unwindThrow(allocator, realm, frames, ex)) {
                        return .{ .thrown = ex };
                    }
                    continue;
                } else {
                    recv.private_properties.put(allocator, key_s.bytes, acc) catch return error.OutOfMemory;
                }
            },

            .super_call, .super_call_forward, .super_call_spread => {
                var args: []const Value = &.{};
                var spread_args: std.ArrayListUnmanaged(Value) = .empty;
                defer spread_args.deinit(allocator);
                if (op == .super_call) {
                    const r_args = code[ip];
                    const argc = code[ip + 1];
                    ip += 2;
                    args = registers[r_args .. @as(usize, r_args) + argc];
                } else if (op == .super_call_spread) {
                    // §13.3.7 — `super(...spread)`. The runtime-
                    // built args array is in r_args_array; walk
                    // its packed elements into a fresh stack-side
                    // list to hand to the parent ctor.
                    const r_args_arr = code[ip];
                    ip += 1;
                    const arr_v = registers[r_args_arr];
                    const arr_obj = heap_mod.valueAsPlainObject(arr_v) orelse return error.InvalidOpcode;
                    if (arr_obj.is_array_exotic) {
                        // The compiler-built spread array is always
                        // dense, but route through the indexed API
                        // so the sparse path remains correct if a
                        // future site reuses this opcode.
                        const len_u32 = arr_obj.arrayLength();
                        var i: u32 = 0;
                        while (i < len_u32) : (i += 1) {
                            spread_args.append(allocator, arr_obj.getIndexed(i)) catch return error.OutOfMemory;
                        }
                    } else {
                        const len_v = arr_obj.get("length");
                        const len: i64 = if (len_v.isInt32()) len_v.asInt32() else if (len_v.isDouble()) @intFromFloat(@trunc(len_v.asDouble())) else 0;
                        var i: i64 = 0;
                        while (i < len) : (i += 1) {
                            var buf: [24]u8 = undefined;
                            const ks = std.fmt.bufPrint(&buf, "{d}", .{i}) catch unreachable;
                            spread_args.append(allocator, arr_obj.get(ks)) catch return error.OutOfMemory;
                        }
                    }
                    args = spread_args.items;
                } else {
                    // super_call_forward: replay the caller's args
                    // (compiler-synthesised default-derived ctor).
                    args = registers[0..f.argc];
                }
                const home = f.home_object orelse {
                    const ex = try makeTypeError(realm, "super used outside a method");
                    f.ip = ip;
                    f.accumulator = acc;
                    committed = true;
                    if (!try unwindThrow(allocator, realm, frames, ex)) {
                        return .{ .thrown = ex };
                    }
                    continue;
                };
                const parent_proto = home.prototype;
                const parent_ctor_v = if (parent_proto) |p| p.get("constructor") else Value.undefined_;
                const parent_fn = heap_mod.valueAsFunction(parent_ctor_v) orelse {
                    const ex = try makeTypeError(realm, "super(...) requires a constructor in the prototype chain");
                    f.ip = ip;
                    f.accumulator = acc;
                    committed = true;
                    if (!try unwindThrow(allocator, realm, frames, ex)) {
                        return .{ .thrown = ex };
                    }
                    continue;
                };
                // §13.3.7 / §10.2.1.4 — `super(...)` invokes the
                // parent constructor with `[[NewTarget]]` of the
                // CURRENT frame (i.e. the original `new` site that
                // started the derived-class chain), not the parent
                // function itself. Without this propagation, a
                // derived class's `new.target` inside its parent
                // body would read as the parent — fixtures verify
                // it stays as the original NewTarget.
                const outcome = try callJSFunctionAsSuper(allocator, realm, parent_fn, f.this_value, args, f.new_target);
                switch (outcome) {
                    .value, .yielded => |v| acc = v,
                    .thrown => |ex| {
                        f.ip = ip;
                        f.accumulator = acc;
                        committed = true;
                        if (!try unwindThrow(allocator, realm, frames, ex)) {
                            return .{ .thrown = ex };
                        }
                        continue;
                    },
                }
                // §10.2.1.4 — `super(...)` flips `[[ThisBindingStatus]]`
                // from "uninitialized" to "initialized". A subsequent
                // `return undefined` is fine; without this flag, falling
                // off the end throws ReferenceError.
                f.super_called = true;
            },

            // ── Globals ─────────────────────────────────────────────────
            .lda_global => {
                const k = readU16(code, ip);
                ip += 2;
                if (k >= local_chunk.constants.len) return error.InvalidOpcode;
                const key_v = local_chunk.constants[k];
                if (!key_v.isString()) return error.InvalidOpcode;
                const key_s: *JSString = @ptrCast(@alignCast(key_v.asString()));
                if (realm.globals.get(key_s.bytes)) |v| {
                    acc = v;
                } else {
                    const ex = try makeReferenceError(realm, key_s.bytes);
                    f.ip = ip;
                    f.accumulator = acc;
                    committed = true;
                    if (!try unwindThrow(allocator, realm, frames, ex)) {
                        return .{ .thrown = ex };
                    }
                    continue;
                }
            },
            .lda_global_or_undef => {
                // §13.5.3 step 3 — typeof of an unresolvable
                // Reference is "undefined", not a thrown
                // ReferenceError. The compiler emits this op
                // for `typeof Identifier` when `Identifier`
                // doesn't bind to any known scope slot.
                const k = readU16(code, ip);
                ip += 2;
                if (k >= local_chunk.constants.len) return error.InvalidOpcode;
                const key_v = local_chunk.constants[k];
                if (!key_v.isString()) return error.InvalidOpcode;
                const key_s: *JSString = @ptrCast(@alignCast(key_v.asString()));
                acc = realm.globals.get(key_s.bytes) orelse Value.undefined_;
            },
            .sta_global => {
                const k = readU16(code, ip);
                ip += 2;
                if (k >= local_chunk.constants.len) return error.InvalidOpcode;
                const key_v = local_chunk.constants[k];
                if (!key_v.isString()) return error.InvalidOpcode;
                const key_s: *JSString = @ptrCast(@alignCast(key_v.asString()));
                // §13.15.2 step 1.f.i — strict-mode assignment to a
                // truly-unresolvable reference throws ReferenceError
                // at PutValue. Top-level `var x` / `let x` / `const x`
                // pre-install their entries at hoist time, so by the
                // time sta_global runs for a known declaration the
                // key is present. Anything missing here is a bare
                // `x = 1` for some `x` that was never declared
                // anywhere — strict mode forbids the implicit global.
                if (!realm.globals.contains(key_s.bytes)) {
                    const ex = try makeReferenceError(realm, key_s.bytes);
                    f.ip = ip;
                    f.accumulator = acc;
                    committed = true;
                    if (!try unwindThrow(allocator, realm, frames, ex)) {
                        return .{ .thrown = ex };
                    }
                    continue;
                }
                try realm.globals.put(realm.allocator, key_s.bytes, acc);
            },
            .capture_unresolved_global => {
                // §13.15.2 step 1.a — Evaluation of the LHS of
                // an `Identifier = expr` assignment produces a
                // Reference Record with `[[Base]]: unresolvable`
                // when the identifier has no binding. Cynic
                // captures *that* state into a register here,
                // ahead of the RHS, so a side-effecting RHS
                // (e.g. `this.foo = …` populating the binding)
                // doesn't mask the unresolvable Reference at
                // PutValue (§6.2.5.5 step 6). The flag is read
                // by `sta_global_strict` after the RHS settles.
                const k = readU16(code, ip);
                ip += 2;
                const r = code[ip];
                ip += 1;
                if (k >= local_chunk.constants.len) return error.InvalidOpcode;
                const key_v = local_chunk.constants[k];
                if (!key_v.isString()) return error.InvalidOpcode;
                const key_s: *JSString = @ptrCast(@alignCast(key_v.asString()));
                registers[r] = if (realm.globals.contains(key_s.bytes))
                    Value.fromBool(false)
                else
                    Value.fromBool(true);
            },
            .sta_global_strict => {
                // §13.15.2 step 1.d — PutValue on the Reference
                // captured by `capture_unresolved_global`. If
                // the snapshot saw an unresolvable Reference,
                // §6.2.5.5 step 6 throws ReferenceError in
                // strict mode (Cynic's only mode); otherwise
                // write through to the realm globals just like
                // `sta_global`. Note the post-RHS check uses the
                // *snapshot*, not the current state — between
                // the snapshot and now the RHS may have created
                // the binding (e.g. via `this.x = …`), but the
                // Reference is still unresolvable per spec.
                const k = readU16(code, ip);
                ip += 2;
                const r = code[ip];
                ip += 1;
                if (k >= local_chunk.constants.len) return error.InvalidOpcode;
                const key_v = local_chunk.constants[k];
                if (!key_v.isString()) return error.InvalidOpcode;
                const key_s: *JSString = @ptrCast(@alignCast(key_v.asString()));
                const flag = registers[r];
                const was_unresolved = flag.isBool() and flag.asBool();
                if (was_unresolved) {
                    const ex = try makeReferenceError(realm, key_s.bytes);
                    f.ip = ip;
                    f.accumulator = acc;
                    committed = true;
                    if (!try unwindThrow(allocator, realm, frames, ex)) {
                        return .{ .thrown = ex };
                    }
                    continue;
                }
                try realm.globals.put(realm.allocator, key_s.bytes, acc);
            },

            // ── Objects / properties ────────────────────────────────────
            .make_object => {
                const obj = realm.heap.allocateObject() catch return error.OutOfMemory;
                obj.prototype = realm.intrinsics.object_prototype;
                acc = heap_mod.taggedObject(obj);
            },
            .make_array => {
                const obj = realm.heap.allocateObject() catch return error.OutOfMemory;
                obj.prototype = realm.intrinsics.array_prototype;
                obj.markAsArrayExotic(allocator) catch return error.OutOfMemory;
                // §23.1.4 — `Array.prototype.length` is
                // non-enumerable. Pre-flag the slot so for-in
                // and `Object.keys` don't surface it.
                obj.setWithFlags(allocator, "length", Value.fromInt32(0), .{
                    .writable = true,
                    .enumerable = false,
                    .configurable = false,
                }) catch return error.OutOfMemory;
                acc = heap_mod.taggedObject(obj);
            },
            .array_spread => {
                // `acc` holds the source; `r_arr` holds the target.
                // Open an iterator (§7.4.1) on the source and append
                // each yielded value to the target, updating its
                // `length`. Native fast-paths short-circuit through
                // the iterator's array-like fallback (no per-call
                // function dispatch); user-defined `@@iterator` (e.g.
                // generators, Maps, Sets) take the protocol path.
                const r_arr = code[ip];
                ip += 1;
                const target = heap_mod.valueAsPlainObject(registers[r_arr]) orelse {
                    const ex = try makeTypeError(realm, "spread target is not an array");
                    f.ip = ip;
                    f.accumulator = acc;
                    committed = true;
                    if (!try unwindThrow(allocator, realm, frames, ex)) {
                        return .{ .thrown = ex };
                    }
                    continue;
                };

                const iter = openIterator(allocator, realm, acc) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    error.InvalidOpcode => return error.InvalidOpcode,
                    error.NotIterable, error.Propagated => |e| {
                        const ex = if (e == error.Propagated and realm.pending_exception != null) blk: {
                            const px = realm.pending_exception.?;
                            realm.pending_exception = null;
                            break :blk px;
                        } else try makeTypeError(realm, "spread source is not iterable");
                        f.ip = ip;
                        f.accumulator = acc;
                        committed = true;
                        if (!try unwindThrow(allocator, realm, frames, ex)) {
                            return .{ .thrown = ex };
                        }
                        continue;
                    },
                };
                // The iterator object lives only as a Zig-stack
                // local across the per-step `next()` calls below;
                // its `next` method allocates a result object and
                // can trigger GC. Without a handle scope the iter
                // (and its `next` function pointer) get swept and
                // we read garbage on the second iteration.
                const spread_scope = realm.heap.openScope() catch return error.OutOfMemory;
                defer spread_scope.close();
                spread_scope.push(iter) catch return error.OutOfMemory;
                const iter_obj = heap_mod.valueAsPlainObject(iter) orelse return error.InvalidOpcode;
                const next_v = iter_obj.get("next");
                const next_fn = heap_mod.valueAsFunction(next_v) orelse {
                    const ex = try makeTypeError(realm, "iterator.next is not callable");
                    f.ip = ip;
                    f.accumulator = acc;
                    committed = true;
                    if (!try unwindThrow(allocator, realm, frames, ex)) {
                        return .{ .thrown = ex };
                    }
                    continue;
                };

                // Walk until done. Cap iterations to guard against
                // pathological generators.
                const target_len_v = target.get("length");
                var target_len: i64 = if (target_len_v.isInt32()) target_len_v.asInt32() else if (target_len_v.isDouble()) blk: {
                    const d = target_len_v.asDouble();
                    if (std.math.isNan(d) or std.math.isInf(d)) break :blk 0;
                    break :blk @intFromFloat(@trunc(d));
                } else 0;
                const max_iter: i64 = 1 << 24;
                var iter_count: i64 = 0;
                while (iter_count < max_iter) : (iter_count += 1) {
                    const step = callJSFunction(allocator, realm, next_fn, iter, &.{}) catch |err| switch (err) {
                        error.OutOfMemory => return error.OutOfMemory,
                        else => return error.InvalidOpcode,
                    };
                    const result_v = switch (step) {
                        .value, .yielded => |v| v,
                        .thrown => |ex| {
                            f.ip = ip;
                            f.accumulator = acc;
                            committed = true;
                            if (!try unwindThrow(allocator, realm, frames, ex)) {
                                return .{ .thrown = ex };
                            }
                            break;
                        },
                    };
                    const result_obj = heap_mod.valueAsPlainObject(result_v) orelse break;
                    // §7.4.7 IteratorComplete / IteratorValue —
                    // accessor descriptors must invoke the getter.
                    // Without this the poisoned-iterator fixtures
                    // (`spread-err-itr-value.js`) never see the
                    // throw and spin to 16M iters.
                    const done_v = intrinsics_mod.getPropertyChain(realm, result_obj, "done") catch |err| switch (err) {
                        error.OutOfMemory => return error.OutOfMemory,
                        else => {
                            const ex = realm.pending_exception orelse Value.undefined_;
                            realm.pending_exception = Value.undefined_;
                            f.ip = ip;
                            f.accumulator = acc;
                            committed = true;
                            if (!try unwindThrow(allocator, realm, frames, ex)) {
                                return .{ .thrown = ex };
                            }
                            break;
                        },
                    };
                    if (toBoolean(done_v)) break;
                    const elem = intrinsics_mod.getPropertyChain(realm, result_obj, "value") catch |err| switch (err) {
                        error.OutOfMemory => return error.OutOfMemory,
                        else => {
                            const ex = realm.pending_exception orelse Value.undefined_;
                            realm.pending_exception = Value.undefined_;
                            f.ip = ip;
                            f.accumulator = acc;
                            committed = true;
                            if (!try unwindThrow(allocator, realm, frames, ex)) {
                                return .{ .thrown = ex };
                            }
                            break;
                        },
                    };
                    // §10.4.2 — `target` is array-exotic, so the
                    // append goes straight into the packed
                    // `elements` vector. No JSString allocation
                    // per index → the pathological iterator
                    // fixtures (16M-iter `spread-err-…`) no
                    // longer balloon the heap.
                    if (target.is_array_exotic and target_len <= 0xFFFFFFFE) {
                        target.setIndexed(allocator, @intCast(target_len), elem) catch return error.OutOfMemory;
                    } else {
                        var db: [24]u8 = undefined;
                        const ds = std.fmt.bufPrint(&db, "{d}", .{target_len}) catch unreachable;
                        const owned = realm.heap.allocateString(ds) catch return error.OutOfMemory;
                        target.set(allocator, owned.bytes, elem) catch return error.OutOfMemory;
                    }
                    target_len += 1;
                }
                if (committed) continue;
                if (iter_count >= max_iter) {
                    const ex = try makeRangeError(realm, "spread source too large");
                    f.ip = ip;
                    f.accumulator = acc;
                    committed = true;
                    if (!try unwindThrow(allocator, realm, frames, ex)) {
                        return .{ .thrown = ex };
                    }
                    continue;
                }

                // §10.4.2.4 — `target` is array-exotic by the
                // time spread runs (every site that allocates an
                // array-shaped JSObject calls `markAsArrayExotic`).
                // The indexed writes above already kept length
                // in sync via `syncLengthProperty`; this final
                // assignment is a no-op, kept for parity with
                // pre-array-exotic objects (e.g. `Array.prototype`
                // itself) that still flow through this path.
                if (target.is_array_exotic) {
                    const u32_len: u32 = if (target_len < 0) 0 else if (target_len > 0xFFFFFFFE) 0xFFFFFFFE else @intCast(target_len);
                    target.setArrayLength(allocator, u32_len) catch return error.OutOfMemory;
                } else {
                    const len_v: Value = if (target_len >= std.math.minInt(i32) and target_len <= std.math.maxInt(i32))
                        Value.fromInt32(@intCast(target_len))
                    else
                        Value.fromDouble(@floatFromInt(target_len));
                    target.set(allocator, "length", len_v) catch return error.OutOfMemory;
                }
            },

            .object_spread => {
                // §13.2.5.5 / §7.3.26 CopyDataProperties for the
                // object-literal spread `{ ...src }`. Walks `src`'s
                // own enumerable string + symbol keys (the engine's
                // `__cynic_*` slots are skipped — they're internal
                // bookkeeping, not user-visible), reads each via
                // the accessor-aware path so getters fire with
                // `this = src`, and `[[Set]]`s the result into the
                // target. `null` / `undefined` source is a no-op.
                const r_obj = code[ip];
                ip += 1;
                if (acc.isNull() or acc.isUndefined()) continue;
                const target = heap_mod.valueAsPlainObject(registers[r_obj]) orelse return error.InvalidOpcode;
                const src_v = acc;
                const src_obj = heap_mod.valueAsPlainObject(src_v) orelse {
                    // Primitives box transparently. For now treat
                    // strings / numbers / booleans as having no
                    // own enumerable string keys (numeric index
                    // expansion for strings is rare in real code
                    // and trips object-rest tests; revisit later).
                    continue;
                };
                const obj_mod = @import("builtins/object.zig");
                const keys = obj_mod.ownPropertyKeysOrdered(realm, src_obj) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    else => return error.InvalidOpcode,
                };
                defer realm.allocator.free(keys);
                for (keys) |key| {
                    if (!src_obj.flagsFor(key).enumerable) continue;
                    var prop_value: Value = undefined;
                    if (lookupAccessor(src_obj, key)) |acc_pair| {
                        if (acc_pair.getter) |getter| {
                            const outcome = try callJSFunction(allocator, realm, getter, src_v, &.{});
                            switch (outcome) {
                                .value, .yielded => |v| prop_value = v,
                                .thrown => |ex| {
                                    f.ip = ip;
                                    f.accumulator = acc;
                                    committed = true;
                                    if (!try unwindThrow(allocator, realm, frames, ex)) {
                                        return .{ .thrown = ex };
                                    }
                                    break;
                                },
                            }
                        } else {
                            prop_value = Value.undefined_;
                        }
                    } else {
                        prop_value = src_obj.get(key);
                    }
                    target.set(allocator, key, prop_value) catch return error.OutOfMemory;
                }
                if (committed) continue;
            },

            .lda_property => {
                const k = readU16(code, ip);
                ip += 2;
                if (k >= local_chunk.constants.len) return error.InvalidOpcode;
                const key_v = local_chunk.constants[k];
                if (!key_v.isString()) return error.InvalidOpcode;
                const key_s: *JSString = @ptrCast(@alignCast(key_v.asString()));
                if (heap_mod.valueAsPlainObject(acc)) |obj_in| {
                    // §10.5 Proxy [[Get]] — if `obj_in` is a proxy
                    // exotic, dispatch through `handler.get` first;
                    // a missing trap falls through to default lookup
                    // on the target.
                    var obj = obj_in;
                    if (obj.proxy_target != null or obj.proxy_revoked) {
                        const r = try proxyGetTrap(allocator, realm, frames, f, ip, obj, key_s.bytes, acc);
                        switch (r) {
                            .value => |v| {
                                acc = v;
                                continue;
                            },
                            .fallthrough => |t| obj = t,
                            .handled => {
                                committed = true;
                                continue;
                            },
                            .uncaught => |ex| return .{ .thrown = ex },
                        }
                    }
                    // §10.1.8 — accessor descriptor wins over data
                    // property. Walk the prototype chain looking
                    // for an accessor first.
                    if (lookupAccessor(obj, key_s.bytes)) |acc_pair| {
                        if (acc_pair.getter) |getter| {
                            const recv = acc;
                            const outcome = try callJSFunction(allocator, realm, getter, recv, &.{});
                            switch (outcome) {
                                .value, .yielded => |v| acc = v,
                                .thrown => |ex| {
                                    f.ip = ip;
                                    f.accumulator = acc;
                                    committed = true;
                                    if (!try unwindThrow(allocator, realm, frames, ex)) {
                                        return .{ .thrown = ex };
                                    }
                                    continue;
                                },
                            }
                        } else {
                            acc = Value.undefined_;
                        }
                    } else {
                        acc = obj.get(key_s.bytes);
                    }
                } else if (heap_mod.valueAsFunction(acc)) |fn_obj| {
                    // §10.1.8.1 OrdinaryGet step 4 — accessor
                    // descriptor wins over data. Walk the full
                    // function `[[Prototype]]` chain (own →
                    // `static_parent` → `proto`) so the poison-pill
                    // `caller` / `arguments` accessors installed on
                    // %Function.prototype% (§10.2.4) fire when user
                    // code reads `fn.caller` / `fn.arguments`.
                    if (lookupFunctionAccessor(fn_obj, key_s.bytes)) |acc_pair| {
                        if (acc_pair.getter) |getter| {
                            const recv = acc;
                            const outcome = try callJSFunction(allocator, realm, getter, recv, &.{});
                            switch (outcome) {
                                .value, .yielded => |v| acc = v,
                                .thrown => |ex| {
                                    f.ip = ip;
                                    f.accumulator = acc;
                                    committed = true;
                                    if (!try unwindThrow(allocator, realm, frames, ex)) {
                                        return .{ .thrown = ex };
                                    }
                                    continue;
                                },
                            }
                        } else {
                            acc = Value.undefined_;
                        }
                    } else {
                        acc = fn_obj.get(key_s.bytes);
                    }
                } else if (acc.isString()) {
                    // §6.1.4.4 — string primitives expose.length,
                    // numeric-index char access, and inherited
                    // `String.prototype` methods (`.charAt` etc.)
                    // looked up through the realm's intrinsic.
                    const recv: *JSString = @ptrCast(@alignCast(acc.asString()));
                    if (std.mem.eql(u8, key_s.bytes, "length")) {
                        acc = Value.fromInt32(@intCast(recv.bytes.len));
                    } else if (realm.intrinsics.string_prototype) |sp| {
                        acc = sp.get(key_s.bytes);
                    } else acc = Value.undefined_;
                } else if (acc.isInt32() or acc.isDouble()) {
                    // §7.1.1 ToObject(Number) — primitive number
                    // methods (`.toFixed`, `.toString`) resolve via
                    // %Number.prototype%.
                    if (heap_mod.valueAsFunction(realm.globals.get("Number") orelse Value.undefined_)) |num_ctor| {
                        if (num_ctor.prototype) |np| {
                            acc = np.get(key_s.bytes);
                        } else acc = Value.undefined_;
                    } else acc = Value.undefined_;
                } else if (acc.isBool()) {
                    if (heap_mod.valueAsFunction(realm.globals.get("Boolean") orelse Value.undefined_)) |bool_ctor| {
                        if (bool_ctor.prototype) |bp| {
                            acc = bp.get(key_s.bytes);
                        } else acc = Value.undefined_;
                    } else acc = Value.undefined_;
                } else if (heap_mod.isBigInt(acc)) {
                    if (heap_mod.valueAsFunction(realm.globals.get("BigInt") orelse Value.undefined_)) |bi_ctor| {
                        if (bi_ctor.prototype) |bp| {
                            acc = bp.get(key_s.bytes);
                        } else acc = Value.undefined_;
                    } else acc = Value.undefined_;
                } else if (heap_mod.isSymbol(acc)) {
                    // §7.1.18 ToObject(Symbol) — primitive
                    // symbol method lookups resolve via
                    // %Symbol.prototype%, with `this` reading
                    // the symbol primitive directly.
                    if (heap_mod.valueAsFunction(realm.globals.get("Symbol") orelse Value.undefined_)) |sym_ctor| {
                        if (sym_ctor.prototype) |sp| {
                            // Accessor descriptors (e.g. `description`)
                            // win over property-bag entries.
                            if (lookupAccessor(sp, key_s.bytes)) |acc_pair| {
                                if (acc_pair.getter) |getter| {
                                    const recv = acc;
                                    const outcome = try callJSFunction(allocator, realm, getter, recv, &.{});
                                    switch (outcome) {
                                        .value, .yielded => |v| acc = v,
                                        .thrown => |ex| {
                                            f.ip = ip;
                                            f.accumulator = acc;
                                            committed = true;
                                            if (!try unwindThrow(allocator, realm, frames, ex)) {
                                                return .{ .thrown = ex };
                                            }
                                            continue;
                                        },
                                    }
                                } else {
                                    acc = Value.undefined_;
                                }
                            } else {
                                acc = sp.get(key_s.bytes);
                            }
                        } else acc = Value.undefined_;
                    } else acc = Value.undefined_;
                } else {
                    const ex = try makeTypeError(realm, "Cannot read properties of non-object");
                    f.ip = ip;
                    f.accumulator = acc;
                    committed = true;
                    if (!try unwindThrow(allocator, realm, frames, ex)) {
                        return .{ .thrown = ex };
                    }
                    continue;
                }
            },
            .sta_property => {
                const k = readU16(code, ip);
                const r_obj = code[ip + 2];
                ip += 3;
                if (k >= local_chunk.constants.len) return error.InvalidOpcode;
                const key_v = local_chunk.constants[k];
                if (!key_v.isString()) return error.InvalidOpcode;
                const key_s: *JSString = @ptrCast(@alignCast(key_v.asString()));
                const recv = registers[r_obj];
                {
                    const set_outcome = try strictSetProperty(allocator, realm, frames, f, ip, recv, key_s.bytes, acc);
                    switch (set_outcome) {
                        .ok => {},
                        .handled => {
                            committed = true;
                            continue;
                        },
                        .uncaught => |ex| return .{ .thrown = ex },
                    }
                }
            },
            .lda_computed => {
                const r_obj = code[ip];
                ip += 1;
                const recv = registers[r_obj];
                // §13.3.4.1 EvaluatePropertyAccessWithExpressionKey
                // step 5 — RequireObjectCoercible(baseValue) BEFORE
                // ToPropertyKey, so `null[obj]` throws TypeError
                // even when `obj.toString` would throw something
                // else.
                if (recv.isNull() or recv.isUndefined()) {
                    const ex = try makeTypeError(realm, "Cannot read property of null or undefined");
                    f.ip = ip;
                    f.accumulator = acc;
                    committed = true;
                    if (!try unwindThrow(allocator, realm, frames, ex)) {
                        return .{ .thrown = ex };
                    }
                    continue;
                }
                // §7.1.19 ToPropertyKey — for object keys (e.g.
                // `obj[arr]`), run ToPrimitive(string) so user-
                // defined `toString` / `valueOf` / `[@@toPrimitive]`
                // hooks fire before we string-format.
                const key_v = switch (try coerceToPropertyKey(allocator, realm, frames, f, ip, acc)) {
                    .ok => |v| v,
                    .handled => {
                        committed = true;
                        continue;
                    },
                    .uncaught => |ex| return .{ .thrown = ex },
                };
                var key_buf: [64]u8 = undefined;
                const key_slice = computedKeyToString(key_v, &key_buf);
                if (heap_mod.valueAsPlainObject(recv)) |obj_in| {
                    var obj = obj_in;
                    // §10.5 Proxy [[Get]] — handler trap dispatch.
                    if (obj.proxy_target != null or obj.proxy_revoked) {
                        const r = try proxyGetTrap(allocator, realm, frames, f, ip, obj, key_slice, recv);
                        switch (r) {
                            .value => |v| {
                                acc = v;
                                continue;
                            },
                            .fallthrough => |t| obj = t,
                            .handled => {
                                committed = true;
                                continue;
                            },
                            .uncaught => |ex| return .{ .thrown = ex },
                        }
                    }
                    // §23.2.4 IntegerIndex — typed-array
                    // numeric index access reads from the
                    // backing buffer. For length-tracking views
                    // over a resizable ArrayBuffer the live length
                    // is recomputed against the (possibly grown
                    // or shrunk) buffer; a fixed-length view past
                    // the current buffer end reports undefined.
                    if (obj.typed_view) |tv| {
                        if (std.fmt.parseInt(usize, key_slice, 10)) |idx| {
                            if (tv.viewed.array_buffer) |buf| {
                                const elem_size = tv.kind.elementSize();
                                const live_len: usize = if (tv.length_tracking) blk: {
                                    if (tv.byte_offset > buf.len) break :blk 0;
                                    break :blk (buf.len - tv.byte_offset) / elem_size;
                                } else blk: {
                                    if (tv.byte_offset + tv.length * elem_size > buf.len) break :blk 0;
                                    break :blk tv.length;
                                };
                                if (idx < live_len) {
                                    const byte_pos = tv.byte_offset + idx * elem_size;
                                    if (byte_pos + elem_size <= buf.len) {
                                        acc = intrinsics_mod.readTypedElement(realm, buf, tv.kind, byte_pos);
                                        continue;
                                    }
                                }
                            }
                            acc = Value.undefined_;
                            continue;
                        } else |_| {}
                    }
                    // §10.1.8 [[Get]] — accessor wins over data.
                    // Mirror the `lda_property` handling so
                    // `obj[expr]` and `obj.x` behave identically
                    // when `x` resolves to a getter on the chain.
                    if (lookupAccessor(obj, key_slice)) |acc_pair| {
                        if (acc_pair.getter) |getter| {
                            const outcome = try callJSFunction(allocator, realm, getter, recv, &.{});
                            switch (outcome) {
                                .value, .yielded => |v| acc = v,
                                .thrown => |ex| {
                                    f.ip = ip;
                                    f.accumulator = acc;
                                    committed = true;
                                    if (!try unwindThrow(allocator, realm, frames, ex)) {
                                        return .{ .thrown = ex };
                                    }
                                    continue;
                                },
                            }
                        } else {
                            acc = Value.undefined_;
                        }
                        continue;
                    }
                    acc = obj.get(key_slice);
                } else if (heap_mod.valueAsFunction(recv)) |fn_obj| {
                    // §10.1.8.1 OrdinaryGet — accessor descriptor
                    // wins. Walk the function `[[Prototype]]` chain
                    // so inherited accessors (the %Function.prototype%
                    // `caller` / `arguments` poison pills, §10.2.4)
                    // fire.
                    if (lookupFunctionAccessor(fn_obj, key_slice)) |acc_pair| {
                        if (acc_pair.getter) |getter| {
                            const outcome = try callJSFunction(allocator, realm, getter, recv, &.{});
                            switch (outcome) {
                                .value, .yielded => |v| acc = v,
                                .thrown => |ex| {
                                    f.ip = ip;
                                    f.accumulator = acc;
                                    committed = true;
                                    if (!try unwindThrow(allocator, realm, frames, ex)) {
                                        return .{ .thrown = ex };
                                    }
                                    continue;
                                },
                            }
                        } else {
                            acc = Value.undefined_;
                        }
                    } else {
                        acc = fn_obj.get(key_slice);
                    }
                } else if (recv.isString()) {
                    // §6.1.4.4 — string primitives expose.length,
                    // numeric-index character access, and inherited
                    // String.prototype methods.
                    const s: *JSString = @ptrCast(@alignCast(recv.asString()));
                    if (std.mem.eql(u8, key_slice, "length")) {
                        acc = Value.fromInt32(@intCast(s.bytes.len));
                    } else if (std.fmt.parseInt(usize, key_slice, 10)) |idx| {
                        if (idx < s.bytes.len) {
                            const ch = s.bytes[idx .. idx + 1];
                            const ns = realm.heap.allocateString(ch) catch return error.OutOfMemory;
                            acc = Value.fromString(ns);
                        } else {
                            acc = Value.undefined_;
                        }
                    } else |_| {
                        if (realm.intrinsics.string_prototype) |sp| {
                            acc = sp.get(key_slice);
                        } else acc = Value.undefined_;
                    }
                } else {
                    // §13.3.4 — `boolean[key]` / `number[key]` /
                    // `bigint[key]` / `symbol[key]` ToObject-box the
                    // receiver, so property reads find the inherited
                    // prototype methods. Walk straight to the boxed
                    // proto chain without materialising a wrapper.
                    const proto_opt: ?*JSObject = intrinsics_mod.lookupPrimitivePrototype(realm, recv);
                    if (proto_opt) |proto| {
                        acc = proto.get(key_slice);
                    } else {
                        const ex = try makeTypeError(realm, "Cannot read properties of non-object");
                        f.ip = ip;
                        f.accumulator = acc;
                        committed = true;
                        if (!try unwindThrow(allocator, realm, frames, ex)) {
                            return .{ .thrown = ex };
                        }
                        continue;
                    }
                }
            },
            .sta_computed => {
                const r_obj = code[ip];
                const r_key = code[ip + 1];
                ip += 2;
                const recv = registers[r_obj];
                // §7.1.19 ToPropertyKey — object keys go through
                // ToPrimitive(string) before stringification.
                const key_v = switch (try coerceToPropertyKey(allocator, realm, frames, f, ip, registers[r_key])) {
                    .ok => |v| v,
                    .handled => {
                        committed = true;
                        continue;
                    },
                    .uncaught => |ex| return .{ .thrown = ex },
                };
                var key_buf: [64]u8 = undefined;
                const key_slice = computedKeyToString(key_v, &key_buf);
                // TypedArray numeric-index write — bypass the
                // ordinary [[Set]] machinery; §10.4.5.5
                // [[Set]] / IntegerIndexedElementSet writes
                // straight to the backing buffer after the
                // mandatory type conversion of `value`.
                if (heap_mod.valueAsPlainObject(recv)) |obj| {
                    if (obj.typed_view) |tv| {
                        if (std.fmt.parseInt(usize, key_slice, 10)) |idx| {
                            // §10.4.5.13 IntegerIndexedElementSet step 1-2 —
                            // type coercion runs BEFORE the bounds /
                            // detached check. A BigInt typed array
                            // calls ToBigInt(value); every other kind
                            // calls ToNumber(value). Either coercion
                            // can throw (Symbol → TypeError; undefined
                            // → TypeError for BigInt; user valueOf), so
                            // it must surface before the silent drop on
                            // an out-of-bounds index.
                            const coerce_outcome: union(enum) { value: Value, thrown: Value } = if (tv.kind.isBigInt()) blk: {
                                const r = @import("builtins/bigint.zig").toBigIntValue(realm, acc) catch |err| switch (err) {
                                    error.OutOfMemory => return error.OutOfMemory,
                                    else => {
                                        const ex = consumePendingException(realm) orelse try makeTypeError(realm, "TypedArray element type-coercion failed");
                                        break :blk .{ .thrown = ex };
                                    },
                                };
                                break :blk .{ .value = r };
                            } else blk: {
                                const r = intrinsics_mod.toNumber(realm, acc) catch |err| switch (err) {
                                    error.OutOfMemory => return error.OutOfMemory,
                                    error.NativeThrew => {
                                        const ex = consumePendingException(realm) orelse try makeTypeError(realm, "TypedArray element type-coercion failed");
                                        break :blk .{ .thrown = ex };
                                    },
                                };
                                break :blk .{ .value = r };
                            };
                            const coerced: Value = switch (coerce_outcome) {
                                .value => |v| v,
                                .thrown => |ex| {
                                    f.ip = ip;
                                    f.accumulator = acc;
                                    committed = true;
                                    if (!try unwindThrow(allocator, realm, frames, ex)) {
                                        return .{ .thrown = ex };
                                    }
                                    continue;
                                },
                            };
                            // §10.4.5.16 IsValidIntegerIndex —
                            // length-tracking views over a
                            // resizable buffer use the live length;
                            // out-of-bounds writes are silently
                            // dropped per spec (after the mandatory
                            // ToNumber/ToBigInt above).
                            if (tv.viewed.array_buffer) |buf| {
                                const elem_size = tv.kind.elementSize();
                                const live_len: usize = if (tv.length_tracking) blk: {
                                    if (tv.byte_offset > buf.len) break :blk 0;
                                    break :blk (buf.len - tv.byte_offset) / elem_size;
                                } else blk: {
                                    if (tv.byte_offset + tv.length * elem_size > buf.len) break :blk 0;
                                    break :blk tv.length;
                                };
                                if (idx < live_len) {
                                    const byte_pos = tv.byte_offset + idx * elem_size;
                                    if (byte_pos + elem_size <= buf.len) {
                                        intrinsics_mod.writeTypedElement(buf, tv.kind, byte_pos, coerced);
                                    }
                                }
                            }
                            continue;
                        } else |_| {}
                        // §10.4.5.5 [[Set]] step 2.b — `CanonicalNumericIndexString`
                        // covers more than non-negative integers: "1.1", "-0",
                        // "-1", "NaN", "Infinity" all map to numbers. Those
                        // route to `IntegerIndexedElementSet`, which performs
                        // the ToNumber/ToBigInt coercion (observable
                        // `valueOf` side-effects) and then silently drops the
                        // store because `IsValidIntegerIndex` returns false.
                        // [[Set]] still returns `true`, so don't fall through
                        // to OrdinarySet (which would store a sticky property).
                        if (isCanonicalNumericIndexString(key_slice)) {
                            if (tv.kind.isBigInt()) {
                                _ = @import("builtins/bigint.zig").toBigIntValue(realm, acc) catch |err| switch (err) {
                                    error.OutOfMemory => return error.OutOfMemory,
                                    else => {
                                        const ex = consumePendingException(realm) orelse try makeTypeError(realm, "TypedArray element type-coercion failed");
                                        f.ip = ip;
                                        f.accumulator = acc;
                                        committed = true;
                                        if (!try unwindThrow(allocator, realm, frames, ex)) {
                                            return .{ .thrown = ex };
                                        }
                                        continue;
                                    },
                                };
                            } else {
                                _ = intrinsics_mod.toNumber(realm, acc) catch |err| switch (err) {
                                    error.OutOfMemory => return error.OutOfMemory,
                                    error.NativeThrew => {
                                        const ex = consumePendingException(realm) orelse try makeTypeError(realm, "TypedArray element type-coercion failed");
                                        f.ip = ip;
                                        f.accumulator = acc;
                                        committed = true;
                                        if (!try unwindThrow(allocator, realm, frames, ex)) {
                                            return .{ .thrown = ex };
                                        }
                                        continue;
                                    },
                                };
                            }
                            continue;
                        }
                    }
                }
                // Allocate a heap-owned copy of the key — the
                // scratch buffer is reused on every iteration.
                // Anchor the JSString to the receiver so GC keeps
                // the key's backing memory alive (the property
                // map only stores the slice).
                const owned = realm.heap.allocateString(key_slice) catch return error.OutOfMemory;
                {
                    const set_outcome = try strictSetPropertyAnchored(allocator, realm, frames, f, ip, recv, owned.bytes, owned, acc);
                    switch (set_outcome) {
                        .ok => {},
                        .handled => {
                            committed = true;
                            continue;
                        },
                        .uncaught => |ex| return .{ .thrown = ex },
                    }
                }
            },
            .del_named_property => {
                const k = readU16(code, ip);
                const r_obj = code[ip + 2];
                ip += 3;
                if (k >= local_chunk.constants.len) return error.InvalidOpcode;
                const key_v = local_chunk.constants[k];
                if (!key_v.isString()) return error.InvalidOpcode;
                const key_s: *JSString = @ptrCast(@alignCast(key_v.asString()));
                const recv = registers[r_obj];
                // §10.5.10 Proxy [[Delete]] dispatch.
                if (heap_mod.valueAsPlainObject(recv)) |obj_in| {
                    if (obj_in.proxy_target != null or obj_in.proxy_revoked) {
                        const r = try proxyDeleteTrap(allocator, realm, frames, f, ip, obj_in, key_s.bytes);
                        switch (r) {
                            .value => |v| {
                                acc = v;
                                continue;
                            },
                            .fallthrough => |t| {
                                const outcome = deleteOwnProperty(realm, heap_mod.taggedObject(t), key_s.bytes);
                                switch (outcome) {
                                    .ok => |b| acc = Value.fromBool(b),
                                    .throw_typeerror => |msg| {
                                        const ex = try makeTypeError(realm, msg);
                                        f.ip = ip;
                                        f.accumulator = acc;
                                        committed = true;
                                        if (!try unwindThrow(allocator, realm, frames, ex)) {
                                            return .{ .thrown = ex };
                                        }
                                        continue;
                                    },
                                }
                                continue;
                            },
                            .handled => {
                                committed = true;
                                continue;
                            },
                            .uncaught => |ex| return .{ .thrown = ex },
                        }
                    }
                }
                const outcome = deleteOwnProperty(realm, recv, key_s.bytes);
                switch (outcome) {
                    .ok => |b| acc = Value.fromBool(b),
                    .throw_typeerror => |msg| {
                        const ex = try makeTypeError(realm, msg);
                        f.ip = ip;
                        f.accumulator = acc;
                        committed = true;
                        if (!try unwindThrow(allocator, realm, frames, ex)) {
                            return .{ .thrown = ex };
                        }
                        continue;
                    },
                }
            },
            .del_computed_property => {
                const r_obj = code[ip];
                const r_key = code[ip + 1];
                ip += 2;
                const recv = registers[r_obj];
                // §7.1.19 ToPropertyKey for the bracket key.
                const key_v = switch (try coerceToPropertyKey(allocator, realm, frames, f, ip, registers[r_key])) {
                    .ok => |v| v,
                    .handled => {
                        committed = true;
                        continue;
                    },
                    .uncaught => |ex| return .{ .thrown = ex },
                };
                var key_buf: [64]u8 = undefined;
                const key_slice = computedKeyToString(key_v, &key_buf);
                if (heap_mod.valueAsPlainObject(recv)) |obj_in| {
                    if (obj_in.proxy_target != null or obj_in.proxy_revoked) {
                        const r = try proxyDeleteTrap(allocator, realm, frames, f, ip, obj_in, key_slice);
                        switch (r) {
                            .value => |v| {
                                acc = v;
                                continue;
                            },
                            .fallthrough => |t| {
                                const outcome = deleteOwnProperty(realm, heap_mod.taggedObject(t), key_slice);
                                switch (outcome) {
                                    .ok => |b| acc = Value.fromBool(b),
                                    .throw_typeerror => |msg| {
                                        const ex = try makeTypeError(realm, msg);
                                        f.ip = ip;
                                        f.accumulator = acc;
                                        committed = true;
                                        if (!try unwindThrow(allocator, realm, frames, ex)) {
                                            return .{ .thrown = ex };
                                        }
                                        continue;
                                    },
                                }
                                continue;
                            },
                            .handled => {
                                committed = true;
                                continue;
                            },
                            .uncaught => |ex| return .{ .thrown = ex },
                        }
                    }
                }
                const outcome = deleteOwnProperty(realm, recv, key_slice);
                switch (outcome) {
                    .ok => |b| acc = Value.fromBool(b),
                    .throw_typeerror => |msg| {
                        const ex = try makeTypeError(realm, msg);
                        f.ip = ip;
                        f.accumulator = acc;
                        committed = true;
                        if (!try unwindThrow(allocator, realm, frames, ex)) {
                            return .{ .thrown = ex };
                        }
                        continue;
                    },
                }
            },

            // ── Environments / closures ─────────────────────────────────
            .make_environment => {
                const slot_count = code[ip];
                ip += 1;
                const env = realm.heap.allocateEnvironment(f.env, slot_count) catch return error.OutOfMemory;
                f.env = env;
            },
            .lda_env => {
                const depth = code[ip];
                const slot = code[ip + 1];
                ip += 2;
                var env: ?*Environment = f.env;
                var d = depth;
                while (d > 0) : (d -= 1) {
                    env = if (env) |e| e.parent else null;
                }
                if (env == null or slot >= env.?.slots.len) return error.InvalidOpcode;
                acc = env.?.slots[slot];
            },
            .sta_env => {
                const depth = code[ip];
                const slot = code[ip + 1];
                ip += 2;
                var env: ?*Environment = f.env;
                var d = depth;
                while (d > 0) : (d -= 1) {
                    env = if (env) |e| e.parent else null;
                }
                if (env == null or slot >= env.?.slots.len) return error.InvalidOpcode;
                env.?.slots[slot] = acc;
            },

            // ── Exceptions ──────────────────────────────────────────────
            .throw_ => {
                f.ip = ip;
                f.accumulator = acc;
                committed = true;
                if (!try unwindThrow(allocator, realm, frames, acc)) {
                    return .{ .thrown = acc };
                }
            },
            .throw_if_hole => {
                if (acc.isHole()) {
                    const ex = try makeReferenceError(realm, "Cannot access binding before initialisation");
                    f.ip = ip;
                    f.accumulator = acc;
                    committed = true;
                    if (!try unwindThrow(allocator, realm, frames, ex)) {
                        return .{ .thrown = ex };
                    }
                }
            },
            .require_object_coercible => {
                if (acc.isNull() or acc.isUndefined()) {
                    const ex = try makeTypeError(realm, "Cannot destructure null or undefined");
                    f.ip = ip;
                    f.accumulator = acc;
                    committed = true;
                    if (!try unwindThrow(allocator, realm, frames, ex)) {
                        return .{ .thrown = ex };
                    }
                }
            },

            .to_property_key => {
                // §7.1.19 ToPropertyKey. Primitives that are
                // already a valid PropertyKey (string / symbol)
                // short-circuit; numbers / bigints / booleans /
                // null / undefined go through ToPrimitive(string)
                // then ToString. The output is a string or symbol
                // value in acc.
                if (acc.isString() or heap_mod.valueAsSymbol(acc) != null) {
                    // already a property key
                } else {
                    const prim_outcome = try coerceToPropertyKey(allocator, realm, frames, f, ip, acc);
                    switch (prim_outcome) {
                        .ok => |v| acc = v,
                        .handled => {
                            committed = true;
                            continue;
                        },
                        .uncaught => |ex| return .{ .thrown = ex },
                    }
                }
            },

            .return_ => {
                // Pop the current frame, leaving its accumulator as
                // the caller's accumulator. If we just popped the
                // last frame, we're done with the program.
                //
                // Constructor frames (entered via `new`): §13.3.5.1.1
                // ConstructResult — if the body returned an object,
                // that wins; otherwise the freshly-allocated `this`
                // does. Non-constructor frames return `acc` verbatim.
                var ret = acc;
                if (f.is_construct) {
                    const returned_object =
                        heap_mod.valueAsPlainObject(acc) != null or
                        heap_mod.valueAsFunction(acc) != null;
                    if (!returned_object) {
                        // §10.2.1.4 step 14 — a derived
                        // constructor MUST return either an
                        // Object or undefined. Returning a
                        // primitive (number / string / null /
                        // bool / symbol / bigint) is a
                        // TypeError. Base constructors fall back
                        // to `this` for non-Object returns.
                        if (f.is_derived_ctor and !acc.isUndefined()) {
                            const ex = try makeTypeError(realm, "Derived constructor must return an Object or undefined");
                            f.ip = ip;
                            f.accumulator = acc;
                            committed = true;
                            if (!try unwindThrow(allocator, realm, frames, ex)) {
                                return .{ .thrown = ex };
                            }
                            continue;
                        }
                        // §10.2.1.4 step 5 — derived ctor falling
                        // off the end (or `return;`) requires that
                        // `super(...)` has run. Otherwise `this` is
                        // uninitialized and a ReferenceError fires.
                        if (f.is_derived_ctor and acc.isUndefined() and !f.super_called) {
                            const ex = try makeReferenceError(realm, "Must call super constructor in derived class before returning from derived constructor");
                            f.ip = ip;
                            f.accumulator = acc;
                            committed = true;
                            if (!try unwindThrow(allocator, realm, frames, ex)) {
                                return .{ .thrown = ex };
                            }
                            continue;
                        }
                        ret = f.this_value;
                    }
                }
                // §27.7 AsyncFunctionStart — an async function's
                // normal completion fulfils the Promise it
                // returns. A user-level `return v` inside an
                // async body becomes `Promise.resolve(v)` to the
                // caller. If `v` is itself a Promise we leave it
                // — the callback chain will handle the unwrap.
                if (f.wrap_return_in_promise) {
                    const already_promise =
                        if (heap_mod.valueAsPlainObject(ret)) |po| po.isPromise() else false;
                    if (!already_promise) {
                        ret = wrapInPromise(realm, true, ret) catch return error.OutOfMemory;
                    }
                }
                if (f.owns_registers) allocator.free(registers);
                _ = frames.pop();
                committed = true;
                if (frames.items.len == 0) {
                    return .{ .value = ret };
                }
                frames.items[frames.items.len - 1].accumulator = ret;
            },
        }
    }
    unreachable;
}

/// Unwind `frames` looking for a handler that covers the
/// current top frame's `ip`. Pops frames whose chunk has no
/// matching handler. Returns `true` once a handler is found and
/// the top frame is positioned at the handler's entry; returns
/// `false` if every frame is exhausted (the throw is uncaught,
/// the host gets `.thrown`).
///
/// Caller has already committed the current frame's `ip` and
/// `accumulator` before calling.
fn unwindThrow(
    allocator: std.mem.Allocator,
    realm: *Realm,
    frames: *std.ArrayListUnmanaged(CallFrame),
    exception: Value,
) RunError!bool {
    const current_ex = exception;
    while (frames.items.len > 0) {
        const frame = &frames.items[frames.items.len - 1];
        for (frame.chunk.handlers) |h| {
            if (frame.ip > h.start_pc and frame.ip <= h.end_pc) {
                frame.ip = h.handler_pc;
                if (h.catch_register) |slot| {
                    // catch param lives in the current
                    // function's env slot (the compiler stored
                    // its env_slot in `catch_register`). Always
                    // depth=0 because the catch scope is in the
                    // same function as the try.
                    if (frame.env) |env| {
                        if (slot < env.slots.len) env.slots[slot] = current_ex;
                    }
                    frame.accumulator = Value.undefined_;
                } else {
                    frame.accumulator = current_ex;
                }
                return true;
            }
        }
        // No handler in this frame. If this is an async-wrapped
        // frame, the throw becomes the rejection value of the
        // Promise we hand back — never escapes the function.
        if (frame.wrap_return_in_promise) {
            const rejected = wrapInPromise(realm, false, current_ex) catch return error.OutOfMemory;
            if (frame.owns_registers) allocator.free(frame.registers);
            _ = frames.pop();
            if (frames.items.len == 0) {
                // Top-level async (rare). The throw was
                // converted to a rejected Promise; signal the
                // outer driver via pending_exception cleared
                // and surface it as a normal completion.
                realm.pending_exception = rejected;
                return false;
            }
            frames.items[frames.items.len - 1].accumulator = rejected;
            return true;
        }
        if (frame.owns_registers) allocator.free(frame.registers);
        _ = frames.pop();
    }
    return false;
}

/// Read and clear `realm.pending_exception`. Used by every
/// native dispatch site after a callback returns
/// `error.NativeThrew`: if the native populated the slot with a
/// specific JS value, propagate that; otherwise the dispatcher
/// synthesises a generic TypeError. Lets natives throw real
/// `RangeError("…")` / `TypeError("…")` instances with full
/// `.message` and `.constructor` identity.
pub fn consumePendingException(realm: *Realm) ?Value {
    const v = realm.pending_exception;
    realm.pending_exception = null;
    return v;
}

/// Walk `obj` and its prototype chain looking for an accessor
/// (getter/setter) descriptor for `key`. Returns the
/// `Accessor` if found, else null. §10.1.8 / §10.1.9.
///
/// §10.1.8.1 OrdinaryGet — an own *data* property on a level
/// shadows any inherited accessor further up the chain. So at
/// each cursor, an own accessor wins, an own data short-circuits
/// to null (caller falls through to the data-lookup path), and
/// only a complete miss continues up.
pub fn lookupAccessor(obj: *JSObject, key: []const u8) ?@import("object.zig").Accessor {
    var cursor: ?*JSObject = obj;
    while (cursor) |c| : (cursor = c.prototype) {
        if (c.accessors.get(key)) |a| return a;
        if (c.hasOwn(key)) return null;
    }
    return null;
}

/// §10.1.8.1 OrdinaryGet — locate an accessor descriptor for `key`
/// starting at `fn_obj`, walking the function's full prototype chain
/// (own → `static_parent` → `proto`). An own *data* property on the
/// receiver shadows any inherited accessor (step 1 returns that own
/// descriptor, step 2 short-circuits the parent walk), so this
/// returns `null` once we've confirmed the key is owned by the
/// receiver as plain data — the caller will then fall through to the
/// regular data-lookup path.
pub fn lookupFunctionAccessor(fn_obj: *JSFunction, key: []const u8) ?@import("object.zig").Accessor {
    if (fn_obj.accessors.get(key)) |a| return a;
    // Own data (or the dedicated `prototype` slot) shadows any
    // inherited accessor — `hasOwn` covers all three storage spots
    // (`properties`, `accessors`, the typed `prototype` field).
    if (fn_obj.hasOwn(key)) return null;
    var sp: ?*JSFunction = fn_obj.static_parent;
    while (sp) |p| : (sp = p.static_parent) {
        if (p.accessors.get(key)) |a| return a;
        if (p.hasOwn(key)) return null;
    }
    if (fn_obj.proto) |proto| {
        return lookupAccessor(proto, key);
    }
    return null;
}

/// Format an arbitrary finite double into the scratch buffer
/// without overflowing it. `{d}` on a huge magnitude (e.g.
/// 1.79e308) writes the full decimal expansion (~310 chars) and
/// blows past a 64-byte buffer. §6.1.6.1.20 NumberToString
/// switches to exponential notation past 10^21; we mirror that
/// (cheaply) by using `{e}` when the magnitude is out of the
/// safe range.
pub fn formatDoubleSafe(scratch: *[64]u8, d: f64) []const u8 {
    const a = @abs(d);
    // Threshold matches §6.1.6.1.20 step 6 (exponential when
    // `n - k <= -6` or `n > 21` on the spec's decomposition). We
    // approximate with absolute-value cutoffs that fit a 64-byte
    // buffer with `{d}` — anything outside uses `{e}` instead,
    // which is bounded.
    if (a != 0 and (a < 1e-6 or a >= 1e21)) {
        const raw = std.fmt.bufPrint(scratch, "{e}", .{d}) catch unreachable;
        // JS spec mandates `1e+22`-style sign on positive
        // exponents; Zig's `{e}` emits `1e22`. Insert the `+`
        // post-hoc using the same scratch buffer.
        const e_idx = std.mem.indexOfScalar(u8, raw, 'e') orelse return raw;
        const after = e_idx + 1;
        if (after >= raw.len) return raw;
        if (raw[after] == '+' or raw[after] == '-') return raw;
        if (raw.len + 1 > scratch.len) return raw;
        var i: usize = raw.len;
        while (i > after) : (i -= 1) scratch[i] = scratch[i - 1];
        scratch[after] = '+';
        return scratch[0 .. raw.len + 1];
    }
    return std.fmt.bufPrint(scratch, "{d}", .{d}) catch unreachable;
}

/// §7.1.19 ToPropertyKey-ish coercion for computed key access.
/// Returns a slice that borrows from `scratch` for primitives and
/// from the original `JSString.bytes` for string keys. Caller
/// must not retain the slice past the next allocation that could
/// invalidate the JSString contents — at sta_computed sites we
/// re-allocate before storing.
/// §7.1.21 CanonicalNumericIndexString — returns `true` when `s`
/// is "-0" or the result of `ToString(ToNumber(s))` (i.e., the
/// canonical string form of a Number). Used at TypedArray
/// `[[Set]]` to detect string keys that route to
/// IntegerIndexedElementSet (which still performs `ToNumber` on
/// the value but silently drops the store when the index is
/// invalid). Spec-faithful: matches the lexical shape of a JS
/// number literal in source form (sign + digits + optional `.`
/// + digits + optional exponent), plus the canonical sentinels
/// ("Infinity", "-Infinity", "NaN", "-0").
pub fn isCanonicalNumericIndexString(s: []const u8) bool {
    if (s.len == 0) return false;
    if (std.mem.eql(u8, s, "-0")) return true;
    if (std.mem.eql(u8, s, "NaN")) return true;
    if (std.mem.eql(u8, s, "Infinity")) return true;
    if (std.mem.eql(u8, s, "-Infinity")) return true;
    // Parse as a JS-style number. `std.fmt.parseFloat` accepts the
    // strict numeric grammar Cynic needs here (no hex / no leading
    // `+`); reject NaN result to filter junk like "abc". The
    // canonical-string round-trip check is over-strict for our
    // purpose — IntegerIndexedElementSet drops on any non-valid
    // index anyway, so "01" / "1.10" both fall into the drop path.
    const d = std.fmt.parseFloat(f64, s) catch return false;
    return !std.math.isNan(d);
}

fn computedKeyToString(v: Value, scratch: *[64]u8) []const u8 {
    if (v.isString()) {
        const s: *JSString = @ptrCast(@alignCast(v.asString()));
        return s.bytes;
    }
    if (v.isInt32()) {
        return std.fmt.bufPrint(scratch, "{d}", .{v.asInt32()}) catch unreachable;
    }
    if (v.isDouble()) {
        const d = v.asDouble();
        if (std.math.isNan(d)) return "NaN";
        if (std.math.isInf(d)) return if (d > 0) "Infinity" else "-Infinity";
        // Integer-valued doubles render without a fractional part —
        // matches §7.1.4 ToString and avoids `arr["0.0"]` mismatches.
        const safe_int_max: f64 = 9007199254740992.0;
        if (d == @trunc(d) and d >= -safe_int_max and d <= safe_int_max) {
            const i: i64 = @intFromFloat(d);
            return std.fmt.bufPrint(scratch, "{d}", .{i}) catch unreachable;
        }
        return formatDoubleSafe(scratch, d);
    }
    if (v.isBool()) return if (v.asBool()) "true" else "false";
    if (v.isNull()) return "null";
    if (v.isUndefined()) return "undefined";
    // §6.1.5.1 Well-Known Symbols + §7.1.19 ToPropertyKey for
    // user Symbols. Each Symbol carries a stable `prop_key`
    // string: the conventional `@@iterator` etc. for well-known
    // ones, a unique `<sym:N>` for user-created ones. So
    // `obj[Symbol.iterator]` and `obj["@@iterator"]` resolve to
    // the same slot (well-known), while two `Symbol("k")` calls
    // produce distinct keys (`<sym:0>` vs `<sym:1>`).
    if (heap_mod.valueAsSymbol(v)) |sym| {
        return sym.prop_key;
    }
    return "[object]";
}

/// Build a runtime error value of the given JS type, with `.message`
/// set to `msg`. Falls back to a bare `JSString` if `installBuiltins`
/// hasn't run on this realm (the inline-test paths construct realms
/// directly without builtins; their assertions only check that
/// _something_ was thrown, not its shape).
fn makeReferenceError(realm: *Realm, msg: []const u8) RunError!Value {
    return intrinsics_mod.newReferenceError(realm, msg) catch return error.OutOfMemory;
}

/// §10.5.5 OrdinaryDelete. Result of attempting `delete obj[key]`:
/// • `.ok = true` — the property didn't exist or was removed.
/// • `.ok = false` — never returned today (legacy non-strict).
/// • `.throw_typeerror` — non-configurable property (strict-only),
/// or non-object receiver. Caller surfaces the message as a
/// `TypeError`.
const DeleteResult = union(enum) {
    ok: bool,
    throw_typeerror: []const u8,
};

fn deleteOwnProperty(realm: *Realm, recv: Value, key: []const u8) DeleteResult {
    _ = realm;
    const obj_mod = @import("object.zig");
    if (heap_mod.valueAsPlainObject(recv)) |obj| {
        // Accessor descriptor — accessors store their own
        // configurable bit in `property_flags` keyed by the
        // accessor name. If absent we treat as configurable=true
        // (default), since later only writes flag entries for
        // non-default descriptors.
        if (obj.accessors.contains(key)) {
            const flags = obj.flagsFor(key);
            if (!flags.configurable) return .{ .throw_typeerror = "Cannot delete non-configurable property" };
            _ = obj.accessors.swapRemove(key);
            _ = obj.property_flags.swapRemove(key);
            return .{ .ok = true };
        }
        // §10.4.2 Array exotic — integer-indexed keys live in
        // the packed `elements` vector, or (when descriptor-flag-
        // demoted) the named-property bag. `JSObject.deleteOwn`
        // handles both: it holes the slot and, if the slot was
        // bag-promoted, removes the bag entry — failing on
        // non-configurable.
        if (obj.is_array_exotic) {
            if (obj_mod.JSObject.canonicalIntegerIndex(key)) |_| {
                if (!obj.deleteOwn(key)) return .{ .throw_typeerror = "Cannot delete non-configurable property" };
                return .{ .ok = true };
            }
        }
        // Data property.
        if (!obj.properties.contains(key)) return .{ .ok = true };
        const flags = obj.flagsFor(key);
        if (!flags.configurable) return .{ .throw_typeerror = "Cannot delete non-configurable property" };
        _ = obj.properties.swapRemove(key);
        _ = obj.property_flags.swapRemove(key);
        return .{ .ok = true };
    }
    if (heap_mod.valueAsFunction(recv)) |fn_obj| {
        // §17 / §10.2.4 / §10.2.9 — `length`, `name` are
        // configurable; `prototype` is non-configurable for
        // ordinary functions. The spec slots get their flags
        // synthesised by `JSFunction.flagsForOwn`; user-installed
        // overrides live in `property_flags`.
        if (!fn_obj.hasOwn(key)) return .{ .ok = true };
        const flags = fn_obj.flagsForOwn(key);
        if (!flags.configurable) return .{ .throw_typeerror = "Cannot delete non-configurable property" };
        // Accessor descriptors live in a separate map (e.g. the
        // static `Promise[@@species]` getter). Remove the accessor
        // entry alongside its flags.
        if (fn_obj.accessors.contains(key)) {
            _ = fn_obj.accessors.swapRemove(key);
            _ = fn_obj.property_flags.swapRemove(key);
            return .{ .ok = true };
        }
        // Removing `name` clears the dedicated slot; removing
        // `length` drops the param-count fallback path entirely
        // (subsequent `hasOwn("length")` returns false). Removing
        // `prototype` clears the dedicated slot.
        if (std.mem.eql(u8, key, "name")) {
            fn_obj.name = null;
            fn_obj.name_string = null;
        }
        if (std.mem.eql(u8, key, "prototype")) fn_obj.prototype = null;
        _ = fn_obj.properties.swapRemove(key);
        _ = fn_obj.property_flags.swapRemove(key);
        return .{ .ok = true };
    }
    if (recv.isNull() or recv.isUndefined()) {
        return .{ .throw_typeerror = "Cannot delete property of null or undefined" };
    }
    // Other primitives (string, number, bool, symbol, bigint) —
    // ToObject wraps them per §7.1.18, but the wrapper has no
    // own properties so the delete trivially succeeds.
    return .{ .ok = true };
}

/// Result of attempting a strict-mode property set:
/// • `.ok` — write done; caller falls through.
/// • `.handled` — write threw and `unwindThrow` re-
/// entered a handler; caller should
/// `continue` the dispatch loop.
/// • `.uncaught: Value` — write threw with no live handler;
/// caller should `return.{.thrown = v }`.
const SetOutcome = union(enum) { ok, handled, uncaught: Value };

/// §10.5.5 OrdinarySet under always-strict semantics. Walks the
/// receiver:
/// • Plain object → accessor setter wins; non-writable own
/// property throws TypeError; otherwise the property bag is
/// updated.
/// • Function → same flow with `setIfWritable`.
/// • Anything else → TypeError "Cannot set properties of …".
fn strictSetProperty(
    allocator: std.mem.Allocator,
    realm: *Realm,
    frames: *std.ArrayListUnmanaged(CallFrame),
    f: *CallFrame,
    ip: usize,
    recv: Value,
    key: []const u8,
    value: Value,
) RunError!SetOutcome {
    return strictSetPropertyAnchored(allocator, realm, frames, f, ip, recv, key, null, value);
}

/// Like `strictSetProperty`, but anchors `key_string` (the
/// JSString whose `bytes == key`) onto the receiver via
/// `setComputedOwned`, so the GC keeps the key's backing memory
/// alive for as long as the property is live. Without this, a
/// `obj[expr] = v` write where `expr` allocates a fresh JSString
/// (e.g. `"k" + i`) loses the key's bytes the next time GC runs
/// and a hash lookup that compares against the dangling slice
/// either crashes or finds nothing.
fn strictSetPropertyAnchored(
    allocator: std.mem.Allocator,
    realm: *Realm,
    frames: *std.ArrayListUnmanaged(CallFrame),
    f: *CallFrame,
    ip: usize,
    recv: Value,
    key: []const u8,
    key_string: ?*JSString,
    value: Value,
) RunError!SetOutcome {
    if (heap_mod.valueAsPlainObject(recv)) |obj_in| {
        // §10.5 Proxy [[Set]] — if `recv` is a proxy exotic,
        // dispatch through `handler.set` before falling back to
        // the target's default setter logic. Loops so that a
        // trapless proxy whose target is itself a proxy keeps
        // dispatching down the chain (§10.5.6 step 7.a recurses
        // into target.[[Set]]).
        var obj = obj_in;
        while (obj.proxy_target != null or obj.proxy_revoked) {
            const r = try proxySetTrap(allocator, realm, frames, f, ip, obj, key, value, recv);
            switch (r) {
                .value => return .ok,
                .fallthrough => |t| {
                    if (t == obj) break;
                    obj = t;
                },
                .handled => return .handled,
                .uncaught => |ex| return .{ .uncaught = ex },
            }
        }
        if (lookupAccessor(obj, key)) |acc_pair| {
            if (acc_pair.setter) |setter| {
                const args = [_]Value{value};
                const outcome = try callJSFunction(allocator, realm, setter, recv, &args);
                switch (outcome) {
                    .value, .yielded => return .ok,
                    .thrown => |ex| return throwInSetter(realm, frames, f, ip, value, ex),
                }
            }
            const ex = try makeTypeError(realm, "Cannot set property which has only a getter");
            return throwInSetter(realm, frames, f, ip, value, ex);
        }
        // §10.4.2 ArraySetLength — when the receiver is array-
        // shaped (its [[Prototype]] is %Array.prototype%) and
        // we're writing `length`, coerce the value to a u32 and
        // delete every own integer-indexed key whose index is
        // >= the new length, walking descending. The walk stops
        // at the first non-configurable element; the spec sets
        // length to that index + 1 and throws TypeError in
        // strict mode (§10.4.2.4 step 17.b.ii).
        if (std.mem.eql(u8, key, "length") and obj.prototype != null and obj.prototype == realm.intrinsics.array_prototype) {
            // Check the existing length is writable. If a prior
            // `Object.defineProperty(arr, "length", {writable:false})`
            // froze it, any future length-write must throw.
            if (obj.property_flags.get("length")) |flags| {
                if (!flags.writable) {
                    const ex = try makeTypeError(realm, "Cannot assign to read-only property 'length'");
                    return throwInSetter(realm, frames, f, ip, value, ex);
                }
            }
            const new_len = arrayLengthCoerce(value) orelse {
                const ex = try makeRangeError(realm, "Invalid array length");
                return throwInSetter(realm, frames, f, ip, value, ex);
            };
            const truncate_result = truncateArrayAtLength(allocator, obj, new_len);
            const final_len = truncate_result.final_length;
            obj.set(allocator, "length", Value.fromInt32(@intCast(@min(final_len, std.math.maxInt(i32))))) catch return error.OutOfMemory;
            if (truncate_result.blocked) {
                const ex = try makeTypeError(realm, "Cannot delete non-configurable array index");
                return throwInSetter(realm, frames, f, ip, value, ex);
            }
            return .ok;
        }
        // §10.4.2.1 [[DefineOwnProperty]] — Array exotic indexed
        // writes go straight to the packed `elements` vector via
        // `setIndexed`, which also keeps `length` in sync. A
        // descriptor-flag-demoted slot lives in the named-property
        // bag instead; the standard property path below picks it
        // up and runs the §10.5.5 writability gate against the
        // bag's flags. The §17 length-write-gating against
        // `length: { writable: false }` still applies.
        if (obj.is_array_exotic) {
            if (canonicalIntegerIndexInterp(key)) |idx| {
                if (idx <= 0xFFFFFFFE and !obj.properties.contains(key)) {
                    if (obj.property_flags.get("length")) |flags| {
                        if (!flags.writable) {
                            const cur_len_v = obj.properties.get("length") orelse Value.fromInt32(0);
                            const cur_len: u32 = if (cur_len_v.isInt32()) @intCast(@max(0, cur_len_v.asInt32())) else 0;
                            if (idx >= cur_len) {
                                const ex = try makeTypeError(realm, "Cannot extend non-writable array length");
                                return throwInSetter(realm, frames, f, ip, value, ex);
                            }
                        }
                    }
                    obj.setIndexed(allocator, idx, value) catch return error.OutOfMemory;
                    return .ok;
                }
            }
        }
        // Fast path that also anchors the key's backing JSString
        // when the caller supplied one. Necessary because
        // `properties` stores `[]const u8` slices, not pointers,
        // so a heap-allocated key gets swept without the anchor.
        const had_entry = obj.properties.contains(key);
        const had_indexed = blk_idx: {
            if (obj.is_array_exotic) {
                if (canonicalIntegerIndexInterp(key)) |idx| break :blk_idx obj.hasOwnIndexedSlot(idx);
            }
            break :blk_idx false;
        };
        if (had_entry) {
            const flags = obj.flagsFor(key);
            if (!flags.writable) {
                const ex = try makeTypeError(realm, "Cannot assign to read-only property");
                return throwInSetter(realm, frames, f, ip, value, ex);
            }
            obj.properties.put(allocator, key, value) catch return error.OutOfMemory;
        } else {
            // §10.1.9.2 OrdinarySetWithOwnDescriptor — when no own
            // descriptor exists for the key, the spec ultimately
            // calls [[DefineOwnProperty]], which fails (and so
            // strict-mode [[Set]] throws — §10.1.9.1 step 4) when
            // the receiver is non-extensible.
            if (!had_indexed and !obj.extensible) {
                const ex = try makeTypeError(realm, "Cannot add property, object is not extensible");
                return throwInSetter(realm, frames, f, ip, value, ex);
            }
            if (key_string) |ks| {
                obj.setComputedOwned(allocator, ks, value) catch return error.OutOfMemory;
            } else {
                obj.set(allocator, key, value) catch return error.OutOfMemory;
            }
        }
        return .ok;
    }
    if (heap_mod.valueAsFunction(recv)) |fn_obj| {
        // §10.1.9 [[Set]] for functions — accessor descriptors
        // win over data slots. Static `set [K](v) {}` on a class
        // lands in `fn_obj.accessors`; without this branch the
        // assignment fell through to `setIfWritable` which treats
        // every entry as a data prop and tripped the read-only
        // guard. Walk the same chain as `lookupFunctionAccessor`
        // (own → `static_parent` → `proto`) so the inherited
        // `%Function.prototype%` `caller` / `arguments` poison-pill
        // setter (§10.2.4) fires on `fn.caller = x` writes, matching
        // the `set` side of the spec accessor.
        if (lookupFunctionAccessor(fn_obj, key)) |acc_pair| {
            if (acc_pair.setter) |setter| {
                const args = [_]Value{value};
                const outcome = try callJSFunction(allocator, realm, setter, recv, &args);
                switch (outcome) {
                    .value, .yielded => return .ok,
                    .thrown => |ex| return throwInSetter(realm, frames, f, ip, value, ex),
                }
            }
            const ex = try makeTypeError(realm, "Cannot set property which has only a getter");
            return throwInSetter(realm, frames, f, ip, value, ex);
        }
        const ok = fn_obj.setIfWritable(allocator, key, value) catch return error.OutOfMemory;
        if (!ok) {
            const ex = try makeTypeError(realm, "Cannot assign to read-only property");
            return throwInSetter(realm, frames, f, ip, value, ex);
        }
        return .ok;
    }
    const ex = try makeTypeError(realm, "Cannot set properties of non-object");
    return throwInSetter(realm, frames, f, ip, value, ex);
}

fn throwInSetter(
    realm: *Realm,
    frames: *std.ArrayListUnmanaged(CallFrame),
    f: *CallFrame,
    ip: usize,
    acc_value: Value,
    ex: Value,
) RunError!SetOutcome {
    f.ip = ip;
    f.accumulator = acc_value;
    const allocator = realm.allocator;
    if (!try unwindThrow(allocator, realm, frames, ex)) {
        return .{ .uncaught = ex };
    }
    return .handled;
}

/// Outcome of a §10.5.5 Proxy `get`/`set`/`has`/`deleteProperty`
/// trap dispatch:
/// • `.value: Value` — trap returned a primitive/object; use it.
/// • `.fallthrough: *JSObject` — no trap installed; the caller
/// should run the default lookup
/// against this object (the proxy
/// target).
/// • `.handled` — trap threw and `unwindThrow` re-entered a
/// bytecode handler; caller `continue`s.
/// • `.uncaught: Value` — trap threw with no handler; caller
/// returns `.{.thrown = v }`.
const ProxyOutcome = union(enum) {
    value: Value,
    fallthrough: *JSObject,
    handled,
    uncaught: Value,
};

/// §10.5.5 [[Get]] (P, Receiver) on a proxy. If the handler's
/// `get` trap is missing or non-callable, fall through to the
/// target. Otherwise call `trap(target, key, receiver)` and use
/// its result. Trap exceptions thread through the bytecode
/// handler chain via `unwindThrow`.
fn proxyGetTrap(
    allocator: std.mem.Allocator,
    realm: *Realm,
    frames: *std.ArrayListUnmanaged(CallFrame),
    f: *CallFrame,
    ip: usize,
    proxy: *JSObject,
    key: []const u8,
    receiver: Value,
) RunError!ProxyOutcome {
    if (proxy.proxy_revoked) {
        const ex = try makeTypeError(realm, "Cannot perform 'get' on a proxy that has been revoked");
        f.ip = ip;
        if (!try unwindThrow(allocator, realm, frames, ex)) {
            return .{ .uncaught = ex };
        }
        return .handled;
    }
    const target = proxy.proxy_target orelse return .{ .fallthrough = proxy };
    const handler = proxy.proxy_handler orelse return .{ .fallthrough = target };
    const trap_v = handler.get("get");
    // §7.3.11 GetMethod — undefined/null fall through; any other
    // non-callable value throws TypeError before the trap runs.
    if (trap_v.isUndefined() or trap_v.isNull()) return .{ .fallthrough = target };
    const trap_fn = heap_mod.valueAsFunction(trap_v) orelse {
        const ex = try makeTypeError(realm, "Proxy 'get' trap is not callable");
        f.ip = ip;
        if (!try unwindThrow(allocator, realm, frames, ex)) return .{ .uncaught = ex };
        return .handled;
    };
    const key_str = realm.heap.allocateString(key) catch return error.OutOfMemory;
    const args = [_]Value{ heap_mod.taggedObject(target), Value.fromString(key_str), receiver };
    const outcome = try callJSFunction(allocator, realm, trap_fn, heap_mod.taggedObject(handler), &args);
    switch (outcome) {
        .value, .yielded => |v| return .{ .value = v },
        .thrown => |ex| {
            f.ip = ip;
            if (!try unwindThrow(allocator, realm, frames, ex)) {
                return .{ .uncaught = ex };
            }
            return .handled;
        },
    }
}

/// §10.5.10 [[Delete]] (P) on a proxy. Calls `handler.deleteProperty`
/// if defined; the result is coerced to a Boolean and returned to
/// the caller for the `delete` opcode's accumulator.
fn proxyDeleteTrap(
    allocator: std.mem.Allocator,
    realm: *Realm,
    frames: *std.ArrayListUnmanaged(CallFrame),
    f: *CallFrame,
    ip: usize,
    proxy: *JSObject,
    key: []const u8,
) RunError!ProxyOutcome {
    if (proxy.proxy_revoked) {
        const ex = try makeTypeError(realm, "Cannot perform 'deleteProperty' on a proxy that has been revoked");
        f.ip = ip;
        if (!try unwindThrow(allocator, realm, frames, ex)) {
            return .{ .uncaught = ex };
        }
        return .handled;
    }
    const target = proxy.proxy_target orelse return .{ .fallthrough = proxy };
    const handler = proxy.proxy_handler orelse return .{ .fallthrough = target };
    const trap_v = handler.get("deleteProperty");
    if (trap_v.isUndefined() or trap_v.isNull()) return .{ .fallthrough = target };
    const trap_fn = heap_mod.valueAsFunction(trap_v) orelse {
        const ex = try makeTypeError(realm, "Proxy 'deleteProperty' trap is not callable");
        f.ip = ip;
        if (!try unwindThrow(allocator, realm, frames, ex)) return .{ .uncaught = ex };
        return .handled;
    };
    const key_str = realm.heap.allocateString(key) catch return error.OutOfMemory;
    const args = [_]Value{ heap_mod.taggedObject(target), Value.fromString(key_str) };
    const outcome = try callJSFunction(allocator, realm, trap_fn, heap_mod.taggedObject(handler), &args);
    switch (outcome) {
        .value, .yielded => |v| return .{ .value = Value.fromBool(arith.toBoolean(v)) },
        .thrown => |ex| {
            f.ip = ip;
            if (!try unwindThrow(allocator, realm, frames, ex)) {
                return .{ .uncaught = ex };
            }
            return .handled;
        },
    }
}

/// §10.5.7 [[HasProperty]] (P) on a proxy. Calls `handler.has`
/// if defined; the result is coerced to a Boolean. Used by the
/// `in` operator and `for-in` (the latter still walks own keys
/// directly today).
fn proxyHasTrap(
    allocator: std.mem.Allocator,
    realm: *Realm,
    frames: *std.ArrayListUnmanaged(CallFrame),
    f: *CallFrame,
    ip: usize,
    proxy: *JSObject,
    key: []const u8,
) RunError!ProxyOutcome {
    if (proxy.proxy_revoked) {
        const ex = try makeTypeError(realm, "Cannot perform 'has' on a proxy that has been revoked");
        f.ip = ip;
        if (!try unwindThrow(allocator, realm, frames, ex)) {
            return .{ .uncaught = ex };
        }
        return .handled;
    }
    const target = proxy.proxy_target orelse return .{ .fallthrough = proxy };
    const handler = proxy.proxy_handler orelse return .{ .fallthrough = target };
    const trap_v = handler.get("has");
    if (trap_v.isUndefined() or trap_v.isNull()) return .{ .fallthrough = target };
    const trap_fn = heap_mod.valueAsFunction(trap_v) orelse {
        const ex = try makeTypeError(realm, "Proxy 'has' trap is not callable");
        f.ip = ip;
        if (!try unwindThrow(allocator, realm, frames, ex)) return .{ .uncaught = ex };
        return .handled;
    };
    const key_str = realm.heap.allocateString(key) catch return error.OutOfMemory;
    const args = [_]Value{ heap_mod.taggedObject(target), Value.fromString(key_str) };
    const outcome = try callJSFunction(allocator, realm, trap_fn, heap_mod.taggedObject(handler), &args);
    switch (outcome) {
        .value, .yielded => |v| return .{ .value = Value.fromBool(arith.toBoolean(v)) },
        .thrown => |ex| {
            f.ip = ip;
            if (!try unwindThrow(allocator, realm, frames, ex)) {
                return .{ .uncaught = ex };
            }
            return .handled;
        },
    }
}

/// §10.5.6 [[Set]] (P, V, Receiver) on a proxy. Mirrors
/// `proxyGetTrap` but for `set`. A successful trap return
/// (truthy) is treated as success; a falsy return discards the
/// write silently in non-strict spec mode, but Cynic is strict-
/// only so we throw TypeError on falsy returns per §10.5.6 step 9.
fn proxySetTrap(
    allocator: std.mem.Allocator,
    realm: *Realm,
    frames: *std.ArrayListUnmanaged(CallFrame),
    f: *CallFrame,
    ip: usize,
    proxy: *JSObject,
    key: []const u8,
    value: Value,
    receiver: Value,
) RunError!ProxyOutcome {
    if (proxy.proxy_revoked) {
        const ex = try makeTypeError(realm, "Cannot perform 'set' on a proxy that has been revoked");
        f.ip = ip;
        if (!try unwindThrow(allocator, realm, frames, ex)) {
            return .{ .uncaught = ex };
        }
        return .handled;
    }
    const target = proxy.proxy_target orelse return .{ .fallthrough = proxy };
    const handler = proxy.proxy_handler orelse return .{ .fallthrough = target };
    const trap_v = handler.get("set");
    if (trap_v.isUndefined() or trap_v.isNull()) return .{ .fallthrough = target };
    const trap_fn = heap_mod.valueAsFunction(trap_v) orelse {
        const ex = try makeTypeError(realm, "Proxy 'set' trap is not callable");
        f.ip = ip;
        if (!try unwindThrow(allocator, realm, frames, ex)) return .{ .uncaught = ex };
        return .handled;
    };
    const key_str = realm.heap.allocateString(key) catch return error.OutOfMemory;
    const args = [_]Value{ heap_mod.taggedObject(target), Value.fromString(key_str), value, receiver };
    const outcome = try callJSFunction(allocator, realm, trap_fn, heap_mod.taggedObject(handler), &args);
    switch (outcome) {
        .value, .yielded => |v| {
            if (!arith.toBoolean(v)) {
                // §10.5.6 step 9 — strict-mode assignment throws on
                // a falsy trap return (Cynic is strict-only).
                const ex = try makeTypeError(realm, "'set' on proxy returned falsy");
                f.ip = ip;
                if (!try unwindThrow(allocator, realm, frames, ex)) {
                    return .{ .uncaught = ex };
                }
                return .handled;
            }
            // §10.5.6 steps 10–12 — the trap can't claim success on
            // a non-configurable / non-writable own data descriptor
            // unless the new value matches, nor on a non-configurable
            // accessor whose [[Set]] is undefined.
            if (target.property_flags.get(key)) |flags| {
                if (target.properties.get(key)) |target_v| {
                    if (!flags.configurable and !flags.writable) {
                        if (!intrinsics_mod.sameValue(target_v, value)) {
                            const ex = try makeTypeError(realm, "proxy 'set' trap reported success for non-writable non-configurable data property");
                            f.ip = ip;
                            if (!try unwindThrow(allocator, realm, frames, ex)) return .{ .uncaught = ex };
                            return .handled;
                        }
                    }
                }
            }
            if (target.accessors.get(key)) |acc| {
                const flags = target.flagsFor(key);
                if (!flags.configurable and acc.setter == null) {
                    const ex = try makeTypeError(realm, "proxy 'set' trap reported success for non-configurable accessor with no setter");
                    f.ip = ip;
                    if (!try unwindThrow(allocator, realm, frames, ex)) return .{ .uncaught = ex };
                    return .handled;
                }
            }
            return .{ .value = Value.undefined_ };
        },
        .thrown => |ex| {
            f.ip = ip;
            if (!try unwindThrow(allocator, realm, frames, ex)) {
                return .{ .uncaught = ex };
            }
            return .handled;
        },
    }
}

/// Result of attempting ToPrimitive coercion for `==`/`!=`/`<`/
/// `>`/`<=`/`>=` opcode handlers (§7.2.13–§7.2.15):
/// • `.ok: Value` — primitive form ready for the compare.
/// • `.handled` — coercion threw and `unwindThrow` re-
/// entered a handler; caller `continue`s.
/// • `.uncaught: Value` — coercion threw with no live handler;
/// caller returns `.{.thrown = v }`.
const CompareOutcome = union(enum) { ok: Value, handled, uncaught: Value };

/// `==`/`!=` variant of `coerceForCompare`. Per §7.2.14 IsLooselyEqual
/// steps 11/12, ToPrimitive(.default) only fires when `self` is an
/// Object and `other` is one of {String, Number, BigInt, Symbol}.
/// Object-vs-Object falls through to strictEq (reference equality)
/// without coercion; Object-vs-Boolean is handled by `looseEq`'s
/// boolean recursion.
fn coerceForCompareEq(
    allocator: std.mem.Allocator,
    realm: *Realm,
    frames: *std.ArrayListUnmanaged(CallFrame),
    f: *CallFrame,
    ip: usize,
    self: Value,
    other: Value,
) RunError!CompareOutcome {
    if (!self.isObject()) return .{ .ok = self };
    // Symbols and BigInts share the object tag bit but are
    // primitive types — they don't need coercion.
    if (heap_mod.valueAsSymbol(self) != null) return .{ .ok = self };
    if (heap_mod.valueAsBigInt(self) != null) return .{ .ok = self };
    // Coerce `self` only if `other` is an eligible primitive.
    // Spec mentions String/Number/BigInt/Symbol in steps 11/12,
    // but Booleans coerce to Number in steps 9/10 then re-enter
    // 11/12 against the (still-Object) `self`, so we treat them
    // as eligible here. null/undefined/Object/Function are not.
    const other_eligible = other.isString() or other.isInt32() or other.isDouble() or
        other.isBool() or heap_mod.valueAsBigInt(other) != null or
        heap_mod.valueAsSymbol(other) != null;
    if (!other_eligible) return .{ .ok = self };
    return coerceForCompare(allocator, realm, frames, f, ip, self, .default);
}

/// §7.1.1 ToPrimitive wrapper for the comparison opcodes. Mirrors
/// `strictSetProperty` — propagates an uncaught throw to the host
/// or routes a caught throw through the bytecode handler chain.
/// `hint` is `.number` for §7.2.13 IsLessThan (relational `<`/
/// `>`/`<=`/`>=`) and `.default` for §7.2.14 IsLooselyEqual
/// (`==`/`!=`).
fn coerceForCompare(
    allocator: std.mem.Allocator,
    realm: *Realm,
    frames: *std.ArrayListUnmanaged(CallFrame),
    f: *CallFrame,
    ip: usize,
    value: Value,
    hint: intrinsics_mod.ToPrimitiveHint,
) RunError!CompareOutcome {
    // Functions are objects per §6.1.7; coerce via ToString
    // (their source / "function() { [native code] }" placeholder)
    // so a computed key `{ [() => {}]: 1 }` lands under the
    // arrow's source text instead of the "[object]" fallback.
    if (heap_mod.valueAsFunction(value)) |_| {
        const s = intrinsics_mod.stringifyArg(realm, value) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.NativeThrew => {
                const ex = realm.pending_exception orelse try makeTypeError(realm, "ToString failed");
                realm.pending_exception = null;
                f.ip = ip;
                f.accumulator = value;
                if (!try unwindThrow(allocator, realm, frames, ex)) {
                    return .{ .uncaught = ex };
                }
                return .handled;
            },
        };
        return .{ .ok = Value.fromString(s) };
    }
    if (!value.isObject()) return .{ .ok = value };
    const prim = intrinsics_mod.toPrimitive(realm, value, hint) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.NativeThrew => {
            const ex = realm.pending_exception orelse try makeTypeError(realm, "ToPrimitive failed");
            realm.pending_exception = null;
            f.ip = ip;
            f.accumulator = value;
            if (!try unwindThrow(allocator, realm, frames, ex)) {
                return .{ .uncaught = ex };
            }
            return .handled;
        },
    };
    return .{ .ok = prim };
}

/// §7.1.19 ToPropertyKey wrapper — when a computed key (`obj[k]`,
/// `{ [k]: v }`, etc.) is an object that's neither Symbol nor
/// BigInt, run §7.1.1 ToPrimitive with hint "string" so that
/// `[arr]` evaluates `arr.toString()` (returning `"a,b,c"` for
/// `[a,b,c]`, the empty string for `[]`, etc.) before
/// `computedKeyToString` formats the result. Symbol primitives
/// pass through — `computedKeyToString` already maps them to
/// their stable `prop_key` slug. Returns `.handled` /
/// `.uncaught` like the comparison coercion helpers.
fn coerceToPropertyKey(
    allocator: std.mem.Allocator,
    realm: *Realm,
    frames: *std.ArrayListUnmanaged(CallFrame),
    f: *CallFrame,
    ip: usize,
    value: Value,
) RunError!CompareOutcome {
    // §7.1.19 ToPropertyKey: ToPrimitive(arg, "string") then
    // ToString unless result is a Symbol. Function values are
    // objects per §6.1.7; without this branch a computed key
    // like `{ [() => {}]: 1 }` skipped coercion and the slot
    // ended up under the literal "[object]" placeholder.
    if (heap_mod.valueAsFunction(value) != null) {
        return coerceForCompare(allocator, realm, frames, f, ip, value, .string);
    }
    if (!value.isObject()) return .{ .ok = value };
    if (heap_mod.valueAsSymbol(value) != null) return .{ .ok = value };
    if (heap_mod.valueAsBigInt(value) != null) return .{ .ok = value };
    return coerceForCompare(allocator, realm, frames, f, ip, value, .string);
}

/// §7.1.5 ToUint32 — coerces to u32 with the round-toward-zero,
/// modulo 2^32 semantics. For our array-length usage we need to
/// reject NaN, Infinity, fractional, and negative inputs (the
/// spec throws RangeError when ToUint32(value) !== ToNumber(value)).
/// Returns null on rejection.
pub fn arrayLengthCoerce(v: Value) ?u32 {
    if (v.isInt32()) {
        const i = v.asInt32();
        if (i < 0) return null;
        return @intCast(i);
    }
    if (v.isDouble()) {
        const d = v.asDouble();
        if (std.math.isNan(d) or std.math.isInf(d)) return null;
        if (d < 0) return null;
        if (d > @as(f64, @floatFromInt(std.math.maxInt(u32)))) return null;
        if (@trunc(d) != d) return null;
        return @intFromFloat(d);
    }
    if (v.isBool()) return if (v.asBool()) 1 else 0;
    if (v.isString()) {
        const s: *JSString = @ptrCast(@alignCast(v.asString()));
        const n = std.fmt.parseFloat(f64, s.bytes) catch return null;
        if (std.math.isNan(n) or std.math.isInf(n) or n < 0 or @trunc(n) != n) return null;
        if (n > @as(f64, @floatFromInt(std.math.maxInt(u32)))) return null;
        return @intFromFloat(n);
    }
    return null;
}

/// Result of an §10.4.2.4 ArraySetLength truncate.
/// `final_length` is the new `length` value the caller must
/// store: equals `target_len` on full success, or `blocker_idx + 1`
/// on a stuck non-configurable element. `blocked` tells the
/// strict-mode setter to throw TypeError.
pub const TruncateResult = struct {
    final_length: u32,
    blocked: bool,
};

/// §10.4.2.4 step 16-17 — walk own integer-indexed properties in
/// descending order, deleting each whose index is `>= target_len`.
/// On a non-configurable element, stop and return its index + 1
/// as the floor.
pub fn truncateArrayAtLength(allocator: std.mem.Allocator, obj: *JSObject, target_len: u32) TruncateResult {
    // §10.4.2.4 — Array exotic: truncate the packed `elements`
    // vector. Indexed slots are configurable today (Cynic doesn't
    // yet support `Object.defineProperty(arr, "0", {configurable:false})`
    // promoting a slot into the named-property bag), so the
    // walk is a single resize.
    if (obj.is_array_exotic) {
        _ = obj.truncateIndexed(allocator, target_len) catch return .{ .final_length = target_len, .blocked = false };
        return .{ .final_length = target_len, .blocked = false };
    }
    // Pre-array-exotic fallback for any object (e.g. an array-
    // like with stringified-index own properties) that ended up
    // routed through ArraySetLength via prototype chaining.
    var indices: std.ArrayListUnmanaged(u32) = .empty;
    defer indices.deinit(allocator);
    var it = obj.properties.iterator();
    while (it.next()) |entry| {
        const k = entry.key_ptr.*;
        if (canonicalIntegerIndexInterp(k)) |idx| {
            if (idx >= target_len) {
                indices.append(allocator, idx) catch return .{ .final_length = target_len, .blocked = false };
            }
        }
    }
    std.mem.sort(u32, indices.items, {}, std.sort.desc(u32));

    var buf: [16]u8 = undefined;
    for (indices.items) |idx| {
        const key = std.fmt.bufPrint(&buf, "{d}", .{idx}) catch continue;
        if (obj.property_flags.get(key)) |flags| {
            if (!flags.configurable) {
                return .{ .final_length = idx + 1, .blocked = true };
            }
        }
        _ = obj.properties.swapRemove(key);
        _ = obj.property_flags.swapRemove(key);
    }
    return .{ .final_length = target_len, .blocked = false };
}

/// §7.1.21 CanonicalNumericIndexString. Local copy for the
/// interpreter's for-in walker (the equivalent in
/// `intrinsics.zig` is module-private). Returns the u32 value
/// when `s` is a canonical integer-index string, else null.
fn canonicalIntegerIndexInterp(s: []const u8) ?u32 {
    if (s.len == 0) return null;
    if (s.len > 10) return null;
    if (s[0] == '0' and s.len > 1) return null;
    var n: u64 = 0;
    for (s) |c| {
        if (c < '0' or c > '9') return null;
        n = n * 10 + (c - '0');
        if (n > std.math.maxInt(u32)) return null;
    }
    return @intCast(n);
}

pub fn makeTypeError(realm: *Realm, msg: []const u8) RunError!Value {
    return intrinsics_mod.newTypeError(realm, msg) catch return error.OutOfMemory;
}

pub fn makeRangeError(realm: *Realm, msg: []const u8) RunError!Value {
    return intrinsics_mod.newRangeError(realm, msg) catch return error.OutOfMemory;
}

// ── Operand decoders ────────────────────────────────────────────────────

fn readU16(code: []const u8, at: usize) u16 {
    return @as(u16, code[at]) | (@as(u16, code[at + 1]) << 8);
}

fn readI16(code: []const u8, at: usize) i16 {
    return @bitCast(readU16(code, at));
}

fn readI32(code: []const u8, at: usize) i32 {
    const u: u32 = @as(u32, code[at]) |
        (@as(u32, code[at + 1]) << 8) |
        (@as(u32, code[at + 2]) << 16) |
        (@as(u32, code[at + 3]) << 24);
    return @bitCast(u);
}

fn applyOffset(ip: usize, off: i16) usize {
    const signed: i64 = @intCast(ip);
    return @intCast(signed + off);
}

// ── Coercions (§7.1) ────────────────────────────────────────────────────

