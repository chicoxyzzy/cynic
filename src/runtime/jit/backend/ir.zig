//! Language-neutral scalar SSA experiment. Cross-block values use block
//! arguments; there are no implicit heap effects or language-specific nodes.
pub const max_values = 2048;
pub const max_nodes = 4096;
pub const max_blocks = 256;
pub const max_arguments = 64;
pub const max_memories = 64;
pub const Type = enum { i32, i64, f32, f64 };
pub const Value = u32;
pub const Op = enum {
    constant,
    add,
    sub,
    mul,
    div_s,
    div_u,
    rem_s,
    rem_u,
    bit_and,
    bit_or,
    bit_xor,
    shl,
    shr_s,
    shr_u,
    rotl,
    rotr,
    clz,
    ctz,
    popcnt,
    sext8,
    sext16,
    sext32,
    eq,
    ne,
    lt_s,
    lt_u,
    gt_s,
    gt_u,
    le_s,
    le_u,
    ge_s,
    ge_u,
    sext_i32,
    zext_i32,
    trunc_i64,
    fadd,
    fsub,
    fmul,
    fdiv,
    fmin,
    fmax,
    fcopysign,
    fabs,
    fneg,
    fsqrt,
    fceil,
    ffloor,
    ftrunc,
    fnearest,
    convert_s,
    convert_u,
    trunc_s,
    trunc_u,
    trunc_sat_s,
    trunc_sat_u,
    feq,
    fne,
    flt,
    fgt,
    fle,
    fge,
    reinterpret,
    promote_f32,
    demote_f64,
    load,
    store,
    call,
    guard,
};
pub const MemoryWidth = enum(u8) {
    byte = 1,
    half = 2,
    word = 4,
    double = 8,

    pub fn bytes(self: MemoryWidth) usize {
        return @backingInt(self);
    }
};
/// Bounded little-endian byte access. Region IDs select frontend-provided
/// views; they are not non-aliasing promises. Offset addition never wraps.
pub const MemoryAccess = struct { region: u32 = 0, width: MemoryWidth, offset: u64 = 0, signed: bool = false };
/// An opaque frontend-owned recovery key and values captured at this exact
/// point. Guards are ordered effects, not removable unused computations.
pub const SideExit = struct { id: u32, values: []const Value };
/// Symbolic runtime call. The frontend owns the target and root interpretation;
/// snapshots are read-only because the current collector does not move objects.
pub const Call = struct {
    target: u32,
    arguments: []const Value,
    parameter_types: []const Type,
    results: []const Value,
    result_types: []const Type,
    /// Raw host callbacks see caller controls; language helpers keep strict FP.
    fp_mode: enum { host, strict } = .host,
    safepoint: SideExit,
};
pub const TrapReason = enum(u32) {
    division_by_zero = 1,
    integer_overflow = 2,
    unreachable_code = 3,
    invalid_conversion = 4,
    memory_out_of_bounds = 5,

    pub fn toError(self: TrapReason) error{ IntegerDivideByZero, IntegerOverflow, Unreachable, InvalidConversionToInteger, OutOfBoundsMemoryAccess } {
        return switch (self) {
            .division_by_zero => error.IntegerDivideByZero,
            .integer_overflow => error.IntegerOverflow,
            .unreachable_code => error.Unreachable,
            .invalid_conversion => error.InvalidConversionToInteger,
            .memory_out_of_bounds => error.OutOfBoundsMemoryAccess,
        };
    }
};
/// The location is opaque to the backend; Wasm uses an instruction byte offset.
pub const Trap = struct { reason: TrapReason, site: u32 };
pub const Node = struct {
    op: Op,
    out: ?Value = null,
    lhs: Value = 0,
    rhs: Value = 0,
    immediate: u64 = 0,
    exit: ?SideExit = null,
    trap_site: ?u32 = null,
    memory: ?MemoryAccess = null,
    call: ?Call = null,

    pub fn outputs(self: Node) OutputIterator {
        return if (self.call) |call| .{ .many = call.results } else .{ .single = self.out };
    }
};
pub const OutputIterator = struct {
    single: ?Value = null,
    many: []const Value = &.{},

    pub fn next(self: *OutputIterator) ?Value {
        if (self.single) |value| {
            self.single = null;
            return value;
        }
        if (self.many.len == 0) return null;
        const value = self.many[0];
        self.many = self.many[1..];
        return value;
    }
};
pub const Edge = struct { target: u32, args: []const Value };
pub const Terminator = union(enum) {
    trap: Trap,
    return_: []const Value,
    jump: Edge,
    branch: struct { condition: Value, taken: Edge, fallthrough: Edge },
};
pub const Block = struct {
    params: []const Value,
    nodes: []const Node = &.{},
    terminator: Terminator = .{ .return_ = &.{} },
};

pub const Graph = struct {
    types: []const Type,
    blocks: []const Block,
    argument_types: []const Type,
    result_types: []const Type,
    memory_count: u32 = 0,

    pub fn verify(self: Graph) !void {
        if (self.types.len > max_values or self.blocks.len > max_blocks or
            self.argument_types.len > max_arguments or self.result_types.len > max_arguments or self.memory_count > max_memories) return error.PrototypeLimit;
        if (self.blocks.len == 0 or self.blocks[0].params.len != self.argument_types.len)
            return error.InvalidGraph;
        var defined: [max_values]bool = @splat(false);
        var node_count: usize = 0;
        for (self.blocks, 0..) |block, block_index| {
            if (block.params.len > max_arguments) return error.PrototypeLimit;
            if (block.nodes.len > max_nodes - node_count) return error.PrototypeLimit;
            node_count += block.nodes.len;
            var available: [max_values]bool = @splat(false);
            for (block.params, 0..) |param, i| {
                try self.define(param, &defined, &available);
                if (block_index == 0 and self.types[param] != self.argument_types[i]) return error.InvalidGraph;
            }
            for (block.nodes) |node| {
                if (mayTrap(node.op) != (node.trap_site != null)) return error.InvalidGraph;
                if (isMemoryOp(node.op) != (node.memory != null)) return error.InvalidGraph;
                if ((node.op == .call) != (node.call != null)) return error.InvalidGraph;
                if (node.op == .guard) {
                    if (node.out != null) return error.InvalidGraph;
                    try self.use(node.lhs, &available);
                    if (self.types[node.lhs] != .i32) return error.InvalidGraph;
                    const side_exit = node.exit orelse return error.InvalidGraph;
                    if (side_exit.values.len > max_arguments) return error.PrototypeLimit;
                    for (side_exit.values) |value| try self.use(value, &available);
                    continue;
                }
                if (node.exit != null) return error.InvalidGraph;
                if (node.call) |call| {
                    if (call.arguments.len > max_arguments or call.results.len > max_arguments or call.result_types.len > max_arguments or call.safepoint.values.len > max_arguments) return error.PrototypeLimit;
                    if (node.out != null or call.arguments.len != call.parameter_types.len or call.results.len != call.result_types.len) return error.InvalidGraph;
                    for (call.arguments, call.parameter_types) |value, ty| {
                        try self.use(value, &available);
                        if (self.types[value] != ty) return error.InvalidGraph;
                    }
                    for (call.safepoint.values) |value| try self.use(value, &available);
                    for (call.results, call.result_types) |out, ty| {
                        try self.define(out, &defined, &available);
                        if (self.types[out] != ty) return error.InvalidGraph;
                    }
                    continue;
                }
                if (node.memory) |access| {
                    if (access.region >= self.memory_count) return error.InvalidGraph;
                    try self.use(node.lhs, &available);
                    if (isFloat(self.types[node.lhs])) return error.InvalidGraph;
                    const value = if (node.op == .load) node.out orelse return error.InvalidGraph else node.rhs;
                    if (value >= self.types.len) return error.InvalidGraph;
                    const ty = self.types[value];
                    const width: usize = if (is32(ty)) 4 else 8;
                    if (access.width.bytes() > width or
                        (isFloat(ty) and access.width.bytes() != width) or
                        (access.signed and (node.op == .store or isFloat(ty) or access.width.bytes() == width))) return error.InvalidGraph;
                    if (node.op == .load) {
                        try self.define(value, &defined, &available);
                    } else {
                        if (node.out != null) return error.InvalidGraph;
                        try self.use(value, &available);
                    }
                    continue;
                }
                const out = node.out orelse return error.InvalidGraph;
                if (out >= self.types.len) return error.InvalidGraph;
                const out_type = self.types[out];
                if (node.op == .constant) {
                    if (normalize(out_type, node.immediate) != node.immediate) return error.InvalidGraph;
                } else if (conversionTypes(node.op)) |conversion| {
                    try self.use(node.lhs, &available);
                    if (self.types[node.lhs] != conversion.input or out_type != conversion.output) return error.InvalidGraph;
                } else if (isNumericConversion(node.op)) {
                    try self.use(node.lhs, &available);
                    const to_float = node.op == .convert_s or node.op == .convert_u;
                    if (isFloat(self.types[node.lhs]) == to_float or isFloat(out_type) != to_float) return error.InvalidGraph;
                } else if (node.op == .reinterpret) {
                    try self.use(node.lhs, &available);
                    const source = self.types[node.lhs];
                    if (isFloat(source) == isFloat(out_type) or is32(source) != is32(out_type)) return error.InvalidGraph;
                } else {
                    try self.use(node.lhs, &available);
                    const input_type = self.types[node.lhs];
                    if (node.op == .sext32 and input_type != .i64) return error.InvalidGraph;
                    if (isFloatOp(node.op) != isFloat(input_type)) return error.InvalidGraph;
                    if (inputCount(node.op) == 2) {
                        try self.use(node.rhs, &available);
                        if (input_type != self.types[node.rhs]) return error.InvalidGraph;
                    }
                    const expected = if (isComparison(node.op)) Type.i32 else input_type;
                    if (out_type != expected) return error.InvalidGraph;
                }
                try self.define(out, &defined, &available);
            }
            switch (block.terminator) {
                .trap => {},
                .return_ => |values| {
                    if (values.len != self.result_types.len) return error.InvalidGraph;
                    for (values, self.result_types) |value, ty| {
                        try self.use(value, &available);
                        if (self.types[value] != ty) return error.InvalidGraph;
                    }
                },
                .jump => |edge| try self.verifyEdge(edge, &available),
                .branch => |branch| {
                    try self.use(branch.condition, &available);
                    if (self.types[branch.condition] != .i32) return error.InvalidGraph;
                    try self.verifyEdge(branch.taken, &available);
                    try self.verifyEdge(branch.fallthrough, &available);
                },
            }
        }
        for (defined[0..self.types.len]) |present| if (!present) return error.InvalidGraph;
    }

    fn define(self: Graph, value: Value, defined: *[max_values]bool, available: *[max_values]bool) !void {
        if (value >= self.types.len or defined[value]) return error.InvalidGraph;
        defined[value] = true;
        available[value] = true;
    }

    fn use(self: Graph, value: Value, available: *const [max_values]bool) !void {
        if (value >= self.types.len or !available[value]) return error.InvalidGraph;
    }

    fn verifyEdge(self: Graph, edge: Edge, available: *const [max_values]bool) !void {
        if (edge.target == 0 or edge.target >= self.blocks.len) return error.InvalidGraph;
        const params = self.blocks[edge.target].params;
        if (edge.args.len != params.len) return error.InvalidGraph;
        for (edge.args, params) |arg, param| {
            try self.use(arg, available);
            if (param >= self.types.len or self.types[arg] != self.types[param]) return error.InvalidGraph;
        }
    }
};

pub fn normalize(ty: Type, value: u64) u64 {
    return if (is32(ty)) @as(u32, @truncate(value)) else value;
}

pub fn is32(ty: Type) bool {
    return ty == .i32 or ty == .f32;
}

pub fn isFloat(ty: Type) bool {
    return ty == .f32 or ty == .f64;
}

pub fn conversionTypes(op: Op) ?struct { input: Type, output: Type } {
    return switch (op) {
        .sext_i32, .zext_i32 => .{ .input = .i32, .output = .i64 },
        .trunc_i64 => .{ .input = .i64, .output = .i32 },
        .promote_f32 => .{ .input = .f32, .output = .f64 },
        .demote_f64 => .{ .input = .f64, .output = .f32 },
        else => null,
    };
}

pub fn isFloatOp(op: Op) bool {
    return switch (op) {
        .fadd, .fsub, .fmul, .fdiv, .fmin, .fmax, .fcopysign, .fabs, .fneg, .fsqrt, .fceil, .ffloor, .ftrunc, .fnearest, .feq, .fne, .flt, .fgt, .fle, .fge, .promote_f32, .demote_f64 => true,
        else => false,
    };
}

pub fn isNumericConversion(op: Op) bool {
    return switch (op) {
        .convert_s, .convert_u, .trunc_s, .trunc_u, .trunc_sat_s, .trunc_sat_u => true,
        else => false,
    };
}

pub fn isMemoryOp(op: Op) bool {
    return op == .load or op == .store;
}

pub fn isComparison(op: Op) bool {
    return switch (op) {
        .eq, .ne, .lt_s, .lt_u, .gt_s, .gt_u, .le_s, .le_u, .ge_s, .ge_u, .feq, .fne, .flt, .fgt, .fle, .fge => true,
        else => false,
    };
}

pub fn inputCount(op: Op) u2 {
    return switch (op) {
        .constant, .call => 0,
        .load => 1,
        .store => 2,
        .fceil, .ffloor, .ftrunc, .fnearest, .convert_s, .convert_u, .trunc_s, .trunc_u, .trunc_sat_s, .trunc_sat_u => 1,
        .guard, .sext_i32, .zext_i32, .trunc_i64, .reinterpret, .promote_f32, .demote_f64, .fabs, .fneg, .fsqrt, .clz, .ctz, .popcnt, .sext8, .sext16, .sext32 => 1,
        .add, .sub, .mul, .div_s, .div_u, .rem_s, .rem_u, .bit_and, .bit_or, .bit_xor, .shl, .shr_s, .shr_u, .rotl, .rotr, .eq, .ne, .lt_s, .lt_u, .gt_s, .gt_u, .le_s, .le_u, .ge_s, .ge_u, .fadd, .fsub, .fmul, .fdiv, .fmin, .fmax, .fcopysign, .feq, .fne, .flt, .fgt, .fle, .fge => 2,
    };
}

pub const Effects = struct {
    reads_memory: bool = false,
    writes_memory: bool = false,
    may_trap: bool = false,
    exits: bool = false,
    safepoint: bool = false,

    pub fn isPure(self: Effects) bool {
        return !self.reads_memory and !self.writes_memory and !self.may_trap and !self.exits and !self.safepoint;
    }
};

pub fn effects(op: Op) Effects {
    // Exhaustive: new operations must declare their observable effects.
    return switch (op) {
        .guard => .{ .exits = true },
        .div_s, .div_u, .rem_s, .rem_u, .trunc_s, .trunc_u => .{ .may_trap = true },
        .load => .{ .reads_memory = true, .may_trap = true },
        .store => .{ .writes_memory = true, .may_trap = true },
        .call => .{ .reads_memory = true, .writes_memory = true, .may_trap = true, .safepoint = true },
        .fceil, .ffloor, .ftrunc, .fnearest, .convert_s, .convert_u, .trunc_sat_s, .trunc_sat_u => .{},
        .constant, .add, .sub, .mul, .bit_and, .bit_or, .bit_xor, .shl, .shr_s, .shr_u, .rotl, .rotr, .clz, .ctz, .popcnt, .sext8, .sext16, .sext32, .eq, .ne, .lt_s, .lt_u, .gt_s, .gt_u, .le_s, .le_u, .ge_s, .ge_u, .sext_i32, .zext_i32, .trunc_i64, .fadd, .fsub, .fmul, .fdiv, .fmin, .fmax, .fcopysign, .fabs, .fneg, .fsqrt, .feq, .fne, .flt, .fgt, .fle, .fge, .reinterpret, .promote_f32, .demote_f64 => .{},
    };
}

pub fn mayTrap(op: Op) bool {
    return effects(op).may_trap;
}

test {
    _ = @import("tests.zig");
    _ = @import("float_test.zig");
    _ = @import("integer_test.zig");
    _ = @import("conversion_test.zig");
    _ = @import("fp_environment_test.zig");
    _ = @import("memory_test.zig");
    _ = @import("call_test.zig");
    _ = @import("results_test.zig");
}
