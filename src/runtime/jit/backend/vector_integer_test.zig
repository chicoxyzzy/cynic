const std = @import("std");
const ir = @import("ir.zig");
const check = @import("vector_test.zig").check;

test "backend SIMD integers: arithmetic preserves live GP and vector homes in every mode" {
    const lhs: u128 = 0x800000007fffffff_80ff01fe7f00ff01;
    const rhs: u128 = 0x7fffffff80000001_7f0102ff80ff0100;
    inline for (.{ .{ ir.VectorLane.i8x16, i8, u8, 16 }, .{ ir.VectorLane.i16x8, i16, u16, 8 }, .{ ir.VectorLane.i32x4, i32, u32, 4 }, .{ ir.VectorLane.i64x2, i64, u64, 2 } }) |case| {
        const left: [case[3]]case[2] = @bitCast(lhs);
        const right: [case[3]]case[2] = @bitCast(rhs);
        for ([_]ir.Op{ .vector_sub, .vector_mul, .vector_abs, .vector_neg, .vector_add_sat_s, .vector_add_sat_u, .vector_sub_sat_s, .vector_sub_sat_u, .vector_min_s, .vector_min_u, .vector_max_s, .vector_max_u, .vector_avgr_u, .vector_popcnt }) |op| {
            if (op == .vector_mul and case[0] == .i8x16) continue;
            if ((op == .vector_add_sat_s or op == .vector_add_sat_u or op == .vector_sub_sat_s or op == .vector_sub_sat_u or op == .vector_avgr_u) and @sizeOf(case[2]) > 2) continue;
            if ((op == .vector_min_s or op == .vector_min_u or op == .vector_max_s or op == .vector_max_u) and @sizeOf(case[2]) > 4) continue;
            if (op == .vector_popcnt and case[0] != .i8x16) continue;
            var lanes: [case[3]]case[2] = undefined;
            for (left, right, 0..) |l, r, i| {
                const sl: case[1] = @bitCast(l);
                const sr: case[1] = @bitCast(r);
                lanes[i] = switch (op) {
                    .vector_sub => l -% r,
                    .vector_mul => l *% r,
                    .vector_abs => if (sl < 0) 0 -% l else l,
                    .vector_neg => 0 -% l,
                    .vector_add_sat_s => @bitCast(sl +| sr),
                    .vector_add_sat_u => l +| r,
                    .vector_sub_sat_s => @bitCast(sl -| sr),
                    .vector_sub_sat_u => l -| r,
                    .vector_min_s => @bitCast(@min(sl, sr)),
                    .vector_min_u => @min(l, r),
                    .vector_max_s => @bitCast(@max(sl, sr)),
                    .vector_max_u => @max(l, r),
                    .vector_avgr_u => @intCast((@as(u128, l) + r + 1) / 2),
                    .vector_popcnt => @popCount(l),
                    else => unreachable,
                };
            }
            try live(op, case[0], lhs, rhs, @bitCast(lanes), false);
        }
        for ([_]ir.Op{ .vector_shl, .vector_shr_s, .vector_shr_u }) |op| for ([_]u32{ 0, 1, @bitSizeOf(case[2]) - 1, @bitSizeOf(case[2]), 0xffffffff }) |count| {
            var lanes: [case[3]]case[2] = undefined;
            const amount: std.math.Log2Int(case[2]) = @truncate(count);
            for (left, 0..) |l, i| lanes[i] = switch (op) {
                .vector_shl => l << amount,
                .vector_shr_s => @bitCast(@as(case[1], @bitCast(l)) >> amount),
                .vector_shr_u => l >> amount,
                else => unreachable,
            };
            try live(op, case[0], lhs, count, @bitCast(lanes), true);
        };
    }
}

fn live(op: ir.Op, lane: ir.VectorLane, lhs: u128, rhs: u128, expected: u128, shift: bool) !void {
    const rhs_type: ir.Type = if (shift) .i32 else .v128;
    const graph: ir.Graph = .{
        .types = &.{ .v128, rhs_type, .v128, .v128, .v128, .i64, .i64, .i64, .i64, .v128 },
        .argument_types = &.{ .v128, rhs_type, .v128, .v128, .v128, .i64, .i64, .i64, .i64 },
        .result_types = &.{ .v128, .v128, rhs_type, .v128, .v128, .v128, .i64, .i64, .i64, .i64 },
        .blocks = &.{.{ .params = &.{ 0, 1, 2, 3, 4, 5, 6, 7, 8 }, .nodes = &.{.{ .op = op, .out = 9, .lhs = 0, .rhs = 1, .vector_lane = lane }}, .terminator = .{ .return_ = &.{ 9, 0, 1, 2, 3, 4, 5, 6, 7, 8 } } }},
    };
    var args: [14]u64 = .{ @truncate(lhs), @truncate(lhs >> 64), @truncate(rhs), @truncate(rhs >> 64), 11, 12, 21, 22, 31, 32, 41, 42, 43, 44 };
    if (shift) std.mem.copyForwards(u64, args[3..], args[4..]);
    const count: usize = if (shift) 13 else 14;
    var results: [16]u64 = undefined;
    results[0] = @truncate(expected);
    results[1] = @truncate(expected >> 64);
    @memcpy(results[2..][0..count], args[0..count]);
    try check(graph, args[0..count], results[0 .. count + 2], null);
}

test "backend SIMD integers: composed selects preserve three operands and live homes" {
    const graph: ir.Graph = .{
        .types = &.{ .v128, .v128, .v128, .v128, .i64, .i64, .i64, .i64, .v128, .v128, .v128 },
        .argument_types = &.{ .v128, .v128, .v128, .v128, .i64, .i64, .i64, .i64 },
        .result_types = &.{ .v128, .v128, .v128, .v128, .v128, .i64, .i64, .i64, .i64 },
        .blocks = &.{.{ .params = &.{ 0, 1, 2, 3, 4, 5, 6, 7 }, .nodes = &.{
            .{ .op = .bit_xor, .out = 8, .lhs = 0, .rhs = 1 },
            .{ .op = .bit_and, .out = 9, .lhs = 8, .rhs = 2 },
            .{ .op = .bit_xor, .out = 10, .lhs = 9, .rhs = 1 },
        }, .terminator = .{ .return_ = &.{ 10, 0, 1, 2, 3, 4, 5, 6, 7 } } }},
    };
    const args = [_]u64{ 0x123456789abcdef0, 0xff00ff00ff00ff00, 0x8877665544332211, 0x0123456789abcdef, 0x80010001ff007f7f, 0xfefdfcfbfaf9f8f7, 42, 43, 11, 22, 33, 44 };
    const expected = [_]u64{ (args[0] & args[4]) | (args[2] & ~args[4]), (args[1] & args[5]) | (args[3] & ~args[5]) } ++ args;
    try check(graph, &args, &expected, null);
}

test "backend SIMD integers: verifier rejects invalid lane widths and shift counts" {
    var nodes = [_]ir.Node{.{ .op = .vector_sub, .out = 2, .lhs = 0, .rhs = 1, .vector_lane = .i8x16 }};
    const node = &nodes[0];
    const blocks = [_]ir.Block{.{ .params = &.{ 0, 1 }, .nodes = &nodes, .terminator = .{ .return_ = &.{2} } }};
    var graph: ir.Graph = .{ .types = &.{ .v128, .v128, .v128 }, .argument_types = &.{ .v128, .v128 }, .result_types = &.{.v128}, .blocks = &blocks };
    for ([_]ir.Op{ .vector_sub, .vector_mul, .vector_abs, .vector_neg, .vector_add_sat_s, .vector_add_sat_u, .vector_sub_sat_s, .vector_sub_sat_u, .vector_min_s, .vector_min_u, .vector_max_s, .vector_max_u, .vector_avgr_u, .vector_popcnt }) |op| {
        node.op = op;
        node.vector_lane = if (op == .vector_mul) .i16x8 else .i8x16;
        try graph.verify();
        node.immediate = 1;
        try std.testing.expectError(error.InvalidGraph, graph.verify());
        node.immediate = 0;
        node.vector_lane = .f32x4;
        try std.testing.expectError(error.InvalidGraph, graph.verify());
        node.vector_lane = .f64x2;
        try std.testing.expectError(error.InvalidGraph, graph.verify());
        if (op != .vector_sub and op != .vector_mul and op != .vector_abs and op != .vector_neg) {
            node.vector_lane = .i64x2;
            try std.testing.expectError(error.InvalidGraph, graph.verify());
        }
    }
    node.op = .vector_mul;
    node.vector_lane = .i8x16;
    try std.testing.expectError(error.InvalidGraph, graph.verify());
    for ([_]ir.Op{ .vector_shl, .vector_shr_s, .vector_shr_u }) |op| {
        node.op = op;
        try std.testing.expectError(error.InvalidGraph, graph.verify());
        graph.types = &.{ .v128, .i32, .v128 };
        graph.argument_types = &.{ .v128, .i32 };
        try graph.verify();
        graph.types = &.{ .v128, .i64, .v128 };
        graph.argument_types = &.{ .v128, .i64 };
        try std.testing.expectError(error.InvalidGraph, graph.verify());
    }
}
