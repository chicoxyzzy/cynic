//! Deterministic abstract register allocation for Ohaimark.
//!
//! The plan assigns target-independent general-purpose register ids and
//! representation-partitioned spill slots. Constants are rematerialized and
//! physical deopt homes remain stable: an ordinary spill reuses its deopt home
//! when one exists, while register-resident values still retain that separate
//! definition-time recovery copy.

const std = @import("std");

const schedule = @import("allocation_schedule.zig");
const control_fusion = @import("control_fusion.zig");
const deopt_physical = @import("deopt_physical.zig");
const ir = @import("ir.zig");
const representation = @import("representation.zig");
const specialize = @import("specialize.zig");

pub const Options = struct {
    register_count: u8,
};

pub const Location = union(enum) {
    none,
    immediate: ir.Immediate,
    register: u8,
    tagged_stack: u32,
    int32_stack: u32,
};

pub const LiveRange = schedule.LiveRange;

pub const Input = struct {
    source: Location,
    conversion: representation.Conversion,
};

pub const Plan = struct {
    allocator: std.mem.Allocator,
    locations: []Location,
    ranges: []?LiveRange,
    register_count: u8,
    tagged_slot_count: u32,
    int32_slot_count: u32,

    pub fn build(
        allocator: std.mem.Allocator,
        graph: *const ir.Graph,
        specialization: *const specialize.Plan,
        representations: *const representation.Plan,
        fused_control: *const control_fusion.Plan,
        homes: *const deopt_physical.Homes,
        options: Options,
    ) !Plan {
        try representations.verify(graph, specialization);
        try fused_control.verify(graph, specialization, representations);
        try validateHomes(graph, specialization, representations, homes);

        const locations = try allocator.alloc(Location, graph.nodes.len);
        errdefer allocator.free(locations);
        const ranges = try allocator.alloc(?LiveRange, graph.nodes.len);
        errdefer allocator.free(ranges);
        const counts = try compute(
            allocator,
            graph,
            specialization,
            representations,
            fused_control,
            homes,
            options,
            locations,
            ranges,
        );

        var plan: Plan = .{
            .allocator = allocator,
            .locations = locations,
            .ranges = ranges,
            .register_count = options.register_count,
            .tagged_slot_count = counts.tagged,
            .int32_slot_count = counts.int32,
        };
        errdefer plan.deinit();
        try plan.verify(graph, specialization, representations, fused_control, homes);
        return plan;
    }

    pub fn deinit(self: *Plan) void {
        self.allocator.free(self.locations);
        self.allocator.free(self.ranges);
        self.* = undefined;
    }

    pub fn verify(
        self: *const Plan,
        graph: *const ir.Graph,
        specialization: *const specialize.Plan,
        representations: *const representation.Plan,
        fused_control: *const control_fusion.Plan,
        homes: *const deopt_physical.Homes,
    ) !void {
        try representations.verify(graph, specialization);
        try fused_control.verify(graph, specialization, representations);
        try validateHomes(graph, specialization, representations, homes);
        if (self.locations.len != graph.nodes.len or self.ranges.len != graph.nodes.len) {
            return error.InvalidAllocation;
        }

        const expected_locations = try self.allocator.alloc(Location, graph.nodes.len);
        defer self.allocator.free(expected_locations);
        const expected_ranges = try self.allocator.alloc(?LiveRange, graph.nodes.len);
        defer self.allocator.free(expected_ranges);
        const counts = try compute(
            self.allocator,
            graph,
            specialization,
            representations,
            fused_control,
            homes,
            .{ .register_count = self.register_count },
            expected_locations,
            expected_ranges,
        );
        if (self.tagged_slot_count != counts.tagged or
            self.int32_slot_count != counts.int32)
        {
            return error.InvalidAllocation;
        }
        for (self.locations, expected_locations) |actual, expected| {
            if (!locationEql(actual, expected)) return error.InvalidAllocation;
        }
        for (self.ranges, expected_ranges) |actual, expected| {
            if (!rangeEql(actual, expected)) return error.InvalidAllocation;
        }
    }

    pub fn nodeInput(
        self: *const Plan,
        graph: *const ir.Graph,
        representations: *const representation.Plan,
        node_id: ir.ValueId,
        operand_index: usize,
    ) !Input {
        if (node_id >= graph.nodes.len) return error.MalformedGraph;
        const node = graph.nodes[node_id];
        const inputs = try checkedRange(graph.inputs.len, node.input_start, node.input_count);
        if (operand_index >= inputs.len) return error.MalformedGraph;
        return self.inputAt(graph, representations, inputs.start + operand_index);
    }

    pub fn inputAt(
        self: *const Plan,
        graph: *const ir.Graph,
        representations: *const representation.Plan,
        input_index: usize,
    ) !Input {
        if (self.locations.len != graph.nodes.len or input_index >= graph.inputs.len or
            representations.input_requirements.len != graph.inputs.len)
        {
            return error.MalformedGraph;
        }
        const producer = graph.inputs[input_index];
        if (producer >= self.locations.len) return error.MalformedGraph;
        const source = self.locations[producer];
        if (source == .none and representations.input_requirements[input_index] != .none) {
            return error.InvalidAllocation;
        }
        return .{
            .source = source,
            .conversion = try representations.conversionAt(graph, input_index),
        };
    }
};

const Counts = struct {
    tagged: u32,
    int32: u32,
};

fn compute(
    allocator: std.mem.Allocator,
    graph: *const ir.Graph,
    specialization: *const specialize.Plan,
    representations: *const representation.Plan,
    fused_control: *const control_fusion.Plan,
    homes: *const deopt_physical.Homes,
    options: Options,
    locations: []Location,
    ranges: []?LiveRange,
) !Counts {
    if (locations.len != graph.nodes.len or ranges.len != graph.nodes.len or
        specialization.node_info.len != graph.nodes.len or
        representations.outputs.len != graph.nodes.len)
    {
        return error.MalformedGraph;
    }
    @memset(locations, .none);
    try schedule.compute(allocator, graph, representations, fused_control, ranges);
    for (ranges, homes.values, 0..) |maybe_range, home, value_index| {
        if (!(try fused_control.valueIsElided(try valueId(value_index)))) continue;
        const range = maybe_range orelse return error.InvalidControlFusion;
        if (range.use_count != 0 or home != null) return error.InvalidControlFusion;
    }

    for (graph.nodes, specialization.node_info, representations.outputs, 0..) |
        node,
        info,
        output,
        value_index,
    | {
        if (immediateFor(node, info)) |immediate| {
            if (output == .none) return error.MalformedGraph;
            locations[value_index] = .{ .immediate = immediate };
        }
    }

    var candidates: std.ArrayListUnmanaged(ir.ValueId) = .empty;
    defer candidates.deinit(allocator);
    for (ranges, locations, 0..) |maybe_range, location, value_index| {
        const range = maybe_range orelse continue;
        if (range.use_count == 0 or location != .none) continue;
        try candidates.append(allocator, try valueId(value_index));
    }
    sortValues(candidates.items, ranges);
    const register_hints = try allocator.alloc(?ir.ValueId, graph.nodes.len);
    defer allocator.free(register_hints);
    try buildRegisterHints(allocator, graph, representations, register_hints);
    try allocateRegisters(
        allocator,
        candidates.items,
        ranges,
        locations,
        register_hints,
        options.register_count,
    );

    var spills: std.ArrayListUnmanaged(ir.ValueId) = .empty;
    defer spills.deinit(allocator);
    for (ranges, locations, homes.values, 0..) |maybe_range, location, home, value_index| {
        const range = maybe_range orelse continue;
        if (location != .none or (range.use_count == 0 and home == null)) continue;
        try spills.append(allocator, try valueId(value_index));
    }
    sortValues(spills.items, ranges);
    return allocateSpills(
        allocator,
        spills.items,
        ranges,
        locations,
        representations,
        homes,
    );
}

fn allocateRegisters(
    allocator: std.mem.Allocator,
    candidates: []const ir.ValueId,
    ranges: []const ?LiveRange,
    locations: []Location,
    register_hints: []const ?ir.ValueId,
    register_count: u8,
) !void {
    if (register_hints.len != locations.len) return error.MalformedGraph;
    const owners = try allocator.alloc(?ir.ValueId, register_count);
    defer allocator.free(owners);
    @memset(owners, null);

    for (candidates) |value| {
        const range = ranges[value] orelse return error.MalformedGraph;
        for (owners) |*owner| {
            if (owner.*) |active| {
                const active_range = ranges[active] orelse return error.MalformedGraph;
                if (active_range.end < range.start) owner.* = null;
            }
        }

        var free_register: ?usize = if (register_hints[value]) |source| blk: {
            if (source >= locations.len) return error.MalformedGraph;
            const preferred = switch (locations[source]) {
                .register => |register| register,
                .none, .immediate, .tagged_stack, .int32_stack => break :blk null,
            };
            if (preferred >= owners.len) return error.InvalidAllocation;
            break :blk if (owners[preferred] == null) preferred else null;
        } else null;
        for (owners, 0..) |owner, register| {
            if (free_register == null and owner == null) {
                free_register = register;
                break;
            }
        }
        if (free_register) |register| {
            owners[register] = value;
            locations[value] = .{ .register = @intCast(register) };
            continue;
        }
        if (owners.len == 0) continue;

        var victim_register: usize = 0;
        var victim = owners[0] orelse return error.MalformedGraph;
        for (owners[1..], 1..) |owner, register| {
            const active = owner orelse return error.MalformedGraph;
            const active_end = (ranges[active] orelse return error.MalformedGraph).end;
            const victim_end = (ranges[victim] orelse return error.MalformedGraph).end;
            if (active_end > victim_end or (active_end == victim_end and active > victim)) {
                victim_register = register;
                victim = active;
            }
        }
        const victim_range = ranges[victim] orelse return error.MalformedGraph;
        if (victim_range.end <= range.end) continue;
        locations[victim] = .none;
        locations[value] = .{ .register = @intCast(victim_register) };
        owners[victim_register] = value;
    }
}

/// A single-predecessor block argument can reuse its incoming register without
/// constraining any merge. Keep the hint conservative: representation changes
/// and edge conversions still need an explicit transfer.
fn buildRegisterHints(
    allocator: std.mem.Allocator,
    graph: *const ir.Graph,
    representations: *const representation.Plan,
    hints: []?ir.ValueId,
) !void {
    if (hints.len != graph.nodes.len or
        representations.outputs.len != graph.nodes.len or
        representations.input_requirements.len != graph.inputs.len)
    {
        return error.MalformedGraph;
    }
    @memset(hints, null);
    const incoming = try allocator.alloc(?usize, graph.blocks.len);
    defer allocator.free(incoming);
    @memset(incoming, null);

    for (graph.edges, 0..) |edge, edge_index| {
        if (edge.to >= graph.blocks.len) return error.MalformedGraph;
        if (graph.blocks[edge.to].predecessor_count != 1) continue;
        if (incoming[edge.to] != null) return error.MalformedGraph;
        incoming[edge.to] = edge_index;
    }

    for (graph.blocks, 0..) |block, block_index| {
        if (!block.reachable or block.predecessor_count != 1) continue;
        const edge_index = incoming[block_index] orelse return error.MalformedGraph;
        const edge = graph.edges[edge_index];
        const params = try checkedRange(graph.params.len, block.param_start, block.param_count);
        const arguments = try checkedRange(
            graph.inputs.len,
            edge.argument_start,
            edge.argument_count,
        );
        if (params.len != arguments.len) return error.MalformedGraph;
        for (0..params.len) |offset| {
            const parameter = graph.params[params.start + offset].value;
            const input_index = arguments.start + offset;
            const source = graph.inputs[input_index];
            if (parameter >= hints.len or source >= hints.len) return error.MalformedGraph;
            if (representations.outputs[parameter] != representations.outputs[source] or
                try representations.conversionAt(graph, input_index) != .none)
            {
                continue;
            }
            hints[parameter] = source;
        }
    }
}

fn allocateSpills(
    allocator: std.mem.Allocator,
    spills: []const ir.ValueId,
    ranges: []const ?LiveRange,
    locations: []Location,
    representations: *const representation.Plan,
    homes: *const deopt_physical.Homes,
) !Counts {
    var tagged_ends: std.ArrayListUnmanaged(usize) = .empty;
    defer tagged_ends.deinit(allocator);
    var int32_ends: std.ArrayListUnmanaged(usize) = .empty;
    defer int32_ends.deinit(allocator);

    for (spills) |value| {
        const range = ranges[value] orelse return error.MalformedGraph;
        if (homes.values[value]) |home| {
            locations[value] = switch (home) {
                .tagged_stack => |slot| .{ .tagged_stack = slot },
                .int32_stack => |slot| .{ .int32_stack = slot },
            };
            continue;
        }
        locations[value] = switch (representations.outputs[value]) {
            .tagged => .{ .tagged_stack = try allocateSpillSlot(
                allocator,
                &tagged_ends,
                homes.tagged_slot_count,
                range,
            ) },
            .int32 => .{ .int32_stack = try allocateSpillSlot(
                allocator,
                &int32_ends,
                homes.int32_slot_count,
                range,
            ) },
            .none => return error.MalformedGraph,
        };
    }
    return .{
        .tagged = try totalSlotCount(homes.tagged_slot_count, tagged_ends.items.len),
        .int32 = try totalSlotCount(homes.int32_slot_count, int32_ends.items.len),
    };
}

fn allocateSpillSlot(
    allocator: std.mem.Allocator,
    ends: *std.ArrayListUnmanaged(usize),
    base: u32,
    range: LiveRange,
) !u32 {
    for (ends.items, 0..) |end, slot| {
        if (end >= range.start) continue;
        ends.items[slot] = range.end;
        return try addSlot(base, slot);
    }
    const slot = ends.items.len;
    try ends.append(allocator, range.end);
    return addSlot(base, slot);
}

fn totalSlotCount(base: u32, additional: usize) !u32 {
    if (additional > @as(usize, std.math.maxInt(u32) - base)) return error.GraphTooLarge;
    return base + @as(u32, @intCast(additional));
}

fn addSlot(base: u32, slot: usize) !u32 {
    if (slot >= @as(usize, std.math.maxInt(u32) - base)) return error.GraphTooLarge;
    return base + @as(u32, @intCast(slot));
}

fn validateHomes(
    graph: *const ir.Graph,
    specialization: *const specialize.Plan,
    representations: *const representation.Plan,
    homes: *const deopt_physical.Homes,
) !void {
    if (homes.values.len != graph.nodes.len or specialization.node_info.len != graph.nodes.len) {
        return error.InvalidMetadata;
    }
    const tagged_count: usize = @intCast(homes.tagged_slot_count);
    const int32_count: usize = @intCast(homes.int32_slot_count);
    if (tagged_count > homes.values.len or int32_count > homes.values.len or
        tagged_count > homes.values.len - int32_count)
    {
        return error.InvalidMetadata;
    }
    const tagged_claimed = try homes.allocator.alloc(bool, tagged_count);
    defer homes.allocator.free(tagged_claimed);
    @memset(tagged_claimed, false);
    const int32_claimed = try homes.allocator.alloc(bool, int32_count);
    defer homes.allocator.free(int32_claimed);
    @memset(int32_claimed, false);

    for (homes.values, graph.nodes, specialization.node_info, 0..) |home, node, info, value| {
        const existing = home orelse continue;
        if (immediateFor(node, info) != null) return error.InvalidMetadata;
        switch (existing) {
            .tagged_stack => |slot| {
                if (representations.outputs[value] != .tagged or slot >= tagged_claimed.len or
                    tagged_claimed[slot])
                {
                    return error.InvalidMetadata;
                }
                tagged_claimed[slot] = true;
            },
            .int32_stack => |slot| {
                if (representations.outputs[value] != .int32 or slot >= int32_claimed.len or
                    int32_claimed[slot])
                {
                    return error.InvalidMetadata;
                }
                int32_claimed[slot] = true;
            },
        }
    }
    for (tagged_claimed) |claimed| if (!claimed) return error.InvalidMetadata;
    for (int32_claimed) |claimed| if (!claimed) return error.InvalidMetadata;
}

fn immediateFor(node: ir.Node, info: specialize.NodeInfo) ?ir.Immediate {
    if (info.folded) |immediate| return immediate;
    if (node.kind != .constant) return null;
    return switch (node.payload) {
        .immediate => |immediate| immediate,
        else => null,
    };
}

fn sortValues(values: []ir.ValueId, ranges: []const ?LiveRange) void {
    std.mem.sort(ir.ValueId, values, RangeOrder{ .ranges = ranges }, RangeOrder.lessThan);
}

const RangeOrder = struct {
    ranges: []const ?LiveRange,

    fn lessThan(self: RangeOrder, lhs: ir.ValueId, rhs: ir.ValueId) bool {
        const lhs_range = self.ranges[lhs].?;
        const rhs_range = self.ranges[rhs].?;
        return lhs_range.start < rhs_range.start or
            (lhs_range.start == rhs_range.start and lhs < rhs);
    }
};

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

fn valueId(index: usize) !ir.ValueId {
    if (index > std.math.maxInt(ir.ValueId)) return error.GraphTooLarge;
    return @intCast(index);
}

fn locationEql(lhs: Location, rhs: Location) bool {
    if (std.meta.activeTag(lhs) != std.meta.activeTag(rhs)) return false;
    return switch (lhs) {
        .none => true,
        .immediate => |value| std.meta.eql(value, rhs.immediate),
        .register => |value| value == rhs.register,
        .tagged_stack => |value| value == rhs.tagged_stack,
        .int32_stack => |value| value == rhs.int32_stack,
    };
}

fn rangeEql(lhs: ?LiveRange, rhs: ?LiveRange) bool {
    if (lhs == null or rhs == null) return lhs == null and rhs == null;
    return std.meta.eql(lhs.?, rhs.?);
}
