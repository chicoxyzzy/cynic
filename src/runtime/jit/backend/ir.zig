//! Language-neutral scalar SSA experiment. Cross-block values use block
//! arguments; there are no implicit heap effects or language-specific nodes.
pub const max_values = 2048;
pub const max_nodes = 4096;
pub const max_blocks = 256;
pub const max_arguments = 64;
pub const Type = enum { i32, i64, f32, f64 };
pub const Value = u32;
pub const Op = enum {
    constant,
    add,
    sub,
    mul,
    bit_and,
    bit_or,
    eq,
    lt_s,
    lt_u,
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
    feq,
    fne,
    flt,
    fgt,
    fle,
    fge,
    reinterpret,
    promote_f32,
    demote_f64,
    guard,
};
/// An opaque frontend-owned recovery key and values captured at this exact
/// point. Guards are ordered effects, not removable unused computations.
pub const SideExit = struct { id: u32, values: []const Value };
pub const Node = struct {
    op: Op,
    out: ?Value = null,
    lhs: Value = 0,
    rhs: Value = 0,
    immediate: u64 = 0,
    exit: ?SideExit = null,
};
pub const Edge = struct { target: u32, args: []const Value };
pub const Terminator = union(enum) {
    return_: Value,
    jump: Edge,
    branch: struct { condition: Value, taken: Edge, fallthrough: Edge },
};
pub const Block = struct {
    params: []const Value,
    nodes: []const Node = &.{},
    terminator: Terminator = .{ .return_ = 0 },
};

pub const Graph = struct {
    types: []const Type,
    blocks: []const Block,
    argument_types: []const Type,
    result_type: Type,

    pub fn verify(self: Graph) !void {
        if (self.types.len > max_values or self.blocks.len > max_blocks or
            self.argument_types.len > max_arguments) return error.PrototypeLimit;
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
                const out = node.out orelse return error.InvalidGraph;
                if (out >= self.types.len) return error.InvalidGraph;
                const out_type = self.types[out];
                if (node.op == .constant) {
                    if (normalize(out_type, node.immediate) != node.immediate) return error.InvalidGraph;
                } else if (conversionTypes(node.op)) |conversion| {
                    try self.use(node.lhs, &available);
                    if (self.types[node.lhs] != conversion.input or out_type != conversion.output) return error.InvalidGraph;
                } else if (node.op == .reinterpret) {
                    try self.use(node.lhs, &available);
                    const source = self.types[node.lhs];
                    if (isFloat(source) == isFloat(out_type) or is32(source) != is32(out_type)) return error.InvalidGraph;
                } else {
                    try self.use(node.lhs, &available);
                    const input_type = self.types[node.lhs];
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
                .return_ => |value| {
                    try self.use(value, &available);
                    if (self.types[value] != self.result_type) return error.InvalidGraph;
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
        .fadd, .fsub, .fmul, .fdiv, .fmin, .fmax, .fcopysign, .fabs, .fneg, .fsqrt, .feq, .fne, .flt, .fgt, .fle, .fge, .promote_f32, .demote_f64 => true,
        else => false,
    };
}

pub fn isComparison(op: Op) bool {
    return switch (op) {
        .eq, .lt_s, .lt_u, .ge_s, .ge_u, .feq, .fne, .flt, .fgt, .fle, .fge => true,
        else => false,
    };
}

pub fn inputCount(op: Op) u2 {
    return switch (op) {
        .constant => 0,
        .guard, .sext_i32, .zext_i32, .trunc_i64, .reinterpret, .promote_f32, .demote_f64, .fabs, .fneg, .fsqrt => 1,
        .add, .sub, .mul, .bit_and, .bit_or, .eq, .lt_s, .lt_u, .ge_s, .ge_u, .fadd, .fsub, .fmul, .fdiv, .fmin, .fmax, .fcopysign, .feq, .fne, .flt, .fgt, .fle, .fge => 2,
    };
}

test {
    _ = @import("tests.zig");
    _ = @import("float_test.zig");
}
