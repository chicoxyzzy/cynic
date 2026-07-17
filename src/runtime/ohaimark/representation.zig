//! Ohaimark value representation selection.
//!
//! The first representation lattice is deliberately narrow: optimized int32
//! values stay unboxed until a tagged use requires boxing, while every other
//! JavaScript value remains tagged. Checked int32 consumers may request an
//! unbox guard from tagged producers; CFG edges never carry such guards because
//! they have no owning deopt point.

const std = @import("std");

const ir = @import("ir.zig");
const specialize = @import("specialize.zig");

pub const Kind = enum {
    none,
    tagged,
    int32,
};

pub const Conversion = enum {
    none,
    box_int32,
    check_int32,
};

pub const Plan = struct {
    allocator: std.mem.Allocator,
    outputs: []Kind,
    /// Aligned with `Graph.inputs`, including both node operands and edge
    /// arguments. `.none` means a folded node does not consume that operand.
    input_requirements: []Kind,

    pub fn build(
        allocator: std.mem.Allocator,
        graph: *const ir.Graph,
        specialization: *const specialize.Plan,
    ) !Plan {
        if (specialization.node_info.len != graph.nodes.len) {
            return error.MalformedGraph;
        }

        const outputs = try allocator.alloc(Kind, graph.nodes.len);
        errdefer allocator.free(outputs);
        const input_requirements = try allocator.alloc(Kind, graph.inputs.len);
        errdefer allocator.free(input_requirements);

        try computeOutputs(allocator, graph, specialization, outputs);
        try computeInputRequirements(
            allocator,
            graph,
            specialization,
            outputs,
            input_requirements,
        );

        var plan: Plan = .{
            .allocator = allocator,
            .outputs = outputs,
            .input_requirements = input_requirements,
        };
        errdefer plan.deinit();
        try plan.verify(graph, specialization);
        return plan;
    }

    pub fn deinit(self: *Plan) void {
        self.allocator.free(self.outputs);
        self.allocator.free(self.input_requirements);
        self.* = undefined;
    }

    pub fn verify(
        self: *const Plan,
        graph: *const ir.Graph,
        specialization: *const specialize.Plan,
    ) !void {
        if (specialization.node_info.len != graph.nodes.len or
            self.outputs.len != graph.nodes.len or
            self.input_requirements.len != graph.inputs.len)
        {
            return error.MalformedGraph;
        }

        const expected_outputs = try self.allocator.alloc(Kind, graph.nodes.len);
        defer self.allocator.free(expected_outputs);
        try computeOutputs(self.allocator, graph, specialization, expected_outputs);
        if (!std.mem.eql(Kind, self.outputs, expected_outputs)) {
            return error.InvalidRepresentation;
        }

        const expected_inputs = try self.allocator.alloc(Kind, graph.inputs.len);
        defer self.allocator.free(expected_inputs);
        try computeInputRequirements(
            self.allocator,
            graph,
            specialization,
            expected_outputs,
            expected_inputs,
        );
        if (!std.mem.eql(Kind, self.input_requirements, expected_inputs)) {
            return error.InvalidRepresentation;
        }

        try verifyConversions(graph, specialization, self);
    }

    pub fn conversionAt(
        self: *const Plan,
        graph: *const ir.Graph,
        input_index: usize,
    ) !Conversion {
        if (self.outputs.len != graph.nodes.len or
            self.input_requirements.len != graph.inputs.len or
            input_index >= graph.inputs.len)
        {
            return error.MalformedGraph;
        }
        const producer = graph.inputs[input_index];
        if (producer >= self.outputs.len or self.outputs[producer] == .none) {
            return error.MalformedGraph;
        }
        return conversion(self.outputs[producer], self.input_requirements[input_index]);
    }

    pub fn nodeInputRequirement(
        self: *const Plan,
        graph: *const ir.Graph,
        node_id: ir.ValueId,
        operand_index: usize,
    ) !Kind {
        const input_index = try nodeInputIndex(graph, node_id, operand_index);
        if (self.input_requirements.len != graph.inputs.len) return error.MalformedGraph;
        return self.input_requirements[input_index];
    }

    pub fn nodeInputConversion(
        self: *const Plan,
        graph: *const ir.Graph,
        node_id: ir.ValueId,
        operand_index: usize,
    ) !Conversion {
        return self.conversionAt(
            graph,
            try nodeInputIndex(graph, node_id, operand_index),
        );
    }
};

fn computeOutputs(
    allocator: std.mem.Allocator,
    graph: *const ir.Graph,
    specialization: *const specialize.Plan,
    outputs: []Kind,
) !void {
    if (specialization.node_info.len != graph.nodes.len or outputs.len != graph.nodes.len) {
        return error.MalformedGraph;
    }
    try validateParameterLayout(allocator, graph);

    for (graph.nodes, specialization.node_info, outputs) |node, info, *output| {
        output.* = try initialOutput(node, info);
    }

    // Exact-int32 block parameters start optimistic. A parameter drops to
    // tagged if any incoming edge is tagged; repeating handles loop phis.
    var iteration: usize = 0;
    while (true) {
        var changed = false;
        for (graph.edges) |edge| {
            const target = try checkedEdgeTarget(graph, edge);
            const arguments = try checkedRange(
                graph.inputs.len,
                edge.argument_start,
                edge.argument_count,
            );
            for (0..arguments.len) |offset| {
                const parameter = graph.params[target.param_start + offset];
                const argument = graph.inputs[arguments.start + offset];
                if (parameter.value >= outputs.len or argument >= outputs.len or
                    outputs[parameter.value] == .none or outputs[argument] == .none)
                {
                    return error.MalformedGraph;
                }
                if (outputs[parameter.value] == .int32 and outputs[argument] != .int32) {
                    outputs[parameter.value] = .tagged;
                    changed = true;
                }
            }
        }
        if (!changed) break;
        if (iteration >= graph.params.len) return error.AnalysisDidNotConverge;
        iteration += 1;
    }
}

fn computeInputRequirements(
    allocator: std.mem.Allocator,
    graph: *const ir.Graph,
    specialization: *const specialize.Plan,
    outputs: []const Kind,
    input_requirements: []Kind,
) !void {
    if (specialization.node_info.len != graph.nodes.len or
        outputs.len != graph.nodes.len or
        input_requirements.len != graph.inputs.len)
    {
        return error.MalformedGraph;
    }
    @memset(input_requirements, .none);
    const claimed = try allocator.alloc(bool, graph.inputs.len);
    defer allocator.free(claimed);
    @memset(claimed, false);

    for (graph.nodes, specialization.node_info) |node, info| {
        const expected_count = nodeInputCount(node.kind);
        if (node.input_count != expected_count) return error.MalformedGraph;
        const inputs = try checkedRange(graph.inputs.len, node.input_start, node.input_count);
        try claimRange(claimed, inputs);
        const requirement = try nodeInputKind(node, info);
        for (inputs.start..inputs.end()) |input_index| {
            const producer = graph.inputs[input_index];
            if (producer >= outputs.len or outputs[producer] == .none) {
                return error.MalformedGraph;
            }
            input_requirements[input_index] = requirement;
        }
    }

    try validateEdgeLayout(allocator, graph);
    for (graph.edges) |edge| {
        const target = try checkedEdgeTarget(graph, edge);
        const arguments = try checkedRange(
            graph.inputs.len,
            edge.argument_start,
            edge.argument_count,
        );
        try claimRange(claimed, arguments);
        for (0..arguments.len) |offset| {
            const producer = graph.inputs[arguments.start + offset];
            const parameter = graph.params[target.param_start + offset];
            if (producer >= outputs.len or parameter.value >= outputs.len or
                outputs[producer] == .none or outputs[parameter.value] == .none)
            {
                return error.MalformedGraph;
            }
            input_requirements[arguments.start + offset] = outputs[parameter.value];
        }
    }

    for (claimed) |is_claimed| if (!is_claimed) return error.MalformedGraph;
}

fn initialOutput(node: ir.Node, info: specialize.NodeInfo) !Kind {
    try validateNodeContract(node, info);
    return switch (node.kind) {
        .block_parameter => switch (node.payload) {
            .parameter => if (info.result_type.eql(specialize.Type.int32)) .int32 else .tagged,
            else => error.MalformedGraph,
        },
        .constant => switch (node.payload) {
            .immediate => |immediate| switch (immediate) {
                .int32 => .int32,
                else => .tagged,
            },
            else => error.MalformedGraph,
        },
        .add => arithmeticOutput(info, .checked_int32_add),
        .sub => arithmeticOutput(info, .checked_int32_sub),
        .mul => arithmeticOutput(info, .checked_int32_mul),
        .div => divisionOutput(info),
        .strict_eq => switch (info.lowering) {
            .constant, .strict_eq => .tagged,
            else => error.MalformedGraph,
        },
        .logical_not => switch (info.lowering) {
            .constant, .logical_not, .checked_boolean_not => .tagged,
            else => error.MalformedGraph,
        },
        .less_than => switch (info.lowering) {
            .constant, .less_than => .tagged,
            else => error.MalformedGraph,
        },
        .load_named => switch (info.lowering) {
            .load_named_generic,
            .load_named_own,
            .load_named_prototype,
            .load_named_synthetic,
            => .tagged,
            else => error.MalformedGraph,
        },
        .load_this => if (info.lowering == .load_this) .tagged else error.MalformedGraph,
        .load_global => switch (info.lowering) {
            .load_global_generic, .load_global => .tagged,
            else => error.MalformedGraph,
        },
        .load_global_slot => if (info.lowering == .load_global_slot)
            .tagged
        else
            error.MalformedGraph,
        .load_environment => if (info.lowering == .load_environment)
            .tagged
        else
            error.MalformedGraph,
        .jump, .branch, .return_ => .none,
    };
}

fn arithmeticOutput(info: specialize.NodeInfo, checked: specialize.Lowering) !Kind {
    if (info.lowering == checked) {
        if (info.folded != null) return error.MalformedGraph;
        return .int32;
    }
    return switch (info.lowering) {
        .generic => if (info.folded == null) .tagged else error.MalformedGraph,
        .constant => switch (info.folded orelse return error.MalformedGraph) {
            .int32 => .int32,
            else => .tagged,
        },
        else => error.MalformedGraph,
    };
}

fn divisionOutput(info: specialize.NodeInfo) !Kind {
    if (info.lowering == .number_div) {
        if (info.folded != null) return error.MalformedGraph;
        return .tagged;
    }
    return arithmeticOutput(info, .checked_int32_div);
}

fn nodeInputKind(node: ir.Node, info: specialize.NodeInfo) !Kind {
    return switch (node.kind) {
        .block_parameter,
        .constant,
        .load_this,
        .load_global,
        .load_global_slot,
        .load_environment,
        .jump,
        => .none,
        .add => arithmeticInput(info, .checked_int32_add),
        .sub => arithmeticInput(info, .checked_int32_sub),
        .mul => arithmeticInput(info, .checked_int32_mul),
        .div => divisionInput(info),
        .strict_eq => switch (info.lowering) {
            .constant => .none,
            .strict_eq => .int32,
            else => error.MalformedGraph,
        },
        .logical_not => switch (info.lowering) {
            .constant => .none,
            .logical_not, .checked_boolean_not => .tagged,
            else => error.MalformedGraph,
        },
        .less_than => switch (info.lowering) {
            .constant => .none,
            .less_than => .tagged,
            else => error.MalformedGraph,
        },
        .load_named => switch (info.lowering) {
            .load_named_generic,
            .load_named_own,
            .load_named_prototype,
            .load_named_synthetic,
            => .tagged,
            else => error.MalformedGraph,
        },
        .branch, .return_ => .tagged,
    };
}

fn arithmeticInput(info: specialize.NodeInfo, checked: specialize.Lowering) !Kind {
    if (info.lowering == checked) return .int32;
    return switch (info.lowering) {
        .generic => .tagged,
        .constant => if (info.folded != null) .none else error.MalformedGraph,
        else => error.MalformedGraph,
    };
}

fn divisionInput(info: specialize.NodeInfo) !Kind {
    if (info.lowering == .number_div) {
        if (info.folded != null) return error.MalformedGraph;
        return .tagged;
    }
    return arithmeticInput(info, .checked_int32_div);
}

fn nodeInputCount(kind: ir.NodeKind) u16 {
    return switch (kind) {
        .block_parameter,
        .constant,
        .load_this,
        .load_global,
        .load_global_slot,
        .load_environment,
        .jump,
        => 0,
        .logical_not, .load_named, .branch, .return_ => 1,
        .add, .sub, .mul, .div, .strict_eq, .less_than => 2,
    };
}

fn conversion(source: Kind, requirement: Kind) !Conversion {
    if (requirement == .none or source == requirement) return .none;
    return switch (source) {
        .int32 => if (requirement == .tagged) .box_int32 else error.InvalidRepresentation,
        .tagged => if (requirement == .int32) .check_int32 else error.InvalidRepresentation,
        .none => error.InvalidRepresentation,
    };
}

fn verifyConversions(
    graph: *const ir.Graph,
    specialization: *const specialize.Plan,
    plan: *const Plan,
) !void {
    for (graph.nodes, specialization.node_info) |node, info| {
        const inputs = try checkedRange(graph.inputs.len, node.input_start, node.input_count);
        for (inputs.start..inputs.end()) |input_index| {
            const selected = try plan.conversionAt(graph, input_index);
            if (selected != .check_int32) continue;
            if (!isCheckedInt32(node.kind, info.lowering) or node.frame_state == null) {
                return error.InvalidRepresentation;
            }
        }
    }

    for (graph.edges) |edge| {
        const inputs = try checkedRange(
            graph.inputs.len,
            edge.argument_start,
            edge.argument_count,
        );
        for (inputs.start..inputs.end()) |input_index| {
            if (try plan.conversionAt(graph, input_index) == .check_int32) {
                return error.InvalidRepresentation;
            }
        }
    }
}

fn isCheckedInt32(kind: ir.NodeKind, lowering: specialize.Lowering) bool {
    return switch (kind) {
        .add => lowering == .checked_int32_add,
        .sub => lowering == .checked_int32_sub,
        .mul => lowering == .checked_int32_mul,
        .div => lowering == .checked_int32_div,
        .strict_eq => lowering == .strict_eq,
        else => false,
    };
}

fn validateNodeContract(node: ir.Node, info: specialize.NodeInfo) !void {
    if (node.kind != .load_named and node.kind != .load_global and
        info.assumption != null)
    {
        return error.MalformedGraph;
    }
    switch (node.kind) {
        .block_parameter => {
            if (!hasPayload(node.payload, .parameter)) return error.MalformedGraph;
        },
        .constant => {
            if (!hasPayload(node.payload, .immediate) or info.lowering != .constant) {
                return error.MalformedGraph;
            }
            const immediate = node.payload.immediate;
            if ((immediate == .constant_pool) != (info.folded == null)) {
                return error.MalformedGraph;
            }
        },
        .add, .sub, .mul, .strict_eq, .logical_not, .less_than => {
            if (!hasPayload(node.payload, .none)) return error.MalformedGraph;
        },
        .div => if (!hasPayload(node.payload, .binary_profile)) return error.MalformedGraph,
        .load_named => {
            if (!hasPayload(node.payload, .named_load)) return error.MalformedGraph;
        },
        .load_this => {
            if (!hasPayload(node.payload, .none) or info.lowering != .load_this or
                info.folded != null)
            {
                return error.MalformedGraph;
            }
        },
        .load_global => {
            if (!hasPayload(node.payload, .global_load) or
                (info.lowering != .load_global_generic and info.lowering != .load_global) or
                info.folded != null)
            {
                return error.MalformedGraph;
            }
        },
        .load_global_slot => {
            if (!hasPayload(node.payload, .global_slot) or
                info.lowering != .load_global_slot or info.folded != null)
            {
                return error.MalformedGraph;
            }
        },
        .load_environment => {
            if (!hasPayload(node.payload, .environment_load) or
                info.lowering != .load_environment or info.folded != null)
            {
                return error.MalformedGraph;
            }
        },
        .jump, .return_ => {
            if (!hasPayload(node.payload, .none) or info.lowering != .none or
                info.folded != null or info.assumption != null)
            {
                return error.MalformedGraph;
            }
        },
        .branch => {
            if (!hasPayload(node.payload, .branch) or info.lowering != .none or
                info.folded != null or info.assumption != null)
            {
                return error.MalformedGraph;
            }
        },
    }
}

fn hasPayload(payload: ir.Payload, tag: std.meta.Tag(ir.Payload)) bool {
    return std.meta.activeTag(payload) == tag;
}

const Range = struct {
    start: usize,
    len: usize,

    fn end(self: Range) usize {
        return self.start + self.len;
    }
};

fn checkedRange(total: usize, raw_start: anytype, raw_len: anytype) !Range {
    const start: usize = @intCast(raw_start);
    const len: usize = @intCast(raw_len);
    if (start > total or len > total - start) return error.MalformedGraph;
    return .{ .start = start, .len = len };
}

fn claimRange(claimed: []bool, range: Range) !void {
    for (claimed[range.start..range.end()]) |*slot| {
        if (slot.*) return error.MalformedGraph;
        slot.* = true;
    }
}

fn nodeInputIndex(
    graph: *const ir.Graph,
    node_id: ir.ValueId,
    operand_index: usize,
) !usize {
    if (node_id >= graph.nodes.len) return error.MalformedGraph;
    const node = graph.nodes[node_id];
    const inputs = try checkedRange(graph.inputs.len, node.input_start, node.input_count);
    if (operand_index >= inputs.len) return error.MalformedGraph;
    return inputs.start + operand_index;
}

const EdgeTarget = struct {
    param_start: usize,
    param_count: usize,
};

fn checkedEdgeTarget(graph: *const ir.Graph, edge: ir.Edge) !EdgeTarget {
    if (edge.from >= graph.blocks.len or edge.to >= graph.blocks.len) {
        return error.MalformedGraph;
    }
    const target = graph.blocks[edge.to];
    const params = try checkedRange(graph.params.len, target.param_start, target.param_count);
    if (params.len != edge.argument_count) return error.MalformedGraph;
    _ = try checkedRange(graph.inputs.len, edge.argument_start, edge.argument_count);
    return .{ .param_start = params.start, .param_count = params.len };
}

fn validateParameterLayout(allocator: std.mem.Allocator, graph: *const ir.Graph) !void {
    const claimed_params = try allocator.alloc(bool, graph.params.len);
    defer allocator.free(claimed_params);
    @memset(claimed_params, false);
    const claimed_nodes = try allocator.alloc(bool, graph.nodes.len);
    defer allocator.free(claimed_nodes);
    @memset(claimed_nodes, false);

    for (graph.blocks) |block| {
        const params = try checkedRange(graph.params.len, block.param_start, block.param_count);
        for (params.start..params.end()) |param_index| {
            if (claimed_params[param_index]) return error.MalformedGraph;
            claimed_params[param_index] = true;
            const param = graph.params[param_index];
            if (param.value >= graph.nodes.len or claimed_nodes[param.value]) {
                return error.MalformedGraph;
            }
            const node = graph.nodes[param.value];
            if (node.kind != .block_parameter or node.input_count != 0) {
                return error.MalformedGraph;
            }
            const payload_index = switch (node.payload) {
                .parameter => |index| index,
                else => return error.MalformedGraph,
            };
            if (payload_index != param_index) return error.MalformedGraph;
            claimed_nodes[param.value] = true;
        }
    }
    for (claimed_params) |claimed| if (!claimed) return error.MalformedGraph;
    for (graph.nodes, claimed_nodes) |node, claimed| {
        if ((node.kind == .block_parameter) != claimed) return error.MalformedGraph;
    }
}

fn validateEdgeLayout(allocator: std.mem.Allocator, graph: *const ir.Graph) !void {
    const claimed = try allocator.alloc(bool, graph.edges.len);
    defer allocator.free(claimed);
    @memset(claimed, false);
    for (graph.blocks, 0..) |block, block_index| {
        const edges = try checkedRange(graph.edges.len, block.edge_start, block.edge_count);
        for (edges.start..edges.end()) |edge_index| {
            if (claimed[edge_index] or graph.edges[edge_index].from != block_index) {
                return error.MalformedGraph;
            }
            claimed[edge_index] = true;
        }
    }
    for (claimed) |is_claimed| if (!is_claimed) return error.MalformedGraph;
}
