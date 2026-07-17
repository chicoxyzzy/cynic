//! Verified control fusion for values consumed only by a terminating branch.
//!
//! The graph and deopt metadata retain the original value node. This side plan
//! records when native code may consume that node's operands directly and omit
//! its materialized result without changing guard order or interpreter state.

const std = @import("std");

const ir = @import("ir.zig");
const representation = @import("representation.zig");
const specialize = @import("specialize.zig");

pub const Plan = struct {
    allocator: std.mem.Allocator,
    /// Indexed by branch node; the value is its directly consumed strict-equal
    /// node when compare-and-branch emission is admissible.
    strict_eq_branches: []?ir.ValueId,
    /// Indexed by value node. Elided values must not receive an allocation.
    elided_values: []bool,

    pub fn build(
        allocator: std.mem.Allocator,
        graph: *const ir.Graph,
        specialization: *const specialize.Plan,
        representations: *const representation.Plan,
    ) !Plan {
        try representations.verify(graph, specialization);
        const strict_eq_branches = try allocator.alloc(?ir.ValueId, graph.nodes.len);
        errdefer allocator.free(strict_eq_branches);
        const elided_values = try allocator.alloc(bool, graph.nodes.len);
        errdefer allocator.free(elided_values);
        try compute(
            allocator,
            graph,
            specialization,
            representations,
            strict_eq_branches,
            elided_values,
        );

        var plan: Plan = .{
            .allocator = allocator,
            .strict_eq_branches = strict_eq_branches,
            .elided_values = elided_values,
        };
        errdefer plan.deinit();
        try plan.verify(graph, specialization, representations);
        return plan;
    }

    pub fn deinit(self: *Plan) void {
        self.allocator.free(self.strict_eq_branches);
        self.allocator.free(self.elided_values);
        self.* = undefined;
    }

    pub fn verify(
        self: *const Plan,
        graph: *const ir.Graph,
        specialization: *const specialize.Plan,
        representations: *const representation.Plan,
    ) !void {
        try representations.verify(graph, specialization);
        if (self.strict_eq_branches.len != graph.nodes.len or
            self.elided_values.len != graph.nodes.len)
        {
            return error.InvalidControlFusion;
        }

        const expected_branches = try self.allocator.alloc(?ir.ValueId, graph.nodes.len);
        defer self.allocator.free(expected_branches);
        const expected_elided = try self.allocator.alloc(bool, graph.nodes.len);
        defer self.allocator.free(expected_elided);
        try compute(
            self.allocator,
            graph,
            specialization,
            representations,
            expected_branches,
            expected_elided,
        );
        for (self.strict_eq_branches, expected_branches) |actual, expected| {
            if (actual != expected) return error.InvalidControlFusion;
        }
        if (!std.mem.eql(bool, self.elided_values, expected_elided)) {
            return error.InvalidControlFusion;
        }
    }

    pub fn strictEqualForBranch(
        self: *const Plan,
        branch: ir.ValueId,
    ) !?ir.ValueId {
        if (branch >= self.strict_eq_branches.len) return error.InvalidControlFusion;
        return self.strict_eq_branches[branch];
    }

    pub fn valueIsElided(self: *const Plan, value: ir.ValueId) !bool {
        if (value >= self.elided_values.len) return error.InvalidControlFusion;
        return self.elided_values[value];
    }
};

fn compute(
    allocator: std.mem.Allocator,
    graph: *const ir.Graph,
    specialization: *const specialize.Plan,
    representations: *const representation.Plan,
    strict_eq_branches: []?ir.ValueId,
    elided_values: []bool,
) !void {
    if (strict_eq_branches.len != graph.nodes.len or
        elided_values.len != graph.nodes.len or
        specialization.node_info.len != graph.nodes.len or
        representations.outputs.len != graph.nodes.len or
        representations.input_requirements.len != graph.inputs.len)
    {
        return error.MalformedGraph;
    }
    @memset(strict_eq_branches, null);
    @memset(elided_values, false);

    const use_counts = try allocator.alloc(u32, graph.nodes.len);
    defer allocator.free(use_counts);
    @memset(use_counts, 0);
    for (graph.inputs) |producer| {
        if (producer >= use_counts.len or use_counts[producer] == std.math.maxInt(u32)) {
            return error.MalformedGraph;
        }
        use_counts[producer] += 1;
    }

    for (graph.blocks) |block| {
        const nodes = try checkedRange(graph.nodes.len, block.node_start, block.node_count);
        if (!block.reachable) {
            if (nodes.len != 0) return error.MalformedGraph;
            continue;
        }
        if (nodes.len < 2) continue;
        for (nodes.start + 1..nodes.end()) |branch_index| {
            const branch = graph.nodes[branch_index];
            if (branch.kind != .branch or branch.input_count != 1) continue;
            const condition = switch (branch.payload) {
                .branch => |value| value,
                else => return error.MalformedGraph,
            };
            if (condition == .nullish) continue;

            const branch_inputs = try checkedRange(
                graph.inputs.len,
                branch.input_start,
                branch.input_count,
            );
            const comparison = graph.inputs[branch_inputs.start];
            const preceding: ir.ValueId = @intCast(branch_index - 1);
            if (comparison != preceding or comparison >= graph.nodes.len or
                use_counts[comparison] != 1)
            {
                continue;
            }

            const comparison_node = graph.nodes[comparison];
            const comparison_info = specialization.node_info[comparison];
            if (comparison_node.kind != .strict_eq or
                comparison_node.frame_state == null or
                comparison_info.lowering != .strict_eq or
                comparison_info.folded != null or
                representations.outputs[comparison] != .tagged or
                representations.input_requirements[branch_inputs.start] != .tagged or
                try representations.conversionAt(graph, branch_inputs.start) != .none)
            {
                continue;
            }
            for (0..2) |operand| {
                if (try representations.nodeInputRequirement(graph, comparison, operand) != .int32) {
                    return error.InvalidRepresentation;
                }
            }

            if (elided_values[comparison]) return error.MalformedGraph;
            strict_eq_branches[branch_index] = comparison;
            elided_values[comparison] = true;
        }
    }
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
