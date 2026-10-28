const std = @import("std");
const ir = @import("ir.zig");
const optimize = @import("optimize.zig");
const native = @import("native.zig");
const CodeAllocator = @import("../code_alloc.zig").CodeAllocator;
const a = std.testing.allocator;

const repeated: ir.Graph = .{
    .types = &.{ .i32, .i64, .i64, .i64, .i64, .i64, .i64, .i64, .i64 },
    .argument_types = &.{ .i64, .i64, .i32 },
    .result_type = .i64,
    .blocks = &.{.{ .params = &.{ 6, 1, 0 }, .nodes = &.{
        .{ .op = .add, .out = 7, .lhs = 6, .rhs = 1 },
        .{ .op = .add, .out = 2, .lhs = 1, .rhs = 6 },
        .{ .op = .mul, .out = 8, .lhs = 7, .rhs = 2 },
        .{ .op = .guard, .lhs = 0, .exit = .{ .id = 41, .values = &.{ 2, 8, 2 } } },
        .{ .op = .mul, .out = 3, .lhs = 2, .rhs = 7 },
        .{ .op = .add, .out = 4, .lhs = 6, .rhs = 1 },
        .{ .op = .guard, .lhs = 0, .exit = .{ .id = 42, .values = &.{ 3, 4, 3 } } },
        .{ .op = .sub, .out = 5, .lhs = 3, .rhs = 4 },
    }, .terminator = .{ .return_ = 5 } }},
};

test "backend CSE: transitive duplicates preserve guards and unordered value IDs" {
    var result = try optimize.run(a, repeated, .{ .constant_folding = false, .dead_code_elimination = false });
    defer result.deinit();
    try result.graph.verify();
    const nodes = result.graph.blocks[0].nodes;
    try std.testing.expectEqual(@as(usize, 5), nodes.len);
    try std.testing.expectEqual(@as(usize, 6), result.graph.types.len);
    try std.testing.expectEqualSlices(ir.Value, &.{ 3, 1, 0 }, result.graph.blocks[0].params);
    try std.testing.expectEqual(@as(u32, 41), nodes[2].exit.?.id);
    try std.testing.expectEqualSlices(ir.Value, &.{ 4, 5, 4 }, nodes[2].exit.?.values);
    try std.testing.expectEqual(@as(u32, 42), nodes[3].exit.?.id);
    try std.testing.expectEqualSlices(ir.Value, &.{ 5, 4, 5 }, nodes[3].exit.?.values);
    try std.testing.expectEqual(@as(ir.Value, 2), result.graph.blocks[0].terminator.return_);
    try std.testing.expectEqual(@as(usize, 8), repeated.blocks[0].nodes.len);
    try std.testing.expectEqualSlices(ir.Value, &.{ 2, 8, 2 }, repeated.blocks[0].nodes[3].exit.?.values);
}

test "backend CSE: commutative keys exclude ordered comparisons and subtraction" {
    for ([_]ir.Type{ .i32, .i64 }) |ty| {
        for ([_]ir.Op{ .add, .sub, .mul, .bit_and, .bit_or, .eq, .lt_s, .lt_u, .ge_s, .ge_u }) |op| {
            const comparison = switch (op) {
                .eq, .lt_s, .lt_u, .ge_s, .ge_u => true,
                else => false,
            };
            const commutative = switch (op) {
                .add, .mul, .bit_and, .bit_or, .eq => true,
                else => false,
            };
            const out_type: ir.Type = if (comparison) .i32 else ty;
            const types = [_]ir.Type{ ty, ty, out_type, out_type, out_type };
            const nodes = [_]ir.Node{
                .{ .op = op, .out = 2, .lhs = 0, .rhs = 1 },
                .{ .op = op, .out = 3, .lhs = 1, .rhs = 0 },
                .{ .op = op, .out = 4, .lhs = 0, .rhs = 1 },
            };
            const blocks = [_]ir.Block{.{ .params = &.{ 0, 1 }, .nodes = &nodes, .terminator = .{ .return_ = 4 } }};
            const graph: ir.Graph = .{ .types = &types, .blocks = &blocks, .argument_types = types[0..2], .result_type = out_type };
            var result = try optimize.run(a, graph, .{ .constant_folding = false, .dead_code_elimination = false });
            defer result.deinit();
            try std.testing.expectEqual(@as(usize, if (commutative) 1 else 2), result.graph.blocks[0].nodes.len);
            try std.testing.expectEqual(@as(ir.Value, 2), result.graph.blocks[0].terminator.return_);
        }
    }
}

test "backend CSE: typed constants conversions and signedness stay distinct" {
    const graph: ir.Graph = .{
        .types = &.{ .i32, .i64, .i32, .i64, .i32, .i64, .i64, .i64, .i32, .i32, .i32 },
        .argument_types = &.{.i32},
        .result_type = .i32,
        .blocks = &.{.{ .params = &.{0}, .nodes = &.{
            .{ .op = .constant, .out = 1, .immediate = 7 },
            .{ .op = .constant, .out = 2, .immediate = 7 },
            .{ .op = .constant, .out = 3, .immediate = 7, .lhs = 999, .rhs = 888 },
            .{ .op = .constant, .out = 4, .immediate = 8 },
            .{ .op = .sext_i32, .out = 5, .lhs = 0 },
            .{ .op = .zext_i32, .out = 6, .lhs = 0 },
            .{ .op = .sext_i32, .out = 7, .lhs = 0, .rhs = 999, .immediate = 123 },
            .{ .op = .lt_s, .out = 8, .lhs = 0, .rhs = 2 },
            .{ .op = .lt_u, .out = 9, .lhs = 0, .rhs = 2 },
            .{ .op = .lt_s, .out = 10, .lhs = 0, .rhs = 2 },
        }, .terminator = .{ .return_ = 10 } }},
    };
    var result = try optimize.run(a, graph, .{ .constant_folding = false, .dead_code_elimination = false });
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 7), result.graph.blocks[0].nodes.len);
    try result.graph.verify();
}

test "backend CSE: block scope and duplicate edge arguments retain control flow" {
    const graph: ir.Graph = .{
        .types = &@as([12]ir.Type, @splat(.i32)),
        .argument_types = &.{.i32},
        .result_type = .i32,
        .blocks = &.{
            .{ .params = &.{0}, .nodes = &.{
                .{ .op = .constant, .out = 1, .immediate = 7 },
                .{ .op = .constant, .out = 2, .immediate = 7 },
                .{ .op = .eq, .out = 3, .lhs = 0, .rhs = 1 },
                .{ .op = .eq, .out = 4, .lhs = 2, .rhs = 0 },
            }, .terminator = .{ .branch = .{ .condition = 4, .taken = .{ .target = 1, .args = &.{2} }, .fallthrough = .{ .target = 1, .args = &.{0} } } } },
            .{ .params = &.{5}, .nodes = &.{
                .{ .op = .constant, .out = 6, .immediate = 7 },
                .{ .op = .constant, .out = 7, .immediate = 7 },
            }, .terminator = .{ .jump = .{ .target = 2, .args = &.{ 5, 7, 7 } } } },
            .{ .params = &.{ 8, 9, 10 }, .nodes = &.{.{ .op = .sub, .out = 11, .lhs = 8, .rhs = 9 }}, .terminator = .{ .return_ = 11 } },
        },
    };
    var result = try optimize.run(a, graph, .{ .constant_folding = false, .dead_code_elimination = false });
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 3), result.graph.blocks.len);
    try std.testing.expectEqual(@as(usize, 2), result.graph.blocks[0].nodes.len);
    try std.testing.expectEqual(@as(usize, 1), result.graph.blocks[1].nodes.len);
    const branch = result.graph.blocks[0].terminator.branch;
    try std.testing.expectEqual(@as(ir.Value, 2), branch.condition);
    try std.testing.expectEqualSlices(ir.Value, &.{1}, branch.taken.args);
    try std.testing.expectEqualSlices(ir.Value, &.{0}, branch.fallthrough.args);
    try std.testing.expectEqualSlices(ir.Value, &.{ 3, 4, 4 }, result.graph.blocks[1].terminator.jump.args);
    try result.graph.verify();
    if (native.supported) {
        var owner = try CodeAllocator.init(a, 256 * 1024);
        defer owner.deinit();
        for ([_]bool{ false, true }) |cse| {
            for ([_]u8{ 0, 1, 4 }) |registers| {
                var code = try native.compileWithOptions(a, &owner, graph, .{ .register_count = registers, .optimization = .{ .constant_folding = false, .common_subexpression_elimination = cse, .dead_code_elimination = false } });
                defer code.deinit();
                try std.testing.expectEqual(@as(u64, 0), try code.run(&.{7}, 3));
                try std.testing.expectEqual(@as(u64, 2), try code.run(&.{9}, 3));
                try std.testing.expectError(error.BudgetExhausted, code.run(&.{7}, 2));
                try std.testing.expectError(error.BudgetExhausted, code.run(&.{9}, 2));
            }
        }
    }
}

test "backend CSE: duplicate predicates keep every guard and capture occurrence" {
    const graph: ir.Graph = .{
        .types = &.{ .i32, .i32, .i32, .i32 },
        .argument_types = &.{.i32},
        .result_type = .i32,
        .blocks = &.{.{ .params = &.{0}, .nodes = &.{
            .{ .op = .constant, .out = 1, .immediate = 1 },
            .{ .op = .eq, .out = 2, .lhs = 0, .rhs = 1 },
            .{ .op = .eq, .out = 3, .lhs = 1, .rhs = 0 },
            .{ .op = .guard, .lhs = 3, .exit = .{ .id = 15, .values = &.{ 3, 2, 3 } } },
            .{ .op = .guard, .lhs = 2, .exit = .{ .id = 15, .values = &.{ 2, 3, 2 } } },
        }, .terminator = .{ .return_ = 3 } }},
    };
    var result = try optimize.run(a, graph, .{});
    defer result.deinit();
    const nodes = result.graph.blocks[0].nodes;
    try std.testing.expectEqual(@as(usize, 4), nodes.len);
    for (nodes[2..]) |node| {
        try std.testing.expectEqual(ir.Op.guard, node.op);
        try std.testing.expectEqual(@as(ir.Value, 2), node.lhs);
        try std.testing.expectEqual(@as(u32, 15), node.exit.?.id);
        try std.testing.expectEqualSlices(ir.Value, &.{ 2, 2, 2 }, node.exit.?.values);
    }
}

test "backend CSE: independent switches preserve native results and exact exits" {
    if (!native.supported) return error.SkipZigTest;
    var owner = try CodeAllocator.init(a, 256 * 1024);
    defer owner.deinit();
    var oracle = try native.compileWithOptions(a, &owner, repeated, .{ .allocation = .scratch, .optimization = .{ .constant_folding = false, .common_subexpression_elimination = false, .dead_code_elimination = false } });
    defer oracle.deinit();
    for ([_]bool{ false, true }) |fold| {
        for ([_]bool{ false, true }) |cse| {
            for ([_]bool{ false, true }) |dce| {
                for ([_]u8{ 0, 1, 4 }) |registers| {
                    var code = try native.compileWithOptions(a, &owner, repeated, .{ .register_count = registers, .optimization = .{ .constant_folding = fold, .common_subexpression_elimination = cse, .dead_code_elimination = dce } });
                    defer code.deinit();
                    try std.testing.expectEqual(@as(u32, if (cse) 3 else 0), code.optimization.commoned_nodes);
                    try std.testing.expectEqual(@as(u32, if (cse) 5 else 8), code.optimization.output_nodes);
                    for ([_][3]u64{ .{ 7, 11, 1 }, .{ 7, 11, 0 }, .{ 0xffff_ffff_ffff_ffff, 1, 1 }, .{ 0x8000_0000_0000_0000, 3, 0 } }) |args| {
                        var expected = try oracle.runOutcome(&args, 1);
                        defer expected.deinit();
                        var actual = try code.runOutcome(&args, 1);
                        defer actual.deinit();
                        try std.testing.expectEqual(std.meta.activeTag(expected), std.meta.activeTag(actual));
                        switch (expected) {
                            .returned => |value| try std.testing.expectEqual(value, actual.returned),
                            .exited => |exit| {
                                try std.testing.expectEqual(exit.id, actual.exited.id);
                                try std.testing.expectEqualSlices(u64, exit.values, actual.exited.values);
                            },
                        }
                    }
                    try std.testing.expectError(error.BudgetExhausted, code.run(&.{ 7, 11, 1 }, 0));
                }
            }
        }
    }
}

test "backend CSE: folding feeds commoning before transitive dead elimination" {
    const graph: ir.Graph = .{
        .types = &@as([5]ir.Type, @splat(.i64)),
        .argument_types = &.{},
        .result_type = .i64,
        .blocks = &.{.{ .params = &.{}, .nodes = &.{
            .{ .op = .constant, .out = 0, .immediate = 7 },
            .{ .op = .constant, .out = 1, .immediate = 7 },
            .{ .op = .add, .out = 2, .lhs = 0, .rhs = 1 },
            .{ .op = .constant, .out = 3, .immediate = 14 },
            .{ .op = .mul, .out = 4, .lhs = 2, .rhs = 3 },
        }, .terminator = .{ .return_ = 4 } }},
    };
    for ([_]bool{ false, true }) |fold| {
        for ([_]bool{ false, true }) |cse| {
            for ([_]bool{ false, true }) |dce| {
                var result = try optimize.run(a, graph, .{ .constant_folding = fold, .common_subexpression_elimination = cse, .dead_code_elimination = dce });
                defer result.deinit();
                try result.graph.verify();
                try std.testing.expectEqual(@as(u32, if (fold) 2 else 0), result.stats.folded_nodes);
                try std.testing.expectEqual(@as(u32, if (!cse) 0 else if (fold) 2 else 1), result.stats.commoned_nodes);
                try std.testing.expectEqual(result.stats.input_nodes, result.stats.output_nodes + result.stats.commoned_nodes + result.stats.removed_nodes);
                if (fold and dce) {
                    try std.testing.expectEqual(@as(usize, 1), result.graph.blocks[0].nodes.len);
                    try std.testing.expectEqual(@as(u64, 196), result.graph.blocks[0].nodes[0].immediate);
                }
            }
        }
    }
}

fn checkAllocationFailures(allocator: std.mem.Allocator) !void {
    var nodes: [64]ir.Node = undefined;
    for (&nodes, 0..) |*node, i| node.* = .{ .op = .constant, .out = @intCast(i), .immediate = i / 2 };
    const blocks = [_]ir.Block{.{ .params = &.{}, .nodes = &nodes, .terminator = .{ .return_ = 63 } }};
    var result = try optimize.run(allocator, .{ .types = &@as([64]ir.Type, @splat(.i64)), .blocks = &blocks, .argument_types = &.{}, .result_type = .i64 }, .{});
    defer result.deinit();
    try std.testing.expectEqual(@as(u32, 32), result.stats.commoned_nodes);
    try result.graph.verify();
}

test "backend CSE: table growth allocation failures release partial state" {
    try std.testing.checkAllAllocationFailures(a, checkAllocationFailures, .{});
}

test "backend CSE: value limit bounds the table and aliases" {
    var nodes: [ir.max_values]ir.Node = undefined;
    for (&nodes, 0..) |*node, i| node.* = .{ .op = .constant, .out = @intCast(i), .immediate = if (i + 1 == nodes.len) 0 else i };
    const blocks = [_]ir.Block{.{ .params = &.{}, .nodes = &nodes, .terminator = .{ .return_ = ir.max_values - 1 } }};
    var result = try optimize.run(a, .{ .types = &@as([ir.max_values]ir.Type, @splat(.i64)), .blocks = &blocks, .argument_types = &.{}, .result_type = .i64 }, .{ .constant_folding = false, .dead_code_elimination = false });
    defer result.deinit();
    try std.testing.expectEqual(@as(u32, 1), result.stats.commoned_nodes);
    try std.testing.expectEqual(@as(u32, ir.max_values - 1), result.stats.output_nodes);
    try std.testing.expectEqual(@as(ir.Value, 0), result.graph.blocks[0].terminator.return_);
    try result.graph.verify();
}
