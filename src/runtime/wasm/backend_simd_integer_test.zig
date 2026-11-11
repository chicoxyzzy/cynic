const std = @import("std");
const wasm = @import("wasm.zig");
const backend = wasm.backend_prototype;
const a = std.testing.allocator;

const values = [_]u128{
    0,                                   1,                                   std.math.maxInt(u128),
    0x808080807f7f7f7f_800080007fff7fff, 0x800000007fffffff_7fffffff80000000, 0x8000000000000000_7fffffffffffffff,
    0x0123456789abcdef_fedcba9876543210,
};

fn signed(value: u128, bits: usize) i128 {
    const sign = @as(u128, 1) << @as(u7, @intCast(bits - 1));
    return @as(i128, @intCast(value)) - (if (value & sign != 0) @as(i128, 1) << @as(u7, @intCast(bits)) else 0);
}

pub fn check(sub: u32, args: []const u128, shift: bool, expected: u128) !void {
    return checkResult(sub, args, shift, expected, null);
}

pub fn checkFloat(sub: u32, args: []const u128, expected: u128, width: u4) !void {
    try std.testing.expect(width == 4 or width == 8);
    return checkResult(sub, args, false, expected, width);
}

fn checkResult(sub: u32, args: []const u128, shift: bool, expected: u128, float_width: ?u4) !void {
    if (!backend.native.supported) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(a);
    try body.append(a, 0);
    for (0..args.len) |i| try body.appendSlice(a, &.{ 0x20, @intCast(i) });
    try body.append(a, 0xfd);
    if (sub < 128) try body.append(a, @intCast(sub)) else try body.appendSlice(a, &.{ @as(u8, @intCast(sub & 127)) | 128, @intCast(sub >> 7) });
    try body.append(a, 0x0b);
    var params: [3]wasm.ValType = @splat(.v128);
    if (shift) params[1] = .i32;
    const module: wasm.Module = .{ .types = &.{.{ .params = params[0..args.len], .results = &.{.v128} }}, .funcs = &.{0}, .code = &.{.{ .bytes = body.items }} };
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
        try std.testing.expectEqual(@as(usize, 1), result.len);
        if (float_width) |width| {
            inline for (.{ .{ u32, f32, 4 }, .{ u64, f64, 2 } }) |case| {
                if (width == @sizeOf(case[0])) {
                    const wanted: [case[2]]case[0] = @bitCast(expected);
                    const actual: [case[2]]case[0] = @bitCast(result[0]);
                    for (wanted, actual, 0..) |want, got, lane| {
                        if (std.math.isNan(@as(case[1], @bitCast(want)))) {
                            const quiet = @as(case[0], 1) << (std.math.floatMantissaBits(case[1]) - 1);
                            try std.testing.expect(std.math.isNan(@as(case[1], @bitCast(got))) and got & quiet != 0);
                            // With only canonical-NaN or numeric inputs, Core
                            // requires a canonical result, not an arbitrary payload.
                            const source_width: u4 = if (sub == 94) 8 else if (sub == 95) 4 else width;
                            const exponent: u64 = if (source_width == 8) 0x7ff0000000000000 else 0x7f800000;
                            const payload: u64 = if (source_width == 8) 0x000fffffffffffff else 0x007fffff;
                            const source_quiet: u64 = (payload + 1) >> 1;
                            var canonical = true;
                            for (args) |arg| {
                                const source: u64 = @truncate(arg >> @as(u7, @intCast(lane * @as(usize, source_width) * 8)));
                                if (source & exponent == exponent and source & payload != 0 and source & payload != source_quiet) canonical = false;
                            }
                            if (canonical) try std.testing.expectEqual(quiet, got & (quiet * 2 - 1));
                        } else try std.testing.expectEqual(want, got);
                    }
                }
            }
        } else try std.testing.expectEqualSlices(u128, &.{expected}, result);
        if (tier == 1) try std.testing.expectEqual(entries + 1, instance.spasm_runs);
        if (tier == 2) {
            try std.testing.expectEqual(entries + 1, instance.shared_backend_stats.entries);
            try std.testing.expectEqual(@as(u64, 0), instance.shared_backend_stats.refusals);
        }
    }
}

test "backend SIMD integers: wrapping and saturating arithmetic across tiers" {
    for (0..4) |size| {
        const bits: usize = @as(usize, 8) << @as(u2, @intCast(size));
        const mask = (@as(u128, 1) << @as(u7, @intCast(bits))) - 1;
        const base: u32 = @intCast(110 + 32 * size);
        for ([_]u32{ base, base + 3, if (size == 0) base else base + 7, base + 1, base + 2, base + 4, base + 5 }, 0..) |sub, kind| {
            if (size > 1 and kind >= 3) continue;
            if (size == 0 and kind == 2) continue;
            for (values) |lhs| for (values) |rhs| {
                var expected: u128 = 0;
                for (0..128 / bits) |i| {
                    const offset: u7 = @intCast(i * bits);
                    const l = (lhs >> offset) & mask;
                    const r = (rhs >> offset) & mask;
                    const part = switch (kind) {
                        0 => (l +% r) & mask,
                        1 => (l -% r) & mask,
                        2 => (l *% r) & mask,
                        else => blk: {
                            const is_signed = kind == 3 or kind == 5;
                            const x = if (is_signed) signed(l, bits) else @as(i128, @intCast(l));
                            const y = if (is_signed) signed(r, bits) else @as(i128, @intCast(r));
                            const bound = @as(i128, 1) << @as(u7, @intCast(bits - 1));
                            const minimum: i128 = if (is_signed) -bound else 0;
                            const maximum: i128 = if (is_signed) bound - 1 else @intCast(mask);
                            break :blk @as(u128, @bitCast(std.math.clamp(if (kind < 5) x + y else x - y, minimum, maximum))) & mask;
                        },
                    };
                    expected |= part << offset;
                }
                try check(sub, &.{ lhs, rhs }, false, expected);
            };
        }
    }
}

test "backend SIMD integers: shifts mask all i32 counts at every lane width" {
    for (0..4) |size| {
        const bits: usize = @as(usize, 8) << @as(u2, @intCast(size));
        const mask = (@as(u128, 1) << @as(u7, @intCast(bits))) - 1;
        for (0..3) |kind| for ([_]u32{ 0, 1, @intCast(bits - 1), @intCast(bits), @intCast(bits + 1), 127, 128, 255, 0x80000001, 0xffffffff }) |count| for (values) |input| {
            var expected: u128 = 0;
            const amount: u7 = @intCast(count % bits);
            for (0..128 / bits) |i| {
                const offset: u7 = @intCast(i * bits);
                const lane = (input >> offset) & mask;
                const part = switch (kind) {
                    0 => lane << amount,
                    1 => @as(u128, @bitCast(signed(lane, bits) >> amount)),
                    else => lane >> amount,
                };
                expected |= (part & mask) << offset;
            }
            try check(@intCast(107 + 32 * size + kind), &.{ input, count }, true, expected);
        };
    }
}

test "backend SIMD integers: abs neg popcount min max and rounded average" {
    for (0..4) |size| {
        const bits: usize = @as(usize, 8) << @as(u2, @intCast(size));
        const mask = (@as(u128, 1) << @as(u7, @intCast(bits))) - 1;
        for (values) |lhs| {
            for (0..2) |negate| {
                var expected: u128 = 0;
                for (0..128 / bits) |i| {
                    const offset: u7 = @intCast(i * bits);
                    const x = signed((lhs >> offset) & mask, bits);
                    expected |= (@as(u128, @bitCast(if (negate != 0 or x < 0) -x else x)) & mask) << offset;
                }
                try check(@intCast(96 + 32 * size + negate), &.{lhs}, false, expected);
            }
            if (size == 0) {
                var expected: u128 = 0;
                for (0..16) |i| expected |= @as(u128, @popCount(@as(u8, @truncate(lhs >> @as(u7, @intCast(i * 8)))))) << @as(u7, @intCast(i * 8));
                try check(98, &.{lhs}, false, expected);
            }
            if (size == 3) continue;
            for (values) |rhs| for (0..5) |kind| {
                if (kind == 4 and size == 2) continue;
                var expected: u128 = 0;
                for (0..128 / bits) |i| {
                    const offset: u7 = @intCast(i * bits);
                    const l = (lhs >> offset) & mask;
                    const r = (rhs >> offset) & mask;
                    const less = if (kind % 2 == 0) signed(l, bits) < signed(r, bits) else l < r;
                    const part = if (kind == 4) (l + r + 1) / 2 else if (less != (kind >= 2)) l else r;
                    expected |= part << offset;
                }
                try check(@intCast(if (kind == 4) 123 + 32 * size else 118 + 32 * size + kind), &.{ lhs, rhs }, false, expected);
            };
        }
    }
}

test "backend SIMD integers: masks and relaxed selects retain per-bit selection" {
    for (values) |lhs| {
        try check(77, &.{lhs}, false, ~lhs);
        for (values) |rhs| {
            try check(79, &.{ lhs, rhs }, false, lhs & ~rhs);
            for (values) |mask| for ([_]u32{ 82, 265, 266, 267, 268 }) |sub| try check(sub, &.{ lhs, rhs, mask }, false, (lhs & mask) | (rhs & ~mask));
        }
    }
}
