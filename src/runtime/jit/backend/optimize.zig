//! Bounded pure scalar optimizations. Guards and control flow are preserved.
const std = @import("std");
const ir = @import("ir.zig");

pub const Options = struct {
    constant_folding: bool = true,
    common_subexpression_elimination: bool = true,
    dead_code_elimination: bool = true,
};
pub const Stats = struct {
    input_nodes: u32 = 0,
    output_nodes: u32 = 0,
    folded_nodes: u32 = 0,
    commoned_nodes: u32 = 0,
    removed_nodes: u32 = 0,
};
pub const Result = struct {
    arena: std.heap.ArenaAllocator,
    graph: ir.Graph,
    stats: Stats,

    pub fn deinit(self: *Result) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

pub fn run(a: std.mem.Allocator, graph: ir.Graph, options: Options) !Result {
    try graph.verify();
    var arena = std.heap.ArenaAllocator.init(a);
    errdefer arena.deinit();
    const allocator = arena.allocator();
    const blocks = try allocator.dupe(ir.Block, graph.blocks);
    var stats: Stats = .{};
    var constants: [ir.max_values]?u64 = @splat(null);
    var representatives: [ir.max_values]ir.Value = undefined;
    for (&representatives, 0..) |*value, i| value.* = @intCast(i);
    var expressions: std.AutoHashMapUnmanaged(Expression, ir.Value) = .empty;
    defer expressions.deinit(a);
    for (blocks) |*block| {
        const nodes = try allocator.dupe(ir.Node, block.nodes);
        stats.input_nodes += @intCast(nodes.len);
        expressions.clearRetainingCapacity();
        var count: usize = 0;
        for (nodes) |original| {
            var node = if (options.common_subexpression_elimination)
                try remapInputs(allocator, original, &representatives)
            else
                original;
            if (options.constant_folding) if (node.out) |out| {
                if (node.op == .constant) {
                    constants[out] = node.immediate;
                } else if (fold(node, graph.types, &constants)) |value| {
                    constants[out] = value;
                    node = .{ .op = .constant, .out = out, .immediate = value };
                    stats.folded_nodes += 1;
                }
            };
            if (options.common_subexpression_elimination) if (expression(node, graph.types)) |key| {
                const entry = try expressions.getOrPut(a, key);
                if (entry.found_existing) {
                    // Inputs already name canonical definitions, so aliases never
                    // form chains, even when value IDs are not in program order.
                    representatives[node.out.?] = entry.value_ptr.*;
                    stats.commoned_nodes += 1;
                    continue;
                }
                entry.value_ptr.* = node.out.?;
            };
            nodes[count] = node;
            count += 1;
        }
        block.nodes = nodes[0..count];
        if (options.common_subexpression_elimination) {
            block.terminator = try remapTerminator(allocator, block.terminator, &representatives);
        }
    }

    var live: [ir.max_values]bool = @splat(!options.dead_code_elimination);
    if (options.dead_code_elimination) for (blocks) |block| {
        // Keep parameter/edge shape and all guards, so block-budget visits
        // and frontend-owned recovery records remain exactly comparable.
        for (block.params) |value| live[value] = true;
        switch (block.terminator) {
            .trap => {},
            .return_ => |value| live[value] = true,
            .jump => |edge| markValues(&live, edge.args),
            .branch => |branch| {
                live[branch.condition] = true;
                markValues(&live, branch.taken.args);
                markValues(&live, branch.fallthrough.args);
            },
        }
        var i = block.nodes.len;
        while (i != 0) {
            i -= 1;
            const node = block.nodes[i];
            if (!isPure(node.op)) if (node.out) |out| {
                live[out] = true;
            };
            if (!isPure(node.op) or live[node.out.?]) markInputs(&live, node);
        }
    };

    var map: [ir.max_values]ir.Value = @splat(std.math.maxInt(ir.Value));
    const types = try allocator.alloc(ir.Type, graph.types.len);
    var value_count: usize = 0;
    for (graph.types, 0..) |ty, value| {
        if (!live[value] or representatives[value] != value) continue;
        map[value] = @intCast(value_count);
        types[value_count] = ty;
        value_count += 1;
    }
    for (blocks) |*block| {
        block.params = try remapValues(allocator, block.params, &map);
        const nodes = try allocator.alloc(ir.Node, block.nodes.len);
        var count: usize = 0;
        for (block.nodes) |original| {
            if (isPure(original.op) and !live[original.out.?]) {
                stats.removed_nodes += 1;
                continue;
            }
            var node = try remapInputs(allocator, original, &map);
            if (node.out) |out| node.out = map[out];
            nodes[count] = node;
            count += 1;
        }
        block.nodes = nodes[0..count];
        stats.output_nodes += @intCast(count);
        block.terminator = try remapTerminator(allocator, block.terminator, &map);
    }
    const result: ir.Graph = .{
        .types = types[0..value_count],
        .blocks = blocks,
        .argument_types = try allocator.dupe(ir.Type, graph.argument_types),
        .result_type = graph.result_type,
        .memory_count = graph.memory_count,
    };
    try result.verify();
    return .{ .arena = arena, .graph = result, .stats = stats };
}

const Expression = struct {
    op: ir.Op,
    ty: ir.Type,
    lhs: ir.Value = 0,
    rhs: ir.Value = 0,
    immediate: u64 = 0,
};

fn expression(node: ir.Node, types: []const ir.Type) ?Expression {
    if (!isPure(node.op)) return null;
    var key: Expression = .{ .op = node.op, .ty = types[node.out.?] };
    switch (ir.inputCount(node.op)) {
        0 => key.immediate = node.immediate,
        1 => key.lhs = node.lhs,
        2 => switch (node.op) {
            .add, .mul, .bit_and, .bit_or, .bit_xor, .eq, .ne => {
                key.lhs = @min(node.lhs, node.rhs);
                key.rhs = @max(node.lhs, node.rhs);
            },
            else => {
                key.lhs = node.lhs;
                key.rhs = node.rhs;
            },
        },
        else => return null,
    }
    return key;
}

fn isPure(op: ir.Op) bool {
    return ir.effects(op).isPure();
}

fn fold(node: ir.Node, types: []const ir.Type, constants: []const ?u64) ?u64 {
    // Leave FP evaluation to the target. No host folding, fast math, or
    // reassociation; literal keys preserve signed zero and NaN payload bits.
    if (!isPure(node.op) or node.op == .constant or ir.isFloatOp(node.op)) return null;
    const lhs = constants[node.lhs] orelse return null;
    if (node.op == .reinterpret) return lhs;
    if (ir.conversionTypes(node.op) != null) return switch (node.op) {
        .sext_i32 => @bitCast(signed(.i32, lhs)),
        .zext_i32, .trunc_i64 => ir.normalize(.i32, lhs),
        else => null,
    };
    // New unary integer operations stay native until they have dedicated
    // folding rules; a nonexistent second operand must never be consulted.
    if (ir.inputCount(node.op) != 2) return null;
    const rhs = constants[node.rhs] orelse return null;
    const ty = types[node.lhs];
    const value: u64 = switch (node.op) {
        .add => lhs +% rhs,
        .sub => lhs -% rhs,
        .mul => lhs *% rhs,
        .bit_and => lhs & rhs,
        .bit_or => lhs | rhs,
        .bit_xor => lhs ^ rhs,
        .eq => @intFromBool(lhs == rhs),
        .ne => @intFromBool(lhs != rhs),
        .lt_s => @intFromBool(signed(ty, lhs) < signed(ty, rhs)),
        .lt_u => @intFromBool(lhs < rhs),
        .gt_s => @intFromBool(signed(ty, lhs) > signed(ty, rhs)),
        .gt_u => @intFromBool(lhs > rhs),
        .le_s => @intFromBool(signed(ty, lhs) <= signed(ty, rhs)),
        .le_u => @intFromBool(lhs <= rhs),
        .ge_s => @intFromBool(signed(ty, lhs) >= signed(ty, rhs)),
        .ge_u => @intFromBool(lhs >= rhs),
        else => return null,
    };
    return ir.normalize(types[node.out.?], value);
}

fn signed(ty: ir.Type, value: u64) i64 {
    return if (ty == .i32) @as(i32, @bitCast(@as(u32, @truncate(value)))) else @bitCast(value);
}

fn markValues(live: []bool, values: []const ir.Value) void {
    for (values) |value| live[value] = true;
}

fn markInputs(live: []bool, node: ir.Node) void {
    if (ir.inputCount(node.op) >= 1) live[node.lhs] = true;
    if (ir.inputCount(node.op) == 2) live[node.rhs] = true;
    if (node.exit) |side_exit| markValues(live, side_exit.values);
    if (node.call) |call| {
        markValues(live, call.arguments);
        markValues(live, call.safepoint.values);
    }
}

fn remapValues(a: std.mem.Allocator, values: []const ir.Value, map: []const ir.Value) ![]const ir.Value {
    const result = try a.alloc(ir.Value, values.len);
    for (values, result) |value, *out| out.* = map[value];
    return result;
}

fn remapEdge(a: std.mem.Allocator, edge: ir.Edge, map: []const ir.Value) !ir.Edge {
    return .{ .target = edge.target, .args = try remapValues(a, edge.args, map) };
}

fn remapInputs(a: std.mem.Allocator, original: ir.Node, map: []const ir.Value) !ir.Node {
    var node = original;
    if (ir.inputCount(node.op) >= 1) node.lhs = map[node.lhs];
    if (ir.inputCount(node.op) == 2) node.rhs = map[node.rhs];
    if (node.exit) |side_exit| node.exit = .{ .id = side_exit.id, .values = try remapValues(a, side_exit.values, map) };
    if (node.call) |call| node.call = .{
        .target = call.target,
        .arguments = try remapValues(a, call.arguments, map),
        .parameter_types = try a.dupe(ir.Type, call.parameter_types),
        .result_type = call.result_type,
        .fp_mode = call.fp_mode,
        .safepoint = .{ .id = call.safepoint.id, .values = try remapValues(a, call.safepoint.values, map) },
    };
    return node;
}

fn remapTerminator(a: std.mem.Allocator, terminator: ir.Terminator, map: []const ir.Value) !ir.Terminator {
    return switch (terminator) {
        .trap => terminator,
        .return_ => |value| .{ .return_ = map[value] },
        .jump => |edge| .{ .jump = try remapEdge(a, edge, map) },
        .branch => |branch| .{ .branch = .{
            .condition = map[branch.condition],
            .taken = try remapEdge(a, branch.taken, map),
            .fallthrough = try remapEdge(a, branch.fallthrough, map),
        } },
    };
}
