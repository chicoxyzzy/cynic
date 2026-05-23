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

/// Inline-cache cell — one per property-access callsite. The
/// interpreter records the last receiver's `(shape, slot)` after a
/// successful own-data lookup; on the next hit, a shape pointer
/// compare and a `slots[slot]` load skip the full lookup.
///
/// Monomorphic: a miss overwrites the cell, no polymorphism / chain.
/// Hermes-style: no JIT, the cache lives entirely in the interpreter.
///
/// `shape == null` is the cold / un-cacheable state (the last lookup
/// hit a dictionary-mode object, an accessor, the prototype chain,
/// or simply hasn't run yet). Initialised that way at chunk
/// finalisation.
pub const ICCell = struct {
    shape: ?*Shape = null,
    slot: u32 = 0,
};

/// Inline-cache cell for `call_method`. Caches the last callee
/// observed at the call site so subsequent calls can skip the
/// callable check, the proxy / revocable-proxy / bound-target
/// exotic dispatch, and the `valueAsFunction` decode — going
/// straight to `callJSFunction(cached_fn, ...)`. Monomorphic.
///
/// `callee == null` is cold / un-cacheable (last callee was
/// exotic, or hasn't run yet). The miss path only refills when
/// the slow-path callee turned out to be a plain (non-bound,
/// non-proxy, non-revoked) JSFunction.
///
/// The cached pointer is a GC-heap allocation, unlike the Shape
/// pointers in `ICCell` (arena-stable). After the GC mark phase
/// the heap walks every reachable chunk's `inline_call_caches`
/// and nulls cells whose callee isn't marked, so a swept-and-
/// reused address cannot reawaken a stale cell.
pub const CallICCell = struct {
    callee: ?*@import("../runtime/function.zig").JSFunction = null,
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

pub const Chunk = struct {
    code: []const u8,
    constants: []const Value,
    source_positions: []const SourcePos,
    handlers: []const Handler,
    function_templates: []FunctionTemplate,
    class_templates: []ClassTemplate,
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
    /// function or arrow). Drives `interpreter.run` to route the
    /// chunk through `startAsyncCall` so the body runs as a
    /// JSGenerator-backed async frame and the `await_` opcode has
    /// a place to suspend. Always false for scripts and for
    /// function-body chunks (their `await` is inside an async
    /// function, which is handled separately).
    is_async_module: bool = false,
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

    pub fn deinit(self: *Chunk, allocator: std.mem.Allocator) void {
        allocator.free(self.code);
        allocator.free(self.constants);
        allocator.free(self.source_positions);
        allocator.free(self.handlers);
        for (self.function_templates) |*t| t.chunk.deinit(allocator);
        allocator.free(self.function_templates);
        for (self.class_templates) |*t| t.deinit(allocator);
        allocator.free(self.class_templates);
        allocator.free(self.inline_caches);
        allocator.free(self.inline_call_caches);
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
    register_count: u8 = 0,
    /// Surfaced on the finished `Chunk` as `.is_async_module`.
    /// Set by `compileModuleAsChunk` after walking the body's
    /// top-level emit for any `.await_` opcode (tracked via the
    /// compiler's `module_has_top_level_await` flag).
    is_async_module: bool = false,
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
        try self.code.append(self.allocator, @intFromEnum(op));
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

    /// Transfer ownership of the accumulated buffers into a Chunk.
    /// The builder is empty after this call; `deinit` is a no-op.
    pub fn finish(self: *Builder) !Chunk {
        const ics = try self.allocator.alloc(ICCell, self.inline_cache_count);
        for (ics) |*c| c.* = .{};
        const call_ics = try self.allocator.alloc(CallICCell, self.inline_call_cache_count);
        for (call_ics) |*c| c.* = .{};
        return .{
            .code = try self.code.toOwnedSlice(self.allocator),
            .constants = try self.constants.toOwnedSlice(self.allocator),
            .source_positions = try self.source_positions.toOwnedSlice(self.allocator),
            .handlers = try self.handlers.toOwnedSlice(self.allocator),
            .function_templates = try self.function_templates.toOwnedSlice(self.allocator),
            .class_templates = try self.class_templates.toOwnedSlice(self.allocator),
            .register_count = self.register_count,
            .is_async_module = self.is_async_module,
            .global_lexical_base = self.global_lexical_base,
            .inline_caches = ics,
            .inline_call_caches = call_ics,
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
