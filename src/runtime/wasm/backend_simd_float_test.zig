const std = @import("std");
const helpers = @import("backend_simd_integer_test.zig");

const Binary = enum { sub, mul, div, min, max, pmin, pmax };
const Unary = enum { abs, neg, sqrt, ceil, floor, trunc, nearest };

fn inputs(comptime F: type) [20](if (F == f32) u32 else u64) {
    const U = if (F == f32) u32 else u64;
    const sign = @as(U, 1) << (@bitSizeOf(F) - 1);
    const inf: U = @bitCast(std.math.inf(F));
    const nan: U = @bitCast(std.math.nan(F));
    return .{ 0, sign, 1, sign | 1, inf, sign | inf, nan, inf | 42, @bitCast(@as(F, 1.5)), @bitCast(@as(F, -1.5)), @bitCast(@as(F, 2.5)), @bitCast(@as(F, -0.5)), @bitCast(@as(F, 2147483648.0)), @bitCast(@as(F, -2147483648.0)), @bitCast(@as(F, 4294967296.0)), @bitCast(@as(F, 1.0000001192092896)), @bitCast(@as(F, 3.25)), @bitCast(@as(F, -4.75)), inf - 1, sign | (inf - 1) };
}

fn pack(comptime F: type, start: usize) u128 {
    const values = inputs(F);
    var lanes: [16 / @sizeOf(F)](if (F == f32) u32 else u64) = undefined;
    for (&lanes, 0..) |*lane, i| lane.* = values[(start + i) % values.len];
    return @bitCast(lanes);
}

fn binary(comptime F: type, kind: Binary, x: F, y: F) F {
    @setFloatMode(.strict);
    return switch (kind) {
        .sub => x - y,
        .mul => x * y,
        .div => x / y,
        .pmin => if (y < x) y else x,
        .pmax => if (x < y) y else x,
        .min, .max => blk: {
            if (std.math.isNan(x) or std.math.isNan(y)) break :blk std.math.nan(F);
            if (x == 0 and y == 0) {
                const negative = if (kind == .min) std.math.signbit(x) or std.math.signbit(y) else std.math.signbit(x) and std.math.signbit(y);
                break :blk if (negative) -@as(F, 0) else 0;
            }
            break :blk if (kind == .min) @min(x, y) else @max(x, y);
        },
    };
}

fn unary(comptime F: type, kind: Unary, value: F) F {
    @setFloatMode(.strict);
    const U = if (F == f32) u32 else u64;
    const bits: U = @bitCast(value);
    const sign = @as(U, 1) << (@bitSizeOf(F) - 1);
    if (kind == .abs) return @bitCast(bits & ~sign);
    if (kind == .neg) return @bitCast(bits ^ sign);
    if (std.math.isNan(value)) return std.math.nan(F);
    return switch (kind) {
        .sqrt => @sqrt(value),
        .ceil => @ceil(value),
        .floor => @floor(value),
        .trunc => @trunc(value),
        .nearest => blk: {
            const magnitude = @abs(value);
            if (magnitude >= @as(F, @floatFromInt(@as(u64, 1) << std.math.floatMantissaBits(F)))) break :blk value;
            const integral = @floor(magnitude);
            const fraction = magnitude - integral;
            const odd = @as(u64, @intFromFloat(integral)) & 1 != 0;
            const rounded = integral + @as(F, if (fraction > 0.5 or (fraction == 0.5 and odd)) 1 else 0);
            break :blk if (std.math.signbit(value)) -rounded else rounded;
        },
        else => unreachable,
    };
}

test "backend SIMD float: arithmetic strict relaxed and pseudo minmax preserve lane semantics" {
    inline for (.{ f32, f64 }) |F| {
        const base: u32 = if (F == f32) 224 else 236;
        for ([_]Binary{ .sub, .mul, .div, .min, .max, .pmin, .pmax }, 0..) |kind, index| {
            const sub = base + 5 + @as(u32, @intCast(index));
            for (0..10) |l| for (0..10) |r| {
                const left = pack(F, l * 2);
                const right = pack(F, r * 2);
                const xs: [16 / @sizeOf(F)]F = @bitCast(left);
                const ys: [16 / @sizeOf(F)]F = @bitCast(right);
                var expected: [16 / @sizeOf(F)]F = undefined;
                for (&expected, xs, ys) |*out, x, y| out.* = binary(F, kind, x, y);
                if (kind == .pmin or kind == .pmax) {
                    try helpers.check(sub, &.{ left, right }, false, @bitCast(expected));
                } else {
                    try helpers.checkFloat(sub, &.{ left, right }, @bitCast(expected), @sizeOf(F));
                    if (kind == .min or kind == .max) try helpers.checkFloat((if (F == f32) @as(u32, 269) else 271) + @as(u32, @intFromBool(kind == .max)), &.{ left, right }, @bitCast(expected), @sizeOf(F));
                }
            };
        }
    }
}

test "backend SIMD float: sign operations rounding and square roots" {
    inline for (.{ f32, f64 }) |F| {
        const opcodes = if (F == f32) [_]u32{ 224, 225, 227, 103, 104, 105, 106 } else [_]u32{ 236, 237, 239, 116, 117, 122, 148 };
        for ([_]Unary{ .abs, .neg, .sqrt, .ceil, .floor, .trunc, .nearest }, opcodes) |kind, sub| for (0..10) |start| {
            const input = pack(F, start * 2);
            const lanes: [16 / @sizeOf(F)]F = @bitCast(input);
            var expected: [16 / @sizeOf(F)]F = undefined;
            for (&expected, lanes) |*out, value| out.* = unary(F, kind, value);
            if (kind == .abs or kind == .neg) try helpers.check(sub, &.{input}, false, @bitCast(expected)) else try helpers.checkFloat(sub, &.{input}, @bitCast(expected), @sizeOf(F));
        };
    }
}

fn truncSat(comptime F: type, value: F, signed: bool) u32 {
    if (std.math.isNan(value)) return 0;
    if (signed) {
        if (value <= -2147483648.0) return 0x80000000;
        if (value >= 2147483648.0) return 0x7fffffff;
        return @bitCast(@as(i32, @intFromFloat(value)));
    }
    if (value <= 0) return 0;
    if (value >= 4294967296.0) return 0xffffffff;
    return @intFromFloat(value);
}

test "backend SIMD float: conversions saturate and clear unused upper lanes" {
    inline for (.{ f32, f64 }) |F| for (0..10) |start| {
        const input = pack(F, start * 2);
        const lanes: [16 / @sizeOf(F)]F = @bitCast(input);
        for ([_]bool{ true, false }) |signed| {
            var result: [4]u32 = @splat(0);
            for (lanes, 0..) |value, i| result[i] = truncSat(F, value, signed);
            const sub: u32 = (if (F == f32) @as(u32, 248) else 252) + @as(u32, @intFromBool(!signed));
            try helpers.check(sub, &.{input}, false, @bitCast(result));
            try helpers.check((if (F == f32) @as(u32, 257) else 259) + @as(u32, @intFromBool(!signed)), &.{input}, false, @bitCast(result));
        }
        if (F == f32) {
            const result = [_]f64{ @floatCast(lanes[0]), @floatCast(lanes[1]) };
            try helpers.checkFloat(95, &.{input}, @bitCast(result), 8);
        } else {
            const result = [_]f32{ @floatCast(lanes[0]), @floatCast(lanes[1]), 0, 0 };
            try helpers.checkFloat(94, &.{input}, @bitCast(result), 4);
        }
    };
    for ([_]u128{ 0, std.math.maxInt(u128), 0x800000007fffffff_800000017ffffffe, 0x0100000101000003_ffffffff00000001 }) |input| {
        const lanes: [4]u32 = @bitCast(input);
        inline for (.{ f32, f64 }) |F| for ([_]bool{ true, false }) |signed| {
            var result: [16 / @sizeOf(F)]F = undefined;
            for (&result, 0..) |*value, i| value.* = if (signed) @floatFromInt(@as(i32, @bitCast(lanes[i]))) else @floatFromInt(lanes[i]);
            try helpers.checkFloat((if (F == f32) @as(u32, 250) else 254) + @as(u32, @intFromBool(!signed)), &.{input}, @bitCast(result), @sizeOf(F));
        };
    }
}

test "backend SIMD float: relaxed multiply add keeps the two rounding profile" {
    @setFloatMode(.strict);
    inline for (.{ f32, f64 }) |F| for ([_]bool{ false, true }) |negative| for (0..10) |start| {
        const left = pack(F, start * 2);
        const right = pack(F, (start * 2 + 3) % 20);
        const acc = pack(F, (start * 2 + 7) % 20);
        const xs: [16 / @sizeOf(F)]F = @bitCast(left);
        const ys: [16 / @sizeOf(F)]F = @bitCast(right);
        const zs: [16 / @sizeOf(F)]F = @bitCast(acc);
        var result: [16 / @sizeOf(F)]F = undefined;
        for (&result, xs, ys, zs) |*value, x, y, z| {
            const product: F = (if (negative) -x else x) * y;
            value.* = product + z;
        }
        try helpers.checkFloat((if (F == f32) @as(u32, 261) else 263) + @as(u32, @intFromBool(negative)), &.{ left, right, acc }, @bitCast(result), @sizeOf(F));
    };
}

test "backend SIMD float: multiply add does not fuse away its intermediate rounding" {
    inline for (.{ f32, f64 }) |F| for ([_]bool{ false, true }) |negative| {
        const epsilon: F = if (F == f32) 0x1p-23 else 0x1p-52;
        const left: [16 / @sizeOf(F)]F = @splat(1 + epsilon);
        const right: [16 / @sizeOf(F)]F = @splat(1 - epsilon);
        const acc: [16 / @sizeOf(F)]F = @splat(if (negative) 1 else -1);
        // A fused operation returns +/- epsilon^2, not zero.
        try helpers.check((if (F == f32) @as(u32, 261) else 263) + @as(u32, @intFromBool(negative)), &.{ @bitCast(left), @bitCast(right), @bitCast(acc) }, false, 0);
    };
}
