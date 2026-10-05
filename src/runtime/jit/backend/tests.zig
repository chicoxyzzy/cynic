const std = @import("std");
const ir = @import("ir.zig");
const native = @import("native.zig");
const CodeAllocator = @import("../code_alloc.zig").CodeAllocator;

test "backend prototype: verifier rejects malformed definitions and types" {
    var types = [_]ir.Type{ .i32, .i32 };
    var nodes = [_]ir.Node{.{ .op = .constant, .out = 1 }};
    var blocks = [_]ir.Block{.{ .params = &.{0}, .nodes = &nodes, .terminator = .{ .return_ = 1 } }};
    var graph: ir.Graph = .{ .types = &types, .blocks = &blocks, .argument_types = &.{.i32}, .result_type = .i32 };
    try graph.verify();
    nodes[0].out = 0;
    try std.testing.expectError(error.InvalidGraph, graph.verify());
    nodes[0].out = 2;
    try std.testing.expectError(error.InvalidGraph, graph.verify());
    nodes[0] = .{ .op = .add, .out = 1, .lhs = 1, .rhs = 0 };
    try std.testing.expectError(error.InvalidGraph, graph.verify());
    nodes[0] = .{ .op = .constant, .out = 1, .immediate = 0x1_0000_0000 };
    try std.testing.expectError(error.InvalidGraph, graph.verify());
    nodes[0].immediate = 0;
    types[0] = .i64;
    try std.testing.expectError(error.InvalidGraph, graph.verify());
    types[0] = .i32;
    graph.result_type = .i64;
    try std.testing.expectError(error.InvalidGraph, graph.verify());
    graph.result_type = .i32;
    blocks[0].terminator = .{ .return_ = 2 };
    try std.testing.expectError(error.InvalidGraph, graph.verify());
}

test "backend prototype: verifier rejects invalid edges and implicit cross-block uses" {
    var blocks = [_]ir.Block{
        .{ .params = &.{0}, .terminator = .{ .jump = .{ .target = 1, .args = &.{0} } } },
        .{ .params = &.{1}, .terminator = .{ .return_ = 1 } },
    };
    var types = [_]ir.Type{ .i32, .i32 };
    const graph: ir.Graph = .{ .types = &types, .blocks = &blocks, .argument_types = &.{.i32}, .result_type = .i32 };
    try graph.verify();
    blocks[1].terminator = .{ .return_ = 0 };
    try std.testing.expectError(error.InvalidGraph, graph.verify());
    blocks[1].terminator = .{ .return_ = 1 };
    blocks[0].terminator.jump.target = 0;
    try std.testing.expectError(error.InvalidGraph, graph.verify());
    blocks[0].terminator.jump.target = 2;
    try std.testing.expectError(error.InvalidGraph, graph.verify());
    blocks[0].terminator.jump.target = 1;
    blocks[0].terminator.jump.args = &.{};
    try std.testing.expectError(error.InvalidGraph, graph.verify());
    blocks[0].terminator.jump.args = &.{0};
    types[1] = .i64;
    try std.testing.expectError(error.InvalidGraph, graph.verify());
}

const swap_graph: ir.Graph = .{
    .types = &@as([13]ir.Type, @splat(.i32)),
    .argument_types = &.{ .i32, .i32, .i32 },
    .result_type = .i32,
    .blocks = &.{
        .{ .params = &.{ 0, 1, 2 }, .terminator = .{ .jump = .{ .target = 1, .args = &.{ 0, 1, 2 } } } },
        .{ .params = &.{ 3, 4, 5 }, .nodes = &.{
            .{ .op = .constant, .out = 6 },
            .{ .op = .eq, .out = 7, .lhs = 5, .rhs = 6 },
            .{ .op = .constant, .out = 8, .immediate = 1 },
            .{ .op = .sub, .out = 9, .lhs = 5, .rhs = 8 },
        }, .terminator = .{ .branch = .{
            .condition = 7,
            .taken = .{ .target = 2, .args = &.{ 3, 4 } },
            .fallthrough = .{ .target = 1, .args = &.{ 4, 3, 9 } },
        } } },
        .{ .params = &.{ 10, 11 }, .nodes = &.{.{ .op = .sub, .out = 12, .lhs = 10, .rhs = 11 }}, .terminator = .{ .return_ = 12 } },
    },
};

test "backend prototype: native edge assignments preserve cycles" {
    if (!native.supported) return error.SkipZigTest;
    var owner = try CodeAllocator.init(std.testing.allocator, 64 * 1024);
    defer owner.deinit();
    var compiled = try native.compile(std.testing.allocator, &owner, swap_graph);
    defer compiled.deinit();
    try std.testing.expectEqual(@as(u64, 0xffff_fffb), try compiled.run(&.{ 7, 2, 1 }, 10));
    try std.testing.expectEqual(@as(u64, 5), try compiled.run(&.{ 7, 2, 2 }, 10));
    try std.testing.expectError(error.BudgetExhausted, compiled.run(&.{ 7, 2, 20 }, 10));
    try std.testing.expectError(error.PrototypeLimit, compiled.run(&.{ 7, 2, 1 }, native.max_budget + 1));
}

fn compileWithFailures(a: std.mem.Allocator, owner: *CodeAllocator) !void {
    var compiled = try native.compile(a, owner, swap_graph);
    defer compiled.deinit();
    try std.testing.expectEqual(@as(u64, 5), try compiled.run(&.{ 7, 2, 2 }, 10));
}

test "backend prototype: native compilation cleans up on allocation failure" {
    if (!native.supported) return error.SkipZigTest;
    var owner = try CodeAllocator.init(std.testing.allocator, 64 * 1024);
    defer owner.deinit();
    try std.testing.checkAllAllocationFailures(std.testing.allocator, compileWithFailures, .{&owner});
}

test "backend prototype: ordered guards capture pre-operation values" {
    if (!native.supported) return error.SkipZigTest;
    var nodes = [_]ir.Node{
        .{ .op = .guard, .lhs = 0, .exit = .{ .id = 42, .values = &.{ 1, 2 } } },
        .{ .op = .add, .out = 4, .lhs = 1, .rhs = 2 },
        .{ .op = .guard, .lhs = 3, .exit = .{ .id = 43, .values = &.{4} } },
    };
    const blocks = [_]ir.Block{.{ .params = &.{ 0, 1, 2, 3 }, .nodes = &nodes, .terminator = .{ .return_ = 4 } }};
    const graph: ir.Graph = .{ .types = &.{ .i32, .i64, .i64, .i32, .i64 }, .argument_types = &.{ .i32, .i64, .i64, .i32 }, .result_type = .i64, .blocks = &blocks };
    var owner = try CodeAllocator.init(std.testing.allocator, 64 * 1024);
    defer owner.deinit();
    var compiled = try native.compile(std.testing.allocator, &owner, graph);
    defer compiled.deinit();
    var success = try compiled.runOutcome(&.{ 1, 7, 9, 1 }, 10);
    defer success.deinit();
    try std.testing.expectEqual(@as(u64, 16), success.returned);
    var failure = try compiled.runOutcome(&.{ 0, 7, 9, 0 }, 10);
    defer failure.deinit();
    try std.testing.expect(failure == .exited);
    try std.testing.expectEqual(@as(u32, 42), failure.exited.id);
    try std.testing.expectEqualSlices(u64, &.{ 7, 9 }, failure.exited.values);
    var later_failure = try compiled.runOutcome(&.{ 1, 7, 9, 0 }, 10);
    defer later_failure.deinit();
    try std.testing.expectEqual(@as(u32, 43), later_failure.exited.id);
    try std.testing.expectEqualSlices(u64, &.{16}, later_failure.exited.values);
    try std.testing.expectError(error.UnexpectedSideExit, compiled.run(&.{ 0, 7, 9, 0 }, 10));
    nodes[0].exit.?.values = &.{4};
    try std.testing.expectError(error.InvalidGraph, graph.verify());
    nodes[0].exit.?.values = &.{1};
    nodes[0].lhs = 1;
    try std.testing.expectError(error.InvalidGraph, graph.verify());
    nodes[0].lhs = 0;
    nodes[0].out = 3;
    try std.testing.expectError(error.InvalidGraph, graph.verify());
    nodes[0].out = null;
    nodes[0].exit = null;
    try std.testing.expectError(error.InvalidGraph, graph.verify());
    nodes[0].exit = .{ .id = 0, .values = &.{} };
    nodes[1].exit = nodes[0].exit;
    try std.testing.expectError(error.InvalidGraph, graph.verify());
    nodes[1].exit = null;
    nodes[1].out = null;
    try std.testing.expectError(error.InvalidGraph, graph.verify());
}

test "backend prototype: guards cannot bypass node and capture limits" {
    const nodes = try std.testing.allocator.alloc(ir.Node, ir.max_nodes + 1);
    defer std.testing.allocator.free(nodes);
    @memset(nodes, .{ .op = .guard, .lhs = 0, .exit = .{ .id = 0, .values = &.{} } });
    var blocks = [_]ir.Block{.{ .params = &.{0}, .nodes = nodes, .terminator = .{ .return_ = 0 } }};
    const graph: ir.Graph = .{ .types = &.{.i32}, .argument_types = &.{.i32}, .result_type = .i32, .blocks = &blocks };
    try std.testing.expectError(error.PrototypeLimit, graph.verify());
    blocks[0].nodes = nodes[0..1];
    try graph.verify();
    nodes[0].exit.?.values = &@as([ir.max_arguments + 1]ir.Value, @splat(0));
    try std.testing.expectError(error.PrototypeLimit, graph.verify());
}

test "backend prototype: signed and unsigned width conversions" {
    if (!native.supported) return error.SkipZigTest;
    var nodes = [_]ir.Node{
        .{ .op = .trunc_i64, .out = 1, .lhs = 0 },
        .{ .op = .sext_i32, .out = 2, .lhs = 1 },
    };
    const blocks = [_]ir.Block{.{ .params = &.{0}, .nodes = &nodes, .terminator = .{ .return_ = 2 } }};
    const graph: ir.Graph = .{ .types = &.{ .i64, .i32, .i64 }, .argument_types = &.{.i64}, .result_type = .i64, .blocks = &blocks };
    var owner = try CodeAllocator.init(std.testing.allocator, 64 * 1024);
    defer owner.deinit();
    {
        var compiled = try native.compile(std.testing.allocator, &owner, graph);
        defer compiled.deinit();
        try std.testing.expectEqual(@as(u64, 0xffff_ffff_8000_0000), try compiled.run(&.{0x1234_5678_8000_0000}, 10));
    }
    nodes[1].op = .zext_i32;
    var compiled = try native.compile(std.testing.allocator, &owner, graph);
    defer compiled.deinit();
    try std.testing.expectEqual(@as(u64, 0x8000_0000), try compiled.run(&.{0x1234_5678_8000_0000}, 10));
    nodes[0].op = .sext_i32;
    try std.testing.expectError(error.InvalidGraph, graph.verify());
}

const pressure_graph: ir.Graph = .{
    .types = &(.{ir.Type.i32} ++ @as([15]ir.Type, @splat(.i64))),
    .argument_types = &(.{ir.Type.i32} ++ @as([8]ir.Type, @splat(.i64))),
    .result_type = .i64,
    .blocks = &.{.{ .params = &.{ 0, 1, 2, 3, 4, 5, 6, 7, 8 }, .nodes = &.{
        .{ .op = .add, .out = 9, .lhs = 1, .rhs = 2 },
        .{ .op = .add, .out = 10, .lhs = 9, .rhs = 3 },
        .{ .op = .guard, .lhs = 0, .exit = .{ .id = 123, .values = &.{ 1, 9, 10, 8 } } },
        .{ .op = .add, .out = 11, .lhs = 10, .rhs = 4 },
        .{ .op = .add, .out = 12, .lhs = 11, .rhs = 5 },
        .{ .op = .add, .out = 13, .lhs = 12, .rhs = 6 },
        .{ .op = .add, .out = 14, .lhs = 13, .rhs = 7 },
        .{ .op = .add, .out = 15, .lhs = 14, .rhs = 8 },
    }, .terminator = .{ .return_ = 15 } }},
};

test "backend allocation: native pressure and guard captures match scratch oracle" {
    if (!native.supported) return error.SkipZigTest;
    var owner = try CodeAllocator.init(std.testing.allocator, 256 * 1024);
    defer owner.deinit();
    var reference = try native.compileWithOptions(std.testing.allocator, &owner, pressure_graph, .{ .allocation = .scratch });
    defer reference.deinit();
    for ([_]u8{ 0, 1, 4 }) |register_count| {
        var compiled = try native.compileWithOptions(std.testing.allocator, &owner, pressure_graph, .{ .register_count = register_count });
        defer compiled.deinit();
        const args = [_]u64{ 1, 1, 2, 3, 4, 5, 6, 7, 8 };
        try std.testing.expectEqual(try reference.run(&args, 10), try compiled.run(&args, 10));
        var exit = try compiled.runOutcome(&.{ 0, 1, 2, 3, 4, 5, 6, 7, 8 }, 10);
        defer exit.deinit();
        var expected_exit = try reference.runOutcome(&.{ 0, 1, 2, 3, 4, 5, 6, 7, 8 }, 10);
        defer expected_exit.deinit();
        try std.testing.expectEqual(@as(u32, 123), exit.exited.id);
        try std.testing.expectEqualSlices(u64, expected_exit.exited.values, exit.exited.values);
        try std.testing.expectEqualSlices(u64, &.{ 1, 3, 6, 8 }, exit.exited.values);
        try std.testing.expect(compiled.scratchSlotCount() < reference.scratchSlotCount());
        if (register_count > 0) try std.testing.expect(compiled.stats.loads + compiled.stats.stores < reference.stats.loads + reference.stats.stores);
    }
    try std.testing.expectError(error.PrototypeLimit, native.compileWithOptions(std.testing.allocator, &owner, pressure_graph, .{ .register_count = 5 }));
}

test "backend allocation: native loop transfers and budget exits match scratch oracle" {
    if (!native.supported) return error.SkipZigTest;
    var owner = try CodeAllocator.init(std.testing.allocator, 256 * 1024);
    defer owner.deinit();
    var reference = try native.compileWithOptions(std.testing.allocator, &owner, swap_graph, .{ .allocation = .scratch });
    defer reference.deinit();
    for ([_]u8{ 0, 1, 4 }) |register_count| {
        var compiled = try native.compileWithOptions(std.testing.allocator, &owner, swap_graph, .{ .register_count = register_count });
        defer compiled.deinit();
        for (0..20) |n| try std.testing.expectEqual(try reference.run(&.{ 7, 2, n }, 100), try compiled.run(&.{ 7, 2, n }, 100));
        try std.testing.expectError(error.BudgetExhausted, compiled.run(&.{ 7, 2, 20 }, 10));
        try std.testing.expectError(error.BudgetExhausted, compiled.run(&.{ 7, 2, 20 }, 0));
        try std.testing.expect(compiled.scratchSlotCount() < reference.scratchSlotCount());
    }
}

test "backend allocation: seeded live-range pressure matches scratch at every guard" {
    if (!native.supported) return error.SkipZigTest;
    const a = std.testing.allocator;
    var owner = try CodeAllocator.init(a, 256 * 1024);
    defer owner.deinit();
    var prng = std.Random.DefaultPrng.init(0x44a1c0de);
    const random = prng.random();
    const ops = [_]ir.Op{ .add, .sub, .mul, .bit_and, .bit_or };
    for (0..12) |_| {
        var types: [60]ir.Type = @splat(.i64);
        @memset(types[0..6], .i32);
        var nodes: [54]ir.Node = undefined;
        var captures: [6][3]ir.Value = undefined;
        var node_index: usize = 0;
        for (0..48) |i| {
            const out: ir.Value = @intCast(12 + i);
            const lhs = 6 + random.int(u32) % (out - 6);
            const rhs = 6 + random.int(u32) % (out - 6);
            nodes[node_index] = .{ .op = ops[random.int(u32) % ops.len], .out = out, .lhs = lhs, .rhs = rhs };
            node_index += 1;
            if (i % 8 == 7) {
                const guard = i / 8;
                captures[guard] = .{ 6, out, lhs };
                nodes[node_index] = .{ .op = .guard, .lhs = @intCast(guard), .exit = .{ .id = @intCast(guard), .values = &captures[guard] } };
                node_index += 1;
            }
        }
        const blocks = [_]ir.Block{.{ .params = &.{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11 }, .nodes = &nodes, .terminator = .{ .return_ = 59 } }};
        const graph: ir.Graph = .{ .types = &types, .argument_types = types[0..12], .result_type = .i64, .blocks = &blocks };
        var reference = try native.compileWithOptions(a, &owner, graph, .{ .allocation = .scratch });
        defer reference.deinit();
        var args: [12]u64 = undefined;
        for (args[6..]) |*arg| arg.* = random.int(u64);
        for ([_]u8{ 0, 1, 4 }) |register_count| {
            var compiled = try native.compileWithOptions(a, &owner, graph, .{ .register_count = register_count });
            defer compiled.deinit();
            for (0..7) |failed_guard| {
                @memset(args[0..6], 1);
                if (failed_guard < 6) args[failed_guard] = 0;
                var expected = try reference.runOutcome(&args, 10);
                defer expected.deinit();
                var actual = try compiled.runOutcome(&args, 10);
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
        }
    }
}
