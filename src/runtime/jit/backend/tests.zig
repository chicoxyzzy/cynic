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
