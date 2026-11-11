const std = @import("std");
const ir = @import("ir.zig");
const check = @import("vector_test.zig").check;

fn comparisons(lane: ir.VectorLane, ops: []const ir.Op, lhs: u128, rhs: u128, masks: []const u128) !void {
    var types: [12]ir.Type = @splat(.v128);
    @memset(types[2..6], .i64);
    var nodes: [6]ir.Node = undefined;
    var results: [12]ir.Value = undefined;
    var result_types: [12]ir.Type = @splat(.v128);
    var expected: [20]u64 = undefined;
    const args = [_]u64{ @truncate(lhs), @truncate(lhs >> 64), @truncate(rhs), @truncate(rhs >> 64), 11, 22, 33, 44 };
    for (ops, masks, 0..) |op, mask, i| {
        nodes[i] = .{ .op = op, .out = @intCast(6 + i), .lhs = 0, .rhs = 1, .vector_lane = lane };
        results[i] = @intCast(6 + i);
        expected[2 * i] = @truncate(mask);
        expected[2 * i + 1] = @truncate(mask >> 64);
    }
    @memcpy(results[ops.len..][0..6], &[_]ir.Value{ 0, 1, 2, 3, 4, 5 });
    @memcpy(result_types[ops.len..][0..6], types[0..6]);
    @memcpy(expected[2 * ops.len ..][0..8], &args);
    const graph: ir.Graph = .{
        .types = types[0 .. 6 + ops.len],
        .argument_types = types[0..6],
        .result_types = result_types[0 .. ops.len + 6],
        .blocks = &.{.{ .params = &.{ 0, 1, 2, 3, 4, 5 }, .nodes = nodes[0..ops.len], .terminator = .{ .return_ = results[0 .. ops.len + 6] } }},
    };
    try check(graph, &args, expected[0 .. 2 * ops.len + 8], null);
}

test "backend SIMD predicates: integer masks keep signedness and live homes" {
    const lhs: u128 = 0x8000000000000001_00000000ffffffff;
    const rhs: u128 = 0x7fffffffffffffff_0000000100000000;
    const ops = [_]ir.Op{ .vector_eq, .vector_ne, .vector_lt_s, .vector_lt_u, .vector_le_s, .vector_le_u };
    inline for (.{ .{ ir.VectorLane.i8x16, i8, u8, 16 }, .{ ir.VectorLane.i16x8, i16, u16, 8 }, .{ ir.VectorLane.i32x4, i32, u32, 4 }, .{ ir.VectorLane.i64x2, i64, u64, 2 } }) |case| {
        const left: [case[3]]case[2] = @bitCast(lhs);
        const right: [case[3]]case[2] = @bitCast(rhs);
        var masks: [6]u128 = undefined;
        for (ops, 0..) |op, index| {
            var lanes: [case[3]]case[2] = undefined;
            for (left, right, 0..) |l, r, i| {
                const sl: case[1] = @bitCast(l);
                const sr: case[1] = @bitCast(r);
                const yes = switch (op) {
                    .vector_eq => l == r,
                    .vector_ne => l != r,
                    .vector_lt_s => sl < sr,
                    .vector_le_s => sl <= sr,
                    .vector_lt_u => l < r,
                    .vector_le_u => l <= r,
                    else => unreachable,
                };
                lanes[i] = if (yes) std.math.maxInt(case[2]) else 0;
            }
            masks[index] = @bitCast(lanes);
        }
        try comparisons(case[0], &ops, lhs, rhs, &masks);
        try comparisons(case[0], &ops, lhs, lhs, &.{ std.math.maxInt(u128), 0, 0, 0, std.math.maxInt(u128), std.math.maxInt(u128) });
    }
}

test "backend SIMD predicates: floating masks survive all allocation and optimization modes" {
    const ops = [_]ir.Op{ .vector_eq, .vector_ne, .vector_flt, .vector_fle };
    inline for (.{ .{ ir.VectorLane.f32x4, f32, u32, 4 }, .{ ir.VectorLane.f64x2, f64, u64, 2 } }) |case| {
        var left: [case[3]]case[1] = @splat(0);
        var right: [case[3]]case[1] = @splat(-1);
        left[0] = std.math.nan(case[1]);
        right[1] = -0.0;
        var masks: [4]u128 = undefined;
        for (ops, 0..) |op, index| {
            var lanes: [case[3]]case[2] = undefined;
            for (left, right, 0..) |l, r, i| lanes[i] = if (switch (op) {
                .vector_eq => l == r,
                .vector_ne => l != r,
                .vector_flt => l < r,
                .vector_fle => l <= r,
                else => unreachable,
            }) std.math.maxInt(case[2]) else 0;
            masks[index] = @bitCast(lanes);
        }
        try comparisons(case[0], &ops, @bitCast(left), @bitCast(right), &masks);
    }
}

test "backend SIMD predicates: reductions preserve scalar and vector homes" {
    for ([_]ir.VectorLane{ .i8x16, .i16x8, .i32x4, .i64x2 }) |lane| for ([_]u128{ 0, 0x8000000000000001_00000000ffffffff, std.math.maxInt(u128) }) |input| {
        const bits = lane.bytes() * 8;
        const mask = (@as(u128, 1) << @as(u7, @intCast(bits))) - 1;
        var all: u64 = 1;
        var signs: u64 = 0;
        for (0..lane.count()) |i| {
            const part = (input >> @as(u7, @intCast(i * bits))) & mask;
            if (part == 0) all = 0;
            if (part >> @as(u7, @intCast(bits - 1)) != 0) signs |= @as(u64, 1) << @as(u6, @intCast(i));
        }
        const args = [_]u64{ @truncate(input), @truncate(input >> 64), 11, 22, 33, 44 };
        const graph: ir.Graph = .{
            .types = &.{ .v128, .i64, .i64, .i64, .i64, .i32, .i32, .i32 },
            .argument_types = &.{ .v128, .i64, .i64, .i64, .i64 },
            .result_types = &.{ .i32, .i32, .i32, .v128, .i64, .i64, .i64, .i64 },
            .blocks = &.{.{ .params = &.{ 0, 1, 2, 3, 4 }, .nodes = &.{
                .{ .op = .vector_any_true, .out = 5, .lhs = 0 },
                .{ .op = .vector_all_true, .out = 6, .lhs = 0, .vector_lane = lane },
                .{ .op = .vector_bitmask, .out = 7, .lhs = 0, .vector_lane = lane },
            }, .terminator = .{ .return_ = &.{ 5, 6, 7, 0, 1, 2, 3, 4 } } }},
        };
        const expected = [_]u64{ @intFromBool(input != 0), all, signs } ++ args;
        try check(graph, &args, &expected, null);
    };
}

test "backend SIMD predicates: CSE retains comparison and reduction lane interpretation" {
    const graph: ir.Graph = .{
        .types = &.{ .v128, .v128, .v128, .v128, .i32, .i32, .i32, .i32 },
        .argument_types = &.{ .v128, .v128 },
        .result_types = &.{ .v128, .v128, .i32, .i32, .i32, .i32 },
        .blocks = &.{.{ .params = &.{ 0, 1 }, .nodes = &.{
            .{ .op = .vector_eq, .out = 2, .lhs = 0, .rhs = 1, .vector_lane = .i32x4 },
            .{ .op = .vector_eq, .out = 3, .lhs = 0, .rhs = 1, .vector_lane = .f32x4 },
            .{ .op = .vector_all_true, .out = 4, .lhs = 1, .vector_lane = .i32x4 },
            .{ .op = .vector_all_true, .out = 5, .lhs = 1, .vector_lane = .i64x2 },
            .{ .op = .vector_bitmask, .out = 6, .lhs = 0, .vector_lane = .i16x8 },
            .{ .op = .vector_bitmask, .out = 7, .lhs = 0, .vector_lane = .i32x4 },
        }, .terminator = .{ .return_ = &.{ 2, 3, 4, 5, 6, 7 } } }},
    };
    try check(graph, &.{ 0x8000000000000001, 0x0000000180000000, 1, 0x0000000100000000 }, &.{
        0xffffffff, 0xffffffff00000000, std.math.maxInt(u64), std.math.maxInt(u64), 0, 1, 0x28, 6,
    }, null);
}

test "backend SIMD predicates: verifier rejects wrong lane kinds and scalar results" {
    var nodes = [_]ir.Node{.{ .op = .vector_eq, .out = 1, .lhs = 0, .rhs = 0, .vector_lane = .i8x16 }};
    const node = &nodes[0];
    const blocks = [_]ir.Block{.{ .params = &.{0}, .nodes = &nodes, .terminator = .{ .return_ = &.{1} } }};
    var graph: ir.Graph = .{ .types = &.{ .v128, .v128 }, .argument_types = &.{.v128}, .result_types = &.{.v128}, .blocks = &blocks };
    try graph.verify();
    node.immediate = 1;
    try std.testing.expectError(error.InvalidGraph, graph.verify());
    node.immediate = 0;
    for ([_]ir.Op{ .vector_lt_s, .vector_lt_u, .vector_le_s, .vector_le_u }) |op| {
        node.op = op;
        node.vector_lane = .f32x4;
        try std.testing.expectError(error.InvalidGraph, graph.verify());
    }
    for ([_]ir.Op{ .vector_flt, .vector_fle }) |op| {
        node.op = op;
        node.vector_lane = .i32x4;
        try std.testing.expectError(error.InvalidGraph, graph.verify());
    }
    for ([_]ir.Op{ .vector_any_true, .vector_all_true, .vector_bitmask }) |op| {
        node.op = op;
        node.vector_lane = if (op == .vector_any_true) null else .i8x16;
        try std.testing.expectError(error.InvalidGraph, graph.verify());
        graph.types = &.{ .v128, .i32 };
        graph.result_types = &.{.i32};
        try graph.verify();
        node.vector_lane = .f32x4;
        try std.testing.expectError(error.InvalidGraph, graph.verify());
        graph.types = &.{ .v128, .v128 };
        graph.result_types = &.{.v128};
    }
}
