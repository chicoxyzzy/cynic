const std = @import("std");
const ir = @import("ir.zig");
const check = @import("vector_test.zig").check;

fn products(nodes: []const ir.Node, lhs: u128, rhs: u128, expected: []const u128) !void {
    var types: [12]ir.Type = @splat(.v128);
    @memset(types[4..8], .i64);
    var results: [12]ir.Value = undefined;
    var result_types: [12]ir.Type = @splat(.v128);
    var words: [20]u64 = undefined;
    const args = [_]u64{ @truncate(lhs), @truncate(lhs >> 64), @truncate(rhs), @truncate(rhs >> 64), 11, 12, 21, 22, 31, 32, 33, 34 };
    for (expected, 0..) |value, i| {
        results[i] = @intCast(8 + i);
        words[2 * i] = @truncate(value);
        words[2 * i + 1] = @truncate(value >> 64);
    }
    @memcpy(results[nodes.len..][0..8], &[_]ir.Value{ 0, 1, 2, 3, 4, 5, 6, 7 });
    @memcpy(result_types[nodes.len..][0..8], types[0..8]);
    @memcpy(words[2 * nodes.len ..][0..args.len], &args);
    const graph: ir.Graph = .{
        .types = types[0 .. 8 + nodes.len],
        .argument_types = types[0..8],
        .result_types = result_types[0 .. nodes.len + 8],
        .blocks = &.{.{ .params = &.{ 0, 1, 2, 3, 4, 5, 6, 7 }, .nodes = nodes, .terminator = .{ .return_ = results[0 .. nodes.len + 8] } }},
    };
    try check(graph, &args, words[0 .. 2 * nodes.len + args.len], null);
}

test "backend SIMD products: extended multiply CSE retains signedness lanes and half selection" {
    const lhs: u128 = 0x80000001ffffffff_800080007fff7fff;
    const rhs: u128 = 0xffffffff7fffffff_7f80018080ff7f01;
    inline for (.{ .{ ir.VectorLane.i8x16, i8, u8, i16, u16, 8 }, .{ ir.VectorLane.i16x8, i16, u16, i32, u32, 4 }, .{ ir.VectorLane.i32x4, i32, u32, i64, u64, 2 } }) |case| {
        const left: [case[5] * 2]case[2] = @bitCast(lhs);
        const right: [case[5] * 2]case[2] = @bitCast(rhs);
        var nodes: [4]ir.Node = undefined;
        var expected: [4]u128 = undefined;
        for (0..4) |form| {
            nodes[form] = .{ .op = if (form < 2) .vector_extmul_s else .vector_extmul_u, .vector_lane = case[0], .immediate = form % 2, .out = @intCast(8 + form), .lhs = 0, .rhs = 1 };
            var lanes: [case[5]]case[4] = undefined;
            for (0..case[5]) |i| {
                const index = i + (form % 2) * case[5];
                lanes[i] = if (form < 2)
                    @bitCast(@as(case[3], @as(case[1], @bitCast(left[index]))) * @as(case[3], @as(case[1], @bitCast(right[index]))))
                else
                    @as(case[4], left[index]) * @as(case[4], right[index]);
            }
            expected[form] = @bitCast(lanes);
        }
        try products(&nodes, lhs, rhs, &expected);
    }
}

test "backend SIMD products: dot and Q15 preserve live homes under every optimization" {
    for ([_]u128{ 0x8080808080808080_8080808080808080, 0x8000800080008000_8000800080008000, 0x80017fff0001ffff_4000c0004001bfff }) |lhs| {
        const rhs = lhs;
        const left16: [8]i16 = @bitCast(lhs);
        const right16: [8]i16 = @bitCast(rhs);
        const left8: [16]i8 = @bitCast(lhs);
        const right8: [16]i8 = @bitCast(rhs);
        var dot: [4]u32 = undefined;
        var q15: [8]i16 = undefined;
        var sat_dot: [8]i16 = undefined;
        for (0..4) |i| {
            const sum = @as(i64, left16[2 * i]) * right16[2 * i] + @as(i64, left16[2 * i + 1]) * right16[2 * i + 1];
            dot[i] = @truncate(@as(u64, @bitCast(sum)));
        }
        for (0..8) |i| {
            q15[i] = @intCast(std.math.clamp((@as(i64, left16[i]) * right16[i] + 0x4000) >> 15, -32768, 32767));
            sat_dot[i] = @intCast(std.math.clamp(@as(i32, left8[2 * i]) * right8[2 * i] + @as(i32, left8[2 * i + 1]) * right8[2 * i + 1], -32768, 32767));
        }
        try products(&.{
            .{ .op = .vector_dot_s, .vector_lane = .i16x8, .out = 8, .lhs = 0, .rhs = 1 },
            .{ .op = .vector_q15mulr_sat_s, .vector_lane = .i16x8, .out = 9, .lhs = 0, .rhs = 1 },
            .{ .op = .vector_dot_sat_s, .vector_lane = .i8x16, .out = 10, .lhs = 0, .rhs = 1 },
        }, lhs, rhs, &.{ @bitCast(dot), @bitCast(q15), @bitCast(sat_dot) });
    }
}

test "backend SIMD products: verifier rejects wrong source widths and immediates" {
    var nodes = [_]ir.Node{.{ .op = .vector_extmul_s, .vector_lane = .i8x16, .out = 2, .lhs = 0, .rhs = 1 }};
    const node = &nodes[0];
    const blocks = [_]ir.Block{.{ .params = &.{ 0, 1 }, .nodes = &nodes, .terminator = .{ .return_ = &.{2} } }};
    const graph: ir.Graph = .{ .types = &.{ .v128, .v128, .v128 }, .argument_types = &.{ .v128, .v128 }, .result_types = &.{.v128}, .blocks = &blocks };
    for ([_]ir.Op{ .vector_extmul_s, .vector_extmul_u, .vector_dot_s, .vector_dot_sat_s, .vector_q15mulr_sat_s }) |op| {
        node.op = op;
        node.vector_lane = if (op == .vector_dot_s or op == .vector_q15mulr_sat_s) .i16x8 else .i8x16;
        try graph.verify();
        node.immediate = if (op == .vector_extmul_s or op == .vector_extmul_u) 2 else 1;
        try std.testing.expectError(error.InvalidGraph, graph.verify());
        node.immediate = 0;
        node.immediate_hi = 1;
        try std.testing.expectError(error.InvalidGraph, graph.verify());
        node.immediate_hi = 0;
        for ([_]ir.VectorLane{ .i64x2, .f32x4, .f64x2 }) |lane| {
            node.vector_lane = lane;
            try std.testing.expectError(error.InvalidGraph, graph.verify());
        }
        if (op != .vector_extmul_s and op != .vector_extmul_u) {
            node.vector_lane = .i32x4;
            try std.testing.expectError(error.InvalidGraph, graph.verify());
            node.vector_lane = if (op == .vector_dot_sat_s) .i16x8 else .i8x16;
            try std.testing.expectError(error.InvalidGraph, graph.verify());
        }
    }
}
