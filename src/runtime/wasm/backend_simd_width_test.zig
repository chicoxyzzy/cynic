const std = @import("std");
const wasm = @import("wasm.zig");
const backend = wasm.backend_prototype;
const simd = @import("spasm_simd.zig");
const a = std.testing.allocator;

const inputs = [_]u128{
    0,                                   0xffffffffffffffff_ffffffffffffffff,
    0x8080808080808080_7f7f7f7f7f7f7f7f, 0x800000007fffffff_ffff000000010000,
    0x80007fff00010000_ffff010000ff0080, 0x0000800000007fff_000100000000ffff,
    0x0123456789abcdef_fedcba9876543210,
};

fn mask(bits: usize) u128 {
    return (@as(u128, 1) << @as(u7, @intCast(bits))) - 1;
}

fn lane(value: u128, index: usize, bits: usize, signed: bool) i64 {
    const raw = (value >> @as(u7, @intCast(index * bits))) & mask(bits);
    var result: i64 = @intCast(raw);
    if (signed and raw & (@as(u128, 1) << @as(u7, @intCast(bits - 1))) != 0) result -= @as(i64, 1) << @as(u6, @intCast(bits));
    return result;
}

fn extend(value: u128, width: usize, signed: bool, high: bool) u128 {
    const count = 8 / width;
    var result: u128 = 0;
    for (0..count) |i| {
        const scalar: u64 = @bitCast(lane(value, i + (if (high) count else 0), width * 8, signed));
        result |= (@as(u128, scalar) & mask(width * 16)) << @as(u7, @intCast(i * width * 16));
    }
    return result;
}

fn narrow(lhs: u128, rhs: u128, width: usize, signed: bool) u128 {
    const bits = width * 8;
    const minimum: i64 = if (signed) -(@as(i64, 1) << @as(u6, @intCast(bits - 1))) else 0;
    const maximum: i64 = @intCast(mask(bits - @intFromBool(signed)));
    var result: u128 = 0;
    for ([_]u128{ lhs, rhs }, 0..) |input, half| for (0..8 / width) |i| {
        const scalar = std.math.clamp(lane(input, i, bits * 2, true), minimum, maximum);
        const raw: u64 = @bitCast(scalar);
        result |= (@as(u128, raw) & mask(bits)) << @as(u7, @intCast(half * 64 + i * bits));
    };
    return result;
}

fn pairwise(value: u128, width: usize, signed: bool) u128 {
    var result: u128 = 0;
    for (0..8 / width) |i| {
        const sum = lane(value, 2 * i, width * 8, signed) + lane(value, 2 * i + 1, width * 8, signed);
        const raw: u64 = @bitCast(sum);
        result |= (@as(u128, raw) & mask(width * 16)) << @as(u7, @intCast(i * width * 16));
    }
    return result;
}

fn expectInvoke(instance: *wasm.Instance, tier: usize, args: []const u128, expected: u128) !void {
    const shared_entries = instance.shared_backend_stats.entries;
    const spasm_entries = instance.spasm_runs;
    const result = try wasm.invoke(instance, a, 0, args);
    defer a.free(result);
    try std.testing.expectEqualSlices(u128, &.{expected}, result);
    if (tier == 1) try std.testing.expectEqual(spasm_entries + 1, instance.spasm_runs);
    if (tier == 2) {
        try std.testing.expectEqual(shared_entries + 1, instance.shared_backend_stats.entries);
        try std.testing.expectEqual(@as(u64, 0), instance.shared_backend_stats.refusals);
    }
}

fn check(sub: u32, args: []const u128, expected: u128) !void {
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
    const params: [2]wasm.ValType = @splat(.v128);
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
        try expectInvoke(&instance, tier, args, expected);
    }
}

test "backend SIMD widths: signed unsigned low and high extension agree across tiers" {
    for ([_]u32{ 135, 136, 137, 138, 167, 168, 169, 170, 199, 200, 201, 202 }) |sub| {
        const op = simd.extendOp(sub).?;
        for (inputs) |value| try check(sub, &.{value}, extend(value, op.width, op.signed, op.high));
    }
}

test "backend SIMD widths: narrowing saturates signed inputs at both destination bounds" {
    for ([_]u32{ 101, 102, 133, 134 }) |sub| {
        const op = simd.narrowOp(sub).?;
        for (inputs) |lhs| for (inputs) |rhs| try check(sub, &.{ lhs, rhs }, narrow(lhs, rhs, op.width, op.signed));
    }
}

test "backend SIMD widths: pairwise sums extend before addition" {
    for (124..128) |sub| {
        const op = simd.pairwiseAddOp(@intCast(sub)).?;
        for (inputs) |value| try check(@intCast(sub), &.{value}, pairwise(value, op.width, op.signed));
    }
}

test "backend SIMD widths: widening loads check eight bytes and preserve trap ordering" {
    if (!backend.native.supported) return error.SkipZigTest;
    for (1..7) |sub| for ([_]bool{ false, true }) |memory64| {
        const op = simd.wideningLoadOp(@intCast(sub)).?;
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        const module: wasm.Module = .{
            .types = &.{.{ .params = &.{if (memory64) .i64 else .i32}, .results = &.{.v128} }},
            .imports = &.{.{ .module = "h", .name = "counter", .desc = .{ .global = .{ .val = .i32, .mut = .mutable } } }},
            .mems = &.{ .{ .limits = .{ .min = 1 } }, .{ .limits = .{ .min = 1, .is_64 = memory64 } } },
            .funcs = &.{0},
            .code = &.{.{ .bytes = &.{ 0, 0x20, 0, 0xfd, @intCast(sub), 0x40, 1, 3, 0x41, 1, 0x24, 0, 0x0b } }},
        };
        var counter: wasm.Global = .{ .value = 0, .mutable = true };
        var instance: wasm.Instance = undefined;
        try wasm.instantiate(&instance, arena.allocator(), a, &module, .{ .globals = &.{&counter} });
        defer instance.deinit();
        const bytes = instance.memories[1].data;
        for (0..3) |tier| {
            instance.spasm_enabled = tier == 1;
            instance.shared_backend_enabled = tier == 2;
            if (tier == 2) {
                var graph = try backend.lowerInstance(a, &instance, 0);
                defer graph.deinit();
                var loads: usize = 0;
                for (graph.graph.blocks) |block| for (block.nodes) |node| {
                    if (node.op == .load and node.memory.?.region == 1) {
                        try std.testing.expectEqual(backend.ir.MemoryWidth.double, node.memory.?.width);
                        try std.testing.expectEqual(@as(?u32, 2), node.trap_site);
                        loads += 1;
                    }
                };
                try std.testing.expectEqual(@as(usize, 1), loads);
            }
            for (inputs) |value| {
                std.mem.writeInt(u64, bytes[bytes.len - 8 ..][0..8], @truncate(value), .little);
                counter.value = 0;
                try expectInvoke(&instance, tier, &.{bytes.len - 11}, extend(@as(u64, @truncate(value)), op.width, op.signed, false));
                try std.testing.expectEqual(@as(u128, 1), counter.value);
            }
            for ([_]u128{ bytes.len - 10, if (memory64) std.math.maxInt(u64) else std.math.maxInt(u32) }) |address| {
                counter.value = 0;
                const shared_entries = instance.shared_backend_stats.entries;
                const spasm_entries = instance.spasm_runs;
                try std.testing.expectError(error.OutOfBoundsMemoryAccess, wasm.invoke(&instance, a, 0, &.{address}));
                try std.testing.expectEqual(@as(u128, 0), counter.value);
                if (tier == 1) try std.testing.expectEqual(spasm_entries + 1, instance.spasm_runs);
                if (tier == 2) try std.testing.expectEqual(shared_entries + 1, instance.shared_backend_stats.entries);
            }
        }
        try std.testing.expect(std.mem.allEqual(u8, instance.memories[0].data, 0));
    };
}
