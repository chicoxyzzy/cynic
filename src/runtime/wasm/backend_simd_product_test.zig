const std = @import("std");
const check = @import("backend_simd_integer_test.zig").check;

const values = [_]u128{
    0,                                   1,                                   std.math.maxInt(u128),
    0x8080808080808080_8080808080808080, 0x8000800080008000_8000800080008000, 0x8000000080000000_8000000080000000,
    0x7f017f027f037f04_8040804080408040, 0x80017fff0001ffff_4000c0004001bfff, 0x0123456789abcdef_fedcba9876543210,
};

fn lane(value: u128, bits: usize, index: usize, signed: bool) i128 {
    const width: u7 = @intCast(bits);
    const raw = (value >> @as(u7, @intCast(index * bits))) & ((@as(u128, 1) << width) - 1);
    return @as(i128, @intCast(raw)) - (if (signed and raw >> (width - 1) != 0) @as(i128, 1) << width else 0);
}

fn append(result: *u128, value: i128, bits: usize, index: usize) void {
    const mask = (@as(u128, 1) << @as(u7, @intCast(bits))) - 1;
    result.* |= (@as(u128, @bitCast(value)) & mask) << @as(u7, @intCast(index * bits));
}

test "backend SIMD products: extended products preserve signedness and selected halves" {
    for ([_]u32{ 156, 188, 220 }, 0..) |base, size| {
        const bits: usize = @as(usize, 8) << @as(u2, @intCast(size));
        const count = 64 / bits;
        for (0..4) |form| for (values) |lhs| for (values) |rhs| {
            var expected: u128 = 0;
            const start = (form % 2) * count;
            for (0..count) |i| append(&expected, lane(lhs, bits, start + i, form < 2) * lane(rhs, bits, start + i, form < 2), bits * 2, i);
            try check(base + @as(u32, @intCast(form)), &.{ lhs, rhs }, false, expected);
        };
    }
}

test "backend SIMD products: strict dot and Q15 use their distinct overflow rules" {
    for (values) |lhs| for (values) |rhs| {
        var dot: u128 = 0;
        var q15: u128 = 0;
        for (0..4) |i| append(&dot, lane(lhs, 16, i * 2, true) * lane(rhs, 16, i * 2, true) + lane(lhs, 16, i * 2 + 1, true) * lane(rhs, 16, i * 2 + 1, true), 32, i);
        for (0..8) |i| {
            const product = lane(lhs, 16, i, true) * lane(rhs, 16, i, true);
            append(&q15, std.math.clamp((product + 0x4000) >> 15, -32768, 32767), 16, i);
        }
        try check(186, &.{ lhs, rhs }, false, dot);
        try check(130, &.{ lhs, rhs }, false, q15);
        try check(273, &.{ lhs, rhs }, false, q15);
    };
}

test "backend SIMD products: relaxed dots saturate before widening and wrapping accumulation" {
    for (values) |lhs| for (values) |rhs| {
        var pairs: [8]i128 = undefined;
        var dot: u128 = 0;
        for (0..8) |i| {
            const sum = lane(lhs, 8, i * 2, true) * lane(rhs, 8, i * 2, true) + lane(lhs, 8, i * 2 + 1, true) * lane(rhs, 8, i * 2 + 1, true);
            pairs[i] = std.math.clamp(sum, -32768, 32767);
            append(&dot, pairs[i], 16, i);
        }
        try check(274, &.{ lhs, rhs }, false, dot);
        for (values) |accumulator| {
            var expected: u128 = 0;
            for (0..4) |i| append(&expected, pairs[i * 2] + pairs[i * 2 + 1] + lane(accumulator, 32, i, true), 32, i);
            try check(275, &.{ lhs, rhs, accumulator }, false, expected);
        }
    };
}
