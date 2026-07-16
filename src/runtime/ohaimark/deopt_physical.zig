//! Physical Ohaimark deoptimization recovery metadata.
//!
//! Logical frame states name SSA values. This pass gives every non-constant
//! value referenced by a deopt point one stable definition-time spill home,
//! split into tagged and int32 regions, then translates the logical stream to
//! concrete stack locations. Future code generation must write these homes at
//! definitions; register allocation may still keep an additional register
//! copy for ordinary uses.

const std = @import("std");

const deopt = @import("deopt.zig");
const codec = @import("deopt_codec.zig");
const ir = @import("ir.zig");
const representation = @import("representation.zig");
const specialize = @import("specialize.zig");
const Value = @import("../value.zig").Value;

pub const Home = union(enum) {
    tagged_stack: u32,
    int32_stack: u32,
};

pub const Homes = struct {
    allocator: std.mem.Allocator,
    values: []?Home,
    tagged_slot_count: u32,
    int32_slot_count: u32,

    pub fn build(
        allocator: std.mem.Allocator,
        graph: *const ir.Graph,
        specialization: *const specialize.Plan,
        representations: *const representation.Plan,
        logical: *const deopt.Metadata,
    ) !Homes {
        try logical.verify(graph, specialization);
        try representations.verify(graph, specialization);

        const values = try allocator.alloc(?Home, graph.nodes.len);
        errdefer allocator.free(values);
        const counts = try computeHomes(allocator, representations, logical, values);
        var homes: Homes = .{
            .allocator = allocator,
            .values = values,
            .tagged_slot_count = counts.tagged,
            .int32_slot_count = counts.int32,
        };
        errdefer homes.deinit();
        try homes.verify(graph, specialization, representations, logical);
        return homes;
    }

    pub fn deinit(self: *Homes) void {
        self.allocator.free(self.values);
        self.* = undefined;
    }

    pub fn verify(
        self: *const Homes,
        graph: *const ir.Graph,
        specialization: *const specialize.Plan,
        representations: *const representation.Plan,
        logical: *const deopt.Metadata,
    ) !void {
        try logical.verify(graph, specialization);
        try representations.verify(graph, specialization);
        if (self.values.len != graph.nodes.len) return error.InvalidMetadata;

        const expected = try self.allocator.alloc(?Home, graph.nodes.len);
        defer self.allocator.free(expected);
        const counts = try computeHomes(self.allocator, representations, logical, expected);
        if (self.tagged_slot_count != counts.tagged or
            self.int32_slot_count != counts.int32)
        {
            return error.InvalidMetadata;
        }
        for (self.values, expected) |actual, wanted| {
            if (!optionalHomeEql(actual, wanted)) return error.InvalidMetadata;
        }
    }

    pub fn homeFor(self: *const Homes, value: ir.ValueId) !Home {
        if (value >= self.values.len) return error.InvalidMetadata;
        return self.values[value] orelse error.MissingRecoveryHome;
    }
};

const Counts = struct {
    tagged: u32 = 0,
    int32: u32 = 0,
};

fn computeHomes(
    allocator: std.mem.Allocator,
    representations: *const representation.Plan,
    logical: *const deopt.Metadata,
    values: []?Home,
) !Counts {
    if (values.len != representations.outputs.len) return error.MalformedGraph;
    @memset(values, null);
    var counts: Counts = .{};
    for (0..logical.points.len) |point_index| {
        var point = try logical.decode(allocator, point_index);
        defer point.deinit();
        try assignRecoveryHome(representations, values, &counts, point.accumulator);
        for (point.slots) |slot| {
            try assignRecoveryHome(representations, values, &counts, slot.recovery);
        }
    }
    return counts;
}

fn assignRecoveryHome(
    representations: *const representation.Plan,
    values: []?Home,
    counts: *Counts,
    recovery: deopt.Recovery,
) !void {
    const value = switch (recovery) {
        .immediate => return,
        .value => |value| value,
    };
    if (value >= values.len or value >= representations.outputs.len) {
        return error.MalformedGraph;
    }
    const expected_tag: std.meta.Tag(Home) = switch (representations.outputs[value]) {
        .tagged => .tagged_stack,
        .int32 => .int32_stack,
        .none => return error.MalformedGraph,
    };
    if (values[value]) |existing| {
        if (std.meta.activeTag(existing) != expected_tag) return error.MalformedGraph;
        return;
    }
    values[value] = switch (expected_tag) {
        .tagged_stack => .{ .tagged_stack = try takeSlot(&counts.tagged) },
        .int32_stack => .{ .int32_stack = try takeSlot(&counts.int32) },
    };
}

fn takeSlot(count: *u32) !u32 {
    if (count.* == std.math.maxInt(u32)) return error.GraphTooLarge;
    const slot = count.*;
    count.* += 1;
    return slot;
}

pub const Recovery = union(enum) {
    tagged_stack: u32,
    int32_stack: u32,
    immediate: ir.Immediate,

    /// Materialize one Lantern-compatible NaN-boxed value without allocating.
    pub fn materialize(
        self: Recovery,
        tagged_spills: []const Value,
        int32_spills: []const i32,
        constants: []const Value,
    ) !Value {
        return switch (self) {
            .tagged_stack => |slot| checkedElement(Value, tagged_spills, slot),
            .int32_stack => |slot| Value.fromInt32(
                try checkedElement(i32, int32_spills, slot),
            ),
            .immediate => |immediate| switch (immediate) {
                .undefined_ => Value.undefined_,
                .null_ => Value.null_,
                .true_ => Value.true_,
                .false_ => Value.false_,
                .hole => Value.hole_,
                .int32 => |value| Value.fromInt32(value),
                .constant_pool => |index| checkedElement(Value, constants, index),
            },
        };
    }
};

fn checkedElement(comptime T: type, values: []const T, raw_index: anytype) !T {
    const index: usize = @intCast(raw_index);
    if (index >= values.len) return error.InvalidRecovery;
    return values[index];
}

pub const Slot = struct {
    register: u8,
    recovery: Recovery,
};

pub const Point = deopt.Point;

pub const DecodedPoint = struct {
    allocator: std.mem.Allocator,
    bytecode_offset: u32,
    accumulator: Recovery,
    slots: []Slot,

    pub fn deinit(self: *DecodedPoint) void {
        self.allocator.free(self.slots);
        self.* = undefined;
    }
};

pub const Metadata = struct {
    allocator: std.mem.Allocator,
    points: []Point,
    stream: []u8,
    tagged_slot_count: u32,
    int32_slot_count: u32,

    pub fn build(
        allocator: std.mem.Allocator,
        graph: *const ir.Graph,
        specialization: *const specialize.Plan,
        representations: *const representation.Plan,
        logical: *const deopt.Metadata,
        homes: *const Homes,
    ) !Metadata {
        try homes.verify(graph, specialization, representations, logical);

        var points: std.ArrayListUnmanaged(Point) = .empty;
        defer points.deinit(allocator);
        var stream: std.ArrayListUnmanaged(u8) = .empty;
        defer stream.deinit(allocator);
        for (logical.points, 0..) |logical_point, point_index| {
            var decoded = try logical.decode(allocator, point_index);
            defer decoded.deinit();
            const stream_offset = try codec.indexU32(stream.items.len);
            try codec.appendU32(&stream, allocator, decoded.bytecode_offset);
            try appendRecovery(
                &stream,
                allocator,
                try physicalRecovery(homes, decoded.accumulator),
            );
            try codec.appendU16(&stream, allocator, @intCast(decoded.slots.len));
            for (decoded.slots) |slot| {
                try stream.append(allocator, slot.register);
                try appendRecovery(
                    &stream,
                    allocator,
                    try physicalRecovery(homes, slot.recovery),
                );
            }
            try points.append(allocator, .{
                .node = logical_point.node,
                .stream_offset = stream_offset,
                .stream_len = try codec.indexU32(stream.items.len - stream_offset),
            });
        }

        const point_slice = try points.toOwnedSlice(allocator);
        errdefer allocator.free(point_slice);
        const stream_slice = try stream.toOwnedSlice(allocator);
        errdefer allocator.free(stream_slice);
        var metadata: Metadata = .{
            .allocator = allocator,
            .points = point_slice,
            .stream = stream_slice,
            .tagged_slot_count = homes.tagged_slot_count,
            .int32_slot_count = homes.int32_slot_count,
        };
        errdefer metadata.deinit();
        try metadata.verify(
            graph,
            specialization,
            representations,
            logical,
            homes,
        );
        return metadata;
    }

    pub fn deinit(self: *Metadata) void {
        self.allocator.free(self.points);
        self.allocator.free(self.stream);
        self.* = undefined;
    }

    pub fn verify(
        self: *const Metadata,
        graph: *const ir.Graph,
        specialization: *const specialize.Plan,
        representations: *const representation.Plan,
        logical: *const deopt.Metadata,
        homes: *const Homes,
    ) !void {
        try homes.verify(graph, specialization, representations, logical);
        if (self.tagged_slot_count != homes.tagged_slot_count or
            self.int32_slot_count != homes.int32_slot_count or
            self.points.len != logical.points.len)
        {
            return error.InvalidMetadata;
        }

        var expected_offset: usize = 0;
        for (self.points, logical.points, 0..) |point, logical_point, point_index| {
            if (point.node != logical_point.node or point.stream_offset != expected_offset) {
                return error.InvalidMetadata;
            }
            const bytes = try pointBytes(self, point);
            var decoded = try logical.decode(self.allocator, point_index);
            defer decoded.deinit();
            try verifyPoint(bytes, decoded, homes, self.tagged_slot_count, self.int32_slot_count);
            expected_offset += bytes.len;
        }
        if (expected_offset != self.stream.len) return error.InvalidMetadata;
    }

    pub fn decode(
        self: *const Metadata,
        allocator: std.mem.Allocator,
        point_index: usize,
    ) !DecodedPoint {
        if (point_index >= self.points.len) return error.InvalidMetadata;
        var cursor: codec.Cursor = .{ .bytes = try pointBytes(self, self.points[point_index]) };
        const bytecode_offset = try cursor.readU32();
        const accumulator = try readRecovery(
            &cursor,
            self.tagged_slot_count,
            self.int32_slot_count,
        );
        const slot_count = try cursor.readU16();
        const slots = try allocator.alloc(Slot, slot_count);
        errdefer allocator.free(slots);
        var previous_register: ?u8 = null;
        for (slots) |*slot| {
            const register = try cursor.readByte();
            if (previous_register) |previous| {
                if (register <= previous) return error.InvalidMetadata;
            }
            slot.* = .{
                .register = register,
                .recovery = try readRecovery(
                    &cursor,
                    self.tagged_slot_count,
                    self.int32_slot_count,
                ),
            };
            previous_register = register;
        }
        if (!cursor.atEnd()) return error.InvalidMetadata;
        return .{
            .allocator = allocator,
            .bytecode_offset = bytecode_offset,
            .accumulator = accumulator,
            .slots = slots,
        };
    }
};

fn physicalRecovery(homes: *const Homes, logical: deopt.Recovery) !Recovery {
    return switch (logical) {
        .immediate => |immediate| .{ .immediate = immediate },
        .value => |value| switch (try homes.homeFor(value)) {
            .tagged_stack => |slot| .{ .tagged_stack = slot },
            .int32_stack => |slot| .{ .int32_stack = slot },
        },
    };
}

fn verifyPoint(
    bytes: []const u8,
    logical: deopt.DecodedPoint,
    homes: *const Homes,
    tagged_slot_count: u32,
    int32_slot_count: u32,
) !void {
    var cursor: codec.Cursor = .{ .bytes = bytes };
    if (try cursor.readU32() != logical.bytecode_offset) return error.InvalidMetadata;
    const accumulator = try readRecovery(&cursor, tagged_slot_count, int32_slot_count);
    if (!recoveryEql(accumulator, try physicalRecovery(homes, logical.accumulator))) {
        return error.InvalidMetadata;
    }
    if (try cursor.readU16() != logical.slots.len) return error.InvalidMetadata;
    for (logical.slots) |slot| {
        if (try cursor.readByte() != slot.register) return error.InvalidMetadata;
        const recovery = try readRecovery(&cursor, tagged_slot_count, int32_slot_count);
        if (!recoveryEql(recovery, try physicalRecovery(homes, slot.recovery))) {
            return error.InvalidMetadata;
        }
    }
    if (!cursor.atEnd()) return error.InvalidMetadata;
}

fn pointBytes(metadata: *const Metadata, point: Point) ![]const u8 {
    return codec.checkedBytes(metadata.stream, point.stream_offset, point.stream_len);
}

const RecoveryTag = enum(u8) {
    tagged_stack,
    int32_stack,
    undefined_,
    null_,
    true_,
    false_,
    hole,
    int32,
    constant_pool,
};

fn appendRecovery(
    stream: *std.ArrayListUnmanaged(u8),
    allocator: std.mem.Allocator,
    recovery: Recovery,
) !void {
    switch (recovery) {
        .tagged_stack => |slot| {
            try stream.append(allocator, @intFromEnum(RecoveryTag.tagged_stack));
            try codec.appendU32(stream, allocator, slot);
        },
        .int32_stack => |slot| {
            try stream.append(allocator, @intFromEnum(RecoveryTag.int32_stack));
            try codec.appendU32(stream, allocator, slot);
        },
        .immediate => |immediate| switch (immediate) {
            .undefined_ => try stream.append(allocator, @intFromEnum(RecoveryTag.undefined_)),
            .null_ => try stream.append(allocator, @intFromEnum(RecoveryTag.null_)),
            .true_ => try stream.append(allocator, @intFromEnum(RecoveryTag.true_)),
            .false_ => try stream.append(allocator, @intFromEnum(RecoveryTag.false_)),
            .hole => try stream.append(allocator, @intFromEnum(RecoveryTag.hole)),
            .int32 => |value| {
                try stream.append(allocator, @intFromEnum(RecoveryTag.int32));
                try codec.appendU32(stream, allocator, @bitCast(value));
            },
            .constant_pool => |index| {
                try stream.append(allocator, @intFromEnum(RecoveryTag.constant_pool));
                try codec.appendU16(stream, allocator, index);
            },
        },
    }
}

fn readRecovery(
    cursor: *codec.Cursor,
    tagged_slot_count: u32,
    int32_slot_count: u32,
) !Recovery {
    return switch (try cursor.readByte()) {
        @intFromEnum(RecoveryTag.tagged_stack) => blk: {
            const slot = try cursor.readU32();
            if (slot >= tagged_slot_count) return error.InvalidMetadata;
            break :blk .{ .tagged_stack = slot };
        },
        @intFromEnum(RecoveryTag.int32_stack) => blk: {
            const slot = try cursor.readU32();
            if (slot >= int32_slot_count) return error.InvalidMetadata;
            break :blk .{ .int32_stack = slot };
        },
        @intFromEnum(RecoveryTag.undefined_) => .{ .immediate = .undefined_ },
        @intFromEnum(RecoveryTag.null_) => .{ .immediate = .null_ },
        @intFromEnum(RecoveryTag.true_) => .{ .immediate = .true_ },
        @intFromEnum(RecoveryTag.false_) => .{ .immediate = .false_ },
        @intFromEnum(RecoveryTag.hole) => .{ .immediate = .hole },
        @intFromEnum(RecoveryTag.int32) => .{
            .immediate = .{ .int32 = @as(i32, @bitCast(try cursor.readU32())) },
        },
        @intFromEnum(RecoveryTag.constant_pool) => .{
            .immediate = .{ .constant_pool = try cursor.readU16() },
        },
        else => error.InvalidMetadata,
    };
}

fn optionalHomeEql(lhs: ?Home, rhs: ?Home) bool {
    if (lhs == null or rhs == null) return lhs == null and rhs == null;
    return homeEql(lhs.?, rhs.?);
}

fn homeEql(lhs: Home, rhs: Home) bool {
    if (std.meta.activeTag(lhs) != std.meta.activeTag(rhs)) return false;
    return switch (lhs) {
        .tagged_stack => |slot| slot == rhs.tagged_stack,
        .int32_stack => |slot| slot == rhs.int32_stack,
    };
}

fn recoveryEql(lhs: Recovery, rhs: Recovery) bool {
    if (std.meta.activeTag(lhs) != std.meta.activeTag(rhs)) return false;
    return switch (lhs) {
        .tagged_stack => |slot| slot == rhs.tagged_stack,
        .int32_stack => |slot| slot == rhs.int32_stack,
        .immediate => |immediate| immediateEql(immediate, rhs.immediate),
    };
}

fn immediateEql(lhs: ir.Immediate, rhs: ir.Immediate) bool {
    if (std.meta.activeTag(lhs) != std.meta.activeTag(rhs)) return false;
    return switch (lhs) {
        .int32 => |value| value == rhs.int32,
        .constant_pool => |value| value == rhs.constant_pool,
        else => true,
    };
}
