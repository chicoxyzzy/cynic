const std = @import("std");
const diagnostics = @import("backend_diagnostics.zig");
const wasm = @import("wasm.zig");
const tier = @import("backend_tier.zig");
const a = std.testing.allocator;

test "backend diagnostics: refusal keys preserve stage error opcode and subopcode" {
    var counts: diagnostics.Refusals = .{};
    const keys = [_]diagnostics.Key{
        .{ .stage = .cache, .reason = error.OutOfMemory },
        .{ .stage = .lowering, .reason = error.OutOfMemory },
        .{ .stage = .compilation, .reason = error.OutOfMemory },
        .{ .stage = .lowering, .reason = error.UnsupportedOpcode, .opcode = 0x1f },
        .{ .stage = .lowering, .reason = error.UnsupportedOpcode, .opcode = 0xfd, .subopcode = 256 },
        .{ .stage = .lowering, .reason = error.UnsupportedOpcode, .opcode = 0xfd, .subopcode = 257 },
        .{ .stage = .lowering, .reason = error.PrototypeLimit, .opcode = 0xfd, .subopcode = 257 },
    };
    for (keys) |key| counts.record(key, 1);
    counts.record(keys[0], 2);
    for (keys, 0..) |key, i| {
        try std.testing.expectEqualDeep(key, counts.entries[i].key);
        try std.testing.expectEqual(@as(u64, if (i == 0) 3 else 1), counts.entries[i].count);
    }
    try std.testing.expectEqual(@as(u64, 0), counts.other);
}

test "backend diagnostics: bounded aggregation keeps overflow and existing keys" {
    var counts: diagnostics.Refusals = .{};
    for (0..diagnostics.Refusals.capacity + 2) |i| counts.record(.{
        .stage = .lowering,
        .reason = error.UnsupportedOpcode,
        .opcode = 0xfd,
        .subopcode = @intCast(i),
    }, 1);
    try std.testing.expectEqual(@as(u64, 2), counts.other);
    counts.record(counts.entries[0].key, 3);
    try std.testing.expectEqual(@as(u64, 4), counts.entries[0].count);
    var other: diagnostics.Refusals = .{ .other = 7 };
    other.record(counts.entries[0].key, 5);
    other.record(.{ .stage = .compilation, .reason = error.OutOfMemory }, 11);
    counts.add(&other);
    try std.testing.expectEqual(@as(u64, 9), counts.entries[0].count);
    try std.testing.expectEqual(@as(u64, 20), counts.other);
    counts.record(counts.entries[0].key, std.math.maxInt(u64));
    try std.testing.expectEqual(std.math.maxInt(u64), counts.entries[0].count);
    counts.other = std.math.maxInt(u64);
    counts.add(&other);
    try std.testing.expectEqual(std.math.maxInt(u64), counts.other);
}

test "backend diagnostics: lowering reports instruction and clears reused diagnostic" {
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const module: wasm.Module = .{
        .types = &.{.{ .params = &.{}, .results = &.{} }},
        .funcs = &.{ 0, 0 },
        .code = &.{
            .{ .bytes = &([_]u8{ 0, 0x01, 0x41, 0, 0x0e, 0x80, 0x02 } ++ @as([257]u8, @splat(0)) ++ [_]u8{0x0b}) },
            .{ .bytes = &.{ 0, 0x0b } },
        },
    };
    var instance: wasm.Instance = undefined;
    try wasm.instantiate(&instance, arena.allocator(), a, &module, .{});
    defer instance.deinit();
    var diagnostic: diagnostics.Lowering = .{};
    try std.testing.expectError(error.PrototypeLimit, wasm.backend_prototype.lowerInstanceDiagnosed(a, &instance, 0, &diagnostic));
    try std.testing.expectEqualDeep(diagnostics.Site{ .offset = 3, .opcode = 0x0e }, diagnostic.site.?);
    var graph = try wasm.backend_prototype.lowerInstanceDiagnosed(a, &instance, 1, &diagnostic);
    defer graph.deinit();
    try std.testing.expect(diagnostic.site == null);
    diagnostic.site = .{ .offset = 123, .opcode = 0xfd, .subopcode = 256 };
    try std.testing.expectError(error.FunctionIndex, wasm.backend_prototype.lowerInstanceDiagnosed(a, &instance, 2, &diagnostic));
    try std.testing.expect(diagnostic.site == null);
}

test "backend diagnostics: disabled instance collection remains empty" {
    var instance: wasm.Instance = undefined;
    instance.shared_backend_stats = .{};
    instance.shared_backend_diagnostics = false;
    tier.refuse(&instance, error.OutOfMemory, .cache, null);
    try std.testing.expectEqualDeep(tier.Stats{}, instance.shared_backend_stats);
    instance.shared_backend_diagnostics = true;
    tier.refuse(&instance, error.UnsupportedOpcode, .lowering, .{ .offset = 3, .opcode = 0x1f });
    try std.testing.expectEqual(@as(u64, 1), instance.shared_backend_stats.refusals);
    try std.testing.expectEqual(@as(anyerror, error.UnsupportedOpcode), instance.shared_backend_stats.last_refusal.?);
    const entry = instance.shared_backend_stats.refusal_details.entries[0];
    try std.testing.expectEqualDeep(diagnostics.Key{ .stage = .lowering, .reason = error.UnsupportedOpcode, .opcode = 0x1f }, entry.key);
    try std.testing.expectEqual(@as(u64, 1), entry.count);
}

test "backend diagnostics: SSA limit records the complete prefixed instruction" {
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(a);
    try body.append(a, 0);
    for (0..wasm.backend_prototype.ir.max_values) |_| try body.appendSlice(a, &.{ 0x41, 0, 0x1a });
    const offset: u32 = @intCast(body.items.len - 1);
    try body.appendSlice(a, &.{ 0xfd, 12 });
    try body.appendSlice(a, &@as([16]u8, @splat(0)));
    try body.appendSlice(a, &.{ 0x1a, 0x0b });
    const module: wasm.Module = .{
        .types = &.{.{ .params = &.{}, .results = &.{} }},
        .funcs = &.{0},
        .code = &.{.{ .bytes = body.items }},
    };
    var instance: wasm.Instance = undefined;
    try wasm.instantiate(&instance, arena.allocator(), a, &module, .{});
    defer instance.deinit();
    var diagnostic: diagnostics.Lowering = .{};
    try std.testing.expectError(error.PrototypeLimit, wasm.backend_prototype.lowerInstanceDiagnosed(a, &instance, 0, &diagnostic));
    try std.testing.expectEqualDeep(diagnostics.Site{ .offset = offset, .opcode = 0xfd, .subopcode = 12 }, diagnostic.site.?);
}
