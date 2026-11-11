const std = @import("std");
const wasm = @import("wasm.zig");
const backend = wasm.backend_prototype;
const simd = @import("spasm_simd.zig");
const a = std.testing.allocator;

const integers = [_]u128{
    0,                                   0xffffffffffffffff_ffffffffffffffff,
    0x808080807f7f7f7f_800080007fff7fff, 0x800000007fffffff_7fffffff80000000,
    0x8000000000000000_7fffffffffffffff, 0x0000000100000000_00000000ffffffff,
    0x0123456789abcdef_fedcba9876543210,
};

fn laneMask(bits: usize) u128 {
    return (@as(u128, 1) << @as(u7, @intCast(bits))) - 1;
}

fn relation(comptime T: type, lhs: T, rhs: T, op: simd.Comparison) bool {
    return switch (op) {
        .eq => lhs == rhs,
        .ne => lhs != rhs,
        .lt => lhs < rhs,
        .gt => lhs > rhs,
        .le => lhs <= rhs,
        .ge => lhs >= rhs,
    };
}

fn compare(lhs: u128, rhs: u128, op: simd.ComparisonOp) u128 {
    const bits: usize = @as(usize, op.width) * 8;
    const mask = laneMask(bits);
    var result: u128 = 0;
    for (0..128 / bits) |index| {
        const shift: u7 = @intCast(index * bits);
        const left = (lhs >> shift) & mask;
        const right = (rhs >> shift) & mask;
        const yes = if (op.floating)
            (if (op.width == 4)
                relation(f32, @bitCast(@as(u32, @intCast(left))), @bitCast(@as(u32, @intCast(right))), op.relation)
            else
                relation(f64, @bitCast(@as(u64, @intCast(left))), @bitCast(@as(u64, @intCast(right))), op.relation))
        else if (op.signed) blk: {
            const sign = @as(u128, 1) << @as(u7, @intCast(bits - 1));
            const modulus = @as(i128, 1) << @as(u7, @intCast(bits));
            const sl = @as(i128, @intCast(left)) - (if (left & sign != 0) modulus else 0);
            const sr = @as(i128, @intCast(right)) - (if (right & sign != 0) modulus else 0);
            break :blk relation(i128, sl, sr, op.relation);
        } else relation(u128, left, right, op.relation);
        if (yes) result |= mask << shift;
    }
    return result;
}

fn check(sub: u32, args: []const u128, result_type: wasm.ValType, expected: u128, branch: bool) !void {
    if (!backend.native.supported) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(a);
    try body.append(a, 0);
    for (0..args.len) |i| try body.appendSlice(a, &.{ 0x20, @intCast(i) });
    try body.append(a, 0xfd);
    if (sub < 128) try body.append(a, @intCast(sub)) else try body.appendSlice(a, &.{ @as(u8, @intCast(sub & 127)) | 128, @intCast(sub >> 7) });
    if (branch) try body.appendSlice(a, &.{ 0x04, 0x7f, 0x41, 7, 0x05, 0x41, 9, 0x0b });
    try body.append(a, 0x0b);
    const params: [2]wasm.ValType = @splat(.v128);
    const module: wasm.Module = .{ .types = &.{.{ .params = params[0..args.len], .results = &.{result_type} }}, .funcs = &.{0}, .code = &.{.{ .bytes = body.items }} };
    var instance: wasm.Instance = undefined;
    try wasm.instantiate(&instance, arena.allocator(), a, &module, .{});
    defer instance.deinit();
    for (0..3) |tier| {
        instance.spasm_enabled = tier == 1;
        instance.shared_backend_enabled = tier == 2;
        if (tier == 2) {
            var graph = try backend.lowerInstance(a, &instance, 0);
            defer graph.deinit();
        }
        const entries = if (tier == 1) instance.spasm_runs else instance.shared_backend_stats.entries;
        const result = try wasm.invoke(&instance, a, 0, args);
        defer a.free(result);
        try std.testing.expectEqualSlices(u128, &.{expected}, result);
        if (tier == 1) try std.testing.expectEqual(entries + 1, instance.spasm_runs);
        if (tier == 2) {
            try std.testing.expectEqual(entries + 1, instance.shared_backend_stats.entries);
            try std.testing.expectEqual(@as(u64, 0), instance.shared_backend_stats.refusals);
        }
    }
}

test "backend SIMD predicates: integer comparisons produce complete masks across tiers" {
    for ([_]struct { start: u32, end: u32 }{ .{ .start = 35, .end = 65 }, .{ .start = 214, .end = 220 } }) |range| {
        for (range.start..range.end) |sub| {
            const op = simd.comparisonOp(@intCast(sub)).?;
            for (integers, 0..) |lhs, i| for ([_]u128{ lhs, ~lhs, integers[(i + 1) % integers.len] }) |rhs| {
                try check(@intCast(sub), &.{ lhs, rhs }, .v128, compare(lhs, rhs, op), false);
            };
        }
    }
}

test "backend SIMD predicates: floating comparisons preserve unordered zero and subnormal semantics" {
    const values = [_]u128{
        0,                                   0x8000000000000000_8000000080000000,
        0x0000000000000001_0000000100000001, 0x8000000000000001_8000000180000001,
        0x7ff0000000000000_7f800000ff800000, 0x7ff8000000000042_7fc000427f800042,
        0xfff0000000000042_ffc00042ff800042, 0x3ff0000000000000_bf8000003f800000,
    };
    for (65..77) |sub| {
        const op = simd.comparisonOp(@intCast(sub)).?;
        for (values) |lhs| for (values) |rhs| try check(@intCast(sub), &.{ lhs, rhs }, .v128, compare(lhs, rhs, op), false);
    }
}

test "backend SIMD predicates: reductions distinguish complete lanes and sign bits" {
    for ([_]u32{ 99, 100, 131, 132, 163, 164, 195, 196 }) |sub| {
        const op = simd.reductionOp(sub).?;
        const bits: usize = @as(usize, op.width) * 8;
        for (0..128 / bits) |index| {
            const shift: u7 = @intCast(index * bits);
            const sign = @as(u128, 1) << @as(u7, @intCast(index * bits + bits - 1));
            for ([_]u128{ sign, ~sign, laneMask(bits) << shift, ~(laneMask(bits) << shift), @as(u128, 1) << shift }) |value| {
                var result: u128 = if (op.bitmask) 0 else 1;
                for (0..128 / bits) |i| {
                    const part = (value >> @as(u7, @intCast(i * bits))) & laneMask(bits);
                    if (op.bitmask) {
                        if (part >> @as(u7, @intCast(bits - 1)) != 0) result |= @as(u128, 1) << @as(u7, @intCast(i));
                    } else if (part == 0) result = 0;
                }
                try check(sub, &.{value}, .i32, result, false);
            }
        }
    }
    for (integers) |value| try check(83, &.{value}, .i32, @intFromBool(value != 0), false);
    for (0..128) |bit| try check(83, &.{@as(u128, 1) << @as(u7, @intCast(bit))}, .i32, 1, false);
}

test "backend SIMD predicates: scalar reductions feed structured branches" {
    for ([_]u32{ 83, 99, 131, 163, 195 }) |sub| {
        try check(sub, &.{0}, .i32, 9, true);
        try check(sub, &.{std.math.maxInt(u128)}, .i32, 7, true);
    }
}
