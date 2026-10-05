//! Block-local allocation for the shared integer SSA backend.
const std = @import("std");
const ir = @import("ir.zig");

pub const max_registers = 4;
pub const Mode = enum { scratch, linear_scan };
pub const Options = struct { mode: Mode = .linear_scan, register_count: u8 = max_registers };
pub const Location = union(enum) { none, register: u8, spill: u32 };
pub const LiveRange = struct { block: u32, start: u32, end: u32, uses: u32 = 0 };

pub const Plan = struct {
    allocator: std.mem.Allocator,
    locations: []Location,
    ranges: []LiveRange,
    register_count: u8,
    spill_slot_count: u32,

    pub fn build(a: std.mem.Allocator, graph: ir.Graph, options: Options) !Plan {
        try graph.verify();
        if (options.register_count > max_registers) return error.PrototypeLimit;
        const locations = try a.alloc(Location, graph.types.len);
        errdefer a.free(locations);
        @memset(locations, .none);
        const ranges = try a.alloc(LiveRange, graph.types.len);
        errdefer a.free(ranges);
        computeRanges(graph, ranges);
        var plan: Plan = .{
            .allocator = a,
            .locations = locations,
            .ranges = ranges,
            .register_count = if (options.mode == .scratch) 0 else options.register_count,
            .spill_slot_count = 0,
        };
        if (options.mode == .scratch) {
            for (locations, 0..) |*location, i| location.* = .{ .spill = @intCast(i) };
            plan.spill_slot_count = @intCast(locations.len);
        } else for (graph.blocks) |block| {
            var owners: [max_registers]?ir.Value = @splat(null);
            for (block.params) |value| plan.assignRegister(value, &owners);
            for (block.nodes) |node| {
                if (node.out) |value| plan.assignRegister(value, &owners);
            }
            // Assign whole-lifetime spills only after register selection, so
            // evicted intervals get a definition-time home, not a late copy.
            var spill_ends: [ir.max_values]?u32 = @splat(null);
            for (block.params) |value| plan.assignSpill(value, &spill_ends);
            for (block.nodes) |node| {
                if (node.out) |value| plan.assignSpill(value, &spill_ends);
            }
        }
        try plan.verify(graph);
        return plan;
    }

    pub fn deinit(self: *Plan) void {
        self.allocator.free(self.locations);
        self.allocator.free(self.ranges);
        self.* = undefined;
    }

    pub fn verify(self: *const Plan, graph: ir.Graph) !void {
        try graph.verify();
        if (self.locations.len != graph.types.len or self.ranges.len != graph.types.len or
            self.register_count > max_registers or self.spill_slot_count > graph.types.len)
            return error.InvalidAllocation;
        const expected = try self.allocator.alloc(LiveRange, graph.types.len);
        defer self.allocator.free(expected);
        computeRanges(graph, expected);
        for (self.locations, self.ranges, expected, 0..) |location, range, actual, i| {
            if (!std.meta.eql(range, actual)) return error.InvalidAllocation;
            switch (location) {
                .none => if (range.uses != 0) {
                    return error.InvalidAllocation;
                },
                .register => |register| if (register >= self.register_count) {
                    return error.InvalidAllocation;
                },
                .spill => |slot| if (slot >= self.spill_slot_count) {
                    return error.InvalidAllocation;
                },
            }
            if (location == .none) continue;
            for (self.locations[0..i], self.ranges[0..i]) |other, other_range| {
                // Include dead definitions with a home: their writes must not
                // clobber another value, even though they have no later use.
                if (std.meta.eql(location, other) and range.block == other_range.block and
                    range.start <= other_range.end and other_range.start <= range.end)
                    return error.InvalidAllocation;
            }
        }
    }

    fn assignRegister(self: *Plan, value: ir.Value, owners: *[max_registers]?ir.Value) void {
        const range = self.ranges[value];
        if (range.uses == 0 or self.register_count == 0) return;
        for (owners[0..self.register_count], 0..) |*owner, register| {
            if (owner.* == null or self.ranges[owner.*.?].end < range.start) {
                owner.* = value;
                self.locations[value] = .{ .register = @intCast(register) };
                return;
            }
        }
        var victim_register: usize = 0;
        for (owners[1..self.register_count], 1..) |owner, register| {
            if (self.ranges[owner.?].end > self.ranges[owners[victim_register].?].end)
                victim_register = register;
        }
        const victim = owners[victim_register].?;
        if (self.ranges[victim].end <= range.end) return;
        self.locations[victim] = .none;
        owners[victim_register] = value;
        self.locations[value] = .{ .register = @intCast(victim_register) };
    }

    fn assignSpill(self: *Plan, value: ir.Value, ends: *[ir.max_values]?u32) void {
        const range = self.ranges[value];
        if (range.uses == 0 or self.locations[value] != .none) return;
        for (ends, 0..) |*end, slot| {
            if (end.* == null or end.*.? < range.start) {
                end.* = range.end;
                self.locations[value] = .{ .spill = @intCast(slot) };
                self.spill_slot_count = @max(self.spill_slot_count, @as(u32, @intCast(slot + 1)));
                return;
            }
        }
    }
};

fn computeRanges(graph: ir.Graph, ranges: []LiveRange) void {
    for (graph.blocks, 0..) |block, block_index| {
        for (block.params) |value| ranges[value] = .{ .block = @intCast(block_index), .start = 0, .end = 0 };
        for (block.nodes, 0..) |node, i| {
            // Operands and guard captures are read before an output is written.
            // Dedicated emitter scratch registers make dying-input reuse safe.
            const read_position: u32 = @intCast(2 * i + 1);
            switch (node.op) {
                .constant => {},
                .guard => {
                    use(ranges, node.lhs, read_position);
                    for (node.exit.?.values) |value| use(ranges, value, read_position);
                },
                .sext_i32, .zext_i32, .trunc_i64 => use(ranges, node.lhs, read_position),
                else => {
                    use(ranges, node.lhs, read_position);
                    use(ranges, node.rhs, read_position);
                },
            }
            if (node.out) |value| ranges[value] = .{ .block = @intCast(block_index), .start = read_position + 1, .end = read_position + 1 };
        }
        const terminal_position: u32 = @intCast(2 * block.nodes.len + 1);
        switch (block.terminator) {
            .return_ => |value| use(ranges, value, terminal_position),
            .jump => |edge| for (edge.args) |value| {
                use(ranges, value, terminal_position);
            },
            .branch => |branch| {
                use(ranges, branch.condition, terminal_position);
                for (branch.taken.args) |value| use(ranges, value, terminal_position);
                for (branch.fallthrough.args) |value| use(ranges, value, terminal_position);
            },
        }
    }
}

fn use(ranges: []LiveRange, value: ir.Value, position: u32) void {
    ranges[value].end = position;
    ranges[value].uses += 1;
}
