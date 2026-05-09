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
pub const Handler = struct {
    start_pc: u32,
    end_pc: u32,
    handler_pc: u32,
    catch_register: ?u8,
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
    param_count: u8,
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

    pub fn deinit(self: *ClassTemplate, allocator: std.mem.Allocator) void {
        self.constructor_chunk.deinit(allocator);
        for (self.instance_methods) |*m| m.chunk.deinit(allocator);
        allocator.free(self.instance_methods);
        for (self.static_methods) |*m| m.chunk.deinit(allocator);
        allocator.free(self.static_methods);
        for (self.instance_fields) |*f| if (f.init_chunk) |*c| c.deinit(allocator);
        allocator.free(self.instance_fields);
        for (self.static_fields) |*f| if (f.init_chunk) |*c| c.deinit(allocator);
        allocator.free(self.static_fields);
        for (self.static_blocks) |*c| c.deinit(allocator);
        allocator.free(self.static_blocks);
    }
};

pub const MethodKind = enum { method, getter, setter };

pub const MethodTemplate = struct {
    /// Method name (`m`, `toString`, etc.). Borrowed slice into
    /// source. For private methods the compiler prefixes the
    /// name with the class's `private_prefix` so brand checks
    /// route correctly.
    name: []const u8,
    chunk: Chunk,
    param_count: u8,
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
};

pub const FieldTemplate = struct {
    name: []const u8,
    /// Sub-chunk that evaluates the initializer with `this`
    /// bound to the instance (or to the class for static
    /// fields). `null` for `class C { x; }` declared without
    /// an initializer — assigned `undefined` at runtime.
    init_chunk: ?Chunk,
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

    pub fn deinit(self: *Chunk, allocator: std.mem.Allocator) void {
        allocator.free(self.code);
        allocator.free(self.constants);
        allocator.free(self.source_positions);
        allocator.free(self.handlers);
        for (self.function_templates) |*t| t.chunk.deinit(allocator);
        allocator.free(self.function_templates);
        for (self.class_templates) |*t| t.deinit(allocator);
        allocator.free(self.class_templates);
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
        return .{
            .code = try self.code.toOwnedSlice(self.allocator),
            .constants = try self.constants.toOwnedSlice(self.allocator),
            .source_positions = try self.source_positions.toOwnedSlice(self.allocator),
            .handlers = try self.handlers.toOwnedSlice(self.allocator),
            .function_templates = try self.function_templates.toOwnedSlice(self.allocator),
            .class_templates = try self.class_templates.toOwnedSlice(self.allocator),
            .register_count = self.register_count,
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
