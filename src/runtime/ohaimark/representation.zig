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

        const plan: Plan = .{
            .allocator = allocator,
            .outputs = outputs,
            .input_requirements = input_requirements,
        };
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
        .mul => profiledArithmeticOutput(info, .checked_int32_mul, .number_mul),
        .div => profiledArithmeticOutput(info, .checked_int32_div, .number_div),
        .strict_eq => switch (info.lowering) {
            .constant, .strict_eq => .tagged,
            else => error.MalformedGraph,
        },
        .logical_not => switch (info.lowering) {
            .constant, .logical_not, .checked_boolean_not => .tagged,
            else => error.MalformedGraph,
        },
        .to_numeric => if (info.lowering == .checked_int32_to_numeric)
            .int32
        else
            error.MalformedGraph,
        .to_string => if (info.lowering == .checked_string_to_string)
            .tagged
        else
            error.MalformedGraph,
        .require_object_coercible => if (info.lowering == .require_object_coercible)
            .tagged
        else
            error.MalformedGraph,
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
        .store_named => switch (info.lowering) {
            .store_named_generic, .store_named_own => .none,
            else => error.MalformedGraph,
        },
        .load_computed => switch (info.lowering) {
            .load_computed_generic, .load_computed_own => .tagged,
            else => error.MalformedGraph,
        },
        .store_computed => switch (info.lowering) {
            .store_computed_generic, .store_computed_own => .none,
            else => error.MalformedGraph,
        },
        .delete_computed_property => if (info.lowering == .delete_computed_property)
            .tagged
        else
            error.MalformedGraph,
        .load_this => if (info.lowering == .load_this) .tagged else error.MalformedGraph,
        .load_global => switch (info.lowering) {
            .load_global_generic, .load_global => .tagged,
            else => error.MalformedGraph,
        },
        .store_global => if (info.lowering == .store_global)
            .none
        else
            error.MalformedGraph,
        .load_global_slot => if (info.lowering == .load_global_slot)
            .tagged
        else
            error.MalformedGraph,
        .store_global_slot_init => if (info.lowering == .store_global_slot_init)
            .none
        else
            error.MalformedGraph,
        .store_global_slot => if (info.lowering == .store_global_slot)
            .none
        else
            error.MalformedGraph,
        .load_environment => if (info.lowering == .load_environment)
            .tagged
        else
            error.MalformedGraph,
        .allocate_environment => if (info.lowering == .allocate_environment)
            .none
        else
            error.MalformedGraph,
        .store_environment => if (info.lowering == .store_environment)
            .none
        else
            error.MalformedGraph,
        .pop_environment => if (info.lowering == .pop_environment)
            .none
        else
            error.MalformedGraph,
        .create_unmapped_arguments_object => if (info.lowering == .create_unmapped_arguments_object)
            .tagged
        else
            error.MalformedGraph,
        .create_ordinary_function => if (info.lowering == .create_ordinary_function)
            .tagged
        else
            error.MalformedGraph,
        .set_home => if (info.lowering == .set_home)
            .none
        else
            error.MalformedGraph,
        .define_object_method_property => if (info.lowering == .define_object_method_property)
            .none
        else
            error.MalformedGraph,
        .create_object_literal => if (info.lowering == .create_object_literal)
            .tagged
        else
            error.MalformedGraph,
        .create_dense_array_literal => if (info.lowering == .create_dense_array_literal)
            .tagged
        else
            error.MalformedGraph,
        .create_array_literal => if (info.lowering == .create_array_literal)
            .tagged
        else
            error.MalformedGraph,
        .append_dense_array_literal_element => if (info.lowering == .append_dense_array_literal_element)
            .none
        else
            error.MalformedGraph,
        .define_template_property => if (info.lowering == .define_template_property)
            .none
        else
            error.MalformedGraph,
        .throw_ => if (info.lowering == .throw_)
            .none
        else
            error.MalformedGraph,
        .throw_if_hole => if (info.lowering == .throw_if_hole)
            .tagged
        else
            error.MalformedGraph,
        .typeof_ => if (info.lowering == .typeof_)
            .tagged
        else
            error.MalformedGraph,
        .direct_call => if (info.lowering == .direct_call)
            .tagged
        else
            error.MalformedGraph,
        .tail_dispatch => if (info.lowering == .tail_dispatch)
            .none
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

fn profiledArithmeticOutput(
    info: specialize.NodeInfo,
    checked: specialize.Lowering,
    number: specialize.Lowering,
) !Kind {
    if (info.lowering == number) {
        if (info.folded != null) return error.MalformedGraph;
        return .tagged;
    }
    return arithmeticOutput(info, checked);
}

fn nodeInputKind(node: ir.Node, info: specialize.NodeInfo) !Kind {
    return switch (node.kind) {
        .block_parameter,
        .constant,
        .load_this,
        .load_global,
        .load_global_slot,
        .load_environment,
        .allocate_environment,
        .pop_environment,
        .create_unmapped_arguments_object,
        .create_ordinary_function,
        .create_object_literal,
        .create_dense_array_literal,
        .create_array_literal,
        .direct_call,
        .tail_dispatch,
        .throw_,
        .jump,
        => .none,
        .add => arithmeticInput(info, .checked_int32_add),
        .sub => arithmeticInput(info, .checked_int32_sub),
        .mul => profiledArithmeticInput(info, .checked_int32_mul, .number_mul),
        .div => profiledArithmeticInput(info, .checked_int32_div, .number_div),
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
        .to_numeric => if (info.lowering == .checked_int32_to_numeric)
            .int32
        else
            error.MalformedGraph,
        .to_string => if (info.lowering == .checked_string_to_string)
            .tagged
        else
            error.MalformedGraph,
        .require_object_coercible => if (info.lowering == .require_object_coercible)
            .tagged
        else
            error.MalformedGraph,
        .less_than => switch (info.lowering) {
            .constant => .none,
            .less_than => .int32,
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
        .store_named => switch (info.lowering) {
            .store_named_generic, .store_named_own => .tagged,
            else => error.MalformedGraph,
        },
        .load_computed => switch (info.lowering) {
            .load_computed_generic, .load_computed_own => .tagged,
            else => error.MalformedGraph,
        },
        .store_computed => switch (info.lowering) {
            .store_computed_generic, .store_computed_own => .tagged,
            else => error.MalformedGraph,
        },
        .store_global => if (info.lowering == .store_global)
            .tagged
        else
            error.MalformedGraph,
        .delete_computed_property => if (info.lowering == .delete_computed_property)
            .tagged
        else
            error.MalformedGraph,
        .store_environment => if (info.lowering == .store_environment)
            .tagged
        else
            error.MalformedGraph,
        .store_global_slot_init => if (info.lowering == .store_global_slot_init)
            .tagged
        else
            error.MalformedGraph,
        .store_global_slot => if (info.lowering == .store_global_slot)
            .tagged
        else
            error.MalformedGraph,
        .define_template_property => if (info.lowering == .define_template_property)
            .tagged
        else
            error.MalformedGraph,
        .set_home => if (info.lowering == .set_home)
            .tagged
        else
            error.MalformedGraph,
        .define_object_method_property => if (info.lowering == .define_object_method_property)
            .tagged
        else
            error.MalformedGraph,
        .append_dense_array_literal_element => if (info.lowering == .append_dense_array_literal_element)
            .tagged
        else
            error.MalformedGraph,
        .throw_if_hole => if (info.lowering == .throw_if_hole)
            .tagged
        else
            error.MalformedGraph,
        .typeof_ => if (info.lowering == .typeof_)
            .tagged
        else
            error.MalformedGraph,
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

fn profiledArithmeticInput(
    info: specialize.NodeInfo,
    checked: specialize.Lowering,
    number: specialize.Lowering,
) !Kind {
    if (info.lowering == number) {
        if (info.folded != null) return error.MalformedGraph;
        return .tagged;
    }
    return arithmeticInput(info, checked);
}

fn nodeInputCount(kind: ir.NodeKind) u16 {
    return switch (kind) {
        .block_parameter,
        .constant,
        .load_this,
        .load_global,
        .load_global_slot,
        .load_environment,
        .allocate_environment,
        .pop_environment,
        .create_unmapped_arguments_object,
        .create_ordinary_function,
        .create_object_literal,
        .create_dense_array_literal,
        .create_array_literal,
        .direct_call,
        .tail_dispatch,
        .throw_,
        .jump,
        => 0,
        .logical_not,
        .to_numeric,
        .to_string,
        .require_object_coercible,
        .load_named,
        .store_global,
        .store_global_slot_init,
        .store_global_slot,
        .store_environment,
        .throw_if_hole,
        .typeof_,
        .branch,
        .return_,
        => 1,
        .load_computed,
        .define_template_property,
        .append_dense_array_literal_element,
        .delete_computed_property,
        .store_named,
        .set_home,
        .define_object_method_property,
        => 2,
        .store_computed => 3,
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
        .to_numeric => lowering == .checked_int32_to_numeric,
        .strict_eq => lowering == .strict_eq,
        .less_than => lowering == .less_than,
        else => false,
    };
}

fn validateNodeContract(node: ir.Node, info: specialize.NodeInfo) !void {
    if (node.kind != .load_named and node.kind != .store_named and node.kind != .load_computed and node.kind != .store_computed and node.kind != .load_global and
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
        .add,
        .sub,
        .strict_eq,
        .logical_not,
        .to_numeric,
        .to_string,
        .require_object_coercible,
        .less_than,
        => {
            if (!hasPayload(node.payload, .none)) return error.MalformedGraph;
        },
        .mul, .div => if (!hasPayload(node.payload, .binary_profile)) return error.MalformedGraph,
        .load_named => {
            if (!hasPayload(node.payload, .named_load)) return error.MalformedGraph;
        },
        .store_named => {
            if (!hasPayload(node.payload, .named_store) or
                (info.lowering != .store_named_generic and info.lowering != .store_named_own) or
                info.folded != null)
            {
                return error.MalformedGraph;
            }
        },
        .load_computed => {
            if (!hasPayload(node.payload, .computed_load) or
                (info.lowering != .load_computed_generic and info.lowering != .load_computed_own) or
                info.folded != null)
            {
                return error.MalformedGraph;
            }
        },
        .store_computed => {
            if (!hasPayload(node.payload, .computed_store) or
                (info.lowering != .store_computed_generic and info.lowering != .store_computed_own) or
                info.folded != null)
            {
                return error.MalformedGraph;
            }
        },
        .delete_computed_property => {
            if (!hasPayload(node.payload, .computed_delete) or
                info.lowering != .delete_computed_property or info.folded != null or
                info.assumption != null)
            {
                return error.MalformedGraph;
            }
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
        .store_global => {
            if (!hasPayload(node.payload, .global_store) or
                info.lowering != .store_global or info.folded != null or
                info.assumption != null)
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
        .store_global_slot_init => {
            if (!hasPayload(node.payload, .global_slot) or
                info.lowering != .store_global_slot_init or info.folded != null)
            {
                return error.MalformedGraph;
            }
        },
        .store_global_slot => {
            if (!hasPayload(node.payload, .global_slot) or
                info.lowering != .store_global_slot or info.folded != null)
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
        .allocate_environment => {
            if (!hasPayload(node.payload, .environment_allocation) or
                info.lowering != .allocate_environment or info.folded != null)
            {
                return error.MalformedGraph;
            }
        },
        .store_environment => {
            if (!hasPayload(node.payload, .environment_store) or
                info.lowering != .store_environment or info.folded != null)
            {
                return error.MalformedGraph;
            }
        },
        .pop_environment => {
            if (!hasPayload(node.payload, .none) or
                info.lowering != .pop_environment or info.folded != null)
            {
                return error.MalformedGraph;
            }
        },
        .create_unmapped_arguments_object => {
            if (!hasPayload(node.payload, .none) or
                info.lowering != .create_unmapped_arguments_object or info.folded != null)
            {
                return error.MalformedGraph;
            }
        },
        .create_ordinary_function => {
            if (!hasPayload(node.payload, .function_template) or
                info.lowering != .create_ordinary_function or info.folded != null)
            {
                return error.MalformedGraph;
            }
        },
        .set_home => {
            if (!hasPayload(node.payload, .home_object) or
                info.lowering != .set_home or info.folded != null)
            {
                return error.MalformedGraph;
            }
        },
        .define_object_method_property => {
            if (!hasPayload(node.payload, .object_method_property) or
                info.lowering != .define_object_method_property or info.folded != null)
            {
                return error.MalformedGraph;
            }
        },
        .create_object_literal => {
            if (!hasPayload(node.payload, .object_literal) or
                info.lowering != .create_object_literal or info.folded != null)
            {
                return error.MalformedGraph;
            }
        },
        .create_dense_array_literal => {
            if (!hasPayload(node.payload, .dense_array_literal) or
                info.lowering != .create_dense_array_literal or info.folded != null)
            {
                return error.MalformedGraph;
            }
            const literal = node.payload.dense_array_literal;
            if (literal.count == 0) return error.MalformedGraph;
        },
        .create_array_literal => {
            if (!hasPayload(node.payload, .none) or
                info.lowering != .create_array_literal or info.folded != null)
            {
                return error.MalformedGraph;
            }
        },
        .append_dense_array_literal_element => {
            if (!hasPayload(node.payload, .dense_array_append) or
                info.lowering != .append_dense_array_literal_element or info.folded != null)
            {
                return error.MalformedGraph;
            }
        },
        .define_template_property => {
            if (!hasPayload(node.payload, .template_property) or
                info.lowering != .define_template_property or info.folded != null)
            {
                return error.MalformedGraph;
            }
        },
        .throw_ => {
            if (!hasPayload(node.payload, .none) or info.lowering != .throw_ or
                info.folded != null)
            {
                return error.MalformedGraph;
            }
        },
        .throw_if_hole => {
            if (!hasPayload(node.payload, .none) or info.lowering != .throw_if_hole or
                info.folded != null)
            {
                return error.MalformedGraph;
            }
        },
        .typeof_ => {
            if (!hasPayload(node.payload, .none) or info.lowering != .typeof_ or
                info.folded != null)
            {
                return error.MalformedGraph;
            }
        },
        .direct_call => {
            if (!hasPayload(node.payload, .direct_call) or info.lowering != .direct_call or
                info.folded != null or info.assumption != null)
            {
                return error.MalformedGraph;
            }
        },
        .tail_dispatch => {
            if (!hasPayload(node.payload, .none) or info.lowering != .tail_dispatch or
                info.folded != null or info.assumption != null)
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
            if (!hasPayload(node.payload, .branch) or
                (info.lowering != .none and info.lowering != .checked_branch) or
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
