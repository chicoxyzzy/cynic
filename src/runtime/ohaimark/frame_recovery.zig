//! Target-independent planning for exact Lantern frame reconstruction.
//!
//! Entry-frame recoveries are parallel assignments: a destination can still
//! contain another recipe's source. This module resolves those moves, including
//! cycles, before architecture-specific emitters write spill/immediate values.

const std = @import("std");

const deopt_physical = @import("deopt_physical.zig");

pub const Location = union(enum) {
    accumulator,
    register: u8,
};

pub const MoveSource = union(enum) {
    frame: Location,
    cycle_scratch,
};

pub const Move = struct {
    source: MoveSource,
    destination: Location,
};

pub const Step = union(enum) {
    save_cycle: Location,
    move: Move,
};

pub const External = struct {
    recovery: deopt_physical.Recovery,
    destination: Location,
};

pub const Plan = struct {
    allocator: std.mem.Allocator,
    steps: []Step,
    externals: []External,

    pub fn build(
        allocator: std.mem.Allocator,
        point: deopt_physical.DecodedPoint,
    ) !Plan {
        var pending: std.ArrayListUnmanaged(Move) = .empty;
        defer pending.deinit(allocator);
        var steps: std.ArrayListUnmanaged(Step) = .empty;
        defer steps.deinit(allocator);
        var externals: std.ArrayListUnmanaged(External) = .empty;
        defer externals.deinit(allocator);

        try appendRecovery(
            &pending,
            &externals,
            allocator,
            point.accumulator,
            .accumulator,
        );
        for (point.slots) |slot| {
            try appendRecovery(
                &pending,
                &externals,
                allocator,
                slot.recovery,
                .{ .register = slot.register },
            );
        }

        var steps_left = pending.items.len * 2 + 1;
        while (pending.items.len != 0) {
            if (steps_left == 0) return error.InvalidMetadata;
            steps_left -= 1;

            var ready: ?usize = null;
            for (pending.items, 0..) |move, index| {
                if (!destinationIsSource(move.destination, pending.items)) {
                    ready = index;
                    break;
                }
            }
            if (ready) |index| {
                try steps.append(allocator, .{
                    .move = pending.orderedRemove(index),
                });
                continue;
            }

            var cycle_source: ?Location = null;
            for (pending.items) |move| switch (move.source) {
                .frame => |source| {
                    cycle_source = source;
                    break;
                },
                .cycle_scratch => {},
            };
            const source = cycle_source orelse return error.InvalidMetadata;
            try steps.append(allocator, .{ .save_cycle = source });
            for (pending.items) |*move| switch (move.source) {
                .frame => |candidate| {
                    if (eql(candidate, source)) move.source = .cycle_scratch;
                },
                .cycle_scratch => {},
            };
        }

        const owned_steps = try steps.toOwnedSlice(allocator);
        errdefer allocator.free(owned_steps);
        const owned_externals = try externals.toOwnedSlice(allocator);
        return .{
            .allocator = allocator,
            .steps = owned_steps,
            .externals = owned_externals,
        };
    }

    pub fn deinit(self: *Plan) void {
        self.allocator.free(self.steps);
        self.allocator.free(self.externals);
        self.* = undefined;
    }
};

fn appendRecovery(
    pending: *std.ArrayListUnmanaged(Move),
    externals: *std.ArrayListUnmanaged(External),
    allocator: std.mem.Allocator,
    recovery: deopt_physical.Recovery,
    destination: Location,
) !void {
    const source: Location = switch (recovery) {
        .frame_accumulator => .accumulator,
        .frame_register => |register| .{ .register = register },
        .tagged_stack, .int32_stack, .immediate => {
            try externals.append(allocator, .{
                .recovery = recovery,
                .destination = destination,
            });
            return;
        },
    };
    if (eql(source, destination)) return;
    for (pending.items) |move| {
        if (eql(move.destination, destination)) return error.InvalidMetadata;
    }
    try pending.append(allocator, .{
        .source = .{ .frame = source },
        .destination = destination,
    });
}

fn destinationIsSource(destination: Location, pending: []const Move) bool {
    for (pending) |move| switch (move.source) {
        .frame => |source| if (eql(destination, source)) return true,
        .cycle_scratch => {},
    };
    return false;
}

pub fn eql(lhs: Location, rhs: Location) bool {
    if (std.meta.activeTag(lhs) != std.meta.activeTag(rhs)) return false;
    return switch (lhs) {
        .accumulator => true,
        .register => |register| register == rhs.register,
    };
}

test "frame recovery plan resolves a register accumulator cycle" {
    var slots = [_]deopt_physical.Slot{
        .{ .register = 0, .recovery = .frame_accumulator },
    };
    const point: deopt_physical.DecodedPoint = .{
        .allocator = std.testing.allocator,
        .bytecode_offset = 7,
        .accumulator = .{ .frame_register = 0 },
        .slots = &slots,
    };
    var plan = try Plan.build(std.testing.allocator, point);
    defer plan.deinit();

    try std.testing.expectEqual(@as(usize, 3), plan.steps.len);
    try std.testing.expectEqualDeep(
        Step{ .save_cycle = .{ .register = 0 } },
        plan.steps[0],
    );
    try std.testing.expectEqualDeep(
        Step{ .move = .{
            .source = .{ .frame = .accumulator },
            .destination = .{ .register = 0 },
        } },
        plan.steps[1],
    );
    try std.testing.expectEqualDeep(
        Step{ .move = .{
            .source = .cycle_scratch,
            .destination = .accumulator,
        } },
        plan.steps[2],
    );
    try std.testing.expectEqual(@as(usize, 0), plan.externals.len);
}

test "frame recovery plan defers external writes until direct moves finish" {
    var slots = [_]deopt_physical.Slot{
        .{ .register = 1, .recovery = .{ .immediate = .{ .int32 = 42 } } },
    };
    const point: deopt_physical.DecodedPoint = .{
        .allocator = std.testing.allocator,
        .bytecode_offset = 9,
        .accumulator = .{ .frame_register = 0 },
        .slots = &slots,
    };
    var plan = try Plan.build(std.testing.allocator, point);
    defer plan.deinit();

    try std.testing.expectEqual(@as(usize, 1), plan.steps.len);
    try std.testing.expectEqualDeep(
        Step{ .move = .{
            .source = .{ .frame = .{ .register = 0 } },
            .destination = .accumulator,
        } },
        plan.steps[0],
    );
    try std.testing.expectEqual(@as(usize, 1), plan.externals.len);
    try std.testing.expectEqualDeep(
        External{
            .recovery = .{ .immediate = .{ .int32 = 42 } },
            .destination = .{ .register = 1 },
        },
        plan.externals[0],
    );
}
