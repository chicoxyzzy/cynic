const std = @import("std");
const ir = @import("ir.zig");
const check = @import("vector_test.zig").check;

test "backend SIMD widths: extension halves and signedness survive CSE and live homes" {
    const input: u128 = 0x80007fff00010000_ffff010000ff0080;
    inline for (.{ .{ ir.VectorLane.i8x16, i8, u8, i16, u16, 16 }, .{ ir.VectorLane.i16x8, i16, u16, i32, u32, 8 }, .{ ir.VectorLane.i32x4, i32, u32, i64, u64, 4 } }) |case| {
        const N = case[5];
        const raw: [N]case[2] = @bitCast(input);
        var signed_low: [N / 2]case[3] = undefined;
        var signed_high: [N / 2]case[3] = undefined;
        var unsigned_low: [N / 2]case[4] = undefined;
        var unsigned_high: [N / 2]case[4] = undefined;
        for (0..N / 2) |i| {
            signed_low[i] = @as(case[1], @bitCast(raw[i]));
            signed_high[i] = @as(case[1], @bitCast(raw[i + N / 2]));
            unsigned_low[i] = raw[i];
            unsigned_high[i] = raw[i + N / 2];
        }
        const sl: [2]u64 = @bitCast(signed_low);
        const sh: [2]u64 = @bitCast(signed_high);
        const ul: [2]u64 = @bitCast(unsigned_low);
        const uh: [2]u64 = @bitCast(unsigned_high);
        const args = [_]u64{ @truncate(input), @truncate(input >> 64), 11, 22, 33, 44 };
        const graph: ir.Graph = .{
            .types = &.{ .v128, .i64, .i64, .i64, .i64, .v128, .v128, .v128, .v128 },
            .argument_types = &.{ .v128, .i64, .i64, .i64, .i64 },
            .result_types = &.{ .v128, .v128, .v128, .v128, .v128, .i64, .i64, .i64, .i64 },
            .blocks = &.{.{ .params = &.{ 0, 1, 2, 3, 4 }, .nodes = &.{
                .{ .op = .vector_extend_s, .out = 5, .lhs = 0, .vector_lane = case[0] },
                .{ .op = .vector_extend_s, .out = 6, .lhs = 0, .vector_lane = case[0], .immediate = 1 },
                .{ .op = .vector_extend_u, .out = 7, .lhs = 0, .vector_lane = case[0] },
                .{ .op = .vector_extend_u, .out = 8, .lhs = 0, .vector_lane = case[0], .immediate = 1 },
            }, .terminator = .{ .return_ = &.{ 5, 6, 7, 8, 0, 1, 2, 3, 4 } } }},
        };
        try check(graph, &args, &(sl ++ sh ++ ul ++ uh ++ args), null);
    }
}

test "backend SIMD widths: signed and unsigned saturation preserve concatenation order" {
    const left: u128 = 0x800000007fffffff_ffff000000010000;
    const right: u128 = 0x0000800000007fff_000100000000ffff;
    inline for (.{ .{ ir.VectorLane.i8x16, i16, i8, u8, 8 }, .{ ir.VectorLane.i16x8, i32, i16, u16, 4 } }) |case| {
        const N = case[4];
        const lhs: [N]case[1] = @bitCast(left);
        const rhs: [N]case[1] = @bitCast(right);
        var signed: [2 * N]case[2] = undefined;
        var unsigned: [2 * N]case[3] = undefined;
        for (lhs ++ rhs, 0..) |value, i| {
            signed[i] = @intCast(std.math.clamp(value, std.math.minInt(case[2]), std.math.maxInt(case[2])));
            unsigned[i] = @intCast(std.math.clamp(value, 0, std.math.maxInt(case[3])));
        }
        const s: [2]u64 = @bitCast(signed);
        const u: [2]u64 = @bitCast(unsigned);
        const args = [_]u64{ @truncate(left), @truncate(left >> 64), @truncate(right), @truncate(right >> 64), 11, 22, 33, 44 };
        const graph: ir.Graph = .{
            .types = &.{ .v128, .v128, .i64, .i64, .i64, .i64, .v128, .v128 },
            .argument_types = &.{ .v128, .v128, .i64, .i64, .i64, .i64 },
            .result_types = &.{ .v128, .v128, .v128, .v128, .i64, .i64, .i64, .i64 },
            .blocks = &.{.{ .params = &.{ 0, 1, 2, 3, 4, 5 }, .nodes = &.{
                .{ .op = .vector_narrow_s, .out = 6, .lhs = 0, .rhs = 1, .vector_lane = case[0] },
                .{ .op = .vector_narrow_u, .out = 7, .lhs = 0, .rhs = 1, .vector_lane = case[0] },
            }, .terminator = .{ .return_ = &.{ 6, 7, 0, 1, 2, 3, 4, 5 } } }},
        };
        try check(graph, &args, &(s ++ u ++ args), null);
    }
}

test "backend SIMD widths: pairwise addition widens before overflow and keeps live inputs" {
    const input: u128 = 0xffff800080807fff_ffffffff00000001;
    inline for (.{ .{ ir.VectorLane.i8x16, i8, u8, i16, u16, 16 }, .{ ir.VectorLane.i16x8, i16, u16, i32, u32, 8 } }) |case| {
        const N = case[5];
        const raw: [N]case[2] = @bitCast(input);
        var signed: [N / 2]case[3] = undefined;
        var unsigned: [N / 2]case[4] = undefined;
        for (0..N / 2) |i| {
            signed[i] = @as(case[3], @as(case[1], @bitCast(raw[2 * i]))) + @as(case[1], @bitCast(raw[2 * i + 1]));
            unsigned[i] = @as(case[4], raw[2 * i]) + raw[2 * i + 1];
        }
        const s: [2]u64 = @bitCast(signed);
        const u: [2]u64 = @bitCast(unsigned);
        const args = [_]u64{ @truncate(input), @truncate(input >> 64), 11, 22, 33, 44 };
        const graph: ir.Graph = .{
            .types = &.{ .v128, .i64, .i64, .i64, .i64, .v128, .v128 },
            .argument_types = &.{ .v128, .i64, .i64, .i64, .i64 },
            .result_types = &.{ .v128, .v128, .v128, .i64, .i64, .i64, .i64 },
            .blocks = &.{.{ .params = &.{ 0, 1, 2, 3, 4 }, .nodes = &.{
                .{ .op = .vector_pairwise_add_s, .out = 5, .lhs = 0, .vector_lane = case[0] },
                .{ .op = .vector_pairwise_add_u, .out = 6, .lhs = 0, .vector_lane = case[0] },
            }, .terminator = .{ .return_ = &.{ 5, 6, 0, 1, 2, 3, 4 } } }},
        };
        try check(graph, &args, &(s ++ u ++ args), null);
    }
}

test "backend SIMD widths: verifier rejects invalid widths halves and operand types" {
    var nodes = [_]ir.Node{.{ .op = .vector_extend_s, .out = 1, .lhs = 0, .vector_lane = .i8x16 }};
    const blocks = [_]ir.Block{.{ .params = &.{0}, .nodes = &nodes, .terminator = .{ .return_ = &.{1} } }};
    var graph: ir.Graph = .{ .types = &.{ .v128, .v128 }, .argument_types = &.{.v128}, .result_types = &.{.v128}, .blocks = &blocks };
    try graph.verify();
    nodes[0].immediate = 2;
    try std.testing.expectError(error.InvalidGraph, graph.verify());
    nodes[0].immediate = 0;
    for ([_]ir.VectorLane{ .i64x2, .f32x4, .f64x2 }) |bad| {
        nodes[0].vector_lane = bad;
        try std.testing.expectError(error.InvalidGraph, graph.verify());
    }
    for ([_]ir.Op{ .vector_narrow_s, .vector_narrow_u, .vector_pairwise_add_s, .vector_pairwise_add_u }) |op| {
        nodes[0] = .{ .op = op, .out = 1, .lhs = 0, .rhs = 0, .vector_lane = .i16x8 };
        try graph.verify();
        nodes[0].immediate = 1;
        try std.testing.expectError(error.InvalidGraph, graph.verify());
        nodes[0].immediate = 0;
        nodes[0].vector_lane = .i32x4;
        try std.testing.expectError(error.InvalidGraph, graph.verify());
    }
    nodes[0] = .{ .op = .vector_extend_s, .out = 1, .lhs = 0, .vector_lane = .i8x16 };
    graph.types = &.{ .i64, .v128 };
    graph.argument_types = &.{.i64};
    try std.testing.expectError(error.InvalidGraph, graph.verify());
}
