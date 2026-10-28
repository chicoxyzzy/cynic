const std = @import("std");
const ir = @import("ir.zig");
const optimize = @import("optimize.zig");
const native = @import("native.zig");
const CodeAllocator = @import("../code_alloc.zig").CodeAllocator;
const a = std.testing.allocator;

fn expectNativeBits(graph: ir.Graph, bits: u64) !void {
    if (!native.supported) return;
    var owner = try CodeAllocator.init(a, 64 * 1024);
    defer owner.deinit();
    var reference = try native.compileWithOptions(a, &owner, graph, .{ .allocation = .scratch, .optimization = .{ .constant_folding = false, .common_subexpression_elimination = false, .dead_code_elimination = false } });
    defer reference.deinit();
    var optimized = try native.compile(a, &owner, graph);
    defer optimized.deinit();
    try std.testing.expectEqual(bits, try reference.run(&.{}, 1));
    try std.testing.expectEqual(bits, try optimized.run(&.{}, 1));
}

const chain: ir.Graph = .{
    .types = &@as([6]ir.Type, @splat(.i64)),
    .argument_types = &.{},
    .result_types = &.{.i64},
    .blocks = &.{.{ .params = &.{}, .nodes = &.{
        .{ .op = .constant, .out = 0, .immediate = 7 },
        .{ .op = .constant, .out = 1, .immediate = 9 },
        .{ .op = .add, .out = 2, .lhs = 0, .rhs = 1 },
        .{ .op = .mul, .out = 3, .lhs = 2, .rhs = 1 },
        .{ .op = .constant, .out = 4, .immediate = 99 },
        .{ .op = .add, .out = 5, .lhs = 4, .rhs = 0 },
    }, .terminator = .{ .return_ = &.{3} } }},
};

test "backend optimization: independent switches and transitive dead computations" {
    for ([_]bool{ false, true }) |fold| {
        for ([_]bool{ false, true }) |dce| {
            var result = try optimize.run(a, chain, .{ .constant_folding = fold, .dead_code_elimination = dce });
            defer result.deinit();
            try result.graph.verify();
            const count: u32 = if (!dce) 6 else if (fold) 1 else 4;
            try std.testing.expectEqual(count, result.stats.output_nodes);
            try std.testing.expectEqual(@as(u32, 6), result.stats.input_nodes);
            try std.testing.expectEqual(@as(u32, if (fold) 3 else 0), result.stats.folded_nodes);
            try std.testing.expectEqual(6 - count, result.stats.removed_nodes);
            try std.testing.expectEqual(count, result.graph.types.len);
            const last = result.graph.blocks[0].nodes[if (fold and dce) 0 else 3];
            try std.testing.expectEqual(if (fold) ir.Op.constant else ir.Op.mul, last.op);
            if (fold) try std.testing.expectEqual(@as(u64, 144), last.immediate);
        }
    }
    try std.testing.expectEqual(ir.Op.add, chain.blocks[0].nodes[2].op);
}

test "backend optimization: constant integer arithmetic and comparisons preserve bits" {
    const Case = struct { op: ir.Op, ty: ir.Type, lhs: u64, rhs: u64, expected: u64 };
    const cases = [_]Case{
        .{ .op = .add, .ty = .i32, .lhs = 0xffff_ffff, .rhs = 1, .expected = 0 },
        .{ .op = .sub, .ty = .i32, .lhs = 0, .rhs = 1, .expected = 0xffff_ffff },
        .{ .op = .mul, .ty = .i32, .lhs = 0x8000_0000, .rhs = 2, .expected = 0 },
        .{ .op = .add, .ty = .i64, .lhs = 0xffff_ffff_ffff_ffff, .rhs = 1, .expected = 0 },
        .{ .op = .sub, .ty = .i64, .lhs = 0, .rhs = 1, .expected = 0xffff_ffff_ffff_ffff },
        .{ .op = .mul, .ty = .i64, .lhs = 0x8000_0000_0000_0000, .rhs = 3, .expected = 0x8000_0000_0000_0000 },
        .{ .op = .bit_and, .ty = .i64, .lhs = 0xffff_ffff_1234_5678, .rhs = 0x8000_0000_0000_ffff, .expected = 0x8000_0000_0000_5678 },
        .{ .op = .bit_or, .ty = .i32, .lhs = 0x8000_0000, .rhs = 0x1234, .expected = 0x8000_1234 },
        .{ .op = .eq, .ty = .i64, .lhs = 0x8000_0000_0000_0000, .rhs = 0x8000_0000_0000_0000, .expected = 1 },
        .{ .op = .eq, .ty = .i32, .lhs = 0, .rhs = 1, .expected = 0 },
        .{ .op = .lt_s, .ty = .i32, .lhs = 0x8000_0000, .rhs = 0x7fff_ffff, .expected = 1 },
        .{ .op = .lt_s, .ty = .i64, .lhs = 0x8000_0000_0000_0000, .rhs = 0, .expected = 1 },
        .{ .op = .lt_u, .ty = .i32, .lhs = 0x8000_0000, .rhs = 0x7fff_ffff, .expected = 0 },
        .{ .op = .lt_u, .ty = .i64, .lhs = 0, .rhs = 0xffff_ffff_ffff_ffff, .expected = 1 },
        .{ .op = .ge_s, .ty = .i32, .lhs = 0xffff_ffff, .rhs = 0, .expected = 0 },
        .{ .op = .ge_s, .ty = .i64, .lhs = 0xffff_ffff_ffff_ffff, .rhs = 0xffff_ffff_ffff_ffff, .expected = 1 },
        .{ .op = .ge_u, .ty = .i32, .lhs = 0xffff_ffff, .rhs = 0, .expected = 1 },
        .{ .op = .ge_u, .ty = .i64, .lhs = 0, .rhs = 1, .expected = 0 },
    };
    for (cases) |case| {
        const output_type: ir.Type = switch (case.op) {
            .eq, .lt_s, .lt_u, .ge_s, .ge_u => .i32,
            else => case.ty,
        };
        const nodes = [_]ir.Node{
            .{ .op = .constant, .out = 0, .immediate = case.lhs },
            .{ .op = .constant, .out = 1, .immediate = case.rhs },
            .{ .op = case.op, .out = 2, .lhs = 0, .rhs = 1 },
        };
        const types = [_]ir.Type{ case.ty, case.ty, output_type };
        const blocks = [_]ir.Block{.{ .params = &.{}, .nodes = &nodes, .terminator = .{ .return_ = &.{2} } }};
        const graph: ir.Graph = .{ .types = &types, .blocks = &blocks, .argument_types = &.{}, .result_types = &.{output_type} };
        var result = try optimize.run(a, graph, .{});
        defer result.deinit();
        try std.testing.expectEqual(@as(usize, 1), result.graph.blocks[0].nodes.len);
        try std.testing.expectEqual(case.expected, result.graph.blocks[0].nodes[0].immediate);
        try result.graph.verify();
        try expectNativeBits(graph, case.expected);
    }
}

test "backend optimization: constant width conversions preserve signedness" {
    const Case = struct { op: ir.Op, input: ir.Type, output: ir.Type, bits: u64, expected: u64 };
    const cases = [_]Case{
        .{ .op = .sext_i32, .input = .i32, .output = .i64, .bits = 0x8000_0000, .expected = 0xffff_ffff_8000_0000 },
        .{ .op = .zext_i32, .input = .i32, .output = .i64, .bits = 0xffff_ffff, .expected = 0xffff_ffff },
        .{ .op = .trunc_i64, .input = .i64, .output = .i32, .bits = 0x1234_5678_8000_0000, .expected = 0x8000_0000 },
    };
    for (cases) |case| {
        const nodes = [_]ir.Node{ .{ .op = .constant, .out = 0, .immediate = case.bits }, .{ .op = case.op, .out = 1, .lhs = 0 } };
        const types = [_]ir.Type{ case.input, case.output };
        const blocks = [_]ir.Block{.{ .params = &.{}, .nodes = &nodes, .terminator = .{ .return_ = &.{1} } }};
        const graph: ir.Graph = .{ .types = &types, .blocks = &blocks, .argument_types = &.{}, .result_types = &.{case.output} };
        var result = try optimize.run(a, graph, .{});
        defer result.deinit();
        try std.testing.expectEqual(@as(usize, 1), result.graph.blocks[0].nodes.len);
        try std.testing.expectEqual(case.expected, result.graph.blocks[0].nodes[0].immediate);
        try expectNativeBits(graph, case.expected);
    }
}

const guarded: ir.Graph = .{
    .types = &.{ .i32, .i64, .i64, .i64, .i64, .i32 },
    .argument_types = &.{},
    .result_types = &.{.i64},
    .blocks = &.{.{ .params = &.{}, .nodes = &.{
        .{ .op = .constant, .out = 0, .immediate = 0 },
        .{ .op = .constant, .out = 1, .immediate = 0x8000_0000_1234_5678 },
        .{ .op = .add, .out = 2, .lhs = 1, .rhs = 1 },
        .{ .op = .constant, .out = 3, .immediate = 99 },
        .{ .op = .add, .out = 4, .lhs = 3, .rhs = 3 },
        .{ .op = .constant, .out = 5, .immediate = 1 },
        .{ .op = .guard, .lhs = 5, .exit = .{ .id = 77, .values = &.{ 2, 1, 2 } } },
        .{ .op = .guard, .lhs = 0, .exit = .{ .id = 78, .values = &.{1} } },
    }, .terminator = .{ .return_ = &.{1} } }},
};

test "backend optimization: guards stay ordered even with constant predicates" {
    var result = try optimize.run(a, guarded, .{});
    defer result.deinit();
    const nodes = result.graph.blocks[0].nodes;
    try std.testing.expectEqual(@as(usize, 6), nodes.len);
    try std.testing.expectEqual(@as(u32, 77), nodes[4].exit.?.id);
    try std.testing.expectEqualSlices(ir.Value, &.{ 2, 1, 2 }, nodes[4].exit.?.values);
    try std.testing.expectEqual(@as(u64, 0x2468_acf0), nodes[2].immediate);
    try std.testing.expectEqual(@as(u32, 78), nodes[5].exit.?.id);
    try std.testing.expectEqual(@as(u32, 2), result.stats.removed_nodes);
    try result.graph.verify();
}

test "backend optimization: loop parameters stay unknown and edges retain their shape" {
    const graph: ir.Graph = .{
        .types = &@as([6]ir.Type, @splat(.i32)),
        .argument_types = &.{},
        .result_types = &.{.i32},
        .blocks = &.{
            .{ .params = &.{}, .nodes = &.{ .{ .op = .constant, .out = 4, .immediate = 1 }, .{ .op = .constant, .out = 2, .immediate = 99 } }, .terminator = .{ .jump = .{ .target = 1, .args = &.{4} } } },
            .{ .params = &.{0}, .nodes = &.{ .{ .op = .constant, .out = 3, .immediate = 1 }, .{ .op = .sub, .out = 5, .lhs = 0, .rhs = 3 } }, .terminator = .{ .branch = .{ .condition = 0, .taken = .{ .target = 1, .args = &.{5} }, .fallthrough = .{ .target = 2, .args = &.{0} } } } },
            .{ .params = &.{1}, .terminator = .{ .return_ = &.{1} } },
        },
    };
    var result = try optimize.run(a, graph, .{});
    defer result.deinit();
    try std.testing.expectEqual(@as(u32, 0), result.stats.folded_nodes);
    try std.testing.expectEqual(@as(u32, 1), result.stats.removed_nodes);
    try std.testing.expectEqual(@as(usize, 3), result.graph.blocks.len);
    try std.testing.expectEqual(ir.Op.sub, result.graph.blocks[1].nodes[1].op);
    try std.testing.expectEqualSlices(ir.Value, &.{3}, result.graph.blocks[0].terminator.jump.args);
    try std.testing.expectEqualSlices(ir.Value, &.{4}, result.graph.blocks[1].terminator.branch.taken.args);
    try result.graph.verify();
}

test "backend optimization: malformed dead definitions are rejected before removal" {
    const graph: ir.Graph = .{
        .types = &.{ .i32, .i32 },
        .argument_types = &.{},
        .result_types = &.{.i32},
        .blocks = &.{.{ .params = &.{}, .nodes = &.{ .{ .op = .constant, .out = 0, .immediate = 0x1_0000_0000 }, .{ .op = .constant, .out = 1 } }, .terminator = .{ .return_ = &.{1} } }},
    };
    try std.testing.expectError(error.InvalidGraph, optimize.run(a, graph, .{}));
}

fn allocationFailures(allocator: std.mem.Allocator) anyerror!void {
    var result = try optimize.run(allocator, guarded, .{});
    defer result.deinit();
    try result.graph.verify();
}

test "backend optimization: allocation failures release partial graphs" {
    try std.testing.checkAllAllocationFailures(a, allocationFailures, .{});
}

test "backend optimization: native switches reduce code and preserve guard captures" {
    if (!native.supported) return error.SkipZigTest;
    var owner = try CodeAllocator.init(a, 256 * 1024);
    defer owner.deinit();
    var reference = try native.compileWithOptions(a, &owner, chain, .{ .allocation = .scratch, .optimization = .{ .constant_folding = false, .common_subexpression_elimination = false, .dead_code_elimination = false } });
    defer reference.deinit();
    for ([_]bool{ false, true }) |fold| {
        for ([_]bool{ false, true }) |dce| {
            const options: native.Options = .{ .allocation = .scratch, .optimization = .{ .constant_folding = fold, .dead_code_elimination = dce } };
            var compiled = try native.compileWithOptions(a, &owner, chain, options);
            defer compiled.deinit();
            try std.testing.expectEqual(try reference.run(&.{}, 1), try compiled.run(&.{}, 1));
            try std.testing.expectEqual(@as(u32, if (fold) 3 else 0), compiled.optimization.folded_nodes);
            if (fold and dce) {
                try std.testing.expectEqual(@as(u32, 5), compiled.optimization.removed_nodes);
                try std.testing.expect(compiled.code.bytes().?.len < reference.code.bytes().?.len);
            }
            try std.testing.expectError(error.BudgetExhausted, compiled.run(&.{}, 0));
            var guarded_code = try native.compileWithOptions(a, &owner, guarded, options);
            defer guarded_code.deinit();
            var outcome = try guarded_code.runOutcome(&.{}, 1);
            defer outcome.deinit();
            try std.testing.expectEqual(@as(u32, 78), outcome.exited.id);
            try std.testing.expectEqualSlices(u64, &.{0x8000_0000_1234_5678}, outcome.exited.values);
        }
    }
}

test "backend optimization: seeded native cases match the unoptimized scratch oracle" {
    if (!native.supported) return error.SkipZigTest;
    var owner = try CodeAllocator.init(a, 256 * 1024);
    defer owner.deinit();
    var prng = std.Random.DefaultPrng.init(0x6f7074696d697a65);
    const random = prng.random();
    const ops = [_]ir.Op{ .add, .sub, .mul, .bit_and, .bit_or };
    for (0..16) |_| {
        var types: [34]ir.Type = @splat(.i64);
        types[0] = .i32;
        var nodes: [33]ir.Node = undefined;
        for (0..32) |i| {
            const out: ir.Value = @intCast(i + 2);
            nodes[i] = if (i < 2 or i % 4 == 0)
                .{ .op = .constant, .out = out, .immediate = random.int(u64) }
            else
                .{ .op = ops[random.int(u32) % ops.len], .out = out, .lhs = if (i == 2) 2 else 1 + random.int(u32) % (out - 1), .rhs = if (i == 2) 3 else 1 + random.int(u32) % (out - 1) };
            if (i % 4 == 3) {
                nodes[i] = nodes[i - 1];
                nodes[i].out = out;
            }
        }
        nodes[32] = .{ .op = .guard, .lhs = 0, .exit = .{ .id = 51, .values = &.{ 1, 4, 32, 4 } } };
        const blocks = [_]ir.Block{.{ .params = &.{ 0, 1 }, .nodes = &nodes, .terminator = .{ .return_ = &.{33} } }};
        const graph: ir.Graph = .{ .types = &types, .blocks = &blocks, .argument_types = types[0..2], .result_types = &.{.i64} };
        var reference = try native.compileWithOptions(a, &owner, graph, .{ .allocation = .scratch, .optimization = .{ .constant_folding = false, .common_subexpression_elimination = false, .dead_code_elimination = false } });
        defer reference.deinit();
        const input = random.int(u64);
        for ([_]bool{ false, true }) |fold| {
            for ([_]bool{ false, true }) |cse| {
                for ([_]bool{ false, true }) |dce| {
                    for ([_]u8{ 0, 1, 4 }) |registers| {
                        var compiled = try native.compileWithOptions(a, &owner, graph, .{ .register_count = registers, .optimization = .{ .constant_folding = fold, .common_subexpression_elimination = cse, .dead_code_elimination = dce } });
                        defer compiled.deinit();
                        for ([_]u64{ 0, 1 }) |predicate| {
                            var expected = try reference.runOutcome(&.{ predicate, input }, 1);
                            defer expected.deinit();
                            var actual = try compiled.runOutcome(&.{ predicate, input }, 1);
                            defer actual.deinit();
                            try std.testing.expectEqual(std.meta.activeTag(expected), std.meta.activeTag(actual));
                            switch (expected) {
                                .trapped => return error.UnexpectedNativeTrap,
                                .returned => |value| try std.testing.expectEqual(value, actual.returned),
                                .exited => |exit| {
                                    try std.testing.expectEqual(exit.id, actual.exited.id);
                                    try std.testing.expectEqualSlices(u64, exit.values, actual.exited.values);
                                },
                            }
                        }
                    }
                }
            }
        }
    }
}

test "backend optimization: output owns argument edges and guard captures" {
    var types = [_]ir.Type{ .i32, .i32 };
    var argument_types = [_]ir.Type{.i32};
    var entry_params = [_]ir.Value{0};
    var target_params = [_]ir.Value{1};
    var args = [_]ir.Value{0};
    var captures = [_]ir.Value{1};
    var nodes = [_]ir.Node{.{ .op = .guard, .lhs = 1, .exit = .{ .id = 31, .values = &captures } }};
    var blocks = [_]ir.Block{
        .{ .params = &entry_params, .terminator = .{ .jump = .{ .target = 1, .args = &args } } },
        .{ .params = &target_params, .nodes = &nodes, .terminator = .{ .return_ = &.{1} } },
    };
    const graph: ir.Graph = .{ .types = &types, .argument_types = &argument_types, .result_types = &.{.i32}, .blocks = &blocks };
    var result = try optimize.run(a, graph, .{});
    defer result.deinit();
    types[0] = .i64;
    argument_types[0] = .i64;
    entry_params[0] = 99;
    target_params[0] = 99;
    args[0] = 99;
    captures[0] = 99;
    nodes[0].lhs = 99;
    blocks[0].terminator.jump.target = 99;
    try result.graph.verify();
    try std.testing.expectEqual(ir.Type.i32, result.graph.argument_types[0]);
    try std.testing.expectEqualSlices(ir.Value, &.{1}, result.graph.blocks[1].nodes[0].exit.?.values);
}
