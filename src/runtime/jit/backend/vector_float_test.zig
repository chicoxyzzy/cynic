const std = @import("std");
const ir = @import("ir.zig");
const check = @import("vector_test.zig").check;

pub const ops = [_]ir.Op{ .vector_fsub, .vector_fmul, .vector_fdiv, .vector_fmin, .vector_fmax, .vector_fpmin, .vector_fpmax, .vector_fabs, .vector_fneg, .vector_fsqrt, .vector_fceil, .vector_ffloor, .vector_ftrunc, .vector_fnearest, .vector_convert_s, .vector_convert_u, .vector_trunc_sat_s, .vector_trunc_sat_u, .vector_promote_f32, .vector_demote_f64 };

pub fn valid(op: ir.Op, lane: ir.VectorLane) bool {
    return (op != .vector_promote_f32 or lane == .f32x4) and (op != .vector_demote_f64 or lane == .f64x2);
}

pub fn sample(op: ir.Op, lane: ir.VectorLane) struct { lhs: u128, rhs: u128, result: u128 } {
    const left: u128 = if (lane == .f32x4) @bitCast([4]f32{ 2.25, 2.25, 2.25, 2.25 }) else @bitCast([2]f64{ 2.25, 2.25 });
    const right: u128 = if (lane == .f32x4) @bitCast([4]f32{ 1.5, 1.5, 1.5, 1.5 }) else @bitCast([2]f64{ 1.5, 1.5 });
    const number: f64 = switch (op) {
        .vector_fsub => 0.75,
        .vector_fmul => 3.375,
        .vector_fdiv, .vector_fmin, .vector_fpmin, .vector_fsqrt => 1.5,
        .vector_fneg => -2.25,
        .vector_fceil => 3,
        .vector_ffloor, .vector_ftrunc, .vector_fnearest => 2,
        .vector_convert_s => -1,
        .vector_convert_u => 4294967295.0,
        else => 2.25,
    };
    const words32: [4]f32 = @splat(@floatCast(number));
    const words64: [2]f64 = @splat(number);
    const result: u128 = switch (op) {
        .vector_trunc_sat_s, .vector_trunc_sat_u => if (lane == .f32x4) @bitCast([4]u32{ 2, 2, 2, 2 }) else @bitCast([4]u32{ 2, 2, 0, 0 }),
        .vector_promote_f32 => @bitCast(words64),
        .vector_demote_f64 => @bitCast([4]f32{ 2.25, 2.25, 0, 0 }),
        else => if (lane == .f32x4) @bitCast(words32) else @bitCast(words64),
    };
    return .{ .lhs = if (op == .vector_convert_s or op == .vector_convert_u) std.math.maxInt(u128) else left, .rhs = right, .result = result };
}

test "backend SIMD float: every operation preserves allocated homes under every optimization" {
    for (ops) |op| for ([_]ir.VectorLane{ .f32x4, .f64x2 }) |lane| {
        if (!valid(op, lane)) continue;
        const values = sample(op, lane);
        const graph: ir.Graph = .{
            .types = &.{ .v128, .v128, .v128, .v128, .i64, .i64, .i64, .i64, .v128 },
            .argument_types = &.{ .v128, .v128, .v128, .v128, .i64, .i64, .i64, .i64 },
            .result_types = &.{ .v128, .v128, .v128, .v128, .v128, .i64, .i64, .i64, .i64 },
            .blocks = &.{.{ .params = &.{ 0, 1, 2, 3, 4, 5, 6, 7 }, .nodes = &.{.{ .op = op, .out = 8, .lhs = 0, .rhs = if (ir.inputCount(op) == 2) 1 else 0, .vector_lane = lane }}, .terminator = .{ .return_ = &.{ 8, 0, 1, 2, 3, 4, 5, 6, 7 } } }},
        };
        const args = [_]u64{ @truncate(values.lhs), @truncate(values.lhs >> 64), @truncate(values.rhs), @truncate(values.rhs >> 64), 11, 12, 21, 22, 31, 32, 33, 34 };
        const expected = [_]u64{ @truncate(values.result), @truncate(values.result >> 64) } ++ args;
        try check(graph, &args, &expected, null);
    };
}

test "backend SIMD float: verifier rejects integer lanes and invalid conversion shapes" {
    var nodes = [_]ir.Node{.{ .op = .vector_fsub, .out = 2, .lhs = 0, .rhs = 1, .vector_lane = .f32x4 }};
    const graph: ir.Graph = .{ .types = &.{ .v128, .v128, .v128 }, .argument_types = &.{ .v128, .v128 }, .result_types = &.{.v128}, .blocks = &.{.{ .params = &.{ 0, 1 }, .nodes = &nodes, .terminator = .{ .return_ = &.{2} } }} };
    for (ops) |op| {
        nodes[0].op = op;
        nodes[0].rhs = if (ir.inputCount(op) == 2) 1 else 0;
        nodes[0].vector_lane = if (op == .vector_demote_f64) .f64x2 else .f32x4;
        try graph.verify();
        nodes[0].immediate = 1;
        try std.testing.expectError(error.InvalidGraph, graph.verify());
        nodes[0].immediate = 0;
        for ([_]ir.VectorLane{ .i8x16, .i16x8, .i32x4, .i64x2 }) |lane| {
            nodes[0].vector_lane = lane;
            try std.testing.expectError(error.InvalidGraph, graph.verify());
        }
        if (op == .vector_demote_f64 or op == .vector_promote_f32) {
            nodes[0].vector_lane = if (op == .vector_demote_f64) .f32x4 else .f64x2;
            try std.testing.expectError(error.InvalidGraph, graph.verify());
        }
    }
}
