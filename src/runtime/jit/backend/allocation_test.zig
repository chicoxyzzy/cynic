const std = @import("std");
const ir = @import("ir.zig");
const allocation = @import("allocation.zig");
const a = std.testing.allocator;

const chain: ir.Graph = .{
    .types = &.{ .i64, .i64, .i64, .i64, .i64 },
    .argument_types = &.{.i64},
    .result_type = .i64,
    .blocks = &.{.{ .params = &.{0}, .nodes = &.{
        .{ .op = .constant, .out = 1, .immediate = 1 },
        .{ .op = .add, .out = 2, .lhs = 0, .rhs = 1 },
        .{ .op = .constant, .out = 3, .immediate = 2 },
        .{ .op = .mul, .out = 4, .lhs = 2, .rhs = 3 },
    }, .terminator = .{ .return_ = 4 } }},
};

test "backend allocation: read-before-write lifetimes reuse registers and spill slots" {
    var plan = try allocation.Plan.build(a, chain, .{ .register_count = 2 });
    defer plan.deinit();
    try std.testing.expectEqual(@as(u32, 0), plan.spill_slot_count);
    try std.testing.expect(std.meta.eql(plan.locations[0], plan.locations[2]));
    try std.testing.expect(plan.ranges[0].end < plan.ranges[2].start);
    try plan.verify(chain);
    var spilled = try allocation.Plan.build(a, chain, .{ .register_count = 0 });
    defer spilled.deinit();
    try std.testing.expectEqual(@as(u32, 2), spilled.spill_slot_count);
    var reference = try allocation.Plan.build(a, chain, .{ .mode = .scratch });
    defer reference.deinit();
    try std.testing.expectEqual(@as(u32, 5), reference.spill_slot_count);
}

const guarded: ir.Graph = .{
    .types = &.{ .i32, .i64, .i64, .i64, .i64 },
    .argument_types = &.{ .i32, .i64 },
    .result_type = .i64,
    .blocks = &.{.{ .params = &.{ 0, 1 }, .nodes = &.{
        .{ .op = .constant, .out = 2, .immediate = 1 },
        .{ .op = .add, .out = 3, .lhs = 1, .rhs = 2 },
        .{ .op = .guard, .lhs = 0, .exit = .{ .id = 9, .values = &.{ 1, 3 } } },
        .{ .op = .constant, .out = 4, .immediate = 99 },
    }, .terminator = .{ .return_ = 3 } }},
};

test "backend allocation: guard-only uses remain live and unused outputs need no home" {
    var plan = try allocation.Plan.build(a, guarded, .{ .register_count = 1 });
    defer plan.deinit();
    try std.testing.expectEqual(@as(u32, 5), plan.ranges[1].end);
    try std.testing.expectEqual(@as(u32, 2), plan.ranges[1].uses);
    try std.testing.expect(!std.meta.eql(plan.locations[1], plan.locations[3]));
    try std.testing.expect(plan.locations[4] == .none);
    try std.testing.expect(plan.spill_slot_count > 0);
    try plan.verify(guarded);
}

test "backend allocation: verifier rejects overlapping homes and forged lifetimes" {
    var plan = try allocation.Plan.build(a, guarded, .{ .register_count = 1 });
    defer plan.deinit();
    const saved = plan.locations[3];
    plan.locations[3] = plan.locations[1];
    try std.testing.expectError(error.InvalidAllocation, plan.verify(guarded));
    plan.locations[3] = saved;
    plan.ranges[1].end = 3;
    try std.testing.expectError(error.InvalidAllocation, plan.verify(guarded));
    plan.ranges[1].end = 5;
    plan.locations[3] = .{ .register = 1 };
    try std.testing.expectError(error.InvalidAllocation, plan.verify(guarded));
    plan.locations[3] = saved;
    plan.locations[4] = saved;
    try std.testing.expectError(error.InvalidAllocation, plan.verify(guarded));
    try std.testing.expectError(error.PrototypeLimit, allocation.Plan.build(a, guarded, .{ .register_count = allocation.max_registers + 1 }));
}

test "backend allocation: branch arguments from both successors remain live" {
    const graph: ir.Graph = .{
        .types = &.{ .i32, .i64, .i64, .i64, .i64 },
        .argument_types = &.{ .i32, .i64, .i64 },
        .result_type = .i64,
        .blocks = &.{
            .{ .params = &.{ 0, 1, 2 }, .terminator = .{ .branch = .{
                .condition = 0,
                .taken = .{ .target = 1, .args = &.{1} },
                .fallthrough = .{ .target = 2, .args = &.{2} },
            } } },
            .{ .params = &.{3}, .terminator = .{ .return_ = 3 } },
            .{ .params = &.{4}, .terminator = .{ .return_ = 4 } },
        },
    };
    var plan = try allocation.Plan.build(a, graph, .{ .register_count = 1 });
    defer plan.deinit();
    try std.testing.expectEqual(@as(u32, 1), plan.ranges[1].end);
    try std.testing.expectEqual(@as(u32, 1), plan.ranges[2].end);
    try std.testing.expect(!std.meta.eql(plan.locations[1], plan.locations[2]));
    try std.testing.expect(std.meta.eql(plan.locations[3], plan.locations[4]));
}

fn allocationFailures(allocator: std.mem.Allocator) anyerror!void {
    var plan = try allocation.Plan.build(allocator, guarded, .{});
    defer plan.deinit();
    try plan.verify(guarded);
}

test "backend allocation: allocation failures release partial plans" {
    try std.testing.checkAllAllocationFailures(a, allocationFailures, .{});
}
