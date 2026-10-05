//! Developer-only Ohaimark consumer of the language-neutral backend. JS tags
//! and Lantern recovery stay here; generated entries cannot allocate or call.
const std = @import("std");
const Chunk = @import("../../bytecode/chunk.zig").Chunk;
const evaluator = @import("evaluator.zig");
const Value = @import("../value.zig").Value;
const ir = @import("ir.zig");
const specialize = @import("specialize.zig");
const low = @import("../jit/backend/ir.zig");
const native = @import("../jit/backend/native.zig");
pub const CodeAllocator = @import("../jit/code_alloc.zig").CodeAllocator;
pub const supported = @import("../jit/code_alloc.zig").supported;

const missing = std.math.maxInt(u32);
const Recovery = struct { node: ir.ValueId, bytecode_offset: u32, registers: []const u8 };

pub const Entry = struct {
    accumulator: Value,
    registers: []const Value,
    this_value: Value = Value.undefined_,
    /// Prototype block visits, not Realm fuel or evaluator instruction steps.
    block_budget: u32,
};

pub const Program = struct {
    allocator: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    graph: low.Graph,
    compiled: native.Compiled,
    entry_roles: []const ir.ParamRole,
    recoveries: []const Recovery,
    register_count: u8,

    pub fn build(a: std.mem.Allocator, owner: *CodeAllocator, chunk: *const Chunk) !Program {
        if (chunk.code.len > 16 * 1024 or chunk.register_count >= low.max_arguments) return error.PrototypeLimit;
        if (chunk.handlers.len != 0) return error.UnsupportedNode;
        var source = try ir.Graph.build(a, chunk);
        defer source.deinit();
        if (source.entry_environment_slots != null) return error.UnsupportedNode;
        if (source.nodes.len > low.max_values or source.blocks.len > low.max_blocks) return error.PrototypeLimit;
        var plan = try specialize.Plan.build(a, &source);
        defer plan.deinit();
        var arena = std.heap.ArenaAllocator.init(a);
        errdefer arena.deinit();
        const allocator = arena.allocator();
        var builder: Builder = .{ .a = allocator, .source = &source, .plan = &plan, .chunk = chunk };
        builder.values = try allocator.alloc(low.Value, source.nodes.len);
        @memset(builder.values, missing);
        builder.block_map = try allocator.alloc(u32, source.blocks.len);
        @memset(builder.block_map, missing);
        for (source.blocks, 0..) |block, i| {
            if (!block.reachable) continue;
            builder.block_map[i] = @intCast(builder.blocks.items.len);
            const params = try allocator.alloc(low.Value, source.blockParams(i).len);
            for (source.blockParams(i), params) |param, *out| {
                out.* = try builder.value(.i64);
                builder.values[param.value] = out.*;
            }
            try builder.blocks.append(allocator, .{ .params = params });
        }
        if (builder.blocks.items.len == 0) return error.UnsupportedNode;
        for (source.blocks, 0..) |block, i| {
            if (block.reachable) try builder.lowerBlock(i);
        }
        const roles = try allocator.alloc(ir.ParamRole, source.blockParams(0).len);
        for (roles, source.blockParams(0)) |*role, param| role.* = param.role;
        const argument_types = try allocator.alloc(low.Type, roles.len);
        @memset(argument_types, .i64);
        const graph: low.Graph = .{
            .types = builder.types.items,
            .blocks = builder.blocks.items,
            .argument_types = argument_types,
            .result_type = .i64,
        };
        try graph.verify();
        return .{
            .allocator = a,
            .arena = arena,
            .graph = graph,
            .compiled = try native.compile(a, owner, graph),
            .entry_roles = roles,
            .recoveries = builder.recoveries.items,
            .register_count = chunk.register_count,
        };
    }

    pub fn deinit(self: *Program) void {
        self.compiled.deinit();
        self.arena.deinit();
        self.* = undefined;
    }

    /// No GC or JS re-entry occurs here. Returned values and recovery records
    /// are detached, not GC roots: resume immediately, or root their heap
    /// values before any intervening operation that may collect.
    pub fn run(self: *const Program, entry: Entry) !evaluator.Outcome {
        if (entry.registers.len != self.register_count) return error.ArgumentCount;
        if (entry.block_budget > native.max_budget) return error.PrototypeLimit;
        var args: [low.max_arguments]u64 = undefined;
        for (self.entry_roles, 0..) |role, i| args[i] = switch (role) {
            .accumulator => entry.accumulator.bits,
            .register => |register| entry.registers[register].bits,
        };
        var outcome = try self.compiled.runOutcome(args[0..self.entry_roles.len], entry.block_budget);
        defer outcome.deinit();
        switch (outcome) {
            .returned => |bits| return .{ .returned = .{ .bits = bits } },
            .exited => |exit| {
                if (exit.id >= self.recoveries.len) return error.InvalidMetadata;
                const recovery = self.recoveries[exit.id];
                if (exit.values.len != recovery.registers.len + 1) return error.InvalidMetadata;
                const registers = try self.allocator.alloc(Value, self.register_count);
                @memset(registers, Value.undefined_);
                for (recovery.registers, exit.values[1..]) |register, bits| registers[register] = .{ .bits = bits };
                return .{ .deopt = .{
                    .allocator = self.allocator,
                    .node = recovery.node,
                    .bytecode_offset = recovery.bytecode_offset,
                    .accumulator = .{ .bits = exit.values[0] },
                    .registers = registers,
                    .this_value = entry.this_value,
                } };
            },
        }
    }
};

const Builder = struct {
    a: std.mem.Allocator,
    source: *const ir.Graph,
    plan: *const specialize.Plan,
    chunk: *const Chunk,
    values: []low.Value = &.{},
    block_map: []u32 = &.{},
    types: std.ArrayList(low.Type) = .empty,
    blocks: std.ArrayList(low.Block) = .empty,
    recoveries: std.ArrayList(Recovery) = .empty,
    nodes: std.ArrayList(low.Node) = .empty,

    fn value(self: *Builder, ty: low.Type) !low.Value {
        if (self.types.items.len >= low.max_values) return error.PrototypeLimit;
        const id: low.Value = @intCast(self.types.items.len);
        try self.types.append(self.a, ty);
        return id;
    }

    fn get(self: *Builder, source: ir.ValueId) !low.Value {
        if (source >= self.values.len or self.values[source] == missing) return error.UnsupportedNode;
        return self.values[source];
    }

    fn constant(self: *Builder, ty: low.Type, bits: u64) !low.Value {
        const out = try self.value(ty);
        try self.nodes.append(self.a, .{ .op = .constant, .out = out, .immediate = bits });
        return out;
    }

    fn binary(self: *Builder, op: low.Op, lhs: low.Value, rhs: low.Value) !low.Value {
        const ty: low.Type = switch (op) {
            .add, .sub, .mul, .bit_and, .bit_or => self.types.items[lhs],
            else => .i32,
        };
        const out = try self.value(ty);
        try self.nodes.append(self.a, .{ .op = op, .out = out, .lhs = lhs, .rhs = rhs });
        return out;
    }

    fn convert(self: *Builder, op: low.Op, input: low.Value) !low.Value {
        const out = try self.value(if (op == .trunc_i64) .i32 else .i64);
        try self.nodes.append(self.a, .{ .op = op, .out = out, .lhs = input });
        return out;
    }

    fn guard(self: *Builder, predicate: low.Value, exit: low.SideExit) !void {
        try self.nodes.append(self.a, .{ .op = .guard, .lhs = predicate, .exit = exit });
    }

    fn hasTag(self: *Builder, input: low.Value, tag: u16) !low.Value {
        const mask = try self.constant(.i64, 0xffff_0000_0000_0000);
        const actual = try self.binary(.bit_and, input, mask);
        return self.binary(.eq, actual, try self.constant(.i64, @as(u64, tag) << 48));
    }

    fn unbox(self: *Builder, input: low.Value, exit: low.SideExit) !low.Value {
        try self.guard(try self.hasTag(input, Value.tag_int32), exit);
        return self.convert(.trunc_i64, input);
    }

    fn box(self: *Builder, input: low.Value, tag: u16) !low.Value {
        return self.binary(.bit_or, try self.convert(.zext_i32, input), try self.constant(.i64, @as(u64, tag) << 48));
    }

    fn sideExit(self: *Builder, node_id: ir.ValueId) !low.SideExit {
        const node = self.source.nodes[node_id];
        const state_index = node.frame_state orelse return error.InvalidMetadata;
        if (state_index >= self.source.frame_states.len) return error.InvalidMetadata;
        const state = self.source.frame_states[state_index];
        const slots = self.source.frameSlots(state);
        if (slots.len + 1 > low.max_arguments) return error.PrototypeLimit;
        const captures = try self.a.alloc(low.Value, slots.len + 1);
        captures[0] = try self.get(state.accumulator);
        const registers = try self.a.alloc(u8, slots.len);
        for (slots, registers, captures[1..]) |slot, *register, *capture| {
            if (slot.register >= self.source.register_count) return error.InvalidMetadata;
            register.* = slot.register;
            capture.* = try self.get(slot.value);
        }
        const id: u32 = @intCast(self.recoveries.items.len);
        try self.recoveries.append(self.a, .{ .node = node_id, .bytecode_offset = state.bytecode_offset, .registers = registers });
        return .{ .id = id, .values = captures };
    }

    fn immediate(self: *Builder, immediate_value: ir.Immediate) !low.Value {
        const js: Value = switch (immediate_value) {
            .undefined_ => Value.undefined_,
            .null_ => Value.null_,
            .true_ => Value.true_,
            .false_ => Value.false_,
            .int32 => |i| Value.fromInt32(i),
            .constant_pool => |index| if (index < self.chunk.constants.len) self.chunk.constants[index] else return error.InvalidMetadata,
            .hole => return error.UnsupportedNode,
        };
        // No compiled-code GC roots in this experiment. Heap constants must
        // remain in the production tier, never embedded as stale addresses.
        if (js.isHeapValue() or js.isHole()) return error.UnsupportedNode;
        return self.constant(.i64, js.bits);
    }

    fn edge(self: *Builder, edge_value: ir.Edge) !low.Edge {
        if (edge_value.to >= self.block_map.len or self.block_map[edge_value.to] == missing) return error.InvalidMetadata;
        const source_args = self.source.edgeArguments(edge_value);
        const args = try self.a.alloc(low.Value, source_args.len);
        for (args, source_args) |*arg, source| arg.* = try self.get(source);
        return .{ .target = self.block_map[edge_value.to], .args = args };
    }

    fn condition(self: *Builder, node_id: ir.ValueId, input_id: ir.ValueId) !low.Value {
        const input = try self.get(input_id);
        const type_info = self.plan.node_info[input_id].result_type;
        if (!type_info.isSubsetOf(specialize.Type.int32.merge(specialize.Type.boolean))) {
            const valid = try self.binary(.bit_or, try self.hasTag(input, Value.tag_int32), try self.hasTag(input, Value.tag_bool));
            try self.guard(valid, try self.sideExit(node_id));
        }
        return self.convert(.trunc_i64, input);
    }

    fn lowerBlock(self: *Builder, block_index: usize) !void {
        self.nodes = .empty;
        const block = self.source.blocks[block_index];
        var terminator: ?low.Terminator = null;
        const start: usize = block.node_start;
        for (self.source.nodes[start..][0..block.node_count], start..) |node, raw_id| {
            const id: ir.ValueId = @intCast(raw_id);
            const inputs = self.source.nodeInputs(id);
            const info = self.plan.node_info[id];
            if (info.folded) |folded| {
                self.values[id] = try self.immediate(folded);
                continue;
            }
            switch (node.kind) {
                .constant => self.values[id] = try self.immediate(node.payload.immediate),
                .add, .sub, .mul, .less_than, .strict_eq => {
                    // The explicit developer path forces Int32 speculation,
                    // including cold inputs. Production feedback policy is
                    // unchanged; each operand is guarded before computation.
                    if (inputs.len != 2) return error.UnsupportedNode;
                    const exit = try self.sideExit(id);
                    const lhs = try self.unbox(try self.get(inputs[0]), exit);
                    const rhs = try self.unbox(try self.get(inputs[1]), exit);
                    if (node.kind == .less_than or node.kind == .strict_eq) {
                        self.values[id] = try self.box(try self.binary(if (node.kind == .less_than) .lt_s else .eq, lhs, rhs), Value.tag_bool);
                    } else {
                        // Widen first: every Int32 add/sub/mul fits exactly in
                        // Int64. Round-trip through Int32 detects overflow.
                        const op: low.Op = switch (node.kind) {
                            .add => .add,
                            .sub => .sub,
                            else => .mul,
                        };
                        const wide = try self.binary(op, try self.convert(.sext_i32, lhs), try self.convert(.sext_i32, rhs));
                        const result = try self.convert(.trunc_i64, wide);
                        try self.guard(try self.binary(.eq, wide, try self.convert(.sext_i32, result)), exit);
                        if (node.kind == .mul) {
                            const zero = try self.constant(.i32, 0);
                            const negative = try self.binary(.bit_or, try self.binary(.lt_s, lhs, zero), try self.binary(.lt_s, rhs, zero));
                            const negative_zero = try self.binary(.bit_and, negative, try self.binary(.eq, result, zero));
                            try self.guard(try self.binary(.eq, negative_zero, zero), exit);
                        }
                        self.values[id] = try self.box(result, Value.tag_int32);
                    }
                },
                .to_numeric => {
                    if (inputs.len != 1) return error.UnsupportedNode;
                    _ = try self.unbox(try self.get(inputs[0]), try self.sideExit(id));
                    self.values[id] = try self.get(inputs[0]);
                },
                .logical_not => {
                    if (inputs.len != 1) return error.UnsupportedNode;
                    const condition_value = try self.condition(id, inputs[0]);
                    self.values[id] = try self.box(try self.binary(.eq, condition_value, try self.constant(.i32, 0)), Value.tag_bool);
                },
                .jump => {
                    const edges = self.source.blockEdges(block_index);
                    if (edges.len != 1) return error.UnsupportedNode;
                    terminator = .{ .jump = try self.edge(edges[0]) };
                },
                .branch => {
                    if (node.payload.branch == .nullish or inputs.len != 1) return error.UnsupportedNode;
                    var condition_value = try self.condition(id, inputs[0]);
                    if (node.payload.branch == .falsy) condition_value = try self.binary(.eq, condition_value, try self.constant(.i32, 0));
                    var taken: ?low.Edge = null;
                    var fallthrough: ?low.Edge = null;
                    for (self.source.blockEdges(block_index)) |source_edge| switch (source_edge.kind) {
                        .branch_taken => taken = try self.edge(source_edge),
                        .branch_fallthrough => fallthrough = try self.edge(source_edge),
                        else => return error.UnsupportedNode,
                    };
                    terminator = .{ .branch = .{ .condition = condition_value, .taken = taken orelse return error.UnsupportedNode, .fallthrough = fallthrough orelse return error.UnsupportedNode } };
                },
                .return_ => {
                    if (inputs.len != 1) return error.UnsupportedNode;
                    terminator = .{ .return_ = try self.get(inputs[0]) };
                },
                else => return error.UnsupportedNode,
            }
        }
        self.blocks.items[self.block_map[block_index]].nodes = self.nodes.items;
        self.blocks.items[self.block_map[block_index]].terminator = terminator orelse return error.UnsupportedNode;
    }
};
