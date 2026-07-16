//! Deterministic sequentialization of parallel CFG-edge assignments.
//!
//! Destination locations are unique, but sources may fan out. Acyclic moves
//! run from the leaves inward. A cycle saves its first raw source in a
//! dedicated scratch register and redirects every consumer of that source;
//! the original conversion remains attached to the final move.

const std = @import("std");

const a64 = @import("../jit/asm_aarch64.zig");
const ir = @import("ir.zig");
const representation = @import("representation.zig");

pub const Location = union(enum) {
    none,
    immediate: ir.Immediate,
    register: a64.Reg,
    tagged_stack: u32,
    int32_stack: u32,
};

pub const Assignment = struct {
    source: Location,
    destination: Location,
    conversion: representation.Conversion,
};

pub const Move = Assignment;

pub fn resolve(
    allocator: std.mem.Allocator,
    assignments: []const Assignment,
    cycle_scratch: a64.Reg,
    output: *std.ArrayListUnmanaged(Move),
) !void {
    try validate(assignments, cycle_scratch);
    const output_start = output.items.len;
    errdefer output.shrinkRetainingCapacity(output_start);

    var pending: std.ArrayListUnmanaged(Assignment) = .empty;
    defer pending.deinit(allocator);
    for (assignments) |assignment| {
        if (assignment.conversion == .none and
            storageEql(assignment.source, assignment.destination))
        {
            continue;
        }
        try pending.append(allocator, assignment);
    }

    const scratch: Location = .{ .register = cycle_scratch };
    while (pending.items.len != 0) {
        var ready: ?usize = null;
        for (pending.items, 0..) |assignment, index| {
            if (!destinationIsSource(assignment.destination, pending.items)) {
                ready = index;
                break;
            }
        }
        if (ready) |index| {
            try output.append(allocator, pending.orderedRemove(index));
            continue;
        }

        var cycle_source: ?Location = null;
        for (pending.items) |assignment| {
            if (isStorage(assignment.source)) {
                cycle_source = assignment.source;
                break;
            }
        }
        const source = cycle_source orelse return error.InvalidParallelMove;
        try output.append(allocator, .{
            .source = source,
            .destination = scratch,
            .conversion = .none,
        });
        for (pending.items) |*assignment| {
            if (storageEql(assignment.source, source)) assignment.source = scratch;
        }
    }
}

fn validate(assignments: []const Assignment, cycle_scratch: a64.Reg) !void {
    const scratch: Location = .{ .register = cycle_scratch };
    for (assignments, 0..) |assignment, index| {
        if (!isSource(assignment.source) or !isStorage(assignment.destination) or
            assignment.conversion == .check_int32 or
            storageEql(assignment.source, scratch) or
            storageEql(assignment.destination, scratch))
        {
            return error.InvalidParallelMove;
        }
        for (assignments[0..index]) |previous| {
            if (storageEql(previous.destination, assignment.destination)) {
                return error.InvalidParallelMove;
            }
        }
    }
}

fn destinationIsSource(destination: Location, assignments: []const Assignment) bool {
    for (assignments) |assignment| {
        if (storageEql(destination, assignment.source)) return true;
    }
    return false;
}

fn isSource(location: Location) bool {
    return switch (location) {
        .none => false,
        .immediate, .register, .tagged_stack, .int32_stack => true,
    };
}

fn isStorage(location: Location) bool {
    return switch (location) {
        .register, .tagged_stack, .int32_stack => true,
        .none, .immediate => false,
    };
}

pub fn eql(lhs: Location, rhs: Location) bool {
    if (std.meta.activeTag(lhs) != std.meta.activeTag(rhs)) return false;
    return switch (lhs) {
        .none => true,
        .immediate => |value| std.meta.eql(value, rhs.immediate),
        .register => |value| value == rhs.register,
        .tagged_stack => |value| value == rhs.tagged_stack,
        .int32_stack => |value| value == rhs.int32_stack,
    };
}

fn storageEql(lhs: Location, rhs: Location) bool {
    if (!isStorage(lhs) or !isStorage(rhs)) return false;
    return eql(lhs, rhs);
}
