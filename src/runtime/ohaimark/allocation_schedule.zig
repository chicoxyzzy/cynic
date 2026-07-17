//! CFG scheduling and conservative live intervals for Ohaimark allocation.
//!
//! SSA ids are not schedule positions: the graph pre-creates every block
//! parameter before translating any body. This module owns that distinction
//! and validates complete block ownership while constructing intervals.

const std = @import("std");

const control_fusion = @import("control_fusion.zig");
const ir = @import("ir.zig");
const representation = @import("representation.zig");

pub const LiveRange = struct {
    start: usize,
    end: usize,
    use_count: u32,
};

pub fn compute(
    allocator: std.mem.Allocator,
    graph: *const ir.Graph,
    representations: *const representation.Plan,
    fused_control: *const control_fusion.Plan,
    ranges: []?LiveRange,
) !void {
    if (ranges.len != graph.nodes.len or representations.outputs.len != graph.nodes.len or
        representations.input_requirements.len != graph.inputs.len)
    {
        return error.MalformedGraph;
    }
    @memset(ranges, null);
    const claimed_nodes = try allocator.alloc(bool, graph.nodes.len);
    defer allocator.free(claimed_nodes);
    @memset(claimed_nodes, false);
    const claimed_params = try allocator.alloc(bool, graph.params.len);
    defer allocator.free(claimed_params);
    @memset(claimed_params, false);
    const claimed_edges = try allocator.alloc(bool, graph.edges.len);
    defer allocator.free(claimed_edges);
    @memset(claimed_edges, false);

    var position: usize = 0;
    for (graph.blocks, 0..) |block, block_index| {
        const params = try checkedRange(graph.params.len, block.param_start, block.param_count);
        const nodes = try checkedRange(graph.nodes.len, block.node_start, block.node_count);
        const edges = try checkedRange(graph.edges.len, block.edge_start, block.edge_count);
        if (!block.reachable) {
            if (params.len != 0 or nodes.len != 0 or edges.len != 0) {
                return error.MalformedGraph;
            }
            continue;
        }

        for (params.start..params.end()) |param_index| {
            if (claimed_params[param_index]) return error.MalformedGraph;
            claimed_params[param_index] = true;
            const param = graph.params[param_index];
            try defineValue(graph, representations, ranges, claimed_nodes, param.value, position, true);
        }
        position = try nextPosition(position);

        for (nodes.start..nodes.end()) |node_index| {
            const node_id = try valueId(node_index);
            if (claimed_nodes[node_index] or graph.nodes[node_index].kind == .block_parameter) {
                return error.MalformedGraph;
            }
            claimed_nodes[node_index] = true;
            const node = graph.nodes[node_index];
            const inputs = try checkedRange(graph.inputs.len, node.input_start, node.input_count);
            const fused_comparison = try fused_control.strictEqualForBranch(node_id);
            for (inputs.start..inputs.end()) |input_index| {
                if (fused_comparison) |comparison| {
                    if (inputs.len != 1 or graph.inputs[input_index] != comparison) {
                        return error.InvalidControlFusion;
                    }
                    continue;
                }
                if (representations.input_requirements[input_index] == .none) continue;
                try noteUse(graph, ranges, graph.inputs[input_index], position);
            }
            try setDefinition(representations, ranges, node_id, position);
            position = try nextPosition(position);
        }

        for (edges.start..edges.end()) |edge_index| {
            if (claimed_edges[edge_index] or graph.edges[edge_index].from != block_index) {
                return error.MalformedGraph;
            }
            claimed_edges[edge_index] = true;
            const edge = graph.edges[edge_index];
            if (edge.to >= graph.blocks.len) return error.MalformedGraph;
            const target = graph.blocks[edge.to];
            const target_params = try checkedRange(
                graph.params.len,
                target.param_start,
                target.param_count,
            );
            const arguments = try checkedRange(
                graph.inputs.len,
                edge.argument_start,
                edge.argument_count,
            );
            if (arguments.len != target_params.len) return error.MalformedGraph;
            for (arguments.start..arguments.end()) |input_index| {
                if (representations.input_requirements[input_index] == .none) {
                    return error.MalformedGraph;
                }
                try noteUse(graph, ranges, graph.inputs[input_index], position);
            }
        }
        position = try nextPosition(position);
    }

    for (claimed_nodes) |claimed| if (!claimed) return error.MalformedGraph;
    for (claimed_params) |claimed| if (!claimed) return error.MalformedGraph;
    for (claimed_edges) |claimed| if (!claimed) return error.MalformedGraph;
}

fn defineValue(
    graph: *const ir.Graph,
    representations: *const representation.Plan,
    ranges: []?LiveRange,
    claimed_nodes: []bool,
    value: ir.ValueId,
    position: usize,
    parameter: bool,
) !void {
    if (value >= graph.nodes.len or claimed_nodes[value]) return error.MalformedGraph;
    const node = graph.nodes[value];
    if ((node.kind == .block_parameter) != parameter) return error.MalformedGraph;
    claimed_nodes[value] = true;
    try setDefinition(representations, ranges, value, position);
}

fn setDefinition(
    representations: *const representation.Plan,
    ranges: []?LiveRange,
    value: ir.ValueId,
    position: usize,
) !void {
    if (value >= ranges.len or value >= representations.outputs.len or ranges[value] != null) {
        return error.MalformedGraph;
    }
    if (representations.outputs[value] != .none) {
        ranges[value] = .{ .start = position, .end = position, .use_count = 0 };
    }
}

fn noteUse(
    graph: *const ir.Graph,
    ranges: []?LiveRange,
    value: ir.ValueId,
    position: usize,
) !void {
    if (value >= graph.nodes.len or value >= ranges.len) return error.MalformedGraph;
    const range = &(ranges[value] orelse return error.MalformedGraph);
    if (position < range.start or range.use_count == std.math.maxInt(u32)) {
        return error.MalformedGraph;
    }
    range.end = @max(range.end, position);
    range.use_count += 1;
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

fn nextPosition(position: usize) !usize {
    if (position == std.math.maxInt(usize)) return error.GraphTooLarge;
    return position + 1;
}

fn valueId(index: usize) !ir.ValueId {
    if (index > std.math.maxInt(ir.ValueId)) return error.GraphTooLarge;
    return @intCast(index);
}
