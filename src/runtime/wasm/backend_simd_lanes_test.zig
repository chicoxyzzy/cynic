const std = @import("std");
const wasm = @import("wasm.zig");
const backend = wasm.backend_prototype;
const simd = @import("spasm_simd.zig");
const a = std.testing.allocator;
const vector: u128 = 0xffeeddccbbaa9988_7766554433221180;

fn check(body: []const u8, params: []const wasm.ValType, results: []const wasm.ValType, args: []const u128, expected: []const u128) !void {
    if (!backend.native.supported) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const module: wasm.Module = .{ .types = &.{.{ .params = params, .results = results }}, .funcs = &.{0}, .code = &.{.{ .bytes = body }} };
    var instance: wasm.Instance = undefined;
    try wasm.instantiate(&instance, arena.allocator(), a, &module, .{});
    defer instance.deinit();
    const interpreted = try wasm.invoke(&instance, a, 0, args);
    defer a.free(interpreted);
    try std.testing.expectEqualSlices(u128, expected, interpreted);
    var graph = try backend.lowerInstance(a, &instance, 0);
    defer graph.deinit();
    instance.shared_backend_enabled = true;
    const actual = try wasm.invoke(&instance, a, 0, args);
    defer a.free(actual);
    try std.testing.expectEqualSlices(u128, expected, actual);
    try std.testing.expectEqual(@as(u64, 1), instance.shared_backend_stats.entries);
    try std.testing.expectEqual(@as(u64, 0), instance.shared_backend_stats.refusals);
}

test "backend SIMD lanes: splats preserve integer and floating bit patterns" {
    for (15..21) |sub| {
        const width: usize = simd.splatWidth(@intCast(sub)).?;
        const ty: wasm.ValType = switch (sub) {
            18 => .i64,
            19 => .f32,
            20 => .f64,
            else => .i32,
        };
        for ([_]u64{ 0, 0xffffffffffffffff, 0x8000000080000000, 0x7ff000007f800042 }) |value| {
            const input = if (width < 8) value & 0xffff_ffff else value;
            const mask = (@as(u128, 1) << @as(u7, @intCast(width * 8))) - 1;
            var expected: u128 = 0;
            for (0..16 / width) |lane| expected |= (@as(u128, input) & mask) << @as(u7, @intCast(lane * width * 8));
            try check(&.{ 0, 0x20, 0, 0xfd, @intCast(sub), 0x0b }, &.{ty}, &.{.v128}, &.{input}, &.{expected});
        }
    }
}

test "backend SIMD lanes: extract and replace every lane with exact float bits" {
    for (21..35) |sub| {
        const op = simd.laneOp(@intCast(sub)).?;
        const width: usize = op.width;
        const ty: wasm.ValType = switch (sub) {
            29, 30 => .i64,
            31, 32 => .f32,
            33, 34 => .f64,
            else => .i32,
        };
        const mask = (@as(u128, 1) << @as(u7, @intCast(width * 8))) - 1;
        for (0..16 / width) |lane| {
            const shift: u7 = @intCast(lane * width * 8);
            if (op.replace) {
                const scalar: u128 = if (op.width == 8) 0xfff0000000000042 else 0xff800042;
                const expected = (vector & ~(mask << shift)) | ((scalar & mask) << shift);
                try check(&.{ 0, 0x20, 0, 0x20, 1, 0xfd, @intCast(sub), @intCast(lane), 0x0b }, &.{ .v128, ty }, &.{.v128}, &.{ vector, scalar }, &.{expected});
            } else {
                var expected = (vector >> shift) & mask;
                if (op.signed and expected & ((mask + 1) >> 1) != 0) expected |= 0xffff_ffff ^ mask;
                try check(&.{ 0, 0x20, 0, 0xfd, @intCast(sub), @intCast(lane), 0x0b }, &.{.v128}, &.{ty}, &.{vector}, &.{expected});
            }
        }
    }
}

test "backend SIMD lanes: shuffle selectors and every swizzle index" {
    const other: u128 = ~vector;
    for (0..32) |start| {
        var body: [24]u8 = undefined;
        @memcpy(body[0..7], &[_]u8{ 0, 0x20, 0, 0x20, 1, 0xfd, 13 });
        var expected: u128 = 0;
        for (0..16) |lane| {
            const selector: u8 = @intCast((start + 7 * lane) % 32);
            body[7 + lane] = selector;
            const source = if (selector < 16) vector else other;
            const value = (source >> @as(u7, @intCast((selector % 16) * 8))) & 255;
            expected |= value << @as(u7, @intCast(lane * 8));
        }
        body[23] = 0x0b;
        try check(&body, &.{ .v128, .v128 }, &.{.v128}, &.{ vector, other }, &.{expected});
    }
    for (0..16) |group| {
        var indices: u128 = 0;
        var expected: u128 = 0;
        for (0..16) |lane| {
            const index = group * 16 + lane;
            indices |= @as(u128, index) << @as(u7, @intCast(lane * 8));
            if (index < 16) expected |= ((vector >> @as(u7, @intCast(index * 8))) & 255) << @as(u7, @intCast(lane * 8));
        }
        try check(&.{ 0, 0x20, 0, 0x20, 1, 0xfd, 14, 0x0b }, &.{ .v128, .v128 }, &.{.v128}, &.{ vector, indices }, &.{expected});
        try check(&.{ 0, 0x20, 0, 0x20, 1, 0xfd, 0x80, 2, 0x0b }, &.{ .v128, .v128 }, &.{.v128}, &.{ vector, indices }, &.{expected});
    }
}

test "backend SIMD lanes: memory forms touch only the selected bytes and trap before stores" {
    if (!backend.native.supported) return error.SkipZigTest;
    for ([_]u8{ 7, 8, 9, 10, 92, 93, 84, 85, 86, 87, 88, 89, 90, 91 }) |sub| for ([_]bool{ false, true }) |memory64| {
        const lane_memory = sub >= 84 and sub <= 91;
        const store = sub >= 88 and sub <= 91;
        const scalar = simd.scalarLoadOp(sub);
        const width: usize = if (scalar) |load| load.width else @as(usize, 1) << @as(u2, @intCast((sub - 84) % 4));
        for (0..if (lane_memory) 16 / width else 1) |lane| {
            var arena = std.heap.ArenaAllocator.init(a);
            defer arena.deinit();
            var body: std.ArrayList(u8) = .empty;
            defer body.deinit(a);
            try body.appendSlice(a, &.{ 0, 0x20, 0 });
            if (lane_memory) try body.appendSlice(a, &.{ 0x20, 1 });
            // Select memory 1, unaligned, with a static offset of three bytes.
            try body.appendSlice(a, &.{ 0xfd, sub, 0x40, 1, 3 });
            if (lane_memory) try body.append(a, @intCast(lane));
            try body.append(a, 0x0b);
            const address_ty: wasm.ValType = if (memory64) .i64 else .i32;
            const params: []const wasm.ValType = if (lane_memory) &.{ address_ty, .v128 } else &.{address_ty};
            const module: wasm.Module = .{
                .types = &.{.{ .params = params, .results = if (store) &.{} else &.{.v128} }},
                .funcs = &.{0},
                .code = &.{.{ .bytes = body.items }},
                .mems = &.{ .{ .limits = .{ .min = 1 } }, .{ .limits = .{ .min = 1, .is_64 = memory64 } } },
            };
            var instance: wasm.Instance = undefined;
            try wasm.instantiate(&instance, arena.allocator(), a, &module, .{});
            defer instance.deinit();
            var graph = try backend.lowerInstance(a, &instance, 0);
            defer graph.deinit();
            instance.shared_backend_enabled = true;
            const bytes = instance.memories[1].data;
            @memset(bytes, 0xa5);
            const args = [_]u128{ bytes.len - width - 3, vector };
            const actual = try wasm.invoke(&instance, a, 0, args[0..params.len]);
            defer a.free(actual);
            const shift: u7 = @intCast(lane * width * 8);
            const mask = (@as(u128, 1) << @as(u7, @intCast(width * 8))) - 1;
            const loaded = @as(u128, 0xa5a5a5a5a5a5a5a5) & mask;
            if (store) {
                for (bytes[0 .. bytes.len - width]) |byte| try std.testing.expectEqual(@as(u8, 0xa5), byte);
                for (bytes[bytes.len - width ..], 0..) |byte, i| try std.testing.expectEqual(@as(u8, @truncate(vector >> @as(u7, @intCast((lane * width + i) * 8)))), byte);
            } else {
                var expected: u128 = loaded;
                if (lane_memory) expected = (vector & ~(mask << shift)) | (loaded << shift) else if (scalar.?.splat) {
                    expected = 0;
                    for (0..16 / width) |i| expected |= loaded << @as(u7, @intCast(i * width * 8));
                }
                try std.testing.expectEqualSlices(u128, &.{expected}, actual);
            }
            try std.testing.expectEqual(@as(u64, 1), instance.shared_backend_stats.entries);
            for ([_]u128{ bytes.len - width - 2, if (memory64) std.math.maxInt(u64) else std.math.maxInt(u32) }) |address| {
                @memset(bytes, 0x5a);
                const bad_args = [_]u128{ address, vector };
                try std.testing.expectError(error.OutOfBoundsMemoryAccess, wasm.invoke(&instance, a, 0, bad_args[0..params.len]));
                try std.testing.expect(std.mem.allEqual(u8, bytes, 0x5a));
            }
            try std.testing.expect(std.mem.allEqual(u8, instance.memories[0].data, 0));
            try std.testing.expectEqual(@as(u64, 0), instance.shared_backend_stats.refusals);
        }
    };
}
