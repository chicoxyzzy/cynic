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
const JSObject = @import("../runtime/object.zig").JSObject;
const jit_code_alloc = @import("../runtime/jit/code_alloc.zig");
const BindingKind = @import("scope.zig").BindingKind;

const BranchPatch = struct {
    operand_offset: u32,
    target: u32,
};

/// Monomorphic named-load cache. Own-data hits use `(shape, slot)`;
/// immediate-prototype hits additionally guard prototype identity, shape, and
/// the realm-wide prototype revision. Frozen synthetic accessors created by
/// the SES override-mistake fix cache their immutable captured value instead
/// of a slot. `proto` is weak-cleared by the heap; while it is live, its own
/// accessor entry strongly traces `synthetic_value` through the getter's
/// `JSFunction.synth_accessor` internal slot.
pub const LoadICCell = struct {
    pub const Kind = enum(u8) { data, synthetic_accessor };

    shape: ?*Shape = null,
    slot: u32 = 0,
    kind: Kind = .data,
    proto: ?*JSObject = null,
    proto_shape: ?*Shape = null,
    proto_rev: u64 = 0,
    synthetic_value: Value = Value.undefined_,

    pub fn fillOwnData(self: *LoadICCell, shape: *Shape, slot: u32) void {
        self.* = .{ .shape = shape, .slot = slot };
    }

    pub fn fillPrototypeData(
        self: *LoadICCell,
        shape: *Shape,
        slot: u32,
        proto: *JSObject,
        proto_shape: ?*Shape,
        proto_rev: u64,
    ) void {
        self.* = .{
            .shape = shape,
            .slot = slot,
            .proto = proto,
            .proto_shape = proto_shape,
            .proto_rev = proto_rev,
        };
    }

    pub fn fillSyntheticAccessor(
        self: *LoadICCell,
        shape: *Shape,
        proto: *JSObject,
        proto_shape: ?*Shape,
        proto_rev: u64,
        value: Value,
    ) void {
        self.* = .{
            .shape = shape,
            .kind = .synthetic_accessor,
            .proto = proto,
            .proto_shape = proto_shape,
            .proto_rev = proto_rev,
            .synthetic_value = value,
        };
    }

    pub fn invalidate(self: *LoadICCell) void {
        self.* = .{};
    }
};

/// Monomorphic named-store cache. Same-shape rewrites use `(shape, slot)`;
/// transition hits guard the receiver's before/after shapes and prototype
/// structure before installing `post_shape`.
pub const StoreICCell = struct {
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
};

/// Monomorphic computed-key cache shared by computed loads, computed stores,
/// and own-positive `in` sites. The key bytes are inline, so this cell has no
/// GC-managed pointer and needs no weak-clear pass.
pub const ComputedICCell = struct {
    shape: ?*Shape = null,
    slot: u32 = 0,
    /// `lda_computed` computed-key IC — the dynamic string key
    /// captured at fill, stored inline (no allocation, no GC anchor:
    /// the bytes are copied, not a JSString pointer). A hit guards on
    /// `shape` AND a byte-equality of the runtime key against
    /// `cached_key_buf[0..cached_key_len]`. `cached_key_len == 0` is
    /// "no computed key cached" (the cell belongs to a non-computed op,
    /// or the key was empty / longer than `computed_key_cap` and so was
    /// never cached — those fall to the slow path, correctness intact).
    cached_key_len: u8 = 0,
    cached_key_buf: [computed_key_cap]u8 = undefined,
    /// `lda_computed` polymorphism counter — bumped on each refill (a
    /// fast-path miss that re-points the cell at a new key). Once it
    /// reaches `computed_key_megamorphic_after`, the cell parks at
    /// `cached_key_len = computed_key_megamorphic` and both the fast
    /// path and the fill go quiet, so a rotating-key (`obj[keys[i]]`)
    /// site pays the plain slow path instead of thrashing the cache.
    cached_key_miss: u8 = 0,
};

/// Inline byte budget for a `lda_computed` IC's cached key. Covers the
/// overwhelming majority of property identifiers (`constructor` is 11);
/// a longer key simply isn't cached. Keeps the cell allocation-free.
pub const computed_key_cap: usize = 23;

/// `cached_key_len` sentinel: the computed-key cell has gone
/// megamorphic and is permanently disabled. Any value `> computed_key_cap`
/// reads as "skip"; `0xFF` is the canonical park value.
pub const computed_key_megamorphic: u8 = 0xFF;

/// Distinct-key refills tolerated before a computed-key cell parks
/// itself megamorphic. Small: a monomorphic site never misses, so it
/// never counts; a 2+-way rotating site converges to the slow path fast.
pub const computed_key_megamorphic_after: u8 = 4;

/// Pointer-free operand feedback for one arithmetic bytecode site. The three
/// observation bits are monotonic for the chunk's lifetime, so Lantern can
/// update the cell without allocating and Ohaimark can copy it into an
/// immutable compiler snapshot. Raw operands are classified before any
/// ToNumeric coercion: a coercive site must not masquerade as Number-only.
pub const BinaryTypeProfile = struct {
    observations: u8 = 0,

    const int32_pair: u8 = 1 << 0;
    const number_pair: u8 = 1 << 1;
    const non_number_pair: u8 = 1 << 2;

    pub fn observe(self: *BinaryTypeProfile, lhs: Value, rhs: Value) void {
        if (lhs.isInt32() and rhs.isInt32()) {
            self.recordInt32Pair();
        } else if (lhs.isNumber() and rhs.isNumber()) {
            self.recordNumberPair();
        } else {
            self.recordNonNumberPair();
        }
    }

    pub inline fn recordInt32Pair(self: *BinaryTypeProfile) void {
        self.observations |= int32_pair;
    }

    pub inline fn recordNumberPair(self: *BinaryTypeProfile) void {
        self.observations |= number_pair;
    }

    pub inline fn recordNonNumberPair(self: *BinaryTypeProfile) void {
        self.observations |= non_number_pair;
    }

    pub fn mode(self: BinaryTypeProfile) BinaryTypeMode {
        if (self.observations == 0) return .cold;
        if ((self.observations & non_number_pair) != 0) {
            return if ((self.observations & (int32_pair | number_pair)) == 0)
                .non_number
            else
                .mixed;
        }
        return if ((self.observations & number_pair) == 0) .int32 else .number;
    }
};

pub const BinaryTypeMode = enum(u8) {
    cold,
    int32,
    number,
    non_number,
    mixed,
};

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
/// pointers in the property IC cells (arena-stable). After the GC mark phase
/// the heap walks every reachable chunk's `inline_call_caches`
/// and nulls cells whose callee (or `proto`, for `new_call`) isn't
/// marked, so a swept-and-reused address cannot reawaken a stale
/// cell.
pub const CallICCell = struct {
    callee: ?*@import("../runtime/function.zig").JSFunction = null,
    proto: ?*@import("../runtime/object.zig").JSObject = null,
    /// `new_call` only — the resolved instance "initial shape" for a
    /// constructor whose body declares a static field run (the chunk's
    /// `ctor_field_shape`). Its `property_count` is the slot count the
    /// instance will reach, so `new_call` pre-sizes the fresh instance's
    /// slot vector to it — the body's `this.<field> =` writes then never
    /// reallocate slots (§10.1.13 OrdinaryCreateFromConstructor + the V8
    /// "initial map" idea). The shape itself is NOT stamped on the
    /// instance: §10.1.11 own-key order must still grow field-by-field as
    /// the stores execute (an early `'y' in this` reads false until
    /// `this.y` runs), so only the slot *capacity* is pre-provisioned.
    ///
    /// Per-realm by construction: this cell only serves when
    /// `callee == cached`, and a `JSFunction` belongs to one realm, so a
    /// shape from realm A's `ShapeTree` is never consulted under realm B's
    /// constructor (a different `JSFunction` pointer misses the guard).
    /// Shapes are arena-stable, so the pointer never dangles; it is
    /// nulled alongside `callee` on sweep purely for reuse-safety.
    initial_shape: ?*@import("../runtime/shape.zig").Shape = null,
};

/// Inline-cache cell for `for_in_open` — caches the §14.7.5.6
/// EnumerateObjectProperties key snapshot at one for-in callsite so a
/// hot `for (k in o)` loop over a stable object skips the array alloc
/// + own/inherited key walk + per-key string copies on re-entry.
///
/// Soundness rests on the receiver's `[[Prototype]]` being a **frozen**
/// object with a `null` `[[Prototype]]` (a one-level frozen chain, e.g.
/// `obj` → frozen `%Object.prototype%` → null). A frozen proto's
/// enumerable contribution to for-in is immutable, so the snapshot stays
/// valid as long as the receiver's own shape is unchanged. This is the
/// corrected gate: the earlier reverted attempt guarded on the proto
/// being *shape-mode*, which never held under SES-default frozen
/// (dictionary-mode, `shape == null`) primordials.
///
/// A filled cell holds `(recv_shape, proto, snapshot, guard_epoch)`:
///   • `recv_shape` — the receiver's shape at fill (own named-key
///     structure). A shape change (add / delete key) misses.
///   • `proto` — the receiver's `[[Prototype]]` identity at fill.
///     A `setPrototypeOf` to a different proto misses.
///   • `snapshot` — the key-array `JSObject` the cold fill built via
///     `buildForInSnapshot`. On a hit the cell serves a FRESH iterator
///     over this same array (the array itself is never mutated).
///   • `guard_epoch` — `heap.proto_struct_epoch` at fill. A structural
///     mutation anywhere bumps it; the hot path re-checks so a frozen
///     proto thawed-then-mutated (it can't be, but defensively) or any
///     structural funnel forces a refill.
///
/// `proto` and `snapshot` are GC-heap pointers held WEAKLY — the heap's
/// mark walk weak-clears the whole cell if either referent is swept, so
/// the cell never roots a dead snapshot and never dangles. `recv_shape`
/// is arena-stable (shapes are never collected individually) but it's
/// cleared alongside the others so a swept-and-reused proto / snapshot
/// address cannot reawaken a stale cell.
///
/// `snapshot == null` is the cold / un-cacheable state (the last open
/// hit a non-fill-eligible receiver — proxy, array-exotic, owns
/// integer-indexed elements, unfrozen or deeper proto chain — or simply
/// hasn't run yet). Initialised that way at chunk finalisation.
pub const ForInICCell = struct {
    recv_shape: ?*Shape = null,
    proto: ?*@import("../runtime/object.zig").JSObject = null,
    snapshot: ?*@import("../runtime/object.zig").JSObject = null,
    guard_epoch: u64 = 0,
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

/// Dense integer switch side table. `targets[i]` is the absolute bytecode PC
/// for case value `min + i`; holes point at `default_target`. Absolute PCs are
/// finalized alongside branches and remapped by every length-changing pass.
pub const SwitchTable = struct {
    min: i32,
    targets: []u32,
    default_target: u32 = 0,
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
    switch_tables: []SwitchTable = &.{},
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
    /// Typed mutable property-cache tables. Keeping unrelated guards out of
    /// each cell reduces per-callsite memory and gives each opcode family an
    /// independent compact operand-index space.
    inline_load_caches: []LoadICCell = &.{},
    inline_store_caches: []StoreICCell = &.{},
    inline_computed_caches: []ComputedICCell = &.{},
    /// One-byte raw operand profiles for arithmetic sites that can benefit
    /// from speculative Number lowering. Indexed by an explicit bytecode
    /// operand; no JS or GC-managed pointers are retained here.
    inline_binary_profiles: []BinaryTypeProfile = &.{},
    /// Sister table for `call_method` callsite caching. Cell at
    /// index `i` is the IC cell for the i-th call_method emit;
    /// the heap mark walks every reachable chunk's cells and
    /// weak-clears stale callee pointers post-mark.
    inline_call_caches: []CallICCell = &.{},
    /// Sister table for `for_in_open` callsite caching. Cell at
    /// index `i` is the IC cell for the i-th for_in_open emit;
    /// the heap mark weak-clears any cell whose cached proto /
    /// snapshot heap pointer was swept (see `ForInICCell`).
    inline_forin_caches: []ForInICCell = &.{},
    /// Object-literal shape templates. `make_object_shape <k>`
    /// indexes this table; the runtime stamps the cached
    /// `Shape*` onto the freshly-allocated object so the
    /// per-key `def_property`s downstream skip the per-key
    /// `ShapeTree.transition` lookup.
    literal_shape_templates: []LiteralShapeTemplate = &.{},
    /// Constructor instance-shape blueprint — the V8 "initial map" /
    /// JSC `inlineCapacity` analog (§10.1.13 OrdinaryCreateFromConstructor
    /// + §15.7.10). When this chunk is a constructor body whose leading
    /// statements are a simple run of `this.<ident> = <expr>` writes
    /// (§13.3.6 PutValue on a member-this), the compiler records the
    /// distinct field keys here, in first-write order, as constant-pool
    /// indices (each a `Value.fromString` interned key). `new_call`
    /// resolves these into a per-realm `Shape*` (cached in the call IC
    /// cell, NOT here — shapes belong to a realm's ShapeTree and the
    /// same chunk can run in several realms) and allocates the instance
    /// directly into that shape, so the body's field writes land in
    /// pre-sized slots with no per-field shape transition.
    ///
    /// `null` when the constructor isn't eligible (derived, computed /
    /// conditional / dynamic `this[k]=`, an early `return <object>`, a
    /// `delete this.x`, `this` escaping before init, or simply not a
    /// constructor body). Set only by `Builder.setCtorFieldShape`; a
    /// non-empty slice is the only state the runtime acts on.
    ctor_field_shape: ?[]const u16 = null,
    /// JIT tier state — mutable side-state on the otherwise-
    /// immutable chunk, following the typed inline-cache pattern
    /// (docs/jit.md §4.1). Allocated unconditionally at `finish`;
    /// the counter costs one saturating add per frame entry and loop
    /// back-edge, while the tier records stay cold until publication.
    /// Bistromath's tier-up
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
        /// T1 and T2 have independent refusal/publication state. A T2 reject
        /// must never disable a valid Bistromath entry, and both tiers retain
        /// owned executable handles so chunk teardown can return their slots
        /// before the heap unmaps the shared code allocator.
        bistromath: BistromathState = .{},
        ohaimark: TierCode = .{},
        /// Function-entry T2 guard exits. Once the bounded budget is spent,
        /// dispatch bypasses this installed entry to avoid permanent
        /// Ohaimark-to-Lantern ping-pong on a changed type profile.
        ohaimark_guard_exits: u8 = 0,

        pub const OsrEntry = extern struct { bc: u32, code_off: u32 };

        pub const Tier = enum(u8) { cold, compiled, dont_compile };

        /// Common single-entry code state. Publication consumes the temporary
        /// compiler handle and makes the status visible last; refusal is local
        /// to this tier and never releases another tier's code.
        pub const TierCode = struct {
            tier: Tier = .cold,
            executable: jit_code_alloc.InstalledCode = .{},

            pub fn entry(self: *const TierCode) ?*const anyopaque {
                return self.executable.entry();
            }

            pub fn publish(self: *TierCode, executable: *jit_code_alloc.InstalledCode) void {
                if (self.executable.bytes() != null or executable.bytes() == null) return;
                self.executable = executable.take();
                self.tier = .compiled;
            }

            pub fn refuse(self: *TierCode) void {
                if (self.executable.bytes() == null) self.tier = .dont_compile;
            }

            fn deinit(self: *TierCode) void {
                self.executable.deinit();
                self.* = .{};
            }
        };

        pub const BistromathState = struct {
            code: TierCode = .{},
            /// Loop headers, post-call continuations, and exception handlers
            /// map bytecode offsets to prologue-stub offsets relative to the
            /// main entry. This data is installed in the executable region so
            /// it shares the same stable-address and teardown contract.
            continuations: jit_code_alloc.InstalledCode = .{},
            continuation_count: u32 = 0,
            /// Each OSR entry that immediately tiers back down is a strike;
            /// past the limit the back-edge precheck stops paying the entry
            /// cost (avoids enter-and-bail ping-pong on every iteration).
            osr_strikes: u8 = 0,

            pub fn entry(self: *const BistromathState) ?*const anyopaque {
                return self.code.entry();
            }

            pub fn publish(
                self: *BistromathState,
                executable: *jit_code_alloc.InstalledCode,
                continuations: ?*jit_code_alloc.InstalledCode,
                continuation_count: u32,
            ) void {
                if (self.code.entry() != null or executable.bytes() == null) return;
                if (continuations) |table| {
                    if (table.bytes()) |bytes| {
                        self.continuations = table.take();
                        const available = bytes.len / @sizeOf(OsrEntry);
                        self.continuation_count = @intCast(@min(continuation_count, available));
                    }
                }
                self.code.publish(executable);
            }

            pub fn refuse(self: *BistromathState) void {
                self.code.refuse();
            }

            pub fn resumeCodeOffset(self: *const BistromathState, bc: u32) ?u32 {
                const bytes = self.continuations.bytes() orelse return null;
                const ptr: [*]const OsrEntry = @ptrCast(@alignCast(bytes.ptr));
                for (ptr[0..self.continuation_count]) |continuation| {
                    if (continuation.bc == bc) return continuation.code_off;
                }
                return null;
            }

            pub fn hasContinuations(self: *const BistromathState) bool {
                return self.continuation_count != 0;
            }

            fn deinit(self: *BistromathState) void {
                self.code.deinit();
                self.continuations.deinit();
                self.* = .{};
            }
        };

        /// Return the compiled stub for a bytecode continuation. Bistromath
        /// records loop-header OSR entries, post-call continuations, and
        /// catch/finally handler entries in this shared table. Returns null
        /// when the bytecode offset has no compiled continuation.
        pub fn resumeCodeOffset(self: *const JitState, bc: u32) ?u32 {
            return self.bistromath.resumeCodeOffset(bc);
        }

        pub fn deinit(self: *JitState) void {
            self.bistromath.deinit();
            self.ohaimark.deinit();
        }

        /// JSC weights +15 per entry / +1 per back-edge; 16 keeps
        /// the entry bump a shift (docs/jit.md §4.7).
        pub const entry_weight: u32 = 16;
    };

    pub fn deinit(self: *Chunk, allocator: std.mem.Allocator) void {
        // Generated code may embed addresses of this chunk's typed IC cells.
        // Make every entry unreachable and return its slot before releasing
        // any bytecode side table it could reference.
        if (self.jit_state) |js| {
            js.deinit();
            allocator.destroy(js);
            self.jit_state = null;
        }
        allocator.free(self.code);
        allocator.free(self.constants);
        allocator.free(self.source_positions);
        allocator.free(self.handlers);
        for (self.switch_tables) |table| allocator.free(table.targets);
        allocator.free(self.switch_tables);
        for (self.function_templates) |*t| t.chunk.deinit(allocator);
        allocator.free(self.function_templates);
        for (self.class_templates) |*t| t.deinit(allocator);
        allocator.free(self.class_templates);
        // §19.2.1 — free the per-call-site direct-eval snapshots. The
        // `name` slices inside each binding borrow source text (not
        // owned); only the binding slices + the outer slice are freed.
        for (self.direct_eval_scopes) |s| allocator.free(s.bindings);
        allocator.free(self.direct_eval_scopes);
        allocator.free(self.inline_load_caches);
        allocator.free(self.inline_store_caches);
        allocator.free(self.inline_computed_caches);
        allocator.free(self.inline_binary_profiles);
        allocator.free(self.inline_call_caches);
        allocator.free(self.inline_forin_caches);
        for (self.literal_shape_templates) |*t| allocator.free(t.keys);
        allocator.free(self.literal_shape_templates);
        if (self.ctor_field_shape) |keys| allocator.free(keys);
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
    switch_tables: std.ArrayListUnmanaged(SwitchTable) = .empty,
    function_templates: std.ArrayListUnmanaged(FunctionTemplate) = .empty,
    class_templates: std.ArrayListUnmanaged(ClassTemplate) = .empty,
    literal_shape_templates: std.ArrayListUnmanaged(LiteralShapeTemplate) = .empty,
    /// Constructor instance-shape field-key list, surfaced on the
    /// finished `Chunk` as `.ctor_field_shape`. Owned heap slice (or
    /// `null`); set once via `setCtorFieldShape` by the constructor /
    /// constructor-shaped-function compile path. See the chunk field.
    ctor_field_shape: ?[]const u16 = null,
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
    /// Running counts for the typed property-cache tables.
    inline_load_cache_count: u16 = 0,
    inline_store_cache_count: u16 = 0,
    inline_computed_cache_count: u16 = 0,
    inline_binary_profile_count: u16 = 0,
    /// Running count of call-IC cells handed out via `allocCallIC`.
    /// Sizes `Chunk.inline_call_caches` at `finish`.
    inline_call_cache_count: u16 = 0,
    /// Running count of for-in-IC cells handed out via `allocForInIC`.
    /// Sizes `Chunk.inline_forin_caches` at `finish`.
    inline_forin_cache_count: u16 = 0,
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
    /// Logical branch relocations. Emission reserves the historical i16
    /// operand, but `finish` re-emits each branch using i8/i16/i32 after every
    /// target is known. Keeping targets out-of-line also removes the old
    /// `JumpTooFar` compile-time failure for large generated functions.
    branch_patches: std.ArrayListUnmanaged(BranchPatch) = .empty,

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
        for (self.switch_tables.items) |table| self.allocator.free(table.targets);
        self.switch_tables.deinit(self.allocator);
        for (self.function_templates.items) |*t| t.chunk.deinit(self.allocator);
        self.function_templates.deinit(self.allocator);
        for (self.class_templates.items) |*t| t.deinit(self.allocator);
        self.class_templates.deinit(self.allocator);
        for (self.literal_shape_templates.items) |*t| self.allocator.free(t.keys);
        self.literal_shape_templates.deinit(self.allocator);
        if (self.ctor_field_shape) |keys| self.allocator.free(keys);
        for (self.direct_eval_scopes.items) |s| self.allocator.free(s.bindings);
        self.direct_eval_scopes.deinit(self.allocator);
        self.branch_patches.deinit(self.allocator);
    }

    /// Record the constructor instance-shape field-key list (constant-
    /// pool indices, first-write order). Takes ownership of `keys`.
    /// Idempotent-safe: a prior list is freed first. See
    /// `Chunk.ctor_field_shape`.
    pub fn setCtorFieldShape(self: *Builder, keys: []const u16) void {
        if (self.ctor_field_shape) |old| self.allocator.free(old);
        self.ctor_field_shape = keys;
    }

    pub fn addHandler(self: *Builder, h: Handler) !void {
        try self.handlers.append(self.allocator, h);
    }

    pub fn reserveSwitchTable(self: *Builder, min: i32, max: i32) !u16 {
        if (self.switch_tables.items.len == std.math.maxInt(u16)) return error.TooManySwitchTables;
        const span = @as(i64, max) - @as(i64, min) + 1;
        if (span <= 0 or span > std.math.maxInt(u16)) return error.TooManySwitchTables;
        const targets = try self.allocator.alloc(u32, @intCast(span));
        errdefer self.allocator.free(targets);
        @memset(targets, std.math.maxInt(u32));
        const index: u16 = @intCast(self.switch_tables.items.len);
        try self.switch_tables.append(self.allocator, .{ .min = min, .targets = targets });
        return index;
    }

    pub fn setSwitchTarget(self: *Builder, table_index: u16, value: i32, target: u32) void {
        const table = &self.switch_tables.items[table_index];
        const slot: usize = @intCast(@as(i64, value) - table.min);
        // Duplicate CaseClauses keep the first match (§14.12.9).
        if (table.targets[slot] == std.math.maxInt(u32)) table.targets[slot] = target;
    }

    pub fn finishSwitchTable(self: *Builder, table_index: u16, default_target: u32) void {
        const table = &self.switch_tables.items[table_index];
        table.default_target = default_target;
        for (table.targets) |*target| {
            if (target.* == std.math.maxInt(u32)) target.* = default_target;
        }
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
        const items = self.code.items;
        // The last instruction must be exactly the store of `r`, in
        // either encoding: compact `Star0..3` (1 byte, register baked
        // in) or the general 2-byte `Star r`. The `start + N == len`
        // guard rejects a stale `last_op_start` (any wider op after).
        const is_store_of_r = blk: {
            if (r <= 3 and @as(usize, start) + 1 == items.len and
                items[start] == @intFromEnum(Op.star_0) + r) break :blk true;
            if (@as(usize, start) + 2 == items.len and
                items[start] == @intFromEnum(Op.star) and items[start + 1] == r) break :blk true;
            break :blk false;
        };
        if (!is_store_of_r) return false;
        return self.max_jump_target < self.here();
    }

    /// Fuse a just-emitted `Add r` with the `ToInt32` about to be
    /// emitted for the `expr | 0` idiom: rewrite the trailing `add`
    /// opcode byte to `add_to_int32` in place and report success, so
    /// the caller skips the separate `to_int32` op. The register
    /// operand and encoding are unchanged (`add` and `add_to_int32`
    /// share the `[op][r:u8]` shape), so nothing downstream shifts.
    ///
    /// Guards, mirroring `accStillHoldsRegister`:
    ///   1. the last instruction is exactly `Add r` (2-byte, at the
    ///      tail — `start + 2 == len` rejects a stale `last_op_start`);
    ///   2. no jump targets the current position (`max_jump_target <
    ///      here()`), so the `add`'s result reaches the fold point by
    ///      fall-through only — a branch-in could arrive with a
    ///      different accumulator (e.g. `(cond ? a + b : c) | 0`).
    /// Returns false (caller emits the un-fused `to_int32`) otherwise.
    pub fn fuseAddToInt32(self: *Builder) bool {
        const start = self.last_op_start orelse return false;
        const items = self.code.items;
        if (@as(usize, start) + 2 != items.len) return false;
        if (items[start] != @intFromEnum(Op.add)) return false;
        if (self.max_jump_target >= self.here()) return false;
        items[start] = @intFromEnum(Op.add_to_int32);
        return true;
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

    pub fn emitI8(self: *Builder, x: i8) !void {
        try self.code.append(self.allocator, @bitCast(x));
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

    /// Emit a register load into the accumulator, choosing the compact
    /// operand-free `Ldar0..3` form for the hot low slots (1 byte) and
    /// falling back to the 2-byte `Ldar rN` otherwise. Semantics are
    /// identical; the single choke point lets the compact encodings be
    /// toggled in one place.
    pub fn emitLoadReg(self: *Builder, span: Span, r: u8) !void {
        if (r <= 3) {
            try self.emitOp(@enumFromInt(@intFromEnum(Op.ldar_0) + r), span);
        } else {
            try self.emitOp(.ldar, span);
            try self.emitU8(r);
        }
    }

    /// Emit a store of the accumulator into a register, choosing the
    /// compact `Star0..3` form for the hot low slots, else `Star rN`.
    pub fn emitStoreReg(self: *Builder, span: Span, r: u8) !void {
        if (r <= 3) {
            try self.emitOp(@enumFromInt(@intFromEnum(Op.star_0) + r), span);
        } else {
            try self.emitOp(.star, span);
            try self.emitU8(r);
        }
    }

    /// Emit a §13.4 register-binding update. Both variants share the
    /// `[op][r:u8]` encoding; keeping the pair in one emitter prevents the
    /// compiler and disassembler operand layouts from drifting apart.
    pub fn emitUpdateReg(self: *Builder, op: Op, span: Span, r: u8) !void {
        std.debug.assert(op == .inc_reg or op == .dec_reg);
        try self.emitOp(op, span);
        try self.emitU8(r);
    }

    /// Emit a binary accumulator operation. Profiled arithmetic carries
    /// `[op] [lhs:u8] [profile:u16]`; other binary operators retain their
    /// historical `[op] [lhs:u8]` encoding.
    pub fn emitBinary(self: *Builder, op: Op, span: Span, lhs: u8) !void {
        std.debug.assert(op.hasBinaryTypeProfile() or op.spec().layout == .reg);
        if (op.hasBinaryTypeProfile() and
            self.inline_binary_profile_count == std.math.maxInt(u16))
        {
            return error.TooManyInlineCaches;
        }
        try self.emitOp(op, span);
        try self.emitU8(lhs);
        if (op.hasBinaryTypeProfile()) {
            const profile = self.inline_binary_profile_count;
            self.inline_binary_profile_count += 1;
            try self.emitU16(profile);
        }
    }

    /// Emit a Smi load, choosing the operand-free `LdaZero` / `LdaOne`
    /// for the two most common constants (1 byte vs 5), else `LdaSmi`.
    pub fn emitLoadSmi(self: *Builder, span: Span, v: i32) !void {
        switch (v) {
            0 => try self.emitOp(.lda_zero, span),
            1 => try self.emitOp(.lda_one, span),
            std.math.minInt(i8)...-1, 2...std.math.maxInt(i8) => {
                try self.emitOp(.lda_smi8, span);
                try self.emitI8(@intCast(v));
            },
            std.math.minInt(i16)...std.math.minInt(i8) - 1,
            std.math.maxInt(i8) + 1...std.math.maxInt(i16),
            => {
                try self.emitOp(.lda_smi16, span);
                try self.emitI16(@intCast(v));
            },
            else => {
                try self.emitOp(.lda_smi, span);
                try self.emitI32(v);
            },
        }
    }

    /// Emit `acc = registers[r] + imm` with the narrowest signed
    /// immediate that preserves the exact i32 value.
    pub fn emitAddSmi(self: *Builder, span: Span, r: u8, imm: i32) !void {
        if (imm >= std.math.minInt(i8) and imm <= std.math.maxInt(i8)) {
            try self.emitOp(.add_smi8, span);
            try self.emitU8(r);
            try self.emitI8(@intCast(imm));
        } else if (imm >= std.math.minInt(i16) and imm <= std.math.maxInt(i16)) {
            try self.emitOp(.add_smi16, span);
            try self.emitU8(r);
            try self.emitI16(@intCast(imm));
        } else {
            try self.emitOp(.add_smi, span);
            try self.emitU8(r);
            try self.emitI32(imm);
        }
    }

    /// Resolve a previously-emitted i16 branch placeholder. The logical
    /// relocation is authoritative; the in-place i16 is only populated when
    /// it fits so pre-finalization peepholes can inspect ordinary branches.
    /// `finish` selects the final i8/i16/i32 encoding.
    pub fn patchI16(self: *Builder, at: u32, target: u32) !void {
        const after_operand: i64 = @intCast(at + 2);
        const offset: i64 = @as(i64, @intCast(target)) - after_operand;
        if (offset >= std.math.minInt(i16) and offset <= std.math.maxInt(i16)) {
            const o: i16 = @intCast(offset);
            const bytes = std.mem.toBytes(o);
            self.code.items[at] = bytes[0];
            self.code.items[at + 1] = bytes[1];
        }
        if (self.findBranchPatch(at)) |patch| {
            patch.target = target;
        } else {
            try self.branch_patches.append(self.allocator, .{ .operand_offset = at, .target = target });
        }
        if (target > self.max_jump_target) self.max_jump_target = target;
    }

    fn findBranchPatch(self: *Builder, operand_offset: u32) ?*BranchPatch {
        for (self.branch_patches.items) |*patch| {
            if (patch.operand_offset == operand_offset) return patch;
        }
        return null;
    }

    fn branchPatchForOp(self: *Builder, op_start: u32, op: Op) ?*BranchPatch {
        const info = op.branchInfo() orelse return null;
        return self.findBranchPatch(op_start + 1 + info.operand_offset);
    }

    pub fn allocLoadIC(self: *Builder) !u16 {
        if (self.inline_load_cache_count == std.math.maxInt(u16)) {
            return error.TooManyInlineCaches;
        }
        const k = self.inline_load_cache_count;
        self.inline_load_cache_count += 1;
        return k;
    }

    pub fn allocStoreIC(self: *Builder) !u16 {
        if (self.inline_store_cache_count == std.math.maxInt(u16)) {
            return error.TooManyInlineCaches;
        }
        const k = self.inline_store_cache_count;
        self.inline_store_cache_count += 1;
        return k;
    }

    pub fn allocComputedIC(self: *Builder) !u16 {
        if (self.inline_computed_cache_count == std.math.maxInt(u16)) {
            return error.TooManyInlineCaches;
        }
        const k = self.inline_computed_cache_count;
        self.inline_computed_cache_count += 1;
        return k;
    }

    /// Emit `lda_property` plus its key constant index and a freshly
    /// allocated IC slot. Encoding: `[op] [k:u16] [ic:u16]`.
    pub fn emitLdaProperty(self: *Builder, span: Span, k: u16) !void {
        const ic = try self.allocLoadIC();
        if (k <= std.math.maxInt(u8) and ic <= std.math.maxInt(u8)) {
            try self.emitOp(.lda_property8, span);
            try self.emitU8(@intCast(k));
            try self.emitU8(@intCast(ic));
        } else {
            try self.emitOp(.lda_property, span);
            try self.emitU16(k);
            try self.emitU16(ic);
        }
    }

    /// Emit `lda_property_reg` plus its key constant index, receiver
    /// register, and a freshly allocated IC slot. Encoding:
    /// `[op] [k:u16] [r_obj:u8] [ic:u16]`. The register-receiver
    /// counterpart to `emitLdaProperty`: the compiler emits this when
    /// the receiver already sits in a frame register, sparing the
    /// redundant `ldar` into the accumulator. The IC cell shape is
    /// identical to `lda_property`'s — only the receiver source moves.
    pub fn emitLdaPropertyReg(self: *Builder, span: Span, k: u16, r_obj: u8) !void {
        const ic = try self.allocLoadIC();
        if (k <= std.math.maxInt(u8) and ic <= std.math.maxInt(u8)) {
            try self.emitOp(.lda_property_reg8, span);
            try self.emitU8(@intCast(k));
            try self.emitU8(r_obj);
            try self.emitU8(@intCast(ic));
        } else {
            try self.emitOp(.lda_property_reg, span);
            try self.emitU16(k);
            try self.emitU8(r_obj);
            try self.emitU16(ic);
        }
    }

    /// Emit `lda_computed` plus its receiver register and a freshly
    /// allocated IC slot. Encoding: `[op] [r_obj:u8] [ic:u16]` — the
    /// key stays in the accumulator. The IC caches `(shape, slot)` keyed
    /// by the runtime string key (captured inline in the cell) so a hot
    /// monomorphic `obj[k]` skips ToPropertyKey + the shape hash.
    pub fn emitLdaComputed(self: *Builder, span: Span, r_obj: u8) !void {
        const ic = try self.allocComputedIC();
        try self.emitOp(if (ic <= std.math.maxInt(u8)) .lda_computed8 else .lda_computed, span);
        try self.emitU8(r_obj);
        if (ic <= std.math.maxInt(u8)) try self.emitU8(@intCast(ic)) else try self.emitU16(ic);
    }

    /// Emit `sta_computed` plus its receiver / key registers and a
    /// freshly allocated IC slot. Encoding:
    /// `[op] [r_obj:u8] [r_key:u8] [ic:u16]` — value stays in the
    /// accumulator. The IC caches `(shape, slot)` keyed by the runtime
    /// key so a hot same-shape `obj[k] = v` rewrite skips ToPropertyKey
    /// + the shape hash + the `[[Set]]` walk.
    pub fn emitStaComputed(self: *Builder, span: Span, r_obj: u8, r_key: u8) !void {
        const ic = try self.allocComputedIC();
        try self.emitOp(if (ic <= std.math.maxInt(u8)) .sta_computed8 else .sta_computed, span);
        try self.emitU8(r_obj);
        try self.emitU8(r_key);
        if (ic <= std.math.maxInt(u8)) try self.emitU8(@intCast(ic)) else try self.emitU16(ic);
    }

    /// Emit `in_op` plus its key register and a freshly allocated IC
    /// slot. Encoding: `[op] [r_key:u8] [ic:u16]` — the object stays in
    /// the accumulator. The IC caches the own-positive result keyed by
    /// the runtime string key (captured inline in the cell), guarded by
    /// the object's shape so a hot `key in obj` over a stable own
    /// property skips ToPropertyKey + the prototype walk.
    pub fn emitInOp(self: *Builder, span: Span, r_key: u8) !void {
        const ic = try self.allocComputedIC();
        try self.emitOp(if (ic <= std.math.maxInt(u8)) .in_op8 else .in_op, span);
        try self.emitU8(r_key);
        if (ic <= std.math.maxInt(u8)) try self.emitU8(@intCast(ic)) else try self.emitU16(ic);
    }

    /// Emit `lda_global` plus its key constant index and a freshly
    /// allocated IC slot. Encoding: `[op] [k:u16] [ic:u16]`. The IC
    /// caches `(globalThis_shape, slot, decl_revision)` so repeated
    /// `Math` / `Object` / `Array` / `print` reads collapse from a
    /// `decl_env.get` + `globalThis.lookupOwn` hash pair to a shape
    /// compare + slot load.
    pub fn emitLdaGlobal(self: *Builder, span: Span, k: u16) !void {
        const ic = try self.allocLoadIC();
        const narrow = k <= std.math.maxInt(u8) and ic <= std.math.maxInt(u8);
        try self.emitOp(if (narrow) .lda_global8 else .lda_global, span);
        if (narrow) try self.emitU8(@intCast(k)) else try self.emitU16(k);
        if (narrow) try self.emitU8(@intCast(ic)) else try self.emitU16(ic);
    }

    /// Emit `lda_global_or_undef` plus its key constant index and a
    /// freshly allocated IC slot. Same cache shape as
    /// `lda_global` — the miss path is the only difference.
    pub fn emitLdaGlobalOrUndef(self: *Builder, span: Span, k: u16) !void {
        const ic = try self.allocLoadIC();
        const narrow = k <= std.math.maxInt(u8) and ic <= std.math.maxInt(u8);
        try self.emitOp(if (narrow) .lda_global_or_undef8 else .lda_global_or_undef, span);
        if (narrow) try self.emitU8(@intCast(k)) else try self.emitU16(k);
        if (narrow) try self.emitU8(@intCast(ic)) else try self.emitU16(ic);
    }

    /// Emit `sta_property` plus its key constant index, receiver
    /// register, and a freshly allocated IC slot. Encoding:
    /// `[op] [k:u16] [r_obj:u8] [ic:u16]`.
    pub fn emitStaProperty(self: *Builder, span: Span, k: u16, r_obj: u8) !void {
        const ic = try self.allocStoreIC();
        const narrow = k <= std.math.maxInt(u8) and ic <= std.math.maxInt(u8);
        try self.emitOp(if (narrow) .sta_property8 else .sta_property, span);
        if (narrow) try self.emitU8(@intCast(k)) else try self.emitU16(k);
        try self.emitU8(r_obj);
        if (narrow) try self.emitU8(@intCast(ic)) else try self.emitU16(ic);
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

    /// Allocate a fresh for-in-IC slot for a `for_in_open` site.
    pub fn allocForInIC(self: *Builder) !u16 {
        if (self.inline_forin_cache_count == std.math.maxInt(u16)) {
            return error.TooManyInlineCaches;
        }
        const k = self.inline_forin_cache_count;
        self.inline_forin_cache_count += 1;
        return k;
    }

    /// Emit `for_in_open` plus a freshly allocated for-in-IC slot.
    /// Encoding: `[op] [ic:u16]` — the object stays in the
    /// accumulator. The IC caches the §14.7.5.6 key snapshot keyed by
    /// the receiver shape + a frozen one-level prototype, so a hot
    /// `for (k in o)` loop over a stable object skips the re-walk.
    pub fn emitForInOpen(self: *Builder, span: Span) !void {
        const ic = try self.allocForInIC();
        try self.emitOp(if (ic <= std.math.maxInt(u8)) .for_in_open8 else .for_in_open, span);
        if (ic <= std.math.maxInt(u8)) try self.emitU8(@intCast(ic)) else try self.emitU16(ic);
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
        const ic = try self.allocCallIC();
        try self.emitOp(if (ic <= std.math.maxInt(u8)) .call_method8 else .call_method, span);
        try self.emitU8(r_recv);
        try self.emitU8(r_callee);
        try self.emitU8(argc);
        if (ic <= std.math.maxInt(u8)) try self.emitU8(@intCast(ic)) else try self.emitU16(ic);
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
        const ic = try self.allocCallIC();
        if (specialized) |op| {
            const emitted_op: Op = if (ic <= std.math.maxInt(u8)) switch (op) {
                .call0 => .call0_8,
                .call1 => .call1_8,
                .call2 => .call2_8,
                else => .call3_8,
            } else op;
            try self.emitOp(emitted_op, span);
            try self.emitU8(r_callee);
            if (ic <= std.math.maxInt(u8)) try self.emitU8(@intCast(ic)) else try self.emitU16(ic);
            return;
        }
        try self.emitOp(if (ic <= std.math.maxInt(u8)) .call8 else .call, span);
        try self.emitU8(r_callee);
        try self.emitU8(argc);
        if (ic <= std.math.maxInt(u8)) try self.emitU8(@intCast(ic)) else try self.emitU16(ic);
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
        const ic = try self.allocCallIC();
        try self.emitOp(if (ic <= std.math.maxInt(u8)) .new_call8 else .new_call, span);
        try self.emitU8(r_callee);
        try self.emitU8(argc);
        if (ic <= std.math.maxInt(u8)) try self.emitU8(@intCast(ic)) else try self.emitU16(ic);
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
        const load_ic = try self.allocLoadIC();
        const call_ic = try self.allocCallIC();
        const narrow = k <= std.math.maxInt(u8) and load_ic <= std.math.maxInt(u8) and call_ic <= std.math.maxInt(u8);
        try self.emitOp(if (narrow) .call_property8 else .call_property, span);
        if (narrow) try self.emitU8(@intCast(k)) else try self.emitU16(k);
        try self.emitU8(r_recv);
        try self.emitU8(argc);
        if (narrow) {
            try self.emitU8(@intCast(load_ic));
            try self.emitU8(@intCast(call_ic));
        } else {
            try self.emitU16(load_ic);
            try self.emitU16(call_ic);
        }
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
                    // Follow the chain: if the target is an
                    // unconditional `jmp`, replace this op's target
                    // with that jmp's target. Repeat until the target
                    // is some other opcode or the hop budget runs out.
                    const patch = self.branchPatchForOp(@intCast(i), op) orelse {
                        i += 1 + op_size;
                        continue;
                    };
                    const target: i64 = patch.target;
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
                        const inner_patch = self.branchPatchForOp(@intCast(t), next_op) orelse break;
                        const next_target: i64 = inner_patch.target;
                        if (next_target == new_target) break; // self-jmp
                        new_target = next_target;
                    }
                    if (new_target != target) {
                        patch.target = @intCast(new_target);
                    }
                },
                else => {},
            }
            i += 1 + op_size;
        }
    }

    fn fitsBranchWidth(rel: i64, width: @import("op.zig").BranchWidth) bool {
        return switch (width) {
            .i8 => rel >= std.math.minInt(i8) and rel <= std.math.maxInt(i8),
            .i16 => rel >= std.math.minInt(i16) and rel <= std.math.maxInt(i16),
            .i32 => rel >= std.math.minInt(i32) and rel <= std.math.maxInt(i32),
        };
    }

    /// Re-emit relative branches at their narrowest lossless width. Widths
    /// start at i32 and only shrink, so the offset fixpoint is monotonic: every
    /// shrink can only reduce the distance crossed by another branch.
    fn relaxBranches(self: *Builder) !void {
        if (self.branch_patches.items.len == 0) return;

        const old_code = self.code.items;
        const n = self.branch_patches.items.len;
        const widths = try self.allocator.alloc(@import("op.zig").BranchWidth, n);
        defer self.allocator.free(widths);
        @memset(widths, .i32);
        const patch_starts = try self.allocator.alloc(u32, n);
        defer self.allocator.free(patch_starts);

        var patch_by_start: std.AutoHashMapUnmanaged(u32, usize) = .empty;
        defer patch_by_start.deinit(self.allocator);
        var patch_by_operand: std.AutoHashMapUnmanaged(u32, usize) = .empty;
        defer patch_by_operand.deinit(self.allocator);
        for (self.branch_patches.items, 0..) |patch, patch_idx| {
            try patch_by_operand.put(self.allocator, patch.operand_offset, patch_idx);
        }
        var found_count: usize = 0;
        var scan: u32 = 0;
        while (scan < old_code.len) {
            const op: Op = @enumFromInt(old_code[scan]);
            if (op.branchInfo()) |info| {
                if (patch_by_operand.get(scan + 1 + info.operand_offset)) |patch_idx| {
                    try patch_by_start.put(self.allocator, scan, patch_idx);
                    patch_starts[patch_idx] = scan;
                    found_count += 1;
                }
            }
            scan += 1 + op.operandSize();
        }
        if (found_count != n) return error.JumpTooFar;

        const new_off = try self.allocator.alloc(u32, old_code.len + 1);
        defer self.allocator.free(new_off);

        var changed = true;
        while (changed) {
            changed = false;
            var old: u32 = 0;
            var new: u32 = 0;
            while (old < old_code.len) {
                new_off[old] = new;
                const op: Op = @enumFromInt(old_code[old]);
                if (patch_by_start.get(old)) |patch_idx| {
                    const info = op.branchInfo().?;
                    new += 1 + info.operand_offset + widths[patch_idx].byteSize();
                } else {
                    new += 1 + op.operandSize();
                }
                old += 1 + op.operandSize();
            }
            new_off[old_code.len] = new;

            for (self.branch_patches.items, 0..) |patch, patch_idx| {
                const old_start = patch_starts[patch_idx];
                const op: Op = @enumFromInt(old_code[old_start]);
                const info = op.branchInfo().?;
                var selected: @import("op.zig").BranchWidth = .i32;
                inline for (.{ @import("op.zig").BranchWidth.i8, @import("op.zig").BranchWidth.i16 }) |candidate| {
                    var target = new_off[patch.target];
                    // A forward target includes this branch's current encoded
                    // width in its mapped position. Evaluate the candidate's
                    // own shrink on both ends of the displacement.
                    if (patch.target > old_start) {
                        target -= widths[patch_idx].byteSize() - candidate.byteSize();
                    }
                    const after = new_off[old_start] + 1 + info.operand_offset + candidate.byteSize();
                    const rel = @as(i64, target) - @as(i64, after);
                    if (fitsBranchWidth(rel, candidate)) {
                        selected = candidate;
                        break;
                    }
                }
                if (@intFromEnum(selected) < @intFromEnum(widths[patch_idx])) {
                    widths[patch_idx] = selected;
                    changed = true;
                }
            }
        }

        // Rebuild the final map for the converged widths.
        var old: u32 = 0;
        var new: u32 = 0;
        while (old < old_code.len) {
            new_off[old] = new;
            const op: Op = @enumFromInt(old_code[old]);
            if (patch_by_start.get(old)) |patch_idx| {
                const info = op.branchInfo().?;
                new += 1 + info.operand_offset + widths[patch_idx].byteSize();
            } else {
                new += 1 + op.operandSize();
            }
            old += 1 + op.operandSize();
        }
        new_off[old_code.len] = new;

        var out: std.ArrayListUnmanaged(u8) = .empty;
        errdefer out.deinit(self.allocator);
        try out.ensureTotalCapacity(self.allocator, new);
        old = 0;
        while (old < old_code.len) {
            const op: Op = @enumFromInt(old_code[old]);
            const old_size: u32 = 1 + op.operandSize();
            if (patch_by_start.get(old)) |patch_idx| {
                const info = op.branchInfo().?;
                const width = widths[patch_idx];
                const variant = op.branchVariant(width);
                try out.append(self.allocator, @intFromEnum(variant));
                try out.appendSlice(self.allocator, old_code[old + 1 .. old + 1 + info.operand_offset]);
                const after: i64 = @intCast(new_off[old] + 1 + info.operand_offset + width.byteSize());
                const rel = @as(i64, new_off[self.branch_patches.items[patch_idx].target]) - after;
                if (!fitsBranchWidth(rel, width)) return error.JumpTooFar;
                switch (width) {
                    .i8 => try out.append(self.allocator, @bitCast(@as(i8, @intCast(rel)))),
                    .i16 => try out.appendSlice(self.allocator, &std.mem.toBytes(@as(i16, @intCast(rel)))),
                    .i32 => try out.appendSlice(self.allocator, &std.mem.toBytes(@as(i32, @intCast(rel)))),
                }
            } else {
                try out.appendSlice(self.allocator, old_code[old .. old + old_size]);
            }
            old += old_size;
        }

        for (self.source_positions.items) |*sp| sp.offset = new_off[sp.offset];
        for (self.handlers.items) |*handler| {
            handler.start_pc = new_off[handler.start_pc];
            handler.end_pc = new_off[handler.end_pc];
            handler.handler_pc = new_off[handler.handler_pc];
        }
        for (self.switch_tables.items) |*table| {
            table.default_target = new_off[table.default_target];
            for (table.targets) |*target| target.* = new_off[target.*];
        }

        self.code.deinit(self.allocator);
        self.code = out;
        self.branch_patches.deinit(self.allocator);
        self.branch_patches = .empty;
    }

    /// Transfer ownership of the accumulated buffers into a Chunk.
    /// The builder is empty after this call; `deinit` is a no-op.
    pub fn finish(self: *Builder) !Chunk {
        self.peephole();
        try self.relaxBranches();
        const load_ics = try self.allocator.alloc(LoadICCell, self.inline_load_cache_count);
        for (load_ics) |*c| c.* = .{};
        const store_ics = try self.allocator.alloc(StoreICCell, self.inline_store_cache_count);
        for (store_ics) |*c| c.* = .{};
        const computed_ics = try self.allocator.alloc(ComputedICCell, self.inline_computed_cache_count);
        for (computed_ics) |*c| c.* = .{};
        const binary_profiles = try self.allocator.alloc(BinaryTypeProfile, self.inline_binary_profile_count);
        for (binary_profiles) |*profile| profile.* = .{};
        const call_ics = try self.allocator.alloc(CallICCell, self.inline_call_cache_count);
        for (call_ics) |*c| c.* = .{};
        const forin_ics = try self.allocator.alloc(ForInICCell, self.inline_forin_cache_count);
        for (forin_ics) |*c| c.* = .{};
        const jit_state = try self.allocator.create(Chunk.JitState);
        jit_state.* = .{};
        // Hand the ctor field-shape slice to the chunk and detach it
        // from the builder so the post-`finish` no-op `deinit` can't
        // double-free it.
        const ctor_shape = self.ctor_field_shape;
        self.ctor_field_shape = null;
        return .{
            .code = try self.code.toOwnedSlice(self.allocator),
            .constants = try self.constants.toOwnedSlice(self.allocator),
            .source_positions = try self.source_positions.toOwnedSlice(self.allocator),
            .handlers = try self.handlers.toOwnedSlice(self.allocator),
            .switch_tables = try self.switch_tables.toOwnedSlice(self.allocator),
            .function_templates = try self.function_templates.toOwnedSlice(self.allocator),
            .class_templates = try self.class_templates.toOwnedSlice(self.allocator),
            .literal_shape_templates = try self.literal_shape_templates.toOwnedSlice(self.allocator),
            .ctor_field_shape = ctor_shape,
            .direct_eval_scopes = try self.direct_eval_scopes.toOwnedSlice(self.allocator),
            .register_count = self.register_count,
            .is_async_module = self.is_async_module,
            .eval_global_deletable = self.eval_global_deletable,
            .global_lexical_base = self.global_lexical_base,
            .inline_load_caches = load_ics,
            .inline_store_caches = store_ics,
            .inline_computed_caches = computed_ics,
            .inline_binary_profiles = binary_profiles,
            .inline_call_caches = call_ics,
            .inline_forin_caches = forin_ics,
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

test "Builder: integer immediates choose the narrowest lossless encoding" {
    var b = Builder.init(testing.allocator);
    errdefer b.deinit();
    const span: Span = .{ .start = 0, .end = 1 };
    const r = try b.reserveRegister();

    try b.emitLoadSmi(span, -2);
    try b.emitLoadSmi(span, 300);
    try b.emitLoadSmi(span, 70_000);
    try b.emitAddSmi(span, r, -3);
    try b.emitAddSmi(span, r, 1_000);
    try b.emitAddSmi(span, r, 100_000);
    var chunk = try b.finish();
    defer chunk.deinit(testing.allocator);

    var pc: usize = 0;
    const expected = [_]Op{ .lda_smi8, .lda_smi16, .lda_smi, .add_smi8, .add_smi16, .add_smi };
    for (expected) |op| {
        try testing.expectEqual(op, @as(Op, @enumFromInt(chunk.code[pc])));
        pc += 1 + op.operandSize();
    }
    try testing.expectEqual(chunk.code.len, pc);
}

test "Builder: profiled arithmetic owns compact binary type profiles" {
    var b = Builder.init(testing.allocator);
    errdefer b.deinit();
    const span: Span = .{ .start = 0, .end = 1 };
    const lhs = try b.reserveRegister();

    try b.emitBinary(.mul, span, lhs);
    try b.emitBinary(.div, span, lhs);
    var chunk = try b.finish();
    defer chunk.deinit(testing.allocator);

    try testing.expectEqual(@as(usize, 8), chunk.code.len);
    try testing.expectEqual(Op.mul, @as(Op, @enumFromInt(chunk.code[0])));
    try testing.expectEqual(lhs, chunk.code[1]);
    try testing.expectEqual(@as(u16, 0), std.mem.readInt(u16, chunk.code[2..4], .little));
    try testing.expectEqual(Op.div, @as(Op, @enumFromInt(chunk.code[4])));
    try testing.expectEqual(lhs, chunk.code[5]);
    try testing.expectEqual(@as(u16, 1), std.mem.readInt(u16, chunk.code[6..8], .little));
    try testing.expectEqual(@as(u8, 3), Op.operandSize(.mul));
    try testing.expectEqual(@as(u8, 3), Op.operandSize(.div));
    try testing.expectEqual(@as(usize, 2), chunk.inline_binary_profiles.len);
    try testing.expectEqual(BinaryTypeMode.cold, chunk.inline_binary_profiles[0].mode());
    try testing.expectEqual(BinaryTypeMode.cold, chunk.inline_binary_profiles[1].mode());
    try testing.expectEqual(@as(usize, 1), @sizeOf(BinaryTypeProfile));

    chunk.inline_binary_profiles[0].observe(Value.fromInt32(6), Value.fromInt32(2));
    try testing.expectEqual(BinaryTypeMode.int32, chunk.inline_binary_profiles[0].mode());
    chunk.inline_binary_profiles[0].observe(Value.fromDouble(1.5), Value.fromInt32(2));
    try testing.expectEqual(BinaryTypeMode.number, chunk.inline_binary_profiles[0].mode());
    chunk.inline_binary_profiles[0].observe(Value.true_, Value.fromInt32(2));
    try testing.expectEqual(BinaryTypeMode.mixed, chunk.inline_binary_profiles[0].mode());

    var coercive: BinaryTypeProfile = .{};
    coercive.observe(Value.true_, Value.fromInt32(2));
    try testing.expectEqual(BinaryTypeMode.non_number, coercive.mode());
}

test "Builder: hot IC sites use byte indexes and retain u16 fallbacks" {
    var b = Builder.init(testing.allocator);
    errdefer b.deinit();
    const span: Span = .{ .start = 0, .end = 1 };
    const r0 = try b.reserveRegister();
    const r1 = try b.reserveRegister();

    try b.emitLdaProperty(span, 7);
    try b.emitLdaPropertyReg(span, 8, r0);
    try b.emitStaProperty(span, 9, r0);
    try b.emitLdaComputed(span, r0);
    try b.emitStaComputed(span, r0, r1);
    try b.emitInOp(span, r0);
    try b.emitLdaGlobal(span, 10);
    try b.emitLdaGlobalOrUndef(span, 11);
    try b.emitForInOpen(span);
    try b.emitCall(span, r0, 0);
    try b.emitCallMethod(span, r0, r1, 2);
    try b.emitNewCall(span, r0, 1);
    try b.emitCallProperty(span, 12, r0, 1);

    var chunk = try b.finish();
    defer chunk.deinit(testing.allocator);
    var pc: usize = 0;
    const expected = [_]Op{
        .lda_property8,
        .lda_property_reg8,
        .sta_property8,
        .lda_computed8,
        .sta_computed8,
        .in_op8,
        .lda_global8,
        .lda_global_or_undef8,
        .for_in_open8,
        .call0_8,
        .call_method8,
        .new_call8,
        .call_property8,
    };
    for (expected) |op| {
        try testing.expectEqual(op, @as(Op, @enumFromInt(chunk.code[pc])));
        pc += 1 + op.operandSize();
    }

    var wide = Builder.init(testing.allocator);
    errdefer wide.deinit();
    wide.inline_load_cache_count = 256;
    try wide.emitLdaProperty(span, 300);
    var wide_chunk = try wide.finish();
    defer wide_chunk.deinit(testing.allocator);
    try testing.expectEqual(Op.lda_property, @as(Op, @enumFromInt(wide_chunk.code[0])));
}

test "Builder: property ICs use typed tables" {
    var b = Builder.init(testing.allocator);
    errdefer b.deinit();
    const span: Span = .{ .start = 0, .end = 1 };

    try b.emitLdaProperty(span, 0);
    try b.emitLdaGlobal(span, 1);
    try b.emitCallProperty(span, 2, 0, 0);
    try b.emitStaProperty(span, 3, 0);
    try b.emitLdaComputed(span, 0);
    try b.emitStaComputed(span, 0, 1);
    try b.emitInOp(span, 0);

    var chunk = try b.finish();
    defer chunk.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 3), chunk.inline_load_caches.len);
    try testing.expectEqual(@as(usize, 1), chunk.inline_store_caches.len);
    try testing.expectEqual(@as(usize, 3), chunk.inline_computed_caches.len);
    try testing.expect(@sizeOf(LoadICCell) <= @sizeOf(StoreICCell));
    try testing.expect(@sizeOf(ComputedICCell) <= @sizeOf(StoreICCell));
    try testing.expect(@sizeOf(StoreICCell) <= 64);
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

test "Builder: store-load emission stays explicit until CFG optimization" {
    var b = Builder.init(testing.allocator);
    defer b.deinit();
    const span: Span = .{ .start = 0, .end = 1 };

    try b.emitStoreReg(span, 2);
    try b.emitLoadReg(span, 2);

    try testing.expectEqualSlices(u8, &.{ @intFromEnum(Op.star_2), @intFromEnum(Op.ldar_2) }, b.code.items);
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

    // Both jumps relax to i8. After threading, the first jumps directly
    // over the second to the return at byte 4: 4 - after(2) = +2.
    try testing.expectEqual(Op.jmp8, @as(Op, @enumFromInt(chunk.code[0])));
    const got_a: i8 = @bitCast(chunk.code[1]);
    try testing.expectEqual(@as(i8, 2), got_a);

    // The second jmp's operand is unchanged.
    try testing.expectEqual(Op.jmp8, @as(Op, @enumFromInt(chunk.code[2])));
    const got_b: i8 = @bitCast(chunk.code[3]);
    try testing.expectEqual(@as(i8, 0), got_b);
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

    // Relaxed layout: cond8(0..2), lda(2), jmp8(3..5), return(5).
    // Threaded target is return: 5 - after(2) = +3.
    try testing.expectEqual(Op.jmp_if_false8, @as(Op, @enumFromInt(chunk.code[0])));
    const got_a: i8 = @bitCast(chunk.code[1]);
    try testing.expectEqual(@as(i8, 3), got_a);
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

    // Self-loop detected; relaxation changes only its width.
    try testing.expectEqual(Op.jmp8, @as(Op, @enumFromInt(chunk.code[0])));
    const got: i8 = @bitCast(chunk.code[1]);
    try testing.expectEqual(@as(i8, -2), got);
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

    // First jmp still points at L1; both branches happen to relax to i8.
    try testing.expectEqual(Op.jmp8, @as(Op, @enumFromInt(chunk.code[0])));
    const got_a: i8 = @bitCast(chunk.code[1]);
    try testing.expectEqual(@as(i8, 0), got_a);
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

    // Relaxed jmp8 still skips the one-byte lda: target(3)-after(2)=1.
    try testing.expectEqual(Op.jmp8, @as(Op, @enumFromInt(chunk.code[0])));
    const got: i8 = @bitCast(chunk.code[1]);
    try testing.expectEqual(@as(i8, 1), got);
}

test "Builder: branch relaxation chooses i8, i16, and i32 widths" {
    const span: Span = .{ .start = 0, .end = 1 };

    var short = Builder.init(testing.allocator);
    errdefer short.deinit();
    try short.emitOp(.jmp, span);
    const short_patch = short.here();
    try short.emitI16(0);
    try short.emitOp(.lda_undefined, span);
    const short_target = short.here();
    try short.emitOp(.return_, span);
    try short.patchI16(short_patch, short_target);
    var short_chunk = try short.finish();
    defer short_chunk.deinit(testing.allocator);
    try testing.expectEqual(Op.jmp8, @as(Op, @enumFromInt(short_chunk.code[0])));
    try testing.expectEqual(@as(i8, 1), @as(i8, @bitCast(short_chunk.code[1])));

    var medium = Builder.init(testing.allocator);
    errdefer medium.deinit();
    try medium.emitOp(.jmp, span);
    const medium_patch = medium.here();
    try medium.emitI16(0);
    for (0..200) |_| try medium.emitOp(.lda_undefined, span);
    const medium_target = medium.here();
    try medium.emitOp(.return_, span);
    try medium.patchI16(medium_patch, medium_target);
    var medium_chunk = try medium.finish();
    defer medium_chunk.deinit(testing.allocator);
    try testing.expectEqual(Op.jmp, @as(Op, @enumFromInt(medium_chunk.code[0])));
    try testing.expectEqual(@as(i16, 200), std.mem.readInt(i16, medium_chunk.code[1..3], .little));

    var long = Builder.init(testing.allocator);
    errdefer long.deinit();
    try long.emitOp(.jmp, span);
    const long_patch = long.here();
    try long.emitI16(0);
    for (0..40_000) |_| try long.emitOp(.lda_undefined, span);
    const long_target = long.here();
    try long.emitOp(.return_, span);
    try long.patchI16(long_patch, long_target);
    var long_chunk = try long.finish();
    defer long_chunk.deinit(testing.allocator);
    try testing.expectEqual(Op.jmp32, @as(Op, @enumFromInt(long_chunk.code[0])));
    try testing.expectEqual(@as(i32, 40_000), std.mem.readInt(i32, long_chunk.code[1..5], .little));
}

test "Builder: branch relaxation remaps source positions and handlers" {
    var b = Builder.init(testing.allocator);
    errdefer b.deinit();
    const span: Span = .{ .start = 4, .end = 9 };

    try b.emitOp(.jmp_if_strict_eq, span);
    try b.emitU8(0);
    const patch = b.here();
    try b.emitI16(0);
    const protected_start = b.here();
    try b.emitOp(.lda_undefined, span);
    const protected_end = b.here();
    const target = b.here();
    try b.emitOp(.return_, span);
    try b.patchI16(patch, target);
    try b.addHandler(.{
        .start_pc = protected_start,
        .end_pc = protected_end,
        .handler_pc = target,
        .catch_register = 0,
    });

    var chunk = try b.finish();
    defer chunk.deinit(testing.allocator);
    try testing.expectEqual(Op.jmp_if_strict_eq8, @as(Op, @enumFromInt(chunk.code[0])));
    try testing.expectEqual(@as(u32, 3), chunk.source_positions[1].offset);
    try testing.expectEqual(@as(u32, 3), chunk.handlers[0].start_pc);
    try testing.expectEqual(@as(u32, 4), chunk.handlers[0].end_pc);
    try testing.expectEqual(@as(u32, 4), chunk.handlers[0].handler_pc);
}

test "Builder: branch relaxation remaps switch table targets" {
    var b = Builder.init(testing.allocator);
    errdefer b.deinit();
    const span: Span = .{ .start = 0, .end = 1 };

    const table = try b.reserveSwitchTable(0, 0);
    try b.emitOp(.switch_smi, span);
    try b.emitU8(0);
    try b.emitU16(table);

    try b.emitOp(.jmp, span);
    const patch = b.here();
    try b.emitI16(0);
    try b.emitOp(.lda_undefined, span);
    const target = b.here();
    try b.emitOp(.return_, span);
    try b.patchI16(patch, target);
    b.setSwitchTarget(table, 0, target);
    b.finishSwitchTable(table, target);

    var chunk = try b.finish();
    defer chunk.deinit(testing.allocator);
    try testing.expectEqual(Op.jmp8, @as(Op, @enumFromInt(chunk.code[4])));
    try testing.expectEqual(@as(u32, 7), chunk.switch_tables[0].targets[0]);
    try testing.expectEqual(@as(u32, 7), chunk.switch_tables[0].default_target);
    try testing.expectEqual(Op.return_, @as(Op, @enumFromInt(chunk.code[7])));
}

test "Chunk JIT state releases baseline continuations and optimized code" {
    const code_alloc = @import("../runtime/jit/code_alloc.zig");
    if (comptime !code_alloc.supported) return error.SkipZigTest;

    var executable = try code_alloc.CodeAllocator.init(testing.allocator, 64 * 1024);
    defer executable.deinit();
    var builder = Builder.init(testing.allocator);
    defer builder.deinit();
    const span: Span = .{ .start = 0, .end = 1 };
    try builder.emitOp(.lda_undefined, span);
    try builder.emitOp(.return_, span);
    var chunk = try builder.finish();
    var chunk_live = true;
    defer if (chunk_live) chunk.deinit(testing.allocator);

    var baseline = try executable.installOwned(code_alloc.ret42_stub);
    defer baseline.deinit();
    var continuations = try executable.installOwned(code_alloc.ret42_stub);
    defer continuations.deinit();
    var optimized = try executable.installOwned(code_alloc.ret42_stub);
    defer optimized.deinit();
    const installed = [_][*]const u8{
        baseline.bytes().?.ptr,
        continuations.bytes().?.ptr,
        optimized.bytes().?.ptr,
    };

    const state = chunk.jit_state.?;
    state.bistromath.publish(&baseline, &continuations, 1);
    state.ohaimark.publish(&optimized);
    try testing.expect(baseline.bytes() == null);
    try testing.expect(continuations.bytes() == null);
    try testing.expect(optimized.bytes() == null);
    chunk.deinit(testing.allocator);
    chunk_live = false;

    var reused: [3]code_alloc.InstalledCode = .{ .{}, .{}, .{} };
    defer for (&reused) |*slot| slot.deinit();
    for (&reused) |*slot| slot.* = try executable.installOwned(code_alloc.ret42_stub);
    for (installed) |want| {
        var found = false;
        for (reused) |slot| found = found or slot.bytes().?.ptr == want;
        try testing.expect(found);
    }
}
