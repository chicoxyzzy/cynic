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
