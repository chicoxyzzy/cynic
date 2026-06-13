//! `Chunk` — a compiled unit of bytecode plus its associated data.
//!
//! Mirrors V8 Ignition's `BytecodeArray` and JSC's `CodeBlock`
//! shape, simplified for later:
//! • `code` — opcode + operand bytes, little-endian.
//! • `constants` — values too big or too non-trivial to
//! inline (doubles, strings, regex
//! patterns later); `LdaConstant <k>`
//! loads constants[k].
//! • `source_positions` — sorted by code offset; lets the
//! interpreter (and stack traces) map
//! a runtime fault back to the source
//! span the parser recorded.
//! • `register_count` — register-file size needed to run this
//! chunk. Computed by the compiler.
//!
//! Construction goes through `Builder` so the running compiler
//! can emit instructions one at a time and lift to an immutable
//! `Chunk` at the end.

const std = @import("std");

const Op = @import("op.zig").Op;
const Span = @import("../source.zig").Span;
const Value = @import("../runtime/value.zig").Value;
const Shape = @import("../runtime/shape.zig").Shape;
const BindingKind = @import("scope.zig").BindingKind;

/// Inline-cache cell — one per property-access callsite. The
/// interpreter records the last receiver's `(shape, slot)` after a
/// successful lookup; on the next hit, a shape pointer compare and a
/// `slots[slot]` load skip the full lookup.
///
/// Three modes (the consumer opcode picks which fields are valid):
///   • Same-shape hit — `proto == null` AND `pre_shape == null`.
///     `shape` matches the receiver; `slot` indexes
///     `recv.slots`. The original `lda_property` / `sta_property`
///     mode.
///   • Proto-load hit (`lda_property`) — `proto != null`. The
///     property was resolved through the receiver's prototype
///     chain; `slot` indexes `proto.slots`. `proto_shape`
///     snapshots `proto.shape` at fill time; `proto_rev` snapshots
///     the realm's `proto_revision_counter`. Either changing
///     invalidates the cell.
///   • Transition hit (`sta_property`) — `pre_shape != null` AND
///     `post_shape != null`. The receiver had `pre_shape` at fill
///     time, no own accessor for the key, AND the full proto
///     chain had no accessor for the key. The fast path stamps
///     `post_shape`, resizes `recv.slots` to its property_count,
///     and writes the new slot value — skipping the slow path's
///     `lookupAccessor` chain walk, `Wyhash` on the key, and
///     `ShapeTree.transition` lookup. `proto` / `proto_shape` /
///     `proto_rev` are additionally snapshot to invalidate on
///     any proto-chain mutation that could introduce an accessor
///     (defineProperty on a proto changes that proto's shape;
///     setPrototypeOf bumps the realm counter).
///
/// Monomorphic: a miss overwrites the cell, no polymorphism / chain.
/// Hermes-style: no JIT, the cache lives entirely in the lantern.
///
/// `shape == null` AND `pre_shape == null` is the cold /
/// un-cacheable state (the last lookup hit a dictionary-mode
/// object, an accessor, the prototype chain, or simply hasn't run
/// yet). Initialised that way at chunk finalisation.
///
/// The `proto` field is a GC-heap pointer; the heap's mark walk
/// weak-clears any cell whose proto isn't otherwise reachable, so
/// a swept-and-reused address cannot reawaken a stale cell.
pub const ICCell = struct {
    shape: ?*Shape = null,
    slot: u32 = 0,
    proto: ?*@import("../runtime/object.zig").JSObject = null,
    proto_shape: ?*Shape = null,
    proto_rev: u64 = 0,
    /// `sta_property` transition mode — required receiver shape
    /// before the write. Paired with `post_shape` below. Both
    /// null in same-shape / proto-load modes.
    pre_shape: ?*Shape = null,
    /// `sta_property` transition mode — the shape to install on
    /// the receiver after the write. The fast path resizes
    /// `recv.slots` to `post_shape.property_count` (cheap on a
    /// hot loop because the slice's underlying capacity carries
    /// over) and stores into `slots[slot]`.
    post_shape: ?*Shape = null,
    /// `sta_property` transition mode — `heap.proto_struct_epoch` at
    /// fill. Complements `proto_shape` / `proto_rev`: a non-writable
    /// data property (or accessor) installed on a *dictionary-mode* or
    /// *non-immediate* prototype after fill bumps this epoch (the
    /// structural funnels in `object.zig`) even though the proto's
    /// (null) shape and the realm counter don't change. A mismatch on
    /// the hot path forces the full `[[Set]]`, honouring §10.1.9.
    guard_epoch: u64 = 0,
    /// Index into the receiver's `properties.values()` for the
    /// shape's `slot`-th key. Cached on `sta_property` IC fill so
    /// the IC-hit bag mirror collapses from a wyhash + bucket walk
    /// + key compare (~41 % of `prop_write` samples) to a single
    /// `values()[bag_index] = acc` store. Sentinel
    /// `bag_index_uncached` means "not yet captured" (e.g. cell
    /// filled by `lda_property` which doesn't need this) — in
    /// that state the IC hit falls back to the hashing
    /// `properties.put(...)` path.
    ///
    /// Stability: shape-stable objects' `properties` map only
    /// appends on a shape transition (which invalidates the cell
    /// via the shape pointer compare), so the cached index stays
    /// valid as long as the cell matches.
    bag_index: u32 = bag_index_uncached,
};

pub const bag_index_uncached: u32 = std.math.maxInt(u32);

/// Inline-cache cell for `call_method` / `call` / `new_call`.
/// Caches the last callee observed at the call site so subsequent
/// calls can skip the callable check, the proxy / revocable-proxy /
/// bound-target exotic dispatch, and the `valueAsFunction` decode —
/// going straight to `callJSFunction(cached_fn, ...)`. Monomorphic.
///
/// `callee == null` is cold / un-cacheable (last callee was
/// exotic, or hasn't run yet). The miss path only refills when
/// the slow-path callee turned out to be a plain (non-bound,
/// non-proxy, non-revoked) JSFunction.
///
/// `proto` is set ONLY by `new_call`. It snapshots
/// `callee.prototype` at fill time so a hot `new C(…)` loop also
/// skips the §10.1.14 GetPrototypeFromConstructor accessor walk:
/// cell hit verifies `cached_callee == observed_callee` AND
/// `cached_proto == cached_callee.prototype` (the latter catches
/// a `C.prototype = …` reassignment that doesn't change the
/// constructor's identity). `.call` and `.call_method` leave
/// `proto` at `null`; they don't consult it.
///
/// The cached pointers are GC-heap allocations, unlike the Shape
/// pointers in `ICCell` (arena-stable). After the GC mark phase
/// the heap walks every reachable chunk's `inline_call_caches`
/// and nulls cells whose callee (or `proto`, for `new_call`) isn't
/// marked, so a swept-and-reused address cannot reawaken a stale
/// cell.
pub const CallICCell = struct {
    callee: ?*@import("../runtime/function.zig").JSFunction = null,
    proto: ?*@import("../runtime/object.zig").JSObject = null,
};

/// Compile-time blueprint for an object-literal's shape — the V8 /
/// JSC "literal boilerplate" pattern. When an object literal like
/// `{a: e1, b: e2}` uses only static identifier keys, no spreads,
/// no methods, and no `__proto__`, the compiler captures the key
/// list in a template. At runtime, `make_object_shape <k>` stamps
/// the cached `Shape*` on the freshly allocated `JSObject` directly,
/// skipping the per-key `ShapeTree.transition` lookups that
/// `def_property`'s `shadowSet` path used to perform on every
/// iteration of a literal-allocating hot loop.
///
/// `cached_shape` is built lazily on first execution by walking
/// `keys` through `ShapeTree.transition` from the root with
/// `PropertyFlags.default` and `kind = .data`. Templates are
/// chunk-lifetime; the cache is plain interior mutation on an
/// otherwise-immutable chunk.
pub const LiteralShapeTemplate = struct {
    /// Constant pool indices for the literal's property keys, in
    /// source order. Each indexed entry is a `Value.fromString`
    /// holding the interned key.
    keys: []const u16,
    /// Resolved `Shape*` after the first execution of any
    /// `make_object_shape` op pointing at this template. Set
    /// once; arena-stable so later cycles trust the pointer.
    cached_shape: ?*Shape = null,
};

/// A single (code-offset → source-span) record. The list is sorted
/// by `offset` ascending; the source span is the parser's range
/// over the AST node that produced the instruction.
pub const SourcePos = struct {
    offset: u32,
    span: Span,
};

/// One entry in the exception-handler table. When `Throw` fires
/// while `ip ∈ [start_pc, end_pc)`, the interpreter jumps to
/// `handler_pc`. `catch_register`, when set, receives the thrown
/// value before the handler runs. A `null` register means the
/// handler is a `finally`-only clause (or the parser-rare
/// `try {... } catch {... }` shape with no binding) — the
/// thrown value lands in the accumulator.
///
/// `is_finally` is true for the *synthetic* handler the compiler
/// emits around a try-finally body. §27.5.1.3 GeneratorPrototype.
/// return must thread the return-completion through pending
/// finallys but skip user `catch` clauses; the unwind path
/// inspects this flag to stop only at finally synthetics when
/// driving a return-completion through a suspended generator.
pub const Handler = struct {
    start_pc: u32,
    end_pc: u32,
    handler_pc: u32,
    catch_register: ?u8,
    is_finally: bool = false,
};

/// Compile-time blueprint for a `JSFunction`. Each function
/// declaration / expression / arrow gets one entry in the
/// enclosing chunk's `function_templates` table; `MakeFunction k`
/// reads template `k` and instantiates a `JSFunction` whose
/// `.chunk` points to `template.chunk` and whose captured env
/// comes from the surrounding frame.
///
/// The template OWNS its inner `Chunk` — `Chunk.deinit` frees it
/// recursively. JSFunction instances merely borrow.
pub const FunctionTemplate = struct {
    /// Compiled body. Lifetime tied to the enclosing chunk.
    chunk: Chunk,
    /// Total declared parameter count — used for env-slot sizing
    /// and the call-site argument-receive plumbing.
    param_count: u8,
    /// §15.7.7 FunctionLength — the value `f.length` exposes,
    /// which is the count of parameters before the first one
    /// with a default value, destructuring pattern, or rest
    /// element. May be less than `param_count`.
    spec_length: u8 = 0,
    /// Borrowed slice into the original source for the function's
    /// declared name. `null` for anonymous functions / arrows.
    name: ?[]const u8,
    is_arrow: bool,
    /// Method-shape marker — class / object methods set this so
    /// `MakeFunction` (or the class builder) can stamp the
    /// resulting `JSFunction.home_object`. Non-method functions
    /// leave it false.
    is_method: bool = false,
    /// `function*` — calling this template allocates a
    /// JSGenerator instead of running the body immediately.
    /// `gen.next()` is what actually runs the body.
    is_generator: bool = false,
    /// `async function` — body returns a Promise. `await` ops
    /// inside synchronously unwrap the awaited promise via
    /// the microtask queue. later ships a sync-await model;
    /// true suspension on pending awaits is later.
    is_async: bool = false,
    /// §20.2.3.5 — borrowed slice of the original source spanning
    /// the function expression / declaration as written. Used by
    /// `Function.prototype.toString` to hand back real source for
    /// user-defined functions; `null` for engine-synthesised
    /// functions (default constructors, native bridges).
    source: ?[]const u8 = null,
};

/// Compile-time blueprint for a class definition.
/// `MakeClass k` reads template `k` and constructs a `JSFunction`
/// (the constructor) plus its `.prototype` object, wiring methods
/// on each as the spec's §15.7.14 OrdinaryClassDefinition demands.
///
/// Owns its constructor body (`constructor_chunk`) and every
/// method body (`MethodTemplate.chunk`). `Chunk.deinit` frees
/// them recursively.
pub const ClassTemplate = struct {
    /// Borrowed slice into the source for the class name. Used
    /// for the constructor's `.name` and stack-trace strings.
    /// `null` for anonymous class expressions.
    name: ?[]const u8,
    /// Span over the whole `class …` form (for diagnostics).
    span: Span,
    /// §20.2.3.5 — source slice spanning `class … { … }`. Used by
    /// `Function.prototype.toString` on the class constructor.
    /// `null` for engine-synthesised classes.
    source: ?[]const u8 = null,
    /// Whether `class C extends …` was written. When true, the
    /// runtime evaluates the heritage expression at MakeClass
    /// time using the bytecode emitted by the enclosing chunk
    /// immediately *before* the `MakeClass` op (the heritage
    /// value sits in the accumulator).
    has_heritage: bool,
    /// Per-class private-name prefix (e.g. `"P0#"`) — used by
    /// the compiler to produce class-identity-mangled keys for
    /// private fields and methods. Borrowed from the source's
    /// compile-time arena.
    private_prefix: []const u8,
    /// Constructor body. For classes without an explicit
    /// constructor the compiler synthesises a default
    /// (`constructor() {}` for non-derived, or
    /// `constructor(...args) { super(...args); }` for derived).
    constructor_chunk: Chunk,
    constructor_param_count: u8,
    /// §15.7.7 FunctionLength — spec value `ClassName.length`
    /// exposes. Same rules as FunctionTemplate.spec_length.
    constructor_spec_length: u8 = 0,
    /// Instance methods (member.is_static == false). Includes
    /// private methods — those have a name prefixed by the
    /// class's `private_prefix`.
    instance_methods: []MethodTemplate,
    /// Static methods (member.is_static == true).
    static_methods: []MethodTemplate,
    /// Public + private instance fields, in declaration order.
    /// Each carries a name (with private_prefix for private)
    /// and a sub-chunk that evaluates the initializer with
    /// `this` bound to the in-progress instance. `init_chunk` is
    /// `null` for `class C { x; }` declared without an initializer.
    instance_fields: []FieldTemplate,
    /// Static fields, in declaration order. Run at MakeClass
    /// time with `this = ctor`; result assigned to `ctor.name`.
    static_fields: []FieldTemplate,
    /// Static blocks (`static { … }`). Run at MakeClass time
    /// with `this = ctor`. Body chunks return undefined.
    static_blocks: []Chunk,
    /// Interleaved source-order of static fields and static
    /// blocks (§15.7.14 step 34 — `For each element of
    /// staticElements in List order`). High bit = is_block,
    /// low 15 bits = index into `static_blocks` /
    /// `static_fields`. Empty when the class has no static
    /// fields or blocks. Without this, `static foo = 1;
    /// static { sideEffect; } static foo = 2;` runs the two
    /// field assignments back-to-back before the block, but
    /// the spec interleaves them.
    static_element_order: []u16,

    pub fn deinit(self: *ClassTemplate, allocator: std.mem.Allocator) void {
        self.constructor_chunk.deinit(allocator);
        for (self.instance_methods) |*m| {
            m.chunk.deinit(allocator);
        }
        allocator.free(self.instance_methods);
        for (self.static_methods) |*m| {
            m.chunk.deinit(allocator);
        }
        allocator.free(self.static_methods);
        for (self.instance_fields) |*f| {
            if (f.init_chunk) |*c| c.deinit(allocator);
        }
        allocator.free(self.instance_fields);
        for (self.static_fields) |*f| {
            if (f.init_chunk) |*c| c.deinit(allocator);
        }
        allocator.free(self.static_fields);
        for (self.static_blocks) |*c| c.deinit(allocator);
        allocator.free(self.static_blocks);
        allocator.free(self.static_element_order);
    }
};

pub const MethodKind = enum { method, getter, setter };

pub const MethodTemplate = struct {
    /// Method name (`m`, `toString`, etc.). Borrowed slice into
    /// source. For private methods the compiler prefixes the
    /// name with the class's `private_prefix` so brand checks
    /// route correctly. Ignored when `computed_key_index >= 0`.
    name: []const u8,
    chunk: Chunk,
    /// Total declared parameter count — see FunctionTemplate.
    param_count: u8,
    /// §15.7.7 FunctionLength for this method. See
    /// FunctionTemplate.spec_length.
    spec_length: u8 = 0,
    /// `method` (default), `getter`, or `setter`. Class-body
    /// `get x() { … }` / `set x(v) { … }` get the latter two;
    /// installed as accessor descriptors at MakeClass time.
    kind: MethodKind = .method,
    /// `*method() {}` — generator method (§15.5).
    is_generator: bool = false,
    /// `async method() {}` — async method (§15.8).
    is_async: bool = false,
    /// §20.2.3.5 — borrowed slice spanning the MethodDefinition
    /// in the original source. `null` for the engine-synthesised
    /// default constructor and any other non-source-backed method.
    source: ?[]const u8 = null,
    /// §13.2.5 ComputedPropertyName — index into the
    /// pre-computed-keys vector that `make_class` consumes when
    /// >= 0; `-1` means this method's key is the static `.name`
    /// field. The compiler evaluates each computed key inline in
    /// the enclosing function's bytecode (so `yield` / `await`
    /// inside a class-key expression suspend the enclosing
    /// generator / async function), `to_property_key`-coerces
    /// the value, and stashes it in a temp register; `make_class`
    /// gathers those registers into the keys vector. Indices
    /// follow source order across all members of the class body.
    computed_key_index: i16 = -1,
};

pub const FieldTemplate = struct {
    name: []const u8,
    /// Sub-chunk that evaluates the initializer with `this`
    /// bound to the instance (or to the class for static
    /// fields). `null` for `class C { x; }` declared without
    /// an initializer — assigned `undefined` at runtime.
    init_chunk: ?Chunk,
    /// §13.2.5 ComputedPropertyName for `class C { [expr] = v; }`.
    /// Same encoding as `MethodTemplate.computed_key_index` —
    /// index into the pre-computed-keys vector, or `-1` when the
    /// field's key is the static `.name`.
    computed_key_index: i16 = -1,
};

/// §19.2.1 direct eval — one enclosing env-slot binding visible at a
/// direct-`eval(...)` call site, captured at compile time so the
/// eval'd source can resolve it against the caller's runtime
/// environment. Only *env-slot* bindings are captured: a free name
/// the eval body doesn't find here falls through to `lda_global`
/// (which resolves top-level `let` / `const` / `var` and builtins by
/// name), so globals need no snapshot entry. `name` borrows from the
/// chunk's source text (realm-lifetime).
pub const DirectEvalBinding = struct {
    name: []const u8,
    /// Compile-time function-nesting depth of the binding (as in
    /// `scope.Binding.env_depth`). The eval compiler emits
    /// `lda_env [caller_env_depth + 1 - env_depth] [env_slot]` — the
    /// `+1` accounts for the eval body's own environment sitting one
    /// level below the caller's innermost env at runtime.
    env_depth: u8,
    env_slot: u8,
    kind: BindingKind,
    is_fn_expr_name: bool = false,
    is_using: bool = false,
};

/// §19.2.1.1 direct eval — one enclosing ClassBody's PrivateEnvironment
/// captured at a direct-`eval(...)` call site so the eval'd source can
/// resolve the class's private names. PerformEval with `direct == true`
/// inherits the running execution context's PrivateEnvironment; Cynic
/// resolves private names at compile time by mangling `#name` with the
/// declaring class's unique `private_prefix`, so the eval compiler must
/// reconstruct the enclosing classes' contexts with the SAME prefixes.
/// All slices are realm-lifetime (the class arena owns the prefix /
/// names), so the chunk borrows them without copying.
pub const DirectEvalClassContext = struct {
    private_prefix: []const u8,
    private_names: []const []const u8,
    is_derived: bool,
};

/// §19.2.1 direct eval — the lexical snapshot captured at one
/// direct-`eval(...)` call site. Indexed by the `direct_eval` opcode's
/// scope operand.
pub const DirectEvalScope = struct {
    /// Visible env-slot bindings, innermost-first (so the first match
    /// per name shadows correctly when reconstructed).
    bindings: []const DirectEvalBinding,
    /// The caller's compile-time `env_depth` at the eval call site —
    /// drives the runtime depth offset (see `DirectEvalBinding`).
    caller_env_depth: u8,
    /// §19.2.1.1 — the enclosing ClassBodies' PrivateEnvironment chain,
    /// outermost-first (mirrors the compiler's `class_stack`), so the
    /// eval compiler can mangle `this.#x` against the same prefixes the
    /// enclosing method used. Empty when the `eval(...)` call site is
    /// outside any class body. Borrowed from the realm's class arena.
    class_contexts: []const DirectEvalClassContext = &.{},
    /// §sec-performeval-rules-in-initializer — true when the `eval(...)`
    /// call site is inside a class field initializer or a class static
    /// block. The eval body then applies the Additional Early Error
    /// Rules for Eval Inside Initializer: `ScriptBody : StatementList`
    /// is a Syntax Error if ContainsArguments of StatementList is true.
    /// False everywhere else — the rule does not apply, so an
    /// `arguments` reference stays ordinary code (a runtime
    /// ReferenceError at worst, never an early SyntaxError).
    in_field_initializer: bool = false,
    /// §13.3.1.1 — the call site is inside non-arrow function code,
    /// so the eval body may contain `new.target`.
    in_function_code: bool = false,
};

pub const Chunk = struct {
    code: []const u8,
    constants: []const Value,
    source_positions: []const SourcePos,
    handlers: []const Handler,
    function_templates: []FunctionTemplate,
    class_templates: []ClassTemplate,
    /// §19.2.1 direct-eval scope snapshots — one per `direct_eval`
    /// opcode emit, indexed by its scope operand. Empty for chunks
    /// with no direct `eval(...)` call sites (the overwhelming
    /// majority). See `DirectEvalScope`.
    direct_eval_scopes: []const DirectEvalScope = &.{},
    register_count: u8,
    /// Module base URL. Used by `module_load` to
    /// resolve relative specifiers. `null` for non-module
    /// chunks (scripts, function bodies). Borrowed; lifetime
    /// is the realm.
    base_url: ?[]const u8 = null,
    /// Names exported by the module. Empty for
    /// non-module chunks. Each name corresponds to a binding
    /// in the module's top-level env that gets snapshotted into
    /// the module's exports namespace at body completion.
    exported_names: []const []const u8 = &.{},
    /// §16.2.1.5.1 [[IsAsync]] — true for a module whose body
    /// contains a *top-level* `await` (lexically outside any
    /// function or arrow). Drives `lantern.run` to route the
    /// chunk through `startAsyncCall` so the body runs as a
    /// JSGenerator-backed async frame and the `await_` opcode has
    /// a place to suspend. Always false for scripts and for
    /// function-body chunks (their `await` is inside an async
    /// function, which is handled separately).
    is_async_module: bool = false,
    /// §19.2.1.3 — when true, this chunk's top-level `var` / function
    /// declarations that bind on the global env are deletable (D=true),
    /// so `sta_global_fn_decl` stamps `[[Configurable]]:true`. Set only
    /// for a non-strict indirect `eval` body (EvalDeclarationInstantiation
    /// steps 15.c.i / 16.a.i pass `true`). False for scripts, modules, and
    /// `ShadowRealm.prototype.evaluate` (§16.1.7 keeps D=false). The var
    /// path is handled at compile time in `installVarBinding`; this flag
    /// carries the same bit to the runtime function-decl opcode.
    eval_global_deletable: bool = false,
    /// Base index into the realm's global declarative env-record
    /// (`GlobalBindings.decl_env`) for this chunk's slot-indexed
    /// global-lexical opcodes (`lda_global_slot` /
    /// `sta_global_slot` / `sta_global_slot_init`). A realm runs
    /// multiple scripts (`Realm.evaluateScript` — e.g. the
    /// test262 harness runs `sta.js` + `assert.js` + the fixture);
    /// each script's slot 0 is `decl_env` index `base`, snapshotted
    /// in `compileScriptAsChunk` just before `hoistLetConst`. Every
    /// nested-function sub-chunk of a script inherits the SAME base
    /// (the script's whole compile tree is one base). The runtime
    /// index for slot `s` is `global_lexical_base + s`. `0` for
    /// modules (module top-levels are never slotted) and for any
    /// chunk that emits no slot opcodes.
    global_lexical_base: u32 = 0,
    /// Mutable per-callsite IC table — one cell per property-access
    /// op (`lda_property` today; `sta_property` and `call_method`
    /// next). The interpreter overwrites cells as receiver shapes
    /// change; the rest of the `Chunk` is logically immutable.
    /// Sized at `finish`; index range `[0, inline_cache_count)` is
    /// the operand space the compiler hands out.
    inline_caches: []ICCell = &.{},
    /// Sister table for `call_method` callsite caching. Cell at
    /// index `i` is the IC cell for the i-th call_method emit;
    /// the heap mark walks every reachable chunk's cells and
    /// weak-clears stale callee pointers post-mark.
    inline_call_caches: []CallICCell = &.{},
    /// Object-literal shape templates. `make_object_shape <k>`
    /// indexes this table; the runtime stamps the cached
    /// `Shape*` onto the freshly-allocated object so the
    /// per-key `def_property`s downstream skip the per-key
    /// `ShapeTree.transition` lookup.
    literal_shape_templates: []LiteralShapeTemplate = &.{},
    /// JIT tier state — mutable side-state on the otherwise-
    /// immutable chunk, following the `inline_caches` pattern
    /// (docs/jit.md §4.1). Allocated unconditionally at `finish`
    /// (8 bytes per template; the counter costs one saturating add
    /// per frame entry and loop back-edge). Bistromath's tier-up
    /// check consumes `warmth` when it lands; until then the heat
    /// signal just accumulates. Null only on hand-built chunks
    /// that never went through `Builder.finish`.
    jit_state: ?*JitState = null,

    /// Per-template tier state (docs/jit.md §4.1, §4.7). `warmth`
    /// is a heat signal, not an exact count: entries — including
    /// §15.10 PTC re-entries, which reframe to ip 0 — weigh
    /// `entry_weight`, loop back-edges weigh 1, and adds saturate
    /// rather than wrap.
    pub const JitState = struct {
        warmth: u32 = 0,
        tier: Tier = .cold,
        /// Bistromath entry point once `tier == .compiled` — stored
        /// type-erased so the bytecode layer doesn't import runtime
        /// types; the dispatcher casts to its concrete signature.
        /// The code bytes live in the heap's code allocator and are
        /// reclaimed wholesale with it (per-chunk code free is a
        /// recorded follow-up, docs/jit.md §8).
        entry: ?*const anyopaque = null,
        /// On-stack-replacement table (docs/jit.md §12 3f): one
        /// entry per loop header, mapping its bytecode offset to a
        /// stub offset relative to `entry`. Lives in the code
        /// region next to the code itself (same wholesale-reclaim
        /// lifetime), so the chunk never owns the allocation.
        osr_ptr: ?[*]const OsrEntry = null,
        osr_len: u32 = 0,
        /// Each OSR entry that immediately tiers back down is a
        /// strike; past the limit the back-edge precheck stops
        /// paying the entry cost (the enter-and-bail ping-pong
        /// would otherwise tax every iteration).
        osr_strikes: u8 = 0,

        pub const OsrEntry = extern struct { bc: u32, code_off: u32 };
        pub const Tier = enum(u8) { cold, compiled, dont_compile };
        /// JSC weights +15 per entry / +1 per back-edge; 16 keeps
        /// the entry bump a shift (docs/jit.md §4.7).
        pub const entry_weight: u32 = 16;
    };

    pub fn deinit(self: *Chunk, allocator: std.mem.Allocator) void {
        allocator.free(self.code);
        allocator.free(self.constants);
        allocator.free(self.source_positions);
        allocator.free(self.handlers);
        for (self.function_templates) |*t| t.chunk.deinit(allocator);
        allocator.free(self.function_templates);
        for (self.class_templates) |*t| t.deinit(allocator);
        allocator.free(self.class_templates);
        // §19.2.1 — free the per-call-site direct-eval snapshots. The
        // `name` slices inside each binding borrow source text (not
        // owned); only the binding slices + the outer slice are freed.
        for (self.direct_eval_scopes) |s| allocator.free(s.bindings);
        allocator.free(self.direct_eval_scopes);
        allocator.free(self.inline_caches);
        allocator.free(self.inline_call_caches);
        for (self.literal_shape_templates) |*t| allocator.free(t.keys);
        allocator.free(self.literal_shape_templates);
        if (self.jit_state) |js| allocator.destroy(js);
    }
};

/// Mutable construction surface for a `Chunk`. The compiler emits
/// into a `Builder`, then calls `finish` once to produce the
/// immutable `Chunk` that the interpreter consumes.
pub const Builder = struct {
    allocator: std.mem.Allocator,
    code: std.ArrayListUnmanaged(u8) = .empty,
    constants: std.ArrayListUnmanaged(Value) = .empty,
    source_positions: std.ArrayListUnmanaged(SourcePos) = .empty,
    handlers: std.ArrayListUnmanaged(Handler) = .empty,
    function_templates: std.ArrayListUnmanaged(FunctionTemplate) = .empty,
    class_templates: std.ArrayListUnmanaged(ClassTemplate) = .empty,
    literal_shape_templates: std.ArrayListUnmanaged(LiteralShapeTemplate) = .empty,
    /// §19.2.1 direct-eval scope snapshots, surfaced on the finished
    /// `Chunk` as `.direct_eval_scopes`. See `DirectEvalScope`.
    direct_eval_scopes: std.ArrayListUnmanaged(DirectEvalScope) = .empty,
    register_count: u8 = 0,
    /// Surfaced on the finished `Chunk` as `.is_async_module`.
    /// Set by `compileModuleAsChunk` after walking the body's
    /// top-level emit for any `.await_` opcode (tracked via the
    /// compiler's `module_has_top_level_await` flag).
    is_async_module: bool = false,
    /// Surfaced on the finished `Chunk` as `.eval_global_deletable`.
    /// Set by the eval compile entry for a non-strict indirect `eval`
    /// body. See `Chunk.eval_global_deletable`.
    eval_global_deletable: bool = false,
    /// Surfaced on the finished `Chunk` as `.global_lexical_base`.
    /// Stamped by the compiler from its `global_lexical_base`
    /// field (constant for a script's whole compile tree) so the
    /// script body chunk AND every nested-function sub-chunk
    /// carry the same base. See `Chunk.global_lexical_base`.
    global_lexical_base: u32 = 0,
    /// Running count of IC cells handed out via `allocIC`. The
    /// `finish` step uses this to size `Chunk.inline_caches`.
    inline_cache_count: u16 = 0,
    /// Running count of call-IC cells handed out via `allocCallIC`.
    /// Sizes `Chunk.inline_call_caches` at `finish`.
    inline_call_cache_count: u16 = 0,
    /// Byte offset of the most recently emitted opcode (set by
    /// `emitOp`). Lets `accStillHoldsRegister` recognise a just-emitted
    /// `Star r` so the compiler can drop a redundant following
    /// `Ldar r` — the accumulator still holds the stored value.
    last_op_start: ?u32 = null,
    /// Highest jump target patched so far (every jump — forward and
    /// backward — resolves through `patchI16`). Used by
    /// `accStillHoldsRegister`: if no jump targets the current
    /// position, control can only have fallen through to it.
    max_jump_target: u32 = 0,

    pub fn init(allocator: std.mem.Allocator) Builder {
        return .{ .allocator = allocator };
    }

    /// Discard everything. Use when the caller will not reach
    /// `finish` — eg. on compile error. After `finish`, the
    /// builder's storage is transferred and `deinit` becomes a
    /// no-op.
    pub fn deinit(self: *Builder) void {
        self.code.deinit(self.allocator);
        self.constants.deinit(self.allocator);
        self.source_positions.deinit(self.allocator);
        self.handlers.deinit(self.allocator);
        for (self.function_templates.items) |*t| t.chunk.deinit(self.allocator);
        self.function_templates.deinit(self.allocator);
        for (self.class_templates.items) |*t| t.deinit(self.allocator);
        self.class_templates.deinit(self.allocator);
        for (self.literal_shape_templates.items) |*t| self.allocator.free(t.keys);
        self.literal_shape_templates.deinit(self.allocator);
        for (self.direct_eval_scopes.items) |s| self.allocator.free(s.bindings);
        self.direct_eval_scopes.deinit(self.allocator);
    }

    pub fn addHandler(self: *Builder, h: Handler) !void {
        try self.handlers.append(self.allocator, h);
    }

    /// Register a compiled function body, returning the
    /// template's index. `MakeFunction k` reads this index at
    /// runtime to instantiate the function.
    pub fn addFunctionTemplate(self: *Builder, t: FunctionTemplate) !u16 {
        if (self.function_templates.items.len == std.math.maxInt(u16)) {
            return error.TooManyFunctions;
        }
        const k: u16 = @intCast(self.function_templates.items.len);
        try self.function_templates.append(self.allocator, t);
        return k;
    }

    /// §19.2.1 — register a direct-eval scope snapshot, returning its
    /// index for the `direct_eval` opcode's scope operand. Takes
    /// ownership of `s.bindings` (freed at chunk/builder teardown).
    pub fn addDirectEvalScope(self: *Builder, s: DirectEvalScope) !u16 {
        if (self.direct_eval_scopes.items.len == std.math.maxInt(u16)) {
            return error.TooManyFunctions;
        }
        const k: u16 = @intCast(self.direct_eval_scopes.items.len);
        try self.direct_eval_scopes.append(self.allocator, s);
        return k;
    }

    /// Register a compiled class blueprint, returning its index.
    /// `MakeClass k` reads this index at runtime to construct the
    /// class object.
    pub fn addClassTemplate(self: *Builder, t: ClassTemplate) !u16 {
        if (self.class_templates.items.len == std.math.maxInt(u16)) {
            return error.TooManyClasses;
        }
        const k: u16 = @intCast(self.class_templates.items.len);
        try self.class_templates.append(self.allocator, t);
        return k;
    }

    /// Register a literal-shape template. `keys` is an owned slice
    /// — the Builder takes ownership and the produced Chunk frees
    /// it. `make_object_shape <k>` at runtime indexes the table at
    /// `k` and stamps the cached `Shape*` on the new object.
    pub fn addLiteralShapeTemplate(self: *Builder, keys: []u16) !u16 {
        if (self.literal_shape_templates.items.len == std.math.maxInt(u16)) {
            return error.TooManyLiteralShapes;
        }
        const k: u16 = @intCast(self.literal_shape_templates.items.len);
        try self.literal_shape_templates.append(self.allocator, .{ .keys = keys });
        return k;
    }

    /// Current write position — useful for jump-target patching.
    pub fn here(self: *const Builder) u32 {
        return @intCast(self.code.items.len);
    }

    /// Reserve a register, returning its index. The compiler
    /// freelist its own register usage; this counter only ever
    /// goes up so the chunk can size its register file correctly.
    pub fn reserveRegister(self: *Builder) !u8 {
        if (self.register_count == std.math.maxInt(u8)) {
            return error.TooManyRegisters;
        }
        const r = self.register_count;
        self.register_count += 1;
        return r;
    }

    pub fn emitOp(self: *Builder, op: Op, span: Span) !void {
        try self.source_positions.append(self.allocator, .{
            .offset = self.here(),
            .span = span,
        });
        self.last_op_start = self.here();
        try self.code.append(self.allocator, @intFromEnum(op));
    }

    /// True when the accumulator provably still holds register `r` at
    /// the current (tail) position, so a redundant `Ldar r` may be
    /// dropped. Two conditions:
    ///   1. the last instruction emitted is exactly `Star r` (acc
    ///      untouched since) — the `start + 2 == len` guard rejects a
    ///      stale `last_op_start` (any wider op emitted after the Star);
    ///   2. no jump targets the current position. Every jump offset is
    ///      patched through `patchI16`, and backward (loop) targets are
    ///      always earlier, so `max_jump_target < here()` proves the
    ///      only edge into here is the Star's fall-through. Without (2)
    ///      a branch could reach here with a different accumulator (the
    ///      `if(x){}else{y}` completion-join case).
    pub fn accStillHoldsRegister(self: *const Builder, r: u8) bool {
        const start = self.last_op_start orelse return false;
        if (@as(usize, start) + 2 != self.code.items.len) return false;
        if (self.code.items[start] != @intFromEnum(Op.star) or
            self.code.items[start + 1] != r) return false;
        return self.max_jump_target < self.here();
    }

    /// True when the position after the last emitted instruction is
    /// provably unreachable — control can't fall off the end. Two
    /// conditions, both required:
    ///   1. the last instruction is an UNCONDITIONAL control transfer
    ///      (`return_` / `throw_` / `jmp` / a tail call), so control
    ///      doesn't fall through into the next slot; and
    ///   2. no jump targets that slot (`max_jump_target < here()`;
    ///      every jump resolves through `patchI16`, backward/loop
    ///      targets are always earlier), so nothing branches there.
    /// Lets the compiler drop the synthetic `LdaUndefined; Return`
    /// epilogue a function would otherwise always append. Conservative
    /// by construction: a conditional terminator (`jmp_if_*`), a
    /// non-terminator tail, OR any jump landing here all yield `false`,
    /// so a function that CAN fall through keeps its epilogue (and
    /// still returns undefined). An empty body (`last_op_start == null`)
    /// is reachable → `false`.
    pub fn tailIsUnreachable(self: *const Builder) bool {
        const start = self.last_op_start orelse return false;
        const op: Op = @enumFromInt(self.code.items[start]);
        switch (op) {
            .return_, .throw_, .jmp, .tail_call, .tail_call_method => {},
            else => return false,
        }
        return self.max_jump_target < self.here();
    }

    pub fn emitU8(self: *Builder, x: u8) !void {
        try self.code.append(self.allocator, x);
    }

    pub fn emitU16(self: *Builder, x: u16) !void {
        try self.code.appendSlice(self.allocator, &std.mem.toBytes(x));
    }

    pub fn emitI16(self: *Builder, x: i16) !void {
        try self.code.appendSlice(self.allocator, &std.mem.toBytes(x));
    }

    pub fn emitI32(self: *Builder, x: i32) !void {
        try self.code.appendSlice(self.allocator, &std.mem.toBytes(x));
    }

    pub fn emitU32(self: *Builder, x: u32) !void {
        try self.code.appendSlice(self.allocator, &std.mem.toBytes(x));
    }

    /// Patch a previously-emitted i16 placeholder at `at` with the
    /// signed offset from the byte AFTER the operand to `target`.
    pub fn patchI16(self: *Builder, at: u32, target: u32) !void {
        const after_operand: i64 = @intCast(at + 2);
        const offset: i64 = @as(i64, @intCast(target)) - after_operand;
        if (offset < std.math.minInt(i16) or offset > std.math.maxInt(i16)) {
            return error.JumpTooFar;
        }
        const o: i16 = @intCast(offset);
        const bytes = std.mem.toBytes(o);
        self.code.items[at] = bytes[0];
        self.code.items[at + 1] = bytes[1];
        if (target > self.max_jump_target) self.max_jump_target = target;
    }

    /// Allocate a fresh inline-cache slot, returning its index. The
    /// caller emits the index as a `u16` operand on a property-access
    /// op; the interpreter indexes `Chunk.inline_caches` with it.
    pub fn allocIC(self: *Builder) !u16 {
        if (self.inline_cache_count == std.math.maxInt(u16)) {
            return error.TooManyInlineCaches;
        }
        const k = self.inline_cache_count;
        self.inline_cache_count += 1;
        return k;
    }

    /// Emit `lda_property` plus its key constant index and a freshly
    /// allocated IC slot. Encoding: `[op] [k:u16] [ic:u16]`.
    pub fn emitLdaProperty(self: *Builder, span: Span, k: u16) !void {
        try self.emitOp(.lda_property, span);
        try self.emitU16(k);
        try self.emitU16(try self.allocIC());
    }

    /// Emit `lda_property_reg` plus its key constant index, receiver
    /// register, and a freshly allocated IC slot. Encoding:
    /// `[op] [k:u16] [r_obj:u8] [ic:u16]`. The register-receiver
    /// counterpart to `emitLdaProperty`: the compiler emits this when
    /// the receiver already sits in a frame register, sparing the
    /// redundant `ldar` into the accumulator. The IC cell shape is
    /// identical to `lda_property`'s — only the receiver source moves.
    pub fn emitLdaPropertyReg(self: *Builder, span: Span, k: u16, r_obj: u8) !void {
        try self.emitOp(.lda_property_reg, span);
        try self.emitU16(k);
        try self.emitU8(r_obj);
        try self.emitU16(try self.allocIC());
    }

    /// Emit `lda_global` plus its key constant index and a freshly
    /// allocated IC slot. Encoding: `[op] [k:u16] [ic:u16]`. The IC
    /// caches `(globalThis_shape, slot, decl_revision)` so repeated
    /// `Math` / `Object` / `Array` / `print` reads collapse from a
    /// `decl_env.get` + `globalThis.lookupOwn` hash pair to a shape
    /// compare + slot load.
    pub fn emitLdaGlobal(self: *Builder, span: Span, k: u16) !void {
        try self.emitOp(.lda_global, span);
        try self.emitU16(k);
        try self.emitU16(try self.allocIC());
    }

    /// Emit `lda_global_or_undef` plus its key constant index and a
    /// freshly allocated IC slot. Same cache shape as
    /// `lda_global` — the miss path is the only difference.
    pub fn emitLdaGlobalOrUndef(self: *Builder, span: Span, k: u16) !void {
        try self.emitOp(.lda_global_or_undef, span);
        try self.emitU16(k);
        try self.emitU16(try self.allocIC());
    }

    /// Emit `sta_property` plus its key constant index, receiver
    /// register, and a freshly allocated IC slot. Encoding:
    /// `[op] [k:u16] [r_obj:u8] [ic:u16]`.
    pub fn emitStaProperty(self: *Builder, span: Span, k: u16, r_obj: u8) !void {
        try self.emitOp(.sta_property, span);
        try self.emitU16(k);
        try self.emitU8(r_obj);
        try self.emitU16(try self.allocIC());
    }

    /// Allocate a fresh call-IC slot for a `call_method` site.
    pub fn allocCallIC(self: *Builder) !u16 {
        if (self.inline_call_cache_count == std.math.maxInt(u16)) {
            return error.TooManyInlineCaches;
        }
        const k = self.inline_call_cache_count;
        self.inline_call_cache_count += 1;
        return k;
    }

    /// Emit `call_method` plus its receiver / callee / argc operands
    /// and a freshly allocated call-IC slot. Encoding:
    /// `[op] [r_recv:u8] [r_callee:u8] [argc:u8] [ic:u16]`.
    pub fn emitCallMethod(
        self: *Builder,
        span: Span,
        r_recv: u8,
        r_callee: u8,
        argc: u8,
    ) !void {
        try self.emitOp(.call_method, span);
        try self.emitU8(r_recv);
        try self.emitU8(r_callee);
        try self.emitU8(argc);
        try self.emitU16(try self.allocCallIC());
    }

    /// Emit `call` plus its callee / argc operands and a freshly
    /// allocated call-IC slot. Encoding:
    /// `[op] [r_callee:u8] [argc:u8] [ic:u16]`. Mirrors
    /// `emitCallMethod`'s allocation pattern; targets the free-
    /// function call site `f(args)` (not `obj.f(args)`), with the
    /// same cached-callee fast path as `call_method`.
    pub fn emitCall(
        self: *Builder,
        span: Span,
        r_callee: u8,
        argc: u8,
    ) !void {
        // ≤3 args: fold argc into the opcode (`call0..3`), dropping the
        // `argc:u8` operand byte. Same callee register, argument
        // window, and call IC as the generic `call`.
        const specialized: ?Op = switch (argc) {
            0 => .call0,
            1 => .call1,
            2 => .call2,
            3 => .call3,
            else => null,
        };
        if (specialized) |op| {
            try self.emitOp(op, span);
            try self.emitU8(r_callee);
            try self.emitU16(try self.allocCallIC());
            return;
        }
        try self.emitOp(.call, span);
        try self.emitU8(r_callee);
        try self.emitU8(argc);
        try self.emitU16(try self.allocCallIC());
    }

    /// Emit `new_call` plus its callee / argc operands and a
    /// freshly allocated call-IC slot. Encoding:
    /// `[op] [r_callee:u8] [argc:u8] [ic:u16]`. The cell caches
    /// the (constructor, resolved-prototype) pair so hot
    /// `new C(…)` loops skip both `valueAsFunction` and the
    /// §10.1.14 GetPrototypeFromConstructor accessor walk.
    pub fn emitNewCall(
        self: *Builder,
        span: Span,
        r_callee: u8,
        argc: u8,
    ) !void {
        try self.emitOp(.new_call, span);
        try self.emitU8(r_callee);
        try self.emitU8(argc);
        try self.emitU16(try self.allocCallIC());
    }

    /// Emit `def_template_property` — templatized CreateDataPropertyOrThrow.
    /// Pairs with a preceding `make_object_shape` whose cached `Shape*`
    /// assigns `slot` to the key at constants[k]. Encoding:
    /// `[op] [k:u16] [r_obj:u8] [slot:u16]`. The slot index is computed
    /// at compile time by counting templatized properties in source order.
    pub fn emitDefTemplateProperty(
        self: *Builder,
        span: Span,
        k: u16,
        r_obj: u8,
        slot: u16,
    ) !void {
        try self.emitOp(.def_template_property, span);
        try self.emitU16(k);
        try self.emitU8(r_obj);
        try self.emitU16(slot);
    }

    /// Emit `call_property` — the fused property-load + method-call
    /// op. Reserves BOTH an IC slot (for the property lookup, same
    /// table `lda_property` uses) AND a call-IC slot (for the loaded
    /// callee, same table `call_method` uses). Encoding:
    /// `[op] [k:u16] [r_recv:u8] [argc:u8] [ic_load:u16] [ic_call:u16]`.
    /// Args live at `r_recv + 1.. r_recv + 1 + argc`.
    pub fn emitCallProperty(
        self: *Builder,
        span: Span,
        k: u16,
        r_recv: u8,
        argc: u8,
    ) !void {
        try self.emitOp(.call_property, span);
        try self.emitU16(k);
        try self.emitU8(r_recv);
        try self.emitU8(argc);
        try self.emitU16(try self.allocIC());
        try self.emitU16(try self.allocCallIC());
    }

    /// Append `v` to the constant pool, returning its index.
    /// Identical doubles, ints, etc. are not deduplicated — the
    /// optimizer (M5+) can do that. Keep simple here.
    pub fn addConstant(self: *Builder, v: Value) !u16 {
        if (self.constants.items.len == std.math.maxInt(u16)) {
            return error.TooManyConstants;
        }
        const k: u16 = @intCast(self.constants.items.len);
        try self.constants.append(self.allocator, v);
        return k;
    }

    fn readI16(code: []const u8, at: usize) i16 {
        const u: u16 = @as(u16, code[at]) | (@as(u16, code[at + 1]) << 8);
        return @bitCast(u);
    }

    /// Length-preserving peephole pass. Scans `self.code` once and
    /// rewrites in place:
    ///
    /// **Jump threading** — every jump (`jmp`, `jmp_if_false`,
    /// `jmp_if_true`, `jmp_if_nullish`) whose target is itself an
    /// unconditional `jmp` has its operand retargeted to the
    /// eventual landing site. Walks through chains, capped at
    /// `max_thread_hops` to defuse pathological self-loops.
    ///
    /// Neither rewrite changes the byte layout — every existing jump
    /// offset, source-position offset, and exception-handler PC stays
    /// valid. The pass runs unconditionally from `finish`; cost is one
    /// linear walk over the code plus one jump-chain follow per jump
    /// instruction. The peephole is the cheapest tier of bytecode
    /// optimisation — length-changing rewrites (`+= 1` → `inc`, dead
    /// code after `return`, etc.) need basic-block / handler-table /
    /// source-position update machinery the chunk doesn't have yet
    /// and are out of scope here.
    pub fn peephole(self: *Builder) void {
        const max_thread_hops: u8 = 16;
        var i: usize = 0;
        while (i < self.code.items.len) {
            const op: Op = @enumFromInt(self.code.items[i]);
            const op_size = Op.operandSize(op);

            switch (op) {
                // Self-mov elimination (`mov rN rN` → nop_3) was tried
                // but reverted: introducing same-length nop_* opcodes
                // grew the dispatch jump table enough to regress every
                // hot-loop bench by ~5-20% from cache layout shifts.
                // The mov itself is already a load+store nop at runtime
                // — the would-be savings (one dispatch round-trip per
                // self-mov) didn't recover the cost. A length-changing
                // rewrite (drop the bytes entirely) needs basic-block /
                // jump-target reverse-index machinery the chunk doesn't
                // have yet; revisit when that lands.
                .jmp, .jmp_if_false, .jmp_if_true, .jmp_if_nullish => {
                    // `[op] [off:i16]`. The offset is relative to the
                    // byte AFTER the operand (matches `patchI16`).
                    // Follow the chain: if the target is an
                    // unconditional `jmp`, replace this op's target
                    // with that jmp's target. Repeat until the target
                    // is some other opcode or the hop budget runs out.
                    const after_operand = i + 3;
                    const cur_off = readI16(self.code.items, i + 1);
                    const target: i64 = @as(i64, @intCast(after_operand)) + cur_off;
                    var hops: u8 = 0;
                    var new_target = target;
                    while (hops < max_thread_hops) : (hops += 1) {
                        if (new_target < 0 or
                            new_target >= self.code.items.len) break;
                        const t: usize = @intCast(new_target);
                        const next_op: Op = @enumFromInt(self.code.items[t]);
                        if (next_op != .jmp) break;
                        // Don't thread through ourselves — the
                        // chain's leading jump rewriting onto its own
                        // landing would still terminate via the hop
                        // cap, but a guard makes the intent explicit.
                        if (t == i) break;
                        const inner_after = t + 3;
                        const inner_off = readI16(self.code.items, t + 1);
                        const next_target: i64 = @as(i64, @intCast(inner_after)) + inner_off;
                        if (next_target == new_target) break; // self-jmp
                        new_target = next_target;
                    }
                    if (new_target != target) {
                        const new_off: i64 = new_target - @as(i64, @intCast(after_operand));
                        if (new_off >= std.math.minInt(i16) and
                            new_off <= std.math.maxInt(i16))
                        {
                            const o: i16 = @intCast(new_off);
                            const bytes = std.mem.toBytes(o);
                            self.code.items[i + 1] = bytes[0];
                            self.code.items[i + 2] = bytes[1];
                        }
                    }
                },
                else => {},
            }
            i += 1 + op_size;
        }
    }

    /// Transfer ownership of the accumulated buffers into a Chunk.
    /// The builder is empty after this call; `deinit` is a no-op.
    pub fn finish(self: *Builder) !Chunk {
        self.peephole();
        const ics = try self.allocator.alloc(ICCell, self.inline_cache_count);
        for (ics) |*c| c.* = .{};
        const call_ics = try self.allocator.alloc(CallICCell, self.inline_call_cache_count);
        for (call_ics) |*c| c.* = .{};
        const jit_state = try self.allocator.create(Chunk.JitState);
        jit_state.* = .{};
        return .{
            .code = try self.code.toOwnedSlice(self.allocator),
            .constants = try self.constants.toOwnedSlice(self.allocator),
            .source_positions = try self.source_positions.toOwnedSlice(self.allocator),
            .handlers = try self.handlers.toOwnedSlice(self.allocator),
            .function_templates = try self.function_templates.toOwnedSlice(self.allocator),
            .class_templates = try self.class_templates.toOwnedSlice(self.allocator),
            .literal_shape_templates = try self.literal_shape_templates.toOwnedSlice(self.allocator),
            .direct_eval_scopes = try self.direct_eval_scopes.toOwnedSlice(self.allocator),
            .register_count = self.register_count,
            .is_async_module = self.is_async_module,
            .eval_global_deletable = self.eval_global_deletable,
            .global_lexical_base = self.global_lexical_base,
            .inline_caches = ics,
            .inline_call_caches = call_ics,
            .jit_state = jit_state,
        };
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "Builder: emit then finish round-trips a simple sequence" {
    var b = Builder.init(testing.allocator);
    errdefer b.deinit();
    const span: Span = .{ .start = 0, .end = 1 };

    try b.emitOp(.lda_smi, span);
    try b.emitI32(42);
    try b.emitOp(.return_, span);

    var chunk = try b.finish();
    defer chunk.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 6), chunk.code.len);
    try testing.expectEqual(@intFromEnum(Op.lda_smi), chunk.code[0]);
    try testing.expectEqual(@intFromEnum(Op.return_), chunk.code[5]);
    try testing.expectEqual(@as(usize, 2), chunk.source_positions.len);
}

test "Builder: addConstant returns sequential indices" {
    var b = Builder.init(testing.allocator);
    defer b.deinit();

    const k0 = try b.addConstant(Value.fromDouble(1.5));
    const k1 = try b.addConstant(Value.fromDouble(2.5));
    try testing.expectEqual(@as(u16, 0), k0);
    try testing.expectEqual(@as(u16, 1), k1);
}

test "Builder: reserveRegister grows the count" {
    var b = Builder.init(testing.allocator);
    defer b.deinit();

    const r0 = try b.reserveRegister();
    const r1 = try b.reserveRegister();
    try testing.expectEqual(@as(u8, 0), r0);
    try testing.expectEqual(@as(u8, 1), r1);
    try testing.expectEqual(@as(u8, 2), b.register_count);
}

test "Builder.peephole: jump threading rewrites first jump's target" {
    var b = Builder.init(testing.allocator);
    errdefer b.deinit();
    const span: Span = .{ .start = 0, .end = 1 };

    // jmp L1; L1: jmp L2; L2: return
    try b.emitOp(.jmp, span);
    const patch_a = b.here();
    try b.emitI16(0);

    const l1 = b.here();
    try b.emitOp(.jmp, span);
    const patch_b = b.here();
    try b.emitI16(0);

    const l2 = b.here();
    try b.emitOp(.return_, span);

    try b.patchI16(patch_a, l1);
    try b.patchI16(patch_b, l2);

    var chunk = try b.finish();
    defer chunk.deinit(testing.allocator);

    // Byte layout: jmp(0..3), jmp(3..6), return(6).
    // After threading, the first jmp should jump straight to L2
    // (the return). Offset is from after-operand = 3, so 6-3 = +3.
    const got_a: i16 = @bitCast(@as(u16, chunk.code[1]) | (@as(u16, chunk.code[2]) << 8));
    try testing.expectEqual(@as(i16, 3), got_a);

    // The second jmp's operand is unchanged.
    const got_b: i16 = @bitCast(@as(u16, chunk.code[4]) | (@as(u16, chunk.code[5]) << 8));
    try testing.expectEqual(@as(i16, 0), got_b);
}

test "Builder.peephole: conditional jump threads through unconditional jmp" {
    var b = Builder.init(testing.allocator);
    errdefer b.deinit();
    const span: Span = .{ .start = 0, .end = 1 };

    // jmp_if_false L1; lda_undefined; L1: jmp L2; L2: return
    try b.emitOp(.jmp_if_false, span);
    const patch_a = b.here();
    try b.emitI16(0);

    try b.emitOp(.lda_undefined, span); // never targeted

    const l1 = b.here();
    try b.emitOp(.jmp, span);
    const patch_b = b.here();
    try b.emitI16(0);

    const l2 = b.here();
    try b.emitOp(.return_, span);

    try b.patchI16(patch_a, l1);
    try b.patchI16(patch_b, l2);

    var chunk = try b.finish();
    defer chunk.deinit(testing.allocator);

    // jmp_if_false at 0, operand 1..3, lda_undefined at 3,
    // jmp at 4, operand 5..7, return at 7.
    // After threading, jmp_if_false's target = L2 = 7,
    // after-operand = 3, so offset = +4.
    const got_a: i16 = @bitCast(@as(u16, chunk.code[1]) | (@as(u16, chunk.code[2]) << 8));
    try testing.expectEqual(@as(i16, 4), got_a);
}

test "Builder.peephole: jump threading caps self-loop and doesn't infinite-loop" {
    var b = Builder.init(testing.allocator);
    errdefer b.deinit();
    const span: Span = .{ .start = 0, .end = 1 };

    // L: jmp L (offset = -3 from after-operand)
    const l = b.here();
    try b.emitOp(.jmp, span);
    const patch = b.here();
    try b.emitI16(0);
    try b.emitOp(.return_, span);
    try b.patchI16(patch, l);

    var chunk = try b.finish();
    defer chunk.deinit(testing.allocator);

    // Self-loop detected — the offset stays as it was.
    const got: i16 = @bitCast(@as(u16, chunk.code[1]) | (@as(u16, chunk.code[2]) << 8));
    try testing.expectEqual(@as(i16, -3), got);
}

test "Builder.peephole: conditional jump targeting a conditional jump is NOT threaded" {
    var b = Builder.init(testing.allocator);
    errdefer b.deinit();
    const span: Span = .{ .start = 0, .end = 1 };

    // jmp L1; L1: jmp_if_false L2; L2: return
    // The first jump is unconditional and could thread, but the
    // target is a CONDITIONAL jmp — threading would observe `acc`
    // semantics that the unconditional first jump doesn't share.
    // Leave it alone.
    try b.emitOp(.jmp, span);
    const patch_a = b.here();
    try b.emitI16(0);

    const l1 = b.here();
    try b.emitOp(.jmp_if_false, span);
    const patch_b = b.here();
    try b.emitI16(0);

    const l2 = b.here();
    try b.emitOp(.return_, span);

    try b.patchI16(patch_a, l1);
    try b.patchI16(patch_b, l2);

    var chunk = try b.finish();
    defer chunk.deinit(testing.allocator);

    // First jmp's offset is still pointing at L1 (offset 0 from
    // after-operand at 3).
    const got_a: i16 = @bitCast(@as(u16, chunk.code[1]) | (@as(u16, chunk.code[2]) << 8));
    try testing.expectEqual(@as(i16, 0), got_a);
}

test "Builder: patchI16 sets a forward jump correctly" {
    var b = Builder.init(testing.allocator);
    errdefer b.deinit();
    const span: Span = .{ .start = 0, .end = 1 };

    // jmp <patch>; lda_undefined; return
    try b.emitOp(.jmp, span);
    const patch_at = b.here();
    try b.emitI16(0); // placeholder
    try b.emitOp(.lda_undefined, span);
    const target = b.here();
    try b.emitOp(.return_, span);

    try b.patchI16(patch_at, target);

    var chunk = try b.finish();
    defer chunk.deinit(testing.allocator);

    // Offset is from byte AFTER the operand. jmp at 0, operand at 1..3,
    // after-operand at 3. lda_undefined at 3. target (return_) at 4.
    // expected offset = 4 - 3 = 1.
    const got: i16 = @bitCast(@as(u16, chunk.code[1]) | (@as(u16, chunk.code[2]) << 8));
    try testing.expectEqual(@as(i16, 1), got);
}
