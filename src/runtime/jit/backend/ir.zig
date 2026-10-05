//! Language-neutral integer SSA experiment. Cross-block values use block
//! arguments; there are no implicit heap effects or language-specific nodes.
pub const max_values = 2048;
pub const max_nodes = 4096;
pub const max_blocks = 256;
pub const max_arguments = 64;
pub const Type = enum { i32, i64 };
pub const Value = u32;
pub const Op = enum { constant, add, sub, mul, bit_and, bit_or, eq, lt_s, lt_u, ge_s, ge_u, sext_i32, zext_i32, trunc_i64, guard };
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
                } else if (isConversion(node.op)) {
                    try self.use(node.lhs, &available);
                    const source: Type = if (node.op == .trunc_i64) .i64 else .i32;
                    const result: Type = if (node.op == .trunc_i64) .i32 else .i64;
                    if (self.types[node.lhs] != source or out_type != result) return error.InvalidGraph;
                } else {
                    try self.use(node.lhs, &available);
                    try self.use(node.rhs, &available);
                    if (self.types[node.lhs] != self.types[node.rhs]) return error.InvalidGraph;
                    const expected = switch (node.op) {
                        .add, .sub, .mul, .bit_and, .bit_or => self.types[node.lhs],
                        else => Type.i32,
                    };
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
    return if (ty == .i32) @as(u32, @truncate(value)) else value;
}

pub fn isConversion(op: Op) bool {
    return op == .sext_i32 or op == .zext_i32 or op == .trunc_i64;
}

test {
    _ = @import("tests.zig");
}
