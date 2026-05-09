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
const JSObject = @import("object.zig").JSObject;
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

const CallFrame = struct {
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
    /// `[[HomeObject]]` (§10.2.5) of the function executing in
    /// this frame. Set on entry from the callee's
    /// `JSFunction.home_object`. `super_get` / `super_call`
    /// resolve through the home object's `[[Prototype]]`.
    home_object: ?*JSObject = null,
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
    // §9.4.7 — `this` at the top of a strict script is undefined.
    {
        const main_regs = try allocator.alloc(Value, chunk.register_count);
        @memset(main_regs, Value.undefined_);
        try frames.append(allocator, .{
            .chunk = chunk,
            .ip = 0,
            .accumulator = Value.undefined_,
            .registers = main_regs,
            .env = null,
            .this_value = Value.undefined_,
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
    _: std.mem.Allocator,
    realm: *Realm,
    chunk: *const @import("../bytecode/chunk.zig").Chunk,
    captured_env: ?*Environment,
    this_value: Value,
    args: []const Value,
) RunError!Value {
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
    return heap_mod.taggedObject(wrapper);
}

/// §27.6 Allocate a wrapper for `async function*` invocation.
/// Mirrors `wrapGenerator` but tags the underlying generator as
/// `is_async = true` so the body's `await` opcode goes through
/// the async-suspend path, and uses `%AsyncGeneratorPrototype%`
/// whose `next`/`return`/`throw` wrap the result in a Promise.
pub fn wrapAsyncGenerator(
    _: std.mem.Allocator,
    realm: *Realm,
    chunk: *const @import("../bytecode/chunk.zig").Chunk,
    captured_env: ?*Environment,
    this_value: Value,
    args: []const Value,
) RunError!Value {
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
    return heap_mod.taggedObject(wrapper);
}

/// Lazily install `%GeneratorPrototype%` on the realm. Has
/// `next` / `return` / `throw` / `[Symbol.iterator]` methods
/// that walk the wrapper's `generator_ref`.
///
/// TODO: per §27.5.1 the `[[Prototype]]` should be
/// `%IteratorPrototype%` so generator iterators inherit
/// `.map` / `.filter` / `.every` / etc. from the
/// iterator-helpers proposal. Wiring it through triggers a
/// SEGV in some `built-ins/Iterator/prototype/map/` fixtures —
/// the chain is still `Object.prototype` until that's tracked
/// down.
fn ensureGeneratorPrototype(realm: *Realm) !*JSObject {
    if (realm.intrinsics.generator_prototype) |p| return p;
    const proto = try realm.heap.allocateObject();
    proto.prototype = realm.intrinsics.object_prototype;

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
fn ensureAsyncGeneratorPrototype(realm: *Realm) !*JSObject {
    if (realm.intrinsics.async_generator_prototype) |p| return p;
    const proto = try realm.heap.allocateObject();
    proto.prototype = realm.intrinsics.object_prototype;

    const next_fn = try realm.heap.allocateFunctionNative(asyncGenNext, 1, "next");
    next_fn.proto = realm.intrinsics.function_prototype;
    try proto.set(realm.allocator, "next", heap_mod.taggedFunction(next_fn));

    const return_fn = try realm.heap.allocateFunctionNative(asyncGenReturn, 1, "return");
    return_fn.proto = realm.intrinsics.function_prototype;
    try proto.set(realm.allocator, "return", heap_mod.taggedFunction(return_fn));

    const throw_fn = try realm.heap.allocateFunctionNative(asyncGenThrow, 1, "throw");
    throw_fn.proto = realm.intrinsics.function_prototype;
    try proto.set(realm.allocator, "throw", heap_mod.taggedFunction(throw_fn));

    // Async generators are themselves async iterables — `@@asyncIterator`
    // returns the generator. The well-known string is what the
    // for-await-of opcode looks up.
    const sym_iter_fn = try realm.heap.allocateFunctionNative(genSymbolIterator, 0, "[Symbol.asyncIterator]");
    sym_iter_fn.proto = realm.intrinsics.function_prototype;
    try proto.set(realm.allocator, "@@asyncIterator", heap_mod.taggedFunction(sym_iter_fn));

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
    const obj = heap_mod.valueAsPlainObject(this_value) orelse return error.NativeThrew;
    const gen = obj.generator_ref orelse return error.NativeThrew;
    const sent: Value = if (args.len > 0) args[0] else Value.undefined_;
    const outcome = resumeGenerator(realm.allocator, realm, gen, sent) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.NativeThrew,
    };
    switch (outcome) {
        .yielded => |raw| return wrapAsyncGenResult(realm, raw, false),
        .value => |raw| return wrapAsyncGenResult(realm, raw, true),
        .thrown => |ex| return intrinsics_mod.allocatePromiseFor(realm, null, .rejected, ex) catch return error.OutOfMemory,
    }
}

/// §27.6.3.6 AsyncGeneratorYield — produce the next() promise.
/// If `raw` is already-settled, unwrap synchronously. If pending,
/// register a reaction so the outer promise settles when `raw`
/// does, with the value transformed into an iterator result.
fn wrapAsyncGenResult(realm: *Realm, raw: Value, done: bool) @import("function.zig").NativeError!Value {
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
    const state_v = obj.get("__cynic_promise_state__");
    if (!state_v.isString()) return .none;
    const state: *@import("string.zig").JSString = @ptrCast(@alignCast(state_v.asString()));
    const inner = obj.get("__cynic_promise_value__");
    if (std.mem.eql(u8, state.bytes, "fulfilled")) return .{ .fulfilled = inner };
    if (std.mem.eql(u8, state.bytes, "rejected")) return .{ .rejected = inner };
    if (std.mem.eql(u8, state.bytes, "pending")) return .{ .pending = obj };
    return .none;
}

fn asyncGenReturn(realm: *Realm, this_value: Value, args: []const Value) @import("function.zig").NativeError!Value {
    const obj = heap_mod.valueAsPlainObject(this_value) orelse return error.NativeThrew;
    const gen = obj.generator_ref orelse return error.NativeThrew;
    gen.state = .completed;
    const ret_v: Value = if (args.len > 0) args[0] else Value.undefined_;
    const result = genResultObject(realm, ret_v, true) catch return error.OutOfMemory;
    return intrinsics_mod.allocatePromiseFor(realm, null, .fulfilled, result) catch return error.OutOfMemory;
}

fn asyncGenThrow(realm: *Realm, this_value: Value, args: []const Value) @import("function.zig").NativeError!Value {
    _ = this_value;
    const ex: Value = if (args.len > 0) args[0] else Value.undefined_;
    return intrinsics_mod.allocatePromiseFor(realm, null, .rejected, ex) catch return error.OutOfMemory;
}

fn genNext(realm: *Realm, this_value: Value, args: []const Value) @import("function.zig").NativeError!Value {
    const obj = heap_mod.valueAsPlainObject(this_value) orelse return error.NativeThrew;
    const gen = obj.generator_ref orelse return error.NativeThrew;
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
    const obj = heap_mod.valueAsPlainObject(this_value) orelse return error.NativeThrew;
    const gen = obj.generator_ref orelse return error.NativeThrew;
    gen.state = .completed;
    return genResultObject(realm, if (args.len > 0) args[0] else Value.undefined_, true) catch return error.OutOfMemory;
}

fn genThrow(realm: *Realm, this_value: Value, args: []const Value) @import("function.zig").NativeError!Value {
    _ = this_value;
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
};

/// §7.4.1 GetIterator. Produce an iterator object for an
/// iterable. Tries the `@@iterator` method first; falls back to
/// an array-like length+index walk so existing arrays / strings
/// still iterate without forcing every host to install a real
/// `@@iterator` on `Array.prototype` / `String.prototype`. The
/// fallback is observably correct (returns `{value, done}` from
/// `.next()`) for the test262 surface that just calls `for-of`
/// over arrays.
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
        const iter_fn_v = obj.get("@@iterator");
        if (heap_mod.valueAsFunction(iter_fn_v)) |iter_fn| {
            const result = callJSFunction(realm.allocator, realm, iter_fn, iterable, &.{}) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return error.InvalidOpcode,
            };
            switch (result) {
                .value, .yielded => |v| {
                    if (heap_mod.valueAsPlainObject(v) == null) return error.NotIterable;
                    return v;
                },
                .thrown => return error.NotIterable,
            }
        }
    }

    // 2. Array-like fallback. Builds a plain object with a
    // `next` method that walks `iterable[i]` for `i` in
    // `0..length`. The closure-shaped state lives as
    // properties on the iterator (`__cynic_iter_target__`,
    // `__cynic_iter_idx__`); the native `next` reads + writes
    // them via the receiver.
    const has_length = if (heap_mod.valueAsPlainObject(iterable)) |o|
        o.hasOwn("length") or (o.prototype != null and !o.get("length").isUndefined())
    else
        iterable.isString();
    if (!has_length) return error.NotIterable;

    const iter = realm.heap.allocateObject() catch return error.OutOfMemory;
    iter.prototype = realm.intrinsics.object_prototype;
    iter.set(realm.allocator, "__cynic_iter_target__", iterable) catch return error.OutOfMemory;
    iter.set(realm.allocator, "__cynic_iter_idx__", Value.fromInt32(0)) catch return error.OutOfMemory;
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

    var seen: std.StringArrayHashMapUnmanaged(void) = .empty;
    defer seen.deinit(realm.allocator);

    var len: i32 = 0;
    if (heap_mod.valueAsPlainObject(obj_v)) |start_obj| {
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

            var it = cur.properties.iterator();
            while (it.next()) |entry| {
                const key = entry.key_ptr.*;
                if (std.mem.startsWith(u8, key, "__cynic_")) continue;
                if (!cur.flagsFor(key).enumerable) continue;
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
                if (!cur.flagsFor(key).enumerable) continue;
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
/// `this.__cynic_iter_target__[idx]`, increments `idx`, returns
/// `{value, done}`. Done when `idx >= length`. Strings get
/// per-codepoint slicing (`s[i]` returns the i-th character as
/// a one-char string). later: respect surrogate pairs (§7.4.6
/// CreateIterResultObject doesn't, but `String.prototype[
/// @@iterator]` is supposed to walk by UTF-16 code points;
/// Cynic walks by ASCII for now).
fn arrayLikeIterNext(realm: *Realm, this_value: Value, args: []const Value) @import("function.zig").NativeError!Value {
    _ = args;
    const iter_obj = heap_mod.valueAsPlainObject(this_value) orelse return error.NativeThrew;
    const target = iter_obj.get("__cynic_iter_target__");
    const idx_v = iter_obj.get("__cynic_iter_idx__");
    const idx: i32 = if (idx_v.isInt32()) idx_v.asInt32() else 0;

    // Length: from `target.length` if it's an object, or from the
    // string's byte length if it's a string.
    var length: i32 = 0;
    if (heap_mod.valueAsPlainObject(target)) |obj| {
        const len_v = obj.get("length");
        if (len_v.isInt32()) length = len_v.asInt32() else if (len_v.isDouble()) length = @intFromFloat(len_v.asDouble());
    } else if (target.isString()) {
        const s: *@import("string.zig").JSString = @ptrCast(@alignCast(target.asString()));
        length = @intCast(@min(s.bytes.len, std.math.maxInt(i32)));
    }

    const result = realm.heap.allocateObject() catch return error.OutOfMemory;
    result.prototype = realm.intrinsics.object_prototype;
    if (idx >= length) {
        result.set(realm.allocator, "value", Value.undefined_) catch return error.OutOfMemory;
        result.set(realm.allocator, "done", Value.true_) catch return error.OutOfMemory;
        return heap_mod.taggedObject(result);
    }

    var elem: Value = Value.undefined_;
    if (heap_mod.valueAsPlainObject(target)) |obj| {
        var ibuf: [16]u8 = undefined;
        const islice = std.fmt.bufPrint(&ibuf, "{d}", .{idx}) catch unreachable;
        elem = obj.get(islice);
    } else if (target.isString()) {
        const s: *@import("string.zig").JSString = @ptrCast(@alignCast(target.asString()));
        const start: usize = @intCast(idx);
        if (start < s.bytes.len) {
            const sub = realm.heap.allocateString(s.bytes[start .. start + 1]) catch return error.OutOfMemory;
            elem = Value.fromString(sub);
        }
    }
    result.set(realm.allocator, "value", elem) catch return error.OutOfMemory;
    result.set(realm.allocator, "done", Value.false_) catch return error.OutOfMemory;
    iter_obj.set(realm.allocator, "__cynic_iter_idx__", Value.fromInt32(idx + 1)) catch return error.OutOfMemory;
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
pub fn loadModule(
    allocator: std.mem.Allocator,
    realm: *Realm,
    specifier: []const u8,
    base_url: ?[]const u8,
) RunError!Value {
    const ModuleRecord = @import("module.zig").ModuleRecord;
    const loader = realm.module_loader orelse {
        const ex = try makeTypeError(realm, "no module loader installed");
        return ex; // caller checks; we encode the type-error in acc and rely on the call site to throw
    };

    const result = loader(realm, specifier, base_url) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.ModuleNotFound => return makeTypeError(realm, "module not found"),
        error.ModuleLoadError => return makeTypeError(realm, "module load failed"),
    };

    // Cache lookup.
    if (realm.modules.get(result.url)) |mr| {
        switch (mr.state) {
            .uninstantiated, .evaluated => return heap_mod.taggedObject(mr.exports),
            .evaluating => return heap_mod.taggedObject(mr.exports), // cycle: partial ns
            .errored => return mr.error_value,
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
        return ex;
    };

    mr.chunk = compiler_mod.compileModuleAsChunk(realm.allocator, realm, &program, result.source, null, result.url) catch {
        mr.state = .errored;
        const ex = makeTypeError(realm, "module compile error") catch return error.OutOfMemory;
        mr.error_value = ex;
        return ex;
    };

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
            return heap_mod.taggedObject(mr.exports);
        },
        .thrown => |ex| {
            mr.state = .errored;
            mr.error_value = ex;
            return ex;
        },
    }
}

/// Wrap `value` in a Promise-shape JSObject that mirrors the
/// `__cynic_promise_state__` / `__cynic_promise_value__`
/// convention `intrinsics.zig` settled on. Used by the Return
/// op when the frame's `wrap_return_in_promise` flag is set —
/// `async function` bodies `return v` into `Promise.resolve(v)`,
/// uncaught throws into `Promise.reject(...)`. Spec: §27.7
/// AsyncFunctionStart: an async function always returns a
/// Promise; the body's normal completion fulfils it, an
/// abrupt completion rejects it.
pub fn wrapInPromise(realm: *Realm, fulfilled: bool, value: Value) !Value {
    const obj = try realm.heap.allocateObject();
    obj.prototype = realm.intrinsics.promise_prototype;
    const state_str: []const u8 = if (fulfilled) "fulfilled" else "rejected";
    const state_v = try realm.heap.allocateString(state_str);
    try obj.set(realm.allocator, "__cynic_promise_state__", Value.fromString(state_v));
    try obj.set(realm.allocator, "__cynic_promise_value__", value);
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
        }
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
            // Promise resolution (§27.2.1.3-ish): if the handler
            // returned a thenable (= a Cynic Promise), chain
            // result_promise's settlement to the inner Promise's.
            // Plain-value returns settle result_promise fulfilled.
            if (heap_mod.valueAsPlainObject(v)) |inner| {
                if (inner.get("__cynic_promise_state__").isString()) {
                    try chainPromiseToInner(realm, inner, result_obj);
                    return;
                }
            }
            try settlePromiseInternal(realm, result_obj, .fulfilled, v);
        },
        .thrown => |ex| {
            try settlePromiseInternal(realm, result_obj, .rejected, ex);
        },
    }
}

/// Chain `outer`'s settlement to `inner`'s — when `inner`
/// settles, `outer` settles the same way with the same value.
/// Implemented by registering a no-handler reaction on `inner`
/// pointing at `outer`. Spec §27.2.1.3 PromiseResolveThenableJob.
fn chainPromiseToInner(realm: *Realm, inner: *JSObject, outer: *JSObject) !void {
    const state = inner.get("__cynic_promise_state__");
    if (state.isString()) {
        const s: *JSString = @ptrCast(@alignCast(state.asString()));
        if (std.mem.eql(u8, s.bytes, "fulfilled")) {
            try realm.enqueuePromiseReaction(Value.undefined_, inner.get("__cynic_promise_value__"), heap_mod.taggedObject(outer), false);
            return;
        }
        if (std.mem.eql(u8, s.bytes, "rejected")) {
            try realm.enqueuePromiseReaction(Value.undefined_, inner.get("__cynic_promise_value__"), heap_mod.taggedObject(outer), true);
            return;
        }
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
            if (gen.result_promise) |rp| {
                if (heap_mod.valueAsPlainObject(rp)) |rp_obj| {
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
    const cur_state = inst.get("__cynic_promise_state__");
    if (cur_state.isString()) {
        const s: *JSString = @ptrCast(@alignCast(cur_state.asString()));
        if (!std.mem.eql(u8, s.bytes, "pending")) return; // already settled
    }
    const state_str: []const u8 = if (state == .fulfilled) "fulfilled" else "rejected";
    const state_s = try realm.heap.allocateString(state_str);
    try inst.set(realm.allocator, "__cynic_promise_state__", Value.fromString(state_s));
    try inst.set(realm.allocator, "__cynic_promise_value__", value);

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
        const wrap = if (callee.is_async)
            try wrapAsyncGenerator(allocator, realm, callee_chunk, callee.captured_env, this_value, args)
        else
            try wrapGenerator(allocator, realm, callee_chunk, callee.captured_env, this_value, args);
        return .{ .value = wrap };
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
    const pending_str = realm.heap.allocateString("pending") catch return error.OutOfMemory;
    promise_obj.set(realm.allocator, "__cynic_promise_state__", Value.fromString(pending_str)) catch return error.OutOfMemory;
    promise_obj.set(realm.allocator, "__cynic_promise_value__", Value.undefined_) catch return error.OutOfMemory;
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
    while (frames.items.len > 0) {
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
                // §15.3 Arrow functions capture lexical `this` at
                // creation. Non-arrow `make_function` ignores this
                // slot — `this` comes from the call site.
                if (tmpl.is_arrow) fn_obj.captured_this = f.this_value;
                fn_obj.is_generator = tmpl.is_generator;
                fn_obj.is_async = tmpl.is_async;
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
                // §10.5 callable Proxy — when the callee is a
                // proxy whose `[[ProxyTarget]]` is a function,
                // unwrap to the target. Apply-trap dispatch is
                // later; today we just forward the call.
                var resolved_v = callee_v;
                if (heap_mod.valueAsPlainObject(callee_v)) |po| {
                    if (po.proxy_target_fn) |target_fn| resolved_v = heap_mod.taggedFunction(target_fn);
                }
                const callee_fn = heap_mod.valueAsFunction(resolved_v) orelse {
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
                    const wrap = if (callee_fn.is_async)
                        try wrapAsyncGenerator(allocator, realm, callee_chunk, callee_fn.captured_env, Value.undefined_, registers[args_start .. args_start + argc])
                    else
                        try wrapGenerator(allocator, realm, callee_chunk, callee_fn.captured_env, Value.undefined_, registers[args_start .. args_start + argc]);
                    acc = wrap;
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
                // §10.5 — unwrap callable Proxy.
                var resolved_v = callee_v;
                if (heap_mod.valueAsPlainObject(callee_v)) |po| {
                    if (po.proxy_target_fn) |target_fn| resolved_v = heap_mod.taggedFunction(target_fn);
                }
                const callee_fn = heap_mod.valueAsFunction(resolved_v) orelse {
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
                    const wrap = if (callee_fn.is_async)
                        try wrapAsyncGenerator(allocator, realm, callee_chunk, callee_fn.captured_env, recv, registers[args_start .. args_start + argc])
                    else
                        try wrapGenerator(allocator, realm, callee_chunk, callee_fn.captured_env, recv, registers[args_start .. args_start + argc]);
                    acc = wrap;
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
                // §10.5 — `new ProxyOfFn(...)` unwraps to the
                // function target. Construct trap is later.
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
                    const inst = realm.heap.allocateObject() catch return error.OutOfMemory;
                    inst.prototype = resolved_callee.prototype;
                    const this_v = heap_mod.taggedObject(inst);
                    const result = try callJSFunction(allocator, realm, resolved_callee, this_v, unwrapped.args);
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
                // Allocate the instance with [[Prototype]] = callee.prototype.
                const instance = realm.heap.allocateObject() catch return error.OutOfMemory;
                instance.prototype = callee_fn.prototype;
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
                    .home_object = callee_fn.home_object,
                    .argc = argc,
                }) catch {
                    allocator.free(callee_regs);
                    return error.OutOfMemory;
                };
            },

            .lda_this => {
                acc = f.this_value;
            },

            .instanceof_ => {
                const r = code[ip];
                ip += 1;
                const lhs = registers[r];
                const rhs = acc;
                // §13.10.2 — RHS must be callable; otherwise TypeError.
                const rhs_fn = heap_mod.valueAsFunction(rhs) orelse {
                    const ex = try makeTypeError(realm, "Right-hand side of instanceof is not callable");
                    f.ip = ip;
                    f.accumulator = acc;
                    committed = true;
                    if (!try unwindThrow(allocator, realm, frames, ex)) {
                        return .{ .thrown = ex };
                    }
                    continue;
                };
                // Walk LHS prototype chain looking for rhs.prototype.
                const target_proto = rhs_fn.prototype;
                if (target_proto == null) {
                    acc = Value.fromBool(false);
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
                ip += 1;
                const iter_v = registers[r];
                if (heap_mod.valueAsPlainObject(iter_v)) |iter_obj| {
                    const ret_v = iter_obj.get("return");
                    if (heap_mod.valueAsFunction(ret_v)) |ret_fn| {
                        // Spec wants errors here to propagate when the
                        // outer abrupt completion is `return`/`break`,
                        // and to be swallowed when it's a `throw`. We
                        // approximate "best effort" — swallow all
                        // errors so the surrounding break/return reaches
                        // its target. later: thread the completion
                        // through.
                        const saved_acc = acc;
                        _ = callJSFunction(allocator, realm, ret_fn, iter_v, &.{}) catch {};
                        if (realm.pending_exception != null) realm.pending_exception = null;
                        acc = saved_acc;
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
                if (obj.proxy_target != null) {
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
                                inst.private_properties.put(allocator, entry.name, heap_mod.taggedFunction(fn_obj)) catch return error.OutOfMemory;
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
                if (recv.private_properties.get(key_s.bytes)) |v| {
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
                gen.argc = f.argc;
                f.ip = ip;
                f.accumulator = acc;
                committed = true;
                return .{ .yielded = acc };
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
                    const state_v = obj.get("__cynic_promise_state__");
                    if (state_v.isString()) {
                        const s: *JSString = @ptrCast(@alignCast(state_v.asString()));
                        if (std.mem.eql(u8, s.bytes, "fulfilled")) {
                            acc = obj.get("__cynic_promise_value__");
                        } else if (std.mem.eql(u8, s.bytes, "rejected")) {
                            const ex = obj.get("__cynic_promise_value__");
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
                    error.NotIterable => {
                        const ex = try makeTypeError(realm, "value is not iterable");
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

            .for_in_open => {
                // §14.7.5.6 — snapshot the object's own + inherited
                // string keys into a fresh array iterator. `null` /
                // `undefined` produce an empty iterator.
                if (acc.isNull() or acc.isUndefined()) {
                    const empty = realm.heap.allocateObject() catch return error.OutOfMemory;
                    empty.prototype = realm.intrinsics.array_prototype;
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
                const result = loadModule(allocator, realm, spec_s.bytes, local_chunk.base_url) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    else => return error.InvalidOpcode,
                };
                // loadModule returns either the namespace
                // (success / cycle) or an exception value. For
                // the later scaffold, we treat any non-
                // object Value as a thrown exception.
                if (heap_mod.valueAsPlainObject(result) == null) {
                    f.ip = ip;
                    f.accumulator = acc;
                    committed = true;
                    if (!try unwindThrow(allocator, realm, frames, result)) {
                        return .{ .thrown = result };
                    }
                    continue;
                }
                acc = result;
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
                // implement); strict-mode unmapped is a plain object.
                const obj = realm.heap.allocateObject() catch return error.OutOfMemory;
                obj.prototype = realm.intrinsics.array_prototype;
                var i: u8 = 0;
                while (i < f.argc) : (i += 1) {
                    var ibuf: [16]u8 = undefined;
                    const islice = std.fmt.bufPrint(&ibuf, "{d}", .{i}) catch unreachable;
                    const owned = realm.heap.allocateString(islice) catch return error.OutOfMemory;
                    obj.set(allocator, owned.bytes, registers[i]) catch return error.OutOfMemory;
                }
                obj.set(allocator, "length", Value.fromInt32(@intCast(f.argc))) catch return error.OutOfMemory;
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
                if (!recv.private_properties.contains(key_s.bytes)) {
                    const ex = try makeTypeError(realm, "Cannot write private field — brand check failed");
                    f.ip = ip;
                    f.accumulator = acc;
                    committed = true;
                    if (!try unwindThrow(allocator, realm, frames, ex)) {
                        return .{ .thrown = ex };
                    }
                    continue;
                }
                recv.private_properties.put(allocator, key_s.bytes, acc) catch return error.OutOfMemory;
            },

            .super_call, .super_call_forward => {
                var args: []const Value = &.{};
                if (op == .super_call) {
                    const r_args = code[ip];
                    const argc = code[ip + 1];
                    ip += 2;
                    args = registers[r_args .. @as(usize, r_args) + argc];
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
                const outcome = try callJSFunction(allocator, realm, parent_fn, f.this_value, args);
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
                // Names are interned in the constant pool; the
                // pointer survives realm-lifetime so storing it
                // as the map key is safe. `put` upserts.
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
                    error.NotIterable => {
                        const ex = try makeTypeError(realm, "spread source is not iterable");
                        f.ip = ip;
                        f.accumulator = acc;
                        committed = true;
                        if (!try unwindThrow(allocator, realm, frames, ex)) {
                            return .{ .thrown = ex };
                        }
                        continue;
                    },
                };
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
                    if (toBoolean(result_obj.get("done"))) break;
                    const elem = result_obj.get("value");
                    var db: [24]u8 = undefined;
                    const ds = std.fmt.bufPrint(&db, "{d}", .{target_len}) catch unreachable;
                    const owned = realm.heap.allocateString(ds) catch return error.OutOfMemory;
                    target.set(allocator, owned.bytes, elem) catch return error.OutOfMemory;
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

                const len_v: Value = if (target_len >= std.math.minInt(i32) and target_len <= std.math.maxInt(i32))
                    Value.fromInt32(@intCast(target_len))
                else
                    Value.fromDouble(@floatFromInt(target_len));
                target.set(allocator, "length", len_v) catch return error.OutOfMemory;
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
                    if (obj.proxy_target != null) {
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
                    acc = fn_obj.get(key_s.bytes);
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
                    if (obj.proxy_target != null) {
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
                    // backing buffer.
                    if (obj.typed_view) |tv| {
                        if (std.fmt.parseInt(usize, key_slice, 10)) |idx| {
                            if (idx < tv.length) {
                                if (tv.viewed.array_buffer) |buf| {
                                    const elem_size = tv.kind.elementSize();
                                    acc = intrinsics_mod.readTypedElement(realm, buf, tv.kind, tv.byte_offset + idx * elem_size);
                                    continue;
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
                    acc = fn_obj.get(key_slice);
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
                // ordinary [[Set]] machinery; §23.2.4.6
                // SetTypedArrayFromArrayLike writes straight to
                // the backing buffer.
                if (heap_mod.valueAsPlainObject(recv)) |obj| {
                    if (obj.typed_view) |tv| {
                        if (std.fmt.parseInt(usize, key_slice, 10)) |idx| {
                            if (idx < tv.length) {
                                if (tv.viewed.array_buffer) |buf| {
                                    const elem_size = tv.kind.elementSize();
                                    intrinsics_mod.writeTypedElement(buf, tv.kind, tv.byte_offset + idx * elem_size, acc);
                                }
                            }
                            continue;
                        } else |_| {}
                    }
                }
                // Allocate a heap-owned copy of the key — the
                // scratch buffer is reused on every iteration.
                const owned = realm.heap.allocateString(key_slice) catch return error.OutOfMemory;
                {
                    const set_outcome = try strictSetProperty(allocator, realm, frames, f, ip, recv, owned.bytes, acc);
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
                    if (obj_in.proxy_target != null) {
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
                    if (obj_in.proxy_target != null) {
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
                    if (!returned_object) ret = f.this_value;
                }
                // §27.7 AsyncFunctionStart — an async function's
                // normal completion fulfils the Promise it
                // returns. A user-level `return v` inside an
                // async body becomes `Promise.resolve(v)` to the
                // caller. If `v` is itself a Promise we leave it
                // — the callback chain will handle the unwrap.
                if (f.wrap_return_in_promise) {
                    const already_promise =
                        if (heap_mod.valueAsPlainObject(ret)) |po|
                            po.get("__cynic_promise_state__").isString()
                        else
                            false;
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
pub fn lookupAccessor(obj: *JSObject, key: []const u8) ?@import("object.zig").Accessor {
    var cursor: ?*JSObject = obj;
    while (cursor) |c| : (cursor = c.prototype) {
        if (c.accessors.get(key)) |a| return a;
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
        return std.fmt.bufPrint(scratch, "{e}", .{d}) catch unreachable;
    }
    return std.fmt.bufPrint(scratch, "{d}", .{d}) catch unreachable;
}

/// §7.1.19 ToPropertyKey-ish coercion for computed key access.
/// Returns a slice that borrows from `scratch` for primitives and
/// from the original `JSString.bytes` for string keys. Caller
/// must not retain the slice past the next allocation that could
/// invalidate the JSString contents — at sta_computed sites we
/// re-allocate before storing.
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
    _ = obj_mod;
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
    if (heap_mod.valueAsPlainObject(recv)) |obj_in| {
        // §10.5 Proxy [[Set]] — if `recv` is a proxy exotic,
        // dispatch through `handler.set` before falling back to
        // the target's default setter logic.
        var obj = obj_in;
        if (obj.proxy_target != null) {
            const r = try proxySetTrap(allocator, realm, frames, f, ip, obj, key, value, recv);
            switch (r) {
                .value => return .ok,
                .fallthrough => |t| obj = t,
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
        const ok = obj.setIfWritable(allocator, key, value) catch return error.OutOfMemory;
        if (!ok) {
            const ex = try makeTypeError(realm, "Cannot assign to read-only property");
            return throwInSetter(realm, frames, f, ip, value, ex);
        }
        return .ok;
    }
    if (heap_mod.valueAsFunction(recv)) |fn_obj| {
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
    const target = proxy.proxy_target orelse return .{ .fallthrough = proxy };
    const handler = proxy.proxy_handler orelse return .{ .fallthrough = target };
    const trap_v = handler.get("get");
    const trap_fn = heap_mod.valueAsFunction(trap_v) orelse return .{ .fallthrough = target };
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
    const target = proxy.proxy_target orelse return .{ .fallthrough = proxy };
    const handler = proxy.proxy_handler orelse return .{ .fallthrough = target };
    const trap_v = handler.get("deleteProperty");
    const trap_fn = heap_mod.valueAsFunction(trap_v) orelse return .{ .fallthrough = target };
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
    const target = proxy.proxy_target orelse return .{ .fallthrough = proxy };
    const handler = proxy.proxy_handler orelse return .{ .fallthrough = target };
    const trap_v = handler.get("has");
    const trap_fn = heap_mod.valueAsFunction(trap_v) orelse return .{ .fallthrough = target };
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
    const target = proxy.proxy_target orelse return .{ .fallthrough = proxy };
    const handler = proxy.proxy_handler orelse return .{ .fallthrough = target };
    const trap_v = handler.get("set");
    const trap_fn = heap_mod.valueAsFunction(trap_v) orelse return .{ .fallthrough = target };
    const key_str = realm.heap.allocateString(key) catch return error.OutOfMemory;
    const args = [_]Value{ heap_mod.taggedObject(target), Value.fromString(key_str), value, receiver };
    const outcome = try callJSFunction(allocator, realm, trap_fn, heap_mod.taggedObject(handler), &args);
    switch (outcome) {
        .value, .yielded => |v| {
            if (!arith.toBoolean(v)) {
                const ex = try makeTypeError(realm, "'set' on proxy returned falsy");
                f.ip = ip;
                if (!try unwindThrow(allocator, realm, frames, ex)) {
                    return .{ .uncaught = ex };
                }
                return .handled;
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
fn arrayLengthCoerce(v: Value) ?u32 {
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
const TruncateResult = struct {
    final_length: u32,
    blocked: bool,
};

/// §10.4.2.4 step 16-17 — walk own integer-indexed properties in
/// descending order, deleting each whose index is `>= target_len`.
/// On a non-configurable element, stop and return its index + 1
/// as the floor.
fn truncateArrayAtLength(allocator: std.mem.Allocator, obj: *JSObject, target_len: u32) TruncateResult {
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

