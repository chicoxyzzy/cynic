//! AArch64 physical-location and CFG-edge lowering plan for Ohaimark.
//!
//! This pass emits no machine code. It fixes the register convention, lays
//! out the precise tagged/int32 spill regions, maps abstract allocation
//! locations to physical ones, and sequentializes parallel block-argument
//! assignments. Code generation consumes only this verified plan.

const std = @import("std");

const a64 = @import("../jit/asm_aarch64.zig");
const allocation = @import("allocation.zig");
const deopt_physical = @import("deopt_physical.zig");
const ir = @import("ir.zig");
const parallel_moves = @import("parallel_moves.zig");
const representation = @import("representation.zig");
const specialize = @import("specialize.zig");

pub const realm_register: a64.Reg = .x19;
pub const lantern_frame_register: a64.Reg = .x20;
pub const lantern_registers_register: a64.Reg = .x21;
pub const spill_base_register: a64.Reg = .x22;
pub const value_registers = [_]a64.Reg{ .x23, .x24, .x25, .x26, .x27, .x28 };
pub const cycle_scratch: a64.Reg = .x9;
pub const transfer_scratch: a64.Reg = .x10;
pub const boxing_scratch: a64.Reg = .x11;

/// FP/LR plus x19-x28, saved as six 16-byte pairs.
pub const callee_save_bytes: u32 = 96;
const max_tagged_offset: u32 = 32_760;
const max_int32_offset: u32 = 16_380;

pub const Location = parallel_moves.Location;
pub const Move = parallel_moves.Move;

pub const FrameLayout = struct {
    tagged_slot_count: u32,
    int32_slot_count: u32,
    tagged_start: u32,
    int32_start: u32,
    spill_bytes: u32,
    callee_save_start: u32,
    native_frame_bytes: u32,

    pub fn build(tagged_slot_count: u32, int32_slot_count: u32) !FrameLayout {
        const tagged_bytes = @as(u64, tagged_slot_count) * 8;
        const int32_bytes = @as(u64, int32_slot_count) * 4;
        if (tagged_slot_count != 0 and tagged_bytes - 8 > max_tagged_offset) {
            return error.FrameTooLarge;
        }
        if (int32_slot_count != 0 and tagged_bytes + int32_bytes - 4 > max_int32_offset) {
            return error.FrameTooLarge;
        }
        const raw_spill_bytes = tagged_bytes + int32_bytes;
        const aligned_spill_bytes = (raw_spill_bytes + 15) & ~@as(u64, 15);
        if (aligned_spill_bytes > std.math.maxInt(u32) - callee_save_bytes) {
            return error.FrameTooLarge;
        }
        const spill_bytes: u32 = @intCast(aligned_spill_bytes);
        return .{
            .tagged_slot_count = tagged_slot_count,
            .int32_slot_count = int32_slot_count,
            .tagged_start = 0,
            .int32_start = @intCast(tagged_bytes),
            .spill_bytes = spill_bytes,
            .callee_save_start = spill_bytes,
            .native_frame_bytes = spill_bytes + callee_save_bytes,
        };
    }

    pub fn verify(self: FrameLayout) !void {
        const expected = try build(self.tagged_slot_count, self.int32_slot_count);
        if (!std.meta.eql(self, expected)) return error.InvalidLowering;
    }

    pub fn taggedByteOffset(self: FrameLayout, slot: u32) !u32 {
        if (slot >= self.tagged_slot_count) return error.InvalidLocation;
        return self.tagged_start + slot * 8;
    }

    pub fn int32ByteOffset(self: FrameLayout, slot: u32) !u32 {
        if (slot >= self.int32_slot_count) return error.InvalidLocation;
        return self.int32_start + slot * 4;
    }
};

pub fn valueRegister(index: u8) !a64.Reg {
    if (index >= value_registers.len) return error.UnsupportedRegisterCount;
    return value_registers[index];
}

pub const EdgeMoves = struct {
    move_start: u32,
    move_count: u32,
};

pub const Plan = struct {
    allocator: std.mem.Allocator,
    frame: FrameLayout,
    locations: []Location,
    edges: []EdgeMoves,
    moves: []Move,

    pub fn build(
        allocator: std.mem.Allocator,
        graph: *const ir.Graph,
        specialization: *const specialize.Plan,
        representations: *const representation.Plan,
        homes: *const deopt_physical.Homes,
        allocated: *const allocation.Plan,
    ) !Plan {
        try allocated.verify(graph, specialization, representations, homes);
        if (allocated.register_count > value_registers.len) {
            return error.UnsupportedRegisterCount;
        }
        const frame = try FrameLayout.build(
            allocated.tagged_slot_count,
            allocated.int32_slot_count,
        );
        const locations = try allocator.alloc(Location, graph.nodes.len);
        errdefer allocator.free(locations);
        try mapLocations(allocated, frame, locations);
        const edges = try allocator.alloc(EdgeMoves, graph.edges.len);
        errdefer allocator.free(edges);
        var moves: std.ArrayListUnmanaged(Move) = .empty;
        defer moves.deinit(allocator);
        try buildEdgeMoves(
            allocator,
            graph,
            representations,
            locations,
            edges,
            &moves,
        );
        const move_slice = try moves.toOwnedSlice(allocator);
        errdefer allocator.free(move_slice);

        var plan: Plan = .{
            .allocator = allocator,
            .frame = frame,
            .locations = locations,
            .edges = edges,
            .moves = move_slice,
        };
        errdefer plan.deinit();
        try plan.verify(graph, specialization, representations, homes, allocated);
        return plan;
    }

    pub fn deinit(self: *Plan) void {
        self.allocator.free(self.locations);
        self.allocator.free(self.edges);
        self.allocator.free(self.moves);
        self.* = undefined;
    }

    pub fn verify(
        self: *const Plan,
        graph: *const ir.Graph,
        specialization: *const specialize.Plan,
        representations: *const representation.Plan,
        homes: *const deopt_physical.Homes,
        allocated: *const allocation.Plan,
    ) !void {
        try allocated.verify(graph, specialization, representations, homes);
        if (allocated.register_count > value_registers.len or
            self.locations.len != graph.nodes.len or self.edges.len != graph.edges.len)
        {
            return error.InvalidLowering;
        }
        const expected_frame = try FrameLayout.build(
            allocated.tagged_slot_count,
            allocated.int32_slot_count,
        );
        if (!std.meta.eql(self.frame, expected_frame)) return error.InvalidLowering;

        const expected_locations = try self.allocator.alloc(Location, graph.nodes.len);
        defer self.allocator.free(expected_locations);
        try mapLocations(allocated, expected_frame, expected_locations);
        for (self.locations, expected_locations) |actual, expected| {
            if (!parallel_moves.eql(actual, expected)) return error.InvalidLowering;
        }

        const expected_edges = try self.allocator.alloc(EdgeMoves, graph.edges.len);
        defer self.allocator.free(expected_edges);
        var expected_moves: std.ArrayListUnmanaged(Move) = .empty;
        defer expected_moves.deinit(self.allocator);
        try buildEdgeMoves(
            self.allocator,
            graph,
            representations,
            expected_locations,
            expected_edges,
            &expected_moves,
        );
        if (self.moves.len != expected_moves.items.len) {
            return error.InvalidLowering;
        }
        for (self.edges, expected_edges) |actual, expected| {
            if (actual.move_start != expected.move_start or
                actual.move_count != expected.move_count)
            {
                return error.InvalidLowering;
            }
        }
        for (self.moves, expected_moves.items) |actual, expected| {
            if (!moveEql(actual, expected)) return error.InvalidLowering;
        }
    }
};

fn mapLocations(
    allocated: *const allocation.Plan,
    frame: FrameLayout,
    locations: []Location,
) !void {
    if (locations.len != allocated.locations.len) return error.MalformedGraph;
    for (allocated.locations, locations) |source, *destination| {
        destination.* = switch (source) {
            .none => .none,
            .immediate => |immediate| .{ .immediate = immediate },
            .register => |register| .{ .register = try valueRegister(register) },
            .tagged_stack => |slot| .{ .tagged_stack = try frame.taggedByteOffset(slot) },
            .int32_stack => |slot| .{ .int32_stack = try frame.int32ByteOffset(slot) },
        };
    }
}

fn buildEdgeMoves(
    allocator: std.mem.Allocator,
    graph: *const ir.Graph,
    representations: *const representation.Plan,
    locations: []const Location,
    edges: []EdgeMoves,
    moves: *std.ArrayListUnmanaged(Move),
) !void {
    if (locations.len != graph.nodes.len or edges.len != graph.edges.len or
        representations.outputs.len != graph.nodes.len)
    {
        return error.MalformedGraph;
    }
    var assignments: std.ArrayListUnmanaged(parallel_moves.Assignment) = .empty;
    defer assignments.deinit(allocator);
    for (graph.edges, edges) |edge, *edge_moves| {
        if (edge.to >= graph.blocks.len) return error.MalformedGraph;
        const target = graph.blocks[edge.to];
        const params = try checkedRange(graph.params.len, target.param_start, target.param_count);
        const arguments = try checkedRange(
            graph.inputs.len,
            edge.argument_start,
            edge.argument_count,
        );
        if (params.len != arguments.len) return error.MalformedGraph;
        assignments.clearRetainingCapacity();
        for (0..params.len) |offset| {
            const parameter = graph.params[params.start + offset];
            if (parameter.value >= locations.len) return error.MalformedGraph;
            const destination = locations[parameter.value];
            if (destination == .none or destination == .immediate) continue;
            const input_index = arguments.start + offset;
            const producer = graph.inputs[input_index];
            if (producer >= locations.len) return error.MalformedGraph;
            const conversion = try representations.conversionAt(graph, input_index);
            try assignments.append(allocator, .{
                .source = locations[producer],
                .destination = destination,
                .source_kind = representations.outputs[producer],
                .destination_kind = representations.outputs[parameter.value],
                .conversion = conversion,
            });
        }
        const move_start = try indexU32(moves.items.len);
        try parallel_moves.resolve(allocator, assignments.items, cycle_scratch, moves);
        edge_moves.* = .{
            .move_start = move_start,
            .move_count = try indexU32(moves.items.len - move_start),
        };
    }
}

const Range = struct {
    start: usize,
    len: usize,

    fn end(self: Range) usize {
        return self.start + self.len;
    }
};

fn checkedRange(total: usize, raw_start: anytype, raw_len: anytype) !Range {
    const start: usize = @intCast(raw_start);
    const len: usize = @intCast(raw_len);
    if (start > total or len > total - start) return error.MalformedGraph;
    return .{ .start = start, .len = len };
}

fn indexU32(index: usize) !u32 {
    if (index > std.math.maxInt(u32)) return error.GraphTooLarge;
    return @intCast(index);
}

fn moveEql(lhs: Move, rhs: Move) bool {
    return lhs.source_kind == rhs.source_kind and
        lhs.destination_kind == rhs.destination_kind and
        lhs.conversion == rhs.conversion and
        parallel_moves.eql(lhs.source, rhs.source) and
        parallel_moves.eql(lhs.destination, rhs.destination);
}
