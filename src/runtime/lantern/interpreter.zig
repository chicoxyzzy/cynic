//! **Lantern** — Cynic's T0 bytecode interpreter. Hosts the
//! switch-dispatched `runFrames` loop plus the top-level entry
//! points (`run`, `evaluateScript`) and the inline dispatch
//! helpers (`decodeNext`, `reEnterDispatch`, `runSafePoint`,
//! `intArith` / `intCompare` / `intBitwise`).
//!
//! Reads a `Chunk` produced by the bytecode compiler and runs it
//! against a `Realm`'s heap. The dispatch loop is a single
//! `while` + labeled `switch` with `continue :dispatch <next>` at
//! each arm — emits a separate indirect branch per arm so the
//! branch predictor learns per-opcode-pair patterns (the
//! computed-goto equivalent that V8 Ignition / JSC LLInt use).
//!
//! Numeric arithmetic uses an int32 fast path when both operands
//! are Smis and the result also fits. Mixed-type and overflow
//! paths fall back to f64 doubles, matching the spec's Number
//! semantics (§6.1.6.1). String concatenation in `+` is the only
//! non-numeric arithmetic shortcut; every other operator coerces
//! non-numbers via `ToNumber`.
//!
//! ## Siblings in this directory
//!
//! - `arith.zig`      — numeric coercion + arithmetic helpers
//! - `call.zig`       — callValue / callJSFunction / constructValue
//!                      / unwrapBoundCall / startAsyncCall
//! - `generator.zig`  — wrapGenerator / wrapAsyncGenerator
//!                      / asyncGen* request pump
//! - `promise.zig`    — drainMicrotasks / settlePromiseInternal
//!                      / resolvePromiseWithValue / async-resume
//! - `iterator.zig`   — openIterator family + openForInIterator
//! - `module.zig`     — loadModule + the §16.2.1.5 pipeline
//! - `helpers.zig`    — accessor lookup, double formatting,
//!                      array-length coercion + truncation, error
//!                      makers
//! - `tests.zig`      — the unit test suite
//!
//! Public surface from siblings is re-exported below as
//! `pub const X = sibling.X;` so the dispatch loop and external
//! callers (built-ins, the wasm host) keep reaching them through
//! `lantern.X(...)` or by bare name inside this file.

const std = @import("std");

const Value = @import("../value.zig").Value;
const JSString = @import("../string.zig").JSString;
const utf16 = @import("../utf16.zig");
const JSFunction = @import("../function.zig").JSFunction;
const object_mod = @import("../object.zig");
const JSObject = object_mod.JSObject;
const Environment = @import("../environment.zig").Environment;
const heap_mod = @import("../heap.zig");
const intrinsics_mod = @import("../intrinsics.zig");
const Realm = @import("../realm.zig").Realm;
const Op = @import("../../bytecode/op.zig").Op;
const chunk_mod = @import("../../bytecode/chunk.zig");
const bistromath = @import("../bistromath/bistromath.zig");
const Chunk = chunk_mod.Chunk;
const Handler = chunk_mod.Handler;
const scope_mod = @import("../../bytecode/scope.zig");
const parser_mod = @import("../../parser/parser.zig");
const compiler_mod = @import("../../bytecode/compiler.zig");
const module_mod = @import("../module.zig");

// Arithmetic / coercion helpers live in `arith.zig`. Pull every
// fn the dispatch loop calls into local aliases so callsites
// stay short.
const arith = @import("arith.zig");

// Standalone helpers live in `helpers.zig` — accessor lookup,
// double formatting, array-length coercion + truncation, error
// makers. Re-exported `pub const`s so external callers
// (`lantern.makeTypeError` from built-ins, etc.) keep working, and
// dispatch-loop callsites can use the bare names.
const helpers = @import("helpers.zig");
pub const consumePendingException = helpers.consumePendingException;
pub const lookupAccessor = helpers.lookupAccessor;
pub const lookupFunctionAccessor = helpers.lookupFunctionAccessor;
pub const formatDoubleSafe = helpers.formatDoubleSafe;
pub const isCanonicalNumericIndexString = helpers.isCanonicalNumericIndexString;
const computedKeyToString = helpers.computedKeyToString;
const canonicalIntegerIndexInterp = helpers.canonicalIntegerIndexInterp;
pub const arrayLengthCoerceSpec = helpers.arrayLengthCoerceSpec;
pub const arrayLengthCoerce = helpers.arrayLengthCoerce;
pub const truncateArrayAtLength = helpers.truncateArrayAtLength;
pub const TruncateResult = helpers.TruncateResult;
pub const makeTypeError = helpers.makeTypeError;
pub const makeRangeError = helpers.makeRangeError;
pub const makeSyntaxError = helpers.makeSyntaxError;
pub const makeEvalError = helpers.makeEvalError;

// Generator + async-generator machinery lives in `generator.zig`.
// Re-export the public entry points so the dispatch loop and
// built-ins reach them as `lantern.wrapGenerator(...)` etc., and
// dispatch-loop callsites can use the bare names.
const generator = @import("generator.zig");
pub const wrapGenerator = generator.wrapGenerator;
pub const wrapAsyncGenerator = generator.wrapAsyncGenerator;
pub const iteratorPrototypeOrObjectPrototypePub = generator.iteratorPrototypeOrObjectPrototypePub;
pub const ensureGeneratorPrototype = generator.ensureGeneratorPrototype;
pub const ensureAsyncIteratorPrototype = generator.ensureAsyncIteratorPrototype;
pub const ensureAsyncGeneratorPrototype = generator.ensureAsyncGeneratorPrototype;
pub const wrapAsyncGenResult = generator.wrapAsyncGenResult;
// Private aliases — used by the drainMicrotasks task dispatch and
// related async-gen plumbing still in this file.
const asyncGeneratorResumeNext = generator.asyncGeneratorResumeNext;
const resumeAsyncGenBody = generator.resumeAsyncGenBody;
const settleAsyncGenRequest = generator.settleAsyncGenRequest;
const rejectAsyncGenRequest = generator.rejectAsyncGenRequest;
const isSyncRejectedPromise = generator.isSyncRejectedPromise;
const genResultObject = generator.genResultObject;

// Promise + async-function resumption + microtask drain live in
// `promise.zig`. Re-export the public surface so dispatch-loop
// callsites use bare names and built-ins reach them as
// `lantern.drainMicrotasks(...)` etc.
const promise = @import("promise.zig");
pub const wrapInPromise = promise.wrapInPromise;
pub const drainMicrotasks = promise.drainMicrotasks;
pub const fireExpiredAsyncWaits = promise.fireExpiredAsyncWaits;
pub const resolvePromiseWithValue = promise.resolvePromiseWithValue;
pub const resumeAsyncFunction = promise.resumeAsyncFunction;
pub const resumeAsyncGeneratorOnSettle = promise.resumeAsyncGeneratorOnSettle;
pub const settlePromiseInternal = promise.settlePromiseInternal;
pub const resumeGenerator = promise.resumeGenerator;
pub const isVanillaPromiseChainExported = promise.isVanillaPromiseChainExported;

// Call + construct machinery lives in `call.zig`. Re-export the
// public entry points so dispatch-loop callsites use bare names
// and built-ins reach them as `lantern.callJSFunction(...)`.
const call = @import("call.zig");
pub const unwrapBoundCall = call.unwrapBoundCall;
pub const callValue = call.callValue;
pub const getPrototypeFromConstructorValue = call.getPrototypeFromConstructorValue;
pub const getPrototypeFromConstructor = call.getPrototypeFromConstructor;
pub const baseConstructIntrinsicDefaultProto = call.baseConstructIntrinsicDefaultProto;
pub const baseConstructDefaultProtoOwner = call.baseConstructDefaultProtoOwner;
pub const constructValue = call.constructValue;
pub const callJSFunction = call.callJSFunction;
pub const callJSFunctionAsSuper = call.callJSFunctionAsSuper;
pub const startAsyncCall = call.startAsyncCall;

// Iterator opening + for-in walker live in `iterator.zig`.
// Re-export the public surface; the dispatch loop's `iter_open`
// / `for_in_open` opcodes and built-ins call these by bare name
// or `lantern.openIterator(...)`.
const iter_mod = @import("iterator.zig");
pub const IterError = iter_mod.IterError;
pub const OpenIterOpts = iter_mod.OpenIterOpts;
pub const openIterator = iter_mod.openIterator;
pub const openIteratorAllowArrayLike = iter_mod.openIteratorAllowArrayLike;
pub const openIteratorOpts = iter_mod.openIteratorOpts;
pub const openAsyncIterator = iter_mod.openAsyncIterator;
pub const openForInIterator = iter_mod.openForInIterator;

// Module loading lives in `module.zig`. Re-export the public
// surface; the dispatch loop's `module_load` / `dynamic_import`
// opcodes and the wasm host call `lantern.loadModule(...)`.
const module_load = @import("module.zig");
pub const LoadModuleOutcome = module_load.LoadModuleOutcome;
pub const loadModule = module_load.loadModule;
const mergeStarKey = module_load.mergeStarKey;

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
const unaryToNumeric = arith.unaryToNumeric;
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

// ── Native re-entry stack guard ─────────────────────────────────────
//
// `max_call_frames` bounds the *JS* frame stack within ONE `runFrames`
// dispatch (direct `f()` calls append to the same `frames` list). But
// a native builtin that calls back into JS — an accessor getter, a
// `.map` / `.forEach` callback, `Reflect.apply`, a Proxy trap, a
// promise reaction drain — re-enters through `callJSFunction`, which
// starts a FRESH `runFrames` on a fresh native stack frame. That
// nesting is bounded by the shared address-based stack guard
// (`stack_guard.nearLimit`), which `runFrames` consults at entry and,
// when within the red zone, throws `RangeError("Maximum call stack
// size exceeded")` instead of letting the host stack overflow. The
// same primitive bounds the JSON parser and the AST parser — see
// `src/stack_guard.zig` for the bounds strategy (macOS + Linux exact
// thread bounds; a growth heuristic elsewhere). `runFrames` entry is
// per-native-re-entry (NOT per JS call — those stay in the dispatch
// loop), so the check is off the hot path.
const stack_guard = @import("../../stack_guard.zig");

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
    /// Heap cell mirroring `super_called`, allocated lazily on the
    /// first arrow `make_function` inside a derived-ctor frame and
    /// shared with every arrow made thereafter. A `super(...)`
    /// performed via the arrow — including from a fresh
    /// `runFrames` re-entry where the outer ctor frame isn't
    /// reachable on the stack — flips this cell. The Return-from-
    /// ctor gate ORs `super_called` with `super_called_cell.*`.
    /// `null` for non-derived-ctor frames and ctor bodies that
    /// never create an arrow.
    super_called_cell: ?*bool = null,
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
    /// arg list without parsing rest params. u32: apply / spread
    /// arg counts are dynamic (§10.4.4 `arguments.length` reflects
    /// the actual count), so the field must not saturate at the
    /// call opcodes' u8 operand range.
    argc: u32 = 0,
    /// The generator that owns this frame, if running a
    /// `function*` body. Set on resume; null for ordinary
    /// frames. When `gen_yield` fires, the dispatch loop saves
    /// state into this generator and unwinds the loop.
    generator: ?*@import("../generator.zig").JSGenerator = null,
    /// Whether `Return` should free `registers`. Generators own
    /// their register file separately, so the dispatch loop
    /// must not free it on Return.
    owns_registers: bool = true,
    /// Whether `registers` was acquired from `realm.value_stack`
    /// (the bump-allocated register-file stack) rather than
    /// `realm.frame_pool` (the heap-backed sized-bin free list).
    /// True only when the call-site path chose the stack and the
    /// `allocStackRegisters` request succeeded — generators,
    /// async functions, and bound-target / proxy / callJSFunction
    /// re-entries all stay on the pool. The Return / unwind
    /// paths branch on this via `releaseFrameRegisters`.
    is_stack_alloc: bool = false,

    /// Set on calls to `async function` bodies. The Return op
    /// wraps the returned value in `Promise.resolve(...)` and
    /// uncaught throws in `Promise.reject(...)` so the caller
    /// observes a Promise — the spec's §27.7 AsyncFunctionStart.
    wrap_return_in_promise: bool = false,
    /// §10.4.1 GetActiveScriptOrModule — the ModuleRecord this
    /// frame belongs to, copied from the callee
    /// `JSFunction.owning_module` at frame entry. Read by the
    /// `import_meta` opcode so a function exported from module
    /// A and invoked from module B's body still resolves
    /// `import.meta` to A's module record (test262
    /// `language/expressions/import.meta/distinct-for-each-module.js`).
    /// `null` for script-goal frames and engine-synthesised
    /// frames whose body never references `import.meta`; the
    /// `import_meta` op falls back to `realm.current_module`
    /// when this is unset (matches the legacy module-body case).
    owning_module: ?*@import("../module.zig").ModuleRecord = null,
    /// §9.4 — the [[Realm]] of the function executing in this
    /// frame, copied from the callee `JSFunction.realm` at frame
    /// entry. This is the running execution context's Realm Record:
    /// the dispatch loop's `realm` parameter is fixed for a whole
    /// `runFrames` session and does NOT switch when a function from
    /// another realm is invoked inline, so an abstract operation
    /// that must throw "in the current Realm" (e.g. §10.5.12
    /// [[Call]] step 1 ValidateNonRevokedProxy, which throws before
    /// any execution context is pushed) reads it here rather than
    /// from the active `realm`. `null` for script-goal frames and
    /// engine-synthesised frames; readers fall back to the active
    /// `realm` (correct when the running function shares its realm,
    /// which is every single-realm program).
    running_realm: ?*@import("../realm.zig").Realm = null,

    /// Release a frame's register file via the right helper for
    /// its storage. Generators leave `owns_registers = false`
    /// because the generator object outlives the frame and owns
    /// the slice; for those this is a no-op. Stack-allocated
    /// frames pop from `realm.value_stack` (LIFO); pool-allocated
    /// frames return to `realm.frame_pool`. Every frame-cleanup
    /// site (Return, unwind, error-path frame drain) routes
    /// through here so the storage choice stays a single-line
    /// branch local to this helper.
    pub fn releaseRegisters(self: *const CallFrame, realm: *Realm, allocator: std.mem.Allocator) void {
        if (!self.owns_registers) return;
        if (self.is_stack_alloc) {
            realm.freeStackRegisters(self.registers);
        } else {
            realm.frame_pool.release(allocator, self.registers);
        }
    }
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
    /// The await path also funnels through this variant with
    /// `Value.undefined_`; the async-gen drain distinguishes
    /// the two by inspecting the gen's `async_state` (an await
    /// path transitions it to `.suspended_await` before
    /// unwinding; a real yield leaves it as `.executing`).
    yielded: Value,
};

pub const EvaluateError = error{
    OutOfMemory,
    ParseError,
    /// A parse-phase diagnostic whose `Code.errorClass()` is
    /// `range_error` rather than `syntax_error` — currently only
    /// `too_deeply_nested` (stack-exhausting source). Distinguished
    /// from `ParseError` so the eval entry points throw the
    /// RangeError V8 / JSC give for deeply nested eval source,
    /// consistent with the diagnostic's class (the test262 scoring
    /// path reads `errorClass()` directly, so this keeps the eval
    /// runtime path in agreement with it).
    ParseRangeError,
    CompileError,
    InvalidOpcode,
};

/// Classify an error-severity parse-diagnostic list into the
/// matching `EvaluateError`. A `range_error`-class code (deeply
/// nested source) becomes `ParseRangeError`; everything else (the
/// SyntaxError family) becomes `ParseError`. Returns `null` when no
/// error-severity diagnostic is present (the caller proceeds).
fn classifyParseDiagnostics(diags: []const @import("../../diagnostic.zig").Diagnostic) ?EvaluateError {
    var result: ?EvaluateError = null;
    for (diags) |d| {
        if (d.severity != .err) continue;
        if (d.code.errorClass() == .range_error) return error.ParseRangeError;
        result = error.ParseError;
    }
    return result;
}

/// §15.7.14 step 31 PrivateBoundIdentifiers — every evaluation of
/// a ClassTail allocates a fresh `[[PrivateBrand]]`. The compiler
/// bakes a class-source-unique prefix (`"P{class_uid}#"`) into
/// every private key constant, but the brand identity must be
/// per-evaluation: two `f()` invocations of a class factory
/// produce classes with different brands, so `A.read(new B())`
/// throws TypeError per §7.3.27 PrivateElementFind.
///
/// At install time `class.zig` stamps the per-evaluation prefix
/// (`"B{n}#"`) on `proto.getPrivateBrand()` and `ctor.getPrivateBrand()`,
/// and keys every private slot by that runtime prefix. At lookup
/// time, this helper rewrites the compile-time-mangled key
/// (`"P0#x"`) into the runtime key (`"B7#x"`) by stripping
/// everything up to and including `#` and prepending the brand.
///
/// `brand` is the executing method's `home_object.getPrivateBrand()`
/// (instance method / constructor) or `home_function.getPrivateBrand()`
/// (static method). When neither is set — e.g. private syntax
/// reached outside a class body, which the parser already rejects —
/// the original key is returned unchanged and the slot lookup
/// fails naturally with the spec-mandated brand-check TypeError.
///
/// Writes into the caller's stack buffer; returns a slice into it.
/// 64 bytes accommodates a 4-digit brand counter and a 60-byte
/// private name (anything realistic — JS identifiers are usually
/// under 30 chars).
fn translatePrivateKey(buf: []u8, key: []const u8, brand: []const u8) []const u8 {
    if (brand.len == 0) return key;
    const hash_idx = std.mem.indexOfScalar(u8, key, '#') orelse return key;
    const suffix = key[hash_idx + 1 ..];
    if (brand.len + suffix.len > buf.len) return key;
    @memcpy(buf[0..brand.len], brand);
    @memcpy(buf[brand.len .. brand.len + suffix.len], suffix);
    return buf[0 .. brand.len + suffix.len];
}

/// §15.7.14 step 31 — pull the per-ClassTail-evaluation brand
/// prefix relevant to a private access. Tried in order:
///   1. `f.home_object.getPrivateBrand()` — instance method body,
///      field initializer, derived ctor.
///   2. `f.home_function.getPrivateBrand()` — static method body.
///   3. Walk the receiver's prototype chain (for the common case
///      where a plain inner function in a method does
///      `obj.#field`: the inner function has no `home_*`, but the
///      receiver's proto carries the class's brand — see the
///      `*-access-on-inner-function.js` fixture family).
///   4. If the receiver itself is the class constructor (static-
///      private access through `C.#x` from an inner function),
///      its `private_brand` is the right answer.
/// Returns "" when nothing matches — `translatePrivateKey` then
/// falls through to the compile-time key and the lookup fails
/// with the spec-mandated brand-check TypeError.
fn framePrivateBrand(f: anytype, recv_hint: Value, key: []const u8) []const u8 {
    // §15.7.14 step 11 — the key has shape `"P{n}#name"`. Match
    // the `"P{n}#"` prefix against `private_compile_prefix` on
    // each candidate so we route to the brand for the *declaring*
    // class, not just any brand in scope. This is what makes a
    // nested-class method that references the outer class's `#x`
    // resolve correctly — the receiver's proto chain reaches the
    // outer prototype where compile_prefix matches.
    const hash_idx = std.mem.indexOfScalar(u8, key, '#');
    const key_prefix: []const u8 = if (hash_idx) |hi| key[0 .. hi + 1] else "";
    if (key_prefix.len > 0) {
        if (f.home_object) |home| {
            if (std.mem.eql(u8, home.getPrivateCompilePrefix(), key_prefix) and home.getPrivateBrand().len > 0) return home.getPrivateBrand();
        }
        if (f.home_function) |home_fn| {
            if (std.mem.eql(u8, home_fn.getPrivateCompilePrefix(), key_prefix) and home_fn.getPrivateBrand().len > 0) return home_fn.getPrivateBrand();
        }
        if (heap_mod.valueAsPlainObject(recv_hint)) |obj| {
            var cur: ?*JSObject = obj.prototype;
            while (cur) |c| {
                if (std.mem.eql(u8, c.getPrivateCompilePrefix(), key_prefix) and c.getPrivateBrand().len > 0) return c.getPrivateBrand();
                cur = c.prototype;
            }
        }
        if (heap_mod.valueAsFunction(recv_hint)) |fn_obj| {
            if (std.mem.eql(u8, fn_obj.getPrivateCompilePrefix(), key_prefix) and fn_obj.getPrivateBrand().len > 0) return fn_obj.getPrivateBrand();
        }
    }
    // Legacy fallback: first brand found anywhere — preserves the
    // pre-§15.7.14-step-11 behavior for keys with no `#` and for
    // brand-check-failure paths where no compile_prefix matches.
    // The brand lookup is best-effort; the slot lookup will throw
    // the spec-mandated TypeError if no match exists.
    if (f.home_object) |home| {
        if (home.getPrivateBrand().len > 0) return home.getPrivateBrand();
    }
    if (f.home_function) |home_fn| {
        if (home_fn.getPrivateBrand().len > 0) return home_fn.getPrivateBrand();
    }
    if (heap_mod.valueAsPlainObject(recv_hint)) |obj| {
        var cur: ?*JSObject = obj.prototype;
        while (cur) |c| {
            if (c.getPrivateBrand().len > 0) return c.getPrivateBrand();
            cur = c.prototype;
        }
    }
    if (heap_mod.valueAsFunction(recv_hint)) |fn_obj| {
        if (fn_obj.getPrivateBrand().len > 0) return fn_obj.getPrivateBrand();
    }
    return "";
}

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
    return evaluateSource(allocator, realm, source, false, false, false);
}

/// §3.8.3.7 PerformShadowRealmEval — evaluate `source` as **Script**
/// code against `realm` (used by `ShadowRealm.prototype.evaluate`).
/// Like `evaluateScript`, but top-level lexical declarations bind in a
/// fresh per-call declarative environment so repeated calls don't
/// collide. Top-level `var` / function declarations still bind on the
/// shadow realm's global env and persist across `evaluate` calls
/// (varEnv = [[GlobalEnv]]). NOT strict-eval var isolation — that's
/// `evaluateIndirectEval`. Free references resolve against the realm's
/// globals.
pub fn evaluateEval(
    allocator: std.mem.Allocator,
    realm: *Realm,
    source: []const u8,
) EvaluateError!RunResult {
    return evaluateSource(allocator, realm, source, true, false, false);
}

/// §19.2.1.1 — evaluate `source` as **indirect eval** code against
/// `realm`. strictEval is determined by the body (§19.2.1): a body
/// with a Use Strict Directive is a strict eval whose top-level `var` /
/// function declarations bind in the eval's own variable environment;
/// a non-strict body binds them on the realm's GLOBAL env (subject to
/// §9.1.1.4.15/.16 CanDeclareGlobalVar / CanDeclareGlobalFunction).
/// Free references resolve against the realm's globals either way.
pub fn evaluateIndirectEval(
    allocator: std.mem.Allocator,
    realm: *Realm,
    source: []const u8,
) EvaluateError!RunResult {
    // Indirect eval: `eval_local` is recomputed from the body's
    // strictness inside `evaluateSource` (the `indirect` flag).
    return evaluateSource(allocator, realm, source, true, true, true);
}

/// §19.2.1 direct eval — the caller-frame context the `direct_eval`
/// opcode hands to `evaluateDirectEval` so the eval'd code inherits
/// the running execution context (§19.2.1 steps 6-13): the caller's
/// `this`, `new.target`, home object, and — via `parent_env` — its
/// lexical environment, so free identifiers resolve against the
/// caller's locals.
pub const DirectEvalContext = struct {
    this_value: Value,
    new_target: Value,
    home_object: ?*JSObject,
    home_function: ?*JSFunction,
    running_realm: ?*Realm,
    owning_module: ?*module_mod.ModuleRecord,
    /// The caller's innermost lexical environment. The eval body's
    /// own environment (its leading `make_environment`) is allocated
    /// as a child of this, so `lda_env [depth]` from eval'd code
    /// walks into the caller's env chain.
    parent_env: ?*Environment,
    is_derived_ctor: bool,
    super_called_cell: ?*bool,
};

/// §19.2.1 PerformEval for a *direct* eval. Compiles `source` as eval
/// code whose free references resolve against the caller's lexical
/// environment (reconstructed from `snapshot`), then runs it in a
/// fresh frame that inherits the caller's `this` / `new.target` / home
/// and whose environment is parented to the caller's (`ctx.parent_env`).
/// Cynic is strict-only, so this is always a strict eval (§19.2.1.3):
/// the eval body's own `var` / `let` bind in its own environment and
/// don't leak into the caller's scope.
pub fn evaluateDirectEval(
    allocator: std.mem.Allocator,
    realm: *Realm,
    source: []const u8,
    snapshot: *const chunk_mod.DirectEvalScope,
    ctx: DirectEvalContext,
) EvaluateError!RunResult {
    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    // Retain a realm-lifetime copy of the source — the compiled chunk
    // lands in `script_chunks` and its function templates borrow
    // slices for `Function.prototype.toString`.
    const stable = try realm.retainEvalSource(source);

    // §19.2.1.1 — mirror the running execution context's super /
    // new.target permission and PrivateEnvironment into the eval-body
    // parse. `super.x` is grammatically valid iff the caller frame has a
    // [[HomeObject]] (a class method / field / static block, or an object-
    // literal method); `super(...)` iff it's a derived constructor;
    // `new.target` iff inside a function-like body — detected here via the
    // home / derived-ctor state (a plain function direct eval keeps the
    // pre-existing behavior of disallowing `new.target`). The inherited
    // PrivateEnvironment names come from the compile-time class-context
    // snapshot.
    const has_home = ctx.home_object != null or ctx.home_function != null;
    // §15.8.1 — the AllPrivateNamesValid pass compares PrivateIdentifier
    // references by their full `#name` StringValue, so re-attach the `#`
    // the compiler's stored prefix-stripped names dropped.
    var private_names_buf: std.ArrayListUnmanaged([]const u8) = .empty;
    for (snapshot.class_contexts) |cc| {
        for (cc.private_names) |n| {
            const hashed = std.fmt.allocPrint(aa, "#{s}", .{n}) catch return error.OutOfMemory;
            private_names_buf.append(aa, hashed) catch return error.OutOfMemory;
        }
    }

    const diag_mod = @import("../../diagnostic.zig");
    var diags: diag_mod.Diagnostics = .empty;
    const program = parser_mod.parseDirectEval(aa, stable, &diags, .{
        .allow_super_property = has_home,
        .allow_super_call = ctx.is_derived_ctor,
        .allow_new_target = has_home or ctx.is_derived_ctor or snapshot.in_function_code,
        .private_names = private_names_buf.items,
        // §sec-performeval-rules-in-initializer — when the call site is a
        // class field initializer / static block, the eval body rejects
        // (SyntaxError) if ContainsArguments of its StatementList is true.
        .in_field_initializer = snapshot.in_field_initializer,
    }) catch return error.ParseError;
    if (classifyParseDiagnostics(diags.items)) |e| return e;

    // Rebuild the caller's visible env-slot bindings as a synthetic
    // outer scope (parent = null). Each binding keeps its original
    // env_depth / env_slot so `lda_env`'s depth arithmetic reaches the
    // right runtime environment. Allocated on the parse arena — only
    // needed during compilation, not at runtime.
    var caller_scope: scope_mod.Scope = .{ .parent = null, .kind = .function };
    for (snapshot.bindings) |b| {
        caller_scope.bindings.append(aa, .{
            .name = b.name,
            .env_slot = b.env_slot,
            .env_depth = b.env_depth,
            .kind = b.kind,
            .span = .{ .start = 0, .end = 0 },
            .is_fn_expr_name = b.is_fn_expr_name,
            .is_using = b.is_using,
        }) catch return error.OutOfMemory;
    }

    const chunk_ptr = try realm.allocator.create(Chunk);
    chunk_ptr.* = compiler_mod.compileDirectEvalAsChunk(
        realm.allocator,
        realm,
        &program,
        stable,
        null,
        &caller_scope,
        // The eval body's env sits one level below the caller's
        // innermost env at runtime. Saturating add guards the
        // pathological 255-deep nesting case.
        snapshot.caller_env_depth +| 1,
        // §19.2.1.1 — the inherited PrivateEnvironment chain so
        // `this.#x` mangles against the enclosing method's prefixes.
        snapshot.class_contexts,
    ) catch {
        realm.allocator.destroy(chunk_ptr);
        return error.CompileError;
    };
    try realm.script_chunks.append(realm.allocator, chunk_ptr);

    var frames: std.ArrayListUnmanaged(CallFrame) = .empty;
    defer {
        for (frames.items) |*fr| fr.releaseRegisters(realm, allocator);
        frames.deinit(allocator);
    }
    const main_regs = try realm.frame_pool.acquire(allocator, chunk_ptr.register_count);
    @memset(main_regs, Value.undefined_);
    try frames.append(allocator, .{
        .chunk = chunk_ptr,
        .ip = 0,
        .accumulator = Value.undefined_,
        .registers = main_regs,
        // Pre-seed the caller's env so the eval body's leading
        // `make_environment` chains its fresh env to the caller's.
        .env = ctx.parent_env,
        .this_value = ctx.this_value,
        .new_target = ctx.new_target,
        .home_object = ctx.home_object,
        .home_function = ctx.home_function,
        .running_realm = ctx.running_realm,
        .owning_module = ctx.owning_module,
        .is_derived_ctor = ctx.is_derived_ctor,
        .super_called_cell = ctx.super_called_cell,
        .argc = 0,
    });
    return runFrames(allocator, realm, &frames);
}

/// True when `program`'s directive prologue contains a Use Strict
/// Directive — §11.2.2 / the body of an indirect eval is a strict eval
/// (§19.2.1) iff this holds. `source` is the text the directive spans
/// index into.
fn programHasUseStrict(program: anytype, source: []const u8) bool {
    for (program.body) |s| {
        switch (s) {
            .expression => |es| {
                // A directive is an ExpressionStatement whose sole
                // expression is a StringLiteral; the prologue ends at
                // the first non-directive statement.
                const dir = es.directive orelse return false;
                const text = std.mem.trim(u8, source[dir.start..dir.end], "\"'");
                if (std.mem.eql(u8, text, "use strict")) return true;
            },
            else => return false,
        }
    }
    return false;
}

fn evaluateSource(
    allocator: std.mem.Allocator,
    realm: *Realm,
    source: []const u8,
    eval_scope: bool,
    /// §19.2.1.3 — when `eval_scope` is set, whether this is a strict
    /// eval (var / function bind eval-locally) vs ShadowRealm-style
    /// Script evaluation (var → global). Ignored when `!eval_scope`.
    /// For an indirect eval (`indirect`), this is recomputed from the
    /// body's strictness after parsing.
    eval_local: bool,
    /// §19.2.1 indirect eval: strictEval is determined by the body's
    /// Use Strict Directive, not the caller. A non-strict body's
    /// top-level `var` / function declarations bind on the global env
    /// (`eval_local = false`); a strict body keeps them eval-local.
    indirect: bool,
) EvaluateError!RunResult {
    var arena: std.heap.ArenaAllocator = .init(allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    // Collect parser diagnostics so a recoverable-but-error-severity
    // condition (e.g. §B.1.1 LegacyOctalIntegerLiteral in strict
    // mode, an early SyntaxError the parser detects after building
    // a usable AST) surfaces as `error.ParseError` instead of
    // silently running the (semantically broken) program. The
    // test262 harness applies the same `hasErrorSeverity` check
    // at its own parse site.
    const diag_mod = @import("../../diagnostic.zig");
    var diags: diag_mod.Diagnostics = .empty;
    const program = parser_mod.parseScript(aa, source, &diags) catch return error.ParseError;
    if (classifyParseDiagnostics(diags.items)) |e| return e;
    // §19.2.1 — an indirect eval is a strict eval iff its body carries
    // a Use Strict Directive. A non-strict body binds top-level `var` /
    // function on the global env (`eval_local = false`); a strict body
    // keeps them eval-local.
    const effective_local = if (indirect) programHasUseStrict(&program, source) else eval_local;
    // §19.2.1.3 steps 15.c.i / 16.a.i — a non-strict indirect eval's
    // top-level `var` / function bind on the global env with D=true
    // (deletable / configurable). ShadowRealm Script evaluation
    // (`!indirect`) keeps §16.1.7's D=false.
    const deletable_global = indirect and !effective_local;
    // The chunk is owned by the realm so that any `JSFunction`
    // declared by this script (which keeps a pointer into the
    // chunk's `function_templates`) outlives the call and stays
    // callable from later `evaluateScript` invocations against
    // the same realm. Heap-allocated so its address is stable
    // across `script_chunks` array growth.
    const chunk_ptr = try realm.allocator.create(Chunk);
    chunk_ptr.* = (if (eval_scope)
        compiler_mod.compileEvalAsChunk(realm.allocator, realm, &program, source, null, effective_local, deletable_global)
    else
        compiler_mod.compileScriptAsChunk(realm.allocator, realm, &program, source, null)) catch {
        realm.allocator.destroy(chunk_ptr);
        return error.CompileError;
    };
    try realm.script_chunks.append(realm.allocator, chunk_ptr);
    // (chunk constants pinned inside the compile entry above)
    return run(allocator, realm, chunk_ptr);
}

/// Run `chunk` to completion. Allocates per-frame register
/// files; the host's `allocator` owns them and they're freed on
/// each `Return` (or on overall run shutdown).
pub fn run(allocator: std.mem.Allocator, realm: *Realm, chunk: *const Chunk) RunError!RunResult {
    // §16.2.1.5.1 [[IsAsync]] — a module body with top-level
    // `await` runs as if wrapped in an async function. Route
    // through `startAsyncCall` so the body's `await_` opcode
    // suspends onto a JSGenerator-backed frame (and so the
    // surrounding expression doesn't get corrupted by the
    // current "passthrough" fall-through when `f.generator` is
    // null). The wrapper allocates a result Promise that
    // settles when the body completes; the harness drains
    // microtasks after this call returns and observes the
    // settlement via `$DONE` for async-flagged fixtures or via
    // the Promise itself for non-async modules. Plain scripts
    // and non-async modules keep the synchronous top-level
    // frame.
    if (chunk.is_async_module) {
        return startAsyncCall(allocator, realm, chunk, null, Value.undefined_, &.{}, null, null, realm.current_module);
    }

    var frames: std.ArrayListUnmanaged(CallFrame) = .empty;
    defer {
        for (frames.items) |*f| f.releaseRegisters(realm, allocator);
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
        const main_regs = try realm.frame_pool.acquire(allocator, chunk.register_count);
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

/// Decode the opcode at `ip.*`, advancing `ip` past the opcode
/// byte. The threaded-dispatch tail for every arm that completes
/// without changing the active frame. `committed` is reset so the
/// arm-local write-back flag never carries state across an opcode
/// boundary.
///
/// The byte → `Op` conversion is an unchecked `@enumFromInt`: the
/// bytecode is compiler-generated and never sourced from outside the
/// engine, so every byte is a valid `Op`. A validity check here is
/// ~a third of a tight dispatch loop's time; `@enumFromInt` is a
/// free bitcast in release and still safety-checked in Debug, which
/// catches any compiler bug that emits a stray byte.
inline fn decodeNext(code: []const u8, ip: *usize, committed: *bool) RunError!Op {
    committed.* = false;
    if (ip.* >= code.len) return error.InvalidOpcode;
    const b = code[ip.*];
    ip.* += 1;
    return @enumFromInt(b);
}

/// Re-derive the loop-persistent dispatch state from the top frame,
/// then decode the next opcode. Used after any step that swaps the
/// active frame (call push / return pop) or repositions it (an
/// exception unwind landing on a handler). The frame carries the
/// authoritative `ip` / `accumulator`: a call push seeds `ip = 0`,
/// `return` / `unwindThrow` write them onto the frame they leave us
/// on. Resets `committed` for the next arm.
inline fn reEnterDispatch(
    frames: *std.ArrayListUnmanaged(CallFrame),
    f: **CallFrame,
    local_chunk: **const Chunk,
    code: *[]const u8,
    registers: *[]Value,
    ip: *usize,
    acc: *Value,
    committed: *bool,
) RunError!Op {
    committed.* = false;
    const fr = &frames.items[frames.items.len - 1];
    f.* = fr;
    local_chunk.* = fr.chunk;
    code.* = fr.chunk.code;
    registers.* = fr.registers;
    ip.* = fr.ip;
    acc.* = fr.accumulator;
    if (fr.ip == 0) {
        // Fresh frame entry — a call push seeds ip 0, a §15.10 PTC
        // re-entry reframes in place to ip 0, and a generator's
        // first resume starts at 0. Returns and unwind landings
        // resume mid-chunk and don't re-heat. docs/jit.md §4.7.
        if (fr.chunk.jit_state) |js| js.warmth +|= Chunk.JitState.entry_weight;
    }
    if (ip.* >= code.*.len) return error.InvalidOpcode;
    const b = code.*[ip.*];
    ip.* += 1;
    // Unchecked decode — see `decodeNext`.
    return @enumFromInt(b);
}

/// Threaded-dispatch safe point. Runs the cooperative checks the
/// old `while`-loop dispatcher performed once per opcode at the
/// loop top — allocation-pressure GC, step budget, host interrupt.
///
/// A threaded interpreter has no per-opcode loop top, so these move
/// to the points where running them is *safe* and where an unbounded
/// iteration is guaranteed to cross one: loop back-edges (a taken
/// backward branch — the only way to build an unbounded loop in
/// straight-line code; see `loopSafePoint`), §15.10 proper-tail-call
/// re-entry (PTC reuses the current frame in place, so a tail-
/// recursive loop is morally a back-edge that bypasses the branch
/// dispatcher), and the first opcode of a fresh `runFrames`
/// invocation (how a suspended generator resumes). A plain `.call`
/// push and a `.return` pop deliberately do *not* cross a safe point
/// — they are on the hot path, and non-tail recursion is bounded
/// separately by `max_call_frames` (a RangeError on overflow), not
/// by the step budget. GC is stop-the-world and only ever fires here
/// — between opcodes, never mid-opcode — so a native holding a raw
/// pointer across a sub-call never sees the heap shift under it.
///
/// The step budget decrements per safe-point crossing rather than
/// per opcode. An unbounded ordinary loop crosses a back-edge each
/// iteration and an unbounded tail-recursive loop crosses the PTC
/// re-entry each call, so the budget bounds both; unbounded non-tail
/// recursion is instead caught by the frame-count ceiling. Returns a
/// non-null `RunResult` when the budget is exhausted or a host
/// interrupt fired — the caller surfaces it directly, without a
/// handler walk, matching the pre-threaded behaviour.
inline fn runSafePoint(realm: *Realm) RunError!?RunResult {
    // Allocation-pressure GC — two-tier dispatch. A minor
    // (young-only) collection fires when `allocs_since_gc` crosses
    // the small `gc_young_threshold`; it is promoted to a major
    // (full) collection when the byte threshold trips, when the
    // major allocation threshold is crossed, or once every
    // `full_every_n_minor` minor cycles so mature garbage and
    // remembered-set residue are reclaimed periodically.
    if (realm.heap.allocs_since_gc >= realm.heap.gc_young_threshold or
        realm.heap.bytes_since_gc >= realm.heap.gc_byte_threshold)
    {
        const force_full =
            realm.heap.bytes_since_gc >= realm.heap.gc_byte_threshold or
            realm.heap.allocs_since_gc >= realm.heap.gc_threshold or
            realm.heap.minor_cycles_since_full + 1 >= realm.heap.full_every_n_minor;
        if (force_full) {
            realm.collectGarbage();
        } else {
            realm.collectGarbageYoung();
        }
    }
    if (realm.step_budget == 0) {
        const ex = try makeRangeError(realm, "interpreter step budget exhausted");
        return RunResult{ .thrown = ex };
    }
    if (realm.interrupt.load(.acquire)) {
        realm.clearInterrupt();
        const ex = try makeRangeError(realm, "execution interrupted");
        return RunResult{ .thrown = ex };
    }
    realm.step_budget -|= 1;
    return null;
}

/// Loop back-edge safe point. A *taken* jump with a negative offset
/// is a loop's back-edge — the one bytecode every loop iteration is
/// guaranteed to cross, and so the place the threaded dispatcher runs
/// `runSafePoint` (allocation-pressure GC, step budget, host
/// interrupt). `f.ip` / `f.accumulator` are synced first so a GC
/// fired here sees the live accumulator as a root. Returns non-null
/// when the budget is spent / an interrupt fired.
inline fn loopSafePoint(realm: *Realm, f: *CallFrame, ip: usize, acc: Value) RunError!?RunResult {
    f.ip = ip;
    f.accumulator = acc;
    // Back-edges heat the chunk's tier counter (+1 per crossing;
    // entries weigh 16) — docs/jit.md §4.7.
    if (f.chunk.jit_state) |js| js.warmth +|= 1;
    return runSafePoint(realm);
}

// ── Int32 fast paths ───────────────────────────────────────────────
// The arithmetic / comparison / bitwise opcodes route the general
// case through `addValues` / `numericBinary` / `relational` /
// `bitwiseBinary` — full §13.15 ApplyStringOrNumericBinaryOperator
// machinery (ToPrimitive, BigInt, object coercion). When both
// operands are already int32 — the overwhelmingly common case in a
// counting loop — that's a 6-arg call for what is one machine
// instruction. These helpers compute the int32 case inline and
// return null to fall through to the general helper otherwise. The
// results are bit-identical to the general path: §6.1.6.1 Number
// addition is f64 arithmetic, so an overflowing sum/product is the
// f64 result; §13.15 keeps an in-range integer sum as an int32.

/// §13.15.3 — `+` / `-` / `*` on two int32 operands. Overflow falls
/// back to the f64 result (the ECMAScript Number result).
inline fn intArith(comptime op: enum { add, sub, mul }, a: Value, b: Value) ?Value {
    if (!a.isInt32() or !b.isInt32()) return null;
    const x = a.asInt32();
    const y = b.asInt32();
    const ov = switch (op) {
        .add => @addWithOverflow(x, y),
        .sub => @subWithOverflow(x, y),
        .mul => @mulWithOverflow(x, y),
    };
    if (ov[1] == 0) return Value.fromInt32(ov[0]);
    const fx: f64 = @floatFromInt(x);
    const fy: f64 = @floatFromInt(y);
    return Value.fromDouble(switch (op) {
        .add => fx + fy,
        .sub => fx - fy,
        .mul => fx * fy,
    });
}

/// §7.2.13 IsLessThan — relational compare on two int32 operands.
inline fn intCompare(comptime op: enum { lt, gt, le, ge }, a: Value, b: Value) ?Value {
    if (!a.isInt32() or !b.isInt32()) return null;
    const x = a.asInt32();
    const y = b.asInt32();
    return Value.fromBool(switch (op) {
        .lt => x < y,
        .gt => x > y,
        .le => x <= y,
        .ge => x >= y,
    });
}

/// §13.15 bitwise / shift on two int32 operands. `&` `|` `^` `<<`
/// `>>` stay in int32; `>>>` yields a uint32 that promotes to a
/// double when it exceeds the int32 range.
inline fn intBitwise(comptime op: enum { band, bor, bxor, shl, shr, shr_u }, a: Value, b: Value) ?Value {
    if (!a.isInt32() or !b.isInt32()) return null;
    const x = a.asInt32();
    const y = b.asInt32();
    switch (op) {
        .band => return Value.fromInt32(x & y),
        .bor => return Value.fromInt32(x | y),
        .bxor => return Value.fromInt32(x ^ y),
        .shl => {
            const sh: u5 = @truncate(@as(u32, @bitCast(y)));
            return Value.fromInt32(@bitCast(@as(u32, @bitCast(x)) << sh));
        },
        .shr => {
            const sh: u5 = @truncate(@as(u32, @bitCast(y)));
            return Value.fromInt32(x >> sh);
        },
        .shr_u => {
            const sh: u5 = @truncate(@as(u32, @bitCast(y)));
            const ru = @as(u32, @bitCast(x)) >> sh;
            return if (ru <= std.math.maxInt(i32))
                Value.fromInt32(@intCast(ru))
            else
                Value.fromDouble(@floatFromInt(ru));
        },
    }
}

pub fn runFrames(
    allocator: std.mem.Allocator,
    realm: *Realm,
    frames: *std.ArrayListUnmanaged(CallFrame),
) RunError!RunResult {
    // §spec — native re-entry stack guard. A builtin that called back
    // into JS (accessor getter, `.map` callback, `Reflect.apply`,
    // Proxy trap, promise drain) re-entered here on a fresh native
    // stack frame. Unbounded nesting overflows the host stack and
    // faults the process; throw `RangeError` while there's still room
    // to unwind. The caller's `defer` releases `frames`. See the
    // `nearNativeStackLimit` block above for the bounds strategy.
    if (stack_guard.nearLimit()) {
        const ex = try makeRangeError(realm, "Maximum call stack size exceeded");
        return .{ .thrown = ex };
    }
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
    // Empty frame stack — nothing to run. (The pre-threaded
    // dispatcher expressed this as the `while` loop condition.)
    if (frames.items.len == 0) return RunResult{ .value = Value.undefined_ };

    // ── Threaded dispatch ────────────────────────────────────────
    // Loop-persistent dispatch state — declared once, mutated in
    // place across opcodes. The pre-threaded `while + switch` form
    // re-derived all of this every iteration and ran a `defer`
    // write-back; that per-opcode overhead is what this rung
    // removes. Each opcode arm ends in `continue :dispatch <next>`,
    // emitting a separate indirect branch per opcode site (the
    // computed-goto equivalent) so the branch predictor learns
    // per-opcode-pair patterns instead of funnelling through one
    // shared dispatch.
    //
    // Frame state (`f.ip` / `f.accumulator`) is written back only
    // at frame-swap points (call / return) and exception unwind;
    // `reEnterDispatch` re-loads it. `committed` is the arm-local
    // write-back flag the few arms that route a throw out through a
    // labeled block consult (`if (committed) continue ...`); the
    // dispatch helpers reset it so it never leaks across an opcode.
    var f: *CallFrame = &frames.items[frames.items.len - 1];
    var local_chunk: *const Chunk = f.chunk;
    var code: []const u8 = local_chunk.code;
    var registers: []Value = f.registers;
    var ip: usize = f.ip;
    var acc: Value = f.accumulator;
    var committed: bool = false;

    // First opcode of this `runFrames` invocation. A fresh entry is
    // also how a suspended generator resumes, so cross the safe
    // point before the first dispatch (GC / step budget / interrupt
    // — see `runSafePoint`).
    if (try runSafePoint(realm)) |r| return r;
    if (ip >= code.len) return error.InvalidOpcode;
    const first_op: Op = @enumFromInt(code[ip]);
    ip += 1;

    dispatch: switch (first_op) {
        // ── Loads ───────────────────────────────────────────────────
        .lda_undefined => {
            acc = Value.undefined_;
            continue :dispatch try decodeNext(code, &ip, &committed);
        },
        .lda_null => {
            acc = Value.null_;
            continue :dispatch try decodeNext(code, &ip, &committed);
        },
        .lda_true => {
            acc = Value.true_;
            continue :dispatch try decodeNext(code, &ip, &committed);
        },
        .lda_false => {
            acc = Value.false_;
            continue :dispatch try decodeNext(code, &ip, &committed);
        },
        .lda_smi => {
            acc = Value.fromInt32(readI32(code, ip));
            ip += 4;
            continue :dispatch try decodeNext(code, &ip, &committed);
        },
        .lda_constant => {
            const k = readU16(code, ip);
            ip += 2;
            acc = local_chunk.constants[k];
            continue :dispatch try decodeNext(code, &ip, &committed);
        },
        .ldar => {
            const r = code[ip];
            ip += 1;
            acc = registers[r];
            continue :dispatch try decodeNext(code, &ip, &committed);
        },
        .star => {
            const r = code[ip];
            ip += 1;
            registers[r] = acc;
            continue :dispatch try decodeNext(code, &ip, &committed);
        },
        .mov => {
            const src = code[ip];
            const dst = code[ip + 1];
            ip += 2;
            registers[dst] = registers[src];
            continue :dispatch try decodeNext(code, &ip, &committed);
        },
        .lda_hole => {
            acc = Value.hole_;
            continue :dispatch try decodeNext(code, &ip, &committed);
        },

        // ── Peephole padding ────────────────────────────────────────
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
            if (intArith(.add, registers[r], acc)) |res| {
                acc = res;
                continue :dispatch try decodeNext(code, &ip, &committed);
            }
            if (try addValues(realm, registers[r], acc)) |res| acc = res else {
                const ex = realm.pending_exception orelse try makeTypeError(realm, "ToPrimitive failed");
                realm.pending_exception = null;
                f.ip = ip;
                f.accumulator = acc;
                committed = true;
                if (!try unwindThrow(allocator, realm, frames, ex)) return .{ .thrown = ex };
                continue :dispatch try reEnterDispatch(frames, &f, &local_chunk, &code, &registers, &ip, &acc, &committed);
            }
            continue :dispatch try decodeNext(code, &ip, &committed);
        },
        .to_int32 => {
            // Fused form of `expr | 0` — semantically equivalent to
            // ApplyStringOrNumericBinaryOperator(BitOr, acc, +0).
            // Int32 fast path: `intBitwise(.bor, acc, 0)` returns
            // `acc | 0 = acc` (identity), so this is a 0-cost
            // transform for the dominant int32 case. Everything
            // else (double, string, bool, null, undefined, BigInt)
            // routes through `bitwiseBinary(.bor, acc, 0)` so the
            // ToInt32 spec sequence (NaN/±∞ → +0, double truncate,
            // ToNumber on String, BigInt TypeError) lands
            // bit-identically to the un-fused `Star r; LdaSmi 0;
            // BitOr r` triple.
            const zero = Value.fromInt32(0);
            if (intBitwise(.bor, acc, zero)) |res| {
                acc = res;
                continue :dispatch try decodeNext(code, &ip, &committed);
            }
            if (try bitwiseBinary(realm, .bit_or, acc, zero)) |res| acc = res else {
                const ex = realm.pending_exception orelse try makeTypeError(realm, "ToPrimitive failed");
                realm.pending_exception = null;
                f.ip = ip;
                f.accumulator = acc;
                committed = true;
                if (!try unwindThrow(allocator, realm, frames, ex)) return .{ .thrown = ex };
                continue :dispatch try reEnterDispatch(frames, &f, &local_chunk, &code, &registers, &ip, &acc, &committed);
            }
            continue :dispatch try decodeNext(code, &ip, &committed);
        },
        .add_smi => {
            // Fused `<reg> + <imm>`. Reads the register, adds the
            // baked-in Smi immediate, writes to acc. The int32 fast
            // path here is BIT-IDENTICAL to `.add` with a Smi RHS:
            // `@addWithOverflow` and fall back to f64 on overflow.
            // The slow path wraps the immediate as a Smi `Value`
            // and routes through `addValues`, so non-int32
            // registers (string, BigInt, double, object) keep
            // every §13.15 semantic — string concat, BigInt
            // TypeError, double + Smi all behave as if the
            // un-fused `LdaSmi imm; Add r` had run.
            const r = code[ip];
            const imm = readI32(code, ip + 1);
            ip += 5;
            const reg_v = registers[r];
            if (reg_v.isInt32()) {
                const ov = @addWithOverflow(reg_v.asInt32(), imm);
                if (ov[1] == 0) {
                    acc = Value.fromInt32(ov[0]);
                } else {
                    const fx: f64 = @floatFromInt(reg_v.asInt32());
                    const fy: f64 = @floatFromInt(imm);
                    acc = Value.fromDouble(fx + fy);
                }
                continue :dispatch try decodeNext(code, &ip, &committed);
            }
            const rhs = Value.fromInt32(imm);
            if (try addValues(realm, reg_v, rhs)) |res| acc = res else {
                const ex = realm.pending_exception orelse try makeTypeError(realm, "ToPrimitive failed");
                realm.pending_exception = null;
                f.ip = ip;
                f.accumulator = acc;
                committed = true;
                if (!try unwindThrow(allocator, realm, frames, ex)) return .{ .thrown = ex };
                continue :dispatch try reEnterDispatch(frames, &f, &local_chunk, &code, &registers, &ip, &acc, &committed);
            }
            continue :dispatch try decodeNext(code, &ip, &committed);
        },
        .sub => {
            const r = code[ip];
            ip += 1;
            if (intArith(.sub, registers[r], acc)) |res| {
                acc = res;
                continue :dispatch try decodeNext(code, &ip, &committed);
            }
            if (try numericBinary(realm, .sub, registers[r], acc)) |res| acc = res else {
                const ex = realm.pending_exception orelse try makeTypeError(realm, "ToPrimitive failed");
                realm.pending_exception = null;
                f.ip = ip;
                f.accumulator = acc;
                committed = true;
                if (!try unwindThrow(allocator, realm, frames, ex)) return .{ .thrown = ex };
                continue :dispatch try reEnterDispatch(frames, &f, &local_chunk, &code, &registers, &ip, &acc, &committed);
            }
            continue :dispatch try decodeNext(code, &ip, &committed);
        },
        .mul => {
            const r = code[ip];
            ip += 1;
            if (intArith(.mul, registers[r], acc)) |res| {
                acc = res;
                continue :dispatch try decodeNext(code, &ip, &committed);
            }
            if (try numericBinary(realm, .mul, registers[r], acc)) |res| acc = res else {
                const ex = realm.pending_exception orelse try makeTypeError(realm, "ToPrimitive failed");
                realm.pending_exception = null;
                f.ip = ip;
                f.accumulator = acc;
                committed = true;
                if (!try unwindThrow(allocator, realm, frames, ex)) return .{ .thrown = ex };
                continue :dispatch try reEnterDispatch(frames, &f, &local_chunk, &code, &registers, &ip, &acc, &committed);
            }
            continue :dispatch try decodeNext(code, &ip, &committed);
        },
        .div => {
            const r = code[ip];
            ip += 1;
            if (try numericBinary(realm, .div, registers[r], acc)) |res| acc = res else {
                const ex = realm.pending_exception orelse try makeTypeError(realm, "ToPrimitive failed");
                realm.pending_exception = null;
                f.ip = ip;
                f.accumulator = acc;
                committed = true;
                if (!try unwindThrow(allocator, realm, frames, ex)) return .{ .thrown = ex };
                continue :dispatch try reEnterDispatch(frames, &f, &local_chunk, &code, &registers, &ip, &acc, &committed);
            }
            continue :dispatch try decodeNext(code, &ip, &committed);
        },
        .mod => {
            const r = code[ip];
            ip += 1;
            if (try numericBinary(realm, .mod, registers[r], acc)) |res| acc = res else {
                const ex = realm.pending_exception orelse try makeTypeError(realm, "ToPrimitive failed");
                realm.pending_exception = null;
                f.ip = ip;
                f.accumulator = acc;
                committed = true;
                if (!try unwindThrow(allocator, realm, frames, ex)) return .{ .thrown = ex };
                continue :dispatch try reEnterDispatch(frames, &f, &local_chunk, &code, &registers, &ip, &acc, &committed);
            }
            continue :dispatch try decodeNext(code, &ip, &committed);
        },
        .pow => {
            const r = code[ip];
            ip += 1;
            if (try numericBinary(realm, .pow, registers[r], acc)) |res| acc = res else {
                const ex = realm.pending_exception orelse try makeTypeError(realm, "ToPrimitive failed");
                realm.pending_exception = null;
                f.ip = ip;
                f.accumulator = acc;
                committed = true;
                if (!try unwindThrow(allocator, realm, frames, ex)) return .{ .thrown = ex };
                continue :dispatch try reEnterDispatch(frames, &f, &local_chunk, &code, &registers, &ip, &acc, &committed);
            }
            continue :dispatch try decodeNext(code, &ip, &committed);
        },

        // ── Bitwise — both operands are ToInt32-coerced ─────────────
        .bit_and => {
            const r = code[ip];
            ip += 1;
            if (intBitwise(.band, registers[r], acc)) |res| {
                acc = res;
                continue :dispatch try decodeNext(code, &ip, &committed);
            }
            if (try bitwiseBinary(realm, .bit_and, registers[r], acc)) |res| acc = res else {
                const ex = realm.pending_exception orelse try makeTypeError(realm, "ToPrimitive failed");
                realm.pending_exception = null;
                f.ip = ip;
                f.accumulator = acc;
                committed = true;
                if (!try unwindThrow(allocator, realm, frames, ex)) return .{ .thrown = ex };
                continue :dispatch try reEnterDispatch(frames, &f, &local_chunk, &code, &registers, &ip, &acc, &committed);
            }
            continue :dispatch try decodeNext(code, &ip, &committed);
        },
        .bit_or => {
            const r = code[ip];
            ip += 1;
            if (intBitwise(.bor, registers[r], acc)) |res| {
                acc = res;
                continue :dispatch try decodeNext(code, &ip, &committed);
            }
            if (try bitwiseBinary(realm, .bit_or, registers[r], acc)) |res| acc = res else {
                const ex = realm.pending_exception orelse try makeTypeError(realm, "ToPrimitive failed");
                realm.pending_exception = null;
                f.ip = ip;
                f.accumulator = acc;
                committed = true;
                if (!try unwindThrow(allocator, realm, frames, ex)) return .{ .thrown = ex };
                continue :dispatch try reEnterDispatch(frames, &f, &local_chunk, &code, &registers, &ip, &acc, &committed);
            }
            continue :dispatch try decodeNext(code, &ip, &committed);
        },
        .bit_xor => {
            const r = code[ip];
            ip += 1;
            if (intBitwise(.bxor, registers[r], acc)) |res| {
                acc = res;
                continue :dispatch try decodeNext(code, &ip, &committed);
            }
            if (try bitwiseBinary(realm, .bit_xor, registers[r], acc)) |res| acc = res else {
                const ex = realm.pending_exception orelse try makeTypeError(realm, "ToPrimitive failed");
                realm.pending_exception = null;
                f.ip = ip;
                f.accumulator = acc;
                committed = true;
                if (!try unwindThrow(allocator, realm, frames, ex)) return .{ .thrown = ex };
                continue :dispatch try reEnterDispatch(frames, &f, &local_chunk, &code, &registers, &ip, &acc, &committed);
            }
            continue :dispatch try decodeNext(code, &ip, &committed);
        },
        .shl => {
            const r = code[ip];
            ip += 1;
            if (intBitwise(.shl, registers[r], acc)) |res| {
                acc = res;
                continue :dispatch try decodeNext(code, &ip, &committed);
            }
            if (try bitwiseBinary(realm, .shl, registers[r], acc)) |res| acc = res else {
                const ex = realm.pending_exception orelse try makeTypeError(realm, "ToPrimitive failed");
                realm.pending_exception = null;
                f.ip = ip;
                f.accumulator = acc;
                committed = true;
                if (!try unwindThrow(allocator, realm, frames, ex)) return .{ .thrown = ex };
                continue :dispatch try reEnterDispatch(frames, &f, &local_chunk, &code, &registers, &ip, &acc, &committed);
            }
            continue :dispatch try decodeNext(code, &ip, &committed);
        },
        .shr => {
            const r = code[ip];
            ip += 1;
            if (intBitwise(.shr, registers[r], acc)) |res| {
                acc = res;
                continue :dispatch try decodeNext(code, &ip, &committed);
            }
            if (try bitwiseBinary(realm, .shr, registers[r], acc)) |res| acc = res else {
                const ex = realm.pending_exception orelse try makeTypeError(realm, "ToPrimitive failed");
                realm.pending_exception = null;
                f.ip = ip;
                f.accumulator = acc;
                committed = true;
                if (!try unwindThrow(allocator, realm, frames, ex)) return .{ .thrown = ex };
                continue :dispatch try reEnterDispatch(frames, &f, &local_chunk, &code, &registers, &ip, &acc, &committed);
            }
            continue :dispatch try decodeNext(code, &ip, &committed);
        },
        .shr_u => {
            const r = code[ip];
            ip += 1;
            if (intBitwise(.shr_u, registers[r], acc)) |res| {
                acc = res;
                continue :dispatch try decodeNext(code, &ip, &committed);
            }
            if (try bitwiseBinary(realm, .shr_u, registers[r], acc)) |res| acc = res else {
                const ex = realm.pending_exception orelse try makeTypeError(realm, "ToPrimitive failed");
                realm.pending_exception = null;
                f.ip = ip;
                f.accumulator = acc;
                committed = true;
                if (!try unwindThrow(allocator, realm, frames, ex)) return .{ .thrown = ex };
                continue :dispatch try reEnterDispatch(frames, &f, &local_chunk, &code, &registers, &ip, &acc, &committed);
            }
            continue :dispatch try decodeNext(code, &ip, &committed);
        },

        // ── Unary on accumulator ────────────────────────────────────
        .negate => {
            if (try unaryNegate(realm, acc)) |res| acc = res else {
                const ex = realm.pending_exception orelse try makeTypeError(realm, "ToPrimitive failed");
                realm.pending_exception = null;
                f.ip = ip;
                f.accumulator = acc;
                committed = true;
                if (!try unwindThrow(allocator, realm, frames, ex)) return .{ .thrown = ex };
                continue :dispatch try reEnterDispatch(frames, &f, &local_chunk, &code, &registers, &ip, &acc, &committed);
            }
            continue :dispatch try decodeNext(code, &ip, &committed);
        },
        .bit_not => {
            if (try unaryBitNot(realm, acc)) |res| acc = res else {
                const ex = realm.pending_exception orelse try makeTypeError(realm, "ToPrimitive failed");
                realm.pending_exception = null;
                f.ip = ip;
                f.accumulator = acc;
                committed = true;
                if (!try unwindThrow(allocator, realm, frames, ex)) return .{ .thrown = ex };
                continue :dispatch try reEnterDispatch(frames, &f, &local_chunk, &code, &registers, &ip, &acc, &committed);
            }
            continue :dispatch try decodeNext(code, &ip, &committed);
        },
        .logical_not => {
            acc = Value.fromBool(!toBoolean(acc));
            continue :dispatch try decodeNext(code, &ip, &committed);
        },
        .to_number => {
            if (try unaryToNumber(realm, acc)) |res| acc = res else {
                const ex = realm.pending_exception orelse try makeTypeError(realm, "ToPrimitive failed");
                realm.pending_exception = null;
                f.ip = ip;
                f.accumulator = acc;
                committed = true;
                if (!try unwindThrow(allocator, realm, frames, ex)) return .{ .thrown = ex };
                continue :dispatch try reEnterDispatch(frames, &f, &local_chunk, &code, &registers, &ip, &acc, &committed);
            }
            continue :dispatch try decodeNext(code, &ip, &committed);
        },
        .to_numeric => {
            if (try unaryToNumeric(realm, acc)) |res| acc = res else {
                const ex = realm.pending_exception orelse try makeTypeError(realm, "ToPrimitive failed");
                realm.pending_exception = null;
                f.ip = ip;
                f.accumulator = acc;
                committed = true;
                if (!try unwindThrow(allocator, realm, frames, ex)) return .{ .thrown = ex };
                continue :dispatch try reEnterDispatch(frames, &f, &local_chunk, &code, &registers, &ip, &acc, &committed);
            }
            continue :dispatch try decodeNext(code, &ip, &committed);
        },
        .to_string => {
            // §7.1.17 ToString — for Object input, runs §7.1.1
            // ToPrimitive(hint "string") which consults
            // `Symbol.toPrimitive` then OrdinaryToPrimitive
            // ("toString" before "valueOf"). Symbol primitives
            // throw TypeError per §7.1.17 step 6. Powers the
            // template-literal substitution lowering — see
            // §13.2.8.6 step 7 / compileTemplateLiteral.
            const s = intrinsics_mod.stringifyArg(realm, acc) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.NativeThrew => {
                    const ex = realm.pending_exception orelse try makeTypeError(realm, "ToString failed");
                    realm.pending_exception = null;
                    f.ip = ip;
                    f.accumulator = acc;
                    committed = true;
                    if (!try unwindThrow(allocator, realm, frames, ex)) return .{ .thrown = ex };
                    continue :dispatch try reEnterDispatch(frames, &f, &local_chunk, &code, &registers, &ip, &acc, &committed);
                },
            };
            acc = Value.fromString(s);
            continue :dispatch try decodeNext(code, &ip, &committed);
        },
        .inc => {
            if (intArith(.add, acc, Value.fromInt32(1))) |res| {
                acc = res;
                continue :dispatch try decodeNext(code, &ip, &committed);
            }
            if (try arith.incOrDec(realm, acc, 1)) |res| acc = res else {
                const ex = realm.pending_exception orelse try makeTypeError(realm, "Update failed");
                realm.pending_exception = null;
                f.ip = ip;
                f.accumulator = acc;
                committed = true;
                if (!try unwindThrow(allocator, realm, frames, ex)) return .{ .thrown = ex };
                continue :dispatch try reEnterDispatch(frames, &f, &local_chunk, &code, &registers, &ip, &acc, &committed);
            }
            continue :dispatch try decodeNext(code, &ip, &committed);
        },
        .dec => {
            if (intArith(.sub, acc, Value.fromInt32(1))) |res| {
                acc = res;
                continue :dispatch try decodeNext(code, &ip, &committed);
            }
            if (try arith.incOrDec(realm, acc, -1)) |res| acc = res else {
                const ex = realm.pending_exception orelse try makeTypeError(realm, "Update failed");
                realm.pending_exception = null;
                f.ip = ip;
                f.accumulator = acc;
                committed = true;
                if (!try unwindThrow(allocator, realm, frames, ex)) return .{ .thrown = ex };
                continue :dispatch try reEnterDispatch(frames, &f, &local_chunk, &code, &registers, &ip, &acc, &committed);
            }
            continue :dispatch try decodeNext(code, &ip, &committed);
        },
        .typeof_ => {
            acc = try typeOf(realm, acc);
            continue :dispatch try decodeNext(code, &ip, &committed);
        },

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
                continue :dispatch try reEnterDispatch(frames, &f, &local_chunk, &code, &registers, &ip, &acc, &committed);
            }
            const rhs = try coerceForCompareEq(allocator, realm, frames, f, ip, rhs_v, lhs.ok);
            if (rhs == .uncaught) return .{ .thrown = rhs.uncaught };
            if (rhs == .handled) {
                committed = true;
                continue :dispatch try reEnterDispatch(frames, &f, &local_chunk, &code, &registers, &ip, &acc, &committed);
            }
            acc = Value.fromBool(looseEq(allocator, lhs.ok, rhs.ok));
            continue :dispatch try decodeNext(code, &ip, &committed);
        },
        .strict_eq => {
            const r = code[ip];
            ip += 1;
            acc = Value.fromBool(strictEq(registers[r], acc));
            continue :dispatch try decodeNext(code, &ip, &committed);
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
                continue :dispatch try reEnterDispatch(frames, &f, &local_chunk, &code, &registers, &ip, &acc, &committed);
            }
            const rhs = try coerceForCompareEq(allocator, realm, frames, f, ip, rhs_v, lhs.ok);
            if (rhs == .uncaught) return .{ .thrown = rhs.uncaught };
            if (rhs == .handled) {
                committed = true;
                continue :dispatch try reEnterDispatch(frames, &f, &local_chunk, &code, &registers, &ip, &acc, &committed);
            }
            acc = Value.fromBool(!looseEq(allocator, lhs.ok, rhs.ok));
            continue :dispatch try decodeNext(code, &ip, &committed);
        },
        .strict_neq => {
            const r = code[ip];
            ip += 1;
            acc = Value.fromBool(!strictEq(registers[r], acc));
            continue :dispatch try decodeNext(code, &ip, &committed);
        },
        .lt => {
            const r = code[ip];
            ip += 1;
            if (intCompare(.lt, registers[r], acc)) |res| {
                acc = res;
                continue :dispatch try decodeNext(code, &ip, &committed);
            }
            const lhs = try coerceForCompare(allocator, realm, frames, f, ip, registers[r], .number);
            if (lhs == .uncaught) return .{ .thrown = lhs.uncaught };
            if (lhs == .handled) {
                committed = true;
                continue :dispatch try reEnterDispatch(frames, &f, &local_chunk, &code, &registers, &ip, &acc, &committed);
            }
            const rhs = try coerceForCompare(allocator, realm, frames, f, ip, acc, .number);
            if (rhs == .uncaught) return .{ .thrown = rhs.uncaught };
            if (rhs == .handled) {
                committed = true;
                continue :dispatch try reEnterDispatch(frames, &f, &local_chunk, &code, &registers, &ip, &acc, &committed);
            }
            acc = relational(.lt, realm, lhs.ok, rhs.ok) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.NativeThrew => {
                    const ex = realm.pending_exception orelse try makeTypeError(realm, "comparison threw");
                    realm.pending_exception = null;
                    f.ip = ip;
                    f.accumulator = lhs.ok;
                    if (!try unwindThrow(allocator, realm, frames, ex)) return .{ .thrown = ex };
                    committed = true;
                    continue :dispatch try reEnterDispatch(frames, &f, &local_chunk, &code, &registers, &ip, &acc, &committed);
                },
            };
            continue :dispatch try decodeNext(code, &ip, &committed);
        },
        .gt => {
            const r = code[ip];
            ip += 1;
            if (intCompare(.gt, registers[r], acc)) |res| {
                acc = res;
                continue :dispatch try decodeNext(code, &ip, &committed);
            }
            const lhs = try coerceForCompare(allocator, realm, frames, f, ip, registers[r], .number);
            if (lhs == .uncaught) return .{ .thrown = lhs.uncaught };
            if (lhs == .handled) {
                committed = true;
                continue :dispatch try reEnterDispatch(frames, &f, &local_chunk, &code, &registers, &ip, &acc, &committed);
            }
            const rhs = try coerceForCompare(allocator, realm, frames, f, ip, acc, .number);
            if (rhs == .uncaught) return .{ .thrown = rhs.uncaught };
            if (rhs == .handled) {
                committed = true;
                continue :dispatch try reEnterDispatch(frames, &f, &local_chunk, &code, &registers, &ip, &acc, &committed);
            }
            acc = relational(.gt, realm, lhs.ok, rhs.ok) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.NativeThrew => {
                    const ex = realm.pending_exception orelse try makeTypeError(realm, "comparison threw");
                    realm.pending_exception = null;
                    f.ip = ip;
                    f.accumulator = lhs.ok;
                    if (!try unwindThrow(allocator, realm, frames, ex)) return .{ .thrown = ex };
                    committed = true;
                    continue :dispatch try reEnterDispatch(frames, &f, &local_chunk, &code, &registers, &ip, &acc, &committed);
                },
            };
            continue :dispatch try decodeNext(code, &ip, &committed);
        },
        .le => {
            const r = code[ip];
            ip += 1;
            if (intCompare(.le, registers[r], acc)) |res| {
                acc = res;
                continue :dispatch try decodeNext(code, &ip, &committed);
            }
            const lhs = try coerceForCompare(allocator, realm, frames, f, ip, registers[r], .number);
            if (lhs == .uncaught) return .{ .thrown = lhs.uncaught };
            if (lhs == .handled) {
                committed = true;
                continue :dispatch try reEnterDispatch(frames, &f, &local_chunk, &code, &registers, &ip, &acc, &committed);
            }
            const rhs = try coerceForCompare(allocator, realm, frames, f, ip, acc, .number);
            if (rhs == .uncaught) return .{ .thrown = rhs.uncaught };
            if (rhs == .handled) {
                committed = true;
                continue :dispatch try reEnterDispatch(frames, &f, &local_chunk, &code, &registers, &ip, &acc, &committed);
            }
            acc = relational(.le, realm, lhs.ok, rhs.ok) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.NativeThrew => {
                    const ex = realm.pending_exception orelse try makeTypeError(realm, "comparison threw");
                    realm.pending_exception = null;
                    f.ip = ip;
                    f.accumulator = lhs.ok;
                    if (!try unwindThrow(allocator, realm, frames, ex)) return .{ .thrown = ex };
                    committed = true;
                    continue :dispatch try reEnterDispatch(frames, &f, &local_chunk, &code, &registers, &ip, &acc, &committed);
                },
            };
            continue :dispatch try decodeNext(code, &ip, &committed);
        },
        .ge => {
            const r = code[ip];
            ip += 1;
            if (intCompare(.ge, registers[r], acc)) |res| {
                acc = res;
                continue :dispatch try decodeNext(code, &ip, &committed);
            }
            const lhs = try coerceForCompare(allocator, realm, frames, f, ip, registers[r], .number);
            if (lhs == .uncaught) return .{ .thrown = lhs.uncaught };
            if (lhs == .handled) {
                committed = true;
                continue :dispatch try reEnterDispatch(frames, &f, &local_chunk, &code, &registers, &ip, &acc, &committed);
            }
            const rhs = try coerceForCompare(allocator, realm, frames, f, ip, acc, .number);
            if (rhs == .uncaught) return .{ .thrown = rhs.uncaught };
            if (rhs == .handled) {
                committed = true;
                continue :dispatch try reEnterDispatch(frames, &f, &local_chunk, &code, &registers, &ip, &acc, &committed);
            }
            acc = relational(.ge, realm, lhs.ok, rhs.ok) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.NativeThrew => {
                    const ex = realm.pending_exception orelse try makeTypeError(realm, "comparison threw");
                    realm.pending_exception = null;
                    f.ip = ip;
                    f.accumulator = lhs.ok;
                    if (!try unwindThrow(allocator, realm, frames, ex)) return .{ .thrown = ex };
                    committed = true;
                    continue :dispatch try reEnterDispatch(frames, &f, &local_chunk, &code, &registers, &ip, &acc, &committed);
                },
            };
            continue :dispatch try decodeNext(code, &ip, &committed);
        },

        // ── Control flow ────────────────────────────────────────────
        .jmp => {
            const off = readI16(code, ip);
            ip += 2;
            ip = applyOffset(ip, off);
            if (off < 0) {
                if (try loopSafePoint(realm, f, ip, acc)) |r| return r;
                // docs/jit.md §12 3f — OSR: a loop hot enough to
                // tier up enters compiled code at this back-edge's
                // header; loopSafePoint synced the frame, so the
                // switch is a jump. Inline-guarded — back-edges are
                // the hottest dispatch path.
                // Cheap precheck — a 5M-iteration interpreted loop
                // cannot afford a function call per back-edge: call
                // only when tier-up is plausibly due (cold and past
                // the threshold floor) or an OSR table exists and is
                // not striking out.
                const osr_worth = realm.jit_enabled and worth: {
                    const js_ = f.chunk.jit_state orelse break :worth false;
                    if (js_.tier == .dont_compile) break :worth false;
                    if (js_.tier == .cold) {
                        const floor = realm.jit_threshold_override orelse bistromath.tier_up_base;
                        break :worth js_.warmth >= floor;
                    }
                    break :worth js_.osr_ptr != null and js_.osr_strikes < bistromath.osr_strike_limit;
                };
                if (osr_worth) {
                    switch (try bistromath.tryOsrEnterTop(allocator, realm, frames)) {
                        .not_entered => {},
                        .resumed => {
                            committed = true;
                            continue :dispatch try reEnterDispatch(frames, &f, &local_chunk, &code, &registers, &ip, &acc, &committed);
                        },
                        .completed => |ret| {
                            if (frames.items.len == 0) return .{ .value = ret };
                            frames.items[frames.items.len - 1].accumulator = ret;
                            committed = true;
                            continue :dispatch try reEnterDispatch(frames, &f, &local_chunk, &code, &registers, &ip, &acc, &committed);
                        },
                        .threw => |ex| {
                            if (!try unwindThrow(allocator, realm, frames, ex)) return .{ .thrown = ex };
                            committed = true;
                            continue :dispatch try reEnterDispatch(frames, &f, &local_chunk, &code, &registers, &ip, &acc, &committed);
                        },
                    }
                }
            }
            continue :dispatch try decodeNext(code, &ip, &committed);
        },
        .jmp_if_false => {
            const off = readI16(code, ip);
            ip += 2;
            if (!toBoolean(acc)) {
                ip = applyOffset(ip, off);
                if (off < 0) {
                    if (try loopSafePoint(realm, f, ip, acc)) |r| return r;
                    // docs/jit.md §12 3f — OSR: a loop hot enough to
                    // tier up enters compiled code at this back-edge's
                    // header; loopSafePoint synced the frame, so the
                    // switch is a jump. Inline-guarded — back-edges are
                    // the hottest dispatch path.
                    // Cheap precheck — a 5M-iteration interpreted loop
                    // cannot afford a function call per back-edge: call
                    // only when tier-up is plausibly due (cold and past
                    // the threshold floor) or an OSR table exists and is
                    // not striking out.
                    const osr_worth = realm.jit_enabled and worth: {
                        const js_ = f.chunk.jit_state orelse break :worth false;
                        if (js_.tier == .dont_compile) break :worth false;
                        if (js_.tier == .cold) {
                            const floor = realm.jit_threshold_override orelse bistromath.tier_up_base;
                            break :worth js_.warmth >= floor;
                        }
                        break :worth js_.osr_ptr != null and js_.osr_strikes < bistromath.osr_strike_limit;
                    };
                    if (osr_worth) {
                        switch (try bistromath.tryOsrEnterTop(allocator, realm, frames)) {
                            .not_entered => {},
                            .resumed => {
                                committed = true;
                                continue :dispatch try reEnterDispatch(frames, &f, &local_chunk, &code, &registers, &ip, &acc, &committed);
                            },
                            .completed => |ret| {
                                if (frames.items.len == 0) return .{ .value = ret };
                                frames.items[frames.items.len - 1].accumulator = ret;
                                committed = true;
                                continue :dispatch try reEnterDispatch(frames, &f, &local_chunk, &code, &registers, &ip, &acc, &committed);
                            },
                            .threw => |ex| {
                                if (!try unwindThrow(allocator, realm, frames, ex)) return .{ .thrown = ex };
                                committed = true;
                                continue :dispatch try reEnterDispatch(frames, &f, &local_chunk, &code, &registers, &ip, &acc, &committed);
                            },
                        }
                    }
                }
            }
            continue :dispatch try decodeNext(code, &ip, &committed);
        },
        .jmp_if_true => {
            const off = readI16(code, ip);
            ip += 2;
            if (toBoolean(acc)) {
                ip = applyOffset(ip, off);
                if (off < 0) {
                    if (try loopSafePoint(realm, f, ip, acc)) |r| return r;
                    // docs/jit.md §12 3f — OSR: a loop hot enough to
                    // tier up enters compiled code at this back-edge's
                    // header; loopSafePoint synced the frame, so the
                    // switch is a jump. Inline-guarded — back-edges are
                    // the hottest dispatch path.
                    // Cheap precheck — a 5M-iteration interpreted loop
                    // cannot afford a function call per back-edge: call
                    // only when tier-up is plausibly due (cold and past
                    // the threshold floor) or an OSR table exists and is
                    // not striking out.
                    const osr_worth = realm.jit_enabled and worth: {
                        const js_ = f.chunk.jit_state orelse break :worth false;
                        if (js_.tier == .dont_compile) break :worth false;
                        if (js_.tier == .cold) {
                            const floor = realm.jit_threshold_override orelse bistromath.tier_up_base;
                            break :worth js_.warmth >= floor;
                        }
                        break :worth js_.osr_ptr != null and js_.osr_strikes < bistromath.osr_strike_limit;
                    };
                    if (osr_worth) {
                        switch (try bistromath.tryOsrEnterTop(allocator, realm, frames)) {
                            .not_entered => {},
                            .resumed => {
                                committed = true;
                                continue :dispatch try reEnterDispatch(frames, &f, &local_chunk, &code, &registers, &ip, &acc, &committed);
                            },
                            .completed => |ret| {
                                if (frames.items.len == 0) return .{ .value = ret };
                                frames.items[frames.items.len - 1].accumulator = ret;
                                committed = true;
                                continue :dispatch try reEnterDispatch(frames, &f, &local_chunk, &code, &registers, &ip, &acc, &committed);
                            },
                            .threw => |ex| {
                                if (!try unwindThrow(allocator, realm, frames, ex)) return .{ .thrown = ex };
                                committed = true;
                                continue :dispatch try reEnterDispatch(frames, &f, &local_chunk, &code, &registers, &ip, &acc, &committed);
                            },
                        }
                    }
                }
            }
            continue :dispatch try decodeNext(code, &ip, &committed);
        },
        .jmp_if_nullish => {
            const off = readI16(code, ip);
            ip += 2;
            if (acc.isNull() or acc.isUndefined()) {
                ip = applyOffset(ip, off);
                if (off < 0) {
                    if (try loopSafePoint(realm, f, ip, acc)) |r| return r;
                    // docs/jit.md §12 3f — OSR: a loop hot enough to
                    // tier up enters compiled code at this back-edge's
                    // header; loopSafePoint synced the frame, so the
                    // switch is a jump. Inline-guarded — back-edges are
                    // the hottest dispatch path.
                    // Cheap precheck — a 5M-iteration interpreted loop
                    // cannot afford a function call per back-edge: call
                    // only when tier-up is plausibly due (cold and past
                    // the threshold floor) or an OSR table exists and is
                    // not striking out.
                    const osr_worth = realm.jit_enabled and worth: {
                        const js_ = f.chunk.jit_state orelse break :worth false;
                        if (js_.tier == .dont_compile) break :worth false;
                        if (js_.tier == .cold) {
                            const floor = realm.jit_threshold_override orelse bistromath.tier_up_base;
                            break :worth js_.warmth >= floor;
                        }
                        break :worth js_.osr_ptr != null and js_.osr_strikes < bistromath.osr_strike_limit;
                    };
                    if (osr_worth) {
                        switch (try bistromath.tryOsrEnterTop(allocator, realm, frames)) {
                            .not_entered => {},
                            .resumed => {
                                committed = true;
                                continue :dispatch try reEnterDispatch(frames, &f, &local_chunk, &code, &registers, &ip, &acc, &committed);
                            },
                            .completed => |ret| {
                                if (frames.items.len == 0) return .{ .value = ret };
                                frames.items[frames.items.len - 1].accumulator = ret;
                                committed = true;
                                continue :dispatch try reEnterDispatch(frames, &f, &local_chunk, &code, &registers, &ip, &acc, &committed);
                            },
                            .threw => |ex| {
                                if (!try unwindThrow(allocator, realm, frames, ex)) return .{ .thrown = ex };
                                committed = true;
                                continue :dispatch try reEnterDispatch(frames, &f, &local_chunk, &code, &registers, &ip, &acc, &committed);
                            },
                        }
                    }
                }
            }
            continue :dispatch try decodeNext(code, &ip, &committed);
        },
        .loop_inc_lt => {
            const r_counter = code[ip];
            const r_bound = code[ip + 1];
            const off = readI16(code, ip + 2);
            ip += 4;
            // Hot path: both operands int32, counter+1 doesn't
            // overflow. The branch back to the body is the
            // overwhelmingly common case (5M iterations of an
            // arith loop hit this every step), so it stays
            // straight-line.
            const c = registers[r_counter];
            const b = registers[r_bound];
            if (c.isInt32() and b.isInt32()) {
                const ov = @addWithOverflow(c.asInt32(), @as(i32, 1));
                if (ov[1] == 0) {
                    registers[r_counter] = Value.fromInt32(ov[0]);
                    if (ov[0] < b.asInt32()) {
                        ip = applyOffset(ip, off);
                        if (off < 0) {
                            if (try loopSafePoint(realm, f, ip, acc)) |r| return r;
                            // docs/jit.md §12 3f — OSR: a loop hot enough to
                            // tier up enters compiled code at this back-edge's
                            // header; loopSafePoint synced the frame, so the
                            // switch is a jump. Inline-guarded — back-edges are
                            // the hottest dispatch path.
                            // Cheap precheck — a 5M-iteration interpreted loop
                            // cannot afford a function call per back-edge: call
                            // only when tier-up is plausibly due (cold and past
                            // the threshold floor) or an OSR table exists and is
                            // not striking out.
                            const osr_worth = realm.jit_enabled and worth: {
                                const js_ = f.chunk.jit_state orelse break :worth false;
                                if (js_.tier == .dont_compile) break :worth false;
                                if (js_.tier == .cold) {
                                    const floor = realm.jit_threshold_override orelse bistromath.tier_up_base;
                                    break :worth js_.warmth >= floor;
                                }
                                break :worth js_.osr_ptr != null and js_.osr_strikes < bistromath.osr_strike_limit;
                            };
                            if (osr_worth) {
                                switch (try bistromath.tryOsrEnterTop(allocator, realm, frames)) {
                                    .not_entered => {},
                                    .resumed => {
                                        committed = true;
                                        continue :dispatch try reEnterDispatch(frames, &f, &local_chunk, &code, &registers, &ip, &acc, &committed);
                                    },
                                    .completed => |ret| {
                                        if (frames.items.len == 0) return .{ .value = ret };
                                        frames.items[frames.items.len - 1].accumulator = ret;
                                        committed = true;
                                        continue :dispatch try reEnterDispatch(frames, &f, &local_chunk, &code, &registers, &ip, &acc, &committed);
                                    },
                                    .threw => |ex| {
                                        if (!try unwindThrow(allocator, realm, frames, ex)) return .{ .thrown = ex };
                                        committed = true;
                                        continue :dispatch try reEnterDispatch(frames, &f, &local_chunk, &code, &registers, &ip, &acc, &committed);
                                    },
                                }
                            }
                        }
                    }
                    continue :dispatch try decodeNext(code, &ip, &committed);
                }
            }
            // Slow path — replicate the unfused `inc` + `lt` +
            // `jmp_if_true` semantics so a non-int32 counter
            // (e.g. crossed into double via overflow) or a
            // non-int32 bound (string, BigInt, …) stays
            // observably identical to the unfused sequence the
            // compiler would have emitted otherwise.
            const bumped = (try arith.incOrDec(realm, c, 1)) orelse {
                const ex = realm.pending_exception orelse try makeTypeError(realm, "Update failed");
                realm.pending_exception = null;
                f.ip = ip;
                f.accumulator = acc;
                committed = true;
                if (!try unwindThrow(allocator, realm, frames, ex)) return .{ .thrown = ex };
                continue :dispatch try reEnterDispatch(frames, &f, &local_chunk, &code, &registers, &ip, &acc, &committed);
            };
            registers[r_counter] = bumped;
            const lhs = try coerceForCompare(allocator, realm, frames, f, ip, bumped, .number);
            if (lhs == .uncaught) return .{ .thrown = lhs.uncaught };
            if (lhs == .handled) {
                committed = true;
                continue :dispatch try reEnterDispatch(frames, &f, &local_chunk, &code, &registers, &ip, &acc, &committed);
            }
            const rhs = try coerceForCompare(allocator, realm, frames, f, ip, b, .number);
            if (rhs == .uncaught) return .{ .thrown = rhs.uncaught };
            if (rhs == .handled) {
                committed = true;
                continue :dispatch try reEnterDispatch(frames, &f, &local_chunk, &code, &registers, &ip, &acc, &committed);
            }
            const cmp = relational(.lt, realm, lhs.ok, rhs.ok) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.NativeThrew => {
                    const ex = realm.pending_exception orelse try makeTypeError(realm, "comparison threw");
                    realm.pending_exception = null;
                    f.ip = ip;
                    f.accumulator = acc;
                    if (!try unwindThrow(allocator, realm, frames, ex)) return .{ .thrown = ex };
                    committed = true;
                    continue :dispatch try reEnterDispatch(frames, &f, &local_chunk, &code, &registers, &ip, &acc, &committed);
                },
            };
            if (toBoolean(cmp)) {
                ip = applyOffset(ip, off);
                if (off < 0) {
                    if (try loopSafePoint(realm, f, ip, acc)) |r| return r;
                    // docs/jit.md §12 3f — OSR: a loop hot enough to
                    // tier up enters compiled code at this back-edge's
                    // header; loopSafePoint synced the frame, so the
                    // switch is a jump. Inline-guarded — back-edges are
                    // the hottest dispatch path.
                    // Cheap precheck — a 5M-iteration interpreted loop
                    // cannot afford a function call per back-edge: call
                    // only when tier-up is plausibly due (cold and past
                    // the threshold floor) or an OSR table exists and is
                    // not striking out.
                    const osr_worth = realm.jit_enabled and worth: {
                        const js_ = f.chunk.jit_state orelse break :worth false;
                        if (js_.tier == .dont_compile) break :worth false;
                        if (js_.tier == .cold) {
                            const floor = realm.jit_threshold_override orelse bistromath.tier_up_base;
                            break :worth js_.warmth >= floor;
                        }
                        break :worth js_.osr_ptr != null and js_.osr_strikes < bistromath.osr_strike_limit;
                    };
                    if (osr_worth) {
                        switch (try bistromath.tryOsrEnterTop(allocator, realm, frames)) {
                            .not_entered => {},
                            .resumed => {
                                committed = true;
                                continue :dispatch try reEnterDispatch(frames, &f, &local_chunk, &code, &registers, &ip, &acc, &committed);
                            },
                            .completed => |ret| {
                                if (frames.items.len == 0) return .{ .value = ret };
                                frames.items[frames.items.len - 1].accumulator = ret;
                                committed = true;
                                continue :dispatch try reEnterDispatch(frames, &f, &local_chunk, &code, &registers, &ip, &acc, &committed);
                            },
                            .threw => |ex| {
                                if (!try unwindThrow(allocator, realm, frames, ex)) return .{ .thrown = ex };
                                committed = true;
                                continue :dispatch try reEnterDispatch(frames, &f, &local_chunk, &code, &registers, &ip, &acc, &committed);
                            },
                        }
                    }
                }
            }
            continue :dispatch try decodeNext(code, &ip, &committed);
        },

        // ── Functions / calls ───────────────────────────────────────
        .make_function, .make_named_function_expr => |op_tag| {
            const k = readU16(code, ip);
            ip += 2;
            if (k >= local_chunk.function_templates.len) return error.InvalidOpcode;
            const tmpl = &local_chunk.function_templates[k];
            // §15.6.5 InstantiateOrdinaryFunctionExpression for a
            // NAMED function expression: allocate a 1-slot wrapper
            // env, instantiate the function capturing it, seed slot
            // 0 with the function itself. The binding is immutable
            // — user-visible writes lower to `throw_assign_const`
            // at compile time (§8.1.1.1.4 step 9.b TypeError).
            const captured_env = if (op_tag == .make_named_function_expr)
                realm.heap.allocateEnvironment(f.env, 1) catch return error.OutOfMemory
            else
                f.env;
            const fn_obj = realm.heap.allocateFunction(
                &tmpl.chunk,
                tmpl.param_count,
                tmpl.name,
                tmpl.is_arrow,
                captured_env,
            ) catch return error.OutOfMemory;
            // §10.4.1 GetActiveScriptOrModule — record the
            // module the function is defined in so a later
            // `import.meta` access (or any future
            // ScriptOrModule-dependent op) reads the
            // function's own module, not its caller's. The
            // call-site dispatch saves and restores
            // `realm.current_module` accordingly.
            fn_obj.owning_module = realm.current_module;
            // §10.2.5 GetFunctionRealm — every user function is
            // created in the realm whose interpreter is
            // currently running. Crucial for the cross-realm
            // species carve-outs (e.g. ArraySpeciesCreate
            // §23.1.3.34 step 4.a): a `class C extends Array`
            // declared inside `$262.createRealm()` must report
            // itself as belonging to the child realm so the
            // caller-realm's `Array.prototype.map` falls back
            // to `%Array%` instead of forwarding to the child
            // constructor.
            fn_obj.realm = f.running_realm orelse realm;
            if (op_tag == .make_named_function_expr) {
                // Routed through `storeEnvSlot` so the
                // generational write barrier sees the
                // self-binding store (a mature named-fn-expr
                // scope getting a young function pointer).
                realm.heap.storeEnvSlot(captured_env.?, 0, heap_mod.taggedFunction(fn_obj));
            }
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
            if (tmpl.is_arrow) {
                realm.heap.setCapturedThis(fn_obj, f.this_value);
                // §13.3.12 NewTarget / §10.2.5 [[HomeObject]] /
                // §13.3.7 super — arrows inherit all three from
                // the enclosing function. The arrow has no
                // execution-context binding of its own; `super`
                // inside an arrow body resolves against the
                // home of the nearest enclosing non-arrow
                // function (which `f`'s slots already encode,
                // because a nested arrow's frame also inherits
                // its parent arrow's captures via this same op).
                realm.heap.setCapturedNewTarget(fn_obj, f.new_target);
                realm.heap.setHomeObject(fn_obj, f.home_object);
                realm.heap.setHomeFunction(fn_obj, f.home_function);
                // §10.2.1.4 / §13.3.7 — an arrow inside a
                // derived-class constructor (or transitively
                // inside a nested arrow) shares the outer
                // ctor's `[[ThisBindingStatus]]` cell. Lazy-
                // allocate on first need. The cell lives until
                // the realm tears down (see Realm.derived_ctor_cells).
                if (f.is_derived_ctor) {
                    if (f.super_called_cell == null) {
                        const cell = realm.allocator.create(bool) catch return error.OutOfMemory;
                        cell.* = f.super_called;
                        realm.derived_ctor_cells.append(realm.allocator, cell) catch {
                            realm.allocator.destroy(cell);
                            return error.OutOfMemory;
                        };
                        f.super_called_cell = cell;
                    }
                    fn_obj.super_called_cell = f.super_called_cell;
                } else if (f.super_called_cell) |cell| {
                    // Nested arrow inside a non-ctor frame
                    // that itself inherited a cell — propagate
                    // through (lexical chain of arrows back to
                    // the derived ctor).
                    fn_obj.super_called_cell = cell;
                }
            }
            fn_obj.is_generator = tmpl.is_generator;
            fn_obj.is_async = tmpl.is_async;
            // §27.3.1 / §27.4 / §27.7 — generator functions,
            // async generator functions, and async functions have
            // no [[Construct]] internal method. `new g()` must
            // throw TypeError. `allocateFunction` defaults to
            // `has_construct = true` for non-arrow templates; drop
            // it for these flavours.
            if (tmpl.is_generator or tmpl.is_async) {
                fn_obj.has_construct = false;
            }
            // §27.3.5 / §27.4.5 — `function*(){}.prototype` /
            // `async function*(){}.prototype` is an ordinary
            // object whose `[[Prototype]]` is `%GeneratorPrototype%`
            // / `%AsyncGeneratorPrototype%`, with NO own
            // `constructor` property. `allocateFunction` always
            // installs `constructor` for non-arrows — undo for
            // the generator variants and rewire the proto chain.
            if (tmpl.is_generator) {
                if (fn_obj.prototype) |proto| {
                    // The shadow shape only describes ADDITIONS; a
                    // removal can't be encoded as a transition, so
                    // demote to dictionary mode before mutating the
                    // bag. Without this, `verifyShapeInvariant`
                    // panics under GC stress because the shape
                    // still claims `constructor` is at its slot
                    // while `properties` no longer has the entry.
                    try proto.demoteFromShape(allocator);
                    _ = proto.properties.swapRemove("constructor");
                    _ = proto.property_flags.swapRemove("constructor");
                    realm.heap.setObjectPrototype(proto, if (tmpl.is_async)
                        ensureAsyncGeneratorPrototype(realm) catch realm.intrinsics.object_prototype
                    else
                        ensureGeneratorPrototype(realm) catch realm.intrinsics.object_prototype);
                }
            } else if (tmpl.is_async) {
                // §27.7.4 — `async function f(){}` does NOT have
                // an own `prototype` slot (unlike sync functions
                // and generator / async-generator functions).
                // `allocateFunction` auto-installs one for every
                // non-arrow; drop it so reads return `undefined`
                // and `Object.defineProperty(f, 'prototype', {…})`
                // succeeds as a fresh data / accessor descriptor.
                realm.heap.setFunctionPrototype(fn_obj, null);
            } else if (fn_obj.prototype) |proto| {
                // §10.2.4 — a regular function's `.prototype`
                // object inherits from `%Object.prototype%`.
                // `allocateFunction` couldn't set this without
                // the realm in scope, so wire it here.
                if (proto.prototype == null) {
                    realm.heap.setObjectPrototype(proto, realm.intrinsics.object_prototype);
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
            continue :dispatch try decodeNext(code, &ip, &committed);
        },
        .direct_eval => {
            // §19.2.1 direct eval. Operands: scope:u16, r_callee:u8,
            // argc:u8. Args are at `r_callee+1 .. r_callee+argc`.
            const scope_idx = readU16(code, ip);
            const r_callee = code[ip + 2];
            const argc = code[ip + 3];
            ip += 4;

            const callee_v = registers[r_callee];
            const args_start = @as(usize, r_callee) + 1;
            const args_slice = registers[args_start .. args_start + argc];

            // §19.2.1.1 — the call is a direct eval only when the
            // callee is this realm's %eval% intrinsic. Otherwise (a
            // reassigned `globalThis.eval`, a cross-realm eval) it's
            // an ordinary call.
            const is_intrinsic_eval = blk: {
                const fnobj = heap_mod.valueAsFunction(callee_v) orelse break :blk false;
                break :blk realm.intrinsics.eval_function == fnobj;
            };
            if (!is_intrinsic_eval) {
                const cresult = try callValue(allocator, realm, f.running_realm orelse realm, callee_v, Value.undefined_, args_slice);
                switch (cresult) {
                    .value, .yielded => |v| {
                        acc = v;
                        continue :dispatch try decodeNext(code, &ip, &committed);
                    },
                    .thrown => |ex| {
                        f.ip = ip;
                        f.accumulator = acc;
                        committed = true;
                        if (!try unwindThrow(allocator, realm, frames, ex)) {
                            return .{ .thrown = ex };
                        }
                        continue :dispatch try reEnterDispatch(frames, &f, &local_chunk, &code, &registers, &ip, &acc, &committed);
                    },
                }
            }

            // §19.2.1 step 2 — a non-String argument is returned
            // unchanged (no source is evaluated).
            const arg0 = if (argc > 0) registers[args_start] else Value.undefined_;
            if (!arg0.isString()) {
                acc = arg0;
                continue :dispatch try decodeNext(code, &ip, &committed);
            }

            // Gate closed → host refusal (EvalError, §19.2.1.2
            // HostEnsureCanCompileStrings), matching the indirect
            // `eval` native and the default posture.
            if (!realm.allow_eval) {
                const ex = try makeEvalError(realm, intrinsics_mod.eval_disabled_msg);
                f.ip = ip;
                f.accumulator = acc;
                committed = true;
                if (!try unwindThrow(allocator, realm, frames, ex)) {
                    return .{ .thrown = ex };
                }
                continue :dispatch try reEnterDispatch(frames, &f, &local_chunk, &code, &registers, &ip, &acc, &committed);
            }

            // Direct eval — compile against the caller's scope snapshot
            // and run with the caller's `this` / env inherited. Flush
            // ip/acc onto the frame first: `evaluateDirectEval`
            // allocates + runs JS, so a GC during it must see the
            // current frame state.
            const src_str: *JSString = @ptrCast(@alignCast(arg0.asString()));
            const snapshot = &local_chunk.direct_eval_scopes[scope_idx];
            const ctx: DirectEvalContext = .{
                .this_value = f.this_value,
                .new_target = f.new_target,
                .home_object = f.home_object,
                .home_function = f.home_function,
                .running_realm = f.running_realm,
                .owning_module = f.owning_module,
                .parent_env = f.env,
                .is_derived_ctor = f.is_derived_ctor,
                .super_called_cell = f.super_called_cell,
            };
            f.ip = ip;
            f.accumulator = acc;
            committed = true;
            const eresult = evaluateDirectEval(allocator, realm, src_str.flatBytes(), snapshot, ctx) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.InvalidOpcode => return error.InvalidOpcode,
                // Deeply nested eval source exhausts the parser stack —
                // a RangeError, matching V8 / JSC and the diagnostic's
                // own `range_error` class (see `too_deeply_nested`).
                error.ParseRangeError => {
                    const ex = try makeRangeError(realm, "Maximum call stack size exceeded");
                    if (!try unwindThrow(allocator, realm, frames, ex)) {
                        return .{ .thrown = ex };
                    }
                    continue :dispatch try reEnterDispatch(frames, &f, &local_chunk, &code, &registers, &ip, &acc, &committed);
                },
                // §19.2.1 step 11 — a parse / compile failure is a
                // SyntaxError raised in the caller.
                error.ParseError, error.CompileError => {
                    const ex = try makeSyntaxError(realm, "eval: SyntaxError in evaluated source");
                    if (!try unwindThrow(allocator, realm, frames, ex)) {
                        return .{ .thrown = ex };
                    }
                    continue :dispatch try reEnterDispatch(frames, &f, &local_chunk, &code, &registers, &ip, &acc, &committed);
                },
            };
            switch (eresult) {
                .value, .yielded => |v| {
                    // The eval ran in its own `runFrames` re-entry — no
                    // frame was pushed onto this stack, so reload the
                    // (unchanged) active frame and continue past the op.
                    acc = v;
                    f.accumulator = v;
                    continue :dispatch try reEnterDispatch(frames, &f, &local_chunk, &code, &registers, &ip, &acc, &committed);
                },
                .thrown => |ex| {
                    if (!try unwindThrow(allocator, realm, frames, ex)) {
                        return .{ .thrown = ex };
                    }
                    continue :dispatch try reEnterDispatch(frames, &f, &local_chunk, &code, &registers, &ip, &acc, &committed);
                },
            }
        },
        .direct_eval_spread => {
            // §13.3.6.1 / §19.2.1 — direct eval whose argument list
            // contained a spread: the args were materialised into a
            // real array by the spread-call lowering. Mirrors the
            // `.direct_eval` arm; only the argument sourcing differs.
            // Operands: scope:u16, r_callee:u8, r_args:u8.
            const scope_idx = readU16(code, ip);
            const r_callee = code[ip + 2];
            const r_args = code[ip + 3];
            ip += 4;

            const callee_v = registers[r_callee];
            const args_obj = heap_mod.valueAsPlainObject(registers[r_args]) orelse return error.InvalidOpcode;
            const argc_v = args_obj.get("length");
            const argc_n: u32 = if (argc_v.isInt32()) @intCast(@max(0, argc_v.asInt32())) else 0;

            const is_intrinsic_eval = blk: {
                const fnobj = heap_mod.valueAsFunction(callee_v) orelse break :blk false;
                break :blk realm.intrinsics.eval_function == fnobj;
            };
            if (!is_intrinsic_eval) {
                // Reassigned / cross-realm `eval` — ordinary call with
                // the unpacked array elements (cold path).
                const args_slice = try allocator.alloc(Value, argc_n);
                defer allocator.free(args_slice);
                var ai: u32 = 0;
                while (ai < argc_n) : (ai += 1) {
                    var kbuf: [12]u8 = undefined;
                    const key = std.fmt.bufPrint(&kbuf, "{d}", .{ai}) catch unreachable;
                    args_slice[ai] = args_obj.get(key);
                }
                const cresult = try callValue(allocator, realm, f.running_realm orelse realm, callee_v, Value.undefined_, args_slice);
                switch (cresult) {
                    .value, .yielded => |v| {
                        acc = v;
                        continue :dispatch try decodeNext(code, &ip, &committed);
                    },
                    .thrown => |ex| {
                        f.ip = ip;
                        f.accumulator = acc;
                        committed = true;
                        if (!try unwindThrow(allocator, realm, frames, ex)) {
                            return .{ .thrown = ex };
                        }
                        continue :dispatch try reEnterDispatch(frames, &f, &local_chunk, &code, &registers, &ip, &acc, &committed);
                    },
                }
            }

            // §19.2.1 step 2 — a non-String first argument is returned
            // unchanged; an empty argument list yields undefined.
            const arg0 = if (argc_n > 0) args_obj.get("0") else Value.undefined_;
            if (!arg0.isString()) {
                acc = arg0;
                continue :dispatch try decodeNext(code, &ip, &committed);
            }

            if (!realm.allow_eval) {
                const ex = try makeEvalError(realm, intrinsics_mod.eval_disabled_msg);
                f.ip = ip;
                f.accumulator = acc;
                committed = true;
                if (!try unwindThrow(allocator, realm, frames, ex)) {
                    return .{ .thrown = ex };
                }
                continue :dispatch try reEnterDispatch(frames, &f, &local_chunk, &code, &registers, &ip, &acc, &committed);
            }

            const src_str: *JSString = @ptrCast(@alignCast(arg0.asString()));
            const snapshot = &local_chunk.direct_eval_scopes[scope_idx];
            const ctx: DirectEvalContext = .{
                .this_value = f.this_value,
                .new_target = f.new_target,
                .home_object = f.home_object,
                .home_function = f.home_function,
                .running_realm = f.running_realm,
                .owning_module = f.owning_module,
                .parent_env = f.env,
                .is_derived_ctor = f.is_derived_ctor,
                .super_called_cell = f.super_called_cell,
            };
            f.ip = ip;
            f.accumulator = acc;
            committed = true;
            const eresult = evaluateDirectEval(allocator, realm, src_str.flatBytes(), snapshot, ctx) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.InvalidOpcode => return error.InvalidOpcode,
                error.ParseRangeError => {
                    const ex = try makeRangeError(realm, "Maximum call stack size exceeded");
                    if (!try unwindThrow(allocator, realm, frames, ex)) {
                        return .{ .thrown = ex };
                    }
                    continue :dispatch try reEnterDispatch(frames, &f, &local_chunk, &code, &registers, &ip, &acc, &committed);
                },
                error.ParseError, error.CompileError => {
                    const ex = try makeSyntaxError(realm, "eval: SyntaxError in evaluated source");
                    if (!try unwindThrow(allocator, realm, frames, ex)) {
                        return .{ .thrown = ex };
                    }
                    continue :dispatch try reEnterDispatch(frames, &f, &local_chunk, &code, &registers, &ip, &acc, &committed);
                },
            };
            switch (eresult) {
                .value, .yielded => |v| {
                    acc = v;
                    f.accumulator = v;
                    continue :dispatch try reEnterDispatch(frames, &f, &local_chunk, &code, &registers, &ip, &acc, &committed);
                },
                .thrown => |ex| {
                    if (!try unwindThrow(allocator, realm, frames, ex)) {
                        return .{ .thrown = ex };
                    }
                    continue :dispatch try reEnterDispatch(frames, &f, &local_chunk, &code, &registers, &ip, &acc, &committed);
                },
            }
        },
        .call => {
            const r_callee = code[ip];
            const argc = code[ip + 1];
            const ic_idx = readU16(code, ip + 2);
            ip += 4;

            const callee_v = registers[r_callee];
            const call_cell = &local_chunk.inline_call_caches[ic_idx];

            // Inline cache: a hit means the same callee was here last
            // time AND it survived every exotic-callee check (proxy,
            // revocable, bound, wrapped, class constructor). Skip the
            // entire dispatch chain below and fall through to the
            // generator / native / async / regular call path.
            //
            // The IC is GC-aware: the heap's mark walk weak-clears
            // any cell whose callee isn't reachable through other
            // refs, so a swept-and-reused address cannot match.
            // Same `CallICCell` shape as `call_method`.
            const callee_fn = blk: {
                if (call_cell.callee) |cached| {
                    if (heap_mod.valueAsFunction(callee_v)) |fn_obj| {
                        if (fn_obj == cached) break :blk fn_obj;
                    }
                }

                // Slow path — exotic-callee dispatch.

                // §10.5.13 callable Proxy [[Call]] — if the callee
                // is a proxy, route through `callValue` which
                // handles the apply trap and chained proxies.
                if (heap_mod.valueAsPlainObject(callee_v)) |po| {
                    if (po.proxy_target_fn != null or po.proxy_target != null or po.proxy_revoked) {
                        const args_start = @as(usize, r_callee) + 1;
                        const args_slice = registers[args_start .. args_start + argc];
                        const cresult = try callValue(allocator, realm, f.running_realm orelse realm, callee_v, Value.undefined_, args_slice);
                        switch (cresult) {
                            .value, .yielded => |v| {
                                acc = v;
                                // `callValue` ran the callee in its own
                                // runFrames re-entry — no frame pushed onto
                                // this stack, the active frame is unchanged
                                // → decodeNext. reEnterDispatch would reload
                                // a stale `f.ip` and re-run this call.
                                continue :dispatch try decodeNext(code, &ip, &committed);
                            },
                            .thrown => |ex| {
                                f.ip = ip;
                                f.accumulator = acc;
                                committed = true;
                                if (!try unwindThrow(allocator, realm, frames, ex)) {
                                    return .{ .thrown = ex };
                                }
                                continue :dispatch try reEnterDispatch(frames, &f, &local_chunk, &code, &registers, &ip, &acc, &committed);
                            },
                        }
                    }
                    // §20.2.3 %Function.prototype% [[Call]] — "the
                    // Function prototype object is itself a built-in
                    // function object that, when invoked, accepts any
                    // arguments and returns undefined." Cynic stores
                    // it as a JSObject (not a JSFunction) so the
                    // identity check is the cheapest dispatch path.
                    if (realm.intrinsics.function_prototype == po) {
                        acc = Value.undefined_;
                        continue :dispatch try decodeNext(code, &ip, &committed);
                    }
                }
                const fn_v = heap_mod.valueAsFunction(callee_v) orelse {
                    const ex = try makeTypeError(realm, "value is not callable");
                    f.ip = ip;
                    f.accumulator = acc;
                    committed = true;
                    if (!try unwindThrow(allocator, realm, frames, ex)) {
                        return .{ .thrown = ex };
                    }
                    continue :dispatch try reEnterDispatch(frames, &f, &local_chunk, &code, &registers, &ip, &acc, &committed);
                };

                // §15.7.14 step 1 — class constructors are not
                // callable without `new`; reject with TypeError.
                // Checked inside the blk so the IC cell never
                // caches a class-constructor callee (the next call
                // would skip this check and try to invoke it).
                if (fn_v.is_class_constructor) {
                    const ex = try makeTypeError(fn_v.realm orelse realm, "Class constructor cannot be invoked without 'new'");
                    f.ip = ip;
                    f.accumulator = acc;
                    committed = true;
                    if (!try unwindThrow(allocator, realm, frames, ex)) {
                        return .{ .thrown = ex };
                    }
                    continue :dispatch try reEnterDispatch(frames, &f, &local_chunk, &code, &registers, &ip, &acc, &committed);
                }

                // §28.2.2.1.1 — revocation function. Calling it
                // clears the captured proxy's internal slots.
                // First call returns undefined and clears the slot;
                // subsequent calls no-op (slot is null).
                if (fn_v.revocable_proxy) |rp| {
                    realm.heap.setProxyTarget(rp, null);
                    realm.heap.setProxyHandler(rp, null);
                    realm.heap.setProxyTargetFn(rp, null);
                    rp.proxy_revoked = true;
                    fn_v.revocable_proxy = null;
                    acc = Value.undefined_;
                    // No frame pushed, no inline call — the active frame
                    // is unchanged → decodeNext.
                    continue :dispatch try decodeNext(code, &ip, &committed);
                }

                // §3.8.3.6 WrappedFunction — cross-realm callable
                // boundary. The inline call fast-path can't marshal
                // args/return through the §3.8.3.4 filter; delegate
                // to `callJSFunction` which routes into the boundary
                // handler in `shadow_realm.zig`.
                if (!fn_v.wrapped_target.isUndefined()) {
                    const args_start = @as(usize, r_callee) + 1;
                    const result = try callJSFunction(allocator, realm, fn_v, Value.undefined_, registers[args_start .. args_start + argc]);
                    switch (result) {
                        .value, .yielded => |v| acc = v,
                        .thrown => |ex| {
                            f.ip = ip;
                            f.accumulator = acc;
                            committed = true;
                            if (!try unwindThrow(allocator, realm, frames, ex)) {
                                return .{ .thrown = ex };
                            }
                            continue :dispatch try reEnterDispatch(frames, &f, &local_chunk, &code, &registers, &ip, &acc, &committed);
                        },
                    }
                    continue :dispatch try decodeNext(code, &ip, &committed);
                }

                // §10.4.1 — bound functions unwrap and re-enter
                // through `callJSFunction` (which builds a fresh
                // frame stack with the concatenated args). Plain
                // calls pass `this = undefined` (strict).
                if (fn_v.bound_target != null) {
                    // §10.2.1 step 2 — the bound wrapper's own
                    // `is_class_constructor` is false, but the
                    // inner target preserves the class-ctor brand.
                    // `Subclass.bind(obj)(...)` must throw.
                    var inner_target = fn_v;
                    while (inner_target.bound_target) |i_t| inner_target = i_t;
                    if (inner_target.is_class_constructor) {
                        const ex = try makeTypeError(inner_target.realm orelse realm, "Class constructor cannot be invoked without 'new'");
                        f.ip = ip;
                        f.accumulator = acc;
                        committed = true;
                        if (!try unwindThrow(allocator, realm, frames, ex)) {
                            return .{ .thrown = ex };
                        }
                        continue :dispatch try reEnterDispatch(frames, &f, &local_chunk, &code, &registers, &ip, &acc, &committed);
                    }
                    const args_start = @as(usize, r_callee) + 1;
                    const result = try callJSFunction(allocator, realm, fn_v, Value.undefined_, registers[args_start .. args_start + argc]);
                    switch (result) {
                        .value, .yielded => |v| acc = v,
                        .thrown => |ex| {
                            f.ip = ip;
                            f.accumulator = acc;
                            committed = true;
                            if (!try unwindThrow(allocator, realm, frames, ex)) {
                                return .{ .thrown = ex };
                            }
                            continue :dispatch try reEnterDispatch(frames, &f, &local_chunk, &code, &registers, &ip, &acc, &committed);
                        },
                    }
                    // `callJSFunction` ran the bound target in its own
                    // runFrames re-entry — no frame pushed onto this
                    // stack, the active frame is unchanged → decodeNext.
                    continue :dispatch try decodeNext(code, &ip, &committed);
                }

                // Survived every exotic check — `fn_v` is a plain
                // function. Refill the IC so the next call takes
                // the fast path.
                call_cell.callee = fn_v;
                break :blk fn_v;
            };

            // §27.5 / §27.6 — calling a `function*` or
            // `async function*` allocates a generator wrapper
            // instead of running the body. Async-generator
            // gets the Promise-wrapping prototype.
            if (callee_fn.is_generator) {
                const callee_chunk = callee_fn.chunk orelse return error.InvalidOpcode;
                const args_start = @as(usize, r_callee) + 1;
                const wrap_result = if (callee_fn.is_async)
                    try wrapAsyncGenerator(allocator, realm, callee_chunk, callee_fn.captured_env, Value.undefined_, registers[args_start .. args_start + argc], callee_fn.home_object, callee_fn.home_function, callee_fn)
                else
                    try wrapGenerator(allocator, realm, callee_chunk, callee_fn.captured_env, Value.undefined_, registers[args_start .. args_start + argc], callee_fn.home_object, callee_fn.home_function, callee_fn);
                switch (wrap_result) {
                    .value, .yielded => |v| acc = v,
                    .thrown => |ex| {
                        f.ip = ip;
                        f.accumulator = acc;
                        committed = true;
                        if (!try unwindThrow(allocator, realm, frames, ex)) {
                            return .{ .thrown = ex };
                        }
                        continue :dispatch try reEnterDispatch(frames, &f, &local_chunk, &code, &registers, &ip, &acc, &committed);
                    },
                }
                // Generator object built inline — no dispatch frame
                // pushed (the body runs later via resumeGenerator).
                // Frame unchanged → decodeNext.
                continue :dispatch try decodeNext(code, &ip, &committed);
            }

            // Native fast path — no frame, no register file,
            // no env. The host fn reads args directly from the
            // caller's register file and returns a value.
            // Plain `Call` passes `this = undefined` (strict);
            // §15.3.4 — arrow functions read `this` from their
            // creation site (captured at MakeFunction time),
            // not the call site.
            if (callee_fn.native_callback) |native| {
                // §10.2.5 — see callJSFunction: record the callee's
                // realm so a cross-realm-shared native (ShadowRealm
                // methods) reads its own function realm. Save /
                // restore for nested native calls.
                const prior_fn_realm = realm.active_native_fn_realm;
                realm.active_native_fn_realm = callee_fn.realm;
                defer realm.active_native_fn_realm = prior_fn_realm;
                const prior_active_native_fn = realm.active_native_fn;
                realm.active_native_fn = callee_fn;
                defer realm.active_native_fn = prior_active_native_fn;
                const args_start = @as(usize, r_callee) + 1;
                const args = registers[args_start .. args_start + argc];
                const native_this: Value = if (callee_fn.is_arrow)
                    callee_fn.captured_this
                else
                    Value.undefined_;
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
                        continue :dispatch try reEnterDispatch(frames, &f, &local_chunk, &code, &registers, &ip, &acc, &committed);
                    },
                };
                acc = result;
                // Native ran inline — no frame pushed, the active
                // frame is unchanged. `decodeNext` keeps the loop-
                // local ip/acc; `reEnterDispatch` would reload a
                // stale `f.ip` and re-run this call forever.
                continue :dispatch try decodeNext(code, &ip, &committed);
            }

            // §27.7 — async function call. Start fresh, run the
            // body in its own re-entry of `runFrames`, settle the
            // result Promise on completion / throw, leave us
            // with the result Promise in `acc`.
            if (callee_fn.is_async) {
                const callee_chunk = callee_fn.chunk orelse return error.InvalidOpcode;
                const args_start = @as(usize, r_callee) + 1;
                const callee_this: Value = if (callee_fn.is_arrow) callee_fn.captured_this else Value.undefined_;
                const outcome = try startAsyncCall(allocator, realm, callee_chunk, callee_fn.captured_env, callee_this, registers[args_start .. args_start + argc], callee_fn.home_object, callee_fn.home_function, callee_fn.owning_module);
                switch (outcome) {
                    .value, .yielded => |v| acc = v,
                    .thrown => |ex| {
                        f.ip = ip;
                        f.accumulator = acc;
                        committed = true;
                        if (!try unwindThrow(allocator, realm, frames, ex)) {
                            return .{ .thrown = ex };
                        }
                        continue :dispatch try reEnterDispatch(frames, &f, &local_chunk, &code, &registers, &ip, &acc, &committed);
                    },
                }
                // Async body ran in its own runFrames re-entry — the
                // dispatch frame is unchanged → decodeNext.
                continue :dispatch try decodeNext(code, &ip, &committed);
            }

            if (frames.items.len >= max_call_frames) {
                const ex = try makeRangeError(realm, "Maximum call stack size exceeded");
                f.ip = ip;
                f.accumulator = acc;
                committed = true;
                if (!try unwindThrow(allocator, realm, frames, ex)) {
                    return .{ .thrown = ex };
                }
                continue :dispatch try reEnterDispatch(frames, &f, &local_chunk, &code, &registers, &ip, &acc, &committed);
            }

            const callee_chunk = callee_fn.chunk orelse return error.InvalidOpcode;
            const reg_count = @max(@as(usize, callee_chunk.register_count), @as(usize, argc));
            // value_stack first, FramePool on overflow — see
            // `.call_method` for the template's rationale.
            var is_stack_alloc = true;
            const callee_regs = realm.allocStackRegisters(reg_count) orelse blk: {
                is_stack_alloc = false;
                break :blk try realm.frame_pool.acquire(allocator, reg_count);
            };
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
            // §13.3.12 — arrows have no NewTarget of their own;
            // a `new.target` read inside the arrow body must
            // see the enclosing function's. Captured at
            // MakeFunction time alongside `captured_this`.
            const callee_new_target: Value = if (callee_fn.is_arrow)
                callee_fn.captured_new_target
            else
                Value.undefined_;

            frames.append(allocator, .{
                .chunk = callee_chunk,
                .ip = 0,
                .accumulator = Value.undefined_,
                .registers = callee_regs,
                .env = callee_fn.captured_env,
                .this_value = callee_this,
                .new_target = callee_new_target,
                .home_object = callee_fn.home_object,
                .home_function = callee_fn.home_function,
                .super_called_cell = callee_fn.super_called_cell,
                .argc = argc,
                .wrap_return_in_promise = false,
                .owning_module = callee_fn.owning_module,
                .running_realm = callee_fn.realm,
                .is_stack_alloc = is_stack_alloc,
            }) catch {
                if (is_stack_alloc) {
                    realm.freeStackRegisters(callee_regs);
                } else {
                    realm.frame_pool.release(allocator, callee_regs);
                }
                return error.OutOfMemory;
            };
            // JS callee — a new frame was pushed; the active
            // frame changed. reEnterDispatch loads the callee's
            // chunk / registers / ip=0. decodeNext would keep
            // running the caller against a reallocated stack.
            //
            // Bistromath first (docs/jit.md §4): a hot compiled
            // callee runs to completion here and hands its result
            // to the caller frame exactly as `return_` would; a
            // tier-down leaves the frame mid-chunk for
            // reEnterDispatch. Cold chunks fall straight through.
            switch (try bistromath.tryEnterTop(allocator, realm, frames)) {
                .not_entered => {},
                .completed => |jit_ret| {
                    frames.items[frames.items.len - 1].accumulator = jit_ret;
                },
                .threw => |ex| {
                    if (!try unwindThrow(allocator, realm, frames, ex)) {
                        return .{ .thrown = ex };
                    }
                },
            }
            continue :dispatch try reEnterDispatch(frames, &f, &local_chunk, &code, &registers, &ip, &acc, &committed);
        },

        .call_method => {
            const r_recv = code[ip];
            const r_callee = code[ip + 1];
            const argc = code[ip + 2];
            const ic_idx = readU16(code, ip + 3);
            ip += 5;

            const callee_v = registers[r_callee];
            const recv = registers[r_recv];
            const call_cell = &local_chunk.inline_call_caches[ic_idx];

            // Inline cache: a hit means the same callee was here
            // last time AND it was a plain (non-proxy, non-bound,
            // non-revocable) JSFunction. Skip the entire exotic
            // dispatch chain and fall through to the generator /
            // native / async / regular call section directly.
            //
            // The IC is GC-aware: the heap's mark walk weak-clears
            // any cell whose callee isn't reachable through other
            // refs, so a swept-and-reused address cannot match.
            const callee_fn = blk: {
                if (call_cell.callee) |cached| {
                    if (heap_mod.valueAsFunction(callee_v)) |fn_obj| {
                        if (fn_obj == cached) break :blk fn_obj;
                    }
                }

                // Slow path — original exotic dispatch.

                // §10.5.13 callable Proxy [[Call]] — route through
                // `callValue` (handles apply trap + chained proxies).
                if (heap_mod.valueAsPlainObject(callee_v)) |po| {
                    if (po.proxy_target_fn != null or po.proxy_target != null or po.proxy_revoked) {
                        const args_start = @as(usize, r_callee) + 1;
                        const args_slice = registers[args_start .. args_start + argc];
                        const cresult = try callValue(allocator, realm, f.running_realm orelse realm, callee_v, recv, args_slice);
                        switch (cresult) {
                            .value, .yielded => |v| {
                                acc = v;
                                // `callValue` ran the callee inline (its
                                // own runFrames re-entry) — active frame
                                // unchanged → decodeNext.
                                continue :dispatch try decodeNext(code, &ip, &committed);
                            },
                            .thrown => |ex| {
                                f.ip = ip;
                                f.accumulator = acc;
                                committed = true;
                                if (!try unwindThrow(allocator, realm, frames, ex)) {
                                    return .{ .thrown = ex };
                                }
                                continue :dispatch try reEnterDispatch(frames, &f, &local_chunk, &code, &registers, &ip, &acc, &committed);
                            },
                        }
                    }
                    // §20.2.3 %Function.prototype% [[Call]] — see
                    // the matching path on `.call`. Method-call
                    // shape doesn't change the spec answer: any
                    // call into %Function.prototype% returns
                    // undefined and ignores both `this` and args.
                    if (realm.intrinsics.function_prototype == po) {
                        acc = Value.undefined_;
                        continue :dispatch try decodeNext(code, &ip, &committed);
                    }
                }
                const fn_v = heap_mod.valueAsFunction(callee_v) orelse {
                    const ex = try makeTypeError(realm, "value is not callable");
                    f.ip = ip;
                    f.accumulator = acc;
                    committed = true;
                    if (!try unwindThrow(allocator, realm, frames, ex)) {
                        return .{ .thrown = ex };
                    }
                    continue :dispatch try reEnterDispatch(frames, &f, &local_chunk, &code, &registers, &ip, &acc, &committed);
                };

                // §28.2.2.1.1 — revocation function. See `.call`.
                if (fn_v.revocable_proxy) |rp| {
                    realm.heap.setProxyTarget(rp, null);
                    realm.heap.setProxyHandler(rp, null);
                    realm.heap.setProxyTargetFn(rp, null);
                    rp.proxy_revoked = true;
                    fn_v.revocable_proxy = null;
                    acc = Value.undefined_;
                    // No frame pushed, no inline call → decodeNext.
                    continue :dispatch try decodeNext(code, &ip, &committed);
                }

                // §10.4.1 — bound functions unwrap. `this = recv`
                // is overridden by the bound `this` inside
                // `unwrapBoundCall`.
                if (fn_v.bound_target != null) {
                    const args_start = @as(usize, r_callee) + 1;
                    const result = try callJSFunction(allocator, realm, fn_v, recv, registers[args_start .. args_start + argc]);
                    switch (result) {
                        .value, .yielded => |v| acc = v,
                        .thrown => |ex| {
                            f.ip = ip;
                            f.accumulator = acc;
                            committed = true;
                            if (!try unwindThrow(allocator, realm, frames, ex)) {
                                return .{ .thrown = ex };
                            }
                            continue :dispatch try reEnterDispatch(frames, &f, &local_chunk, &code, &registers, &ip, &acc, &committed);
                        },
                    }
                    // Bound target ran inline via `callJSFunction` —
                    // active frame unchanged → decodeNext.
                    continue :dispatch try decodeNext(code, &ip, &committed);
                }

                // Survived every exotic check — the callee is a
                // plain function. Refill the IC so the next call
                // takes the fast path.
                call_cell.callee = fn_v;
                break :blk fn_v;
            };

            // §27.5 / §27.6 — calling a `function*` or
            // `async function*` allocates a generator wrapper
            // instead of running the body. Methods on a `class`
            // body marked `*g()` or `async *g()` flow through
            // here too.
            if (callee_fn.is_generator) {
                const callee_chunk = callee_fn.chunk orelse return error.InvalidOpcode;
                const args_start = @as(usize, r_callee) + 1;
                const wrap_result = if (callee_fn.is_async)
                    try wrapAsyncGenerator(allocator, realm, callee_chunk, callee_fn.captured_env, recv, registers[args_start .. args_start + argc], callee_fn.home_object, callee_fn.home_function, callee_fn)
                else
                    try wrapGenerator(allocator, realm, callee_chunk, callee_fn.captured_env, recv, registers[args_start .. args_start + argc], callee_fn.home_object, callee_fn.home_function, callee_fn);
                switch (wrap_result) {
                    .value, .yielded => |v| acc = v,
                    .thrown => |ex| {
                        f.ip = ip;
                        f.accumulator = acc;
                        committed = true;
                        if (!try unwindThrow(allocator, realm, frames, ex)) {
                            return .{ .thrown = ex };
                        }
                        continue :dispatch try reEnterDispatch(frames, &f, &local_chunk, &code, &registers, &ip, &acc, &committed);
                    },
                }
                // Generator object built inline — no dispatch frame
                // pushed (the body runs later via resumeGenerator).
                // Frame unchanged → decodeNext.
                continue :dispatch try decodeNext(code, &ip, &committed);
            }

            // Native fast path — no frame, no register file.
            // §13.3.6 — `obj.method()` binds `this = obj`,
            // unless the method is an arrow function — §15.3.4
            // arrows ignore the call-site receiver and use
            // `captured_this` from their creation site.
            if (callee_fn.native_callback) |native| {
                // §10.2.5 — see callJSFunction: record the callee's
                // realm so a cross-realm-shared native (ShadowRealm
                // methods) reads its own function realm. Save /
                // restore for nested native calls.
                const prior_fn_realm = realm.active_native_fn_realm;
                realm.active_native_fn_realm = callee_fn.realm;
                defer realm.active_native_fn_realm = prior_fn_realm;
                const prior_active_native_fn = realm.active_native_fn;
                realm.active_native_fn = callee_fn;
                defer realm.active_native_fn = prior_active_native_fn;
                const args_start = @as(usize, r_callee) + 1;
                const args = registers[args_start .. args_start + argc];
                const native_this: Value = if (callee_fn.is_arrow)
                    callee_fn.captured_this
                else
                    recv;
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
                        continue :dispatch try reEnterDispatch(frames, &f, &local_chunk, &code, &registers, &ip, &acc, &committed);
                    },
                };
                acc = result;
                // Native ran inline — frame unchanged; decodeNext,
                // not reEnterDispatch (which would reload a stale ip).
                continue :dispatch try decodeNext(code, &ip, &committed);
            }

            if (callee_fn.is_async) {
                const callee_chunk = callee_fn.chunk orelse return error.InvalidOpcode;
                const args_start = @as(usize, r_callee) + 1;
                const callee_this: Value = if (callee_fn.is_arrow) callee_fn.captured_this else recv;
                const outcome = try startAsyncCall(allocator, realm, callee_chunk, callee_fn.captured_env, callee_this, registers[args_start .. args_start + argc], callee_fn.home_object, callee_fn.home_function, callee_fn.owning_module);
                switch (outcome) {
                    .value, .yielded => |v| acc = v,
                    .thrown => |ex| {
                        f.ip = ip;
                        f.accumulator = acc;
                        committed = true;
                        if (!try unwindThrow(allocator, realm, frames, ex)) {
                            return .{ .thrown = ex };
                        }
                        continue :dispatch try reEnterDispatch(frames, &f, &local_chunk, &code, &registers, &ip, &acc, &committed);
                    },
                }
                // Async body ran in its own runFrames re-entry — the
                // dispatch frame is unchanged → decodeNext.
                continue :dispatch try decodeNext(code, &ip, &committed);
            }

            if (frames.items.len >= max_call_frames) {
                const ex = try makeRangeError(realm, "Maximum call stack size exceeded");
                f.ip = ip;
                f.accumulator = acc;
                committed = true;
                if (!try unwindThrow(allocator, realm, frames, ex)) {
                    return .{ .thrown = ex };
                }
                continue :dispatch try reEnterDispatch(frames, &f, &local_chunk, &code, &registers, &ip, &acc, &committed);
            }

            const callee_chunk = callee_fn.chunk orelse return error.InvalidOpcode;
            const reg_count = @max(@as(usize, callee_chunk.register_count), @as(usize, argc));
            // Try the bump-allocated `value_stack` first — it
            // covers the LIFO common case (plain non-generator,
            // non-async JS callee whose register file's lifetime
            // is bounded by the frame). Falls through to the
            // heap-backed `frame_pool` when the stack would
            // overflow its pre-allocated buffer (which `Realm.init`
            // sizes for the 1024-frame `max_call_frames` ceiling
            // with headroom; only pathological workloads with
            // very wide frames spill).
            var is_stack_alloc = true;
            const callee_regs = realm.allocStackRegisters(reg_count) orelse blk: {
                is_stack_alloc = false;
                break :blk try realm.frame_pool.acquire(allocator, reg_count);
            };
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
            // §13.3.12 — arrows have no NewTarget of their own;
            // see `.call` above.
            const callee_new_target: Value = if (callee_fn.is_arrow)
                callee_fn.captured_new_target
            else
                Value.undefined_;

            frames.append(allocator, .{
                .chunk = callee_chunk,
                .ip = 0,
                .accumulator = Value.undefined_,
                .registers = callee_regs,
                .env = callee_fn.captured_env,
                .this_value = callee_this,
                .new_target = callee_new_target,
                .home_object = callee_fn.home_object,
                .home_function = callee_fn.home_function,
                .super_called_cell = callee_fn.super_called_cell,
                .argc = argc,
                .wrap_return_in_promise = false,
                .owning_module = callee_fn.owning_module,
                .running_realm = callee_fn.realm,
                .is_stack_alloc = is_stack_alloc,
            }) catch {
                // Release via the matching helper. Can't construct
                // a transient CallFrame here without restating
                // every field, so branch inline.
                if (is_stack_alloc) {
                    realm.freeStackRegisters(callee_regs);
                } else {
                    realm.frame_pool.release(allocator, callee_regs);
                }
                return error.OutOfMemory;
            };
            // JS callee — a new frame was pushed; the active
            // frame changed. reEnterDispatch loads the callee's
            // chunk / registers / ip=0. decodeNext would keep
            // running the caller against a reallocated stack.
            //
            // Bistromath first (docs/jit.md §4): a hot compiled
            // callee runs to completion here and hands its result
            // to the caller frame exactly as `return_` would; a
            // tier-down leaves the frame mid-chunk for
            // reEnterDispatch. Cold chunks fall straight through.
            switch (try bistromath.tryEnterTop(allocator, realm, frames)) {
                .not_entered => {},
                .completed => |jit_ret| {
                    frames.items[frames.items.len - 1].accumulator = jit_ret;
                },
                .threw => |ex| {
                    if (!try unwindThrow(allocator, realm, frames, ex)) {
                        return .{ .thrown = ex };
                    }
                },
            }
            continue :dispatch try reEnterDispatch(frames, &f, &local_chunk, &code, &registers, &ip, &acc, &committed);
        },

        // §13.3.6 EvaluateCall — fused property load + method call
        // for the simple `obj.method(args)` shape. Replaces a
        // 4-op `ldar + lda_property + star + call_method` sequence
        // with one dispatch. Hot path: receiver shape compare +
        // load cached own / proto slot + callee pointer compare +
        // direct `callJSFunction`. Slow path: `slowLookupForCallProperty`
        // (mirrors `lda_property`'s 11-arm receiver-type matrix)
        // followed by the same call-dispatch arms as `call_method`
        // (proxy / bound / revocable / native / generator / async /
        // regular).
        .call_property => {
            const k = readU16(code, ip);
            const r_recv = code[ip + 2];
            const argc = code[ip + 3];
            const ic_load_idx = readU16(code, ip + 4);
            const ic_call_idx = readU16(code, ip + 6);
            ip += 8;

            if (k >= local_chunk.constants.len) return error.InvalidOpcode;
            const key_v = local_chunk.constants[k];
            if (!key_v.isString()) return error.InvalidOpcode;
            const key_s: *JSString = @ptrCast(@alignCast(key_v.asString()));
            const recv = registers[r_recv];

            // Resolve the callee. Fast path: shape compare on the
            // receiver (and proto identity + proto_shape + proto_rev
            // for the proto-load mode), serve `recv.slots[slot]` or
            // `proto.slots[slot]`. Slow path: `slowLookupForCallProperty`.
            var callee_v: Value = Value.undefined_;
            var resolved_fast: bool = false;
            if (heap_mod.valueAsPlainObject(recv)) |obj_in| {
                const cell = &local_chunk.inline_caches[ic_load_idx];
                if (cell.shape != null and cell.shape == obj_in.shape) {
                    if (cell.proto) |proto| {
                        if (obj_in.prototype == proto and
                            proto.shape == cell.proto_shape and
                            cell.proto_rev == realm.proto_revision_counter)
                        {
                            callee_v = proto.slotAt(cell.slot);
                            resolved_fast = true;
                        }
                    } else {
                        callee_v = obj_in.slotAt(cell.slot);
                        resolved_fast = true;
                    }
                }
            }
            if (!resolved_fast) {
                const lookup = try slowLookupForCallProperty(allocator, realm, frames, f, ip, recv, key_s.flatBytes());
                callee_v = switch (lookup) {
                    .value => |v| v,
                    .handled => {
                        // The helper called `unwindThrow`, which
                        // already rewrote `f.ip` to the matching
                        // catch handler's PC. DO NOT overwrite it
                        // — `reEnterDispatch` reads `f.ip` to pick
                        // up at the catch. (Mirrors the
                        // `getThroughChain` `.handled` arm in
                        // `lda_property`'s slow path.)
                        committed = true;
                        continue :dispatch try reEnterDispatch(frames, &f, &local_chunk, &code, &registers, &ip, &acc, &committed);
                    },
                    .uncaught => |ex| return .{ .thrown = ex },
                };
                // Refill the load IC for the simple shape-claimed
                // own / proto-data case so the next call takes the
                // fast path. Anything more exotic (accessor, proxy,
                // module namespace, primitive auto-box) stays
                // un-cached — mirrors `lda_property`'s IC fill
                // policy.
                if (heap_mod.valueAsPlainObject(recv)) |obj_in| {
                    if (obj_in.shape) |sh| {
                        const cell = &local_chunk.inline_caches[ic_load_idx];
                        if (sh.lookup(key_s.flatBytes())) |entry| {
                            if (entry.kind == .data) {
                                cell.shape = sh;
                                cell.slot = entry.slot;
                                cell.proto = null;
                                cell.proto_shape = null;
                            }
                        } else if (!chainHasProxy(obj_in) and !obj_in.hasAccessor(key_s.flatBytes())) {
                            var cursor: ?*JSObject = obj_in.prototype;
                            while (cursor) |proto| : (cursor = proto.prototype) {
                                if (proto.proxy_target != null or proto.proxy_revoked) break;
                                if (proto.is_module_namespace) break;
                                if (proto.hasAccessor(key_s.flatBytes())) break;
                                if (proto.shape) |proto_sh| {
                                    if (proto_sh.lookup(key_s.flatBytes())) |entry| {
                                        if (entry.kind == .data) {
                                            cell.shape = sh;
                                            cell.slot = entry.slot;
                                            cell.proto = proto;
                                            cell.proto_shape = proto_sh;
                                            cell.proto_rev = realm.proto_revision_counter;
                                            break;
                                        }
                                    }
                                }
                                if (proto.ownDataContains(key_s.flatBytes())) break;
                            }
                        }
                    }
                }
            }

            // Call IC: pointer-compare the loaded callee against the
            // cached `JSFunction*`. A hit skips the entire exotic-
            // dispatch chain below (proxy / revocable / bound /
            // `valueAsFunction`) and goes straight to the
            // generator / native / async / regular call.
            const call_cell = &local_chunk.inline_call_caches[ic_call_idx];
            const callee_fn = blk: {
                if (call_cell.callee) |cached| {
                    if (heap_mod.valueAsFunction(callee_v)) |fn_obj| {
                        if (fn_obj == cached) break :blk fn_obj;
                    }
                }

                // §10.5.13 callable Proxy [[Call]].
                if (heap_mod.valueAsPlainObject(callee_v)) |po| {
                    if (po.proxy_target_fn != null or po.proxy_target != null or po.proxy_revoked) {
                        const args_start = @as(usize, r_recv) + 1;
                        const args_slice = registers[args_start .. args_start + argc];
                        const cresult = try callValue(allocator, realm, f.running_realm orelse realm, callee_v, recv, args_slice);
                        switch (cresult) {
                            .value, .yielded => |v| {
                                acc = v;
                                continue :dispatch try decodeNext(code, &ip, &committed);
                            },
                            .thrown => |ex| {
                                f.ip = ip;
                                f.accumulator = acc;
                                committed = true;
                                if (!try unwindThrow(allocator, realm, frames, ex)) {
                                    return .{ .thrown = ex };
                                }
                                continue :dispatch try reEnterDispatch(frames, &f, &local_chunk, &code, &registers, &ip, &acc, &committed);
                            },
                        }
                    }
                    // §20.2.3 — call into %Function.prototype% is undefined.
                    if (realm.intrinsics.function_prototype == po) {
                        acc = Value.undefined_;
                        continue :dispatch try decodeNext(code, &ip, &committed);
                    }
                }
                const fn_v = heap_mod.valueAsFunction(callee_v) orelse {
                    const ex = try makeTypeError(realm, "value is not callable");
                    f.ip = ip;
                    f.accumulator = acc;
                    committed = true;
                    if (!try unwindThrow(allocator, realm, frames, ex)) {
                        return .{ .thrown = ex };
                    }
                    continue :dispatch try reEnterDispatch(frames, &f, &local_chunk, &code, &registers, &ip, &acc, &committed);
                };

                // §28.2.2.1.1 — revocation function.
                if (fn_v.revocable_proxy) |rp| {
                    realm.heap.setProxyTarget(rp, null);
                    realm.heap.setProxyHandler(rp, null);
                    realm.heap.setProxyTargetFn(rp, null);
                    rp.proxy_revoked = true;
                    fn_v.revocable_proxy = null;
                    acc = Value.undefined_;
                    continue :dispatch try decodeNext(code, &ip, &committed);
                }

                // §10.4.1 — bound function. The bound `this`
                // overrides `recv` inside `unwrapBoundCall`.
                if (fn_v.bound_target != null) {
                    const args_start = @as(usize, r_recv) + 1;
                    const result = try callJSFunction(allocator, realm, fn_v, recv, registers[args_start .. args_start + argc]);
                    switch (result) {
                        .value, .yielded => |v| acc = v,
                        .thrown => |ex| {
                            f.ip = ip;
                            f.accumulator = acc;
                            committed = true;
                            if (!try unwindThrow(allocator, realm, frames, ex)) {
                                return .{ .thrown = ex };
                            }
                            continue :dispatch try reEnterDispatch(frames, &f, &local_chunk, &code, &registers, &ip, &acc, &committed);
                        },
                    }
                    continue :dispatch try decodeNext(code, &ip, &committed);
                }

                // Plain callable — refill the call IC.
                call_cell.callee = fn_v;
                break :blk fn_v;
            };

            // §27.5 / §27.6 — generator / async generator wrap.
            if (callee_fn.is_generator) {
                const callee_chunk = callee_fn.chunk orelse return error.InvalidOpcode;
                const args_start = @as(usize, r_recv) + 1;
                const wrap_result = if (callee_fn.is_async)
                    try wrapAsyncGenerator(allocator, realm, callee_chunk, callee_fn.captured_env, recv, registers[args_start .. args_start + argc], callee_fn.home_object, callee_fn.home_function, callee_fn)
                else
                    try wrapGenerator(allocator, realm, callee_chunk, callee_fn.captured_env, recv, registers[args_start .. args_start + argc], callee_fn.home_object, callee_fn.home_function, callee_fn);
                switch (wrap_result) {
                    .value, .yielded => |v| acc = v,
                    .thrown => |ex| {
                        f.ip = ip;
                        f.accumulator = acc;
                        committed = true;
                        if (!try unwindThrow(allocator, realm, frames, ex)) {
                            return .{ .thrown = ex };
                        }
                        continue :dispatch try reEnterDispatch(frames, &f, &local_chunk, &code, &registers, &ip, &acc, &committed);
                    },
                }
                continue :dispatch try decodeNext(code, &ip, &committed);
            }

            // Native fast path.
            if (callee_fn.native_callback) |native| {
                const prior_fn_realm = realm.active_native_fn_realm;
                realm.active_native_fn_realm = callee_fn.realm;
                defer realm.active_native_fn_realm = prior_fn_realm;
                const prior_active_native_fn = realm.active_native_fn;
                realm.active_native_fn = callee_fn;
                defer realm.active_native_fn = prior_active_native_fn;
                const args_start = @as(usize, r_recv) + 1;
                const args = registers[args_start .. args_start + argc];
                const native_this: Value = if (callee_fn.is_arrow)
                    callee_fn.captured_this
                else
                    recv;
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
                        continue :dispatch try reEnterDispatch(frames, &f, &local_chunk, &code, &registers, &ip, &acc, &committed);
                    },
                };
                acc = result;
                continue :dispatch try decodeNext(code, &ip, &committed);
            }

            if (callee_fn.is_async) {
                const callee_chunk = callee_fn.chunk orelse return error.InvalidOpcode;
                const args_start = @as(usize, r_recv) + 1;
                const callee_this: Value = if (callee_fn.is_arrow) callee_fn.captured_this else recv;
                const outcome = try startAsyncCall(allocator, realm, callee_chunk, callee_fn.captured_env, callee_this, registers[args_start .. args_start + argc], callee_fn.home_object, callee_fn.home_function, callee_fn.owning_module);
                switch (outcome) {
                    .value, .yielded => |v| acc = v,
                    .thrown => |ex| {
                        f.ip = ip;
                        f.accumulator = acc;
                        committed = true;
                        if (!try unwindThrow(allocator, realm, frames, ex)) {
                            return .{ .thrown = ex };
                        }
                        continue :dispatch try reEnterDispatch(frames, &f, &local_chunk, &code, &registers, &ip, &acc, &committed);
                    },
                }
                continue :dispatch try decodeNext(code, &ip, &committed);
            }

            // §15.7.14 step 1 — class constructors are not callable.
            if (callee_fn.is_class_constructor) {
                const ex = try makeTypeError(callee_fn.realm orelse realm, "Class constructor cannot be invoked without 'new'");
                f.ip = ip;
                f.accumulator = acc;
                committed = true;
                if (!try unwindThrow(allocator, realm, frames, ex)) {
                    return .{ .thrown = ex };
                }
                continue :dispatch try reEnterDispatch(frames, &f, &local_chunk, &code, &registers, &ip, &acc, &committed);
            }

            // Plain JS callee — push a new frame.
            const callee_chunk = callee_fn.chunk orelse return error.InvalidOpcode;
            const reg_count = @max(@as(usize, callee_chunk.register_count), @as(usize, argc));
            var is_stack_alloc = true;
            const callee_regs = realm.allocStackRegisters(reg_count) orelse blk: {
                is_stack_alloc = false;
                break :blk try realm.frame_pool.acquire(allocator, reg_count);
            };
            @memset(callee_regs, Value.undefined_);
            var ai: u8 = 0;
            while (ai < argc and @as(usize, ai) < callee_regs.len) : (ai += 1) {
                callee_regs[ai] = registers[@as(usize, r_recv) + 1 + ai];
            }

            f.ip = ip;
            f.accumulator = acc;
            committed = true;

            const callee_this: Value = if (callee_fn.is_arrow)
                callee_fn.captured_this
            else
                recv;
            const callee_new_target: Value = if (callee_fn.is_arrow)
                callee_fn.captured_new_target
            else
                Value.undefined_;

            frames.append(allocator, .{
                .chunk = callee_chunk,
                .ip = 0,
                .accumulator = Value.undefined_,
                .registers = callee_regs,
                .env = callee_fn.captured_env,
                .this_value = callee_this,
                .new_target = callee_new_target,
                .home_object = callee_fn.home_object,
                .home_function = callee_fn.home_function,
                .super_called_cell = callee_fn.super_called_cell,
                .argc = argc,
                .wrap_return_in_promise = false,
                .owning_module = callee_fn.owning_module,
                .running_realm = callee_fn.realm,
                .is_stack_alloc = is_stack_alloc,
            }) catch {
                if (is_stack_alloc) {
                    realm.freeStackRegisters(callee_regs);
                } else {
                    realm.frame_pool.release(allocator, callee_regs);
                }
                return error.OutOfMemory;
            };
            // Bistromath first (docs/jit.md §4) — same hook as the
            // `.call` / `.call_method` arms; this is the
            // own-property method-call push site.
            switch (try bistromath.tryEnterTop(allocator, realm, frames)) {
                .not_entered => {},
                .completed => |jit_ret| {
                    frames.items[frames.items.len - 1].accumulator = jit_ret;
                },
                .threw => |ex| {
                    if (!try unwindThrow(allocator, realm, frames, ex)) {
                        return .{ .thrown = ex };
                    }
                },
            }
            continue :dispatch try reEnterDispatch(frames, &f, &local_chunk, &code, &registers, &ip, &acc, &committed);
        },

        // §15.10 PTC — tail call. The compiler emitted this
        // only after the §15.10.1 IsInTailPosition checks
        // passed (statically a tail expression; not in async
        // / generator / try-finally / open for-of). The
        // runtime job: REUSE the current frame for the callee
        // instead of pushing a new one. For plain JSFunction
        // callees that means freeing the current frame's
        // register file, allocating the callee's, overwriting
        // the frame's chunk/ip/env/this/etc., and re-entering
        // dispatch.  Exotic callees (proxy, bound, native,
        // generator, async) fall back to ordinary call
        // semantics — they each manage their own frame stack
        // via callValue / callJSFunction / startAsyncCall and
        // can't be flattened. After the fallback, the value
        // sits in `acc` and the unconditionally-emitted
        // `return_` immediately after the `tail_call` in the
        // bytecode propagates the result. So a tail call is a
        // 0-cost optimization where it applies and falls back
        // to ordinary call+return where it doesn't.
        .tail_call => {
            const r_callee = code[ip];
            const argc = code[ip + 1];
            ip += 2;

            const callee_v = registers[r_callee];

            // §10.5.13 callable Proxy [[Call]] — fall back.
            if (heap_mod.valueAsPlainObject(callee_v)) |po| {
                if (po.proxy_target_fn != null or po.proxy_target != null or po.proxy_revoked) {
                    const args_start = @as(usize, r_callee) + 1;
                    const args_slice = registers[args_start .. args_start + argc];
                    const cresult = try callValue(allocator, realm, f.running_realm orelse realm, callee_v, Value.undefined_, args_slice);
                    switch (cresult) {
                        .value, .yielded => |v| {
                            acc = v;
                            continue :dispatch try decodeNext(code, &ip, &committed);
                        },
                        .thrown => |ex| {
                            f.ip = ip;
                            f.accumulator = acc;
                            committed = true;
                            if (!try unwindThrow(allocator, realm, frames, ex)) {
                                return .{ .thrown = ex };
                            }
                            continue :dispatch try reEnterDispatch(frames, &f, &local_chunk, &code, &registers, &ip, &acc, &committed);
                        },
                    }
                }
                // §20.2.3 — tail-position call into
                // %Function.prototype% degrades to "return
                // undefined" too. The surrounding `return_`
                // emitted right after a tail-call observes the
                // accumulator directly.
                if (realm.intrinsics.function_prototype == po) {
                    acc = Value.undefined_;
                    continue :dispatch try decodeNext(code, &ip, &committed);
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
                continue :dispatch try reEnterDispatch(frames, &f, &local_chunk, &code, &registers, &ip, &acc, &committed);
            };

            // §15.7.14 step 1 — class constructors are not
            // callable without `new`.
            if (callee_fn.is_class_constructor) {
                const ex = try makeTypeError(callee_fn.realm orelse realm, "Class constructor cannot be invoked without 'new'");
                f.ip = ip;
                f.accumulator = acc;
                committed = true;
                if (!try unwindThrow(allocator, realm, frames, ex)) {
                    return .{ .thrown = ex };
                }
                continue :dispatch try reEnterDispatch(frames, &f, &local_chunk, &code, &registers, &ip, &acc, &committed);
            }

            // §28.2.2.1.1 — revocation function (one-shot).
            if (callee_fn.revocable_proxy) |rp| {
                realm.heap.setProxyTarget(rp, null);
                realm.heap.setProxyHandler(rp, null);
                realm.heap.setProxyTargetFn(rp, null);
                rp.proxy_revoked = true;
                callee_fn.revocable_proxy = null;
                acc = Value.undefined_;
                continue :dispatch try decodeNext(code, &ip, &committed);
            }

            // §3.8.3.6 WrappedFunction — see the matching branch
            // in `.call`. Cross-realm callable boundary needs the
            // arg/return marshalling that the inline fast-path
            // can't do; delegate to `callJSFunction`.
            if (!callee_fn.wrapped_target.isUndefined()) {
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
                        continue :dispatch try reEnterDispatch(frames, &f, &local_chunk, &code, &registers, &ip, &acc, &committed);
                    },
                }
                continue :dispatch try decodeNext(code, &ip, &committed);
            }

            // §10.4.1 — bound function: fall back through
            // `callJSFunction` (handles the concatenated args
            // and `this` rebinding). Doesn't preserve PTC
            // semantics but matches every shipping engine —
            // JSC included.
            if (callee_fn.bound_target != null) {
                var inner_target = callee_fn;
                while (inner_target.bound_target) |i_t| inner_target = i_t;
                if (inner_target.is_class_constructor) {
                    const ex = try makeTypeError(realm, "Class constructor cannot be invoked without 'new'");
                    f.ip = ip;
                    f.accumulator = acc;
                    committed = true;
                    if (!try unwindThrow(allocator, realm, frames, ex)) {
                        return .{ .thrown = ex };
                    }
                    continue :dispatch try reEnterDispatch(frames, &f, &local_chunk, &code, &registers, &ip, &acc, &committed);
                }
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
                        continue :dispatch try reEnterDispatch(frames, &f, &local_chunk, &code, &registers, &ip, &acc, &committed);
                    },
                }
                continue :dispatch try decodeNext(code, &ip, &committed);
            }

            // §27.5 / §27.6 — generator constructor allocates a
            // wrapper. Fall back: wrap and return the
            // generator object in acc.
            if (callee_fn.is_generator) {
                const callee_chunk_g = callee_fn.chunk orelse return error.InvalidOpcode;
                const args_start = @as(usize, r_callee) + 1;
                const wrap_result = if (callee_fn.is_async)
                    try wrapAsyncGenerator(allocator, realm, callee_chunk_g, callee_fn.captured_env, Value.undefined_, registers[args_start .. args_start + argc], callee_fn.home_object, callee_fn.home_function, callee_fn)
                else
                    try wrapGenerator(allocator, realm, callee_chunk_g, callee_fn.captured_env, Value.undefined_, registers[args_start .. args_start + argc], callee_fn.home_object, callee_fn.home_function, callee_fn);
                switch (wrap_result) {
                    .value, .yielded => |v| acc = v,
                    .thrown => |ex| {
                        f.ip = ip;
                        f.accumulator = acc;
                        committed = true;
                        if (!try unwindThrow(allocator, realm, frames, ex)) {
                            return .{ .thrown = ex };
                        }
                        continue :dispatch try reEnterDispatch(frames, &f, &local_chunk, &code, &registers, &ip, &acc, &committed);
                    },
                }
                continue :dispatch try decodeNext(code, &ip, &committed);
            }

            // Native fallback — runs inline.
            if (callee_fn.native_callback) |native| {
                // §10.2.5 — see callJSFunction: record the callee's
                // realm so a cross-realm-shared native (ShadowRealm
                // methods) reads its own function realm. Save /
                // restore for nested native calls.
                const prior_fn_realm = realm.active_native_fn_realm;
                realm.active_native_fn_realm = callee_fn.realm;
                defer realm.active_native_fn_realm = prior_fn_realm;
                const prior_active_native_fn = realm.active_native_fn;
                realm.active_native_fn = callee_fn;
                defer realm.active_native_fn = prior_active_native_fn;
                const args_start = @as(usize, r_callee) + 1;
                const args = registers[args_start .. args_start + argc];
                const native_this: Value = if (callee_fn.is_arrow)
                    callee_fn.captured_this
                else
                    Value.undefined_;
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
                        continue :dispatch try reEnterDispatch(frames, &f, &local_chunk, &code, &registers, &ip, &acc, &committed);
                    },
                };
                acc = result;
                continue :dispatch try decodeNext(code, &ip, &committed);
            }

            // §27.7 — async function fallback (compiler should
            // have suppressed PTC here, but defend in depth).
            if (callee_fn.is_async) {
                const callee_chunk_a = callee_fn.chunk orelse return error.InvalidOpcode;
                const args_start = @as(usize, r_callee) + 1;
                const callee_this_a: Value = if (callee_fn.is_arrow) callee_fn.captured_this else Value.undefined_;
                const outcome = try startAsyncCall(allocator, realm, callee_chunk_a, callee_fn.captured_env, callee_this_a, registers[args_start .. args_start + argc], callee_fn.home_object, callee_fn.home_function, callee_fn.owning_module);
                switch (outcome) {
                    .value, .yielded => |v| acc = v,
                    .thrown => |ex| {
                        f.ip = ip;
                        f.accumulator = acc;
                        committed = true;
                        if (!try unwindThrow(allocator, realm, frames, ex)) {
                            return .{ .thrown = ex };
                        }
                        continue :dispatch try reEnterDispatch(frames, &f, &local_chunk, &code, &registers, &ip, &acc, &committed);
                    },
                }
                continue :dispatch try decodeNext(code, &ip, &committed);
            }

            // Plain JSFunction with a chunk — REUSE the current
            // frame. §14.6 PrepareForTailCall: the caller's
            // execution context is "popped" (we free its
            // registers and overwrite the slot) and the
            // callee runs in place. No frames.append, no
            // matching pop on Return — the callee's Return
            // returns to the CALLER's caller.
            const callee_chunk_t = callee_fn.chunk orelse return error.InvalidOpcode;

            // Buffer the args before we free the current
            // register file. argc is u8 so 256 is enough.
            var args_buf: [256]Value = undefined;
            {
                var i: u8 = 0;
                while (i < argc) : (i += 1) args_buf[i] = registers[r_callee + 1 + i];
            }

            // Free the current frame's register file. The new
            // one is sized for the callee chunk.
            f.releaseRegisters(realm, allocator);
            const callee_regs_t = try realm.frame_pool.acquire(allocator, @max(@as(usize, callee_chunk_t.register_count), @as(usize, argc)));
            @memset(callee_regs_t, Value.undefined_);
            {
                var i: u8 = 0;
                while (i < argc) : (i += 1) callee_regs_t[i] = args_buf[i];
            }

            // Reframe in place. §13.3.6 / §15.3.4 — `this` /
            // `new.target` for an arrow inherit from creation
            // site; plain calls reset to undefined.
            f.chunk = callee_chunk_t;
            f.ip = 0;
            f.accumulator = Value.undefined_;
            f.registers = callee_regs_t;
            f.env = callee_fn.captured_env;
            f.this_value = if (callee_fn.is_arrow) callee_fn.captured_this else Value.undefined_;
            f.is_construct = false;
            f.new_target = if (callee_fn.is_arrow) callee_fn.captured_new_target else Value.undefined_;
            f.is_derived_ctor = false;
            f.super_called = false;
            f.super_called_cell = callee_fn.super_called_cell;
            f.home_object = callee_fn.home_object;
            f.home_function = callee_fn.home_function;
            f.argc = argc;
            f.generator = null;
            f.owns_registers = true;
            // Tail-call reallocated through `frame_pool` above,
            // so the reused frame is pool-backed regardless of
            // whether the prior incarnation was stack-allocated.
            // (The prior incarnation's stack registers, if any,
            // were popped by the `releaseRegisters` call above.)
            f.is_stack_alloc = false;
            f.wrap_return_in_promise = false;
            f.owning_module = callee_fn.owning_module;
            f.running_realm = callee_fn.realm;
            committed = true;
            // §15.10 PTC re-entry is morally a loop back-edge: it
            // re-enters dispatch in-place, crossing neither the
            // runFrames-entry safe point nor a loop back-edge. Poll
            // here so an allocating tail-recursive loop still paces
            // the allocation-pressure GC (allocs_since_gc) and
            // decrements the step budget. f.ip / f.accumulator are
            // synced above, so a GC fired here sees the reframed
            // frame (still the top-of-stack slot) as a root.
            if (try runSafePoint(realm)) |r| return r;
            // The reframed frame sits at ip 0 — a tail-recursive
            // function enters the tier exactly like a fresh call
            // (docs/jit.md §12 3f).
            switch (try bistromath.tryEnterTop(allocator, realm, frames)) {
                .not_entered => {},
                .completed => |jit_ret| {
                    if (frames.items.len == 0) return .{ .value = jit_ret };
                    frames.items[frames.items.len - 1].accumulator = jit_ret;
                },
                .threw => |ex| {
                    if (!try unwindThrow(allocator, realm, frames, ex)) return .{ .thrown = ex };
                },
            }
            continue :dispatch try reEnterDispatch(frames, &f, &local_chunk, &code, &registers, &ip, &acc, &committed);
        },

        // §15.10 PTC — method tail call. Same as `tail_call`
        // but `this` comes from `r_recv` (§13.3.6 — method
        // call binds receiver). Encoding:
        // `[op] [r_recv:u8] [r_callee:u8] [argc:u8]`. No IC
        // slot (unlike `call_method`) — tail-recursive method
        // dispatch is rare and the cache layout doesn't
        // compose with frame reuse.
        .tail_call_method => {
            const r_recv = code[ip];
            const r_callee = code[ip + 1];
            const argc = code[ip + 2];
            ip += 3;

            const callee_v = registers[r_callee];
            const recv = registers[r_recv];

            // §10.5.13 callable Proxy [[Call]] — fall back.
            if (heap_mod.valueAsPlainObject(callee_v)) |po| {
                if (po.proxy_target_fn != null or po.proxy_target != null or po.proxy_revoked) {
                    const args_start = @as(usize, r_callee) + 1;
                    const args_slice = registers[args_start .. args_start + argc];
                    const cresult = try callValue(allocator, realm, f.running_realm orelse realm, callee_v, recv, args_slice);
                    switch (cresult) {
                        .value, .yielded => |v| {
                            acc = v;
                            continue :dispatch try decodeNext(code, &ip, &committed);
                        },
                        .thrown => |ex| {
                            f.ip = ip;
                            f.accumulator = acc;
                            committed = true;
                            if (!try unwindThrow(allocator, realm, frames, ex)) {
                                return .{ .thrown = ex };
                            }
                            continue :dispatch try reEnterDispatch(frames, &f, &local_chunk, &code, &registers, &ip, &acc, &committed);
                        },
                    }
                }
                // §20.2.3 %Function.prototype% [[Call]] — see
                // the matching path on `.call`. Tail-method-call
                // shape into %Function.prototype% returns
                // undefined too.
                if (realm.intrinsics.function_prototype == po) {
                    acc = Value.undefined_;
                    continue :dispatch try decodeNext(code, &ip, &committed);
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
                continue :dispatch try reEnterDispatch(frames, &f, &local_chunk, &code, &registers, &ip, &acc, &committed);
            };

            if (callee_fn.is_class_constructor) {
                const ex = try makeTypeError(realm, "Class constructor cannot be invoked without 'new'");
                f.ip = ip;
                f.accumulator = acc;
                committed = true;
                if (!try unwindThrow(allocator, realm, frames, ex)) {
                    return .{ .thrown = ex };
                }
                continue :dispatch try reEnterDispatch(frames, &f, &local_chunk, &code, &registers, &ip, &acc, &committed);
            }

            if (callee_fn.revocable_proxy) |rp| {
                realm.heap.setProxyTarget(rp, null);
                realm.heap.setProxyHandler(rp, null);
                realm.heap.setProxyTargetFn(rp, null);
                rp.proxy_revoked = true;
                callee_fn.revocable_proxy = null;
                acc = Value.undefined_;
                continue :dispatch try decodeNext(code, &ip, &committed);
            }

            // §3.8.3.6 WrappedFunction — see the `.call` branch.
            if (!callee_fn.wrapped_target.isUndefined()) {
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
                        continue :dispatch try reEnterDispatch(frames, &f, &local_chunk, &code, &registers, &ip, &acc, &committed);
                    },
                }
                continue :dispatch try decodeNext(code, &ip, &committed);
            }

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
                        continue :dispatch try reEnterDispatch(frames, &f, &local_chunk, &code, &registers, &ip, &acc, &committed);
                    },
                }
                continue :dispatch try decodeNext(code, &ip, &committed);
            }

            if (callee_fn.is_generator) {
                const callee_chunk_g = callee_fn.chunk orelse return error.InvalidOpcode;
                const args_start = @as(usize, r_callee) + 1;
                const wrap_result = if (callee_fn.is_async)
                    try wrapAsyncGenerator(allocator, realm, callee_chunk_g, callee_fn.captured_env, recv, registers[args_start .. args_start + argc], callee_fn.home_object, callee_fn.home_function, callee_fn)
                else
                    try wrapGenerator(allocator, realm, callee_chunk_g, callee_fn.captured_env, recv, registers[args_start .. args_start + argc], callee_fn.home_object, callee_fn.home_function, callee_fn);
                switch (wrap_result) {
                    .value, .yielded => |v| acc = v,
                    .thrown => |ex| {
                        f.ip = ip;
                        f.accumulator = acc;
                        committed = true;
                        if (!try unwindThrow(allocator, realm, frames, ex)) {
                            return .{ .thrown = ex };
                        }
                        continue :dispatch try reEnterDispatch(frames, &f, &local_chunk, &code, &registers, &ip, &acc, &committed);
                    },
                }
                continue :dispatch try decodeNext(code, &ip, &committed);
            }

            if (callee_fn.native_callback) |native| {
                // §10.2.5 — see callJSFunction: record the callee's
                // realm so a cross-realm-shared native (ShadowRealm
                // methods) reads its own function realm. Save /
                // restore for nested native calls.
                const prior_fn_realm = realm.active_native_fn_realm;
                realm.active_native_fn_realm = callee_fn.realm;
                defer realm.active_native_fn_realm = prior_fn_realm;
                const prior_active_native_fn = realm.active_native_fn;
                realm.active_native_fn = callee_fn;
                defer realm.active_native_fn = prior_active_native_fn;
                const args_start = @as(usize, r_callee) + 1;
                const args = registers[args_start .. args_start + argc];
                const native_this: Value = if (callee_fn.is_arrow)
                    callee_fn.captured_this
                else
                    recv;
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
                        continue :dispatch try reEnterDispatch(frames, &f, &local_chunk, &code, &registers, &ip, &acc, &committed);
                    },
                };
                acc = result;
                continue :dispatch try decodeNext(code, &ip, &committed);
            }

            if (callee_fn.is_async) {
                const callee_chunk_a = callee_fn.chunk orelse return error.InvalidOpcode;
                const args_start = @as(usize, r_callee) + 1;
                const callee_this_a: Value = if (callee_fn.is_arrow) callee_fn.captured_this else recv;
                const outcome = try startAsyncCall(allocator, realm, callee_chunk_a, callee_fn.captured_env, callee_this_a, registers[args_start .. args_start + argc], callee_fn.home_object, callee_fn.home_function, callee_fn.owning_module);
                switch (outcome) {
                    .value, .yielded => |v| acc = v,
                    .thrown => |ex| {
                        f.ip = ip;
                        f.accumulator = acc;
                        committed = true;
                        if (!try unwindThrow(allocator, realm, frames, ex)) {
                            return .{ .thrown = ex };
                        }
                        continue :dispatch try reEnterDispatch(frames, &f, &local_chunk, &code, &registers, &ip, &acc, &committed);
                    },
                }
                continue :dispatch try decodeNext(code, &ip, &committed);
            }

            // Plain JSFunction — reframe in place.
            const callee_chunk_t = callee_fn.chunk orelse return error.InvalidOpcode;
            var args_buf: [256]Value = undefined;
            {
                var i: u8 = 0;
                while (i < argc) : (i += 1) args_buf[i] = registers[r_callee + 1 + i];
            }
            f.releaseRegisters(realm, allocator);
            const callee_regs_t = try realm.frame_pool.acquire(allocator, @max(@as(usize, callee_chunk_t.register_count), @as(usize, argc)));
            @memset(callee_regs_t, Value.undefined_);
            {
                var i: u8 = 0;
                while (i < argc) : (i += 1) callee_regs_t[i] = args_buf[i];
            }

            f.chunk = callee_chunk_t;
            f.ip = 0;
            f.accumulator = Value.undefined_;
            f.registers = callee_regs_t;
            f.env = callee_fn.captured_env;
            f.this_value = if (callee_fn.is_arrow) callee_fn.captured_this else recv;
            f.is_construct = false;
            f.new_target = if (callee_fn.is_arrow) callee_fn.captured_new_target else Value.undefined_;
            f.is_derived_ctor = false;
            f.super_called = false;
            f.super_called_cell = callee_fn.super_called_cell;
            f.home_object = callee_fn.home_object;
            f.home_function = callee_fn.home_function;
            f.argc = argc;
            f.generator = null;
            f.owns_registers = true;
            // See `tail_call`: tail-call reallocates through
            // `frame_pool`, so the reused frame is pool-backed.
            f.is_stack_alloc = false;
            f.wrap_return_in_promise = false;
            f.owning_module = callee_fn.owning_module;
            f.running_realm = callee_fn.realm;
            committed = true;
            // §15.10 PTC re-entry — see the matching poll in
            // `.tail_call`. A method tail call flattens recursion
            // the same way, so it must cross the safe point too.
            if (try runSafePoint(realm)) |r| return r;
            // The reframed frame sits at ip 0 — a tail-recursive
            // function enters the tier exactly like a fresh call
            // (docs/jit.md §12 3f).
            switch (try bistromath.tryEnterTop(allocator, realm, frames)) {
                .not_entered => {},
                .completed => |jit_ret| {
                    if (frames.items.len == 0) return .{ .value = jit_ret };
                    frames.items[frames.items.len - 1].accumulator = jit_ret;
                },
                .threw => |ex| {
                    if (!try unwindThrow(allocator, realm, frames, ex)) return .{ .thrown = ex };
                },
            }
            continue :dispatch try reEnterDispatch(frames, &f, &local_chunk, &code, &registers, &ip, &acc, &committed);
        },

        .new_call => {
            const r_callee = code[ip];
            const argc = code[ip + 1];
            const ic_idx = readU16(code, ip + 2);
            ip += 4;

            const callee_v = registers[r_callee];
            const call_cell = &local_chunk.inline_call_caches[ic_idx];

            // IC fast path: previously cached a plain non-bound
            // non-proxy non-arrow JS-callee constructor whose
            // `.prototype` hasn't been reassigned since fill. Hit
            // skips the proxy check, the `valueAsFunction` decode,
            // the `is_arrow` / `has_construct` gates, the bound-
            // target unwrap, the deferred-proto-lookup native
            // check, the §10.1.14 GetPrototypeFromConstructor
            // accessor walk, AND the native-callback dispatch —
            // straight into instance allocation + JS body frame.
            //
            // Identity guard on `fn_obj.prototype` catches a
            // `C.prototype = newProto` reassignment that leaves
            // the constructor function pointer unchanged.
            if (call_cell.callee) |cached| {
                if (heap_mod.valueAsFunction(callee_v)) |fn_obj| {
                    if (fn_obj == cached and fn_obj.prototype == call_cell.proto) {
                        if (frames.items.len >= max_call_frames) {
                            const ex = try makeRangeError(realm, "Maximum call stack size exceeded");
                            f.ip = ip;
                            f.accumulator = acc;
                            committed = true;
                            if (!try unwindThrow(allocator, realm, frames, ex)) {
                                return .{ .thrown = ex };
                            }
                            continue :dispatch try reEnterDispatch(frames, &f, &local_chunk, &code, &registers, &ip, &acc, &committed);
                        }
                        const callee_chunk = fn_obj.chunk orelse return error.InvalidOpcode;
                        const reg_count = @max(@as(usize, callee_chunk.register_count), @as(usize, argc));
                        var is_stack_alloc = true;
                        const callee_regs = realm.allocStackRegisters(reg_count) orelse blk: {
                            is_stack_alloc = false;
                            break :blk try realm.frame_pool.acquire(allocator, reg_count);
                        };
                        @memset(callee_regs, Value.undefined_);
                        var ai: u8 = 0;
                        while (ai < argc and @as(usize, ai) < callee_regs.len) : (ai += 1) {
                            callee_regs[ai] = registers[r_callee + 1 + ai];
                        }
                        const instance = realm.heap.allocateObject() catch {
                            if (is_stack_alloc) {
                                realm.freeStackRegisters(callee_regs);
                            } else {
                                realm.frame_pool.release(allocator, callee_regs);
                            }
                            return error.OutOfMemory;
                        };
                        realm.heap.setObjectPrototype(instance, call_cell.proto);
                        const this_value = heap_mod.taggedObject(instance);

                        f.ip = ip;
                        f.accumulator = acc;
                        committed = true;

                        frames.append(allocator, .{
                            .chunk = callee_chunk,
                            .ip = 0,
                            .accumulator = Value.undefined_,
                            .registers = callee_regs,
                            .env = fn_obj.captured_env,
                            .this_value = this_value,
                            .is_construct = true,
                            .is_derived_ctor = fn_obj.constructor_kind == .derived,
                            .new_target = heap_mod.taggedFunction(fn_obj),
                            .home_object = fn_obj.home_object,
                            .home_function = fn_obj.home_function,
                            .owning_module = fn_obj.owning_module,
                            .running_realm = fn_obj.realm,
                            .argc = argc,
                            .is_stack_alloc = is_stack_alloc,
                        }) catch {
                            if (is_stack_alloc) {
                                realm.freeStackRegisters(callee_regs);
                            } else {
                                realm.frame_pool.release(allocator, callee_regs);
                            }
                            return error.OutOfMemory;
                        };
                        continue :dispatch try reEnterDispatch(frames, &f, &local_chunk, &code, &registers, &ip, &acc, &committed);
                    }
                }
            }

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
                            // `constructValue` ran the callee inline
                            // (its own runFrames re-entry) — active
                            // frame unchanged → decodeNext.
                            continue :dispatch try decodeNext(code, &ip, &committed);
                        },
                        .thrown => |ex| {
                            f.ip = ip;
                            f.accumulator = acc;
                            committed = true;
                            if (!try unwindThrow(allocator, realm, frames, ex)) {
                                return .{ .thrown = ex };
                            }
                            continue :dispatch try reEnterDispatch(frames, &f, &local_chunk, &code, &registers, &ip, &acc, &committed);
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
                continue :dispatch try reEnterDispatch(frames, &f, &local_chunk, &code, &registers, &ip, &acc, &committed);
            };
            if (callee_fn.is_arrow) {
                const ex = try makeTypeError(realm, "arrow functions are not constructors");
                f.ip = ip;
                f.accumulator = acc;
                committed = true;
                if (!try unwindThrow(allocator, realm, frames, ex)) {
                    return .{ .thrown = ex };
                }
                continue :dispatch try reEnterDispatch(frames, &f, &local_chunk, &code, &registers, &ip, &acc, &committed);
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
                continue :dispatch try reEnterDispatch(frames, &f, &local_chunk, &code, &registers, &ip, &acc, &committed);
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
                // §10.4.1.2 [[Construct]] step 5 — for `new boundFn()`
                // the original NewTarget *is* `boundFn`, so SameValue
                // collapses it to the (fully unwrapped) target. The
                // §10.1.14 GetPrototypeFromConstructor that follows
                // therefore reads `Get(resolved_callee, "prototype")`
                // (the collapsed NewTarget), not the bound wrapper's —
                // which has no own `prototype`. The §10.2.2 base-kind
                // default is %Object.prototype% for an ordinary target,
                // its own %X.prototype% for a native; so a target with
                // `prototype = null` falls back correctly instead of
                // returning a stale slot.
                const proto_lookup = try getPrototypeFromConstructor(allocator, realm, resolved_callee, baseConstructIntrinsicDefaultProto(realm, resolved_callee), baseConstructDefaultProtoOwner(realm, resolved_callee));
                const resolved_proto: ?*JSObject = switch (proto_lookup) {
                    .proto => |p| p,
                    .proto_fn => null, // function-valued proto — applied via the parallel slot below
                    .thrown => |ex| {
                        f.ip = ip;
                        f.accumulator = acc;
                        committed = true;
                        if (!try unwindThrow(allocator, realm, frames, ex)) {
                            return .{ .thrown = ex };
                        }
                        continue :dispatch try reEnterDispatch(frames, &f, &local_chunk, &code, &registers, &ip, &acc, &committed);
                    },
                };
                const inst = realm.heap.allocateObject() catch return error.OutOfMemory;
                if (proto_lookup == .proto_fn) realm.heap.setObjectPrototypeFn(inst, proto_lookup.proto_fn) else realm.heap.setObjectPrototype(inst, resolved_proto);
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
                        continue :dispatch try reEnterDispatch(frames, &f, &local_chunk, &code, &registers, &ip, &acc, &committed);
                    },
                }
                // Bound target constructed inline via
                // `callJSFunctionAsSuper` — active frame unchanged
                // → decodeNext.
                continue :dispatch try decodeNext(code, &ip, &committed);
            }

            // §25.1.4.1 / §25.3.2.1 — native ctors that
            // pre-validate args BEFORE OCFC. Stash newTarget,
            // invoke with `this = undefined`, let the native
            // run its own GetPrototypeFromConstructor after
            // validation. ConstructResult requires an Object;
            // a non-Object return throws TypeError (no
            // fallback `this` since we never allocated one).
            if (callee_fn.defers_proto_lookup and callee_fn.native_callback != null) {
                const args_start = @as(usize, r_callee) + 1;
                const args = registers[args_start .. args_start + argc];
                const prior_pnt = realm.pending_native_new_target;
                realm.pending_native_new_target = heap_mod.taggedFunction(callee_fn);
                defer realm.pending_native_new_target = prior_pnt;
                const result = callee_fn.native_callback.?(realm, Value.undefined_, args) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    error.NativeThrew => {
                        const ex = consumePendingException(realm) orelse try makeTypeError(realm, "native error");
                        f.ip = ip;
                        f.accumulator = acc;
                        committed = true;
                        if (!try unwindThrow(allocator, realm, frames, ex)) {
                            return .{ .thrown = ex };
                        }
                        continue :dispatch try reEnterDispatch(frames, &f, &local_chunk, &code, &registers, &ip, &acc, &committed);
                    },
                };
                if (heap_mod.valueAsPlainObject(result) != null or
                    heap_mod.valueAsFunction(result) != null)
                {
                    acc = result;
                } else {
                    const ex = try makeTypeError(realm, "deferred-proto-lookup constructor did not return an object");
                    f.ip = ip;
                    f.accumulator = acc;
                    committed = true;
                    if (!try unwindThrow(allocator, realm, frames, ex)) {
                        return .{ .thrown = ex };
                    }
                    continue :dispatch try reEnterDispatch(frames, &f, &local_chunk, &code, &registers, &ip, &acc, &committed);
                }
                // Native ctor ran inline — frame unchanged; decodeNext,
                // not reEnterDispatch (which would reload a stale ip).
                continue :dispatch try decodeNext(code, &ip, &committed);
            }
            // §13.3.5.1.1 OrdinaryCallBindThis with NewTarget=callee.
            // §10.1.14 GetPrototypeFromConstructor — read
            // `prototype` through the accessor path so a
            // user-installed getter on the constructor fires. The
            // §10.2.2 base-kind default is %Object.prototype% for an
            // ordinary function (the native ctors that reach here
            // carry their own %X.prototype%), so `new F()` with
            // `F.prototype = null` falls back to %Object.prototype%
            // rather than F's own stale slot.
            const proto_lookup_main = try getPrototypeFromConstructor(allocator, realm, callee_fn, baseConstructIntrinsicDefaultProto(realm, callee_fn), baseConstructDefaultProtoOwner(realm, callee_fn));
            const resolved_proto_main: ?*JSObject = switch (proto_lookup_main) {
                .proto => |p| p,
                .proto_fn => null, // function-valued proto — applied via the parallel slot below
                .thrown => |ex| {
                    f.ip = ip;
                    f.accumulator = acc;
                    committed = true;
                    if (!try unwindThrow(allocator, realm, frames, ex)) {
                        return .{ .thrown = ex };
                    }
                    continue :dispatch try reEnterDispatch(frames, &f, &local_chunk, &code, &registers, &ip, &acc, &committed);
                },
            };
            const instance = realm.heap.allocateObject() catch return error.OutOfMemory;
            if (proto_lookup_main == .proto_fn) realm.heap.setObjectPrototypeFn(instance, proto_lookup_main.proto_fn) else realm.heap.setObjectPrototype(instance, resolved_proto_main);
            const this_value = heap_mod.taggedObject(instance);

            // Native fast path — same calling shape as `Call`,
            // but with the implicit instance allocated above.
            // a way to flag a native as a true
            // constructor (i.e. it returns the instance). For
            // later, treat native callees as plain calls
            // and ignore the construct path.
            if (callee_fn.native_callback) |native| {
                // §10.2.5 — see callJSFunction: record the callee's
                // realm so a cross-realm-shared native (ShadowRealm
                // methods) reads its own function realm. Save /
                // restore for nested native calls.
                const prior_fn_realm = realm.active_native_fn_realm;
                realm.active_native_fn_realm = callee_fn.realm;
                defer realm.active_native_fn_realm = prior_fn_realm;
                const prior_active_native_fn = realm.active_native_fn;
                realm.active_native_fn = callee_fn;
                defer realm.active_native_fn = prior_active_native_fn;
                const args_start = @as(usize, r_callee) + 1;
                const args = registers[args_start .. args_start + argc];
                // For native constructors, `this` is the freshly
                // allocated instance (the §13.3.5.1.1 fallback).
                const native_this: Value = this_value;
                // The instance is reachable only through this Zig
                // local until the native returns and we publish it
                // to `acc`. A native constructor that re-enters JS
                // — a user `toString` / `valueOf` / `@@toPrimitive`
                // run while coercing an argument — can trigger a GC
                // mid-call; root the instance so the sweep can't
                // free it out from under the native. The
                // `native_ctor_roots` stack is allocation-free at
                // steady state, unlike a `HandleScope` per `new`.
                realm.heap.pushNativeRoot(this_value) catch return error.OutOfMemory;
                defer realm.heap.popNativeRoot();
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
                        continue :dispatch try reEnterDispatch(frames, &f, &local_chunk, &code, &registers, &ip, &acc, &committed);
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
                // Native ctor ran inline — frame unchanged; decodeNext,
                // not reEnterDispatch (which would reload a stale ip).
                continue :dispatch try decodeNext(code, &ip, &committed);
            }

            if (frames.items.len >= max_call_frames) {
                const ex = try makeRangeError(realm, "Maximum call stack size exceeded");
                f.ip = ip;
                f.accumulator = acc;
                committed = true;
                if (!try unwindThrow(allocator, realm, frames, ex)) {
                    return .{ .thrown = ex };
                }
                continue :dispatch try reEnterDispatch(frames, &f, &local_chunk, &code, &registers, &ip, &acc, &committed);
            }

            const callee_chunk = callee_fn.chunk orelse return error.InvalidOpcode;
            const reg_count = @max(@as(usize, callee_chunk.register_count), @as(usize, argc));
            var is_stack_alloc = true;
            const callee_regs = realm.allocStackRegisters(reg_count) orelse blk: {
                is_stack_alloc = false;
                break :blk try realm.frame_pool.acquire(allocator, reg_count);
            };
            @memset(callee_regs, Value.undefined_);
            var ai: u8 = 0;
            while (ai < argc and @as(usize, ai) < callee_regs.len) : (ai += 1) {
                callee_regs[ai] = registers[r_callee + 1 + ai];
            }

            f.ip = ip;
            f.accumulator = acc;
            committed = true;

            // Survived every exotic-construct gate (proxy, bound,
            // arrow, no-construct, deferred-proto native, native
            // callback) and the slow `getPrototypeFromConstructor`
            // accessor walk. Refill the IC so the next iteration
            // of a hot `new C(…)` loop takes the fast path: same
            // callee identity AND same `.prototype` slot value →
            // skip everything above.
            call_cell.callee = callee_fn;
            call_cell.proto = resolved_proto_main;

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
                .owning_module = callee_fn.owning_module,
                .running_realm = callee_fn.realm,
                .argc = argc,
                .is_stack_alloc = is_stack_alloc,
            }) catch {
                if (is_stack_alloc) {
                    realm.freeStackRegisters(callee_regs);
                } else {
                    realm.frame_pool.release(allocator, callee_regs);
                }
                return error.OutOfMemory;
            };
            // JS callee — a new frame was pushed; the active
            // frame changed. reEnterDispatch loads the callee's
            // chunk / registers / ip=0. decodeNext would keep
            // running the caller against a reallocated stack.
            //
            // Bistromath first (docs/jit.md §4): a hot compiled
            // callee runs to completion here and hands its result
            // to the caller frame exactly as `return_` would; a
            // tier-down leaves the frame mid-chunk for
            // reEnterDispatch. Cold chunks fall straight through.
            switch (try bistromath.tryEnterTop(allocator, realm, frames)) {
                .not_entered => {},
                .completed => |jit_ret| {
                    frames.items[frames.items.len - 1].accumulator = jit_ret;
                },
                .threw => |ex| {
                    if (!try unwindThrow(allocator, realm, frames, ex)) {
                        return .{ .thrown = ex };
                    }
                },
            }
            continue :dispatch try reEnterDispatch(frames, &f, &local_chunk, &code, &registers, &ip, &acc, &committed);
        },

        .lda_this => {
            // §10.2.1.4 BindThisValue / §9.1.1.3.4 GetThisBinding —
            // in a derived constructor, `this` is uninitialised
            // until `super(...)` completes. A read before that
            // point throws ReferenceError "Must call super
            // constructor before accessing 'this'".
            //
            // Two frame shapes can hit this gate:
            //   • The derived ctor frame itself: own `is_derived_ctor`
            //     flag plus `super_called` toggle.
            //   • An arrow / nested arrow whose lexical `this` is
            //     the derived ctor's: arrow frames carry
            //     `super_called_cell` pointing at the ctor's cell,
            //     and `is_derived_ctor = false`. The cell's
            //     current value answers "has super run yet?".
            const uninit = blk: {
                if (f.is_derived_ctor and !f.super_called) break :blk true;
                if (!f.is_derived_ctor) {
                    if (f.super_called_cell) |cell| {
                        if (!cell.*) break :blk true;
                    }
                }
                break :blk false;
            };
            if (uninit) {
                const ex = try makeReferenceError(realm, "Must call super constructor before accessing 'this'");
                f.ip = ip;
                f.accumulator = acc;
                committed = true;
                if (!try unwindThrow(allocator, realm, frames, ex)) {
                    return .{ .thrown = ex };
                }
                continue :dispatch try reEnterDispatch(frames, &f, &local_chunk, &code, &registers, &ip, &acc, &committed);
            }
            acc = f.this_value;
            continue :dispatch try decodeNext(code, &ip, &committed);
        },

        .lda_new_target => {
            acc = f.new_target;
            continue :dispatch try decodeNext(code, &ip, &committed);
        },

        .import_meta => {
            // §16.2.1.7 ImportMeta runtime semantics.
            //   1. Let module be GetActiveScriptOrModule().[[Module]].
            //   2. Let importMeta be module.[[ImportMeta]].
            //   3. If importMeta is undefined:
            //      a. Set importMeta to OrdinaryObjectCreate(%Object.prototype%).
            //      b-e. Host hook stubbed.
            //      f. Set module.[[ImportMeta]] to importMeta.
            //      g. Return importMeta.
            //   4. Else return importMeta.
            //
            // The active "script or module" is the one this
            // frame's function was defined in (captured at
            // `make_function` time, propagated through frame
            // entry as `f.owning_module`). A function exported
            // from module A and called from module B must
            // still see A's import.meta — so we consult
            // `f.owning_module` first and only fall through
            // to `realm.current_module` for module-body
            // top-level frames (where owning_module is null
            // because the body itself isn't a JSFunction).
            const mr_opt = f.owning_module orelse realm.current_module;
            if (mr_opt) |mr| {
                if (mr.import_meta) |im| {
                    acc = heap_mod.taggedObject(im);
                } else {
                    const im = realm.heap.allocateObject() catch return error.OutOfMemory;
                    realm.heap.setObjectPrototype(im, realm.intrinsics.object_prototype);
                    mr.import_meta = im;
                    acc = heap_mod.taggedObject(im);
                }
            } else {
                // Parser gates `import.meta` to a Module goal,
                // so this branch is unreachable in practice;
                // throw a defensive SyntaxError if a future code
                // path (host-script eval, etc.) ever reaches it.
                const ex = @import("../builtins/error.zig").newSyntaxError(realm, "import.meta is only valid inside a Module") catch return error.OutOfMemory;
                f.ip = ip;
                f.accumulator = acc;
                committed = true;
                if (!try unwindThrow(allocator, realm, frames, ex)) return .{ .thrown = ex };
                continue :dispatch try reEnterDispatch(frames, &f, &local_chunk, &code, &registers, &ip, &acc, &committed);
            }
            continue :dispatch try decodeNext(code, &ip, &committed);
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
                continue :dispatch try reEnterDispatch(frames, &f, &local_chunk, &code, &registers, &ip, &acc, &committed);
            }
            // §13.10.2 step 2 — `GetMethod(target, @@hasInstance)`.
            // Walks the prototype chain via the accessor-aware
            // `getPropertyChain` so a `defineProperty(rhs,
            // Symbol.hasInstance, {get…})` fires its getter
            // (test262 language/expressions/instanceof/symbol-
            // hasinstance-get-err.js, -to-boolean.js).
            const hi_v: Value = blk_hi: {
                if (rhs_obj_opt) |o| {
                    break :blk_hi intrinsics_mod.getPropertyChain(realm, o, "@@hasInstance") catch |err| switch (err) {
                        error.OutOfMemory => return error.OutOfMemory,
                        error.NativeThrew => {
                            const ex = realm.pending_exception orelse Value.undefined_;
                            realm.pending_exception = null;
                            f.ip = ip;
                            f.accumulator = acc;
                            committed = true;
                            if (!try unwindThrow(allocator, realm, frames, ex)) {
                                return .{ .thrown = ex };
                            }
                            continue :dispatch try reEnterDispatch(frames, &f, &local_chunk, &code, &registers, &ip, &acc, &committed);
                        },
                    };
                } else if (rhs_fn_opt) |fn_obj| {
                    break :blk_hi fn_obj.get("@@hasInstance");
                } else break :blk_hi Value.undefined_;
            };
            if (heap_mod.valueAsFunction(hi_v)) |hi_fn| {
                const hi_args = [_]Value{lhs};
                const outcome = try callJSFunction(allocator, realm, hi_fn, rhs, &hi_args);
                switch (outcome) {
                    .value, .yielded => |v| {
                        // §13.10.2 step 4.a — `ToBoolean(? Call(…))`.
                        acc = Value.fromBool(arith.toBoolean(v));
                        // `@@hasInstance` ran inline via callJSFunction
                        // — active frame unchanged → decodeNext.
                        continue :dispatch try decodeNext(code, &ip, &committed);
                    },
                    .thrown => |ex| {
                        f.ip = ip;
                        f.accumulator = acc;
                        committed = true;
                        if (!try unwindThrow(allocator, realm, frames, ex)) {
                            return .{ .thrown = ex };
                        }
                        continue :dispatch try reEnterDispatch(frames, &f, &local_chunk, &code, &registers, &ip, &acc, &committed);
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
                continue :dispatch try reEnterDispatch(frames, &f, &local_chunk, &code, &registers, &ip, &acc, &committed);
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
                    continue :dispatch try reEnterDispatch(frames, &f, &local_chunk, &code, &registers, &ip, &acc, &committed);
                }
            } else if (heap_mod.valueAsPlainObject(lhs)) |lhs_obj| {
                var cursor: ?*JSObject = lhs_obj.prototype orelse if (lhs_obj.prototype_fn) |pf| pf.proto else null;
                var found = false;
                while (cursor) |p| : (cursor = p.prototype orelse if (p.prototype_fn) |pf| pf.proto else null) {
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
            continue :dispatch try decodeNext(code, &ip, &committed);
        },

        .object_rest_from => {
            const r_src = code[ip];
            const r_excl = code[ip + 1];
            ip += 2;
            const src_v = registers[r_src];
            const excl_v = registers[r_excl];
            const out_obj = realm.heap.allocateObject() catch return error.OutOfMemory;
            realm.heap.setObjectPrototype(out_obj, realm.intrinsics.object_prototype);
            // §7.3.27 — `out_obj` is held as a raw pointer across
            // every source read below (ToObject coercion, the Proxy
            // ownKeys / get traps, accessor getters via
            // getPropertyChain), each a JS re-entry that can GC. It
            // doesn't become reachable from a rooted graph until it
            // lands in `acc` at the end, so a sweep mid-walk frees it
            // and the `storeProperty(out_obj, …)` below dereferences
            // poisoned memory. Root it (and the coerced source
            // wrapper) for the whole opcode.
            const out_scope = realm.heap.openScope() catch return error.OutOfMemory;
            defer out_scope.close();
            out_scope.push(heap_mod.taggedObject(out_obj)) catch return error.OutOfMemory;
            // §7.3.27 CopyDataProperties step 2 — `ToObject(source)`.
            // Primitive sources (Strings, Numbers, Booleans, Symbols,
            // BigInts) wrap into the matching boxed object — a String
            // wrapper carries its code-unit characters as own indexed
            // properties, so `{...rest} = "foo"` yields
            // `rest = {0:"f", 1:"o", 2:"o"}`. null / undefined are a
            // no-op (the spec returns the empty target).
            const src_coerced: Value = if (src_v.isNull() or src_v.isUndefined())
                Value.undefined_
            else if (heap_mod.valueAsPlainObject(src_v) != null or heap_mod.valueAsFunction(src_v) != null)
                src_v
            else blk_coerce: {
                const w = intrinsics_mod.toObjectThis(realm, src_v) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    else => {
                        const ex = consumePendingException(realm) orelse try makeTypeError(realm, "rest source could not be coerced to object");
                        f.ip = ip;
                        f.accumulator = acc;
                        committed = true;
                        if (!try unwindThrow(allocator, realm, frames, ex)) {
                            return .{ .thrown = ex };
                        }
                        break :blk_coerce Value.undefined_;
                    },
                };
                break :blk_coerce heap_mod.taggedObject(w);
            };
            if (committed) continue :dispatch try reEnterDispatch(frames, &f, &local_chunk, &code, &registers, &ip, &acc, &committed);
            // For a primitive source (`{...r} = "ab"`) this is a
            // fresh boxed wrapper held across the same getter
            // re-entries as `out_obj`; for an object source it's a
            // register-backed value (rooting is a harmless no-op).
            out_scope.push(src_coerced) catch return error.OutOfMemory;
            if (heap_mod.valueAsPlainObject(src_coerced)) |src_obj| {
                // §14.3.3.4 RestBindingInitialization →
                // §7.3.27 CopyDataProperties: build the
                // excluded-key set, walk OwnPropertyKeys in
                // spec order (integer-indexed → insertion),
                // and route each read through `[[Get]]` so
                // an accessor getter on the source fires
                // (Object.assign uses the same shape).
                var excluded: std.ArrayListUnmanaged([]const u8) = .empty;
                defer excluded.deinit(allocator);
                var excluded_owned: std.ArrayListUnmanaged([]u8) = .empty;
                defer {
                    for (excluded_owned.items) |s| allocator.free(s);
                    excluded_owned.deinit(allocator);
                }
                if (heap_mod.valueAsPlainObject(excl_v)) |excl_arr| {
                    const len_v = excl_arr.get("length");
                    const len_i: i64 = if (len_v.isInt32()) len_v.asInt32() else 0;
                    var ibuf: [24]u8 = undefined;
                    var i: i64 = 0;
                    while (i < len_i) : (i += 1) {
                        const islice = std.fmt.bufPrint(&ibuf, "{d}", .{i}) catch unreachable;
                        const k_v = excl_arr.get(islice);
                        if (k_v.isUndefined()) continue;
                        // Computed-key exclusions
                        // (`{[expr]: x, ...rest}`) store the raw
                        // post-ToPropertyKey value here — could be
                        // a string or a number primitive that hasn't
                        // been stringified yet (our
                        // `coerceToPropertyKey` short-circuits
                        // non-object primitives per §7.1.19's
                        // ToPrimitive-first path). Normalise via
                        // the same key-to-string helper that
                        // `sta_computed` uses on the source side,
                        // so the exclusion string matches the
                        // source's stored key form.
                        if (k_v.isString()) {
                            const ks: *JSString = @ptrCast(@alignCast(k_v.asString()));
                            excluded.append(allocator, ks.flatBytes()) catch return error.OutOfMemory;
                        } else if (heap_mod.valueAsSymbol(k_v)) |sym| {
                            // Symbols exclude by their `prop_key`.
                            excluded.append(allocator, sym.prop_key) catch return error.OutOfMemory;
                        } else {
                            var kbuf: [64]u8 = undefined;
                            const ks = computedKeyToString(k_v, &kbuf);
                            const dup = allocator.dupe(u8, ks) catch return error.OutOfMemory;
                            excluded_owned.append(allocator, dup) catch {
                                allocator.free(dup);
                                return error.OutOfMemory;
                            };
                            excluded.append(allocator, dup) catch return error.OutOfMemory;
                        }
                    }
                }
                // Snapshot the key list before we start calling
                // user getters — they could otherwise mutate the
                // property bag mid-iteration. For a Proxy source,
                // route through `proxyOwnKeysOrNull` so the
                // `ownKeys` trap fires (§7.3.27 step 4 +
                // §10.5.11), and use `getOwnPropertyDescriptor`
                // to decide enumerability — that fires the
                // §10.5.5 trap for every non-excluded key, even
                // when the descriptor will ultimately be
                // ignored.
                const obj_mod_inner = @import("../builtins/object.zig");
                const is_src_proxy = src_obj.proxy_target != null or src_obj.proxy_revoked;
                const key_scope = realm.heap.openScope() catch return error.OutOfMemory;
                defer key_scope.close();
                const keys_opt: ?[]const []const u8 = blk_pk: {
                    const ko = obj_mod_inner.proxyOwnKeysOrNull(realm, src_obj, key_scope) catch |err| switch (err) {
                        error.OutOfMemory => return error.OutOfMemory,
                        else => {
                            const ex = consumePendingException(realm) orelse try makeTypeError(realm, "object rest ownKeys trap threw");
                            f.ip = ip;
                            f.accumulator = acc;
                            committed = true;
                            if (!try unwindThrow(allocator, realm, frames, ex)) {
                                return .{ .thrown = ex };
                            }
                            break :blk_pk null;
                        },
                    };
                    break :blk_pk ko;
                };
                if (committed) continue :dispatch try reEnterDispatch(frames, &f, &local_chunk, &code, &registers, &ip, &acc, &committed);
                const keys: []const []const u8 = if (keys_opt) |k| k else (obj_mod_inner.ownPropertyKeysOrdered(realm, src_obj, key_scope) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    else => return error.InvalidOpcode,
                });
                defer allocator.free(keys);
                for (keys) |k| {
                    if (std.mem.startsWith(u8, k, "__cynic_")) continue;
                    var skip = false;
                    for (excluded.items) |ek| {
                        if (std.mem.eql(u8, ek, k)) {
                            skip = true;
                            break;
                        }
                    }
                    if (skip) continue;
                    // §7.3.27 step 4.c.i — `desc = ? from.[[GetOwnProperty]](key)`.
                    // For a Proxy source, the trap must fire for
                    // every non-excluded key. For a plain object
                    // it's a quick own-flag read.
                    if (is_src_proxy) {
                        const key_str = realm.heap.allocateString(k) catch return error.OutOfMemory;
                        const desc_args = [_]Value{ heap_mod.taggedObject(src_obj), Value.fromString(key_str) };
                        const desc_v = obj_mod_inner.objectGetOwnPropertyDescriptor(realm, Value.undefined_, &desc_args) catch |err| switch (err) {
                            error.OutOfMemory => return error.OutOfMemory,
                            else => {
                                const ex = consumePendingException(realm) orelse try makeTypeError(realm, "object rest descriptor trap threw");
                                f.ip = ip;
                                f.accumulator = acc;
                                committed = true;
                                if (!try unwindThrow(allocator, realm, frames, ex)) {
                                    return .{ .thrown = ex };
                                }
                                break;
                            },
                        };
                        if (desc_v.isUndefined()) continue;
                        const desc_obj = heap_mod.valueAsPlainObject(desc_v) orelse continue;
                        if (!intrinsics_mod.toBoolean(desc_obj.get("enumerable"))) continue;
                    } else {
                        if (!src_obj.flagsFor(k).enumerable) continue;
                    }
                    // §7.3.27 step 4.c.iii — Get(from, nextKey).
                    // Route the Proxy source through the
                    // [[Get]] trap so the `get` handler fires
                    // for every enumerable key; the plain-object
                    // path stays on `getPropertyChain` for
                    // accessor support. A throw propagates as an
                    // abrupt completion through the destructuring.
                    const v: Value = if (is_src_proxy) blk_v: {
                        const proxy_mod = @import("../builtins/proxy.zig");
                        const outcome = proxy_mod.nativeProxyGet(realm, src_obj, k, heap_mod.taggedObject(src_obj), null) catch |err| switch (err) {
                            error.OutOfMemory => return error.OutOfMemory,
                            else => {
                                const ex = consumePendingException(realm) orelse try makeTypeError(realm, "rest property read failed");
                                f.ip = ip;
                                f.accumulator = acc;
                                committed = true;
                                if (!try unwindThrow(allocator, realm, frames, ex)) {
                                    return .{ .thrown = ex };
                                }
                                break;
                            },
                        };
                        break :blk_v switch (outcome) {
                            .value => |val| val,
                            .fallthrough => |t| t.get(k),
                        };
                    } else intrinsics_mod.getPropertyChain(realm, src_obj, k) catch |err| switch (err) {
                        error.OutOfMemory => return error.OutOfMemory,
                        else => {
                            const ex = consumePendingException(realm) orelse try makeTypeError(realm, "rest property read failed");
                            f.ip = ip;
                            f.accumulator = acc;
                            committed = true;
                            if (!try unwindThrow(allocator, realm, frames, ex)) {
                                return .{ .thrown = ex };
                            }
                            break;
                        },
                    };
                    // §7.3.27 step 4.c.iv — `CreateDataPropertyOrThrow`.
                    // Allocate a fresh JSString and route through the
                    // anchored store. `keys` borrows either from
                    // `src_obj.key_anchors` (gone with src) or from the
                    // opcode-local `key_scope`'s integer-index strings
                    // (gone after `key_scope.close()`); plain
                    // `storeProperty` would leave `out_obj.properties`
                    // with dangling key slices the next sweep poisons.
                    key_scope.push(v) catch return error.OutOfMemory;
                    const k_anchor = realm.heap.allocateString(k) catch return error.OutOfMemory;
                    realm.heap.storePropertyComputedOwned(out_obj, allocator, k_anchor, v) catch return error.OutOfMemory;
                }
                if (committed) continue :dispatch try reEnterDispatch(frames, &f, &local_chunk, &code, &registers, &ip, &acc, &committed);
            }
            acc = heap_mod.taggedObject(out_obj);
            continue :dispatch try decodeNext(code, &ip, &committed);
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
            realm.heap.setObjectPrototype(out_obj, realm.intrinsics.array_prototype);
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
                realm.heap.storeProperty(out_obj, allocator, owned.flatBytes(), elem) catch return error.OutOfMemory;
            }
            realm.heap.storeProperty(out_obj, allocator, "length", Value.fromInt32(@intCast(out_idx))) catch return error.OutOfMemory;
            acc = heap_mod.taggedObject(out_obj);
            continue :dispatch try decodeNext(code, &ip, &committed);
        },

        .iter_close => {
            const r = code[ip];
            const mode = code[ip + 1];
            ip += 2;
            const iter_v = registers[r];
            if (heap_mod.valueAsPlainObject(iter_v)) |iter_obj| {
                // §7.4.6 IteratorClose step 4 — only run when
                // `iteratorRecord.[[Done]]` is false. Cynic
                // tracks this on the iter object's typed
                // `iter_record` slot that `iter_step` maintains.
                if (iter_obj.iter_record) |rec| {
                    if (rec.done) continue :dispatch try decodeNext(code, &ip, &committed);
                }
                // §7.4.6 IteratorClose step 4 → §7.3.10 GetMethod —
                // a present but non-callable `return` throws
                // TypeError. Only `undefined` / `null` skip the
                // call. A throw here propagates per mode: on a
                // normal/break/return completion (mode==0) it
                // surfaces; on a throw completion (mode==1) the
                // outer throw still wins.
                //
                // Accessor-aware so `get return() { … }` fires
                // exactly once (the fixtures track gets via a
                // side-effect counter).
                const ret_v = intrinsics_mod.getPropertyChain(realm, iter_obj, "return") catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    else => {
                        const ex = consumePendingException(realm) orelse try makeTypeError(realm, "iterator 'return' read failed");
                        if (mode == 1) {
                            // Throw completion swallows inner errors.
                            continue :dispatch try decodeNext(code, &ip, &committed);
                        }
                        f.ip = ip;
                        f.accumulator = acc;
                        committed = true;
                        if (!try unwindThrow(allocator, realm, frames, ex)) {
                            return .{ .thrown = ex };
                        }
                        continue :dispatch try reEnterDispatch(frames, &f, &local_chunk, &code, &registers, &ip, &acc, &committed);
                    },
                };
                const ret_fn_opt: ?*JSFunction = blk: {
                    if (ret_v.isUndefined() or ret_v.isNull()) break :blk null;
                    if (heap_mod.valueAsFunction(ret_v)) |rf| break :blk rf;
                    if (mode == 1) break :blk null;
                    const ex = try makeTypeError(realm, "iterator 'return' is not callable");
                    f.ip = ip;
                    f.accumulator = acc;
                    committed = true;
                    if (!try unwindThrow(allocator, realm, frames, ex)) {
                        return .{ .thrown = ex };
                    }
                    break :blk null;
                };
                if (committed) continue :dispatch try reEnterDispatch(frames, &f, &local_chunk, &code, &registers, &ip, &acc, &committed);
                if (ret_fn_opt) |ret_fn| {
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
                                continue :dispatch try reEnterDispatch(frames, &f, &local_chunk, &code, &registers, &ip, &acc, &committed);
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
                                    continue :dispatch try reEnterDispatch(frames, &f, &local_chunk, &code, &registers, &ip, &acc, &committed);
                                }
                                acc = saved_acc;
                            },
                        }
                    }
                }
            }
            continue :dispatch try decodeNext(code, &ip, &committed);
        },

        .in_op => {
            const r = code[ip];
            ip += 1;
            const obj_v = acc;
            // §13.10.1 — RHS must be an object; otherwise TypeError.
            // §10.1.7 HasProperty / §7.3.12 — applies to any
            // Object, including callable Functions. Function
            // receivers walk through the JSFunction's own
            // properties + the function's prototype chain (which
            // typically resolves to Function.prototype).
            if (heap_mod.valueAsFunction(obj_v)) |fn_in| {
                // §7.1.19 ToPropertyKey on the LHS.
                const key_v = switch (try coerceToPropertyKey(allocator, realm, frames, f, ip, registers[r])) {
                    .ok => |v| v,
                    .handled => {
                        committed = true;
                        continue :dispatch try reEnterDispatch(frames, &f, &local_chunk, &code, &registers, &ip, &acc, &committed);
                    },
                    .uncaught => |ex| return .{ .thrown = ex },
                };
                var key_buf: [64]u8 = undefined;
                const key_slice = computedKeyToString(key_v, &key_buf);
                // Function own properties: \`prototype\` lives in
                // a dedicated slot (synthesised via \`hasOwn\`);
                // the rest are in \`properties\` / \`accessors\`.
                var found = fn_in.hasOwn(key_slice);
                if (!found) {
                    var cursor: ?*JSObject = fn_in.proto;
                    while (cursor) |c| : (cursor = c.prototype) {
                        if (c.ownDataContains(key_slice) or c.hasAccessor(key_slice)) {
                            found = true;
                            break;
                        }
                    }
                }
                acc = Value.fromBool(found);
                continue :dispatch try decodeNext(code, &ip, &committed);
            }
            const obj_in = heap_mod.valueAsPlainObject(obj_v) orelse {
                const ex = try makeTypeError(realm, "Cannot use 'in' operator to search non-object");
                f.ip = ip;
                f.accumulator = acc;
                committed = true;
                if (!try unwindThrow(allocator, realm, frames, ex)) {
                    return .{ .thrown = ex };
                }
                continue :dispatch try reEnterDispatch(frames, &f, &local_chunk, &code, &registers, &ip, &acc, &committed);
            };
            // §7.1.19 ToPropertyKey on the LHS.
            const key_v = switch (try coerceToPropertyKey(allocator, realm, frames, f, ip, registers[r])) {
                .ok => |v| v,
                .handled => {
                    committed = true;
                    continue :dispatch try reEnterDispatch(frames, &f, &local_chunk, &code, &registers, &ip, &acc, &committed);
                },
                .uncaught => |ex| return .{ .thrown = ex },
            };
            var key_buf: [64]u8 = undefined;
            const key_slice = computedKeyToString(key_v, &key_buf);
            // §10.5.7 Proxy [[HasProperty]] dispatch, then
            // §10.1.7.1 OrdinaryHasProperty prototype walk. When
            // a proxy appears at *any* point in the chain (the
            // receiver itself or an inherited prototype), we
            // dispatch through its handler and recurse if the
            // trap is absent.
            var cursor: ?*JSObject = obj_in;
            var found = false;
            var handled_via_proxy = false;
            walk: while (cursor) |c| {
                if (c.proxy_target != null or c.proxy_revoked) {
                    const r2 = try proxyHasTrap(allocator, realm, frames, f, ip, c, key_slice, key_v);
                    switch (r2) {
                        .value => |v| {
                            // Trap ran via `callJSFunction` (its
                            // own frame stack) — our frame is
                            // intact. Record ip + result so the
                            // shared `reEnterDispatch` tail below
                            // reloads them.
                            f.ip = ip;
                            f.accumulator = v;
                            acc = v;
                            handled_via_proxy = true;
                            break :walk;
                        },
                        .fallthrough => |t| {
                            if (t == c) break :walk;
                            cursor = t;
                            continue :walk;
                        },
                        .handled => {
                            committed = true;
                            handled_via_proxy = true;
                            break :walk;
                        },
                        .uncaught => |ex| return .{ .thrown = ex },
                    }
                }
                // §10.1.7.1 OrdinaryHasProperty step 3 —
                // `HasOwnProperty(O, P)` includes array-exotic /
                // typed-array integer-indexed slots, not just
                // the `properties` / `accessors` maps.
                if (c.hasOwn(key_slice)) {
                    found = true;
                    break :walk;
                }
                cursor = c.prototype;
            }
            if (handled_via_proxy)
                continue :dispatch try reEnterDispatch(frames, &f, &local_chunk, &code, &registers, &ip, &acc, &committed);
            acc = Value.fromBool(found);
            continue :dispatch try decodeNext(code, &ip, &committed);
        },

        // ── Class definition + super ───────────────────────
        .make_class => {
            const k = readU16(code, ip);
            ip += 2;
            const r_keys_base = code[ip];
            ip += 1;
            // §15.7.14 step 27.b — inner classScopeEnvRec slot
            // index for the class binding (`C` in `class C {…}`).
            // Sentinel `0xFF` means the class is anonymous, so
            // there's no inner env / no binding to publish.
            // Named classes need the binding initialised BEFORE
            // static fields / static blocks run; see
            // `class.buildClass`.
            const inner_slot_raw = code[ip];
            ip += 1;
            const inner_class_slot: ?u8 = if (inner_slot_raw == 0xFF) null else inner_slot_raw;
            if (k >= local_chunk.class_templates.len) return error.InvalidOpcode;
            const tmpl = &local_chunk.class_templates[k];
            const heritage: ?Value = if (tmpl.has_heritage) acc else null;
            // §13.2.5 — gather pre-computed `[expr]` key
            // values from the contiguous register block
            // `f.registers[r_keys_base..]`. The compiler
            // emitted the key expressions inline (so
            // `yield` / `await` inside a key suspend the
            // enclosing generator / async function — see
            // `emitMakeClass` in compiler.zig); each is
            // already `to_property_key`-coerced to a string
            // or symbol Value. Walk the template to count
            // members with `computed_key_index >= 0`, then
            // slice the register block.
            var keys_buf: [256]Value = undefined;
            var key_count: usize = 0;
            for (tmpl.instance_methods) |*m| {
                if (m.computed_key_index >= 0) key_count += 1;
            }
            for (tmpl.static_methods) |*m| {
                if (m.computed_key_index >= 0) key_count += 1;
            }
            for (tmpl.instance_fields) |*fd| {
                if (fd.computed_key_index >= 0) key_count += 1;
            }
            for (tmpl.static_fields) |*fd| {
                if (fd.computed_key_index >= 0) key_count += 1;
            }
            if (key_count > keys_buf.len) return error.InvalidOpcode;
            {
                var ki: usize = 0;
                while (ki < key_count) : (ki += 1) {
                    keys_buf[ki] = f.registers[r_keys_base + ki];
                }
            }
            const class_mod = @import("../class.zig");
            acc = class_mod.buildClass(f.running_realm orelse realm, tmpl, f.env, heritage, keys_buf[0..key_count], inner_class_slot) catch |err| switch (err) {
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
            if (committed) continue :dispatch try reEnterDispatch(frames, &f, &local_chunk, &code, &registers, &ip, &acc, &committed);
            continue :dispatch try decodeNext(code, &ip, &committed);
        },

        .super_get => {
            const k = readU16(code, ip);
            ip += 2;
            if (k >= local_chunk.constants.len) return error.InvalidOpcode;
            const key_v = local_chunk.constants[k];
            if (!key_v.isString()) return error.InvalidOpcode;
            const key_s: *JSString = @ptrCast(@alignCast(key_v.asString()));
            // §13.3.7.3 MakeSuperPropertyReference step 3 —
            // GetThisBinding precedes any property lookup. In
            // a derived ctor before `super(...)`, `this` is
            // uninitialized and §9.1.1.3.4 throws ReferenceError.
            if (f.is_derived_ctor and !f.super_called) {
                const ex = try makeReferenceError(realm, "'this' is not initialized");
                f.ip = ip;
                f.accumulator = acc;
                committed = true;
                if (!try unwindThrow(allocator, realm, frames, ex)) {
                    return .{ .thrown = ex };
                }
                continue :dispatch try reEnterDispatch(frames, &f, &local_chunk, &code, &registers, &ip, &acc, &committed);
            }
            // §13.3.7 static-method form — home is the class
            // constructor (a JSFunction); super walks
            // `ctor.static_parent` which is the parent class.
            // Gate on `home_object == null` so the instance-
            // ctor frames (which carry both home_function = ctor
            // for super-call dispatch and home_object = proto
            // for the property walk) take the prototype path
            // below.
            if (f.home_object == null) {
                if (f.home_function) |hf| {
                    if (hf.static_parent) |parent_fn| {
                        // §10.1.8.1 OrdinaryGet — accessor descriptor
                        // wins; getter fires with `this` =
                        // f.this_value (the current class).
                        if (parent_fn.accessors.get(key_s.flatBytes())) |acc_pair| {
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
                                        continue :dispatch try reEnterDispatch(frames, &f, &local_chunk, &code, &registers, &ip, &acc, &committed);
                                    },
                                }
                            } else {
                                acc = Value.undefined_;
                            }
                        } else {
                            acc = parent_fn.get(key_s.flatBytes());
                        }
                    } else {
                        acc = Value.undefined_;
                    }
                    // Any getter ran inline (callJSFunction) — active
                    // frame unchanged → decodeNext.
                    continue :dispatch try decodeNext(code, &ip, &committed);
                }
            }
            const home = f.home_object orelse {
                const ex = try makeTypeError(realm, "super used outside a method");
                f.ip = ip;
                f.accumulator = acc;
                committed = true;
                if (!try unwindThrow(allocator, realm, frames, ex)) {
                    return .{ .thrown = ex };
                }
                continue :dispatch try reEnterDispatch(frames, &f, &local_chunk, &code, &registers, &ip, &acc, &committed);
            };
            // §13.3.7.3 MakeSuperPropertyReference step 5 —
            // RequireObjectCoercible(GetSuperBase()). When the
            // home object's `[[Prototype]]` is null (e.g.
            // `class C extends null`), the check fires before
            // the property access and throws TypeError.
            const parent_proto = home.prototype orelse {
                const ex = try makeTypeError(realm, "Cannot read properties of null (super)");
                f.ip = ip;
                f.accumulator = acc;
                committed = true;
                if (!try unwindThrow(allocator, realm, frames, ex)) {
                    return .{ .thrown = ex };
                }
                continue :dispatch try reEnterDispatch(frames, &f, &local_chunk, &code, &registers, &ip, &acc, &committed);
            };
            // §10.1.8 OrdinaryGet via super reference — the
            // accessor descriptor wins, and getters fire with
            // `this` bound to the caller's `this_value` (§9.1.6
            // step 5: Receiver = the active method's `this`,
            // not the parent prototype).
            if (lookupAccessor(parent_proto, key_s.flatBytes())) |acc_pair| {
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
                            continue :dispatch try reEnterDispatch(frames, &f, &local_chunk, &code, &registers, &ip, &acc, &committed);
                        },
                    }
                } else {
                    acc = Value.undefined_;
                }
                // Getter ran inline (callJSFunction) — active frame
                // unchanged → decodeNext.
                continue :dispatch try decodeNext(code, &ip, &committed);
            }
            acc = parent_proto.get(key_s.flatBytes());
            continue :dispatch try decodeNext(code, &ip, &committed);
        },

        .super_get_computed => {
            // Same gate as `.super_get`: only treat as the
            // static-method form when no instance home_object
            // is in scope (a class ctor frame carries both).
            if (f.home_object == null) {
                if (f.home_function) |hf| {
                    const key_v_static = switch (try coerceToPropertyKey(allocator, realm, frames, f, ip, acc)) {
                        .ok => |v| v,
                        .handled => {
                            committed = true;
                            continue :dispatch try reEnterDispatch(frames, &f, &local_chunk, &code, &registers, &ip, &acc, &committed);
                        },
                        .uncaught => |ex| return .{ .thrown = ex },
                    };
                    var key_buf_s: [64]u8 = undefined;
                    const key_slice_s = computedKeyToString(key_v_static, &key_buf_s);
                    if (hf.static_parent) |parent_fn| {
                        // §10.1.8.1 OrdinaryGet step 4 — accessor
                        // dispatch runs through the getter, not the
                        // data slot. `JSFunction.get` only resolves
                        // data; honour an own accessor on the parent
                        // function before falling back so e.g.
                        // `static get K() { ... }` on B reads via the
                        // getter when `super[K]` walks up.
                        if (parent_fn.ownAccessor(key_slice_s)) |acc_pair| {
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
                                        continue :dispatch try reEnterDispatch(frames, &f, &local_chunk, &code, &registers, &ip, &acc, &committed);
                                    },
                                }
                            } else {
                                acc = Value.undefined_;
                            }
                            continue :dispatch try decodeNext(code, &ip, &committed);
                        }
                        acc = parent_fn.get(key_slice_s);
                    } else {
                        acc = Value.undefined_;
                    }
                    continue :dispatch try decodeNext(code, &ip, &committed);
                }
            }
            const home = f.home_object orelse {
                const ex = try makeTypeError(realm, "super used outside a method");
                f.ip = ip;
                f.accumulator = acc;
                committed = true;
                if (!try unwindThrow(allocator, realm, frames, ex)) {
                    return .{ .thrown = ex };
                }
                continue :dispatch try reEnterDispatch(frames, &f, &local_chunk, &code, &registers, &ip, &acc, &committed);
            };
            // §13.3.7.3 MakeSuperPropertyReference step 5 —
            // RequireObjectCoercible on the home object's
            // `[[Prototype]]`. A null prototype throws TypeError
            // before the bracket-key conversion runs.
            const parent_proto = home.prototype orelse {
                const ex = try makeTypeError(realm, "Cannot read properties of null (super)");
                f.ip = ip;
                f.accumulator = acc;
                committed = true;
                if (!try unwindThrow(allocator, realm, frames, ex)) {
                    return .{ .thrown = ex };
                }
                continue :dispatch try reEnterDispatch(frames, &f, &local_chunk, &code, &registers, &ip, &acc, &committed);
            };
            // §7.1.19 ToPropertyKey on the bracket key.
            const key_v = switch (try coerceToPropertyKey(allocator, realm, frames, f, ip, acc)) {
                .ok => |v| v,
                .handled => {
                    committed = true;
                    continue :dispatch try reEnterDispatch(frames, &f, &local_chunk, &code, &registers, &ip, &acc, &committed);
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
                            continue :dispatch try reEnterDispatch(frames, &f, &local_chunk, &code, &registers, &ip, &acc, &committed);
                        },
                    }
                } else {
                    acc = Value.undefined_;
                }
                continue :dispatch try decodeNext(code, &ip, &committed);
            }
            acc = parent_proto.get(key_slice);
            continue :dispatch try decodeNext(code, &ip, &committed);
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
            // §13.3.7.3 MakeSuperPropertyReference step 3 —
            // GetThisBinding. In a derived ctor before super()
            // `this` is uninitialized; throw ReferenceError.
            if (f.is_derived_ctor and !f.super_called) {
                const ex = try makeReferenceError(realm, "'this' is not initialized");
                f.ip = ip;
                f.accumulator = acc;
                committed = true;
                if (!try unwindThrow(allocator, realm, frames, ex)) {
                    return .{ .thrown = ex };
                }
                continue :dispatch try reEnterDispatch(frames, &f, &local_chunk, &code, &registers, &ip, &acc, &committed);
            }
            // §13.3.7 static-method form — `this` is the
            // current class; super setter dispatch reads the
            // parent JSFunction's `accessors` map. Same
            // home_object-null gate as the read paths so a
            // class ctor body falls through to the prototype
            // walk instead.
            if (f.home_object == null) {
                if (f.home_function) |hf| {
                    if (hf.static_parent) |parent_fn| {
                        if (parent_fn.accessors.get(key_s.flatBytes())) |acc_pair| {
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
                                        continue :dispatch try reEnterDispatch(frames, &f, &local_chunk, &code, &registers, &ip, &acc, &committed);
                                    },
                                }
                                acc = value;
                                continue :dispatch try decodeNext(code, &ip, &committed);
                            }
                        }
                    }
                    // §6.2.5.5 PutValue with a Super Reference —
                    // `Let baseObj be ? ToObject(V.[[Base]])`.
                    // GetSuperBase for a static method returns
                    // `HomeObject.[[GetPrototypeOf]]()` = the
                    // constructor's [[Prototype]]. When that's
                    // null (e.g. after `Object.setPrototypeOf(C,
                    // null)`), ToObject(null) throws TypeError —
                    // and the spec runs this AFTER the RHS has
                    // been evaluated, so any side effect there
                    // (count += 1) is already observable. Match
                    // that ordering: we land here post-RHS, so
                    // throwing here preserves the spec sequence.
                    // See test262
                    // language/expressions/assignment/
                    // target-super-identifier-reference-null.js.
                    if (hf.static_parent == null and hf.proto == null) {
                        const ex = try makeTypeError(realm, "Cannot set properties of null (super)");
                        f.ip = ip;
                        f.accumulator = acc;
                        committed = true;
                        if (!try unwindThrow(allocator, realm, frames, ex)) {
                            return .{ .thrown = ex };
                        }
                        continue :dispatch try reEnterDispatch(frames, &f, &local_chunk, &code, &registers, &ip, &acc, &committed);
                    }
                    // Fall back to writing on `this` (the
                    // current constructor, since this is static).
                    if (heap_mod.valueAsFunction(f.this_value)) |this_fn| {
                        realm.heap.storeFunctionProperty(this_fn, allocator, key_s.flatBytes(), value) catch return error.OutOfMemory;
                    } else if (heap_mod.valueAsPlainObject(f.this_value)) |this_obj| {
                        realm.heap.storeProperty(this_obj, allocator, key_s.flatBytes(), value) catch return error.OutOfMemory;
                    }
                    acc = value;
                    continue :dispatch try decodeNext(code, &ip, &committed);
                }
            }
            const home = f.home_object orelse {
                const ex = try makeTypeError(realm, "super used outside a method");
                f.ip = ip;
                f.accumulator = acc;
                committed = true;
                if (!try unwindThrow(allocator, realm, frames, ex)) {
                    return .{ .thrown = ex };
                }
                continue :dispatch try reEnterDispatch(frames, &f, &local_chunk, &code, &registers, &ip, &acc, &committed);
            };
            // §13.3.7.3 MakeSuperPropertyReference step 5 —
            // RequireObjectCoercible on the home object's
            // `[[Prototype]]`. A null prototype throws TypeError
            // before the [[Set]] runs.
            const parent_proto = home.prototype orelse {
                const ex = try makeTypeError(realm, "Cannot set properties of null (super)");
                f.ip = ip;
                f.accumulator = acc;
                committed = true;
                if (!try unwindThrow(allocator, realm, frames, ex)) {
                    return .{ .thrown = ex };
                }
                continue :dispatch try reEnterDispatch(frames, &f, &local_chunk, &code, &registers, &ip, &acc, &committed);
            };
            var did_setter = false;
            {
                const p = parent_proto;
                if (lookupAccessor(p, key_s.flatBytes())) |acc_pair| {
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
                                continue :dispatch try reEnterDispatch(frames, &f, &local_chunk, &code, &registers, &ip, &acc, &committed);
                            },
                        }
                        did_setter = true;
                    }
                }
            }
            if (!did_setter) {
                // §10.1.9.2 OrdinarySetWithOwnDescriptor step
                // 1 reads `Receiver.[[GetOwnProperty]](P)`. On
                // a module namespace receiver that routes
                // through §9.4.6.4 → §9.4.6.7 [[Get]] →
                // GetBindingValue(N, true), which throws
                // ReferenceError when the source binding is
                // still the seeded TDZ-Hole. The plain
                // namespace [[Set]] reject (TypeError) only
                // fires once that descriptor read succeeds.
                if (heap_mod.valueAsPlainObject(f.this_value)) |this_obj| {
                    if (this_obj.is_module_namespace and !std.mem.startsWith(u8, key_s.flatBytes(), "@@") and !std.mem.startsWith(u8, key_s.flatBytes(), "<sym:") and this_obj.hasOwn(key_s.flatBytes())) {
                        _ = module_mod.namespaceGetThrowingOnHole(realm, this_obj, key_s.flatBytes()) catch |err| switch (err) {
                            error.OutOfMemory => return error.OutOfMemory,
                            error.NativeThrew => {
                                const ex = realm.pending_exception orelse Value.undefined_;
                                realm.pending_exception = null;
                                f.ip = ip;
                                f.accumulator = acc;
                                committed = true;
                                if (!try unwindThrow(allocator, realm, frames, ex)) {
                                    return .{ .thrown = ex };
                                }
                                continue :dispatch try reEnterDispatch(frames, &f, &local_chunk, &code, &registers, &ip, &acc, &committed);
                            },
                        };
                    }
                    // §6.2.5.6 PutValue step 3.d / §13.5.1 — a
                    // Super Reference is *always* strict (Cynic
                    // is strict-only). When [[Set]] would return
                    // false — receiver is non-extensible and has
                    // no own slot to overwrite, OR the existing
                    // own data slot is non-writable — the spec
                    // says throw TypeError. Surface that here
                    // before the silent-write fallback.
                    if (!this_obj.hasOwn(key_s.flatBytes())) {
                        if (!this_obj.extensible) {
                            const ex = try makeTypeError(realm, "Cannot add property, object is not extensible");
                            f.ip = ip;
                            f.accumulator = acc;
                            committed = true;
                            if (!try unwindThrow(allocator, realm, frames, ex)) {
                                return .{ .thrown = ex };
                            }
                            continue :dispatch try reEnterDispatch(frames, &f, &local_chunk, &code, &registers, &ip, &acc, &committed);
                        }
                    } else {
                        const ok = realm.heap.storePropertyIfWritable(this_obj, allocator, key_s.flatBytes(), value) catch return error.OutOfMemory;
                        if (!ok) {
                            const ex = try makeTypeError(realm, "Cannot assign to read-only property via super");
                            f.ip = ip;
                            f.accumulator = acc;
                            committed = true;
                            if (!try unwindThrow(allocator, realm, frames, ex)) {
                                return .{ .thrown = ex };
                            }
                            continue :dispatch try reEnterDispatch(frames, &f, &local_chunk, &code, &registers, &ip, &acc, &committed);
                        }
                        acc = value;
                        continue :dispatch try reEnterDispatch(frames, &f, &local_chunk, &code, &registers, &ip, &acc, &committed);
                    }
                    // Fall back to a plain `this[key] = value`
                    // write per §10.1.9.2 — the receiver is
                    // the current `this`, not the parent
                    // prototype. (No own slot + extensible.)
                    realm.heap.storeProperty(this_obj, allocator, key_s.flatBytes(), value) catch return error.OutOfMemory;
                } else if (heap_mod.valueAsFunction(f.this_value)) |this_fn| {
                    // Receiver is a class function (static
                    // super.X = v lands here). No extensibility
                    // flag on JSFunction yet — leave the silent
                    // write path. TODO(cynic): wire JSFunction
                    // extensibility for Object.freeze parity.
                    realm.heap.storeFunctionProperty(this_fn, allocator, key_s.flatBytes(), value) catch return error.OutOfMemory;
                }
            }
            acc = value;
            continue :dispatch try decodeNext(code, &ip, &committed);
        },

        .super_set_computed => {
            // §13.3.7 — `super[key] = value`. `r_key` holds
            // the key after ToPropertyKey, `r_value` the
            // value to write. Same dispatch shape as
            // `super_set`.
            const r_key = code[ip];
            const r_value = code[ip + 1];
            ip += 2;
            const key_v_raw = registers[r_key];
            const value = registers[r_value];
            const home = f.home_object orelse {
                const ex = try makeTypeError(realm, "super used outside a method");
                f.ip = ip;
                f.accumulator = acc;
                committed = true;
                if (!try unwindThrow(allocator, realm, frames, ex)) {
                    return .{ .thrown = ex };
                }
                continue :dispatch try reEnterDispatch(frames, &f, &local_chunk, &code, &registers, &ip, &acc, &committed);
            };
            // §13.3.7.3 MakeSuperPropertyReference step 5 —
            // RequireObjectCoercible on the home object's
            // `[[Prototype]]`. A null prototype throws TypeError
            // before the bracket-key conversion or [[Set]] runs.
            // The proto is captured HERE — §6.2.5.6 PutValue
            // step 3.c (ToPropertyKey) runs after this, so a
            // user `key.toString()` that mutates `home`'s
            // prototype must observe the captured value, not the
            // post-mutation one (see test262
            // `prop-expr-getsuperbase-before-topropertykey-putvalue`).
            const parent_proto = home.prototype orelse {
                const ex = try makeTypeError(realm, "Cannot set properties of null (super)");
                f.ip = ip;
                f.accumulator = acc;
                committed = true;
                if (!try unwindThrow(allocator, realm, frames, ex)) {
                    return .{ .thrown = ex };
                }
                continue :dispatch try reEnterDispatch(frames, &f, &local_chunk, &code, &registers, &ip, &acc, &committed);
            };
            // §6.2.5.6 PutValue step 3.c.i — ToPropertyKey now
            // (after baseValue captured above). A user
            // `toString` running here can mutate the proto chain
            // but the captured `parent_proto` survives.
            const key_v = switch (try coerceToPropertyKey(allocator, realm, frames, f, ip, key_v_raw)) {
                .ok => |v| v,
                .handled => {
                    committed = true;
                    continue :dispatch try reEnterDispatch(frames, &f, &local_chunk, &code, &registers, &ip, &acc, &committed);
                },
                .uncaught => |ex| return .{ .thrown = ex },
            };
            var key_buf: [64]u8 = undefined;
            const key_slice = computedKeyToString(key_v, &key_buf);
            var did_setter = false;
            {
                const p = parent_proto;
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
                                continue :dispatch try reEnterDispatch(frames, &f, &local_chunk, &code, &registers, &ip, &acc, &committed);
                            },
                        }
                        did_setter = true;
                    }
                }
            }
            if (!did_setter) {
                if (heap_mod.valueAsPlainObject(f.this_value)) |this_obj| {
                    // §6.2.5.6 PutValue step 3.d — super
                    // reference is strict; throw TypeError when
                    // [[Set]] would reject. Same gate as
                    // `.super_set`.
                    if (!this_obj.hasOwn(key_slice)) {
                        if (!this_obj.extensible) {
                            const ex = try makeTypeError(realm, "Cannot add property, object is not extensible");
                            f.ip = ip;
                            f.accumulator = acc;
                            committed = true;
                            if (!try unwindThrow(allocator, realm, frames, ex)) {
                                return .{ .thrown = ex };
                            }
                            continue :dispatch try reEnterDispatch(frames, &f, &local_chunk, &code, &registers, &ip, &acc, &committed);
                        }
                    } else {
                        const ok = realm.heap.storePropertyIfWritable(this_obj, allocator, key_slice, value) catch return error.OutOfMemory;
                        if (!ok) {
                            const ex = try makeTypeError(realm, "Cannot assign to read-only property via super");
                            f.ip = ip;
                            f.accumulator = acc;
                            committed = true;
                            if (!try unwindThrow(allocator, realm, frames, ex)) {
                                return .{ .thrown = ex };
                            }
                            continue :dispatch try reEnterDispatch(frames, &f, &local_chunk, &code, &registers, &ip, &acc, &committed);
                        }
                        acc = value;
                        continue :dispatch try reEnterDispatch(frames, &f, &local_chunk, &code, &registers, &ip, &acc, &committed);
                    }
                    realm.heap.storeProperty(this_obj, allocator, key_slice, value) catch return error.OutOfMemory;
                }
            }
            acc = value;
            continue :dispatch try decodeNext(code, &ip, &committed);
        },

        .super_check_this => {
            // §13.3.7.1 SuperProperty evaluation — step 2
            // (`actualThis = ? env.GetThisBinding()`) runs
            // *before* Expression evaluation. The compiler
            // emits this op before `super[expr]` so a derived
            // ctor before `super(...)` throws ReferenceError
            // and the inner expression never executes
            // (§9.1.1.3.4 GetThisBinding).
            if (f.is_derived_ctor and !f.super_called) {
                const ex = try makeReferenceError(realm, "'this' is not initialized");
                f.ip = ip;
                f.accumulator = acc;
                committed = true;
                if (!try unwindThrow(allocator, realm, frames, ex)) {
                    return .{ .thrown = ex };
                }
                continue :dispatch try reEnterDispatch(frames, &f, &local_chunk, &code, &registers, &ip, &acc, &committed);
            }
            continue :dispatch try decodeNext(code, &ip, &committed);
        },

        .init_instance_fields => {
            // §15.7.10 InitializeInstanceElements. Reads the
            // executing fn's home_object (= class prototype),
            // installs each private method binding on the
            // instance, then runs each field initializer.
            const home = f.home_object orelse return error.InvalidOpcode;
            if (home.getPrivateMethodInits()) |inits| {
                if (heap_mod.valueAsPlainObject(f.this_value)) |inst| {
                    var thrown_method: bool = false;
                    for (inits) |entry| {
                        if (entry.init_fn) |fn_obj| {
                            // §7.3.32 PrivateFieldAdd step 1 (and the
                            // §7.3.33 PrivateMethodOrAccessorAdd
                            // counterpart) — installing a private
                            // element on a non-extensible receiver
                            // throws TypeError. Hit by the
                            // `nonextensible-applies-to-private`
                            // (ES2022) fixtures where a derived
                            // ctor's `super(seal)` calls
                            // `Object.preventExtensions(this)`
                            // before instance elements install.
                            if (!inst.extensible) {
                                const ex = try makeTypeError(f.running_realm orelse realm, "Cannot install private element on non-extensible object");
                                f.ip = ip;
                                f.accumulator = acc;
                                committed = true;
                                if (!try unwindThrow(allocator, realm, frames, ex)) {
                                    return .{ .thrown = ex };
                                }
                                thrown_method = true;
                                break;
                            }
                            // §7.3.28 PrivateMethodOrAccessorAdd
                            // step 2-3: `Let entry be ! PrivateElementFind
                            // (method.[[Key]], O). If entry is not empty,
                            // throw a TypeError.` A derived class whose
                            // base `constructor(o){return o}` returns an
                            // object already populated by an earlier
                            // construction (`new C(obj); new C(obj)`)
                            // hits this on every entry. Accessor halves
                            // declared in the SAME class get paired into
                            // one private slot — distinguished here by
                            // matching the existing kind: if there's
                            // already a private_accessors entry for this
                            // key and we're installing the OTHER half
                            // (a getter when only a setter is present,
                            // or vice versa), allow it. Otherwise the
                            // key is already taken — throw.
                            const already_present: bool = switch (entry.accessor_kind) {
                                .none => inst.hasPrivateProperty(entry.name) or inst.hasPrivateAccessor(entry.name),
                                .getter => blk: {
                                    if (inst.hasPrivateProperty(entry.name)) break :blk true;
                                    if (inst.getPrivateAccessor(entry.name)) |existing| {
                                        // Existing entry already has a
                                        // getter slot filled → conflict.
                                        break :blk existing.getter != null;
                                    }
                                    break :blk false;
                                },
                                .setter => blk: {
                                    if (inst.hasPrivateProperty(entry.name)) break :blk true;
                                    if (inst.getPrivateAccessor(entry.name)) |existing| {
                                        break :blk existing.setter != null;
                                    }
                                    break :blk false;
                                },
                            };
                            if (already_present) {
                                const ex = try makeTypeError(f.running_realm orelse realm, "Cannot install duplicate private method on object");
                                f.ip = ip;
                                f.accumulator = acc;
                                committed = true;
                                if (!try unwindThrow(allocator, realm, frames, ex)) {
                                    return .{ .thrown = ex };
                                }
                                thrown_method = true;
                                break;
                            }
                            switch (entry.accessor_kind) {
                                .none => {
                                    inst.putPrivateProperty(allocator, entry.name, heap_mod.taggedFunction(fn_obj)) catch return error.OutOfMemory;
                                    // §7.3.30 PrivateSet step 4 — methods are read-only.
                                    inst.putPrivateMethod(allocator, entry.name) catch return error.OutOfMemory;
                                },
                                .getter => {
                                    const ent = inst.getOrPutPrivateAccessor(allocator, entry.name) catch return error.OutOfMemory;
                                    if (!ent.found_existing) ent.value_ptr.* = .{};
                                    realm.heap.setAccessorGetter(.{ .object = inst }, ent.value_ptr, fn_obj);
                                },
                                .setter => {
                                    const ent = inst.getOrPutPrivateAccessor(allocator, entry.name) catch return error.OutOfMemory;
                                    if (!ent.found_existing) ent.value_ptr.* = .{};
                                    realm.heap.setAccessorSetter(.{ .object = inst }, ent.value_ptr, fn_obj);
                                },
                            }
                        }
                    }
                    if (thrown_method) continue :dispatch try reEnterDispatch(frames, &f, &local_chunk, &code, &registers, &ip, &acc, &committed);
                }
            }
            if (home.getInstanceFieldInits()) |inits| {
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
                            // §7.3.32 PrivateFieldAdd step 1 —
                            // the initializer may have just run
                            // `Object.preventExtensions(this)`
                            // (base-class `#g = (prevent(this), …)`),
                            // so re-check before each put.
                            if (!inst.extensible) {
                                const ex = try makeTypeError(f.running_realm orelse realm, "Cannot add private field to non-extensible object");
                                f.ip = ip;
                                f.accumulator = acc;
                                committed = true;
                                if (!try unwindThrow(allocator, realm, frames, ex)) {
                                    return .{ .thrown = ex };
                                }
                                break;
                            }
                            // §7.3.32 PrivateFieldAdd steps 3-4:
                            // PrivateFieldFind(P, O); if entry not
                            // empty, throw TypeError. Hit by
                            // `new C(obj); new C(obj)` patterns where
                            // C's base returns an existing instance.
                            if (inst.hasPrivateProperty(entry.name) or inst.hasPrivateAccessor(entry.name)) {
                                const ex = try makeTypeError(f.running_realm orelse realm, "Cannot install duplicate private field on object");
                                f.ip = ip;
                                f.accumulator = acc;
                                committed = true;
                                if (!try unwindThrow(allocator, realm, frames, ex)) {
                                    return .{ .thrown = ex };
                                }
                                break;
                            }
                            inst.putPrivateProperty(allocator, entry.name, v) catch return error.OutOfMemory;
                        } else {
                            // §7.3.7 CreateDataPropertyOrThrow —
                            // a public class field installs with
                            // `[[CreateDataProperty]]`, which on
                            // a non-extensible receiver returns
                            // false and the surrounding "OrThrow"
                            // wrapper raises TypeError. Hit by
                            // `class C { f = Object.freeze(this);
                            // g = "x"; }` where the first field
                            // freezes the instance and the second
                            // attempts to install on the frozen
                            // object.
                            if (!inst.extensible and inst.proxy_target == null and inst.proxy_target_fn == null) {
                                const ex = try makeTypeError(realm, "Cannot add field to non-extensible object");
                                f.ip = ip;
                                f.accumulator = acc;
                                committed = true;
                                if (!try unwindThrow(allocator, realm, frames, ex)) {
                                    return .{ .thrown = ex };
                                }
                                break;
                            }
                            // §10.5.6 Proxy [[DefineOwnProperty]] —
                            // when `this` is a Proxy (e.g. derived
                            // `class extends ProxyBase`), the public
                            // field install must route through the
                            // handler's `defineProperty` trap with
                            // a `{value, writable:true, enumerable:
                            // true, configurable:true}` descriptor.
                            // `inst.set` would silently bypass the
                            // trap and the fixture would never see
                            // the field appear at the trap site.
                            if (inst.proxy_target != null or inst.proxy_target_fn != null or inst.proxy_revoked) {
                                // Build the descriptor object.
                                const desc = realm.heap.allocateObject() catch return error.OutOfMemory;
                                realm.heap.setObjectPrototype(desc, realm.intrinsics.object_prototype);
                                realm.heap.storeProperty(desc, allocator, "value", v) catch return error.OutOfMemory;
                                realm.heap.storeProperty(desc, allocator, "writable", Value.fromBool(true)) catch return error.OutOfMemory;
                                realm.heap.storeProperty(desc, allocator, "enumerable", Value.fromBool(true)) catch return error.OutOfMemory;
                                realm.heap.storeProperty(desc, allocator, "configurable", Value.fromBool(true)) catch return error.OutOfMemory;
                                const key_s = realm.heap.allocateString(entry.name) catch return error.OutOfMemory;
                                const obj_builtin = @import("../builtins/object.zig");
                                const args_three = [_]Value{
                                    heap_mod.taggedObject(inst),
                                    Value.fromString(key_s),
                                    heap_mod.taggedObject(desc),
                                };
                                _ = obj_builtin.objectDefineProperty(realm, Value.undefined_, &args_three) catch |err| switch (err) {
                                    error.OutOfMemory => return error.OutOfMemory,
                                    error.NativeThrew => {
                                        const ex = realm.pending_exception orelse try makeTypeError(realm, "defineProperty on class field receiver threw");
                                        realm.pending_exception = null;
                                        f.ip = ip;
                                        f.accumulator = acc;
                                        committed = true;
                                        if (!try unwindThrow(allocator, realm, frames, ex)) {
                                            return .{ .thrown = ex };
                                        }
                                        break;
                                    },
                                };
                            } else {
                                realm.heap.storeProperty(inst, allocator, entry.name, v) catch return error.OutOfMemory;
                            }
                        }
                    }
                }
                if (committed) continue :dispatch try reEnterDispatch(frames, &f, &local_chunk, &code, &registers, &ip, &acc, &committed);
            }
            continue :dispatch try decodeNext(code, &ip, &committed);
        },

        .lda_private => {
            const k = readU16(code, ip);
            ip += 2;
            if (k >= local_chunk.constants.len) return error.InvalidOpcode;
            const key_v = local_chunk.constants[k];
            if (!key_v.isString()) return error.InvalidOpcode;
            const key_s: *JSString = @ptrCast(@alignCast(key_v.asString()));
            // §15.7.14 step 31 — rewrite the compile-time
            // mangled key into the per-evaluation runtime key
            // using the executing method's brand. The brand
            // lives on the method's home_object / home_function
            // — both set by `class.zig` at ClassTail evaluation.
            var brand_buf: [128]u8 = undefined;
            const lookup_key = translatePrivateKey(&brand_buf, key_s.flatBytes(), framePrivateBrand(f, acc, key_s.flatBytes()));
            // §15.7 — `class C { static #x = …; static M() { return C.#x; } }`
            // routes the read through the constructor's
            // private slots when the receiver is the class
            // function itself.
            if (heap_mod.valueAsFunction(acc)) |fn_recv| {
                if (fn_recv.private_accessors.get(lookup_key)) |pa| {
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
                                continue :dispatch try reEnterDispatch(frames, &f, &local_chunk, &code, &registers, &ip, &acc, &committed);
                            },
                        }
                        // Getter ran inline via callJSFunction —
                        // active frame unchanged → decodeNext.
                        continue :dispatch try decodeNext(code, &ip, &committed);
                    }
                    // §10.1.8.1 PrivateFieldGet step 6.b —
                    // accessor without [[Get]] throws TypeError.
                    const ex = try makeTypeError(f.running_realm orelse realm, "Cannot read from private accessor with no getter");
                    f.ip = ip;
                    f.accumulator = acc;
                    committed = true;
                    if (!try unwindThrow(allocator, realm, frames, ex)) {
                        return .{ .thrown = ex };
                    }
                    continue :dispatch try reEnterDispatch(frames, &f, &local_chunk, &code, &registers, &ip, &acc, &committed);
                }
                if (fn_recv.private_properties.get(lookup_key)) |v| {
                    acc = v;
                    continue :dispatch try decodeNext(code, &ip, &committed);
                }
                const ex = try makeTypeError(f.running_realm orelse realm, "Cannot read private field — brand check failed");
                f.ip = ip;
                f.accumulator = acc;
                committed = true;
                if (!try unwindThrow(allocator, realm, frames, ex)) {
                    return .{ .thrown = ex };
                }
                continue :dispatch try reEnterDispatch(frames, &f, &local_chunk, &code, &registers, &ip, &acc, &committed);
            }
            const recv = heap_mod.valueAsPlainObject(acc) orelse {
                const ex = try makeTypeError(f.running_realm orelse realm, "Cannot read private field on non-object");
                f.ip = ip;
                f.accumulator = acc;
                committed = true;
                if (!try unwindThrow(allocator, realm, frames, ex)) {
                    return .{ .thrown = ex };
                }
                continue :dispatch try reEnterDispatch(frames, &f, &local_chunk, &code, &registers, &ip, &acc, &committed);
            };
            // §15.7 — private accessor descriptors win over
            // data slots on read. A read of a write-only
            // accessor (`set #x` without `get #x`) throws
            // TypeError per §10.1.8.1 PrivateFieldGet step 6.b.
            if (recv.getPrivateAccessor(lookup_key)) |pa| {
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
                            continue :dispatch try reEnterDispatch(frames, &f, &local_chunk, &code, &registers, &ip, &acc, &committed);
                        },
                    }
                } else {
                    const ex = try makeTypeError(f.running_realm orelse realm, "Cannot read from private accessor with no getter");
                    f.ip = ip;
                    f.accumulator = acc;
                    committed = true;
                    if (!try unwindThrow(allocator, realm, frames, ex)) {
                        return .{ .thrown = ex };
                    }
                    continue :dispatch try reEnterDispatch(frames, &f, &local_chunk, &code, &registers, &ip, &acc, &committed);
                }
            } else if (recv.getPrivateProperty(lookup_key)) |v| {
                acc = v;
            } else {
                const ex = try makeTypeError(f.running_realm orelse realm, "Cannot read private field — brand check failed");
                f.ip = ip;
                f.accumulator = acc;
                committed = true;
                if (!try unwindThrow(allocator, realm, frames, ex)) {
                    return .{ .thrown = ex };
                }
                continue :dispatch try reEnterDispatch(frames, &f, &local_chunk, &code, &registers, &ip, &acc, &committed);
            }
            continue :dispatch try decodeNext(code, &ip, &committed);
        },

        .private_in => {
            // §13.10.2 PrivateIdentifier in ShiftExpression
            // (class-fields-private-in proposal, stage 4).
            // The RHS landed in `acc`; the compile-time
            // mangled key is at constants[k]. Unlike
            // `lda_private` we tolerate a missing slot — a
            // brand-check miss returns `false` rather than
            // throwing.
            const k = readU16(code, ip);
            ip += 2;
            if (k >= local_chunk.constants.len) return error.InvalidOpcode;
            const key_v_const = local_chunk.constants[k];
            if (!key_v_const.isString()) return error.InvalidOpcode;
            const key_s: *JSString = @ptrCast(@alignCast(key_v_const.asString()));
            // §13.10.2 step 4 — Type(rval) must be Object. A
            // plain primitive (`#x in 1`, `#x in null`, …)
            // throws TypeError.
            if (!acc.isObject()) {
                const ex = try makeTypeError(realm, "Cannot use 'in' operator to search non-object");
                f.ip = ip;
                f.accumulator = acc;
                committed = true;
                if (!try unwindThrow(allocator, realm, frames, ex)) {
                    return .{ .thrown = ex };
                }
                continue :dispatch try reEnterDispatch(frames, &f, &local_chunk, &code, &registers, &ip, &acc, &committed);
            }
            // §15.7.14 step 31 — same brand resolution as
            // `lda_private` / `sta_private`. The runtime key
            // depends on the executing method's home class,
            // so a `#field in obj` reference inside class C
            // resolves against C's private brand, even if the
            // receiver also belongs to a sibling class with a
            // colliding identifier.
            var brand_buf: [128]u8 = undefined;
            const lookup_key = translatePrivateKey(&brand_buf, key_s.flatBytes(), framePrivateBrand(f, acc, key_s.flatBytes()));
            // Static private members live on the class
            // function itself (`#x` declared `static`); instance
            // private members live on the receiver object.
            // Mirror the read/write paths that already
            // distinguish them.
            if (heap_mod.valueAsFunction(acc)) |fn_recv| {
                const present = fn_recv.private_properties.contains(lookup_key) or fn_recv.private_accessors.contains(lookup_key);
                acc = Value.fromBool(present);
                continue :dispatch try decodeNext(code, &ip, &committed);
            }
            if (heap_mod.valueAsPlainObject(acc)) |obj| {
                const present = obj.hasPrivateProperty(lookup_key) or obj.hasPrivateAccessor(lookup_key);
                acc = Value.fromBool(present);
                continue :dispatch try decodeNext(code, &ip, &committed);
            }
            // Some other object kind (Symbol/BigInt wrapped
            // primitives etc.) — they can't carry private
            // slots, so the answer is `false`.
            acc = Value.fromBool(false);
            continue :dispatch try decodeNext(code, &ip, &committed);
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
            realm.heap.setGeneratorEnv(gen, f.env);
            realm.heap.storeInternalSlot(.{ .generator = gen }, f.this_value);
            gen.this_value = f.this_value;
            realm.heap.setGeneratorHomeObject(gen, f.home_object);
            realm.heap.setGeneratorHomeFunction(gen, f.home_function);
            gen.argc = f.argc;
            gen.yielded_iter_result = false;
            f.ip = ip;
            f.accumulator = acc;
            committed = true;
            return .{ .yielded = acc };
        },

        .gen_yield_iter_result => {
            // §15.5.5 step 7.a.iv — sync `yield*` passes
            // the inner iterator's IteratorResult through
            // verbatim. Same save/unwind shape as
            // `gen_yield`, but sets the `yielded_iter_result`
            // flag so `genNext` returns acc as-is instead of
            // wrapping in a fresh CreateIterResultObject.
            const gen = f.generator orelse return error.InvalidOpcode;
            gen.ip = ip;
            gen.accumulator = Value.undefined_;
            realm.heap.setGeneratorEnv(gen, f.env);
            realm.heap.storeInternalSlot(.{ .generator = gen }, f.this_value);
            gen.this_value = f.this_value;
            realm.heap.setGeneratorHomeObject(gen, f.home_object);
            realm.heap.setGeneratorHomeFunction(gen, f.home_function);
            gen.argc = f.argc;
            gen.yielded_iter_result = true;
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
            realm.heap.setGeneratorEnv(gen, f.env);
            realm.heap.storeInternalSlot(.{ .generator = gen }, f.this_value);
            gen.this_value = f.this_value;
            realm.heap.setGeneratorHomeObject(gen, f.home_object);
            realm.heap.setGeneratorHomeFunction(gen, f.home_function);
            gen.argc = f.argc;
            f.ip = ip;
            f.accumulator = acc;
            committed = true;
            return .{ .yielded = Value.undefined_ };
        },

        .await_ => {
            // §27.7.5.3 Await. Per spec the operation is:
            //   1. promise = ? PromiseResolve(%Promise%, v).
            //   2. fulfilledClosure = on-fulfilled steps that
            //      Resume(asyncContext, NormalCompletion(value)).
            //   3. rejectedClosure  = on-rejected steps that
            //      Resume(asyncContext, ThrowCompletion(reason)).
            //   4. PerformPromiseThen(promise, fulfilledClosure,
            //      rejectedClosure).
            //   5. Remove asyncContext from execution stack;
            //      transfer control to its suspending caller.
            //
            // Two observable consequences:
            // • PromiseResolve always allocates a fresh
            //   Promise (or returns `v` unchanged if it's
            //   already a same-realm Promise), so `await N`
            //   for a non-Promise N always defers one tick
            //   — top-level-ticks{,-2}.js asserts this.
            // • PerformPromiseThen always queues the
            //   handler as a microtask, even on an
            //   already-fulfilled Promise — i.e. there is
            //   no synchronous-resume fast path for
            //   `await fulfilledPromise`.
            //
            // Four input shapes, all routed through the
            // same suspend-and-enqueue path:
            //   • pending Promise   → register as waiter,
            //     wait for settlement.
            //   • settled Promise   → enqueue an
            //     async_resume microtask carrying the
            //     unwrapped value / reason.
            //   • thenable (object with callable `.then`)
            //     → §27.7.5.3 step 1 routes through
            //     §27.2.1.3.2 Promise Resolve Functions
            //     7-11, which queues a
            //     PromiseResolveThenableJob against a
            //     fresh pending Promise; we then suspend
            //     on that promise.
            //   • bare value        → enqueue an
            //     async_resume microtask carrying `v`.
            //
            // The microtask drain runs in the surrounding
            // job loop (host CLI, harness, or the
            // microtask drain at the next await / Promise
            // settlement), not synchronously here.
            const v = acc;
            const gen_opt: ?*@import("../generator.zig").JSGenerator = if (f.generator) |g| (if (g.is_async) g else null) else null;
            if (gen_opt) |gen| {
                var suspend_target: ?*JSObject = null;
                var resume_value: Value = v;
                var resume_throws: bool = false;
                var use_microtask: bool = true;
                if (heap_mod.valueAsPlainObject(v)) |obj| {
                    if (obj.isPromise()) {
                        // §27.7.5.3 Await step 1 — PromiseResolve(
                        // %Promise%, value). §27.2.4.7 step 1.a:
                        // when the resolution is already a Promise,
                        // the spec reads `value.constructor` to
                        // honour the species hook before deciding
                        // to return `value` unchanged. Cynic never
                        // species-dispatches (we always reuse the
                        // %Promise%), but the read itself is
                        // observable — a poisoned `constructor`
                        // getter throws, and the `?` on step 1
                        // makes that abrupt completion the result
                        // of Await (the body resumes with a
                        // throw). Mirrors the same read in
                        // `awaitForReturnCompletion`.
                        const ctor_v = intrinsics_mod.getPropertyChain(realm, obj, "constructor") catch |err| switch (err) {
                            error.OutOfMemory => return error.OutOfMemory,
                            else => blk: {
                                const ex = realm.pending_exception orelse Value.undefined_;
                                realm.pending_exception = null;
                                resume_value = ex;
                                resume_throws = true;
                                use_microtask = true;
                                break :blk Value.undefined_;
                            },
                        };
                        if (resume_throws and use_microtask) {
                            // `constructor` getter threw — skip the
                            // ordinary settled/pending dispatch and
                            // resume the body with the thrown value.
                        } else if (obj.promise_state == .pending) {
                            suspend_target = obj;
                            use_microtask = false;
                        } else {
                            resume_value = obj.promise_value;
                            resume_throws = (obj.promise_state == .rejected);
                        }
                        _ = ctor_v;
                    } else {
                        // Thenable check — §27.7.5.3 step 1
                        // through §27.2.1.3.2 Promise Resolve
                        // Functions steps 7-11. `.then` may be
                        // an accessor whose getter throws (e.g.
                        // yield-star-next-then-get-abrupt.js);
                        // route through the prototype-walking
                        // path so accessors fire and any abrupt
                        // completion becomes a rejected Promise
                        // we suspend on.
                        const then_v = intrinsics_mod.getPropertyChain(realm, obj, "then") catch |err| switch (err) {
                            error.OutOfMemory => return error.OutOfMemory,
                            else => blk: {
                                // Getter threw — §27.2.1.3.2
                                // Promise Resolve Functions step
                                // 9.b catches the abrupt and
                                // rejects the synthesised Promise
                                // with it. We then suspend on
                                // that rejected Promise so the
                                // gen body's await resumes with
                                // a throw. The microtask-deferred
                                // path (resume_throws = true)
                                // is observationally identical
                                // — one tick of latency, then
                                // the body lands at the next
                                // exception handler.
                                const ex = realm.pending_exception orelse Value.undefined_;
                                realm.pending_exception = null;
                                resume_value = ex;
                                resume_throws = true;
                                use_microtask = true;
                                break :blk Value.undefined_;
                            },
                        };
                        if (heap_mod.valueAsFunction(then_v) != null) {
                            const promise_v = @import("../builtins/promise.zig").allocatePromise(realm, .pending, Value.undefined_) catch return error.OutOfMemory;
                            const promise_obj = heap_mod.valueAsPlainObject(promise_v) orelse return error.OutOfMemory;
                            realm.enqueueThenableJob(promise_v, v, then_v) catch return error.OutOfMemory;
                            suspend_target = promise_obj;
                            use_microtask = false;
                        }
                    }
                }
                // Save frame state into the gen so the
                // resumption microtask re-enters here.
                gen.ip = ip;
                gen.accumulator = Value.undefined_;
                realm.heap.setGeneratorEnv(gen, f.env);
                realm.heap.storeInternalSlot(.{ .generator = gen }, f.this_value);
                gen.this_value = f.this_value;
                realm.heap.setGeneratorHomeObject(gen, f.home_object);
                realm.heap.setGeneratorHomeFunction(gen, f.home_function);
                gen.argc = f.argc;
                f.ip = ip;
                f.accumulator = Value.undefined_;
                committed = true;
                if (use_microtask) {
                    realm.enqueueAsyncResume(gen, resume_value, resume_throws) catch return error.OutOfMemory;
                } else if (suspend_target) |obj| {
                    const waiters = obj.promiseWaitersPtr(realm.allocator) catch return error.OutOfMemory;
                    waiters.append(realm.allocator, gen) catch return error.OutOfMemory;
                }
                // §27.6.3.4 — async-gen suspended in
                // await must not pop its head request when
                // the queue drain re-enters; plain async
                // functions ignore this flag.
                if (gen.is_async_generator) {
                    gen.async_state = .suspended_await;
                }
                return .{ .yielded = Value.undefined_ };
            }
            // `await` only emits inside async function /
            // async generator bodies (parser-enforced) and
            // module bodies with top-level await (routed
            // through startAsyncCall, so f.generator is
            // set). Reaching here means a caller invoked
            // the opcode outside that envelope — drain any
            // queued microtasks for symmetry and fall
            // through.
            drainMicrotasks(allocator, realm) catch return error.OutOfMemory;
            continue :dispatch try decodeNext(code, &ip, &committed);
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
                    continue :dispatch try reEnterDispatch(frames, &f, &local_chunk, &code, &registers, &ip, &acc, &committed);
                },
                error.InvalidOpcode => return error.InvalidOpcode,
            };
            acc = new_iter;
            continue :dispatch try decodeNext(code, &ip, &committed);
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
                    continue :dispatch try reEnterDispatch(frames, &f, &local_chunk, &code, &registers, &ip, &acc, &committed);
                },
                error.InvalidOpcode => return error.InvalidOpcode,
            };
            acc = new_iter;
            continue :dispatch try decodeNext(code, &ip, &committed);
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
                continue :dispatch try decodeNext(code, &ip, &committed);
            };
            // §7.4.1 Iterator Record — `iter_step` runs many
            // times for one destructuring pattern (`[a, b, c]
            // = src` → three iter_steps). The record caches
            // `[[NextMethod]]` / `[[Done]]` on the iterated
            // object's typed `iter_record` slot — off the
            // property bag, so a user-supplied iterator gains
            // no observable own property.
            const iter_rec: *@import("../object.zig").IterRecord = iter_obj.iter_record orelse blk: {
                const r = realm.allocator.create(@import("../object.zig").IterRecord) catch return error.OutOfMemory;
                r.* = .{};
                iter_obj.iter_record = r;
                break :blk r;
            };
            // Once the iter has surfaced `done: true` we stop
            // calling `.next()` so subsequent pattern slots bind
            // to `undefined` without re-entering the iterator.
            if (iter_rec.done) {
                acc = Value.undefined_;
                registers[r_done] = Value.true_;
                continue :dispatch try decodeNext(code, &ip, &committed);
            }
            // §7.4.5 GetIteratorDirect — the spec captures
            // [[NextMethod]] once at iterator open. Snapshot it
            // on the first step so later steps don't re-fire a
            // `get next()` accessor.
            const next_v = if (iter_rec.next_cached) iter_rec.next else nv: {
                const v = intrinsics_mod.getPropertyChain(realm, iter_obj, "next") catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    else => {
                        const ex = consumePendingException(realm) orelse try makeTypeError(realm, "iterator.next read failed");
                        f.ip = ip;
                        f.accumulator = acc;
                        committed = true;
                        if (!try unwindThrow(allocator, realm, frames, ex)) {
                            return .{ .thrown = ex };
                        }
                        break :nv Value.undefined_;
                    },
                };
                iter_rec.next = v;
                iter_rec.next_cached = true;
                break :nv v;
            };
            if (committed) continue :dispatch try reEnterDispatch(frames, &f, &local_chunk, &code, &registers, &ip, &acc, &committed);
            const next_fn = heap_mod.valueAsFunction(next_v) orelse {
                const ex = try makeTypeError(realm, "iterator.next is not callable");
                f.ip = ip;
                f.accumulator = acc;
                committed = true;
                if (!try unwindThrow(allocator, realm, frames, ex)) {
                    return .{ .thrown = ex };
                }
                continue :dispatch try reEnterDispatch(frames, &f, &local_chunk, &code, &registers, &ip, &acc, &committed);
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
                    iter_rec.done = true;
                    f.ip = ip;
                    f.accumulator = acc;
                    committed = true;
                    if (!try unwindThrow(allocator, realm, frames, ex)) {
                        return .{ .thrown = ex };
                    }
                    continue :dispatch try reEnterDispatch(frames, &f, &local_chunk, &code, &registers, &ip, &acc, &committed);
                },
            };
            if (heap_mod.valueAsPlainObject(result_v)) |result_obj| {
                const done_v = intrinsics_mod.getPropertyChain(realm, result_obj, "done") catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    else => {
                        iter_rec.done = true;
                        const ex = consumePendingException(realm) orelse try makeTypeError(realm, "iterator result .done read failed");
                        f.ip = ip;
                        f.accumulator = acc;
                        committed = true;
                        if (!try unwindThrow(allocator, realm, frames, ex)) {
                            return .{ .thrown = ex };
                        }
                        continue :dispatch try reEnterDispatch(frames, &f, &local_chunk, &code, &registers, &ip, &acc, &committed);
                    },
                };
                if (toBoolean(done_v)) {
                    iter_rec.done = true;
                    acc = Value.undefined_;
                    registers[r_done] = Value.true_;
                    continue :dispatch try decodeNext(code, &ip, &committed);
                }
                const value_v = intrinsics_mod.getPropertyChain(realm, result_obj, "value") catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    else => {
                        iter_rec.done = true;
                        const ex = consumePendingException(realm) orelse try makeTypeError(realm, "iterator result .value read failed");
                        f.ip = ip;
                        f.accumulator = acc;
                        committed = true;
                        if (!try unwindThrow(allocator, realm, frames, ex)) {
                            return .{ .thrown = ex };
                        }
                        continue :dispatch try reEnterDispatch(frames, &f, &local_chunk, &code, &registers, &ip, &acc, &committed);
                    },
                };
                acc = value_v;
                registers[r_done] = Value.false_;
            } else {
                // §7.4.4 step 5 — `next()` result is not an
                // object → TypeError. Mark done so the
                // pattern walk's trailing `iter_close` no-ops.
                iter_rec.done = true;
                const ex = try makeTypeError(realm, "iterator result is not an object");
                f.ip = ip;
                f.accumulator = acc;
                committed = true;
                if (!try unwindThrow(allocator, realm, frames, ex)) {
                    return .{ .thrown = ex };
                }
                continue :dispatch try reEnterDispatch(frames, &f, &local_chunk, &code, &registers, &ip, &acc, &committed);
            }
            continue :dispatch try decodeNext(code, &ip, &committed);
        },

        .for_of_next => {
            // §7.4.2 IteratorNext + §7.4.8 IteratorStepValue,
            // folded for plain sync `for-of`. `r_next` holds
            // the iterator's `[[NextMethod]]` captured at loop
            // entry. Produces the stepped value in `acc` and
            // the boolean `done` in `r_done`.
            const r_iter = code[ip];
            const r_next = code[ip + 1];
            const r_done = code[ip + 2];
            ip += 3;
            const iter_v = registers[r_iter];
            const next_v = registers[r_next];

            // Fast path — the unmodified built-in Array
            // iterator: carries `array_like_iter` state, chains
            // to `%ArrayIteratorPrototype%`, and `r_next` is
            // still the original `next` native. Step the
            // backing storage directly; no `.next()` call, no
            // CreateIterResultObject allocation.
            fast: {
                const iter_obj = heap_mod.valueAsPlainObject(iter_v) orelse break :fast;
                const st = iter_obj.array_like_iter orelse break :fast;
                // `entries` builds a [k,v] pair object — leave
                // it to the spec slow path below.
                if (st.kind == .entries) break :fast;
                if (iter_obj.prototype != realm.intrinsics.array_iterator_prototype) break :fast;
                if (next_v.bits != realm.intrinsics.array_iterator_next.bits) break :fast;
                const collections_mod = @import("../builtins/collections.zig");
                const stepped = collections_mod.arrayIterStepFast(realm, iter_v) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    else => {
                        const ex = consumePendingException(realm) orelse try makeTypeError(realm, "iterator step failed");
                        f.ip = ip;
                        f.accumulator = acc;
                        committed = true;
                        if (!try unwindThrow(allocator, realm, frames, ex)) {
                            return .{ .thrown = ex };
                        }
                        continue :dispatch try reEnterDispatch(frames, &f, &local_chunk, &code, &registers, &ip, &acc, &committed);
                    },
                };
                if (stepped) |v| {
                    acc = v;
                    registers[r_done] = Value.false_;
                } else {
                    acc = Value.undefined_;
                    registers[r_done] = Value.true_;
                }
                continue :dispatch try decodeNext(code, &ip, &committed);
            }

            // Slow path — §7.4.2 IteratorNext protocol. Any
            // sync iterator: generators, Map / Set / String
            // iterators, user iterables, or a monkeypatched
            // Array iterator.
            const next_fn = heap_mod.valueAsFunction(next_v) orelse {
                const ex = try makeTypeError(realm, "iterator.next is not a function");
                f.ip = ip;
                f.accumulator = acc;
                committed = true;
                if (!try unwindThrow(allocator, realm, frames, ex)) {
                    return .{ .thrown = ex };
                }
                continue :dispatch try reEnterDispatch(frames, &f, &local_chunk, &code, &registers, &ip, &acc, &committed);
            };
            const outcome = callJSFunction(allocator, realm, next_fn, iter_v, &.{}) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return error.InvalidOpcode,
            };
            const result_v = switch (outcome) {
                .value, .yielded => |v| v,
                .thrown => |ex| {
                    f.ip = ip;
                    f.accumulator = acc;
                    committed = true;
                    if (!try unwindThrow(allocator, realm, frames, ex)) {
                        return .{ .thrown = ex };
                    }
                    continue :dispatch try reEnterDispatch(frames, &f, &local_chunk, &code, &registers, &ip, &acc, &committed);
                },
            };
            // §7.4.2 step 4 — `next()` result must be an object.
            const result_obj = heap_mod.valueAsPlainObject(result_v) orelse {
                const ex = try makeTypeError(realm, "iterator result is not an object");
                f.ip = ip;
                f.accumulator = acc;
                committed = true;
                if (!try unwindThrow(allocator, realm, frames, ex)) {
                    return .{ .thrown = ex };
                }
                continue :dispatch try reEnterDispatch(frames, &f, &local_chunk, &code, &registers, &ip, &acc, &committed);
            };
            // §7.4.3 IteratorComplete — read `.done`.
            const done_v = intrinsics_mod.getPropertyChain(realm, result_obj, "done") catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => {
                    const ex = consumePendingException(realm) orelse try makeTypeError(realm, "iterator result .done read failed");
                    f.ip = ip;
                    f.accumulator = acc;
                    committed = true;
                    if (!try unwindThrow(allocator, realm, frames, ex)) {
                        return .{ .thrown = ex };
                    }
                    continue :dispatch try reEnterDispatch(frames, &f, &local_chunk, &code, &registers, &ip, &acc, &committed);
                },
            };
            if (toBoolean(done_v)) {
                // §7.4.8 step 3 — on `done`, `.value` is NOT read.
                acc = Value.undefined_;
                registers[r_done] = Value.true_;
                continue :dispatch try decodeNext(code, &ip, &committed);
            }
            // §7.4.7 IteratorValue — read `.value`.
            const value_v = intrinsics_mod.getPropertyChain(realm, result_obj, "value") catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => {
                    const ex = consumePendingException(realm) orelse try makeTypeError(realm, "iterator result .value read failed");
                    f.ip = ip;
                    f.accumulator = acc;
                    committed = true;
                    if (!try unwindThrow(allocator, realm, frames, ex)) {
                        return .{ .thrown = ex };
                    }
                    continue :dispatch try reEnterDispatch(frames, &f, &local_chunk, &code, &registers, &ip, &acc, &committed);
                },
            };
            acc = value_v;
            registers[r_done] = Value.false_;
            continue :dispatch try decodeNext(code, &ip, &committed);
        },

        .for_in_open => {
            // §14.7.5.6 — snapshot the object's own + inherited
            // string keys into a fresh array iterator. `null` /
            // `undefined` produce an empty iterator.
            if (acc.isNull() or acc.isUndefined()) {
                const empty = realm.heap.allocateObject() catch return error.OutOfMemory;
                realm.heap.setObjectPrototype(empty, realm.intrinsics.array_prototype);
                empty.markAsArrayExotic(allocator) catch return error.OutOfMemory;
                realm.heap.storeProperty(empty, allocator, "length", Value.fromInt32(0)) catch return error.OutOfMemory;
                acc = openIterator(allocator, realm, heap_mod.taggedObject(empty)) catch return error.OutOfMemory;
            } else {
                // §9.4.6.4 Module Namespace [[GetOwnProperty]]
                // — EnumerateObjectProperties (§14.7.5.6) reads
                // each own descriptor, materialising
                // `[[Value]]` via [[Get]] (§9.4.6.7). Probe the
                // namespace for any TDZ-Hole-seeded exported
                // binding up front and throw ReferenceError if
                // present; matches the spec's per-key probe
                // before the loop body runs.
                if (heap_mod.valueAsPlainObject(acc)) |ns_obj| {
                    if (ns_obj.is_module_namespace) {
                        var ns_it = ns_obj.iterOwnNamedKeys();
                        const probe_outcome = blk_probe: while (ns_it.next()) |entry| {
                            const k = entry.key_ptr.*;
                            if (std.mem.startsWith(u8, k, "__cynic_")) continue;
                            if (std.mem.startsWith(u8, k, "@@") or std.mem.startsWith(u8, k, "<sym:")) continue;
                            if (entry.value_ptr.*.isHole()) {
                                const ex = makeReferenceError(realm, k) catch return error.OutOfMemory;
                                break :blk_probe ex;
                            }
                        } else break :blk_probe Value.undefined_;
                        if (!probe_outcome.isUndefined()) {
                            f.ip = ip;
                            f.accumulator = acc;
                            committed = true;
                            if (!try unwindThrow(allocator, realm, frames, probe_outcome)) {
                                return .{ .thrown = probe_outcome };
                            }
                            continue :dispatch try reEnterDispatch(frames, &f, &local_chunk, &code, &registers, &ip, &acc, &committed);
                        }
                    }
                }
                acc = openForInIterator(allocator, realm, acc) catch return error.OutOfMemory;
            }
            continue :dispatch try decodeNext(code, &ip, &committed);
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
            continue :dispatch try decodeNext(code, &ip, &committed);
        },

        .module_load => {
            const k = readU16(code, ip);
            ip += 2;
            const k_attr = readU16(code, ip);
            ip += 2;
            if (k >= local_chunk.constants.len) return error.InvalidOpcode;
            const spec_v = local_chunk.constants[k];
            if (!spec_v.isString()) return error.InvalidOpcode;
            const spec_s: *JSString = @ptrCast(@alignCast(spec_v.asString()));
            // §16.2.1.4 — `0xFFFF` is the compiler's "no
            // `with { type: "..." }`" sentinel (see
            // `Compiler.MODULE_NO_ATTRIBUTE` in
            // `src/bytecode/compiler.zig`).
            const attribute_type: ?[]const u8 = if (k_attr == 0xFFFF) null else blk: {
                if (k_attr >= local_chunk.constants.len) return error.InvalidOpcode;
                const a_v = local_chunk.constants[k_attr];
                if (!a_v.isString()) return error.InvalidOpcode;
                const a_s: *JSString = @ptrCast(@alignCast(a_v.asString()));
                break :blk a_s.flatBytes();
            };
            const outcome = loadModule(allocator, realm, spec_s.flatBytes(), local_chunk.base_url, attribute_type) catch |err| switch (err) {
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
                continue :dispatch try reEnterDispatch(frames, &f, &local_chunk, &code, &registers, &ip, &acc, &committed);
            }
            acc = outcome.value;
            continue :dispatch try decodeNext(code, &ip, &committed);
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
            //
            // Spec algorithm (§13.3.10.1 / §16.2.1.10
            // EvaluateImportCall):
            //   5. Let promiseCapability be ! NewPromiseCapability(%Promise%).
            //   6. Let specifierString be Completion(ToString(specifier)).
            //   7. IfAbruptRejectPromise(specifierString, promiseCapability).
            //   8. Perform HostImportModuleDynamically(...).
            //   9. Return promiseCapability.[[Promise]].
            const promise_mod = @import("../builtins/promise.zig");

            const k_attr = readU16(code, ip);
            ip += 2;
            const attribute_type: ?[]const u8 = if (k_attr == 0xFFFF) null else blk: {
                if (k_attr >= local_chunk.constants.len) return error.InvalidOpcode;
                const a_v = local_chunk.constants[k_attr];
                if (!a_v.isString()) return error.InvalidOpcode;
                const a_s: *JSString = @ptrCast(@alignCast(a_v.asString()));
                break :blk a_s.flatBytes();
            };

            // §13.3.10.1 step 6 — ToString(specifier). For
            // primitives this is the trivial branch; for objects
            // it dispatches into `Symbol.toPrimitive` / `toString`
            // / `valueOf` and may throw (Symbol, user toString
            // throwing). Any abrupt completion routes to a
            // rejected Promise per IfAbruptRejectPromise.
            const di_spec_string: ?*JSString = intrinsics_mod.stringifyArg(realm, acc) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.NativeThrew => di_blk: {
                    const ex = realm.pending_exception orelse try makeTypeError(realm, "import specifier coercion failed");
                    realm.pending_exception = null;
                    acc = try promise_mod.allocatePromiseFor(realm, null, .rejected, ex);
                    break :di_blk null;
                },
            };
            if (di_spec_string) |spec_string| {
                // §16.2.1.10 EvaluateImportCall — the module
                // load + link + InnerModuleEvaluation must NOT
                // run synchronously at the `import()` call site.
                // If it did, a dynamic import naming a module
                // that is also a *static* dependency of the
                // surrounding graph would evaluate that module
                // mid-body, before the synchronous §16.2.1.5
                // DFS reaches it — perturbing evaluation order
                // ("dynamic import can't preempt DFS order").
                // Allocate the pending result Promise now and
                // defer the actual `loadModule` to a microtask
                // job; the job settles this Promise once the
                // module (whether freshly loaded here or
                // already evaluated by the static DFS) is
                // ready.
                const pending = try promise_mod.allocatePromiseFor(realm, null, .pending, Value.undefined_);
                try realm.enqueueModuleImport(
                    Value.fromString(spec_string),
                    pending,
                    local_chunk.base_url,
                    attribute_type,
                );
                acc = pending;
            }
            continue :dispatch try decodeNext(code, &ip, &committed);
        },

        .dynamic_import_with_options => {
            // §13.3.10 dynamic `import(specifier, options)` with
            // a non-literal `options` expression. The compiler
            // pre-stored the specifier into `r_spec`; `options`
            // arrives in `acc`. Implements §13.3.10.1
            // EvaluateImportCall steps 9-15:
            //   9.  Let attributes be a new empty List.
            //   10. If options is not undefined, then
            //       a. If Type(options) is not Object → reject
            //          promise with TypeError.
            //       b. Let attributesObj be ? Get(options, "with").
            //       c. IfAbruptRejectPromise(attributesObj).
            //       d. If attributesObj is not undefined:
            //          i.   If Type(attributesObj) is not Object
            //               → reject.
            //          ii.  Let keys be ? EnumerableOwnNames(
            //               attributesObj).
            //          iii. For each String key of keys:
            //               - Let value be ? Get(attributesObj,
            //                 key).
            //               - If Type(value) is not String →
            //                 reject TypeError.
            //               - Otherwise add to attributes.
            //   11-15. Resolve specifier + perform host import.
            //
            // The only attribute Cynic's loader inspects today
            // is `"type"`; other keys are still observed through
            // their `Get` (so Proxy traps fire) but discarded.
            const promise_mod = @import("../builtins/promise.zig");
            const object_helpers = @import("../builtins/object.zig");

            const r_spec = code[ip];
            ip += 1;
            const options_v = acc;
            const specifier_v = registers[r_spec];

            // §13.3.10.1 step 7 — ToString(specifier). Any abrupt
            // completion goes to a rejected Promise.
            const dio_spec_string: ?*JSString = intrinsics_mod.stringifyArg(realm, specifier_v) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.NativeThrew => spec_blk: {
                    const ex = realm.pending_exception orelse try makeTypeError(realm, "import specifier coercion failed");
                    realm.pending_exception = null;
                    acc = try promise_mod.allocatePromiseFor(realm, null, .rejected, ex);
                    break :spec_blk null;
                },
            };
            if (dio_spec_string == null) {
                continue :dispatch try decodeNext(code, &ip, &committed);
            }
            const spec_string = dio_spec_string.?;

            // §13.3.10.1 step 9-10 — walk the options object,
            // gathering `type` if present. Track abrupt
            // completions and the failure reason value so the
            // caller can construct the right rejection.
            var attribute_type: ?[]const u8 = null;
            var attr_owned: ?[]u8 = null;
            defer if (attr_owned) |o| realm.allocator.free(o);
            var reject_reason: ?Value = null;

            if (!options_v.isUndefined()) {
                if (heap_mod.valueAsPlainObject(options_v)) |opts_obj| {
                    // step 10.b — `attributesObj = Get(options,
                    // "with")`. Use the accessor-aware getter so a
                    // user-installed getter / Proxy `get` trap
                    // fires; an abrupt completion routes to the
                    // rejected-Promise path through `realm.
                    // pending_exception`.
                    const with_v = blk: {
                        const v = intrinsics_mod.getPropertyChain(realm, opts_obj, "with") catch |err| switch (err) {
                            error.OutOfMemory => return error.OutOfMemory,
                            error.NativeThrew => {
                                const ex = realm.pending_exception orelse try makeTypeError(realm, "Get(options, \"with\") threw");
                                realm.pending_exception = null;
                                reject_reason = ex;
                                break :blk Value.undefined_;
                            },
                        };
                        break :blk v;
                    };
                    if (reject_reason == null and !with_v.isUndefined()) {
                        if (heap_mod.valueAsPlainObject(with_v)) |with_obj| {
                            // step 10.d.ii — EnumerableOwnPropertyNames.
                            // `enumerableOwnPropertyKeyValues` fires
                            // Proxy `ownKeys` / `getOwnPropertyDescriptor`
                            // / `get` traps per spec, and roots each
                            // gathered key/value across the loop's
                            // JS re-entries.
                            const enum_scope = realm.heap.openScope() catch return error.OutOfMemory;
                            defer enum_scope.close();
                            const entries = object_helpers.enumerableOwnPropertyKeyValues(realm, with_obj, enum_scope) catch |err| switch (err) {
                                error.OutOfMemory => return error.OutOfMemory,
                                error.NativeThrew => en_blk: {
                                    const ex = realm.pending_exception orelse try makeTypeError(realm, "options.with enumeration threw");
                                    realm.pending_exception = null;
                                    reject_reason = ex;
                                    break :en_blk &.{};
                                },
                            };
                            defer realm.allocator.free(entries);
                            if (reject_reason == null) {
                                for (entries) |entry| {
                                    // step 10.d.iii.2 — value must be a
                                    // String. Numbers, Symbols, etc.
                                    // surface as TypeError.
                                    if (!entry.value.isString()) {
                                        reject_reason = try makeTypeError(realm, "Import attribute value must be a string");
                                        break;
                                    }
                                    const key_bytes = entry.key_str.flatBytes();
                                    if (std.mem.eql(u8, key_bytes, "type")) {
                                        const val_str: *JSString = @ptrCast(@alignCast(entry.value.asString()));
                                        const val_bytes = val_str.flatBytes();
                                        // Copy now — `entries` and the
                                        // gathered strings live on the
                                        // enum scope, which goes out of
                                        // scope at the `defer close` above.
                                        attr_owned = realm.allocator.dupe(u8, val_bytes) catch return error.OutOfMemory;
                                        attribute_type = attr_owned.?;
                                    }
                                }
                            }
                        } else {
                            // step 10.d.i — non-Object `with` → TypeError.
                            reject_reason = try makeTypeError(realm, "Import attributes 'with' must be an Object");
                        }
                    }
                } else {
                    // step 10.a — non-Object options → TypeError.
                    reject_reason = try makeTypeError(realm, "import() options must be an Object");
                }
            }

            if (reject_reason) |ex| {
                acc = try promise_mod.allocatePromiseFor(realm, null, .rejected, ex);
                continue :dispatch try decodeNext(code, &ip, &committed);
            }

            // Happy path — enqueue the deferred load with the
            // resolved attribute. Mirrors the static `.dynamic_import`
            // tail; see the spec ordering rationale there.
            const pending = try promise_mod.allocatePromiseFor(realm, null, .pending, Value.undefined_);
            try realm.enqueueModuleImport(
                Value.fromString(spec_string),
                pending,
                local_chunk.base_url,
                attribute_type,
            );
            acc = pending;
            continue :dispatch try decodeNext(code, &ip, &committed);
        },

        .module_export => {
            const k = readU16(code, ip);
            ip += 2;
            if (k >= local_chunk.constants.len) return error.InvalidOpcode;
            const name_v = local_chunk.constants[k];
            if (!name_v.isString()) return error.InvalidOpcode;
            const name_s: *JSString = @ptrCast(@alignCast(name_v.asString()));
            // §16.2.3.7 ExportDeclaration : `export default`
            // AssignmentExpression, step 3 — if the value is
            // an anonymous function-like definition and has no
            // own `name` property, SetFunctionName(value,
            // "default"). The compiler routes both anonymous
            // FunctionExpressions / ClassExpressions and the
            // `export default function () {}` / `export default
            // class {}` forms through `default_value` with the
            // expression's compiled value in `acc` — both
            // land here with an empty-named JSFunction. Named
            // forms already have a non-empty own `name`, so the
            // own-property check leaves them alone.
            if (std.mem.eql(u8, name_s.flatBytes(), "default")) {
                if (heap_mod.valueAsFunction(acc)) |fn_obj| {
                    // §16.2.3.7 step 3 — `If hasNameProperty is
                    // false, perform SetFunctionName(value,
                    // "default")`. Spec uses HasOwnProperty,
                    // but Cynic auto-installs `name = ""` on
                    // every freshly-allocated JSFunction (so
                    // `Object.getOwnPropertyDescriptor(fn,
                    // "name")` returns a real descriptor for
                    // anonymous fns), which makes a literal
                    // hasOwn check trivially true. Treat
                    // "empty-string name" as the auto-install
                    // marker and overwrite it; any other own
                    // value (`static name() { … }`, an explicit
                    // name from a NamedEvaluation, …) skips
                    // the rename per spec.
                    const cur = fn_obj.get("name");
                    const looks_anonymous = blk: {
                        if (!cur.isString()) break :blk false;
                        const cs: *JSString = @ptrCast(@alignCast(cur.asString()));
                        break :blk cs.flatBytes().len == 0;
                    };
                    if (looks_anonymous) {
                        const owned = realm.heap.allocateString("default") catch return error.OutOfMemory;
                        realm.heap.storeFunctionProperty(fn_obj, realm.allocator, "name", Value.fromString(owned)) catch return error.OutOfMemory;
                        realm.heap.setFunctionNameString(fn_obj, owned);
                        fn_obj.name = owned.flatBytes();
                    }
                }
            }
            // §9.4.6.7 live bindings — publish to the module that
            // DEFINED this code (the frame's `owning_module`), not
            // whatever module happens to be current in the caller:
            // an exported function mutating its own module-level
            // binding may be invoked from another module, from
            // script code, or from a host callback, and the
            // namespace it must update is always its defining
            // module's. Module top-level frames fall back to
            // `realm.current_module` (set by module evaluation).
            if (f.owning_module orelse realm.current_module) |mr| {
                mr.exports.set(realm.allocator, name_s.flatBytes(), acc) catch return error.OutOfMemory;
            }
            // No-op outside module context (e.g. running
            // module-shaped code as a script for tests).
            continue :dispatch try decodeNext(code, &ip, &committed);
        },

        .module_reexport_named => {
            const k_local = readU16(code, ip);
            ip += 2;
            const k_exported = readU16(code, ip);
            ip += 2;
            if (k_local >= local_chunk.constants.len) return error.InvalidOpcode;
            if (k_exported >= local_chunk.constants.len) return error.InvalidOpcode;
            const local_v = local_chunk.constants[k_local];
            const exp_v = local_chunk.constants[k_exported];
            if (!local_v.isString() or !exp_v.isString()) return error.InvalidOpcode;
            const local_s: *JSString = @ptrCast(@alignCast(local_v.asString()));
            const exp_s: *JSString = @ptrCast(@alignCast(exp_v.asString()));
            if (realm.current_module) |mr| {
                if (heap_mod.valueAsPlainObject(acc)) |src_obj| {
                    // §15.2.1.16.3 ResolveExport — install a
                    // live redirect entry so reads through
                    // `mr.exports[exp_s]` walk to
                    // `src_obj[local_s]` at access time.
                    // Resolving lazily lets the chain pick up
                    // bindings that the source module only
                    // publishes after a cycle returns (cf.
                    // `instn-named-iee-cycle` — long chains of
                    // re-exports terminating at a `var`).
                    //
                    // We still pre-clear any pre-seeded Hole on
                    // the importer's exports map so the
                    // namespace doesn't carry a stale Hole
                    // value alongside the redirect (the
                    // redirect-first lookup path skips the
                    // local map when a redirect is present).
                    mr.exports.putNamespaceRedirect(realm.allocator, exp_s.flatBytes(), .{
                        .target_ns = src_obj,
                        .target_key = local_s.flatBytes(),
                        // §15.2.1.16 IndirectExportEntries — flag
                        // so post-body validation in
                        // `validateIndirectExports` walks this
                        // entry. Star-merged redirects via
                        // `mergeStarKey` leave the flag default
                        // false; they're not validated at
                        // instantiation per spec.
                        .from_indirect_export = true,
                    }) catch return error.OutOfMemory;
                    // Drop the placeholder so `'X' in ns`
                    // still resolves through the redirect
                    // walk without an empty data slot getting
                    // in the way. Demote first: the shadow
                    // shape can't encode a removal.
                    mr.exports.demoteFromShape(allocator) catch return error.OutOfMemory;
                    _ = mr.exports.properties.swapRemove(exp_s.flatBytes());
                }
            }
            continue :dispatch try decodeNext(code, &ip, &committed);
        },

        .module_reexport_star => {
            // §16.2.3.7 ExportDeclaration step 8 (no `as`) —
            // merge every non-`default` own export from the
            // source namespace (in `acc`) onto the executing
            // module's namespace as a *redirect* pointing at
            // the source. Redirects (not value-copies) so a
            // chained `export *` walks back to the originating
            // module at read time.
            //
            // §15.2.1.16.3 step 8 ambiguity check — when two
            // distinct `export *` sources both expose the
            // same name and the underlying bindings live on
            // different modules, the resolution is ambiguous.
            // §15.2.1.18 GetModuleNamespace step 3.c says
            // ambiguous names DO NOT appear in the namespace's
            // exported names. We detect this by walking the
            // redirect chains of the existing and new entries
            // down to their terminal (module, binding) pairs;
            // if they differ, drop the binding and record it
            // in `ambiguous_namespace_keys` so `'X' in ns` /
            // `Object.keys(ns)` / `Reflect.has(ns, 'X')` skip
            // it (matches §9.4.6.{2,5,7}).
            //
            // Local / indirect exports take precedence over
            // star entries (§15.2.1.16.3 step 4-5 before step
            // 8): if the key is already in `properties` (a
            // local export pre-seeded by `seedTdzExportHoles`
            // / `publishExportedNamesFromDecl`) or in
            // `namespace_redirects` from a prior `export
            // { X } from "..."`, the star entry is a no-op.
            //
            // No-op outside module context.
            if (realm.current_module) |mr| {
                const src_obj = heap_mod.valueAsPlainObject(acc) orelse {
                    continue :dispatch try decodeNext(code, &ip, &committed);
                };
                // Helper closure values can't be expressed in
                // Zig's switch arms — inline the merge for
                // each iter so the ambiguity check stays close
                // to the install site.
                var it = src_obj.iterOwnNamedKeys();
                while (it.next()) |entry| {
                    const key = entry.key_ptr.*;
                    if (std.mem.eql(u8, key, "default")) continue;
                    if (std.mem.eql(u8, key, "@@toStringTag")) continue;
                    try mergeStarKey(realm.allocator, mr.exports, key, src_obj, key);
                }
                if (src_obj.namespaceRedirectIterator()) |rit_outer| {
                    var rit = rit_outer;
                    while (rit.next()) |entry| {
                        const key = entry.key_ptr.*;
                        if (std.mem.eql(u8, key, "default")) continue;
                        try mergeStarKey(realm.allocator, mr.exports, key, src_obj, key);
                    }
                }
            }
            continue :dispatch try decodeNext(code, &ip, &committed);
        },

        .module_link_complete => {
            // §16.2.1.5 InnerModuleEvaluation — emitted by
            // the compiler after the importer's hoisted
            // import block, before its body proper.
            // `loadModule` walked each dep depth-first
            // already; sync ones ran to completion, async
            // ones suspended at their top-level `await`
            // (or transitively re-suspended an ancestor in
            // a cycle). Drain microtasks now so any
            // outstanding async-module work gets a chance
            // to settle before the importer's body touches
            // their exports — matters for both the direct
            // dep case (the dep's body has suspended at
            // TLA and we recorded its evaluation Promise
            // on `pending_async_deps`) AND the cycle-root
            // case (importer imports a cycle-leaf that's
            // already `.evaluated`, but the cycle-root is
            // still suspended; per §16.2.1.5 step 11.c.iv.1
            // the importer waits on the CycleRoot, not the
            // leaf — so we drain even with an empty
            // pending list).
            //
            // After draining, walk `pending_async_deps`:
            // any dep whose evaluation Promise rejected
            // becomes an abrupt completion at this link
            // boundary (matches §16.2.1.9
            // AsyncModuleExecutionRejected propagating to
            // each [[AsyncParentModule]]).
            const mr = realm.current_module orelse continue :dispatch try decodeNext(code, &ip, &committed);
            f.ip = ip;
            f.accumulator = acc;
            committed = true;
            try drainMicrotasks(allocator, realm);
            var dep_rejection: ?Value = null;
            for (mr.pending_async_deps.items) |dep| {
                if (heap_mod.valueAsPlainObject(dep.evaluation_promise)) |p_obj| {
                    if (p_obj.isPromise() and p_obj.promise_state == .rejected) {
                        dep_rejection = p_obj.promise_value;
                        break;
                    }
                }
            }
            mr.pending_async_deps.clearRetainingCapacity();
            if (dep_rejection) |ex| {
                if (!try unwindThrow(allocator, realm, frames, ex)) {
                    return .{ .thrown = ex };
                }
                continue :dispatch try reEnterDispatch(frames, &f, &local_chunk, &code, &registers, &ip, &acc, &committed);
            }
            ip = f.ip;
            acc = f.accumulator;
            committed = false;
            continue :dispatch try decodeNext(code, &ip, &committed);
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
            // §10.4.4 CreateUnmappedArgumentsObject runs in the *running
            // function's* execution context, so its %Object.prototype%,
            // %ThrowTypeError% (callee trap), and %Array.prototype.values%
            // (@@iterator) come from that function's [[Realm]], not the
            // caller's. For a cross-realm call (`other.fn()`) the frame's
            // `running_realm` is the callee's home realm; same-realm it is
            // the dispatch realm (or null → fall back). The heap is shared,
            // so allocation still goes through `realm.heap`.
            const arg_realm = f.running_realm orelse realm;
            const obj = realm.heap.allocateObject() catch return error.OutOfMemory;
            realm.heap.setObjectPrototype(obj, arg_realm.intrinsics.object_prototype);
            obj.is_arguments_exotic = true;
            var i: u32 = 0;
            while (i < f.argc) : (i += 1) {
                var ibuf: [16]u8 = undefined;
                const islice = std.fmt.bufPrint(&ibuf, "{d}", .{i}) catch unreachable;
                const owned = realm.heap.allocateString(islice) catch return error.OutOfMemory;
                // The index key is a freshly heap-allocated JSString;
                // anchor it on the object so a GC sweep can't free the
                // key slice out from under `arguments[i]` lookups.
                realm.heap.storePropertyComputedOwned(obj, allocator, owned, registers[i]) catch return error.OutOfMemory;
            }
            // §10.4.4.6 step 8 — `length` is `{ writable: true,
            // enumerable: false, configurable: true }`. Default
            // `set` lands at all-true, so `Object.keys(arguments)`
            // surfaced "length" as an enumerable own key.
            realm.heap.storePropertyWithFlags(obj, allocator, "length", Value.fromInt32(@intCast(f.argc)), .{
                .writable = true,
                .enumerable = false,
                .configurable = true,
            }) catch return error.OutOfMemory;
            // §10.4.4.7 step 5 — strict-mode unmapped arguments
            // installs a `callee` accessor whose [[Get]] and
            // [[Set]] are both %ThrowTypeError%. Cynic is
            // strict-only, so every `arguments` object lands
            // here. The thrower function is a per-realm
            // singleton (§10.2.4); reuse the running function's.
            if (arg_realm.intrinsics.throw_type_error) |thrower| {
                const entry = obj.getOrPutAccessor(allocator, "callee") catch return error.OutOfMemory;
                realm.heap.storeInternalSlot(.{ .object = obj }, heap_mod.taggedFunction(thrower));
                entry.value_ptr.* = .{ .getter = thrower, .setter = thrower };
                obj.property_flags.put(allocator, "callee", .{
                    .writable = false,
                    .enumerable = false,
                    .configurable = false,
                }) catch return error.OutOfMemory;
            }
            // §10.4.4.7 step 7 — DefinePropertyOrThrow on
            // @@iterator pointing at %Array.prototype.values%.
            // Without this, `[...arguments]` and
            // `for (const x of arguments)` fall through the
            // GetIterator path with a TypeError. Resolve the
            // function via Array.prototype.values (its identity
            // is intentional — `arguments[@@iterator] ===
            // Array.prototype.values` per §10.4.4.7 step 7).
            if (arg_realm.intrinsics.array_prototype) |arr_proto| {
                const values_v = arr_proto.get("values");
                if (heap_mod.valueAsFunction(values_v) != null) {
                    realm.heap.storePropertyWithFlags(obj, allocator, "@@iterator", values_v, .{
                        .writable = true,
                        .enumerable = false,
                        .configurable = true,
                    }) catch return error.OutOfMemory;
                }
            }
            acc = heap_mod.taggedObject(obj);
            continue :dispatch try decodeNext(code, &ip, &committed);
        },

        .rest_args_from => {
            // §15.2.4 — collect the trailing args into a real
            // Array (not an array-like). Slot `start` is the
            // first arg index past the named non-rest params.
            const start = code[ip];
            ip += 1;
            const obj = realm.heap.allocateObject() catch return error.OutOfMemory;
            realm.heap.setObjectPrototype(obj, realm.intrinsics.array_prototype);
            obj.markAsArrayExotic(allocator) catch return error.OutOfMemory;
            var len: i32 = 0;
            if (start < f.argc) {
                var i: u32 = start;
                while (i < f.argc) : (i += 1) {
                    var ibuf: [16]u8 = undefined;
                    const islice = std.fmt.bufPrint(&ibuf, "{d}", .{len}) catch unreachable;
                    const owned = realm.heap.allocateString(islice) catch return error.OutOfMemory;
                    realm.heap.storeProperty(obj, allocator, owned.flatBytes(), registers[i]) catch return error.OutOfMemory;
                    len += 1;
                }
            }
            realm.heap.storeProperty(obj, allocator, "length", Value.fromInt32(len)) catch return error.OutOfMemory;
            acc = heap_mod.taggedObject(obj);
            continue :dispatch try decodeNext(code, &ip, &committed);
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
            // The shadow shape only models data properties; an
            // accessor install demotes to dictionary mode so the
            // shape never claims the accessor key.
            obj.demoteFromShape(allocator) catch return error.OutOfMemory;
            const entry = obj.getOrPutAccessor(allocator, key_s.flatBytes()) catch return error.OutOfMemory;
            if (!entry.found_existing) entry.value_ptr.* = .{};
            if (is_setter) {
                realm.heap.setAccessorSetter(.{ .object = obj }, entry.value_ptr, fn_obj);
            } else {
                realm.heap.setAccessorGetter(.{ .object = obj }, entry.value_ptr, fn_obj);
            }
            // §10.1.11 OrdinaryOwnPropertyKeys — accessor counts as
            // an own key for enumeration order.
            _ = obj.recordKey(allocator, key_s.flatBytes()) catch return error.OutOfMemory;
            continue :dispatch try decodeNext(code, &ip, &committed);
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
                    continue :dispatch try reEnterDispatch(frames, &f, &local_chunk, &code, &registers, &ip, &acc, &committed);
                },
                .uncaught => |ex| return .{ .thrown = ex },
            };
            var key_buf: [64]u8 = undefined;
            const key_slice = computedKeyToString(key_v, &key_buf);
            const obj = heap_mod.valueAsPlainObject(registers[r_obj]) orelse return error.InvalidOpcode;
            const fn_obj = heap_mod.valueAsFunction(acc) orelse return error.InvalidOpcode;
            // Accessor install: the shadow shape only models data
            // properties, so demote before recording the accessor.
            obj.demoteFromShape(allocator) catch return error.OutOfMemory;
            const owned = realm.heap.allocateString(key_slice) catch return error.OutOfMemory;
            const entry = obj.getOrPutAccessor(allocator, owned.flatBytes()) catch return error.OutOfMemory;
            if (!entry.found_existing) {
                entry.value_ptr.* = .{};
                // The accessors map borrows the `owned` slice as
                // its key; anchor the heap JSString so a GC sweep
                // can't dangle a computed accessor key.
                obj.key_anchors.append(allocator, owned) catch return error.OutOfMemory;
            }
            if (is_setter) {
                realm.heap.setAccessorSetter(.{ .object = obj }, entry.value_ptr, fn_obj);
            } else {
                realm.heap.setAccessorGetter(.{ .object = obj }, entry.value_ptr, fn_obj);
            }
            _ = obj.recordKey(allocator, owned.flatBytes()) catch return error.OutOfMemory;
            continue :dispatch try decodeNext(code, &ip, &committed);
        },

        .set_home => {
            // §10.2.5 set [[HomeObject]] for an object-literal
            // method. acc holds the freshly-built JSFunction;
            // `r_obj` holds the enclosing object. `super` lookup
            // walks `home_object.[[Prototype]]` so this is what
            // makes `super.x()` from inside `{ method(){} }`
            // resolve against `Object.getPrototypeOf(obj)`.
            //
            // §15.4.4 / §15.5 — MethodDefinitions (concise
            // methods, getters, setters, generators, async
            // methods) have no [[Construct]] slot. `new obj.m()`
            // must throw TypeError. Stamp `has_construct = false`
            // here so the `new_call` opcode rejects them.
            const r_obj = code[ip];
            ip += 1;
            if (heap_mod.valueAsFunction(acc)) |fn_obj| {
                if (heap_mod.valueAsPlainObject(registers[r_obj])) |home| {
                    realm.heap.setHomeObject(fn_obj, home);
                }
                fn_obj.has_construct = false;
                // §15.4.4 / §15.5.6 step 2 — MethodDefinitions
                // (concise methods, getters, setters, generators,
                // async methods) are non-constructors and do
                // NOT install a `prototype` data property. The
                // generic `allocateFunction` path auto-creates
                // one for every non-arrow function; drop it here
                // so `hasOwnProperty.call(method, 'prototype')`
                // returns false. Generator and async-generator
                // method shapes get their `prototype` re-installed
                // by the dedicated paths above before this fires
                // — that branch handles them.
                if (!fn_obj.is_generator and !fn_obj.is_async) {
                    realm.heap.setFunctionPrototype(fn_obj, null);
                }
            }
            continue :dispatch try decodeNext(code, &ip, &committed);
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
                realm.heap.setObjectPrototype(obj, null);
                realm.proto_revision_counter +%= 1;
            } else if (heap_mod.valueAsPlainObject(acc)) |p| {
                realm.heap.setObjectPrototype(obj, p);
                realm.proto_revision_counter +%= 1;
            }
            // else: no-op; do not throw.
            continue :dispatch try decodeNext(code, &ip, &committed);
        },

        .set_fn_name_from => {
            // §15.5.6.4 SetFunctionName for computed property
            // keys. Only applies to anonymous function-likes
            // (functions / classes whose .name is currently
            // empty); a named expression keeps its name.
            const r_key = code[ip];
            const prefix_kind = code[ip + 1];
            ip += 2;
            const fn_obj = heap_mod.valueAsFunction(acc) orelse continue :dispatch try decodeNext(code, &ip, &committed);
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
                if (cs.flatBytes().len != 0 and prefix_kind == 0) continue :dispatch try decodeNext(code, &ip, &committed);
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
                realm.heap.storeFunctionProperty(fn_obj, realm.allocator, "name", Value.fromString(owned)) catch return error.OutOfMemory;
                continue :dispatch try decodeNext(code, &ip, &committed);
            }
            var key_buf: [64]u8 = undefined;
            const key_slice = computedKeyToString(key_v, &key_buf);
            const final = std.fmt.allocPrint(realm.allocator, "{s}{s}", .{ prefix, key_slice }) catch return error.OutOfMemory;
            defer realm.allocator.free(final);
            const owned = realm.heap.allocateString(final) catch return error.OutOfMemory;
            realm.heap.storeFunctionProperty(fn_obj, realm.allocator, "name", Value.fromString(owned)) catch return error.OutOfMemory;
            continue :dispatch try decodeNext(code, &ip, &committed);
        },

        .sta_private => {
            const k = readU16(code, ip);
            const r_obj = code[ip + 2];
            ip += 3;
            if (k >= local_chunk.constants.len) return error.InvalidOpcode;
            const key_v = local_chunk.constants[k];
            if (!key_v.isString()) return error.InvalidOpcode;
            const key_s: *JSString = @ptrCast(@alignCast(key_v.asString()));
            // §15.7.14 step 31 — translate the compile-time
            // mangled key into the per-evaluation runtime key
            // (see `translatePrivateKey`). Without this, a
            // write through `obj.#x` would fall back to the
            // shared compile-time prefix and let two unrelated
            // ClassTail evaluations share storage.
            var brand_buf: [128]u8 = undefined;
            // §15.7.14 step 11 — pass the receiver (in r_obj),
            // NOT `acc` (which holds the value being stored).
            // The brand walk needs the target object's chain.
            const lookup_key = translatePrivateKey(&brand_buf, key_s.flatBytes(), framePrivateBrand(f, registers[r_obj], key_s.flatBytes()));
            // §15.7 static private — receiver is the class
            // constructor function. Mirror the JSObject path
            // (accessor wins, then data, then brand-check
            // failure).
            if (heap_mod.valueAsFunction(registers[r_obj])) |fn_recv| {
                if (fn_recv.private_accessors.get(lookup_key)) |pa| {
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
                                continue :dispatch try reEnterDispatch(frames, &f, &local_chunk, &code, &registers, &ip, &acc, &committed);
                            },
                        }
                    } else {
                        const ex = try makeTypeError(f.running_realm orelse realm, "Cannot write to private accessor with no setter");
                        f.ip = ip;
                        f.accumulator = acc;
                        committed = true;
                        if (!try unwindThrow(allocator, realm, frames, ex)) {
                            return .{ .thrown = ex };
                        }
                        continue :dispatch try reEnterDispatch(frames, &f, &local_chunk, &code, &registers, &ip, &acc, &committed);
                    }
                } else if (!fn_recv.private_properties.contains(lookup_key)) {
                    const ex = try makeTypeError(f.running_realm orelse realm, "Cannot write private field — brand check failed");
                    f.ip = ip;
                    f.accumulator = acc;
                    committed = true;
                    if (!try unwindThrow(allocator, realm, frames, ex)) {
                        return .{ .thrown = ex };
                    }
                    continue :dispatch try reEnterDispatch(frames, &f, &local_chunk, &code, &registers, &ip, &acc, &committed);
                } else if (fn_recv.private_methods.contains(lookup_key)) {
                    // §7.3.30 PrivateSet step 4 — methods aren't writable.
                    const ex = try makeTypeError(realm, "Cannot assign to private method");
                    f.ip = ip;
                    f.accumulator = acc;
                    committed = true;
                    if (!try unwindThrow(allocator, realm, frames, ex)) {
                        return .{ .thrown = ex };
                    }
                    continue :dispatch try reEnterDispatch(frames, &f, &local_chunk, &code, &registers, &ip, &acc, &committed);
                } else {
                    // Use the existing key slice in the map
                    // (it's the per-evaluation brand-prefixed
                    // string in `class_arena`); putByKey would
                    // reuse the stored slot. `put` with our
                    // stack-buffered `lookup_key` would store
                    // a dangling pointer past this stack frame
                    // — use `getPtr` to mutate in place.
                    const slot = fn_recv.private_properties.getPtr(lookup_key) orelse return error.InvalidOpcode;
                    realm.heap.storeInternalSlot(.{ .function = fn_recv }, acc);
                    slot.* = acc;
                }
                continue :dispatch try decodeNext(code, &ip, &committed);
            }
            const recv = heap_mod.valueAsPlainObject(registers[r_obj]) orelse {
                const ex = try makeTypeError(f.running_realm orelse realm, "Cannot write private field on non-object");
                f.ip = ip;
                f.accumulator = acc;
                committed = true;
                if (!try unwindThrow(allocator, realm, frames, ex)) {
                    return .{ .thrown = ex };
                }
                continue :dispatch try reEnterDispatch(frames, &f, &local_chunk, &code, &registers, &ip, &acc, &committed);
            };
            // §15.7 — private accessor descriptors win over
            // data slots on write. A write to a read-only
            // accessor (`get #x` without `set #x`) throws
            // TypeError per §10.1.9.1 step 6.b.
            if (recv.getPrivateAccessor(lookup_key)) |pa| {
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
                            continue :dispatch try reEnterDispatch(frames, &f, &local_chunk, &code, &registers, &ip, &acc, &committed);
                        },
                    }
                } else {
                    const ex = try makeTypeError(f.running_realm orelse realm, "Cannot write to private accessor with no setter");
                    f.ip = ip;
                    f.accumulator = acc;
                    committed = true;
                    if (!try unwindThrow(allocator, realm, frames, ex)) {
                        return .{ .thrown = ex };
                    }
                    continue :dispatch try reEnterDispatch(frames, &f, &local_chunk, &code, &registers, &ip, &acc, &committed);
                }
            } else if (!recv.hasPrivateProperty(lookup_key)) {
                const ex = try makeTypeError(f.running_realm orelse realm, "Cannot write private field — brand check failed");
                f.ip = ip;
                f.accumulator = acc;
                committed = true;
                if (!try unwindThrow(allocator, realm, frames, ex)) {
                    return .{ .thrown = ex };
                }
                continue :dispatch try reEnterDispatch(frames, &f, &local_chunk, &code, &registers, &ip, &acc, &committed);
            } else if (recv.hasPrivateMethod(lookup_key)) {
                // §7.3.30 PrivateSet step 4 — methods aren't writable.
                const ex = try makeTypeError(realm, "Cannot assign to private method");
                f.ip = ip;
                f.accumulator = acc;
                committed = true;
                if (!try unwindThrow(allocator, realm, frames, ex)) {
                    return .{ .thrown = ex };
                }
                continue :dispatch try reEnterDispatch(frames, &f, &local_chunk, &code, &registers, &ip, &acc, &committed);
            } else {
                // The key is guaranteed present (the hasPrivateProperty
                // check just above); `put` overwrites the existing
                // slot rather than re-inserting the lookup_key buffer.
                realm.heap.storeInternalSlot(.{ .object = recv }, acc);
                recv.putPrivateProperty(allocator, lookup_key, acc) catch return error.OutOfMemory;
            }
            continue :dispatch try decodeNext(code, &ip, &committed);
        },

        .super_call, .super_call_forward, .super_call_spread => |which| {
            var args: []const Value = &.{};
            var spread_args: std.ArrayListUnmanaged(Value) = .empty;
            defer spread_args.deinit(allocator);
            if (which == .super_call) {
                const r_args = code[ip];
                const argc = code[ip + 1];
                ip += 2;
                args = registers[r_args .. @as(usize, r_args) + argc];
            } else if (which == .super_call_spread) {
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
            // §13.3.7.1 SuperCall — the double-call gate is at
            // step 8 (BindThisValue), which fires AFTER args are
            // evaluated and AFTER `Construct(parent, args, NT)`
            // runs. So the parent constructor IS invoked even on
            // a re-entrant super(...), and side effects in arg
            // expressions / the parent body are observable —
            // see test262 `definition/this-check-ordering.js`.
            // The flag is checked post-call below; here we just
            // remember the pre-call state so the BindThisValue
            // gate can fire correctly.
            //
            // For `super(...)` invoked from an arrow body, the
            // current frame is the arrow's — `is_derived_ctor`
            // is false and `super_called` is the arrow's own
            // local zero. The lexically-enclosing derived ctor
            // shares its `super_called_cell` with us, so read
            // that cell as the authoritative "has super already
            // been called" signal. Otherwise the second
            // `() => super()` invocation wouldn't trip the
            // BindThisValue ReferenceError and the field
            // initializers would re-run (test262
            // language/expressions/class/elements/
            // fields-run-once-on-double-super.js).
            const enclosing_super_called: bool = blk: {
                if (f.super_called_cell) |cell| break :blk cell.*;
                break :blk f.super_called;
            };
            const second_super_call = enclosing_super_called;
            // §13.3.7.2 GetSuperConstructor — the *active*
            // function's [[Prototype]], not its home-object's
            // prototype's `constructor` slot. `Object.setPrototypeOf(C,
            // X)` retargets `super(...)` to X without touching
            // `C.prototype`; the home-object walk would miss that.
            //
            // Cynic stores the parent-class edge on
            // `home_function.static_parent` (function-typed)
            // because the `proto` slot is JSObject-typed.
            // `Object.setPrototypeOf` writes to BOTH slots when
            // the value is a callable, so `static_parent`
            // tracks `[[Prototype]]` for active-function-walk
            // purposes.
            const home_fn = f.home_function orelse {
                const ex = try makeTypeError(realm, "super used outside a constructor");
                f.ip = ip;
                f.accumulator = acc;
                committed = true;
                if (!try unwindThrow(allocator, realm, frames, ex)) {
                    return .{ .thrown = ex };
                }
                continue :dispatch try reEnterDispatch(frames, &f, &local_chunk, &code, &registers, &ip, &acc, &committed);
            };
            const parent_fn = home_fn.static_parent orelse {
                const ex = try makeTypeError(realm, "super(...) requires a constructor in the prototype chain");
                f.ip = ip;
                f.accumulator = acc;
                committed = true;
                if (!try unwindThrow(allocator, realm, frames, ex)) {
                    return .{ .thrown = ex };
                }
                continue :dispatch try reEnterDispatch(frames, &f, &local_chunk, &code, &registers, &ip, &acc, &committed);
            };
            // §13.3.7.1 step 5 — `IsConstructor(func)` is checked
            // *after* ArgumentListEvaluation. The args were just
            // evaluated above; throw TypeError if the lookup
            // chain produced a non-constructor (e.g. `parseInt`,
            // an arrow, a generator, an async fn).
            if (!parent_fn.has_construct or parent_fn.is_arrow or parent_fn.is_generator or parent_fn.is_async) {
                const ex = try makeTypeError(realm, "super(...) requires a constructor in the prototype chain");
                f.ip = ip;
                f.accumulator = acc;
                committed = true;
                if (!try unwindThrow(allocator, realm, frames, ex)) {
                    return .{ .thrown = ex };
                }
                continue :dispatch try reEnterDispatch(frames, &f, &local_chunk, &code, &registers, &ip, &acc, &committed);
            }
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
                .value, .yielded => |v| {
                    // §10.2.1.4 BindThisValue step 3 — if the
                    // function env-record's [[ThisBindingStatus]]
                    // is already "initialized", BindThisValue
                    // throws ReferenceError. The throw must fire
                    // AFTER the call so the parent's side effects
                    // (and the ArgumentListEvaluation side effects
                    // above) are observable per
                    // test262 `this-check-ordering.js`.
                    if (second_super_call) {
                        const ex = try makeReferenceError(realm, "Super constructor may only be called once");
                        f.ip = ip;
                        f.accumulator = acc;
                        committed = true;
                        if (!try unwindThrow(allocator, realm, frames, ex)) {
                            return .{ .thrown = ex };
                        }
                        continue :dispatch try reEnterDispatch(frames, &f, &local_chunk, &code, &registers, &ip, &acc, &committed);
                    }
                    // §10.2.1.3 [[Construct]] step 10 — if the
                    // parent ctor body returned an Object, that
                    // becomes the Construct result; otherwise the
                    // pre-allocated `thisArgument` survives. We
                    // call the parent with `is_construct = false`
                    // (see `callJSFunctionAsSuper`) so the parent
                    // hands back its raw body value — apply
                    // ConstructResult here, then BindThisValue
                    // (§13.3.7.1 step 8) on the derived frame.
                    const construct_result: Value = blk: {
                        if (heap_mod.valueAsPlainObject(v) != null or
                            heap_mod.valueAsFunction(v) != null)
                        {
                            break :blk v;
                        }
                        break :blk f.this_value;
                    };
                    f.this_value = construct_result;
                    acc = construct_result;
                },
                .thrown => |ex| {
                    f.ip = ip;
                    f.accumulator = acc;
                    committed = true;
                    if (!try unwindThrow(allocator, realm, frames, ex)) {
                        return .{ .thrown = ex };
                    }
                    continue :dispatch try reEnterDispatch(frames, &f, &local_chunk, &code, &registers, &ip, &acc, &committed);
                },
            }
            // §10.2.1.4 — `super(...)` flips `[[ThisBindingStatus]]`
            // from "uninitialized" to "initialized". A subsequent
            // `return undefined` is fine; without this flag, falling
            // off the end throws ReferenceError.
            f.super_called = true;
            // §15.3 / §13.3.7 — `super(...)` from inside an arrow
            // body resolves against the lexically enclosing
            // derived constructor, and flips THAT frame's
            // `[[ThisBindingStatus]]`. Two propagation paths:
            //   1. The outer ctor frame is still on this
            //      `frames` stack (the common case — arrow
            //      called synchronously from inside the ctor
            //      body). Walk back to find it and flip
            //      directly.
            //   2. The arrow is invoked from a fresh
            //      `runFrames` re-entry (e.g. iterator
            //      `return()` during a for-of close, an
            //      async callback). The outer ctor isn't on
            //      this stack — but it shares a heap cell
            //      with us via `super_called_cell`, populated
            //      at `make_function` time. Flip the cell.
            // The cell-write covers both cases; the frame
            // walk is a small redundancy that keeps semantics
            // working for any future code that reads
            // `super_called` directly off a still-live frame.
            if (f.super_called_cell) |cell| cell.* = true;
            if (frames.items.len >= 2) {
                var idx: usize = frames.items.len - 1;
                while (idx > 0) {
                    idx -= 1;
                    const outer = &frames.items[idx];
                    if (outer.is_derived_ctor) {
                        outer.super_called = true;
                        break;
                    }
                }
            }
            continue :dispatch try decodeNext(code, &ip, &committed);
        },

        // ── Globals ─────────────────────────────────────────────────
        .lda_global => {
            const k = readU16(code, ip);
            const ic_idx = readU16(code, ip + 2);
            ip += 4;
            // §8.3 / §9.1: free globals resolve through the
            // *executing* function's global environment, which is
            // its [[Realm]]'s. With a shared heap (a ShadowRealm
            // child) the running realm differs from the dispatch
            // realm, so route the lookup through the active frame's
            // `running_realm` rather than the top-level `realm`.
            const gr = f.running_realm orelse realm;
            // IC fast path: shape compare on the global object plus
            // a decl-revision snapshot. A hit means no new `let` /
            // `const` / `class` has been declared since fill and
            // the global object hasn't transitioned to a different
            // shape — the cached object-env slot is still
            // authoritative.
            if (gr.globals.target) |gt| {
                const cell = &local_chunk.inline_caches[ic_idx];
                if (cell.shape != null and cell.shape == gt.shape and cell.proto == null and cell.proto_rev == gr.globals.decl_revision) {
                    acc = gt.slotAt(cell.slot);
                    continue :dispatch try decodeNext(code, &ip, &committed);
                }
            }
            if (k >= local_chunk.constants.len) return error.InvalidOpcode;
            const key_v = local_chunk.constants[k];
            if (!key_v.isString()) return error.InvalidOpcode;
            const key_s: *JSString = @ptrCast(@alignCast(key_v.asString()));
            switch (try slowLdaGlobal(allocator, realm, frames, f, ip, gr, key_s.flatBytes(), &local_chunk.inline_caches[ic_idx])) {
                .value => |v| acc = v,
                .handled => {
                    committed = true;
                    continue :dispatch try reEnterDispatch(frames, &f, &local_chunk, &code, &registers, &ip, &acc, &committed);
                },
                .uncaught => |ex| return .{ .thrown = ex },
                .not_found => {
                    const ex = try makeReferenceError(gr, key_s.flatBytes());
                    f.ip = ip;
                    f.accumulator = acc;
                    committed = true;
                    if (!try unwindThrow(allocator, realm, frames, ex)) {
                        return .{ .thrown = ex };
                    }
                    continue :dispatch try reEnterDispatch(frames, &f, &local_chunk, &code, &registers, &ip, &acc, &committed);
                },
            }
            continue :dispatch try decodeNext(code, &ip, &committed);
        },
        .lda_global_or_undef => {
            // §13.5.3 step 3 — typeof of an unresolvable
            // Reference is "undefined", not a thrown
            // ReferenceError. Shares the IC machinery with
            // `lda_global`; only the `.not_found` case differs.
            const k = readU16(code, ip);
            const ic_idx = readU16(code, ip + 2);
            ip += 4;
            const gr = f.running_realm orelse realm;
            if (gr.globals.target) |gt| {
                const cell = &local_chunk.inline_caches[ic_idx];
                if (cell.shape != null and cell.shape == gt.shape and cell.proto == null and cell.proto_rev == gr.globals.decl_revision) {
                    acc = gt.slotAt(cell.slot);
                    continue :dispatch try decodeNext(code, &ip, &committed);
                }
            }
            if (k >= local_chunk.constants.len) return error.InvalidOpcode;
            const key_v = local_chunk.constants[k];
            if (!key_v.isString()) return error.InvalidOpcode;
            const key_s: *JSString = @ptrCast(@alignCast(key_v.asString()));
            switch (try slowLdaGlobal(allocator, realm, frames, f, ip, gr, key_s.flatBytes(), &local_chunk.inline_caches[ic_idx])) {
                .value => |v| acc = v,
                .handled => {
                    committed = true;
                    continue :dispatch try reEnterDispatch(frames, &f, &local_chunk, &code, &registers, &ip, &acc, &committed);
                },
                .uncaught => |ex| return .{ .thrown = ex },
                .not_found => acc = Value.undefined_,
            }
            continue :dispatch try decodeNext(code, &ip, &committed);
        },
        .sta_global_init => {
            // §9.1.1.4 InitializeBinding for a top-level
            // `let` / `const` / `class` — write the
            // initializer's value into the declarative env-
            // record's slot. No const check (this IS the
            // initialization step); the slot was seeded
            // `Hole` at hoist time and the initializer
            // overwrites here.
            const k = readU16(code, ip);
            ip += 2;
            if (k >= local_chunk.constants.len) return error.InvalidOpcode;
            const key_v = local_chunk.constants[k];
            if (!key_v.isString()) return error.InvalidOpcode;
            const key_s: *JSString = @ptrCast(@alignCast(key_v.asString()));
            try realm.globals.putDecl(realm.allocator, key_s.flatBytes(), acc);
            continue :dispatch try decodeNext(code, &ip, &committed);
        },
        .sta_global_fn_decl => {
            // §9.1.1.4.19 CreateGlobalFunctionBinding —
            // function-decl install onto the global object
            // overwrites both data and descriptor flags
            // (writable+enumerable+[[Configurable]]:D). D=false for
            // §16.1.7 script source; D=true (`eval_global_deletable`)
            // for a non-strict indirect `eval` (§19.2.1.3 step 15.c.i).
            const k = readU16(code, ip);
            ip += 2;
            if (k >= local_chunk.constants.len) return error.InvalidOpcode;
            const key_v = local_chunk.constants[k];
            if (!key_v.isString()) return error.InvalidOpcode;
            const key_s: *JSString = @ptrCast(@alignCast(key_v.asString()));
            try realm.globals.installScriptFunctionBinding(realm.allocator, key_s.flatBytes(), acc, local_chunk.eval_global_deletable);
            continue :dispatch try decodeNext(code, &ip, &committed);
        },
        .lda_global_slot => {
            // Slot-indexed load of a top-level `let` / `const`
            // / `class` binding. Runtime index =
            // `chunk.global_lexical_base + slot`; the value is
            // a bounds-checked array index into the §9.1.1.4
            // declarative env-record (`decl_env.values()`) —
            // no name hash. The compiler emits this only when
            // the resolved binding is provably a global
            // lexical; Cynic ships no `eval`, so the complete
            // global-lexical set is known at compile time and
            // no runtime guard is needed. §13.3.1 TDZ: a
            // following `throw_if_hole` (emitted by the
            // compiler) catches the uninitialised slot.
            const slot = readU32(code, ip);
            ip += 4;
            // The slot index is relative to the realm the running
            // chunk was compiled in (its [[Realm]]'s decl_env), which
            // with a shared heap differs from the dispatch realm —
            // route through the active frame's `running_realm`.
            const gr = f.running_realm orelse realm;
            const idx = local_chunk.global_lexical_base + slot;
            const vals = gr.globals.decl_env.values();
            std.debug.assert(idx < vals.len);
            std.debug.assert(gr.globals.decl_consts.count() == gr.globals.decl_env.count());
            acc = vals[idx];
            continue :dispatch try decodeNext(code, &ip, &committed);
        },
        .sta_global_slot_init => {
            // §9.1.1.4 InitializeBinding — slot-indexed
            // initializer store for a top-level `let` /
            // `const` / `class`. Fills the TDZ Hole; no const
            // check (this IS the initialization step).
            const slot = readU32(code, ip);
            ip += 4;
            const gr = f.running_realm orelse realm;
            const idx = local_chunk.global_lexical_base + slot;
            const vals = gr.globals.decl_env.values();
            std.debug.assert(idx < vals.len);
            std.debug.assert(gr.globals.decl_consts.count() == gr.globals.decl_env.count());
            vals[idx] = acc;
            continue :dispatch try decodeNext(code, &ip, &committed);
        },
        .sta_global_slot => {
            // §9.1.1.4 SetMutableBinding — slot-indexed
            // non-init store to a top-level `let` / `const`.
            // §13.3.1: Hole → ReferenceError; §13.15.2:
            // `const` → TypeError; else write.
            const slot = readU32(code, ip);
            ip += 4;
            const gr = f.running_realm orelse realm;
            const idx = local_chunk.global_lexical_base + slot;
            const vals = gr.globals.decl_env.values();
            std.debug.assert(idx < vals.len);
            std.debug.assert(gr.globals.decl_consts.count() == gr.globals.decl_env.count());
            if (vals[idx].isHole()) {
                const ex = try makeReferenceError(gr, "Cannot access binding before initialisation");
                f.ip = ip;
                f.accumulator = acc;
                committed = true;
                if (!try unwindThrow(allocator, realm, frames, ex)) {
                    return .{ .thrown = ex };
                }
                continue :dispatch try reEnterDispatch(frames, &f, &local_chunk, &code, &registers, &ip, &acc, &committed);
            }
            if (gr.globals.decl_consts.values()[idx]) {
                const ex = try makeTypeError(gr, "Assignment to constant variable");
                f.ip = ip;
                f.accumulator = acc;
                committed = true;
                if (!try unwindThrow(allocator, realm, frames, ex)) {
                    return .{ .thrown = ex };
                }
                continue :dispatch try reEnterDispatch(frames, &f, &local_chunk, &code, &registers, &ip, &acc, &committed);
            }
            vals[idx] = acc;
            continue :dispatch try decodeNext(code, &ip, &committed);
        },
        .sta_global => {
            const k = readU16(code, ip);
            ip += 2;
            if (k >= local_chunk.constants.len) return error.InvalidOpcode;
            const key_v = local_chunk.constants[k];
            if (!key_v.isString()) return error.InvalidOpcode;
            const key_s: *JSString = @ptrCast(@alignCast(key_v.asString()));
            const gr = f.running_realm orelse realm;
            // §13.15.2 step 1.f.i — strict-mode assignment to a
            // truly-unresolvable reference throws ReferenceError
            // at PutValue. Top-level `var x` / `let x` / `const x`
            // pre-install their entries at hoist time, so by the
            // time sta_global runs for a known declaration the
            // key is present. Anything missing here is a bare
            // `x = 1` for some `x` that was never declared
            // anywhere — strict mode forbids the implicit global.
            if (!gr.globals.contains(key_s.flatBytes())) {
                const ex = try makeReferenceError(gr, key_s.flatBytes());
                f.ip = ip;
                f.accumulator = acc;
                committed = true;
                if (!try unwindThrow(allocator, realm, frames, ex)) {
                    return .{ .thrown = ex };
                }
                continue :dispatch try reEnterDispatch(frames, &f, &local_chunk, &code, &registers, &ip, &acc, &committed);
            }
            // §9.1.1.4 SetMutableBinding — declarative env-
            // record first. `sta_global` is the non-init store:
            // the compiler picks `sta_global_init` for every
            // declarator path (including destructuring
            // declarators after `is_init` was threaded through
            // `compileDestructure`). Reaching here for a lex
            // binding means a §13.15.5 destructuring-assignment
            // leaf, an assignment expression, or a for-of LHS
            // against an outer-scope binding — all of which are
            // PutValue (§6.2.5.5) and must surface the §13.3.1
            // TDZ ReferenceError when the slot still holds the
            // Hole sentinel.
            if (gr.globals.hasLexicalDeclaration(key_s.flatBytes())) {
                const cur = gr.globals.getDecl(key_s.flatBytes()) orelse Value.hole_;
                if (cur.isHole()) {
                    const ex = try makeReferenceError(gr, "Cannot access binding before initialisation");
                    f.ip = ip;
                    f.accumulator = acc;
                    committed = true;
                    if (!try unwindThrow(allocator, realm, frames, ex)) {
                        return .{ .thrown = ex };
                    }
                    continue :dispatch try reEnterDispatch(frames, &f, &local_chunk, &code, &registers, &ip, &acc, &committed);
                }
                if (gr.globals.isLexConst(key_s.flatBytes())) {
                    const ex = try makeTypeError(gr, "Assignment to constant variable");
                    f.ip = ip;
                    f.accumulator = acc;
                    committed = true;
                    if (!try unwindThrow(allocator, realm, frames, ex)) {
                        return .{ .thrown = ex };
                    }
                    continue :dispatch try reEnterDispatch(frames, &f, &local_chunk, &code, &registers, &ip, &acc, &committed);
                }
                try gr.globals.putDecl(realm.allocator, key_s.flatBytes(), acc);
            } else {
                // §10.1.9.1 OrdinarySet step 3 — a write to a
                // non-writable own data property of the global
                // object is a §6.2.5.5 PutValue failure: under
                // strict mode (Cynic's only mode) it throws
                // TypeError. Covers the §19.1 frozen globals
                // (`undefined = 1`, `NaN = 1`, `Infinity = 1`)
                // and any host-installed read-only data slot.
                if (gr.globals.target) |gt| {
                    // Shape-first: a frozen-in-shape global carries
                    // its locked attrs in the shape entry, not in
                    // `property_flags` (empty in shape mode) —
                    // `flagsFor` consults both representations.
                    if (gt.ownDataContains(key_s.flatBytes())) {
                        const flags = gt.flagsFor(key_s.flatBytes());
                        if (!flags.writable) {
                            const ex = try makeTypeError(gr, "Cannot assign to read-only property on globalThis");
                            f.ip = ip;
                            f.accumulator = acc;
                            committed = true;
                            if (!try unwindThrow(allocator, realm, frames, ex)) {
                                return .{ .thrown = ex };
                            }
                            continue :dispatch try reEnterDispatch(frames, &f, &local_chunk, &code, &registers, &ip, &acc, &committed);
                        }
                    }
                }
                try gr.globals.put(realm.allocator, key_s.flatBytes(), acc);
                // Generational write barrier — a top-level `var`
                // store can land a young value into the (mature)
                // global object; record the old→young edge.
                if (gr.globals.target) |gt| realm.heap.writeBarrier(.{ .object = gt }, acc);
            }
            continue :dispatch try decodeNext(code, &ip, &committed);
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
            // Resolvability is judged against the executing function's
            // home realm (same routing as `lda_global` / `sta_global`),
            // not the dispatch realm — a free global assigned by a
            // cross-realm-called function resolves in its own realm.
            const gr = f.running_realm orelse realm;
            registers[r] = if (gr.globals.contains(key_s.flatBytes()))
                Value.fromBool(false)
            else
                Value.fromBool(true);
            continue :dispatch try decodeNext(code, &ip, &committed);
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
            const gr = f.running_realm orelse realm;
            const flag = registers[r];
            const was_unresolved = flag.isBool() and flag.asBool();
            if (was_unresolved) {
                const ex = try makeReferenceError(gr, key_s.flatBytes());
                f.ip = ip;
                f.accumulator = acc;
                committed = true;
                if (!try unwindThrow(allocator, realm, frames, ex)) {
                    return .{ .thrown = ex };
                }
                continue :dispatch try reEnterDispatch(frames, &f, &local_chunk, &code, &registers, &ip, &acc, &committed);
            }
            // Same declarative-vs-object env-record dispatch
            // as `sta_global`. The unresolved-Reference check
            // above already gated on `contains()` (which spans
            // both records); a name that was lex-declared
            // after the capture but before the store still
            // routes correctly to the declarative record here.
            if (gr.globals.hasLexicalDeclaration(key_s.flatBytes())) {
                // §13.3.1 — `sta_global_strict` is reached only
                // from assignment-expression code paths (never
                // a declarator init), so a Hole-valued slot
                // here is a §13.3.1 TDZ ReferenceError, not a
                // first-init. Mirrors the matching check in
                // `sta_global` above.
                const cur = gr.globals.getDecl(key_s.flatBytes()) orelse Value.hole_;
                if (cur.isHole()) {
                    const ex = try makeReferenceError(gr, "Cannot access binding before initialisation");
                    f.ip = ip;
                    f.accumulator = acc;
                    committed = true;
                    if (!try unwindThrow(allocator, realm, frames, ex)) {
                        return .{ .thrown = ex };
                    }
                    continue :dispatch try reEnterDispatch(frames, &f, &local_chunk, &code, &registers, &ip, &acc, &committed);
                }
                if (gr.globals.isLexConst(key_s.flatBytes())) {
                    const ex = try makeTypeError(gr, "Assignment to constant variable");
                    f.ip = ip;
                    f.accumulator = acc;
                    committed = true;
                    if (!try unwindThrow(allocator, realm, frames, ex)) {
                        return .{ .thrown = ex };
                    }
                    continue :dispatch try reEnterDispatch(frames, &f, &local_chunk, &code, &registers, &ip, &acc, &committed);
                }
                try gr.globals.putDecl(realm.allocator, key_s.flatBytes(), acc);
            } else {
                // §10.1.9.1 OrdinarySet step 3 — same writable
                // gate as `sta_global`. `sta_global_strict` is
                // the assignment-expression path; under strict
                // mode (Cynic's only mode) a non-writable own
                // data property of the global object refuses
                // the write with TypeError.
                if (gr.globals.target) |gt| {
                    // Shape-first: a frozen-in-shape global carries
                    // its locked attrs in the shape entry, not in
                    // `property_flags` (empty in shape mode) —
                    // `flagsFor` consults both representations.
                    if (gt.ownDataContains(key_s.flatBytes())) {
                        const flags = gt.flagsFor(key_s.flatBytes());
                        if (!flags.writable) {
                            const ex = try makeTypeError(gr, "Cannot assign to read-only property on globalThis");
                            f.ip = ip;
                            f.accumulator = acc;
                            committed = true;
                            if (!try unwindThrow(allocator, realm, frames, ex)) {
                                return .{ .thrown = ex };
                            }
                            continue :dispatch try reEnterDispatch(frames, &f, &local_chunk, &code, &registers, &ip, &acc, &committed);
                        }
                    }
                }
                try gr.globals.put(realm.allocator, key_s.flatBytes(), acc);
                // Generational write barrier — a top-level `var`
                // store can land a young value into the (mature)
                // global object; record the old→young edge.
                if (gr.globals.target) |gt| realm.heap.writeBarrier(.{ .object = gt }, acc);
            }
            continue :dispatch try decodeNext(code, &ip, &committed);
        },

        // ── Objects / properties ────────────────────────────────────
        .make_object => {
            const obj = realm.heap.allocateObject() catch return error.OutOfMemory;
            realm.heap.setObjectPrototype(obj, realm.intrinsics.object_prototype);
            acc = heap_mod.taggedObject(obj);
            continue :dispatch try decodeNext(code, &ip, &committed);
        },
        .make_object_shape => {
            // Literal-shape boilerplate. The compiler captured
            // the literal's static key list in
            // `Chunk.literal_shape_templates[k]`; first hit
            // builds the shape by walking
            // `ShapeTree.transition` from the root, caches it
            // on the template, and pre-sizes `slots`. Hits on
            // a populated cache stamp the shape directly.
            const k = readU16(code, ip);
            ip += 2;
            if (k >= local_chunk.literal_shape_templates.len) return error.InvalidOpcode;
            const tmpl = &local_chunk.literal_shape_templates[k];
            const shape = blk: {
                if (tmpl.cached_shape) |s| break :blk s;
                // Cold cache — build the shape.
                var cur = realm.heap.shapes.root;
                for (tmpl.keys) |key_idx| {
                    if (key_idx >= local_chunk.constants.len) return error.InvalidOpcode;
                    const key_v = local_chunk.constants[key_idx];
                    if (!key_v.isString()) return error.InvalidOpcode;
                    const key_s: *JSString = @ptrCast(@alignCast(key_v.asString()));
                    cur = realm.heap.shapes.transition(
                        cur,
                        key_s.flatBytes(),
                        @import("../object.zig").PropertyFlags.default,
                        .data,
                    ) catch return error.OutOfMemory;
                }
                @constCast(tmpl).cached_shape = cur;
                break :blk cur;
            };
            const obj = realm.heap.allocateObject() catch return error.OutOfMemory;
            realm.heap.setObjectPrototype(obj, realm.intrinsics.object_prototype);
            obj.shape = shape;
            obj.resizeSlots(allocator, shape.property_count) catch return error.OutOfMemory;
            // `ArrayList.resize` doesn't zero-fill. Initialise
            // every slot to `undefined` so a GC trigger between
            // `make_object_shape` and the downstream property
            // writes finds a valid Value (the slot won't have its
            // real entry yet — that's the `def_template_property` /
            // `def_property` job).
            {
                var us_i: usize = 0;
                while (us_i < obj.slotCount()) : (us_i += 1) obj.slotPtr(us_i).* = Value.undefined_;
            }
            // Pre-fill `own_key_order` from the template's keys.
            // The downstream `def_template_property` op skips
            // `recordKey` entirely, so this is the one chance to
            // populate the §10.1.11 OrdinaryOwnPropertyKeys order
            // list. Chunk constants are pinned for the chunk's
            // lifetime, so the borrowed slices outlive any
            // reachable instance.
            obj.own_key_order.ensureTotalCapacityPrecise(allocator, tmpl.keys.len) catch return error.OutOfMemory;
            for (tmpl.keys) |key_idx| {
                const key_v = local_chunk.constants[key_idx];
                const key_s: *JSString = @ptrCast(@alignCast(key_v.asString()));
                obj.own_key_order.appendAssumeCapacity(key_s.flatBytes());
            }
            acc = heap_mod.taggedObject(obj);
            continue :dispatch try decodeNext(code, &ip, &committed);
        },
        .make_array => {
            const obj = realm.heap.allocateObject() catch return error.OutOfMemory;
            realm.heap.setObjectPrototype(obj, realm.intrinsics.array_prototype);
            // `markAsArrayExotic` installs the §23.1.4 `length` slot
            // (non-enumerable, non-configurable) — no separate write
            // needed. It deliberately avoids bumping the proto-struct
            // epoch so a constructor's transition write IC survives an
            // array literal built in the same hot loop.
            obj.markAsArrayExotic(allocator) catch return error.OutOfMemory;
            acc = heap_mod.taggedObject(obj);
            continue :dispatch try decodeNext(code, &ip, &committed);
        },
        .make_array_n => {
            // §13.2.4.1 fused dense literal — the compiler staged the
            // n element values left-to-right in consecutive registers
            // (GC-rooted frame slots, so the allocation below can
            // collect safely), and the array is unreachable until
            // this arm returns it. One exact-capacity reserve, one
            // bulk copy, no per-element canonical-index parse, and no
            // write barriers: the array is young by construction, so
            // no old→young edge can form (the barrier's generation
            // reject, taken statically).
            const r_base = code[ip];
            ip += 1;
            const n = code[ip];
            ip += 1;
            // Construction shared with Bistromath via
            // `Heap.makeDenseArray` so both tiers build a
            // byte-identical object — same exotic shape, pooled
            // element buffer (NO general-purpose alloc for a
            // literal that fits the slab class), and virtual length.
            // The n element values sit in consecutive GC-rooted
            // frame registers, so the allocation inside can collect
            // safely.
            const obj = realm.heap.makeDenseArray(realm.intrinsics.array_prototype, registers[r_base .. @as(usize, r_base) + n]) catch return error.OutOfMemory;
            acc = heap_mod.taggedObject(obj);
            continue :dispatch try decodeNext(code, &ip, &committed);
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
                continue :dispatch try reEnterDispatch(frames, &f, &local_chunk, &code, &registers, &ip, &acc, &committed);
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
                    continue :dispatch try reEnterDispatch(frames, &f, &local_chunk, &code, &registers, &ip, &acc, &committed);
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
                continue :dispatch try reEnterDispatch(frames, &f, &local_chunk, &code, &registers, &ip, &acc, &committed);
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
                    realm.heap.storeElement(target, allocator, @intCast(target_len), elem) catch return error.OutOfMemory;
                } else {
                    var db: [24]u8 = undefined;
                    const ds = std.fmt.bufPrint(&db, "{d}", .{target_len}) catch unreachable;
                    const owned = realm.heap.allocateString(ds) catch return error.OutOfMemory;
                    realm.heap.storeProperty(target, allocator, owned.flatBytes(), elem) catch return error.OutOfMemory;
                }
                target_len += 1;
            }
            if (committed) continue :dispatch try reEnterDispatch(frames, &f, &local_chunk, &code, &registers, &ip, &acc, &committed);
            if (iter_count >= max_iter) {
                const ex = try makeRangeError(realm, "spread source too large");
                f.ip = ip;
                f.accumulator = acc;
                committed = true;
                if (!try unwindThrow(allocator, realm, frames, ex)) {
                    return .{ .thrown = ex };
                }
                continue :dispatch try reEnterDispatch(frames, &f, &local_chunk, &code, &registers, &ip, &acc, &committed);
            }

            // §10.4.2.4 — `target` is array-exotic by the
            // time spread runs (every site that allocates an
            // array-shaped JSObject calls `markAsArrayExotic`).
            // The indexed writes above already extended the virtual
            // length (it tracks the indexed storage); this final
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
            continue :dispatch try decodeNext(code, &ip, &committed);
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
            if (acc.isNull() or acc.isUndefined()) continue :dispatch try decodeNext(code, &ip, &committed);
            const target = heap_mod.valueAsPlainObject(registers[r_obj]) orelse return error.InvalidOpcode;
            const src_v = acc;
            const src_obj = heap_mod.valueAsPlainObject(src_v) orelse {
                // Primitives box transparently. For now treat
                // strings / numbers / booleans as having no
                // own enumerable string keys (numeric index
                // expansion for strings is rare in real code
                // and trips object-rest tests; revisit later).
                continue :dispatch try decodeNext(code, &ip, &committed);
            };
            const obj_mod = @import("../builtins/object.zig");
            // §7.3.27 CopyDataProperties step 4 — fire the
            // Proxy `ownKeys` trap when `src` is a proxy
            // exotic, then iterate the trap result. When
            // `src` isn't a proxy this is just the ordinary
            // own-key walk.
            const is_src_proxy = src_obj.proxy_target != null or src_obj.proxy_revoked;
            const key_scope = realm.heap.openScope() catch return error.OutOfMemory;
            defer key_scope.close();
            const keys_opt: ?[]const []const u8 = blk_pk: {
                const ko = obj_mod.proxyOwnKeysOrNull(realm, src_obj, key_scope) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    else => {
                        const ex = consumePendingException(realm) orelse try makeTypeError(realm, "object spread ownKeys trap threw");
                        f.ip = ip;
                        f.accumulator = acc;
                        committed = true;
                        if (!try unwindThrow(allocator, realm, frames, ex)) {
                            return .{ .thrown = ex };
                        }
                        break :blk_pk null;
                    },
                };
                break :blk_pk ko;
            };
            if (committed) continue :dispatch try reEnterDispatch(frames, &f, &local_chunk, &code, &registers, &ip, &acc, &committed);
            const keys: []const []const u8 = if (keys_opt) |k| k else (obj_mod.ownPropertyKeysOrdered(realm, src_obj, key_scope) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return error.InvalidOpcode,
            });
            defer realm.allocator.free(keys);
            for (keys) |key| {
                if (std.mem.startsWith(u8, key, "__cynic_")) continue;
                var prop_value: Value = undefined;
                if (is_src_proxy) {
                    // §7.3.27 step 4.c.i — `desc = ? from.[[GetOwnProperty]](key)`.
                    // The Proxy `getOwnPropertyDescriptor` trap must
                    // fire even when we'll discard the result; that's
                    // what fixtures like
                    // `object-spread-proxy-no-excluded-keys.js` assert.
                    const key_str = realm.heap.allocateString(key) catch return error.OutOfMemory;
                    const desc_args = [_]Value{ src_v, Value.fromString(key_str) };
                    const desc_v = obj_mod.objectGetOwnPropertyDescriptor(realm, Value.undefined_, &desc_args) catch |err| switch (err) {
                        error.OutOfMemory => return error.OutOfMemory,
                        else => {
                            const ex = consumePendingException(realm) orelse try makeTypeError(realm, "object spread descriptor trap threw");
                            f.ip = ip;
                            f.accumulator = acc;
                            committed = true;
                            if (!try unwindThrow(allocator, realm, frames, ex)) {
                                return .{ .thrown = ex };
                            }
                            break;
                        },
                    };
                    if (desc_v.isUndefined()) continue;
                    const desc_obj = heap_mod.valueAsPlainObject(desc_v) orelse continue;
                    if (!intrinsics_mod.toBoolean(desc_obj.get("enumerable"))) continue;
                    // §7.3.27 step 4.c.iii — `Get(from, key)`.
                    // Route through `nativeProxyGet` so the
                    // Proxy `get` trap fires with the proxy as
                    // receiver. `getPropertyChain` walks the
                    // ordinary property bag + prototype chain
                    // and would silently miss the trap.
                    const proxy_mod = @import("../builtins/proxy.zig");
                    const outcome = proxy_mod.nativeProxyGet(realm, src_obj, key, src_v, null) catch |err| switch (err) {
                        error.OutOfMemory => return error.OutOfMemory,
                        else => {
                            const ex = consumePendingException(realm) orelse try makeTypeError(realm, "object spread get failed");
                            f.ip = ip;
                            f.accumulator = acc;
                            committed = true;
                            if (!try unwindThrow(allocator, realm, frames, ex)) {
                                return .{ .thrown = ex };
                            }
                            break;
                        },
                    };
                    switch (outcome) {
                        .value => |v| prop_value = v,
                        .fallthrough => |t| prop_value = t.get(key),
                    }
                } else {
                    if (!src_obj.flagsFor(key).enumerable) continue;
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
                }
                // §7.3.27 step 4.c.iv — `CreateDataPropertyOrThrow`.
                // Allocate a fresh JSString and route through the
                // anchored store; see the matching note on
                // `.object_rest_from`. Without this the integer-index
                // keys synthesised for a TypedArray source dangle on
                // `target.properties` after `key_scope.close()` and a
                // later `Object.getOwnPropertyNames(target)` poisons
                // `orderListContains`.
                key_scope.push(prop_value) catch return error.OutOfMemory;
                const key_anchor = realm.heap.allocateString(key) catch return error.OutOfMemory;
                realm.heap.storePropertyComputedOwned(target, allocator, key_anchor, prop_value) catch return error.OutOfMemory;
            }
            if (committed) continue :dispatch try reEnterDispatch(frames, &f, &local_chunk, &code, &registers, &ip, &acc, &committed);
            continue :dispatch try decodeNext(code, &ip, &committed);
        },

        .lda_property => {
            const k = readU16(code, ip);
            const ic_idx = readU16(code, ip + 2);
            ip += 4;
            if (k >= local_chunk.constants.len) return error.InvalidOpcode;
            const key_v = local_chunk.constants[k];
            if (!key_v.isString()) return error.InvalidOpcode;
            const key_s: *JSString = @ptrCast(@alignCast(key_v.asString()));
            if (heap_mod.valueAsPlainObject(acc)) |obj_in| {
                // Monomorphic inline cache. Two hit modes:
                //   • Own-data hit — `proto == null`. Pointer
                //     compare on the receiver's shape; serve
                //     from `recv.slots[slot]`.
                //   • Prototype-load hit — `proto != null`. The
                //     property was resolved through the chain at
                //     fill time. Re-validate by comparing the
                //     receiver's shape, the proto pointer's own
                //     shape (catches data→accessor / delete /
                //     shape mutation on the proto), AND the
                //     realm's `proto_revision_counter` (catches a
                //     `setPrototypeOf` / `__proto__` swap on
                //     ANY object since fill time).
                //
                // shadowSet demotes any exotic (proxy, namespace,
                // typed view, array, engine-internal key) before
                // stamping a shape, so a shaped receiver is a
                // plain ordinary object — the proxy / namespace
                // checks below are still required for shapeless
                // receivers and are reached on a cache miss.
                const cell = &local_chunk.inline_caches[ic_idx];
                if (cell.shape != null and cell.shape == obj_in.shape) {
                    if (cell.proto) |proto| {
                        // Two receivers can share an own shape
                        // (the same root, or the same chain of
                        // transitions) while pointing at different
                        // prototype objects — e.g. `new String(x)`
                        // and `new Object(x)` both start at shape
                        // root but inherit from String.prototype
                        // vs Object.prototype. Verify identity of
                        // the cached proto pointer alongside its
                        // shape; otherwise the IC would serve the
                        // wrong chain's slot.
                        if (obj_in.prototype == proto and
                            proto.shape == cell.proto_shape and
                            cell.proto_rev == realm.proto_revision_counter)
                        {
                            acc = proto.slotAt(cell.slot);
                            continue :dispatch try decodeNext(code, &ip, &committed);
                        }
                    } else {
                        acc = obj_in.slotAt(cell.slot);
                        continue :dispatch try decodeNext(code, &ip, &committed);
                    }
                }
                // Cold / shape-changed / proto-invalidated.
                // Probe own shape first.
                if (obj_in.shape) |sh| {
                    if (sh.lookup(key_s.flatBytes())) |entry| {
                        if (entry.kind == .data) {
                            cell.shape = sh;
                            cell.slot = entry.slot;
                            cell.proto = null;
                            cell.proto_shape = null;
                            acc = obj_in.slotAt(entry.slot);
                            continue :dispatch try decodeNext(code, &ip, &committed);
                        }
                    }
                    // Prototype-load chain walk. Cache the first
                    // shape-claimed own-data hit; otherwise fall
                    // through to the slow path.
                    //
                    // CRITICAL: if a proto has the key in its
                    // `properties` bag but NOT in its shape (the
                    // proto is in dictionary mode for that key —
                    // some built-in prototypes like
                    // `%String.prototype%` lose their shape via
                    // exotic markers or other demoting paths),
                    // BREAK out of the walk. The slow path's
                    // properties-walk semantics still resolve the
                    // value correctly at this proto level; we
                    // must not skip past it and miscache a deeper
                    // proto's same-named property as if it were
                    // the resolution target.
                    //
                    // Also skip if the receiver has an own
                    // accessor for this key — the slow path's
                    // `lookupAccessor` dispatch fires the getter;
                    // serving an inherited data slot would
                    // silently bypass it.
                    if (!chainHasProxy(obj_in) and !obj_in.hasAccessor(key_s.flatBytes())) {
                        var cursor: ?*@import("../object.zig").JSObject = obj_in.prototype;
                        while (cursor) |proto| : (cursor = proto.prototype) {
                            if (proto.proxy_target != null or proto.proxy_revoked) break;
                            if (proto.is_module_namespace) break;
                            if (proto.hasAccessor(key_s.flatBytes())) break;
                            if (proto.shape) |proto_sh| {
                                if (proto_sh.lookup(key_s.flatBytes())) |entry| {
                                    if (entry.kind == .data) {
                                        cell.shape = sh;
                                        cell.slot = entry.slot;
                                        cell.proto = proto;
                                        cell.proto_shape = proto_sh;
                                        cell.proto_rev = realm.proto_revision_counter;
                                        acc = proto.slotAt(entry.slot);
                                        continue :dispatch try decodeNext(code, &ip, &committed);
                                    }
                                }
                            }
                            // Dictionary-mode proto holding the
                            // key — let the slow path resolve it.
                            if (proto.ownDataContains(key_s.flatBytes())) break;
                        }
                    }
                }
                // §10.5 Proxy [[Get]] — if `obj_in` is a proxy
                // exotic, dispatch through `handler.get` first;
                // a missing trap falls through to default lookup
                // on the target.
                var obj = obj_in;
                if (obj.proxy_target != null or obj.proxy_revoked) {
                    const r = try proxyGetTrap(allocator, realm, frames, f, ip, obj, key_s.flatBytes(), key_v, acc);
                    switch (r) {
                        .value => |v| {
                            acc = v;
                            continue :dispatch try decodeNext(code, &ip, &committed);
                        },
                        .fallthrough => |t| obj = t,
                        .handled => {
                            committed = true;
                            continue :dispatch try reEnterDispatch(frames, &f, &local_chunk, &code, &registers, &ip, &acc, &committed);
                        },
                        .uncaught => |ex| return .{ .thrown = ex },
                    }
                }
                // §9.4.6.7 Module Namespace [[Get]] — for a
                // string key bound to an export, route through
                // GetBindingValue(N, true) (§8.1.1.1.6) which
                // throws ReferenceError on the TDZ-Hole the
                // source module pre-seeds for uninitialised
                // `let` / `const` / `class` / default exports.
                // Symbol keys (and Cynic's flattened
                // `@@toStringTag`) bypass the env-record
                // dispatch per step 2 and fall through to the
                // ordinary path. Accessors don't exist on a
                // module namespace, so the lookupAccessor walk
                // below is skipped for the namespace case.
                if (obj.is_module_namespace and !std.mem.startsWith(u8, key_s.flatBytes(), "@@") and !std.mem.startsWith(u8, key_s.flatBytes(), "<sym:")) {
                    const v_ns = module_mod.namespaceGetThrowingOnHole(realm, obj, key_s.flatBytes()) catch |err| switch (err) {
                        error.OutOfMemory => return error.OutOfMemory,
                        error.NativeThrew => {
                            const ex = realm.pending_exception orelse Value.undefined_;
                            realm.pending_exception = null;
                            f.ip = ip;
                            f.accumulator = acc;
                            committed = true;
                            if (!try unwindThrow(allocator, realm, frames, ex)) {
                                return .{ .thrown = ex };
                            }
                            continue :dispatch try reEnterDispatch(frames, &f, &local_chunk, &code, &registers, &ip, &acc, &committed);
                        },
                    };
                    acc = v_ns;
                } else if (chainHasProxy(obj)) {
                    // §10.1.8 OrdinaryGet — when any ancestor in
                    // the prototype chain is a Proxy exotic, walk
                    // explicitly so that the proxy's [[Get]] fires
                    // with the original receiver (§10.1.8.1 step
                    // 4.b passes Receiver unchanged). Without this
                    // an inherited proxy accessor / trap silently
                    // bypasses.
                    switch (try getThroughChain(allocator, realm, frames, f, ip, obj, key_s.flatBytes(), acc)) {
                        .value => |v| acc = v,
                        .handled => {
                            committed = true;
                            continue :dispatch try reEnterDispatch(frames, &f, &local_chunk, &code, &registers, &ip, &acc, &committed);
                        },
                        .uncaught => |ex| return .{ .thrown = ex },
                    }
                } else if (lookupAccessor(obj, key_s.flatBytes())) |acc_pair| {
                    // §10.1.8 — accessor descriptor wins over
                    // data property. Walk the prototype chain
                    // looking for an accessor first.
                    if (acc_pair.getter) |getter| {
                        // Phase 3 SES fast path — a synthetic
                        // getter just returns its captured value
                        // (no observable side effects). Skip the
                        // call-frame setup and dispatch loop
                        // entry; we'd just pay malloc + a 5-stage
                        // return for what amounts to a pointer
                        // load.
                        if (getter.synth_accessor) |sa| {
                            if (!sa.is_setter) {
                                acc = sa.value;
                                continue :dispatch try decodeNext(code, &ip, &committed);
                            }
                        }
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
                                continue :dispatch try reEnterDispatch(frames, &f, &local_chunk, &code, &registers, &ip, &acc, &committed);
                            },
                        }
                    } else {
                        acc = Value.undefined_;
                    }
                } else {
                    acc = obj.get(key_s.flatBytes());
                }
            } else if (heap_mod.valueAsFunction(acc)) |fn_obj| {
                // §10.1.8.1 OrdinaryGet step 4 — accessor
                // descriptor wins over data. Walk the full
                // function `[[Prototype]]` chain (own →
                // `static_parent` → `proto`) so the poison-pill
                // `caller` / `arguments` accessors installed on
                // %Function.prototype% (§10.2.4) fire when user
                // code reads `fn.caller` / `fn.arguments`.
                if (lookupFunctionAccessor(fn_obj, key_s.flatBytes())) |acc_pair| {
                    if (acc_pair.getter) |getter| {
                        // Phase 3 SES fast path — see the same
                        // optimization in the plain-object arm.
                        if (getter.synth_accessor) |sa| {
                            if (!sa.is_setter) {
                                acc = sa.value;
                                continue :dispatch try decodeNext(code, &ip, &committed);
                            }
                        }
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
                                continue :dispatch try reEnterDispatch(frames, &f, &local_chunk, &code, &registers, &ip, &acc, &committed);
                            },
                        }
                    } else {
                        acc = Value.undefined_;
                    }
                } else {
                    acc = fn_obj.get(key_s.flatBytes());
                }
            } else if (acc.isString()) {
                // §6.1.4.4 — string primitives expose.length,
                // numeric-index char access, and inherited
                // `String.prototype` methods (`.charAt` etc.)
                // looked up through the realm's intrinsic.
                const recv: *JSString = @ptrCast(@alignCast(acc.asString()));
                if (std.mem.eql(u8, key_s.flatBytes(), "length")) {
                    // §22.1.5.1 — String.prototype.length is the
                    // count of UTF-16 code units in the String
                    // value (§6.1.4), not the WTF-8 byte length.
                    acc = Value.fromInt32(@intCast(utf16.lengthInCodeUnits(recv.flatBytes())));
                } else if (realm.intrinsics.string_prototype) |sp| {
                    // §10.1.8.1 OrdinaryGet — walk the prototype
                    // chain looking for an accessor first; an
                    // accessor anywhere on the chain wins over
                    // an inherited data property. Strict-mode
                    // primitive receivers forward the primitive
                    // as `this` to the getter (§10.2.1.2
                    // OrdinaryCallBindThis — no boxing).
                    if (lookupAccessor(sp, key_s.flatBytes())) |acc_pair| {
                        if (acc_pair.getter) |getter| {
                            const recv_v = acc;
                            const outcome = try callJSFunction(allocator, realm, getter, recv_v, &.{});
                            switch (outcome) {
                                .value, .yielded => |v| acc = v,
                                .thrown => |ex| {
                                    f.ip = ip;
                                    f.accumulator = acc;
                                    committed = true;
                                    if (!try unwindThrow(allocator, realm, frames, ex)) {
                                        return .{ .thrown = ex };
                                    }
                                    continue :dispatch try reEnterDispatch(frames, &f, &local_chunk, &code, &registers, &ip, &acc, &committed);
                                },
                            }
                        } else {
                            acc = Value.undefined_;
                        }
                    } else {
                        acc = sp.get(key_s.flatBytes());
                    }
                } else acc = Value.undefined_;
            } else if (acc.isInt32() or acc.isDouble()) {
                // §7.1.1 ToObject(Number) — primitive number
                // methods (`.toFixed`, `.toString`) resolve via
                // %Number.prototype%. An accessor inherited
                // from `Object.prototype` (e.g. user code added
                // `Object.defineProperty(Object.prototype, "x",
                // { get })`) wins over the data-property fast
                // path (§10.1.8.1); the getter is called with
                // `this = <number primitive>` in strict mode.
                if (heap_mod.valueAsFunction((f.running_realm orelse realm).globals.get("Number") orelse Value.undefined_)) |num_ctor| {
                    if (num_ctor.prototype) |np| {
                        if (lookupAccessor(np, key_s.flatBytes())) |acc_pair| {
                            if (acc_pair.getter) |getter| {
                                const recv_v = acc;
                                const outcome = try callJSFunction(allocator, realm, getter, recv_v, &.{});
                                switch (outcome) {
                                    .value, .yielded => |v| acc = v,
                                    .thrown => |ex| {
                                        f.ip = ip;
                                        f.accumulator = acc;
                                        committed = true;
                                        if (!try unwindThrow(allocator, realm, frames, ex)) {
                                            return .{ .thrown = ex };
                                        }
                                        continue :dispatch try reEnterDispatch(frames, &f, &local_chunk, &code, &registers, &ip, &acc, &committed);
                                    },
                                }
                            } else {
                                acc = Value.undefined_;
                            }
                        } else {
                            acc = np.get(key_s.flatBytes());
                        }
                    } else acc = Value.undefined_;
                } else acc = Value.undefined_;
            } else if (acc.isBool()) {
                // §7.1.1 ToObject(Boolean). Same accessor-aware
                // chain walk as the Number arm above.
                if (heap_mod.valueAsFunction((f.running_realm orelse realm).globals.get("Boolean") orelse Value.undefined_)) |bool_ctor| {
                    if (bool_ctor.prototype) |bp| {
                        if (lookupAccessor(bp, key_s.flatBytes())) |acc_pair| {
                            if (acc_pair.getter) |getter| {
                                const recv_v = acc;
                                const outcome = try callJSFunction(allocator, realm, getter, recv_v, &.{});
                                switch (outcome) {
                                    .value, .yielded => |v| acc = v,
                                    .thrown => |ex| {
                                        f.ip = ip;
                                        f.accumulator = acc;
                                        committed = true;
                                        if (!try unwindThrow(allocator, realm, frames, ex)) {
                                            return .{ .thrown = ex };
                                        }
                                        continue :dispatch try reEnterDispatch(frames, &f, &local_chunk, &code, &registers, &ip, &acc, &committed);
                                    },
                                }
                            } else {
                                acc = Value.undefined_;
                            }
                        } else {
                            acc = bp.get(key_s.flatBytes());
                        }
                    } else acc = Value.undefined_;
                } else acc = Value.undefined_;
            } else if (heap_mod.isBigInt(acc)) {
                // §7.1.1 ToObject(BigInt). Same accessor-aware
                // chain walk as the Number arm above.
                if (heap_mod.valueAsFunction((f.running_realm orelse realm).globals.get("BigInt") orelse Value.undefined_)) |bi_ctor| {
                    if (bi_ctor.prototype) |bp| {
                        if (lookupAccessor(bp, key_s.flatBytes())) |acc_pair| {
                            if (acc_pair.getter) |getter| {
                                const recv_v = acc;
                                const outcome = try callJSFunction(allocator, realm, getter, recv_v, &.{});
                                switch (outcome) {
                                    .value, .yielded => |v| acc = v,
                                    .thrown => |ex| {
                                        f.ip = ip;
                                        f.accumulator = acc;
                                        committed = true;
                                        if (!try unwindThrow(allocator, realm, frames, ex)) {
                                            return .{ .thrown = ex };
                                        }
                                        continue :dispatch try reEnterDispatch(frames, &f, &local_chunk, &code, &registers, &ip, &acc, &committed);
                                    },
                                }
                            } else {
                                acc = Value.undefined_;
                            }
                        } else {
                            acc = bp.get(key_s.flatBytes());
                        }
                    } else acc = Value.undefined_;
                } else acc = Value.undefined_;
            } else if (heap_mod.isSymbol(acc)) {
                // §7.1.18 ToObject(Symbol) — primitive
                // symbol method lookups resolve via
                // %Symbol.prototype%, with `this` reading
                // the symbol primitive directly.
                if (heap_mod.valueAsFunction((f.running_realm orelse realm).globals.get("Symbol") orelse Value.undefined_)) |sym_ctor| {
                    if (sym_ctor.prototype) |sp| {
                        // Accessor descriptors (e.g. `description`)
                        // win over property-bag entries.
                        if (lookupAccessor(sp, key_s.flatBytes())) |acc_pair| {
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
                                        continue :dispatch try reEnterDispatch(frames, &f, &local_chunk, &code, &registers, &ip, &acc, &committed);
                                    },
                                }
                            } else {
                                acc = Value.undefined_;
                            }
                        } else {
                            acc = sp.get(key_s.flatBytes());
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
                continue :dispatch try reEnterDispatch(frames, &f, &local_chunk, &code, &registers, &ip, &acc, &committed);
            }
            continue :dispatch try decodeNext(code, &ip, &committed);
        },
        .sta_property => {
            const k = readU16(code, ip);
            const r_obj = code[ip + 2];
            const ic_idx = readU16(code, ip + 3);
            ip += 5;
            if (k >= local_chunk.constants.len) return error.InvalidOpcode;
            const key_v = local_chunk.constants[k];
            if (!key_v.isString()) return error.InvalidOpcode;
            const key_s: *JSString = @ptrCast(@alignCast(key_v.asString()));
            const recv = registers[r_obj];
            // Monomorphic IC fast path. A cached shape pointer
            // implies a shaped plain ordinary object (shadowSet
            // demotes any exotic before stamping), and the cell
            // is only filled for existing own-data writable
            // entries — so a hit means the prototype walk for
            // a non-writable ancestor was already mooted by the
            // own shadow. The slow path below refills the cell
            // only on same-shape rewrites (no transition).
            const recv_obj_opt = heap_mod.valueAsPlainObject(recv);
            if (recv_obj_opt) |obj_in| {
                const cell = &local_chunk.inline_caches[ic_idx];
                if (cell.shape != null and cell.shape == obj_in.shape) {
                    // Shape-authoritative write: slot vector is
                    // the source of truth for shape-mode objects.
                    // `JSObject.get` / `.hasOwn` are shape-first
                    // (4133c7f / 4b06eb4), so spec-surface reads
                    // resolve against `slots`. Skip the bag mirror
                    // entirely on the IC hot path. Any remaining
                    // direct `obj.properties.get` reader that
                    // sees a stale value is a migration target —
                    // route it through `JSObject.get` or accept
                    // the bag staleness as an audit-flagged
                    // divergence.
                    obj_in.setSlot(cell.slot, acc);
                    realm.heap.storeInternalSlot(.{ .object = obj_in }, acc);
                    continue :dispatch try decodeNext(code, &ip, &committed);
                }
                // Transition fast path — the "fresh instance" case
                // the same-shape IC above refuses (the cached
                // post-shape never matches the next iteration's
                // pre-shape). Cell records `(pre_shape, post_shape,
                // slot, proto, proto_shape, proto_rev)` so a hot
                // class-ctor loop's `this.x = …` writes skip the
                // slow path's `lookupAccessor` chain walk,
                // `Wyhash` on the key, and `ShapeTree.transition`.
                //
                // Validity:
                //   • `obj.shape == cell.pre_shape` — receiver shape
                //     unchanged since fill.
                //   • `obj.prototype == cell.proto` — immediate
                //     proto identity unchanged. The slot is on the
                //     receiver, but accessor inheritance fires
                //     from the chain — invalidating on chain
                //     identity catches `setPrototypeOf(obj, x)`
                //     calls that don't bump the realm counter.
                //   • `cell.proto.?.shape == cell.proto_shape` —
                //     proto's own shape unchanged. Adding an
                //     accessor to a proto with `defineProperty`
                //     changes that proto's shape (accessor entries
                //     are part of the shape), so we catch it.
                //   • `cell.proto_rev == realm.proto_revision_counter`
                //     — no `Object.setPrototypeOf` /
                //     `Reflect.setPrototypeOf` / `__proto__` write
                //     anywhere in the realm since fill. Covers
                //     deeper-chain mutations.
                // `post_shape != null` is the transition-mode
                // indicator (cold cells leave it null; same-shape
                // mode never sets it). Using it instead of
                // `pre_shape != null` lets the very FIRST write
                // on a fresh instance hit the fast path — that
                // instance has `shape == null` (the root), which
                // matches `cell.pre_shape == null` from fill on
                // an equally-fresh sibling instance. Before this
                // fix, only the second-onward write in a ctor
                // loop hit the fast path.
                if (cell.post_shape != null and cell.pre_shape == obj_in.shape and
                    obj_in.prototype != null and obj_in.prototype == cell.proto and
                    cell.proto.?.shape == cell.proto_shape and
                    cell.proto_rev == realm.proto_revision_counter and
                    // §10.1.9 — also catch a non-writable / accessor
                    // installed on a dictionary-mode or non-immediate
                    // prototype after fill (proto_shape / proto_rev miss
                    // those; the structural funnels bump this epoch).
                    cell.guard_epoch == realm.heap.proto_struct_epoch)
                {
                    const post_shape = cell.post_shape.?;
                    if (obj_in.slotCount() < post_shape.property_count) {
                        obj_in.resizeSlots(allocator, post_shape.property_count) catch return error.OutOfMemory;
                    }
                    obj_in.shape = post_shape;
                    obj_in.setSlot(cell.slot, acc);
                    realm.heap.writeBarrier(.{ .object = obj_in }, acc);
                    realm.heap.storeInternalSlot(.{ .object = obj_in }, acc);
                    continue :dispatch try decodeNext(code, &ip, &committed);
                }
            }
            // Capture the pre-write shape so the refill below
            // can distinguish a same-shape rewrite (cacheable
            // — next iteration hits) from a shape transition
            // (cacheable via the transition mode, gated on
            // proto-chain accessor-cleanliness — see fill block).
            const pre_shape: ?*@import("../shape.zig").Shape = if (recv_obj_opt) |o| o.shape else null;
            {
                const set_outcome = try strictSetProperty(allocator, realm, frames, f, ip, recv, key_s.flatBytes(), acc);
                switch (set_outcome) {
                    .ok => {},
                    .handled => {
                        committed = true;
                        continue :dispatch try reEnterDispatch(frames, &f, &local_chunk, &code, &registers, &ip, &acc, &committed);
                    },
                    .uncaught => |ex| return .{ .thrown = ex },
                }
            }
            if (recv_obj_opt) |obj_after| {
                if (obj_after.shape) |sh| {
                    if (pre_shape == sh) {
                        // Same-shape rewrite — fill the original
                        // own-data IC.
                        if (sh.lookup(key_s.flatBytes())) |entry| {
                            if (entry.kind == .data and entry.attrs.writable) {
                                const cell = &local_chunk.inline_caches[ic_idx];
                                cell.shape = sh;
                                cell.slot = entry.slot;
                                cell.pre_shape = null;
                                cell.post_shape = null;
                                // Capture the bag's array-index for
                                // the IC hot path's bag mirror. Safe
                                // for shape-stable receivers because
                                // shape transitions are the only
                                // bag-append site (and they
                                // invalidate the cell via the shape
                                // pointer compare).
                                if (obj_after.properties.getIndex(key_s.flatBytes())) |bi| {
                                    cell.bag_index = @intCast(bi);
                                } else {
                                    cell.bag_index = chunk_mod.bag_index_uncached;
                                }
                            }
                        }
                    } else if (sh.lookup(key_s.flatBytes())) |entry| {
                        // Shape transition (sh != pre_shape) AND the
                        // new shape claims the key as own data. The
                        // write went through `shadowSet` cleanly, so
                        // the receiver has no own accessor for the
                        // key. Fill the transition IC if (a) the
                        // entire proto chain has no accessor for
                        // the key — otherwise a future call would
                        // skip a setter inherited from a proto;
                        // (b) no proxy ancestor — proxy [[Set]] must
                        // run every time; (c) the receiver has a
                        // non-null prototype to snapshot.
                        if (entry.kind == .data and entry.attrs.writable and
                            !chainHasProxy(obj_after) and
                            obj_after.prototype != null)
                        {
                            // Walk the chain once at fill time to
                            // ensure no accessor exists for the
                            // key anywhere. This is `lookupAccessor`'s
                            // shape — done once per cell-fill rather
                            // than once per write.
                            var chain_clean = true;
                            var cursor: ?*JSObject = obj_after.prototype;
                            while (cursor) |proto| : (cursor = proto.prototype) {
                                if (proto.hasAccessor(key_s.flatBytes())) {
                                    chain_clean = false;
                                    break;
                                }
                            }
                            if (chain_clean) {
                                const cell = &local_chunk.inline_caches[ic_idx];
                                cell.shape = null;
                                cell.pre_shape = pre_shape;
                                cell.post_shape = sh;
                                cell.slot = entry.slot;
                                cell.proto = obj_after.prototype;
                                cell.proto_shape = obj_after.prototype.?.shape;
                                cell.proto_rev = realm.proto_revision_counter;
                                cell.guard_epoch = realm.heap.proto_struct_epoch;
                                cell.bag_index = chunk_mod.bag_index_uncached;
                            }
                        }
                    }
                }
            }
            continue :dispatch try decodeNext(code, &ip, &committed);
        },
        .def_property => {
            // §7.3.7 CreateDataPropertyOrThrow — used by Array /
            // Object literal init. Bypasses [[Set]] (so inherited
            // accessors on `Array.prototype.0` / `Object.prototype.x`
            // don't fire) and lands the value as an own data slot
            // with `{w:T,e:T,c:T}`. The receiver is always a fresh
            // object we just made via `make_array` / `make_object`,
            // so it's extensible and has no preexisting own slot at
            // this key — the throws below are defensive.
            const k = readU16(code, ip);
            const r_obj = code[ip + 2];
            ip += 3;
            if (k >= local_chunk.constants.len) return error.InvalidOpcode;
            const key_v = local_chunk.constants[k];
            if (!key_v.isString()) return error.InvalidOpcode;
            const key_s: *JSString = @ptrCast(@alignCast(key_v.asString()));
            const recv = registers[r_obj];
            const obj = heap_mod.valueAsPlainObject(recv) orelse return error.InvalidOpcode;
            // §13.2.4.1 ArrayAccumulation fast path — an array literal
            // `[a, b, c]` emits one CreateDataProperty per element with
            // the next canonical index ("0", "1", "2") onto a freshly
            // made dense Array exotic. A sequential dense append produces
            // exactly CreateDataProperty's effect (`elements[idx] = v`,
            // `length = idx + 1`, implicit `{w,e,c} = true`) while skipping
            // the `hasOwn` precheck (a fresh append is never a preexisting
            // own slot), the second `canonicalIntegerIndex` re-parse inside
            // `setWithFlags`, and `setIndexed`'s redundant hole-fill +
            // duplicate write barrier. Falls through for sparse arrays or
            // out-of-order / overwriting indices.
            if (obj.is_array_exotic) {
                if (object_mod.JSObject.canonicalIntegerIndex(key_s.flatBytes())) |idx| {
                    if (obj.appendDenseSequential(allocator, idx, acc) catch return error.OutOfMemory) {
                        continue :dispatch try decodeNext(code, &ip, &committed);
                    }
                }
            }
            const had_own = obj.hasOwn(key_s.flatBytes());
            if (!had_own and !obj.extensible) {
                const ex = try makeTypeError(realm, "Cannot define property on non-extensible object");
                return .{ .thrown = ex };
            }
            if (had_own) {
                const cur = obj.flagsFor(key_s.flatBytes());
                if (!cur.configurable) {
                    const ex = try makeTypeError(realm, "Cannot redefine non-configurable property");
                    return .{ .thrown = ex };
                }
                // Same-attrs redefine — let `setWithFlags`'s
                // shadowSet path overwrite the existing entry
                // in place (slot write + bag put-overwrite).
                // Crucial for `make_object_shape` literal
                // templates: the shape stamp marks every key
                // as already own, so `had_own` is true on the
                // first def_property — without this branch,
                // every templatized literal would
                // immediately demote.
                const new_default: object_mod.PropertyFlags = .{
                    .writable = true,
                    .enumerable = true,
                    .configurable = true,
                };
                if (cur.writable == new_default.writable and
                    cur.enumerable == new_default.enumerable and
                    cur.configurable == new_default.configurable)
                {
                    realm.heap.storePropertyWithFlags(obj, allocator, key_s.flatBytes(), acc, new_default) catch return error.OutOfMemory;
                    continue :dispatch try decodeNext(code, &ip, &committed);
                }
                // Attrs would change — the append-only shape
                // can't encode that, so demote and rebuild
                // through `storePropertyWithFlags`.
                obj.demoteFromShape(allocator) catch return error.OutOfMemory;
                _ = obj.properties.swapRemove(key_s.flatBytes());
                _ = obj.property_flags.swapRemove(key_s.flatBytes());
            }
            realm.heap.storePropertyWithFlags(obj, allocator, key_s.flatBytes(), acc, object_mod.PropertyFlags.default) catch return error.OutOfMemory;
            continue :dispatch try decodeNext(code, &ip, &committed);
        },
        .def_template_property => {
            // §7.3.7 CreateDataPropertyOrThrow, templatized form.
            // The preceding `make_object_shape` op stamped a cached
            // `Shape*` whose layout puts this key at `slot` and
            // pre-filled `own_key_order` with every template key,
            // so the fast path is a raw slot write + generational
            // write barrier. No `hasOwn`, no `flagsFor`, no
            // `shadowSet` shape lookup, no `recordKey` linear scan.
            const k = readU16(code, ip);
            const r_obj = code[ip + 2];
            const slot = readU16(code, ip + 3);
            ip += 5;
            const recv = registers[r_obj];
            const obj = heap_mod.valueAsPlainObject(recv) orelse return error.InvalidOpcode;
            // Fast path: the templatized shape is still in place,
            // the pre-sized slots vector still covers `slot`, and
            // the object hasn't been demoted (e.g. by a user-code
            // `Object.defineProperty` between `make_object_shape`
            // and this write, which can't happen for a literal in
            // a temp register but is checked for safety).
            if (obj.shape != null and slot < obj.slotCount()) {
                obj.setSlot(slot, acc);
                realm.heap.writeBarrier(.{ .object = obj }, acc);
                continue :dispatch try decodeNext(code, &ip, &committed);
            }
            // Deopt — fall through to the regular def_property
            // semantics so any unexpected shape demote (a future
            // path, a debugger-injected mutation, etc.) keeps
            // CreateDataPropertyOrThrow's spec contract.
            if (k >= local_chunk.constants.len) return error.InvalidOpcode;
            const key_v = local_chunk.constants[k];
            if (!key_v.isString()) return error.InvalidOpcode;
            const key_s: *JSString = @ptrCast(@alignCast(key_v.asString()));
            const had_own = obj.hasOwn(key_s.flatBytes());
            if (!had_own and !obj.extensible) {
                const ex = try makeTypeError(realm, "Cannot define property on non-extensible object");
                return .{ .thrown = ex };
            }
            if (had_own) {
                const cur = obj.flagsFor(key_s.flatBytes());
                if (!cur.configurable) {
                    const ex = try makeTypeError(realm, "Cannot redefine non-configurable property");
                    return .{ .thrown = ex };
                }
                const new_default: object_mod.PropertyFlags = .{
                    .writable = true,
                    .enumerable = true,
                    .configurable = true,
                };
                if (cur.writable == new_default.writable and
                    cur.enumerable == new_default.enumerable and
                    cur.configurable == new_default.configurable)
                {
                    realm.heap.storePropertyWithFlags(obj, allocator, key_s.flatBytes(), acc, new_default) catch return error.OutOfMemory;
                    continue :dispatch try decodeNext(code, &ip, &committed);
                }
                obj.demoteFromShape(allocator) catch return error.OutOfMemory;
                _ = obj.properties.swapRemove(key_s.flatBytes());
                _ = obj.property_flags.swapRemove(key_s.flatBytes());
            }
            realm.heap.storePropertyWithFlags(obj, allocator, key_s.flatBytes(), acc, object_mod.PropertyFlags.default) catch return error.OutOfMemory;
            continue :dispatch try decodeNext(code, &ip, &committed);
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
                continue :dispatch try reEnterDispatch(frames, &f, &local_chunk, &code, &registers, &ip, &acc, &committed);
            }
            // §10.1.8.1 OrdinaryGet step 1 — an int32 non-negative
            // key on a non-proxy dense Array exotic resolves to the
            // own element when present, shadowing everything behind
            // it. §7.1.19 ToPropertyKey of an int32 is side-effect-
            // free and §7.1.21 CanonicalNumericIndexString of any
            // non-negative int32 is exactly its decimal string, so
            // serving `elements[idx]` directly is observably
            // identical to the full stringify + chain walk (which
            // was ~23 % of the ctor_array_build profile — see
            // docs/ctor-array-build-gap.md). Every miss class —
            // hole, out-of-bounds, sparse storage, proxy receiver,
            // accessor-promoted slot — falls through unchanged.
            // Shared with Bistromath via `Heap.denseElementFastGet`
            // (a pure, allocation-free check) so the compiled tier's
            // codegen is byte-identical (L1: don't fork).
            if (heap_mod.Heap.denseElementFastGet(recv, acc)) |v| {
                acc = v;
                continue :dispatch try decodeNext(code, &ip, &committed);
            }
            // §7.1.19 ToPropertyKey — for object keys (e.g.
            // `obj[arr]`), run ToPrimitive(string) so user-
            // defined `toString` / `valueOf` / `[@@toPrimitive]`
            // hooks fire before we string-format.
            const key_v = switch (try coerceToPropertyKey(allocator, realm, frames, f, ip, acc)) {
                .ok => |v| v,
                .handled => {
                    committed = true;
                    continue :dispatch try reEnterDispatch(frames, &f, &local_chunk, &code, &registers, &ip, &acc, &committed);
                },
                .uncaught => |ex| return .{ .thrown = ex },
            };
            var key_buf: [64]u8 = undefined;
            const key_slice = computedKeyToString(key_v, &key_buf);
            if (heap_mod.valueAsPlainObject(recv)) |obj_in| {
                var obj = obj_in;
                // §10.5 Proxy [[Get]] — handler trap dispatch.
                if (obj.proxy_target != null or obj.proxy_revoked) {
                    const r = try proxyGetTrap(allocator, realm, frames, f, ip, obj, key_slice, key_v, recv);
                    switch (r) {
                        .value => |v| {
                            acc = v;
                            continue :dispatch try decodeNext(code, &ip, &committed);
                        },
                        .fallthrough => |t| obj = t,
                        .handled => {
                            committed = true;
                            continue :dispatch try reEnterDispatch(frames, &f, &local_chunk, &code, &registers, &ip, &acc, &committed);
                        },
                        .uncaught => |ex| return .{ .thrown = ex },
                    }
                }
                // §10.4.5.4 Integer-Indexed Exotic [[Get]] — when
                // the key is a CanonicalNumericIndexString, the
                // lookup is intercepted by IntegerIndexedElementGet.
                // Per §10.4.5.9: any non-IsValidIntegerIndex form
                // (non-integer, -0, negative, ≥ length, detached
                // buffer) returns `undefined` WITHOUT walking the
                // prototype chain. So `ta["-0"]`, `ta["1.1"]`,
                // `ta["-1"]`, `ta["1000000000000000000000"]` all
                // bypass an accessor installed on
                // TypedArray.prototype["<same key>"].
                if (obj.getTypedView()) |tv| {
                    const ta_mod = @import("../builtins/typed_array.zig");
                    if (ta_mod.canonicalNumericIndex(key_slice)) |num| {
                        if (ta_mod.isValidIntegerIndexPub(tv, num)) {
                            const buf = tv.viewed.getArrayBuffer().?;
                            const elem_size = tv.kind.elementSize();
                            const idx: usize = @intFromFloat(num);
                            acc = intrinsics_mod.readTypedElement(realm, buf, tv.kind, tv.byte_offset + idx * elem_size);
                        } else {
                            acc = Value.undefined_;
                        }
                        continue :dispatch try decodeNext(code, &ip, &committed);
                    }
                }
                // §9.4.6.7 Module Namespace [[Get]] — mirror
                // `lda_property` for the computed-key form
                // (`ns[k]`). String keys bound to exports route
                // through GetBindingValue(N, true) and throw
                // ReferenceError on the TDZ-Hole. Symbol keys
                // (and Cynic's flattened `@@toStringTag`) take
                // the ordinary path.
                if (obj.is_module_namespace and !std.mem.startsWith(u8, key_slice, "@@") and !std.mem.startsWith(u8, key_slice, "<sym:")) {
                    const v_ns = module_mod.namespaceGetThrowingOnHole(realm, obj, key_slice) catch |err| switch (err) {
                        error.OutOfMemory => return error.OutOfMemory,
                        error.NativeThrew => {
                            const ex = realm.pending_exception orelse Value.undefined_;
                            realm.pending_exception = null;
                            f.ip = ip;
                            f.accumulator = acc;
                            committed = true;
                            if (!try unwindThrow(allocator, realm, frames, ex)) {
                                return .{ .thrown = ex };
                            }
                            continue :dispatch try reEnterDispatch(frames, &f, &local_chunk, &code, &registers, &ip, &acc, &committed);
                        },
                    };
                    acc = v_ns;
                    continue :dispatch try decodeNext(code, &ip, &committed);
                }
                // §10.1.8 [[Get]] — accessor wins over data.
                // Mirror the `lda_property` handling so
                // `obj[expr]` and `obj.x` behave identically
                // when `x` resolves to a getter on the chain.
                if (chainHasProxy(obj)) {
                    switch (try getThroughChain(allocator, realm, frames, f, ip, obj, key_slice, recv)) {
                        .value => |v| acc = v,
                        .handled => {
                            committed = true;
                            continue :dispatch try reEnterDispatch(frames, &f, &local_chunk, &code, &registers, &ip, &acc, &committed);
                        },
                        .uncaught => |ex| return .{ .thrown = ex },
                    }
                    continue :dispatch try decodeNext(code, &ip, &committed);
                }
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
                                continue :dispatch try reEnterDispatch(frames, &f, &local_chunk, &code, &registers, &ip, &acc, &committed);
                            },
                        }
                    } else {
                        acc = Value.undefined_;
                    }
                    continue :dispatch try decodeNext(code, &ip, &committed);
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
                                continue :dispatch try reEnterDispatch(frames, &f, &local_chunk, &code, &registers, &ip, &acc, &committed);
                            },
                        }
                    } else {
                        acc = Value.undefined_;
                    }
                } else {
                    acc = fn_obj.get(key_slice);
                }
            } else if (recv.isString()) {
                // §22.1.4.4 — String exotic objects expose
                // `length` (count of UTF-16 code units) and
                // numeric-index character access (one-element
                // String of the code unit at the index), plus
                // inherited String.prototype methods.
                const s: *JSString = @ptrCast(@alignCast(recv.asString()));
                if (std.mem.eql(u8, key_slice, "length")) {
                    acc = Value.fromInt32(@intCast(utf16.lengthInCodeUnits(s.flatBytes())));
                } else if (std.fmt.parseInt(usize, key_slice, 10)) |idx| {
                    // §22.1.4.4 [[GetOwnProperty]] — the indexed
                    // own property is the one-element String
                    // value containing the code unit at index
                    // `idx`. Walk the code-unit view and emit
                    // the WTF-8 encoding of that single unit.
                    if (utf16.codeUnitAt(s.flatBytes(), idx)) |cu| {
                        var buf: std.ArrayListUnmanaged(u8) = .empty;
                        defer buf.deinit(allocator);
                        utf16.appendCodeUnitAsWtf8(allocator, &buf, cu) catch return error.OutOfMemory;
                        const ns = realm.heap.allocateString(buf.items) catch return error.OutOfMemory;
                        acc = Value.fromString(ns);
                    } else {
                        acc = Value.undefined_;
                    }
                } else |_| {
                    if (realm.intrinsics.string_prototype) |sp| {
                        // §10.1.8.1 OrdinaryGet — accessor on
                        // the proto chain wins over inherited
                        // data; primitive `this` is forwarded
                        // unboxed in strict mode (§10.2.1.2).
                        if (lookupAccessor(sp, key_slice)) |acc_pair| {
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
                                        continue :dispatch try reEnterDispatch(frames, &f, &local_chunk, &code, &registers, &ip, &acc, &committed);
                                    },
                                }
                            } else {
                                acc = Value.undefined_;
                            }
                        } else {
                            acc = sp.get(key_slice);
                        }
                    } else acc = Value.undefined_;
                }
            } else {
                // §13.3.4 — `boolean[key]` / `number[key]` /
                // `bigint[key]` / `symbol[key]` ToObject-box the
                // receiver, so property reads find the inherited
                // prototype methods. Walk straight to the boxed
                // proto chain without materialising a wrapper.
                // §10.1.8.1 OrdinaryGet — an accessor descriptor
                // anywhere on the proto chain wins over a data
                // property. Strict-mode primitive receivers
                // forward `this = <primitive>` to the getter.
                const proto_opt: ?*JSObject = intrinsics_mod.lookupPrimitivePrototype(realm, recv);
                if (proto_opt) |proto| {
                    if (lookupAccessor(proto, key_slice)) |acc_pair| {
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
                                    continue :dispatch try reEnterDispatch(frames, &f, &local_chunk, &code, &registers, &ip, &acc, &committed);
                                },
                            }
                        } else {
                            acc = Value.undefined_;
                        }
                    } else {
                        acc = proto.get(key_slice);
                    }
                } else {
                    const ex = try makeTypeError(realm, "Cannot read properties of non-object");
                    f.ip = ip;
                    f.accumulator = acc;
                    committed = true;
                    if (!try unwindThrow(allocator, realm, frames, ex)) {
                        return .{ .thrown = ex };
                    }
                    continue :dispatch try reEnterDispatch(frames, &f, &local_chunk, &code, &registers, &ip, &acc, &committed);
                }
            }
            continue :dispatch try decodeNext(code, &ip, &committed);
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
                    continue :dispatch try reEnterDispatch(frames, &f, &local_chunk, &code, &registers, &ip, &acc, &committed);
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
            // CanonicalNumericIndexString-shaped keys intercept
            // the OrdinarySet path: a valid integer index writes
            // through; an invalid one (NaN/Infinity/-0/non-integer/
            // negative/out-of-bounds) silently drops after the
            // ToNumber/ToBigInt side effects fire.
            if (heap_mod.valueAsPlainObject(recv)) |obj| {
                if (obj.getTypedView()) |tv| {
                    const ta_mod = @import("../builtins/typed_array.zig");
                    if (ta_mod.canonicalNumericIndex(key_slice)) |num| {
                        // §10.4.5.13 SetTypedArrayElement — type
                        // coercion runs FIRST, with full side-effect
                        // visibility (user `valueOf` / `Symbol.toPrimitive`
                        // may throw or detach the buffer). After the
                        // coercion settles we re-check IsValidIntegerIndex;
                        // an invalid index (NaN, -0, non-integer,
                        // negative, ≥ length, detached) silently drops the
                        // write. [[Set]] still returns true in both branches.
                        const coerce_outcome: union(enum) { value: Value, thrown: Value } = if (tv.kind.isBigInt()) blk: {
                            const r = @import("../builtins/bigint.zig").toBigIntValue(realm, acc) catch |err| switch (err) {
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
                                continue :dispatch try reEnterDispatch(frames, &f, &local_chunk, &code, &registers, &ip, &acc, &committed);
                            },
                        };
                        // Re-fetch the live view (a user `valueOf` could
                        // have detached / shrunk the buffer between
                        // ToNumber and the write).
                        const live_tv = obj.getTypedView() orelse {
                            continue :dispatch try decodeNext(code, &ip, &committed);
                        };
                        if (ta_mod.isValidIntegerIndexPub(live_tv, num)) {
                            const buf = live_tv.viewed.getArrayBuffer().?;
                            const elem_size = live_tv.kind.elementSize();
                            const idx: usize = @intFromFloat(num);
                            // Name-aware dispatch keeps Uint8ClampedArray
                            // on the ToUint8Clamp path (§7.1.11) rather
                            // than modular ToUint8 (§7.1.6).
                            intrinsics_mod.writeTypedElementForView(buf, live_tv, live_tv.byte_offset + idx * elem_size, coerced);
                        }
                        continue :dispatch try decodeNext(code, &ip, &committed);
                    }
                }
            }
            // The property map stores only the key slice, so a
            // heap-owned JSString is allocated to anchor the
            // key's backing memory against GC. Skip that
            // allocation for an Array exotic receiver indexed by
            // a non-negative Int32: such a [[Set]] resolves to
            // `storeElement` (the packed `elements` vector, which
            // keys on the integer index, not a string) on a fresh
            // index, or — when the slot was descriptor-demoted
            // into the named bag — to an in-place update of the
            // already-anchored entry. Neither path inserts a new
            // string key, so no anchor is consumed; the stack
            // `key_slice` stays valid for the whole synchronous
            // call. Hot loops like `a[i++] = x` (e.g. test262's
            // `buildString` code-point accumulation) allocated one
            // throwaway JSString per iteration before this guard.
            const skip_key_anchor = key_v.isInt32() and key_v.asInt32() >= 0 and
                if (heap_mod.valueAsPlainObject(recv)) |o| o.is_array_exotic else false;
            const owned: ?*JSString =
                if (skip_key_anchor) null else (realm.heap.allocateString(key_slice) catch return error.OutOfMemory);
            {
                const key_arg: []const u8 = if (owned) |o| o.flatBytes() else key_slice;
                const set_outcome = try strictSetPropertyAnchored(allocator, realm, frames, f, ip, recv, key_arg, owned, acc);
                switch (set_outcome) {
                    .ok => {},
                    .handled => {
                        committed = true;
                        continue :dispatch try reEnterDispatch(frames, &f, &local_chunk, &code, &registers, &ip, &acc, &committed);
                    },
                    .uncaught => |ex| return .{ .thrown = ex },
                }
            }
            continue :dispatch try decodeNext(code, &ip, &committed);
        },
        .def_computed => {
            // §7.3.7 CreateDataPropertyOrThrow with a computed
            // key — used by object literals with `[expr]: value`
            // shorthand. The key in `r_key` has already been
            // run through ToPropertyKey by the compiler.
            const r_obj = code[ip];
            const r_key = code[ip + 1];
            ip += 2;
            const recv = registers[r_obj];
            const key_v = registers[r_key];
            // Need a stable, GC-anchored key slice. For a String
            // key, use the JSString bytes directly and anchor on
            // the receiver via `key_anchors`. For other primitives,
            // intern a JSString first.
            const obj = heap_mod.valueAsPlainObject(recv) orelse return error.InvalidOpcode;
            const key_js: *JSString = blk: {
                if (key_v.isString()) break :blk @ptrCast(@alignCast(key_v.asString()));
                var key_buf: [64]u8 = undefined;
                const tmp = computedKeyToString(key_v, &key_buf);
                break :blk realm.heap.allocateString(tmp) catch return error.OutOfMemory;
            };
            const key_slice = key_js.flatBytes();
            const had_own = obj.hasOwn(key_slice);
            if (!had_own and !obj.extensible) {
                const ex = try makeTypeError(realm, "Cannot define property on non-extensible object");
                return .{ .thrown = ex };
            }
            if (had_own) {
                const cur = obj.flagsFor(key_slice);
                if (!cur.configurable) {
                    const ex = try makeTypeError(realm, "Cannot redefine non-configurable property");
                    return .{ .thrown = ex };
                }
                // Append-only shadow shape can't express a slot
                // drop; demote so the next write rebuilds.
                obj.demoteFromShape(allocator) catch return error.OutOfMemory;
                _ = obj.properties.swapRemove(key_slice);
                _ = obj.property_flags.swapRemove(key_slice);
            }
            realm.heap.storePropertyWithFlags(obj, allocator, key_slice, acc, object_mod.PropertyFlags.default) catch return error.OutOfMemory;
            obj.key_anchors.append(allocator, key_js) catch return error.OutOfMemory;
            continue :dispatch try decodeNext(code, &ip, &committed);
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
                    const r = try proxyDeleteTrap(allocator, realm, frames, f, ip, obj_in, key_s.flatBytes(), key_v);
                    switch (r) {
                        .value => |v| {
                            // §13.5.1.2 step 6 — strict-mode
                            // `delete` of a Reference must throw
                            // TypeError when [[Delete]] returns
                            // false. Cynic is strict-only.
                            if (!arith.toBoolean(v)) {
                                const ex = try makeTypeError(realm, "Cannot delete property");
                                f.ip = ip;
                                f.accumulator = acc;
                                committed = true;
                                if (!try unwindThrow(allocator, realm, frames, ex)) {
                                    return .{ .thrown = ex };
                                }
                                continue :dispatch try reEnterDispatch(frames, &f, &local_chunk, &code, &registers, &ip, &acc, &committed);
                            }
                            acc = v;
                            continue :dispatch try decodeNext(code, &ip, &committed);
                        },
                        .fallthrough => |t| {
                            const outcome = try deleteOwnProperty(realm, heap_mod.taggedObject(t), key_s.flatBytes());
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
                                    continue :dispatch try reEnterDispatch(frames, &f, &local_chunk, &code, &registers, &ip, &acc, &committed);
                                },
                            }
                            continue :dispatch try decodeNext(code, &ip, &committed);
                        },
                        .handled => {
                            committed = true;
                            continue :dispatch try reEnterDispatch(frames, &f, &local_chunk, &code, &registers, &ip, &acc, &committed);
                        },
                        .uncaught => |ex| return .{ .thrown = ex },
                    }
                }
            }
            const outcome = try deleteOwnProperty(realm, recv, key_s.flatBytes());
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
                    continue :dispatch try reEnterDispatch(frames, &f, &local_chunk, &code, &registers, &ip, &acc, &committed);
                },
            }
            continue :dispatch try decodeNext(code, &ip, &committed);
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
                    continue :dispatch try reEnterDispatch(frames, &f, &local_chunk, &code, &registers, &ip, &acc, &committed);
                },
                .uncaught => |ex| return .{ .thrown = ex },
            };
            var key_buf: [64]u8 = undefined;
            const key_slice = computedKeyToString(key_v, &key_buf);
            if (heap_mod.valueAsPlainObject(recv)) |obj_in| {
                if (obj_in.proxy_target != null or obj_in.proxy_revoked) {
                    const r = try proxyDeleteTrap(allocator, realm, frames, f, ip, obj_in, key_slice, key_v);
                    switch (r) {
                        .value => |v| {
                            if (!arith.toBoolean(v)) {
                                const ex = try makeTypeError(realm, "Cannot delete property");
                                f.ip = ip;
                                f.accumulator = acc;
                                committed = true;
                                if (!try unwindThrow(allocator, realm, frames, ex)) {
                                    return .{ .thrown = ex };
                                }
                                continue :dispatch try reEnterDispatch(frames, &f, &local_chunk, &code, &registers, &ip, &acc, &committed);
                            }
                            acc = v;
                            // proxy `deleteProperty` trap ran inline —
                            // active frame unchanged → decodeNext.
                            continue :dispatch try decodeNext(code, &ip, &committed);
                        },
                        .fallthrough => |t| {
                            const outcome = try deleteOwnProperty(realm, heap_mod.taggedObject(t), key_slice);
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
                                    continue :dispatch try reEnterDispatch(frames, &f, &local_chunk, &code, &registers, &ip, &acc, &committed);
                                },
                            }
                            // Active frame unchanged → decodeNext.
                            continue :dispatch try decodeNext(code, &ip, &committed);
                        },
                        .handled => {
                            committed = true;
                            continue :dispatch try reEnterDispatch(frames, &f, &local_chunk, &code, &registers, &ip, &acc, &committed);
                        },
                        .uncaught => |ex| return .{ .thrown = ex },
                    }
                }
            }
            const outcome = try deleteOwnProperty(realm, recv, key_slice);
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
                    continue :dispatch try reEnterDispatch(frames, &f, &local_chunk, &code, &registers, &ip, &acc, &committed);
                },
            }
            continue :dispatch try decodeNext(code, &ip, &committed);
        },

        // ── Environments / closures ─────────────────────────────────
        .make_environment => {
            const slot_count = code[ip];
            ip += 1;
            const env = realm.heap.allocateEnvironment(f.env, slot_count) catch return error.OutOfMemory;
            f.env = env;
            continue :dispatch try decodeNext(code, &ip, &committed);
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
            continue :dispatch try decodeNext(code, &ip, &committed);
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
            realm.heap.storeEnvSlot(env.?, slot, acc);
            continue :dispatch try decodeNext(code, &ip, &committed);
        },

        // ── Exceptions ──────────────────────────────────────────────
        .throw_ => {
            f.ip = ip;
            f.accumulator = acc;
            committed = true;
            if (!try unwindThrow(allocator, realm, frames, acc)) {
                return .{ .thrown = acc };
            }
            // unwindThrow popped to (and repositioned) the handler
            // frame — the active frame changed. reEnterDispatch
            // reloads it; decodeNext would keep the dead frame.
            continue :dispatch try reEnterDispatch(frames, &f, &local_chunk, &code, &registers, &ip, &acc, &committed);
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
                // unwindThrow repositioned the active frame → reEnterDispatch.
                continue :dispatch try reEnterDispatch(frames, &f, &local_chunk, &code, &registers, &ip, &acc, &committed);
            }
            continue :dispatch try decodeNext(code, &ip, &committed);
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
                // unwindThrow repositioned to a handler frame —
                // reEnterDispatch reloads it; decodeNext would keep
                // the dead frame.
                continue :dispatch try reEnterDispatch(frames, &f, &local_chunk, &code, &registers, &ip, &acc, &committed);
            }
            continue :dispatch try decodeNext(code, &ip, &committed);
        },
        .throw_assign_const => {
            // §8.1.1.1.4 SetMutableBinding step 9.b — write to
            // an immutable binding throws TypeError. Currently
            // emitted only for store-to-import paths the parser
            // can't reject as `assignment_to_const` (e.g. via
            // destructuring patterns). `let { foo: imported }
            // = obj` lands here, as does `[imported] = arr`.
            const ex = try makeTypeError(realm, "Assignment to constant variable");
            f.ip = ip;
            f.accumulator = acc;
            committed = true;
            if (!try unwindThrow(allocator, realm, frames, ex)) {
                return .{ .thrown = ex };
            }
            // unwindThrow repositioned the active frame → reEnterDispatch.
            continue :dispatch try reEnterDispatch(frames, &f, &local_chunk, &code, &registers, &ip, &acc, &committed);
        },
        .throw_if_not_object => {
            // §7.2.5 IsObject — pass plain objects and callable
            // Functions; reject every primitive. Emitted after
            // each `await_` inside async `yield*` to enforce
            // §27.6.3.7 step 7.b.iv: after Awaiting the inner
            // iter-step result, if its Type is not Object then
            // throw a TypeError. A manually implemented async
            // iterator that returns `42` from `.next()` fulfils
            // the await with `42`; we then reject the outer step
            // (Number.prototype.then must NOT be consulted —
            // §27.7.5.3 PromiseResolve step 7 short-circuits
            // for non-Object resolutions before the `Get(.then)`
            // lookup in step 8).
            const is_object =
                heap_mod.valueAsPlainObject(acc) != null or
                heap_mod.valueAsFunction(acc) != null;
            if (!is_object) {
                const ex = try makeTypeError(realm, "iterator result is not an object");
                f.ip = ip;
                f.accumulator = acc;
                committed = true;
                if (!try unwindThrow(allocator, realm, frames, ex)) {
                    return .{ .thrown = ex };
                }
                // unwindThrow repositioned the active frame → reEnterDispatch.
                continue :dispatch try reEnterDispatch(frames, &f, &local_chunk, &code, &registers, &ip, &acc, &committed);
            }
            continue :dispatch try decodeNext(code, &ip, &committed);
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
                        continue :dispatch try reEnterDispatch(frames, &f, &local_chunk, &code, &registers, &ip, &acc, &committed);
                    },
                    .uncaught => |ex| return .{ .thrown = ex },
                }
            }
            continue :dispatch try decodeNext(code, &ip, &committed);
        },

        // ── ES2026 explicit-resource-management — `using` ──────────
        .alloc_dispose_stack => {
            // §13.2.4.6 BlockStatement Runtime Semantics —
            // allocate the engine-internal DisposableStack
            // that backs a block's `using` decls.
            // `[[DisposableState]] = pending`, empty
            // `[[DisposeCapability]]`. The object is not a
            // user-visible DisposableStack instance (no
            // prototype, no `[[Symbol.dispose]]`); it lives
            // only in this register and never reaches user JS.
            const r_dst = code[ip];
            ip += 1;
            const stack = realm.heap.allocateObject() catch return error.OutOfMemory;
            // No prototype — the runtime treats `null` proto
            // as the engine-internal record.
            stack.setDisposableState(realm.allocator, .sync_pending) catch return error.OutOfMemory;
            registers[r_dst] = heap_mod.taggedObject(stack);
            continue :dispatch try decodeNext(code, &ip, &committed);
        },

        .register_using => {
            // §13.2.4.6 + §9.5.3 AddDisposableResource — append
            // the resource in `r_value` to the dispose stack
            // in `r_stack`. `value` is null/undefined → no-op.
            // Otherwise GetDisposeMethod(value, hint) reads
            // Symbol.dispose (hint=0) or Symbol.asyncDispose
            // (hint=1, with fallback to Symbol.dispose); a
            // missing or non-callable method throws TypeError
            // AT THIS SITE per §14.3.x early-error behaviour.
            const r_stack = code[ip];
            const r_value = code[ip + 1];
            const hint_byte = code[ip + 2];
            ip += 3;
            const stack_v = registers[r_stack];
            const value_v = registers[r_value];
            const stack_obj = heap_mod.valueAsPlainObject(stack_v) orelse {
                // Should never happen — alloc_dispose_stack
                // wrote a fresh object.
                return error.InvalidOpcode;
            };
            const ds_mod = @import("../builtins/disposable_stack.zig");
            const hint: object_mod.DisposableHint = if (hint_byte == 1) .async_dispose else .sync_dispose;
            ds_mod.addDisposableResource(realm, stack_obj, value_v, hint) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.NativeThrew => {
                    const ex = consumePendingException(realm) orelse try makeTypeError(realm, "register_using failed");
                    f.ip = ip;
                    f.accumulator = acc;
                    committed = true;
                    if (!try unwindThrow(allocator, realm, frames, ex)) {
                        return .{ .thrown = ex };
                    }
                    continue :dispatch try reEnterDispatch(frames, &f, &local_chunk, &code, &registers, &ip, &acc, &committed);
                },
            };
            continue :dispatch try decodeNext(code, &ip, &committed);
        },

        .dispose_stack => {
            // §13.2.4.6 BlockStatement Runtime Semantics +
            // §9.5.4 DisposeResources — walk the dispose stack
            // in REVERSE (LIFO) and invoke each resource's
            // `[[DisposeMethod]]` with `this = resource`. A
            // mid-disposal throw while another throw is in
            // flight wraps via SuppressedError per spec.
            //
            // mode:
            //   0 — normal-completion arm. `acc` carries a
            //       stashed value (return value, fall-through
            //       expression-statement result); we preserve
            //       it across the walk. A disposer throw
            //       surfaces as an outgoing throw.
            //   1 — throw-completion arm. `acc` holds the in-
            //       flight throw; the walk uses it as the
            //       pending completion. After the walk, `acc`
            //       holds either the original throw (no
            //       disposer raised) or a SuppressedError
            //       chain. Surrounding bytecode then `throw_`s
            //       (mode 1 doesn't surface the throw itself
            //       so the compiler can also emit follow-up
            //       cleanup like iter_close between dispose
            //       and the rethrow).
            const r_stack = code[ip];
            const mode = code[ip + 1];
            ip += 2;
            const stack_v = registers[r_stack];
            const stack_obj = heap_mod.valueAsPlainObject(stack_v) orelse {
                return error.InvalidOpcode;
            };
            const ds_mod = @import("../builtins/disposable_stack.zig");
            const saved_acc = acc;
            stack_obj.setDisposableState(realm.allocator, .sync_disposed) catch return error.OutOfMemory;
            const existing: ?Value = if (mode == 1) acc else null;
            _ = ds_mod.disposeResourcesWithCompletion(realm, stack_obj, existing) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.NativeThrew => {
                    // A throw surfaced from the walk. In mode
                    // 1 we leak it back into `acc` (so the
                    // surrounding `throw_` rethrows it); in
                    // mode 0 we unwind through the dispatcher
                    // so any enclosing handler picks it up.
                    const ex = consumePendingException(realm) orelse try makeTypeError(realm, "dispose_stack: unexpected dispose throw");
                    if (mode == 1) {
                        acc = ex;
                        continue :dispatch try decodeNext(code, &ip, &committed);
                    }
                    f.ip = ip;
                    f.accumulator = acc;
                    committed = true;
                    if (!try unwindThrow(allocator, realm, frames, ex)) {
                        return .{ .thrown = ex };
                    }
                    continue :dispatch try reEnterDispatch(frames, &f, &local_chunk, &code, &registers, &ip, &acc, &committed);
                },
            };
            // No disposer throw surfaced. In mode 0 restore
            // the stashed acc. In mode 1 the throw was a
            // no-op in disposers (none threw), so the original
            // throw (still in `acc` from before the call) is
            // re-emitted by the surrounding `throw_`.
            acc = saved_acc;
            continue :dispatch try decodeNext(code, &ip, &committed);
        },

        .dispose_stack_async => {
            // §13.2.4.6 + §9.5.4 — async sibling of
            // `dispose_stack`, emitted by blocks that contain
            // at least one `await using` declaration. Returns
            // a Promise in `acc`; the compiler emits an
            // `await` opcode immediately after to suspend.
            //
            // mode:
            //   0 — normal completion. The Promise rejects
            //       with the first disposer throw (or a
            //       SuppressedError chain if multiple throw).
            //   1 — throw completion. `acc` holds the
            //       in-flight throw on entry; the walk seeds
            //       its `pending_error` so a clean walk
            //       preserves the original throw and a
            //       disposer throw wraps via SuppressedError.
            //       The Promise either resolves with undefined
            //       (clean walk — surrounding bytecode re-
            //       throws the saved `acc`) or rejects with
            //       the SuppressedError chain.
            const r_stack = code[ip];
            const mode = code[ip + 1];
            ip += 2;
            const stack_v = registers[r_stack];
            const stack_obj = heap_mod.valueAsPlainObject(stack_v) orelse {
                return error.InvalidOpcode;
            };
            const ads_mod = @import("../builtins/async_disposable_stack.zig");
            stack_obj.setDisposableState(realm.allocator, .async_disposed) catch return error.OutOfMemory;
            const promise_v: Value = if (mode == 1) blk: {
                const existing = acc;
                const p = ads_mod.startAsyncDisposeWalkWithExisting(realm, stack_obj, existing) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    else => {
                        const ex = consumePendingException(realm) orelse try makeTypeError(realm, "dispose_stack_async: unexpected throw");
                        f.ip = ip;
                        f.accumulator = acc;
                        committed = true;
                        if (!try unwindThrow(allocator, realm, frames, ex)) {
                            return .{ .thrown = ex };
                        }
                        continue :dispatch try reEnterDispatch(frames, &f, &local_chunk, &code, &registers, &ip, &acc, &committed);
                    },
                };
                break :blk p;
            } else blk: {
                const p = ads_mod.startAsyncDisposeWalkPublic(realm, stack_obj) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    else => {
                        const ex = consumePendingException(realm) orelse try makeTypeError(realm, "dispose_stack_async: unexpected throw");
                        f.ip = ip;
                        f.accumulator = acc;
                        committed = true;
                        if (!try unwindThrow(allocator, realm, frames, ex)) {
                            return .{ .thrown = ex };
                        }
                        continue :dispatch try reEnterDispatch(frames, &f, &local_chunk, &code, &registers, &ip, &acc, &committed);
                    },
                };
                break :blk p;
            };
            acc = promise_v;
            continue :dispatch try decodeNext(code, &ip, &committed);
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
            // §10.2.2 [[Construct]] steps 7-11: the return-value
            // coercion and the uninitialized-`this` gate happen
            // *after* the callee's execution context has been
            // popped. That ordering is observable — a user
            // try/catch inside the body must NOT catch the
            // synthetic TypeError / ReferenceError that those
            // steps raise. We compute the verdict here, then
            // pop the frame, then dispatch the throw against
            // the caller stack.
            //
            // Possible verdicts:
            //   .normal: hand `ret` back to the caller.
            //   .type_error: derived ctor returned a non-Object
            //                non-undefined (step 7c).
            //   .ref_error:  derived ctor returned undefined
            //                without calling super (step 11 →
            //                §9.1.1.3.4 GetThisBinding).
            const Verdict = enum { normal, type_error, ref_error };
            var verdict: Verdict = .normal;
            if (f.is_construct) {
                const returned_object =
                    heap_mod.valueAsPlainObject(acc) != null or
                    heap_mod.valueAsFunction(acc) != null;
                // Merge any cross-`runFrames` super-call flip
                // tracked through `super_called_cell` (e.g. an
                // arrow performed `super(...)` from inside
                // iterator close `return()` during the for-of
                // unwind — that call ran in a separate
                // `runFrames` invocation so the direct frame
                // walk in `.super_call` couldn't see us).
                if (f.super_called_cell) |cell| {
                    if (cell.*) f.super_called = true;
                }
                if (!returned_object) {
                    if (f.is_derived_ctor and !acc.isUndefined()) {
                        // §10.2.2 step 7c — derived ctors must
                        // return either an Object or undefined.
                        // null / number / string / bool /
                        // symbol / bigint all trip the gate.
                        verdict = .type_error;
                    } else if (f.is_derived_ctor and !f.super_called) {
                        // §10.2.2 step 11 → §9.1.1.3.4
                        // GetThisBinding — `this` is still
                        // uninitialized because `super(...)`
                        // never executed.
                        verdict = .ref_error;
                    } else {
                        // §10.2.2 step 7b — base ctor (or
                        // derived ctor after super) returning
                        // a non-Object falls back to the
                        // initialized `this`.
                        ret = f.this_value;
                    }
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
            // `registers` is `f.registers` aliased earlier in the
            // dispatch loop; `releaseRegisters` reads `f.registers`
            // directly, so this is the same slice.
            f.releaseRegisters(realm, allocator);
            _ = frames.pop();
            committed = true;
            // §10.2.2 [[Construct]] steps 7c / 11 — raise the
            // derived-ctor exception against the *caller* of
            // the constructor. The callee's frame is already
            // popped, so unwindThrow won't see the body's own
            // try/catch handlers (the spec runs steps 7-11
            // after popping the execution context).
            if (verdict != .normal) {
                const ex = switch (verdict) {
                    .type_error => try makeTypeError(realm, "Derived constructors may only return object or undefined"),
                    .ref_error => try makeReferenceError(realm, "Must call super constructor in derived class before returning from derived constructor"),
                    .normal => unreachable,
                };
                if (frames.items.len == 0) {
                    return .{ .thrown = ex };
                }
                if (!try unwindThrow(allocator, realm, frames, ex)) {
                    return .{ .thrown = ex };
                }
                continue :dispatch try reEnterDispatch(frames, &f, &local_chunk, &code, &registers, &ip, &acc, &committed);
            }
            if (frames.items.len == 0) {
                return .{ .value = ret };
            }
            frames.items[frames.items.len - 1].accumulator = ret;
            continue :dispatch try reEnterDispatch(frames, &f, &local_chunk, &code, &registers, &ip, &acc, &committed);
        },
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
/// §9.1.1.4 GetBindingValue — object env-record fallback for
/// accessor properties installed on the globalThis object
/// (e.g. `Object.defineProperty(globalThis, "x", {get: …})`).
/// `lda_global` / `lda_global_or_undef` consult this AFTER the
/// declarative + data-property check fails, so a getter on
/// globalThis fires when user code reads `x` (or `typeof x`)
/// as a bare identifier. Returns `null` if no accessor is
/// installed; the caller decides between ReferenceError
/// (lda_global) and undefined (lda_global_or_undef).
pub const GlobalAccessorLookup = union(enum) {
    /// No accessor installed for `key` anywhere on the global
    /// object's prototype chain.
    none,
    /// Accessor fired (or setter-only short-circuit) — value is
    /// the result of the getter call.
    value: Value,
    /// Accessor's getter threw; the exception is already in
    /// `realm.pending_exception`. The caller surfaces it via the
    /// normal `unwindThrow` path so handler-walk semantics hold.
    thrown: Value,
};
fn lookupGlobalAccessor(
    allocator: std.mem.Allocator,
    realm: *Realm,
    key: []const u8,
) RunError!GlobalAccessorLookup {
    const gt = realm.globals.target orelse return .none;
    var cur: ?*JSObject = gt;
    while (cur) |o| {
        if (o.getAccessor(key)) |acc| {
            if (acc.getter) |getter| {
                const outcome = try callJSFunction(allocator, realm, getter, heap_mod.taggedObject(gt), &[_]Value{});
                switch (outcome) {
                    .value, .yielded => |v| return .{ .value = v },
                    .thrown => |ex| return .{ .thrown = ex },
                }
            }
            // Setter-only accessor → undefined per §10.1.8.1.
            return .{ .value = Value.undefined_ };
        }
        cur = o.prototype;
    }
    return .none;
}

pub fn unwindThrow(
    allocator: std.mem.Allocator,
    realm: *Realm,
    frames: *std.ArrayListUnmanaged(CallFrame),
    exception: Value,
) RunError!bool {
    const current_ex = exception;
    // §27.5.1.3 — while a generator is being driven through its
    // pending finallys with a return-completion (set up by
    // `genReturn`), step past user `catch` clauses and stop
    // only at synthetic finally handlers. Catching a Return
    // completion in a user `catch (e) { … }` would observe an
    // internal sentinel as `e`, which the spec forbids. The
    // flag is read once per unwind; once we *land* on a finally
    // handler, the finally body runs without the flag set
    // (cleared below) — its own throws / returns are normal
    // user code and must use normal handler-walk semantics.
    const return_mode = realm.gen_return_completion != null;
    while (frames.items.len > 0) {
        const frame = &frames.items[frames.items.len - 1];
        for (frame.chunk.handlers) |h| {
            if (frame.ip > h.start_pc and frame.ip <= h.end_pc) {
                if (return_mode and !h.is_finally) continue;
                frame.ip = h.handler_pc;
                if (h.catch_register) |slot| {
                    // catch param lives in the current
                    // function's env slot (the compiler stored
                    // its env_slot in `catch_register`). Always
                    // depth=0 because the catch scope is in the
                    // same function as the try.
                    if (frame.env) |env| {
                        // Routed through `storeEnvSlot` so the
                        // write barrier records a mature catch
                        // scope receiving a young exception value.
                        if (slot < env.slots.len)
                            realm.heap.storeEnvSlot(env, slot, current_ex);
                    }
                    frame.accumulator = Value.undefined_;
                } else {
                    frame.accumulator = current_ex;
                }
                // Clear the return-completion flag once we've
                // landed on a finally — the finally body runs
                // as normal user code from here. The synth
                // handler's `lda + throw_` at the body's end
                // re-throws the saved value; `resumeGenerator`
                // recognises the rethrown sentinel and
                // surfaces `.value` instead of `.thrown`.
                if (return_mode) realm.gen_return_completion = null;
                return true;
            }
        }
        // No handler in this frame. If this is an async-wrapped
        // frame, the throw becomes the rejection value of the
        // Promise we hand back — never escapes the function.
        if (frame.wrap_return_in_promise) {
            const rejected = wrapInPromise(realm, false, current_ex) catch return error.OutOfMemory;
            frame.releaseRegisters(realm, allocator);
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
        frame.releaseRegisters(realm, allocator);
        _ = frames.pop();
    }
    return false;
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

fn deleteOwnProperty(realm: *Realm, recv: Value, key: []const u8) error{OutOfMemory}!DeleteResult {
    const obj_mod = @import("../object.zig");
    if (heap_mod.valueAsPlainObject(recv)) |obj| {
        // §23.1.4 — an array exotic's `length` is the virtual,
        // non-configurable own slot (never in the bag, so the
        // ordinary missing-key path below would wrongly succeed).
        if (obj.isVirtualLengthKey(key)) {
            return .{ .throw_typeerror = "Cannot delete non-configurable property" };
        }
        // A property removal cannot be expressed as a shape
        // transition (the transition tree is append-only), so
        // demote the object to the dictionary representation —
        // back-fills `properties` from `slots` per Phase 3 of
        // [docs/lazy-property-bag.md].
        try obj.demoteFromShape(realm.allocator);
        // §9.4.6.6 Module Namespace [[Delete]]. Symbol keys
        // (Cynic's flattened `@@toStringTag` / `<sym:*>`) fall
        // through to OrdinaryDelete — `@@toStringTag` was
        // installed non-configurable so the ordinary path rejects
        // it. Any string key that's an export name is permanent;
        // [[Delete]] returns false, which strict-mode `delete`
        // surfaces as TypeError. Non-exported keys (never installed
        // on the namespace) take the missing-key `true` branch
        // below — `delete ns.undef` must succeed.
        if (obj.is_module_namespace and !std.mem.startsWith(u8, key, "@@") and !std.mem.startsWith(u8, key, "<sym:") and obj.hasOwn(key)) {
            return .{ .throw_typeerror = "Cannot delete module namespace export" };
        }
        // §10.4.5.6 [[Delete]] for Integer-Indexed Exotic Objects.
        // CanonicalNumericIndexString(P) of "-0", "1.5", "-1",
        // "Infinity" etc. produces a non-undefined numericIndex. Any
        // such key is intercepted here BEFORE OrdinaryDelete. Per
        // ES2024 align-detached-buffer-semantics: a non-
        // IsValidIntegerIndex form returns true (silently succeeds);
        // a valid index returns false (the slot is permanent →
        // TypeError under strict-mode `delete`). Non-canonical
        // numeric keys (e.g. "1.0", "+1", "0.0000001") fall through
        // to OrdinaryDelete, which lets the ordinary property bag
        // surface them normally.
        if (obj.getTypedView()) |tv| {
            const ta_mod = @import("../builtins/typed_array.zig");
            if (ta_mod.canonicalNumericIndex(key)) |num| {
                if (!ta_mod.isValidIntegerIndexPub(tv, num)) return .{ .ok = true };
                return .{ .throw_typeerror = "Cannot delete TypedArray index property" };
            }
        }
        // Accessor descriptor — accessors store their own
        // configurable bit in `property_flags` keyed by the
        // accessor name. If absent we treat as configurable=true
        // (default), since later only writes flag entries for
        // non-default descriptors.
        if (obj.hasAccessor(key)) {
            const flags = obj.flagsFor(key);
            if (!flags.configurable) return .{ .throw_typeerror = "Cannot delete non-configurable property" };
            _ = obj.removeAccessor(key);
            _ = obj.property_flags.swapRemove(key);
            // §10.1.11 — drop the slot from the unified order list
            // unless the data half also exists (it shouldn't —
            // OrdinaryDefineOwnProperty wipes one when the other
            // is installed — but be defensive).
            if (!obj.ownDataContains(key)) obj.forgetKey(key);
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
                if (!try obj.deleteOwn(realm.allocator, key)) return .{ .throw_typeerror = "Cannot delete non-configurable property" };
                return .{ .ok = true };
            }
        }
        // Data property.
        if (!obj.ownDataContains(key)) return .{ .ok = true };
        const flags = obj.flagsFor(key);
        if (!flags.configurable) return .{ .throw_typeerror = "Cannot delete non-configurable property" };
        // Demote: shape can't express a removal — back-fill the
        // bag (Phase 3) so the swapRemove below has the entry.
        try obj.demoteFromShape(realm.allocator);
        _ = obj.properties.swapRemove(key);
        _ = obj.property_flags.swapRemove(key);
        if (!obj.hasAccessor(key)) obj.forgetKey(key);
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
            if (!fn_obj.ownDataContains(key)) fn_obj.forgetKey(key);
            return .{ .ok = true };
        }
        // Removing `name` clears the dedicated slot; removing
        // `length` drops the param-count fallback path entirely
        // (subsequent `hasOwn("length")` returns false). Removing
        // `prototype` clears the dedicated slot.
        if (std.mem.eql(u8, key, "name")) {
            fn_obj.name = null;
            realm.heap.setFunctionNameString(fn_obj, null);
        }
        if (std.mem.eql(u8, key, "prototype")) realm.heap.setFunctionPrototype(fn_obj, null);
        _ = fn_obj.properties.swapRemove(key);
        _ = fn_obj.property_flags.swapRemove(key);
        if (!fn_obj.accessors.contains(key)) fn_obj.forgetKey(key);
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
/// §10.4.2.4 ArraySetLength for the strict [[Set]] slow path —
/// outlined so the (cold) length-write machinery doesn't sit inline
/// in `strictSetPropertyAnchored`. The caller gates on the receiver
/// being an array exotic with key "length"; per §10.1.9.2 step 2 the
/// own (virtual) data slot wins BEFORE any prototype walk, so this
/// runs ahead of the proxy [[Set]] walk and the accessor climb.
noinline fn strictArraySetLength(
    allocator: std.mem.Allocator,
    realm: *Realm,
    frames: *std.ArrayListUnmanaged(CallFrame),
    f: *CallFrame,
    ip: usize,
    obj: *JSObject,
    value: Value,
) RunError!SetOutcome {
    // Check the existing length is writable. If a prior
    // `Object.defineProperty(arr, "length", {writable:false})`
    // froze it, any future length-write must throw.
    if (!obj.array_length_writable) {
        const ex = try makeTypeError(realm, "Cannot assign to read-only property 'length'");
        return throwInSetter(realm, frames, f, ip, value, ex);
    }
    // §10.4.2.4 ArraySetLength — drives two observable
    // ToNumber calls (step 3 via ToUint32, step 4 standalone).
    // A user-side valueOf / toString throw surfaces via
    // `error.NativeThrew` + `realm.pending_exception`; we
    // translate that into the strict-set's setter throw path.
    const coerce_result = arrayLengthCoerceSpec(realm, value) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.NativeThrew => {
            const ex = realm.pending_exception orelse try makeTypeError(realm, "ToPrimitive failed");
            realm.pending_exception = null;
            return throwInSetter(realm, frames, f, ip, value, ex);
        },
    };
    const new_len = coerce_result orelse {
        const ex = try makeRangeError(realm, "Invalid array length");
        return throwInSetter(realm, frames, f, ip, value, ex);
    };
    // Re-check writability AFTER the coercion — a user
    // valueOf may have flipped `length: { writable: false }`
    // between the two ToNumber calls (§10.4.2.4 step 17.b
    // gates the actual write on the *current* writability,
    // not the pre-coercion state).
    if (!obj.array_length_writable) {
        const ex = try makeTypeError(realm, "Cannot assign to read-only property 'length'");
        return throwInSetter(realm, frames, f, ip, value, ex);
    }
    const truncate_result = truncateArrayAtLength(allocator, obj, new_len);
    const final_len = truncate_result.final_length;
    // §10.4.2.4 ArraySetLength step 16 — write the final
    // length THROUGH the array-exotic storage so the indexed
    // backing matches. `setArrayLength` calls
    // `ensureElementsLen` on grow (so the virtual length —
    // which tracks the indexed storage — reads as the new
    // value immediately) and is a
    // no-op truncate on shrink (the descending walk above
    // already cleared the slots up to `final_len`).
    obj.setArrayLength(allocator, final_len) catch return error.OutOfMemory;
    if (truncate_result.blocked) {
        const ex = try makeTypeError(realm, "Cannot delete non-configurable array index");
        return throwInSetter(realm, frames, f, ip, value, ex);
    }
    return .ok;
}

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
        // §9.4.6.4 Module Namespace exotic [[Set]] — always
        // returns false, which under strict-mode assignment
        // becomes a TypeError. The brand wins before any
        // proxy / accessor / descriptor logic so that
        // `Reflect.set(ns, ...)` reads false and `ns.x = v`
        // throws.
        if (obj_in.is_module_namespace) {
            const ex = try makeTypeError(realm, "Cannot assign to read-only module namespace property");
            return throwInSetter(realm, frames, f, ip, value, ex);
        }
        // §10.1.9.2 step 2 — the array exotic's own (virtual) `length`
        // wins before any prototype walk; see `strictArraySetLength`.
        if (obj_in.is_array_exotic and std.mem.eql(u8, key, "length")) {
            return strictArraySetLength(allocator, realm, frames, f, ip, obj_in, value);
        }
        // §10.5 Proxy [[Set]] — if `recv` is a proxy exotic,
        // dispatch through `handler.set` before falling back to
        // the target's default setter logic. Loops so that a
        // trapless proxy whose target is itself a proxy keeps
        // dispatching down the chain (§10.5.6 step 7.a recurses
        // into target.[[Set]]).
        var obj = obj_in;
        const receiver_is_proxy = obj_in.proxy_target != null or obj_in.proxy_target_fn != null or obj_in.proxy_revoked;
        // Every Proxy `[[Set]]` path below — the `set` trap loop, the
        // trapless GetOwnPropertyDescriptor / DefineProperty pair —
        // re-enters JS and can GC. `key` is borrowed from `key_string`
        // for a computed-key set (`o[expr] = v`), and the post-trap
        // invariant checks (`nativeProxySet` reads
        // `target.property_flags.get(key)`) would then hash a dangling
        // slice and miss. Root `key_string` / `value` / `recv` for the
        // whole proxy path; gated on `receiver_is_proxy` so a plain
        // object set pays nothing.
        const px_root_scope: ?*@import("../heap.zig").HandleScope = if (receiver_is_proxy) blk: {
            const sc = realm.heap.openScope() catch return error.OutOfMemory;
            if (key_string) |ks| sc.push(Value.fromString(ks)) catch return error.OutOfMemory;
            sc.push(value) catch return error.OutOfMemory;
            sc.push(recv) catch return error.OutOfMemory;
            break :blk sc;
        } else null;
        defer if (px_root_scope) |sc| sc.close();
        while (obj.proxy_target != null or obj.proxy_target_fn != null or obj.proxy_revoked) {
            // §10.5.9 [[Set]] on a callable Proxy whose `[[ProxyTarget]]`
            // is a function (`proxy_target_fn`). The trap, if present,
            // fires with the function as the spec-target arg; absent,
            // the spec says `Return ? target.[[Set]](P, V, Receiver)`,
            // which for a function is OrdinarySet — write through
            // `setIfWritable` and translate a false return to a
            // strict-mode TypeError. Without this branch the bytecode
            // loop exits the moment it reaches a callable proxy and
            // the post-loop default-receiver path silently creates the
            // property on the outer proxy. See test262
            // built-ins/Proxy/set/trap-is-undefined-target-is-proxy.js.
            if (obj.proxy_target == null and obj.proxy_target_fn != null and !obj.proxy_revoked) {
                const handler = obj.proxy_handler orelse {
                    const ex = try makeTypeError(realm, "proxy handler slot is null");
                    f.ip = ip;
                    if (!try unwindThrow(allocator, realm, frames, ex)) return .{ .uncaught = ex };
                    return .handled;
                };
                const trap_v = handler.get("set");
                if (!trap_v.isUndefined() and !trap_v.isNull()) {
                    const trap_fn = heap_mod.valueAsFunction(trap_v) orelse {
                        const ex = try makeTypeError(realm, "Proxy 'set' trap is not callable");
                        f.ip = ip;
                        if (!try unwindThrow(allocator, realm, frames, ex)) return .{ .uncaught = ex };
                        return .handled;
                    };
                    const key_hint_v: ?Value = if (key_string) |ks| Value.fromString(ks) else null;
                    const key_v_t = try proxyTrapKeyValue(realm, key, key_hint_v);
                    const trap_args = [_]Value{ heap_mod.taggedFunction(obj.proxy_target_fn.?), key_v_t, value, recv };
                    const trap_outcome = try callJSFunction(allocator, realm, trap_fn, heap_mod.taggedObject(handler), &trap_args);
                    switch (trap_outcome) {
                        .value, .yielded => |trap_ret| {
                            if (!arith.toBoolean(trap_ret)) {
                                const ex = try makeTypeError(realm, "'set' on proxy returned falsy");
                                f.ip = ip;
                                if (!try unwindThrow(allocator, realm, frames, ex)) return .{ .uncaught = ex };
                                return .handled;
                            }
                            return .ok;
                        },
                        .thrown => |ex| {
                            f.ip = ip;
                            if (!try unwindThrow(allocator, realm, frames, ex)) return .{ .uncaught = ex };
                            return .handled;
                        },
                    }
                }
                // Trap missing — §10.5.9 step 7.a: `Return ?
                // target.[[Set]](P, V, Receiver)`. The target is the
                // function; OrdinarySet writes through `setIfWritable`.
                const fn_target = obj.proxy_target_fn.?;
                const owned_k_fn = realm.heap.allocateString(key) catch return error.OutOfMemory;
                const ok = realm.heap.storeFunctionPropertyIfWritable(fn_target, allocator, owned_k_fn.flatBytes(), value) catch return error.OutOfMemory;
                if (!ok) {
                    const ex = try makeTypeError(realm, "Cannot assign to read-only property");
                    f.ip = ip;
                    if (!try unwindThrow(allocator, realm, frames, ex)) return .{ .uncaught = ex };
                    return .handled;
                }
                return .ok;
            }
            const key_hint_v: ?Value = if (key_string) |ks| Value.fromString(ks) else null;
            const r = try proxySetTrap(allocator, realm, frames, f, ip, obj, key, key_hint_v, value, recv);
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
        // §10.4.5.6 IntegerIndexedExoticSet — when any ancestor of
        // `obj` is a TypedArray and `key` is a CanonicalNumericIndex
        // String, the TA's [[Set]] intercepts the inherited write
        // BEFORE any TA.prototype accessor or receiver-side
        // defineProperty trap fires. `!IsValidIntegerIndex(O, num)`
        // (with `recv` differing from the TA) short-circuits to step
        // 2.b.ii: return true, no coercion, no further write. The
        // valid-index + different-receiver case falls through to the
        // ordinary receiver-side write below — `lookupAccessor`
        // already treats canonical-numeric keys as data-shadowing
        // at the TA rung, so the accessor path won't fire.
        const ta_decision = typedArrayChainSetDecision(obj, key, recv);
        if (ta_decision.decision == .short_circuit) return .ok;
        if (ta_decision.decision == .coerce_and_write) {
            const ta_mod = @import("../builtins/typed_array.zig");
            const tv0 = ta_decision.ta.?.getTypedView() orelse return .ok;
            const coerced = ta_mod.coerceForTypedSlot(realm, tv0.kind, value) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.NativeThrew => {
                    const ex = realm.pending_exception orelse try makeTypeError(realm, "TypedArray element type-coercion failed");
                    realm.pending_exception = null;
                    return throwInSetter(realm, frames, f, ip, value, ex);
                },
            };
            const live_tv = ta_decision.ta.?.getTypedView() orelse return .ok;
            if (ta_mod.isValidIntegerIndexPub(live_tv, ta_decision.num)) {
                const buf = live_tv.viewed.getArrayBuffer().?;
                const elem_size = live_tv.kind.elementSize();
                const idx: usize = @intFromFloat(ta_decision.num);
                @import("../intrinsics.zig").writeTypedElementForView(buf, live_tv, live_tv.byte_offset + idx * elem_size, coerced);
            }
            return .ok;
        }
        // For `.ordinary_set`, fall through to the existing receiver-
        // side write path. For `.not_applicable`, identical fall-through.
        // §10.5.6 step 7.a fall-through — `target.[[Set]](P, V,
        // Receiver)`. When Receiver is a Proxy (recv differs from
        // the walked-to target), the spec composition
        // OrdinarySetWithOwnDescriptor lands on
        // `Receiver.[[DefineOwnProperty]]`, which fires the
        // `defineProperty` trap on the Proxy. Route through
        // `objectDefineProperty` for the data-desc branch so the
        // trap observes the defineProperty call. Accessor
        // descriptors on the target still need their setter to
        // fire with Receiver as this — fall through to the
        // accessor walk below for that case.
        if (receiver_is_proxy and obj != obj_in) {
            // `key` / `value` / `recv` are kept rooted by
            // `px_root_scope` above for the whole proxy path.
            const has_own_data = obj.ownDataContains(key);
            const has_own_acc = obj.hasAccessor(key);
            if (has_own_data and !has_own_acc) {
                const flags = obj.flagsFor(key);
                if (!flags.writable) {
                    const ex = try makeTypeError(realm, "Cannot assign to read-only property");
                    return throwInSetter(realm, frames, f, ip, value, ex);
                }
                // §10.1.9.2 step 3.c — existingDescriptor =
                // Receiver.[[GetOwnProperty]](P). Fires the proxy's
                // `getOwnPropertyDescriptor` trap as a side effect.
                const obj_mod = @import("../builtins/object.zig");
                const key_owned_gop = realm.heap.allocateString(key) catch return error.OutOfMemory;
                const gop_args = [_]Value{ recv, Value.fromString(key_owned_gop) };
                _ = obj_mod.objectGetOwnPropertyDescriptor(realm, Value.undefined_, &gop_args) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    error.NativeThrew => {
                        const ex = realm.pending_exception orelse try makeTypeError(realm, "getOwnPropertyDescriptor trap failed");
                        realm.pending_exception = null;
                        return throwInSetter(realm, frames, f, ip, value, ex);
                    },
                };
                // §10.1.9.2 step 3.d.iv — Receiver.[[DefineOwnProperty]](P, {Value: V}).
                const desc_obj = realm.heap.allocateObject() catch return error.OutOfMemory;
                realm.heap.setObjectPrototype(desc_obj, realm.intrinsics.object_prototype);
                const key_owned = realm.heap.allocateString(key) catch return error.OutOfMemory;
                realm.heap.storeProperty(desc_obj, allocator, "value", value) catch return error.OutOfMemory;
                const dp_args = [_]Value{ recv, Value.fromString(key_owned), heap_mod.taggedObject(desc_obj) };
                _ = obj_mod.objectDefineProperty(realm, Value.undefined_, &dp_args) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    error.NativeThrew => {
                        const ex = realm.pending_exception orelse try makeTypeError(realm, "defineProperty trap failed");
                        realm.pending_exception = null;
                        return throwInSetter(realm, frames, f, ip, value, ex);
                    },
                };
                return .ok;
            }
            // No own descriptor on target — §10.1.9.2 step 2 says
            // recurse on parent. For now, fall through to a
            // CreateDataProperty on Receiver = proxy via the GOPD +
            // defineProperty pair so both traps observe each call.
            if (!has_own_data and !has_own_acc) {
                const obj_mod = @import("../builtins/object.zig");
                const key_owned_gop = realm.heap.allocateString(key) catch return error.OutOfMemory;
                const gop_args = [_]Value{ recv, Value.fromString(key_owned_gop) };
                _ = obj_mod.objectGetOwnPropertyDescriptor(realm, Value.undefined_, &gop_args) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    error.NativeThrew => {
                        const ex = realm.pending_exception orelse try makeTypeError(realm, "getOwnPropertyDescriptor trap failed");
                        realm.pending_exception = null;
                        return throwInSetter(realm, frames, f, ip, value, ex);
                    },
                };
                const desc_obj = realm.heap.allocateObject() catch return error.OutOfMemory;
                realm.heap.setObjectPrototype(desc_obj, realm.intrinsics.object_prototype);
                const key_owned = realm.heap.allocateString(key) catch return error.OutOfMemory;
                realm.heap.storeProperty(desc_obj, allocator, "value", value) catch return error.OutOfMemory;
                realm.heap.storeProperty(desc_obj, allocator, "writable", Value.true_) catch return error.OutOfMemory;
                realm.heap.storeProperty(desc_obj, allocator, "enumerable", Value.true_) catch return error.OutOfMemory;
                realm.heap.storeProperty(desc_obj, allocator, "configurable", Value.true_) catch return error.OutOfMemory;
                const dp_args = [_]Value{ recv, Value.fromString(key_owned), heap_mod.taggedObject(desc_obj) };
                _ = obj_mod.objectDefineProperty(realm, Value.undefined_, &dp_args) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    error.NativeThrew => {
                        const ex = realm.pending_exception orelse try makeTypeError(realm, "defineProperty trap failed");
                        realm.pending_exception = null;
                        return throwInSetter(realm, frames, f, ip, value, ex);
                    },
                };
                return .ok;
            }
        }
        // §10.1.9.2 OrdinarySetWithOwnDescriptor step 2 — if no own
        // descriptor exists, recurse into `parent.[[Set]](P, V,
        // Receiver)`. When a parent is a Proxy, that fires its set
        // trap (or recurses again per §10.5.6 step 7.a). Check the
        // chain for a proxy ancestor and route through it,
        // preserving the original `recv` as Receiver.
        if (obj.proxy_target == null and !obj.proxy_revoked and chainHasProxy(obj)) {
            switch (try setThroughChain(allocator, realm, frames, f, ip, obj, key, value, recv)) {
                .handled_set => |ok| {
                    if (ok) return .ok;
                    // Walk consumed the proxies; fall through to
                    // ordinary set on `recv` for receiver-side write.
                },
                .handled_or_uncaught => |out| return out,
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
                if (idx <= 0xFFFFFFFE and !obj.ownDataContains(key)) {
                    if (!obj.array_length_writable) {
                        {
                            const cur_len: u32 = obj.arrayLength();
                            if (idx >= cur_len) {
                                const ex = try makeTypeError(realm, "Cannot extend non-writable array length");
                                return throwInSetter(realm, frames, f, ip, value, ex);
                            }
                        }
                    }
                    // §10.4.2.1 [[DefineOwnProperty]] for Array exotic —
                    // adding a NEW indexed slot on a non-extensible
                    // array is the §10.1.6.3 OrdinaryDefineOwnProperty
                    // step-2 reject (extensibility check). Strict
                    // assignment surfaces it as TypeError.
                    if (!obj.extensible and !obj.hasOwnIndexedSlot(idx)) {
                        const ex = try makeTypeError(realm, "Cannot add property, object is not extensible");
                        return throwInSetter(realm, frames, f, ip, value, ex);
                    }
                    realm.heap.storeElement(obj, allocator, idx, value) catch return error.OutOfMemory;
                    return .ok;
                }
            }
        }
        // Fast path that also anchors the key's backing JSString
        // when the caller supplied one. Necessary because
        // `properties` stores `[]const u8` slices, not pointers,
        // so a heap-allocated key gets swept without the anchor.
        const had_entry = obj.ownDataContains(key);
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
            realm.heap.storeInternalSlot(.{ .object = obj }, value);
            // Route through `setWithFlags` so shape-mode receivers
            // keep their slot authoritative (Phase 3 of
            // [docs/lazy-property-bag.md]); the bag is updated
            // automatically when shadowSet can't absorb.
            obj.setWithFlags(allocator, key, value, flags) catch return error.OutOfMemory;
        } else {
            // §10.1.9.2 OrdinarySetWithOwnDescriptor step 2 —
            // when no own descriptor exists, the spec walks
            // `parent.[[Set]]`. For an ordinary parent, that
            // bottoms out at OrdinarySetWithOwnDescriptor with
            // `existingDescriptor = parent.[[GetOwnProperty]](P)`:
            // a non-writable data descriptor on any ancestor
            // surfaces as a strict-mode TypeError on the
            // receiver-side write (test262
            // language/expressions/assignment/8.14.4-8-b_2.js).
            if (!had_indexed) {
                var cursor: ?*JSObject = obj.prototype;
                while (cursor) |p| : (cursor = p.prototype) {
                    if (p.hasAccessor(key)) break; // accessor already handled above
                    if (p.ownDataContains(key)) {
                        const p_flags = p.flagsFor(key);
                        if (!p_flags.writable) {
                            const ex = try makeTypeError(realm, "Cannot assign to read-only property");
                            return throwInSetter(realm, frames, f, ip, value, ex);
                        }
                        break;
                    }
                }
            }
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
                realm.heap.storePropertyComputedOwned(obj, allocator, ks, value) catch return error.OutOfMemory;
            } else {
                realm.heap.storeProperty(obj, allocator, key, value) catch return error.OutOfMemory;
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
        // §10.1.9.2 OrdinarySetWithOwnDescriptor — a write that
        // would add a new own property on a non-extensible
        // function (e.g. after `Object.preventExtensions(fn)`)
        // must fail; strict-mode assignment surfaces that as a
        // TypeError per §10.1.9.1 step 4. Cynic's JSFunction
        // carries its own `extensible` slot (flipped by
        // `Object.preventExtensions(fn)` in
        // `objectPreventExtensions`).
        const had_fn_entry = fn_obj.ownDataContains(key);
        if (!had_fn_entry and !fn_obj.extensible) {
            const ex = try makeTypeError(realm, "Cannot add property, object is not extensible");
            return throwInSetter(realm, frames, f, ip, value, ex);
        }
        const ok = realm.heap.storeFunctionPropertyIfWritable(fn_obj, allocator, key, value) catch return error.OutOfMemory;
        if (!ok) {
            const ex = try makeTypeError(realm, "Cannot assign to read-only property");
            return throwInSetter(realm, frames, f, ip, value, ex);
        }
        // A `fn[expr] = v` write stores the key as a borrowed
        // `bytes` slice; anchor the heap-allocated key JSString on
        // the function so GC keeps the slice alive. Only on first
        // insertion — re-writes to an existing key reuse the anchor.
        if (!had_fn_entry) {
            if (key_string) |ks| {
                fn_obj.key_anchors.append(allocator, ks) catch return error.OutOfMemory;
            }
        }
        return .ok;
    }
    // §6.2.5.6 PutValue step 5 — when the Reference's base is a
    // primitive (string / number / bigint / boolean / symbol),
    // `HasPrimitiveBase(V)` is true: `base` is set to
    // `ToObject(base)` and `[[Set]]` runs with `GetThisValue(V)`
    // — the *original primitive* — as the Receiver. The transient
    // wrapper has no own properties, so OrdinarySetWithOwnDescriptor
    // recurses straight into `<Prototype>.[[Set]]` (§10.1.9.2 step
    // 2). Walk that prototype chain with `setThroughChain`, keeping
    // the primitive as `recv`: an accessor / Proxy ancestor handles
    // the write (test262 language/types/reference/
    // put-value-prop-base-primitive.js installs a `set`-trapping
    // Proxy as `Number.prototype`'s prototype). A clean walk with no
    // descriptor bottoms out at a receiver-side CreateDataProperty
    // on the primitive, which returns false — strict assignment then
    // throws TypeError per §6.2.5.6 step 5.c.
    if (primitiveWrapperPrototype(realm, recv)) |proto_obj| {
        switch (try setThroughChain(allocator, realm, frames, f, ip, proto_obj, key, value, recv)) {
            .handled_set => |ok| {
                if (ok) return .ok;
                // No accessor / writable-data descriptor on the
                // chain: the receiver-side write targets a
                // primitive and fails. Strict mode → TypeError.
                const ex = try makeTypeError(realm, "Cannot create property on primitive value");
                return throwInSetter(realm, frames, f, ip, value, ex);
            },
            .handled_or_uncaught => |out| return out,
        }
    }
    const ex = try makeTypeError(realm, "Cannot set properties of non-object");
    return throwInSetter(realm, frames, f, ip, value, ex);
}

/// §7.1.18 ToObject for a primitive — returns the `[[Prototype]]`
/// object of the transient wrapper that `ToObject` would build for
/// `v` (i.e. `<Type>.prototype`), or `null` when `v` is not a
/// primitive with a wrapper type (objects, functions, null,
/// undefined). The wrapper itself carries no own properties, so
/// callers that only need to walk the wrapper's prototype chain
/// (e.g. §6.2.5.6 PutValue with a primitive base) can start here.
fn primitiveWrapperPrototype(realm: *Realm, v: Value) ?*JSObject {
    const ctor_name: []const u8 = if (v.isString())
        "String"
    else if (v.isInt32() or v.isDouble())
        "Number"
    else if (v.isBool())
        "Boolean"
    else if (heap_mod.isBigInt(v))
        "BigInt"
    else if (heap_mod.isSymbol(v))
        "Symbol"
    else
        return null;
    const ctor_fn = heap_mod.valueAsFunction(realm.globals.get(ctor_name) orelse return null) orelse return null;
    return ctor_fn.prototype;
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

/// True iff any ancestor of `obj` on its prototype chain is a
/// Proxy exotic (including a revoked proxy or a callable proxy
/// whose target lives in `proxy_target_fn`). Used by `lda_property`
/// and `lda_computed_property` to detect when a normal proto-chain
/// walk would silently bypass a Proxy `get` trap installed on an
/// ancestor.
fn chainHasProxy(obj: *JSObject) bool {
    var cursor: ?*JSObject = obj;
    while (cursor) |c| : (cursor = c.prototype) {
        if (c.proxy_target != null or c.proxy_target_fn != null or c.proxy_revoked) return true;
    }
    return false;
}

/// §10.4.5.6 IntegerIndexedExoticSet decision for the prototype-
/// chain walk. When any ancestor of `obj` is a TypedArray and `key`
/// is a CanonicalNumericIndexString, the IIE `[[Set]]` short-circuits
/// the inherited-accessor / defineProperty paths. Returns:
///   - `not_applicable` — no TA ancestor, or key isn't a canonical
///     numeric string; caller continues with ordinary walk.
///   - `coerce_and_write` — `recv` is the TA itself (SameValue
///     case, §10.4.5.6 step 2.b.i.1). Caller runs SetTypedArrayElement
///     (ToNumber/ToBigInt + maybe write).
///   - `short_circuit` — TA ancestor present, !IsValidIntegerIndex,
///     `recv` differs from the TA (§10.4.5.6 step 2.b.ii). [[Set]]
///     returns true with no coercion, no write — must not fire any
///     accessor on TA.prototype, nor any receiver-side defineProperty.
///   - `ordinary_set` — TA ancestor present, valid integer index,
///     `recv` differs (§10.4.5.6 step 3). Falls through to OrdinarySet
///     on Receiver; the TA's IIE [[GetOwnProperty]] hides the receiver-
///     side write from any TA.prototype accessor (no coercion).
const TAChainSetDecision = enum {
    not_applicable,
    coerce_and_write,
    short_circuit,
    ordinary_set,
};

const TAChainSetResult = struct {
    decision: TAChainSetDecision,
    ta: ?*JSObject = null,
    num: f64 = 0,
};

fn typedArrayChainSetDecision(obj: *JSObject, key: []const u8, recv: Value) TAChainSetResult {
    const ta_mod = @import("../builtins/typed_array.zig");
    const num = ta_mod.canonicalNumericIndex(key) orelse return .{ .decision = .not_applicable };
    var cursor: ?*JSObject = obj;
    while (cursor) |c| : (cursor = c.prototype) {
        if (c.getTypedView()) |tv| {
            const recv_obj = heap_mod.valueAsPlainObject(recv);
            const same_receiver = (recv_obj == c);
            if (same_receiver) {
                return .{ .decision = .coerce_and_write, .ta = c, .num = num };
            }
            if (!ta_mod.isValidIntegerIndexPub(tv, num)) {
                return .{ .decision = .short_circuit, .ta = c, .num = num };
            }
            return .{ .decision = .ordinary_set, .ta = c, .num = num };
        }
    }
    return .{ .decision = .not_applicable };
}

const GetChainOutcome = union(enum) {
    value: Value,
    handled,
    uncaught: Value,
};

const LdaGlobalSlowOutcome = union(enum) {
    /// Resolved synchronously (object-env slot, decl-env value,
    /// accessor returning a value, or bootstrap fallback hit).
    value: Value,
    /// A user function (proxy / accessor getter) ran inline and
    /// the helper already arranged the dispatch state for a
    /// caught throw. Caller must `reEnterDispatch` without
    /// re-stamping `f.ip`.
    handled,
    /// Uncaught exception — propagate.
    uncaught: Value,
    /// No binding for the name. Caller decides:
    ///   • `lda_global` → ReferenceError.
    ///   • `lda_global_or_undef` → `undefined`.
    not_found,
};

/// Slow path of `lda_global` / `lda_global_or_undef`. Pulled out
/// of the dispatch loop to keep each handler tight (better i-cache
/// over the giant switch) and to dedupe the receiver-type matrix
/// the two opcodes share. Fills `ic_cell` on a shape-resolvable
/// object-env hit; leaves the cell alone on decl-env / fallback /
/// accessor paths so they keep re-walking the slow path until the
/// shape becomes the authoritative source.
fn slowLdaGlobal(
    allocator: std.mem.Allocator,
    realm: *Realm,
    frames: *std.ArrayListUnmanaged(CallFrame),
    f: *CallFrame,
    ip: usize,
    gr: *Realm,
    key: []const u8,
    ic_cell: *@import("../../bytecode/chunk.zig").ICCell,
) RunError!LdaGlobalSlowOutcome {
    // §9.1.1.4 GetBindingValue — declarative env-record FIRST.
    // A decl-env hit MUST shadow the cached object-env slot; that's
    // why we don't fill `ic_cell` on this path. Subsequent calls
    // pay the small `decl_env.get` cost, which the
    // `decl_revision` snapshot guarantees stays in sync.
    if (gr.globals.decl_env.get(key)) |v| return .{ .value = v };
    if (gr.globals.target) |gt| {
        // Shape lookup — the common case for host-installed
        // intrinsics (`Math`, `Object`, …) and top-level
        // `function` / `var` declarations (added through
        // `installScriptFunctionBinding` / `installScriptVarBinding`,
        // which route through `setWithFlags` / `shadowSet` and
        // stamp the shape).
        if (gt.shape) |sh| {
            if (sh.lookup(key)) |entry| {
                if (entry.kind == .data) {
                    ic_cell.shape = sh;
                    ic_cell.slot = entry.slot;
                    ic_cell.proto = null;
                    ic_cell.proto_shape = null;
                    ic_cell.proto_rev = gr.globals.decl_revision;
                    return .{ .value = gt.slotAt(entry.slot) };
                }
            }
        }
        // Shape miss / dictionary mode / accessor descriptor.
        if (gt.lookupOwn(key)) |v| return .{ .value = v };
        switch (try lookupGlobalAccessor(allocator, gr, key)) {
            .value => |v| return .{ .value = v },
            .thrown => |ex| {
                f.ip = ip;
                if (!try unwindThrow(allocator, realm, frames, ex)) return .{ .uncaught = ex };
                return .handled;
            },
            .none => return .not_found,
        }
    }
    // Pre-`bindToObject` bootstrap — `target` not yet wired.
    if (gr.globals.fallback.get(key)) |v| return .{ .value = v };
    switch (try lookupGlobalAccessor(allocator, gr, key)) {
        .value => |v| return .{ .value = v },
        .thrown => |ex| {
            f.ip = ip;
            if (!try unwindThrow(allocator, realm, frames, ex)) return .{ .uncaught = ex };
            return .handled;
        },
        .none => return .not_found,
    }
}

/// §13.3.6 EvaluateCall + §10.1.8 OrdinaryGet — resolve the callee
/// for the fused `call_property` opcode's slow path. Mirrors
/// `lda_property`'s 11-arm receiver-type matrix (plain object,
/// function, string, int / double, bool, bigint, symbol, plus the
/// proxy / module-namespace / chainHasProxy edge cases and the
/// non-coercible `null` / `undefined` throw) and routes the
/// resolved value through a `GetChainOutcome` instead of the
/// dispatch loop's accumulator.
///
/// Pairs with the `.lda_property` slow path in the dispatch loop —
/// any new receiver-type arm added there must be mirrored here.
/// The decision not to fold the two into one shared helper is
/// pragmatic: `lda_property` is the engine's hottest opcode and
/// folding would require threading the dispatch-loop locals
/// (`acc`, `committed`, `code`, `registers`, `local_chunk`)
/// through every arm.
fn slowLookupForCallProperty(
    allocator: std.mem.Allocator,
    realm: *Realm,
    frames: *std.ArrayListUnmanaged(CallFrame),
    f: *CallFrame,
    ip: usize,
    recv: Value,
    key: []const u8,
) RunError!GetChainOutcome {
    // §13.3.4.1 EvaluatePropertyAccessWithIdentifierKey step 5 —
    // RequireObjectCoercible(baseValue) before the lookup.
    if (recv.isNull() or recv.isUndefined()) {
        const ex = try makeTypeError(realm, "Cannot read properties of null or undefined");
        f.ip = ip;
        if (!try unwindThrow(allocator, realm, frames, ex)) return .{ .uncaught = ex };
        return .handled;
    }
    if (heap_mod.valueAsPlainObject(recv)) |obj_in| {
        var obj = obj_in;
        // §10.5 Proxy [[Get]].
        if (obj.proxy_target != null or obj.proxy_revoked) {
            const r = try proxyGetTrap(allocator, realm, frames, f, ip, obj, key, null, recv);
            switch (r) {
                .value => |v| return .{ .value = v },
                .fallthrough => |t| obj = t,
                .handled => return .handled,
                .uncaught => |ex| return .{ .uncaught = ex },
            }
        }
        // §9.4.6.7 Module Namespace [[Get]] — string-key path.
        if (obj.is_module_namespace and !std.mem.startsWith(u8, key, "@@") and !std.mem.startsWith(u8, key, "<sym:")) {
            const v_ns = module_mod.namespaceGetThrowingOnHole(realm, obj, key) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.NativeThrew => {
                    const ex = realm.pending_exception orelse Value.undefined_;
                    realm.pending_exception = null;
                    f.ip = ip;
                    if (!try unwindThrow(allocator, realm, frames, ex)) return .{ .uncaught = ex };
                    return .handled;
                },
            };
            return .{ .value = v_ns };
        }
        // §10.1.8 OrdinaryGet — a proxy ancestor anywhere on the
        // chain forces the explicit `Receiver`-preserving walk so
        // the proxy's [[Get]] fires with the original `recv`.
        if (chainHasProxy(obj)) {
            switch (try getThroughChain(allocator, realm, frames, f, ip, obj, key, recv)) {
                .value => |v| return .{ .value = v },
                .handled => return .handled,
                .uncaught => |ex| return .{ .uncaught = ex },
            }
        }
        // Accessor wins over inherited data.
        if (lookupAccessor(obj, key)) |acc_pair| {
            if (acc_pair.getter) |getter| {
                if (getter.synth_accessor) |sa| {
                    if (!sa.is_setter) return .{ .value = sa.value };
                }
                const outcome = try callJSFunction(allocator, realm, getter, recv, &.{});
                switch (outcome) {
                    .value, .yielded => |v| return .{ .value = v },
                    .thrown => |ex| {
                        f.ip = ip;
                        if (!try unwindThrow(allocator, realm, frames, ex)) return .{ .uncaught = ex };
                        return .handled;
                    },
                }
            }
            return .{ .value = Value.undefined_ };
        }
        return .{ .value = obj.get(key) };
    }
    if (heap_mod.valueAsFunction(recv)) |fn_obj| {
        // §10.2.4 — `.caller` / `.arguments` are poison-pill
        // accessors on %Function.prototype% inherited by every
        // function object.
        if (lookupFunctionAccessor(fn_obj, key)) |acc_pair| {
            if (acc_pair.getter) |getter| {
                if (getter.synth_accessor) |sa| {
                    if (!sa.is_setter) return .{ .value = sa.value };
                }
                const outcome = try callJSFunction(allocator, realm, getter, recv, &.{});
                switch (outcome) {
                    .value, .yielded => |v| return .{ .value = v },
                    .thrown => |ex| {
                        f.ip = ip;
                        if (!try unwindThrow(allocator, realm, frames, ex)) return .{ .uncaught = ex };
                        return .handled;
                    },
                }
            }
            return .{ .value = Value.undefined_ };
        }
        return .{ .value = fn_obj.get(key) };
    }
    if (recv.isString()) {
        // §6.1.4.4 — String primitive: .length (UTF-16 code units),
        // numeric-index char access, inherited String.prototype.
        const recv_s: *JSString = @ptrCast(@alignCast(recv.asString()));
        if (std.mem.eql(u8, key, "length")) {
            return .{ .value = Value.fromInt32(@intCast(utf16.lengthInCodeUnits(recv_s.flatBytes()))) };
        }
        if (realm.intrinsics.string_prototype) |sp| {
            if (lookupAccessor(sp, key)) |acc_pair| {
                if (acc_pair.getter) |getter| {
                    const outcome = try callJSFunction(allocator, realm, getter, recv, &.{});
                    switch (outcome) {
                        .value, .yielded => |v| return .{ .value = v },
                        .thrown => |ex| {
                            f.ip = ip;
                            if (!try unwindThrow(allocator, realm, frames, ex)) return .{ .uncaught = ex };
                            return .handled;
                        },
                    }
                }
                return .{ .value = Value.undefined_ };
            }
            return .{ .value = sp.get(key) };
        }
        return .{ .value = Value.undefined_ };
    }
    if (recv.isInt32() or recv.isDouble()) {
        return primitiveProtoLookupForCall(allocator, realm, frames, f, ip, recv, key, (f.running_realm orelse realm).globals.get("Number") orelse Value.undefined_);
    }
    if (recv.isBool()) {
        return primitiveProtoLookupForCall(allocator, realm, frames, f, ip, recv, key, (f.running_realm orelse realm).globals.get("Boolean") orelse Value.undefined_);
    }
    if (heap_mod.isBigInt(recv)) {
        return primitiveProtoLookupForCall(allocator, realm, frames, f, ip, recv, key, (f.running_realm orelse realm).globals.get("BigInt") orelse Value.undefined_);
    }
    if (heap_mod.isSymbol(recv)) {
        return primitiveProtoLookupForCall(allocator, realm, frames, f, ip, recv, key, (f.running_realm orelse realm).globals.get("Symbol") orelse Value.undefined_);
    }
    const ex = try makeTypeError(realm, "Cannot read properties of non-object");
    f.ip = ip;
    if (!try unwindThrow(allocator, realm, frames, ex)) return .{ .uncaught = ex };
    return .handled;
}

/// Shared tail of the Number / Boolean / BigInt / Symbol arms in
/// `slowLookupForCallProperty` — read the ctor's `.prototype`, look
/// up an accessor (firing the getter with the primitive as `this`),
/// else fall back to the prototype's own / inherited data property.
fn primitiveProtoLookupForCall(
    allocator: std.mem.Allocator,
    realm: *Realm,
    frames: *std.ArrayListUnmanaged(CallFrame),
    f: *CallFrame,
    ip: usize,
    recv: Value,
    key: []const u8,
    ctor_v: Value,
) RunError!GetChainOutcome {
    const ctor = heap_mod.valueAsFunction(ctor_v) orelse return .{ .value = Value.undefined_ };
    const proto = ctor.prototype orelse return .{ .value = Value.undefined_ };
    if (lookupAccessor(proto, key)) |acc_pair| {
        if (acc_pair.getter) |getter| {
            const outcome = try callJSFunction(allocator, realm, getter, recv, &.{});
            switch (outcome) {
                .value, .yielded => |v| return .{ .value = v },
                .thrown => |ex| {
                    f.ip = ip;
                    if (!try unwindThrow(allocator, realm, frames, ex)) return .{ .uncaught = ex };
                    return .handled;
                },
            }
        }
        return .{ .value = Value.undefined_ };
    }
    return .{ .value = proto.get(key) };
}

/// §10.1.8 OrdinaryGet over a prototype chain that includes at
/// least one Proxy ancestor. Walks the chain rung by rung: on a
/// proxy ancestor dispatches `[[Get]]` with `receiver` unchanged
/// (per §10.1.8.1 step 4.b); on an ordinary ancestor looks up own
/// accessor / data slot, returning early on a hit. Returning
/// `undefined` matches the spec's "no descriptor found" terminus.
fn getThroughChain(
    allocator: std.mem.Allocator,
    realm: *Realm,
    frames: *std.ArrayListUnmanaged(CallFrame),
    f: *CallFrame,
    ip: usize,
    obj: *JSObject,
    key: []const u8,
    receiver: Value,
) RunError!GetChainOutcome {
    var cursor: ?*JSObject = obj;
    while (cursor) |c| {
        if (c.proxy_target != null or c.proxy_revoked) {
            // §10.5.5 Proxy [[Get]] — dispatch with `receiver`,
            // not the proxy itself. The trap helper already
            // recurses through proxy-target-is-proxy chains.
            switch (try proxyGetTrap(allocator, realm, frames, f, ip, c, key, null, receiver)) {
                .value => |v| return .{ .value = v },
                .fallthrough => |t| {
                    // Trapless proxy whose target is non-proxy —
                    // continue the OrdinaryGet walk starting at
                    // the target (step 7.a's recursion). Re-enter
                    // this loop on `t` without advancing prototype.
                    cursor = t;
                    continue;
                },
                .handled => return .handled,
                .uncaught => |ex| return .{ .uncaught = ex },
            }
        }
        // Callable proxy (target is a function held in
        // `proxy_target_fn`) — trapless reads forward to the
        // function target. We don't have a trap-dispatch entry
        // point for this case yet (the helper would need to
        // operate over Values not *JSObject), so apply the §10.5.5
        // step 7.a fallthrough directly when no handler.get is
        // installed.
        if (c.proxy_target_fn) |target_fn| {
            const handler_opt = c.proxy_handler;
            const trap_v = if (handler_opt) |h| h.get("get") else Value.undefined_;
            if (trap_v.isUndefined() or trap_v.isNull()) {
                // Forward to the function target's own get.
                return .{ .value = target_fn.get(key) };
            }
            // Trap installed — dispatch with `target_fn` as the
            // first arg (proxy target value).
            const trap_fn = heap_mod.valueAsFunction(trap_v) orelse {
                const ex = try makeTypeError(realm, "Proxy 'get' trap is not callable");
                f.ip = ip;
                if (!try unwindThrow(allocator, realm, frames, ex)) return .{ .uncaught = ex };
                return .handled;
            };
            const key_str = realm.heap.allocateString(key) catch return error.OutOfMemory;
            const args = [_]Value{ heap_mod.taggedFunction(target_fn), Value.fromString(key_str), receiver };
            const outcome = try callJSFunction(allocator, realm, trap_fn, heap_mod.taggedObject(handler_opt.?), &args);
            switch (outcome) {
                .value, .yielded => |v| return .{ .value = v },
                .thrown => |ex| {
                    f.ip = ip;
                    if (!try unwindThrow(allocator, realm, frames, ex)) return .{ .uncaught = ex };
                    return .handled;
                },
            }
        }
        if (c.getAccessor(key)) |acc| {
            if (acc.getter) |getter| {
                const out = try callJSFunction(allocator, realm, getter, receiver, &.{});
                switch (out) {
                    .value, .yielded => |v| return .{ .value = v },
                    .thrown => |ex| {
                        f.ip = ip;
                        if (!try unwindThrow(allocator, realm, frames, ex)) return .{ .uncaught = ex };
                        return .handled;
                    },
                }
            }
            return .{ .value = Value.undefined_ };
        }
        if (c.is_array_exotic) {
            if (@import("../object.zig").JSObject.canonicalIntegerIndex(key)) |idx| {
                if (c.tryGetIndexedOwn(idx)) |v| return .{ .value = v };
            }
        }
        if (c.lookupOwn(key)) |v| return .{ .value = v };
        cursor = c.prototype;
    }
    return .{ .value = Value.undefined_ };
}

/// Outcome of `setThroughChain` — either the chain dispatched the
/// write and we should bypass the ordinary trailing path, or the
/// helper found nothing on the chain and the caller should fall
/// through to the receiver-side write.
const SetChainOutcome = union(enum) {
    /// `true` — chain handled the write (returned ok); caller stops.
    /// `false` — chain walked clean past every proxy with no
    /// descriptor; caller falls through to ordinary set on `recv`.
    handled_set: bool,
    /// Caller propagates the outcome (trap threw / unhandled).
    handled_or_uncaught: SetOutcome,
};

/// §10.1.9.2 OrdinarySetWithOwnDescriptor — walks the prototype
/// chain of `obj` (which is itself not a Proxy) looking for the
/// first own descriptor for `key`. When a Proxy ancestor is hit,
/// dispatches its `[[Set]]` with `recv` as Receiver; an ordinary
/// own data / accessor descriptor on a non-proxy ancestor is
/// handled inline. The trailing "create or update on receiver"
/// step is left to the caller (signalled via `.handled_set =
/// false`).
fn setThroughChain(
    allocator: std.mem.Allocator,
    realm: *Realm,
    frames: *std.ArrayListUnmanaged(CallFrame),
    f: *CallFrame,
    ip: usize,
    obj: *JSObject,
    key: []const u8,
    value: Value,
    recv: Value,
) RunError!SetChainOutcome {
    var cursor: ?*JSObject = obj;
    while (cursor) |c| {
        if (c.proxy_target != null or c.proxy_revoked) {
            switch (try proxySetTrap(allocator, realm, frames, f, ip, c, key, null, value, recv)) {
                .value => return .{ .handled_set = true },
                .fallthrough => |t| {
                    // The proxy is trapless and target is non-proxy.
                    // Continue OrdinaryGet-style walk from `t`.
                    cursor = t;
                    continue;
                },
                .handled => return .{ .handled_or_uncaught = .handled },
                .uncaught => |ex| return .{ .handled_or_uncaught = .{ .uncaught = ex } },
            }
        }
        // §10.1.9.2 — own accessor wins.
        if (c.getAccessor(key)) |acc| {
            if (acc.setter) |setter| {
                const args = [_]Value{value};
                const outcome = try callJSFunction(allocator, realm, setter, recv, &args);
                switch (outcome) {
                    .value, .yielded => return .{ .handled_set = true },
                    .thrown => |ex| {
                        f.ip = ip;
                        if (!try unwindThrow(allocator, realm, frames, ex)) {
                            return .{ .handled_or_uncaught = .{ .uncaught = ex } };
                        }
                        return .{ .handled_or_uncaught = .handled };
                    },
                }
            }
            // Getter-only accessor — strict-mode throws.
            const ex = try makeTypeError(realm, "Cannot set property which has only a getter");
            f.ip = ip;
            if (!try unwindThrow(allocator, realm, frames, ex)) {
                return .{ .handled_or_uncaught = .{ .uncaught = ex } };
            }
            return .{ .handled_or_uncaught = .handled };
        }
        // Own data prop with writable: false — §10.1.9.2 step 3.a
        // short-circuits to "set returns false" / strict throws.
        if (c.ownDataContains(key)) {
            const flags = c.flagsFor(key);
            if (!flags.writable) {
                const ex = try makeTypeError(realm, "Cannot assign to read-only property");
                f.ip = ip;
                if (!try unwindThrow(allocator, realm, frames, ex)) {
                    return .{ .handled_or_uncaught = .{ .uncaught = ex } };
                }
                return .{ .handled_or_uncaught = .handled };
            }
            // Writable own data — break out; caller writes on recv.
            return .{ .handled_set = false };
        }
        if (c.is_array_exotic) {
            if (@import("../object.zig").JSObject.canonicalIntegerIndex(key)) |idx| {
                if (c.tryGetIndexedOwn(idx) != null) {
                    // Writable by default; let caller handle the
                    // receiver-side write.
                    return .{ .handled_set = false };
                }
            }
        }
        // §10.4.5.5 Integer-Indexed Exotic Object [[Set]] step 2.b —
        // when the cursor is a typed-array AND the key is a canonical
        // numeric index in-bounds, the IIE's [[GetOwnProperty]]
        // (§10.4.5.4) returns a writable data descriptor for that
        // slot. That stops the proto-chain walk for accessor lookup:
        // a setter installed on a typed array's prototype (e.g.
        // `Object.defineProperty(Int32Array.prototype, 0, { set: … })`)
        // is shadowed by the typed array's own integer-indexed slot
        // and MUST NOT fire when the receiver inherits from the
        // typed array. Match `is_array_exotic` above — short-circuit
        // so the caller creates a property on the receiver instead.
        if (c.getTypedView() != null) {
            const ta_mod = @import("../builtins/typed_array.zig");
            if (ta_mod.canonicalNumericIndex(key)) |_| {
                return .{ .handled_set = false };
            }
        }
        cursor = c.prototype;
    }
    return .{ .handled_set = false };
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

/// Build the String Value passed to a Proxy trap. If `hint` is a
/// String whose flat bytes equal `key`, reuse it — the
/// constants-pool JSString an `lda_property` opcode already holds
/// — and skip a fresh `allocateString`. Symbol-key marker strings
/// (`@@iterator`, `<sym:N>`) are handled by the caller before
/// reaching here.
inline fn proxyTrapKeyValue(realm: *Realm, key: []const u8, hint: ?Value) RunError!Value {
    if (hint) |kh| {
        if (kh.isString()) {
            const s: *@import("../string.zig").JSString = @ptrCast(@alignCast(kh.asString()));
            if (std.mem.eql(u8, s.flatBytes(), key)) return kh;
        }
    }
    const key_str = realm.heap.allocateString(key) catch return error.OutOfMemory;
    return Value.fromString(key_str);
}

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
    /// Optional String Value that already backs `key` (the
    /// constants-pool JSString an `lda_property` opcode holds for
    /// a static-name read, etc.). Avoids the per-trap-fire
    /// `allocateString` that otherwise drives this hot path into
    /// the young-GC trigger — a Vue-style `o.x` proxy loop fires
    /// one `Get` trap per access, so the saved allocation is the
    /// dominant per-call cost.
    key_hint: ?Value,
    receiver: Value,
) RunError!ProxyOutcome {
    // §10.5.5 [[Get]] step 7.a — when the trap is missing, the
    // spec recurses through `target.[[Get]]`. If `target` is itself
    // a Proxy, that re-invokes Proxy [[Get]] (firing the inner
    // trap). Walk the chain here so a trapless outer proxy whose
    // target is another proxy doesn't silently bypass the inner
    // trap.
    var cur = proxy;
    while (true) {
        if (cur.proxy_revoked) {
            const ex = try makeTypeError(realm, "Cannot perform 'get' on a proxy that has been revoked");
            f.ip = ip;
            if (!try unwindThrow(allocator, realm, frames, ex)) {
                return .{ .uncaught = ex };
            }
            return .handled;
        }
        const target = cur.proxy_target orelse return .{ .fallthrough = cur };
        const handler = cur.proxy_handler orelse return .{ .fallthrough = target };
        const trap_v = handler.get("get");
        // §7.3.11 GetMethod — undefined/null fall through; any other
        // non-callable value throws TypeError before the trap runs.
        if (trap_v.isUndefined() or trap_v.isNull()) {
            if (target.proxy_target != null or target.proxy_revoked) {
                cur = target;
                continue;
            }
            return .{ .fallthrough = target };
        }
        const trap_fn = heap_mod.valueAsFunction(trap_v) orelse {
            const ex = try makeTypeError(realm, "Proxy 'get' trap is not callable");
            f.ip = ip;
            if (!try unwindThrow(allocator, realm, frames, ex)) return .{ .uncaught = ex };
            return .handled;
        };
        // §7.1.19 ToPropertyKey — symbol keys flow into the
        // trap as Symbol values, NOT as their `<sym:N>` /
        // `@@xxx` prop-key string. A bare `fromString(key)` flips
        // `typeof k === "symbol"` to `"string"` inside the
        // handler and silently loses the brand match on
        // well-known Symbols too.
        const key_v: Value = blk_kv: {
            if (std.mem.startsWith(u8, key, "@@") or std.mem.startsWith(u8, key, "<sym:")) {
                if (realm.heap.symbolForKey(key)) |sym| break :blk_kv heap_mod.taggedSymbol(sym);
            }
            break :blk_kv try proxyTrapKeyValue(realm, key, key_hint);
        };
        const args = [_]Value{ heap_mod.taggedObject(target), key_v, receiver };
        const outcome = try callJSFunction(allocator, realm, trap_fn, heap_mod.taggedObject(handler), &args);
        const v = switch (outcome) {
            .value, .yielded => |val| val,
            .thrown => |ex| {
                f.ip = ip;
                if (!try unwindThrow(allocator, realm, frames, ex)) {
                    return .{ .uncaught = ex };
                }
                return .handled;
            },
        };
        // §10.5.5 step 10 — non-configurable non-writable data
        // property must match. `flagsFor` is shape-aware under
        // Phase 3 of [docs/lazy-property-bag.md]; the prior
        // direct `property_flags.get` check missed shape-mode
        // descriptors (attrs stored on the shape transition node).
        if (target.lookupOwn(key)) |target_v| {
            const flags = target.flagsFor(key);
            if (!flags.configurable and !flags.writable) {
                if (!intrinsics_mod.sameValue(target_v, v)) {
                    const ex = try makeTypeError(realm, "proxy 'get' trap returned mismatched value for non-writable non-configurable data property");
                    f.ip = ip;
                    if (!try unwindThrow(allocator, realm, frames, ex)) return .{ .uncaught = ex };
                    return .handled;
                }
            }
        }
        // §10.5.5 step 11 — accessor with undefined getter requires
        // trap result to be undefined.
        if (target.getAccessor(key)) |acc| {
            const flags = target.flagsFor(key);
            if (!flags.configurable and acc.getter == null) {
                if (!v.isUndefined()) {
                    const ex = try makeTypeError(realm, "proxy 'get' trap returned non-undefined for non-configurable accessor with no getter");
                    f.ip = ip;
                    if (!try unwindThrow(allocator, realm, frames, ex)) return .{ .uncaught = ex };
                    return .handled;
                }
            }
        }
        return .{ .value = v };
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
    /// See `proxyGetTrap`'s `key_hint` — same reuse contract.
    key_hint: ?Value,
) RunError!ProxyOutcome {
    // §10.5.10 [[Delete]] step 7.a — when the trap is missing,
    // recurse via `target.[[Delete]]`. If `target` is itself a
    // Proxy, that re-enters Proxy [[Delete]] dispatch (firing the
    // inner trap). Walk the chain so a trapless outer proxy
    // forwards correctly.
    var cur = proxy;
    while (true) {
        if (cur.proxy_revoked) {
            const ex = try makeTypeError(realm, "Cannot perform 'deleteProperty' on a proxy that has been revoked");
            f.ip = ip;
            if (!try unwindThrow(allocator, realm, frames, ex)) {
                return .{ .uncaught = ex };
            }
            return .handled;
        }
        // For callable-target proxies (`proxy_target = null`,
        // `proxy_target_fn` set), the spec target is a JSFunction.
        // When the trap is missing we delete on the function
        // directly; when present we dispatch with the function as
        // the trap's `target` arg.
        if (cur.proxy_target == null and cur.proxy_target_fn != null) {
            const target_fn = cur.proxy_target_fn.?;
            const handler_opt = cur.proxy_handler;
            const trap_v = if (handler_opt) |h| h.get("deleteProperty") else Value.undefined_;
            if (trap_v.isUndefined() or trap_v.isNull()) {
                // §10.1.10.1 [[Delete]] on a function — non-
                // configurable own properties return false (and
                // strict-mode `delete` then throws TypeError at the
                // bytecode level). `hasOwn` covers the dedicated
                // `prototype` slot too.
                if (target_fn.hasOwn(key)) {
                    if (target_fn.flagsForOwn(key).configurable == false) {
                        return .{ .value = Value.false_ };
                    }
                }
                _ = target_fn.properties.swapRemove(key);
                _ = target_fn.accessors.swapRemove(key);
                _ = target_fn.property_flags.swapRemove(key);
                target_fn.forgetKey(key);
                return .{ .value = Value.true_ };
            }
            const trap_fn = heap_mod.valueAsFunction(trap_v) orelse {
                const ex = try makeTypeError(realm, "Proxy 'deleteProperty' trap is not callable");
                f.ip = ip;
                if (!try unwindThrow(allocator, realm, frames, ex)) return .{ .uncaught = ex };
                return .handled;
            };
            const key_v = try proxyTrapKeyValue(realm, key, key_hint);
            const args = [_]Value{ heap_mod.taggedFunction(target_fn), key_v };
            const outcome = try callJSFunction(allocator, realm, trap_fn, heap_mod.taggedObject(handler_opt.?), &args);
            const v = switch (outcome) {
                .value, .yielded => |val| val,
                .thrown => |ex| {
                    f.ip = ip;
                    if (!try unwindThrow(allocator, realm, frames, ex)) return .{ .uncaught = ex };
                    return .handled;
                },
            };
            return .{ .value = Value.fromBool(arith.toBoolean(v)) };
        }
        const target = cur.proxy_target orelse return .{ .fallthrough = cur };
        const handler = cur.proxy_handler orelse return .{ .fallthrough = target };
        const trap_v = handler.get("deleteProperty");
        if (trap_v.isUndefined() or trap_v.isNull()) {
            if (target.proxy_target != null or target.proxy_target_fn != null or target.proxy_revoked) {
                cur = target;
                continue;
            }
            return .{ .fallthrough = target };
        }
        const trap_fn = heap_mod.valueAsFunction(trap_v) orelse {
            const ex = try makeTypeError(realm, "Proxy 'deleteProperty' trap is not callable");
            f.ip = ip;
            if (!try unwindThrow(allocator, realm, frames, ex)) return .{ .uncaught = ex };
            return .handled;
        };
        const key_v = try proxyTrapKeyValue(realm, key, key_hint);
        const args = [_]Value{ heap_mod.taggedObject(target), key_v };
        const outcome = try callJSFunction(allocator, realm, trap_fn, heap_mod.taggedObject(handler), &args);
        const v = switch (outcome) {
            .value, .yielded => |val| val,
            .thrown => |ex| {
                f.ip = ip;
                if (!try unwindThrow(allocator, realm, frames, ex)) {
                    return .{ .uncaught = ex };
                }
                return .handled;
            },
        };
        const b = arith.toBoolean(v);
        if (b) {
            // §10.5.10 step 10-13 — the trap can't report success
            // when the target's own property is non-configurable,
            // and (proxy-missing-checks: §10.5.10 step 14) when
            // target is non-extensible and the property exists on
            // target.
            const has_own = target.ownDataContains(key) or target.hasAccessor(key);
            if (has_own) {
                const flags = target.flagsFor(key);
                if (!flags.configurable) {
                    const ex = try makeTypeError(realm, "proxy 'deleteProperty' trap reported success for non-configurable own property");
                    f.ip = ip;
                    if (!try unwindThrow(allocator, realm, frames, ex)) return .{ .uncaught = ex };
                    return .handled;
                }
                if (!target.extensible) {
                    const ex = try makeTypeError(realm, "proxy 'deleteProperty' trap reported success for own property of non-extensible target");
                    f.ip = ip;
                    if (!try unwindThrow(allocator, realm, frames, ex)) return .{ .uncaught = ex };
                    return .handled;
                }
            }
        }
        return .{ .value = Value.fromBool(b) };
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
    /// See `proxyGetTrap`'s `key_hint` — same reuse contract.
    key_hint: ?Value,
) RunError!ProxyOutcome {
    // §10.5.7 [[HasProperty]] step 7.a — trap missing recurses
    // via `target.[[HasProperty]]`. Walk the chain so a trapless
    // outer proxy forwards to the inner proxy's has trap.
    var cur = proxy;
    while (true) {
        if (cur.proxy_revoked) {
            const ex = try makeTypeError(realm, "Cannot perform 'has' on a proxy that has been revoked");
            f.ip = ip;
            if (!try unwindThrow(allocator, realm, frames, ex)) {
                return .{ .uncaught = ex };
            }
            return .handled;
        }
        const target = cur.proxy_target orelse return .{ .fallthrough = cur };
        const handler = cur.proxy_handler orelse return .{ .fallthrough = target };
        const trap_v = handler.get("has");
        if (trap_v.isUndefined() or trap_v.isNull()) {
            if (target.proxy_target != null or target.proxy_revoked) {
                cur = target;
                continue;
            }
            return .{ .fallthrough = target };
        }
        const trap_fn = heap_mod.valueAsFunction(trap_v) orelse {
            const ex = try makeTypeError(realm, "Proxy 'has' trap is not callable");
            f.ip = ip;
            if (!try unwindThrow(allocator, realm, frames, ex)) return .{ .uncaught = ex };
            return .handled;
        };
        const key_v = try proxyTrapKeyValue(realm, key, key_hint);
        const args = [_]Value{ heap_mod.taggedObject(target), key_v };
        const outcome = try callJSFunction(allocator, realm, trap_fn, heap_mod.taggedObject(handler), &args);
        const v = switch (outcome) {
            .value, .yielded => |val| val,
            .thrown => |ex| {
                f.ip = ip;
                if (!try unwindThrow(allocator, realm, frames, ex)) {
                    return .{ .uncaught = ex };
                }
                return .handled;
            },
        };
        const b = arith.toBoolean(v);
        // §10.5.7 step 9-11 — can't pretend a non-configurable own
        // property doesn't exist, nor pretend an own property of a
        // non-extensible target doesn't exist.
        if (!b) {
            const has_own = target.ownDataContains(key) or target.hasAccessor(key);
            if (has_own) {
                const flags = target.flagsFor(key);
                if (!flags.configurable) {
                    const ex = try makeTypeError(realm, "proxy 'has' trap returned false for non-configurable own property");
                    f.ip = ip;
                    if (!try unwindThrow(allocator, realm, frames, ex)) return .{ .uncaught = ex };
                    return .handled;
                }
                if (!target.extensible) {
                    const ex = try makeTypeError(realm, "proxy 'has' trap returned false for own property of non-extensible target");
                    f.ip = ip;
                    if (!try unwindThrow(allocator, realm, frames, ex)) return .{ .uncaught = ex };
                    return .handled;
                }
            }
        }
        return .{ .value = Value.fromBool(b) };
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
    /// See `proxyGetTrap`'s `key_hint` — same reuse contract.
    key_hint: ?Value,
    value: Value,
    receiver: Value,
) RunError!ProxyOutcome {
    // §10.5.6 [[Set]] step 7.a — trap missing recurses via
    // `target.[[Set]]`. Walk the chain so a trapless outer proxy
    // forwards to the inner proxy's set trap.
    var cur = proxy;
    while (true) {
        if (cur.proxy_revoked) {
            const ex = try makeTypeError(realm, "Cannot perform 'set' on a proxy that has been revoked");
            f.ip = ip;
            if (!try unwindThrow(allocator, realm, frames, ex)) {
                return .{ .uncaught = ex };
            }
            return .handled;
        }
        const target = cur.proxy_target orelse return .{ .fallthrough = cur };
        const handler = cur.proxy_handler orelse return .{ .fallthrough = target };
        const trap_v = handler.get("set");
        if (trap_v.isUndefined() or trap_v.isNull()) {
            if (target.proxy_target != null or target.proxy_revoked) {
                cur = target;
                continue;
            }
            return .{ .fallthrough = target };
        }
        const trap_fn = heap_mod.valueAsFunction(trap_v) orelse {
            const ex = try makeTypeError(realm, "Proxy 'set' trap is not callable");
            f.ip = ip;
            if (!try unwindThrow(allocator, realm, frames, ex)) return .{ .uncaught = ex };
            return .handled;
        };
        const key_v = try proxyTrapKeyValue(realm, key, key_hint);
        const args = [_]Value{ heap_mod.taggedObject(target), key_v, value, receiver };
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
                // accessor whose [[Set]] is undefined. Shape-aware via
                // `flagsFor`; Phase 3 of [docs/lazy-property-bag.md]
                // moved non-default attrs to the shape transition node.
                if (target.lookupOwn(key)) |target_v| {
                    const flags = target.flagsFor(key);
                    if (!flags.configurable and !flags.writable) {
                        if (!intrinsics_mod.sameValue(target_v, value)) {
                            const ex = try makeTypeError(realm, "proxy 'set' trap reported success for non-writable non-configurable data property");
                            f.ip = ip;
                            if (!try unwindThrow(allocator, realm, frames, ex)) return .{ .uncaught = ex };
                            return .handled;
                        }
                    }
                }
                if (target.getAccessor(key)) |acc| {
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

fn readU32(code: []const u8, at: usize) u32 {
    return @as(u32, code[at]) |
        (@as(u32, code[at + 1]) << 8) |
        (@as(u32, code[at + 2]) << 16) |
        (@as(u32, code[at + 3]) << 24);
}

fn applyOffset(ip: usize, off: i16) usize {
    const signed: i64 = @intCast(ip);
    return @intCast(signed + off);
}

// ── Coercions (§7.1) ────────────────────────────────────────────────────
