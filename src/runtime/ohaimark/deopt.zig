//! Ohaimark deoptimization frame-state encoding and verification.
//!
//! Graph nodes that may speculate carry the pre-operation Lantern state as
//! SSA ValueIds. This module serializes only guarded nodes selected by the
//! specialization plan. Constants are embedded directly; non-constant values
//! remain SSA references until register allocation assigns physical recovery
//! locations. Runtime reconstruction is deliberately deferred until that
//! location map exists.

const std = @import("std");

const codec = @import("deopt_codec.zig");
const ir = @import("ir.zig");
const specialize = @import("specialize.zig");

pub const Recovery = union(enum) {
    value: ir.ValueId,
    immediate: ir.Immediate,
};

pub const Slot = struct {
    register: u8,
    recovery: Recovery,
};

pub const Point = struct {
    node: ir.ValueId,
    stream_offset: u32,
    stream_len: u32,
};

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

    pub fn build(
        allocator: std.mem.Allocator,
        graph: *const ir.Graph,
        plan: *const specialize.Plan,
    ) !Metadata {
        if (plan.node_info.len != graph.nodes.len) return error.MalformedGraph;

        var points: std.ArrayListUnmanaged(Point) = .empty;
        defer points.deinit(allocator);
        var stream: std.ArrayListUnmanaged(u8) = .empty;
        defer stream.deinit(allocator);

        for (graph.nodes, 0..) |_, node_index| {
            const node_id: ir.ValueId = @intCast(node_index);
            const info = plan.node_info[node_index];
            if (!requiresDeopt(info.lowering)) continue;
            try validateGuardedNode(graph, plan, node_id);
            const state = try checkedState(graph, node_id);
            const slots = try checkedSlots(graph, node_id, state);

            const stream_offset = try codec.indexU32(stream.items.len);
            try codec.appendU32(&stream, allocator, state.bytecode_offset);
            try appendRecovery(
                &stream,
                allocator,
                try recoveryFor(graph, state.accumulator),
            );
            try codec.appendU16(&stream, allocator, state.slot_count);
            for (slots) |slot| {
                try stream.append(allocator, slot.register);
                try appendRecovery(
                    &stream,
                    allocator,
                    try recoveryFor(graph, slot.value),
                );
            }
            const stream_len = try codec.indexU32(stream.items.len - stream_offset);
            try points.append(allocator, .{
                .node = node_id,
                .stream_offset = stream_offset,
                .stream_len = stream_len,
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
        };
        errdefer metadata.deinit();
        try metadata.verify(graph, plan);
        return metadata;
    }

    pub fn deinit(self: *Metadata) void {
        self.allocator.free(self.points);
        self.allocator.free(self.stream);
        self.* = undefined;
    }

    /// Verify both the byte stream and its semantic correspondence to the
    /// graph. This parser is bounds-checked throughout so corrupt compiler
    /// metadata is a normal error rather than a slice panic.
    pub fn verify(
        self: *const Metadata,
        graph: *const ir.Graph,
        plan: *const specialize.Plan,
    ) !void {
        if (plan.node_info.len != graph.nodes.len) return error.MalformedGraph;

        var point_index: usize = 0;
        var expected_stream_offset: usize = 0;
        for (graph.nodes, 0..) |_, node_index| {
            const node_id: ir.ValueId = @intCast(node_index);
            const info = plan.node_info[node_index];
            if (!requiresDeopt(info.lowering)) continue;
            try validateGuardedNode(graph, plan, node_id);
            if (point_index >= self.points.len) return error.InvalidMetadata;
            const point = self.points[point_index];
            if (point.node != node_id or point.stream_offset != expected_stream_offset) {
                return error.InvalidMetadata;
            }
            const bytes = try pointBytes(self, point);
            try verifyPoint(bytes, graph, node_id);
            expected_stream_offset += bytes.len;
            point_index += 1;
        }
        if (point_index != self.points.len or expected_stream_offset != self.stream.len) {
            return error.InvalidMetadata;
        }
    }

    pub fn decode(
        self: *const Metadata,
        allocator: std.mem.Allocator,
        point_index: usize,
    ) !DecodedPoint {
        if (point_index >= self.points.len) return error.InvalidMetadata;
        var cursor: codec.Cursor = .{ .bytes = try pointBytes(self, self.points[point_index]) };
        const bytecode_offset = try cursor.readU32();
        const accumulator = try readRecovery(&cursor);
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
                .recovery = try readRecovery(&cursor),
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

pub fn requiresDeopt(lowering: specialize.Lowering) bool {
    return switch (lowering) {
        .checked_int32_add,
        .checked_int32_sub,
        .checked_int32_mul,
        .strict_eq,
        .load_named_own,
        .load_named_prototype,
        .load_named_synthetic,
        => true,
        else => false,
    };
}

fn validateGuardedNode(
    graph: *const ir.Graph,
    plan: *const specialize.Plan,
    node_id: ir.ValueId,
) !void {
    if (node_id >= graph.nodes.len or node_id >= plan.node_info.len) {
        return error.MalformedGraph;
    }
    const node = graph.nodes[node_id];
    const info = plan.node_info[node_id];
    const valid = switch (info.lowering) {
        .checked_int32_add => node.kind == .add,
        .checked_int32_sub => node.kind == .sub,
        .checked_int32_mul => node.kind == .mul,
        .strict_eq => node.kind == .strict_eq,
        .load_named_own => try hasAssumption(plan, info, .load_own) and node.kind == .load_named,
        .load_named_prototype => try hasAssumption(plan, info, .load_prototype) and node.kind == .load_named,
        .load_named_synthetic => try hasAssumption(plan, info, .load_synthetic) and node.kind == .load_named,
        else => false,
    };
    if (!valid or node.frame_state == null) return error.MalformedGraph;
}

fn hasAssumption(
    plan: *const specialize.Plan,
    info: specialize.NodeInfo,
    kind: specialize.AssumptionKind,
) !bool {
    const assumption_index = info.assumption orelse return false;
    if (assumption_index >= plan.assumptions.len) return error.MalformedGraph;
    return plan.assumptions[assumption_index].kind == kind;
}

fn checkedState(graph: *const ir.Graph, node_id: ir.ValueId) !ir.FrameState {
    if (node_id >= graph.nodes.len) return error.MalformedGraph;
    const node = graph.nodes[node_id];
    const state_id = node.frame_state orelse return error.MalformedGraph;
    if (state_id >= graph.frame_states.len) return error.MalformedGraph;
    const state = graph.frame_states[state_id];
    if (state.block >= graph.blocks.len) return error.MalformedGraph;
    const block = graph.blocks[state.block];
    const body_start: usize = block.node_start;
    const body_count: usize = block.node_count;
    if (!block.reachable or body_start > graph.nodes.len or
        body_count > graph.nodes.len - body_start)
    {
        return error.MalformedGraph;
    }
    const node_index: usize = node_id;
    if (node_index < body_start or node_index >= body_start + body_count or
        node.bytecode_offset < block.start or node.bytecode_offset >= block.end or
        state.bytecode_offset != node.bytecode_offset or
        !try valueAvailable(graph, state, node_id, state.accumulator))
    {
        return error.MalformedGraph;
    }
    return state;
}

fn checkedSlots(
    graph: *const ir.Graph,
    node_id: ir.ValueId,
    state: ir.FrameState,
) ![]const ir.FrameSlot {
    const start: usize = state.slot_start;
    const count: usize = state.slot_count;
    if (start > graph.frame_slots.len or count > graph.frame_slots.len - start) {
        return error.MalformedGraph;
    }
    const slots = graph.frame_slots[start..][0..count];
    var previous_register: ?u8 = null;
    for (slots) |slot| {
        if (slot.register >= graph.register_count or
            !try valueAvailable(graph, state, node_id, slot.value))
        {
            return error.MalformedGraph;
        }
        if (previous_register) |previous| {
            if (slot.register <= previous) return error.MalformedGraph;
        }
        previous_register = slot.register;
    }
    return slots;
}

fn valueAvailable(
    graph: *const ir.Graph,
    state: ir.FrameState,
    node_id: ir.ValueId,
    value: ir.ValueId,
) !bool {
    if (value >= node_id or value >= graph.nodes.len or state.block >= graph.blocks.len) {
        return false;
    }
    const block = graph.blocks[state.block];
    const body_start: usize = block.node_start;
    const value_index: usize = value;
    if (value_index >= body_start and value < node_id) return true;

    const param_start: usize = block.param_start;
    const param_count: usize = block.param_count;
    if (param_start > graph.params.len or param_count > graph.params.len - param_start) {
        return error.MalformedGraph;
    }
    for (graph.params[param_start..][0..param_count], 0..) |param, offset| {
        if (param.value >= graph.nodes.len or graph.nodes[param.value].kind != .block_parameter) {
            return error.MalformedGraph;
        }
        const parameter_index = switch (graph.nodes[param.value].payload) {
            .parameter => |index| index,
            else => return error.MalformedGraph,
        };
        if (parameter_index != param_start + offset) return error.MalformedGraph;
        if (param.value == value) return true;
    }
    return false;
}

fn recoveryFor(graph: *const ir.Graph, value: ir.ValueId) !Recovery {
    if (value >= graph.nodes.len) return error.MalformedGraph;
    const node = graph.nodes[value];
    if (node.kind != .constant) return .{ .value = value };
    return switch (node.payload) {
        .immediate => |immediate| .{ .immediate = immediate },
        else => error.MalformedGraph,
    };
}

fn verifyPoint(bytes: []const u8, graph: *const ir.Graph, node_id: ir.ValueId) !void {
    const state = try checkedState(graph, node_id);
    const slots = try checkedSlots(graph, node_id, state);
    var cursor: codec.Cursor = .{ .bytes = bytes };
    if (try cursor.readU32() != state.bytecode_offset) return error.InvalidMetadata;
    if (!recoveryEql(try readRecovery(&cursor), try recoveryFor(graph, state.accumulator))) {
        return error.InvalidMetadata;
    }
    if (try cursor.readU16() != slots.len) return error.InvalidMetadata;
    for (slots) |slot| {
        if (try cursor.readByte() != slot.register) return error.InvalidMetadata;
        if (!recoveryEql(try readRecovery(&cursor), try recoveryFor(graph, slot.value))) {
            return error.InvalidMetadata;
        }
    }
    if (!cursor.atEnd()) return error.InvalidMetadata;
}

fn pointBytes(metadata: *const Metadata, point: Point) ![]const u8 {
    return codec.checkedBytes(metadata.stream, point.stream_offset, point.stream_len);
}

const RecoveryTag = enum(u8) {
    value,
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
        .value => |value| {
            try stream.append(allocator, @intFromEnum(RecoveryTag.value));
            try codec.appendU32(stream, allocator, value);
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
            .constant_pool => |value| {
                try stream.append(allocator, @intFromEnum(RecoveryTag.constant_pool));
                try codec.appendU16(stream, allocator, value);
            },
        },
    }
}

fn readRecovery(cursor: *codec.Cursor) !Recovery {
    const tag = try cursor.readByte();
    return switch (tag) {
        @intFromEnum(RecoveryTag.value) => .{ .value = try cursor.readU32() },
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

fn recoveryEql(lhs: Recovery, rhs: Recovery) bool {
    if (std.meta.activeTag(lhs) != std.meta.activeTag(rhs)) return false;
    return switch (lhs) {
        .value => |value| value == rhs.value,
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
