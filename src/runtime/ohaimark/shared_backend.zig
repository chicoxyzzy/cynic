//! Ohaimark consumer of the language-neutral backend. JS tags and exact
//! Lantern recovery remain frontend-owned. Runtime polls never collect in native code.
const std = @import("std");
const Chunk = @import("../../bytecode/chunk.zig").Chunk;
const Op = @import("../../bytecode/op.zig").Op;
const evaluator = @import("evaluator.zig");
const Value = @import("../value.zig").Value;
const ir = @import("ir.zig");
const specialize = @import("specialize.zig");
const low = @import("../jit/backend/ir.zig");
const native = @import("../jit/backend/native.zig");
const lantern = @import("../lantern/interpreter.zig");
const Realm = @import("../realm.zig").Realm;
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
        return buildWithOptions(a, owner, chunk, .{});
    }

    pub fn buildWithOptions(a: std.mem.Allocator, owner: *CodeAllocator, chunk: *const Chunk, options: native.Options) !Program {
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
        var builder: Builder = .{ .a = allocator, .source = &source, .plan = &plan, .chunk = chunk, .runtime = options.execution_policy == .controlled };
        builder.values = try allocator.alloc(low.Value, source.nodes.len);
        @memset(builder.values, missing);
        builder.block_map = try allocator.alloc(u32, source.blocks.len);
        @memset(builder.block_map, missing);
        const entry_loop = source.blocks.len != 0 and source.blocks[0].predecessor_count != 0;
        if (entry_loop) try builder.blocks.append(allocator, .{ .params = &.{} });
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
        if (entry_loop) {
            const params = try allocator.alloc(low.Value, source.blockParams(0).len);
            for (params) |*param| param.* = try builder.value(.i64);
            builder.blocks.items[0] = .{ .params = params, .terminator = .{ .jump = .{ .target = builder.block_map[0], .args = params } } };
        }
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
            .result_types = &.{.i64},
        };
        try graph.verify();
        return .{
            .allocator = a,
            .arena = arena,
            .graph = graph,
            .compiled = try native.compileWithOptions(a, owner, graph, options),
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

    pub const FrameOutcome = union(enum) { returned: Value, resumed, safe_point };

    /// The existing frame stays authoritative. Neither compilation, native
    /// arithmetic, nor the poll callback can collect or re-enter JavaScript.
    pub fn runFrame(self: *const Program, allocator: std.mem.Allocator, realm: *Realm, frame: *lantern.CallFrame, entries: *u64) !FrameOutcome {
        if (frame.registers.len < self.register_count) return error.ArgumentCount;
        var args: [low.max_arguments]u64 = undefined;
        for (self.entry_roles, 0..) |role, i| args[i] = switch (role) {
            .accumulator => frame.accumulator.bits,
            .register => |register| frame.registers[register].bits,
        };
        var host: FrameHost = .{ .program = self, .realm = realm, .frame = frame };
        var result: [1]u64 = undefined;
        var completion = self.compiled.runControlledInto(allocator, args[0..self.entry_roles.len], &.{}, .{
            .runtime = .{ .context = &host, .call = FrameHost.poll },
            .entry_counter = entries,
        }, &result) catch |err| {
            if (err == error.SharedJSSafePoint) return .safe_point;
            return err;
        };
        defer completion.deinit();
        return switch (completion) {
            .returned => .{ .returned = .{ .bits = result[0] } },
            .trapped => error.UnexpectedNativeTrap,
            .exited => |exit| blk: {
                try self.restoreFrame(frame, exit.id, exit.values);
                break :blk .resumed;
            },
        };
    }

    fn restoreFrame(self: *const Program, frame: *lantern.CallFrame, id: u32, values: []const u64) !void {
        if (id >= self.recoveries.len or frame.registers.len < self.register_count) return error.InvalidMetadata;
        const recovery = self.recoveries[id];
        if (values.len != recovery.registers.len + 1) return error.InvalidMetadata;
        for (recovery.registers) |register| if (register >= self.register_count) return error.InvalidMetadata;
        // The call ABI may reserve extra slots for surplus actual arguments.
        // They are not bytecode temporaries and must survive frame recovery.
        @memset(frame.registers[0..self.register_count], Value.undefined_);
        for (recovery.registers, values[1..]) |register, bits| frame.registers[register] = .{ .bits = bits };
        frame.accumulator = .{ .bits = values[0] };
        frame.ip = recovery.bytecode_offset;
    }

    const FrameHost = struct {
        program: *const Program,
        realm: *Realm,
        frame: *lantern.CallFrame,

        fn poll(raw: ?*anyopaque, request: native.CallRequest) !void {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            if (request.target != 0 or request.arguments.len != 0 or request.results.len != 0) return error.InvalidMetadata;
            const realm = self.realm;
            const heap = realm.heap;
            // Same fast/slow split as the production Ohaimark backedge poll.
            // Host hooks and GC run only after exact frame restoration.
            if (realm.terminationReason() != null or
                heap.sweep_phase == .sweeping or heap.marking_phase == .marking or
                heap.allocs_since_gc >= heap.gc_young_threshold or heap.bytes_since_gc >= heap.gc_byte_threshold or
                realm.step_budget == 0 or realm.interrupt.load(.acquire) or realm.interrupt_hook != null)
            {
                try self.program.restoreFrame(self.frame, request.safepoint, request.captures);
                return error.SharedJSSafePoint;
            }
            if (realm.step_budget != std.math.maxInt(u64) or realm.fuel_exhaustion == .terminate) realm.step_budget -|= 1;
        }
    };

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
            .trapped => return error.UnexpectedNativeTrap,
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
    runtime: bool = false,
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
        const ty: low.Type = if (low.isComparison(op)) .i32 else self.types.items[lhs];
        const out = try self.value(ty);
        try self.nodes.append(self.a, .{ .op = op, .out = out, .lhs = lhs, .rhs = rhs });
        return out;
    }

    fn convert(self: *Builder, op: low.Op, input: low.Value) !low.Value {
        return self.convertTo(op, input, if (op == .trunc_i64) .i32 else .i64);
    }

    fn convertTo(self: *Builder, op: low.Op, input: low.Value, ty: low.Type) !low.Value {
        const out = try self.value(ty);
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

    fn box(self: *Builder, input: low.Value, tag: u16) !low.Value {
        return self.binary(.bit_or, try self.convert(.zext_i32, input), try self.constant(.i64, @as(u64, tag) << 48));
    }

    fn selectBits(self: *Builder, condition_value: low.Value, yes: low.Value, no: low.Value) !low.Value {
        const mask = try self.binary(.sub, try self.constant(.i64, 0), try self.convert(.zext_i32, condition_value));
        return self.binary(.bit_xor, no, try self.binary(.bit_and, mask, try self.binary(.bit_xor, yes, no)));
    }

    fn number(self: *Builder, input: low.Value, exit: low.SideExit, comptime allow_boolean: bool) !low.Value {
        var integral = try self.hasTag(input, Value.tag_int32);
        if (allow_boolean) integral = try self.binary(.bit_or, integral, try self.hasTag(input, Value.tag_bool));
        const double = try self.binary(.lt_u, input, try self.constant(.i64, @as(u64, Value.tag_object) << 48));
        try self.guard(try self.binary(.bit_or, integral, double), exit);
        const converted = try self.convertTo(.convert_s, try self.convert(.trunc_i64, input), .f64);
        const raw = try self.binary(.sub, input, try self.constant(.i64, Value.double_encode_offset));
        // Select integer bit patterns before reinterpretation: a tag payload
        // must never be consumed as a floating-point value.
        return self.convertTo(.reinterpret, try self.selectBits(integral, try self.convertTo(.reinterpret, converted, .i64), raw), .f64);
    }

    fn boxDouble(self: *Builder, input: low.Value) !low.Value {
        const raw = try self.convertTo(.reinterpret, input, .i64);
        const encoded = try self.binary(.add, raw, try self.constant(.i64, Value.double_encode_offset));
        // Match Value.fromDouble: hardware NaN signs/payloads can otherwise
        // encode as heap tags. Number:: arithmetic exposes only one NaN value.
        return self.selectBits(try self.binary(.fne, input, input), try self.constant(.i64, Value.fromDouble(std.math.nan(f64)).bits), encoded);
    }

    fn arithmetic(self: *Builder, kind: ir.NodeKind, lhs: low.Value, rhs: low.Value, exit: low.SideExit) !low.Value {
        const x = try self.number(lhs, exit, false);
        const y = try self.number(rhs, exit, false);
        if (kind == .div) return self.boxDouble(try self.binary(.fdiv, x, y));

        const int_pair = try self.binary(.bit_and, try self.hasTag(lhs, Value.tag_int32), try self.hasTag(rhs, Value.tag_int32));
        const not_int_pair = try self.binary(.eq, int_pair, try self.constant(.i32, 0));
        const lhs_int = try self.convert(.trunc_i64, lhs);
        const rhs_int = try self.convert(.trunc_i64, rhs);
        const int_op: low.Op = switch (kind) {
            .add => .add,
            .sub => .sub,
            .mul => .mul,
            else => return error.UnsupportedNode,
        };
        const float_op: low.Op = switch (kind) {
            .add => .fadd,
            .sub => .fsub,
            .mul => .fmul,
            else => return error.UnsupportedNode,
        };
        const wide = try self.binary(int_op, try self.convert(.sext_i32, lhs_int), try self.convert(.sext_i32, rhs_int));
        const narrow = try self.convert(.trunc_i64, wide);
        const fits = try self.binary(.eq, wide, try self.convert(.sext_i32, narrow));
        try self.guard(try self.binary(.bit_or, not_int_pair, fits), exit);
        if (kind == .mul) {
            const zero = try self.constant(.i32, 0);
            const negative = try self.binary(.bit_or, try self.binary(.lt_s, lhs_int, zero), try self.binary(.lt_s, rhs_int, zero));
            const negative_zero = try self.binary(.bit_and, negative, try self.binary(.eq, narrow, zero));
            try self.guard(try self.binary(.bit_or, not_int_pair, try self.binary(.eq, negative_zero, zero)), exit);
        }
        // Retain the existing checked-Int32 recovery contract. Mixed/double
        // inputs use strict FP, including overflow to infinity and signed zero.
        const floating = try self.boxDouble(try self.binary(float_op, x, y));
        return self.selectBits(int_pair, try self.box(narrow, Value.tag_int32), floating);
    }

    fn lessThan(self: *Builder, node: ir.Node, lhs: low.Value, rhs: low.Value) !low.Value {
        if (node.bytecode_offset >= self.chunk.code.len) return error.InvalidMetadata;
        const op: Op = @fromBackingInt(@intCast(self.chunk.code[node.bytecode_offset]));
        const canonical = if (op.branchInfo()) |branch| branch.canonical else op;
        // The source IR represents >= and fused !<= / !>= via an inverted
        // integer < predicate. Invert ordered >= instead so NaN stays false
        // for the original relation; operand reversal is already in the IR.
        return switch (canonical) {
            .ge, .jmp_if_not_le, .jmp_if_not_ge => self.binary(.eq, try self.binary(.fge, lhs, rhs), try self.constant(.i32, 0)),
            else => self.binary(.flt, lhs, rhs),
        };
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
        const target = self.block_map[edge_value.to];
        if (!self.runtime or edge_value.to > edge_value.from) return .{ .target = target, .args = args };
        // Split only taken backward edges. Forward entries into the same loop
        // header must not consume fuel or invoke an extra interpreter safepoint.
        if (self.blocks.items.len >= low.max_blocks) return error.PrototypeLimit;
        const params = try self.a.alloc(low.Value, args.len);
        for (params) |*param| param.* = try self.value(.i64);
        const source_params = self.source.blockParams(edge_value.to);
        if (source_params.len == 0 or source_params[0].role != .accumulator) return error.InvalidMetadata;
        const registers = try self.a.alloc(u8, source_params.len - 1);
        for (registers, source_params[1..]) |*register, param| register.* = switch (param.role) {
            .register => |index| index,
            else => return error.InvalidMetadata,
        };
        const id: u32 = @intCast(self.recoveries.items.len);
        const pc = self.source.blocks[edge_value.to].start;
        try self.recoveries.append(self.a, .{ .node = source_params[0].value, .bytecode_offset = pc, .registers = registers });
        const nodes = try self.a.dupe(low.Node, &.{.{ .op = .call, .trap_site = pc, .call = .{
            .target = 0,
            .arguments = &.{},
            .parameter_types = &.{},
            .results = &.{},
            .result_types = &.{},
            .safepoint = .{ .id = id, .values = params },
        } }});
        const poll_block: u32 = @intCast(self.blocks.items.len);
        try self.blocks.append(self.a, .{ .params = params, .nodes = nodes, .terminator = .{ .jump = .{ .target = target, .args = params } } });
        return .{ .target = poll_block, .args = args };
    }

    fn condition(self: *Builder, node_id: ir.ValueId, input_id: ir.ValueId) !low.Value {
        const input = try self.get(input_id);
        const type_info = self.plan.node_info[input_id].result_type;
        if (type_info.isSubsetOf(specialize.Type.boolean)) return self.convert(.trunc_i64, input);
        // Int32 facts in the production specialization plan may describe a
        // broader Number here. Only Boolean result facts remain unconditional.
        const numeric = try self.number(input, try self.sideExit(node_id), true);
        const nonzero = try self.binary(.fne, numeric, try self.constant(.f64, 0));
        return self.binary(.bit_and, nonzero, try self.binary(.feq, numeric, numeric));
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
                .add, .sub, .mul, .div => {
                    if (inputs.len != 2) return error.UnsupportedNode;
                    const exit = try self.sideExit(id);
                    self.values[id] = try self.arithmetic(node.kind, try self.get(inputs[0]), try self.get(inputs[1]), exit);
                },
                .less_than, .strict_eq => {
                    if (inputs.len != 2) return error.UnsupportedNode;
                    const exit = try self.sideExit(id);
                    const lhs = try self.number(try self.get(inputs[0]), exit, false);
                    const rhs = try self.number(try self.get(inputs[1]), exit, false);
                    const result = if (node.kind == .less_than) try self.lessThan(node, lhs, rhs) else try self.binary(.feq, lhs, rhs);
                    self.values[id] = try self.box(result, Value.tag_bool);
                },
                .to_numeric => {
                    if (inputs.len != 1) return error.UnsupportedNode;
                    _ = try self.number(try self.get(inputs[0]), try self.sideExit(id), false);
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
                    terminator = .{ .return_ = try self.a.dupe(low.Value, &.{try self.get(inputs[0])}) };
                },
                else => return error.UnsupportedNode,
            }
        }
        self.blocks.items[self.block_map[block_index]].nodes = self.nodes.items;
        self.blocks.items[self.block_map[block_index]].terminator = terminator orelse return error.UnsupportedNode;
    }
};
