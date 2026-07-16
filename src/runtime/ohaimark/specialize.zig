//! Pure Ohaimark specialization planning. This pass computes monotone value
//! facts over block-argument SSA and records lowering choices plus explicit IC
//! assumptions. It emits no code and mutates neither the graph nor runtime
//! state, so its reasoning can be tested before deoptimization exists.

const std = @import("std");

const feedback = @import("feedback.zig");
const ir = @import("ir.zig");
const Shape = @import("../shape.zig").Shape;

pub const Type = struct {
    bits: u16,

    const undefined_bit: u16 = 1 << 0;
    const null_bit: u16 = 1 << 1;
    const boolean_bit: u16 = 1 << 2;
    const int32_bit: u16 = 1 << 3;
    const double_bit: u16 = 1 << 4;
    const string_bit: u16 = 1 << 5;
    const object_bit: u16 = 1 << 6;
    const function_bit: u16 = 1 << 7;
    const symbol_bit: u16 = 1 << 8;
    const bigint_bit: u16 = 1 << 9;
    const hole_bit: u16 = 1 << 10;

    pub const bottom: Type = .{ .bits = 0 };
    pub const undefined_: Type = .{ .bits = undefined_bit };
    pub const null_: Type = .{ .bits = null_bit };
    pub const boolean: Type = .{ .bits = boolean_bit };
    pub const int32: Type = .{ .bits = int32_bit };
    pub const double: Type = .{ .bits = double_bit };
    pub const number: Type = .{ .bits = int32_bit | double_bit };
    pub const string: Type = .{ .bits = string_bit };
    pub const object: Type = .{ .bits = object_bit };
    pub const function: Type = .{ .bits = function_bit };
    pub const symbol: Type = .{ .bits = symbol_bit };
    pub const bigint: Type = .{ .bits = bigint_bit };
    pub const hole: Type = .{ .bits = hole_bit };
    pub const any: Type = .{ .bits = (1 << 11) - 1 };

    pub fn eql(self: Type, other: Type) bool {
        return self.bits == other.bits;
    }

    pub fn merge(self: Type, other: Type) Type {
        return .{ .bits = self.bits | other.bits };
    }

    pub fn isBottom(self: Type) bool {
        return self.bits == 0;
    }

    pub fn isSubsetOf(self: Type, other: Type) bool {
        return self.bits != 0 and (self.bits & ~other.bits) == 0;
    }
};

pub const Lowering = enum {
    none,
    generic,
    constant,
    checked_int32_add,
    checked_int32_sub,
    checked_int32_mul,
    strict_eq,
    logical_not,
    checked_boolean_not,
    less_than,
    load_named_generic,
    load_named_own,
    load_named_prototype,
    load_named_synthetic,
};

pub const AssumptionKind = enum {
    load_own,
    load_prototype,
    load_synthetic,
};

/// A removable optimization assumption. `feedback_index` tells future
/// codegen which live typed IC cell to guard at runtime. The copied shape and
/// scalar fields are realm-arena-stable compiler inputs; no GC-managed
/// prototype, callee, accessor value, or snapshot pointer is retained here.
pub const Assumption = struct {
    kind: AssumptionKind,
    feedback_index: u16,
    receiver_shape: ?*Shape,
    holder_shape: ?*Shape,
    slot: u32,
    revision: u64,
};

pub const NodeInfo = struct {
    result_type: Type = Type.bottom,
    lowering: Lowering = .none,
    folded: ?ir.Immediate = null,
    assumption: ?u32 = null,
};

pub const Plan = struct {
    allocator: std.mem.Allocator,
    node_info: []NodeInfo,
    assumptions: []Assumption,

    pub fn build(allocator: std.mem.Allocator, graph: *const ir.Graph) !Plan {
        const node_info = try allocator.alloc(NodeInfo, graph.nodes.len);
        errdefer allocator.free(node_info);
        for (node_info) |*info| info.* = .{};
        const incoming = try allocator.alloc(NodeInfo, graph.params.len);
        defer allocator.free(incoming);

        // Entry parameters have values supplied by the Lantern frame. Other
        // block parameters start at bottom and grow from incoming edge facts.
        if (graph.blocks.len != 0) {
            for (graph.blockParams(0)) |param| {
                node_info[param.value].result_type = Type.any;
                node_info[param.value].lowering = .generic;
            }
        }

        const iteration_limit = graph.nodes.len +| graph.params.len +| 2;
        var iteration: usize = 0;
        while (iteration < iteration_limit) : (iteration += 1) {
            var changed = false;

            for (graph.nodes, 0..) |node, node_index| {
                if (node.kind == .block_parameter) continue;
                const next = try inferNode(graph, node_info, @intCast(node_index));
                if (!infoEql(node_info[node_index], next)) {
                    node_info[node_index] = next;
                    changed = true;
                }
            }

            for (incoming) |*fact| fact.* = .{};
            for (graph.edges) |edge| {
                if (edge.to >= graph.blocks.len) return error.MalformedGraph;
                if (edge.to == 0) continue;
                const block = graph.blocks[edge.to];
                const params = graph.blockParams(edge.to);
                const arguments = graph.edgeArguments(edge);
                if (params.len != arguments.len) return error.MalformedGraph;
                for (arguments, 0..) |argument, argument_index| {
                    if (argument >= node_info.len) return error.MalformedGraph;
                    const param_index = @as(usize, block.param_start) + argument_index;
                    if (param_index >= incoming.len) return error.MalformedGraph;
                    incoming[param_index] = mergeFacts(incoming[param_index], node_info[argument]);
                }
            }
            for (graph.blocks, 0..) |block, block_index| {
                if (block_index == 0) continue;
                for (graph.blockParams(block_index), 0..) |param, param_offset| {
                    const param_index = @as(usize, block.param_start) + param_offset;
                    if (param_index >= incoming.len or param.value >= node_info.len) {
                        return error.MalformedGraph;
                    }
                    if (!infoEql(node_info[param.value], incoming[param_index])) {
                        node_info[param.value] = incoming[param_index];
                        changed = true;
                    }
                }
            }

            if (!changed) break;
        } else return error.AnalysisDidNotConverge;

        var assumptions: std.ArrayListUnmanaged(Assumption) = .empty;
        defer assumptions.deinit(allocator);
        for (graph.nodes, 0..) |node, node_index| {
            if (node.kind != .load_named) continue;
            const site = switch (node.payload) {
                .named_load => |named| named,
                else => return error.MalformedGraph,
            };
            if (site.feedback_index >= graph.feedback.loads.len) return error.MalformedGraph;
            const observed = graph.feedback.loads[site.feedback_index];
            const decision = loadDecision(observed);
            if (node_info[node_index].result_type.isBottom()) return error.MalformedGraph;
            node_info[node_index].lowering = decision.lowering;
            if (decision.kind) |kind| {
                if (assumptions.items.len > std.math.maxInt(u32)) return error.GraphTooLarge;
                const assumption_index: u32 = @intCast(assumptions.items.len);
                try assumptions.append(allocator, .{
                    .kind = kind,
                    .feedback_index = site.feedback_index,
                    .receiver_shape = observed.receiver_shape,
                    .holder_shape = observed.holder_shape,
                    .slot = observed.slot,
                    .revision = observed.revision,
                });
                node_info[node_index].assumption = assumption_index;
            }
        }

        return .{
            .allocator = allocator,
            .node_info = node_info,
            .assumptions = try assumptions.toOwnedSlice(allocator),
        };
    }

    pub fn deinit(self: *Plan) void {
        self.allocator.free(self.node_info);
        self.allocator.free(self.assumptions);
        self.* = undefined;
    }
};

const LoadDecision = struct {
    lowering: Lowering,
    kind: ?AssumptionKind,
};

fn loadDecision(observed: feedback.Load) LoadDecision {
    return switch (observed.mode) {
        .cold => .{ .lowering = .load_named_generic, .kind = null },
        .own_data => .{ .lowering = .load_named_own, .kind = .load_own },
        .prototype_data => .{ .lowering = .load_named_prototype, .kind = .load_prototype },
        .synthetic_accessor => .{ .lowering = .load_named_synthetic, .kind = .load_synthetic },
    };
}

fn inferNode(graph: *const ir.Graph, facts: []const NodeInfo, id: ir.ValueId) !NodeInfo {
    if (id >= graph.nodes.len) return error.MalformedGraph;
    const node = graph.nodes[id];
    const inputs = graph.nodeInputs(id);
    for (inputs) |input| if (input >= facts.len) return error.MalformedGraph;

    return switch (node.kind) {
        .block_parameter => facts[id],
        .constant => inferConstant(node),
        .add => inferArithmetic(.add, facts, inputs),
        .sub => inferArithmetic(.sub, facts, inputs),
        .mul => inferArithmetic(.mul, facts, inputs),
        .strict_eq => inferStrictEq(facts, inputs),
        .logical_not => inferLogicalNot(facts, inputs),
        .less_than => inferLessThan(facts, inputs),
        .load_named => if (inputs.len == 1 and !facts[inputs[0]].result_type.isBottom())
            .{ .result_type = Type.any, .lowering = .load_named_generic }
        else
            .{},
        .jump, .branch, .return_ => .{},
    };
}

fn inferConstant(node: ir.Node) NodeInfo {
    const immediate = switch (node.payload) {
        .immediate => |value| value,
        else => return .{},
    };
    if (immediate == .constant_pool) {
        return .{ .result_type = Type.any, .lowering = .constant };
    }
    return .{
        .result_type = immediateType(immediate),
        .lowering = .constant,
        .folded = immediate,
    };
}

const Arithmetic = enum { add, sub, mul };

fn inferArithmetic(op: Arithmetic, facts: []const NodeInfo, inputs: []const ir.ValueId) NodeInfo {
    if (inputs.len != 2) return .{};
    const lhs = facts[inputs[0]];
    const rhs = facts[inputs[1]];
    if (lhs.result_type.isBottom() or rhs.result_type.isBottom()) return .{};

    if (intConstant(lhs.folded)) |x| if (intConstant(rhs.folded)) |y| {
        if (foldIntArithmetic(op, x, y)) |folded| {
            return .{
                .result_type = Type.int32,
                .lowering = .constant,
                .folded = .{ .int32 = folded },
            };
        }
    };

    if (lhs.result_type.eql(Type.int32) and rhs.result_type.eql(Type.int32)) {
        return .{
            .result_type = Type.number,
            .lowering = switch (op) {
                .add => .checked_int32_add,
                .sub => .checked_int32_sub,
                .mul => .checked_int32_mul,
            },
        };
    }
    if (lhs.result_type.isSubsetOf(Type.number) and
        rhs.result_type.isSubsetOf(Type.number))
    {
        return .{ .result_type = Type.number, .lowering = .generic };
    }
    return .{ .result_type = Type.any, .lowering = .generic };
}

fn inferStrictEq(facts: []const NodeInfo, inputs: []const ir.ValueId) NodeInfo {
    if (inputs.len != 2) return .{};
    const lhs = facts[inputs[0]];
    const rhs = facts[inputs[1]];
    if (lhs.result_type.isBottom() or rhs.result_type.isBottom()) return .{};
    if (knownStrictEqual(lhs.folded, rhs.folded)) |equal| {
        return .{
            .result_type = Type.boolean,
            .lowering = .constant,
            .folded = if (equal) .true_ else .false_,
        };
    }
    return .{ .result_type = Type.boolean, .lowering = .strict_eq };
}

fn inferLogicalNot(facts: []const NodeInfo, inputs: []const ir.ValueId) NodeInfo {
    if (inputs.len != 1) return .{};
    const input = facts[inputs[0]];
    if (input.result_type.isBottom()) return .{};
    if (logicalNotConstant(input.folded)) |folded| {
        return .{
            .result_type = Type.boolean,
            .lowering = .constant,
            .folded = folded,
        };
    }
    return .{
        .result_type = Type.boolean,
        .lowering = if (input.result_type.eql(Type.boolean))
            .logical_not
        else
            .checked_boolean_not,
    };
}

fn inferLessThan(facts: []const NodeInfo, inputs: []const ir.ValueId) NodeInfo {
    if (inputs.len != 2) return .{};
    const lhs = facts[inputs[0]];
    const rhs = facts[inputs[1]];
    if (lhs.result_type.isBottom() or rhs.result_type.isBottom()) return .{};
    if (intConstant(lhs.folded)) |x| if (intConstant(rhs.folded)) |y| {
        return .{
            .result_type = Type.boolean,
            .lowering = .constant,
            .folded = if (x < y) .true_ else .false_,
        };
    };
    return .{ .result_type = Type.boolean, .lowering = .less_than };
}

fn foldIntArithmetic(op: Arithmetic, lhs: i32, rhs: i32) ?i32 {
    const result = switch (op) {
        .add => @addWithOverflow(lhs, rhs),
        .sub => @subWithOverflow(lhs, rhs),
        .mul => @mulWithOverflow(lhs, rhs),
    };
    if (result[1] != 0) return null;
    // ECMAScript multiplication preserves negative zero. Int32 constants do
    // not encode -0, so leave a sign-negative zero product to generic code.
    if (op == .mul and result[0] == 0 and ((lhs < 0) != (rhs < 0))) return null;
    return result[0];
}

fn immediateType(value: ir.Immediate) Type {
    return switch (value) {
        .undefined_ => Type.undefined_,
        .null_ => Type.null_,
        .true_, .false_ => Type.boolean,
        .hole => Type.hole,
        .int32 => Type.int32,
        .constant_pool => Type.any,
    };
}

fn intConstant(value: ?ir.Immediate) ?i32 {
    const immediate = value orelse return null;
    return switch (immediate) {
        .int32 => |number| number,
        else => null,
    };
}

fn logicalNotConstant(value: ?ir.Immediate) ?ir.Immediate {
    const immediate = value orelse return null;
    const result = switch (immediate) {
        .undefined_, .null_ => true,
        .true_ => false,
        .false_ => true,
        .int32 => |number| number == 0,
        .hole, .constant_pool => return null,
    };
    return if (result) .true_ else .false_;
}

fn knownStrictEqual(lhs: ?ir.Immediate, rhs: ?ir.Immediate) ?bool {
    const a = lhs orelse return null;
    const b = rhs orelse return null;
    if (a == .constant_pool or b == .constant_pool or a == .hole or b == .hole) return null;
    return immediateEql(a, b);
}

fn mergeFacts(lhs: NodeInfo, rhs: NodeInfo) NodeInfo {
    if (lhs.result_type.isBottom()) return factOnly(rhs);
    if (rhs.result_type.isBottom()) return factOnly(lhs);
    const folded: ?ir.Immediate = if (lhs.folded != null and rhs.folded != null and
        immediateEql(lhs.folded.?, rhs.folded.?))
        lhs.folded
    else
        null;
    return .{
        .result_type = lhs.result_type.merge(rhs.result_type),
        .lowering = if (folded != null) .constant else .none,
        .folded = folded,
    };
}

fn factOnly(info: NodeInfo) NodeInfo {
    return .{
        .result_type = info.result_type,
        .lowering = if (info.folded != null) .constant else .none,
        .folded = info.folded,
    };
}

fn immediateEql(lhs: ir.Immediate, rhs: ir.Immediate) bool {
    if (std.meta.activeTag(lhs) != std.meta.activeTag(rhs)) return false;
    return switch (lhs) {
        .int32 => |value| value == rhs.int32,
        .constant_pool => |value| value == rhs.constant_pool,
        else => true,
    };
}

fn infoEql(lhs: NodeInfo, rhs: NodeInfo) bool {
    if (!lhs.result_type.eql(rhs.result_type) or lhs.lowering != rhs.lowering or
        lhs.assumption != rhs.assumption)
    {
        return false;
    }
    if (lhs.folded == null or rhs.folded == null) return lhs.folded == null and rhs.folded == null;
    return immediateEql(lhs.folded.?, rhs.folded.?);
}
