//! Ohaimark's bytecode-to-SSA entry layer. The graph uses block arguments as
//! phi nodes: every reachable block pre-creates an accumulator parameter and
//! parameters for its live-in Lantern registers, then predecessor edges carry
//! the corresponding values. Pre-creation makes backward edges ordinary and
//! avoids a separate loop-phi repair pass.
//!
//! This first layer is intentionally small. Unsupported bytecode and exception
//! regions return explicit errors so the tiering driver can leave the chunk in
//! Lantern; optimizer input must never turn valid JavaScript into a host abort.

const std = @import("std");

const chunk_mod = @import("../../bytecode/chunk.zig");
const Chunk = chunk_mod.Chunk;
const Op = @import("../../bytecode/op.zig").Op;
const liveness = @import("../../bytecode/liveness.zig");
const feedback_mod = @import("feedback.zig");

pub const ValueId = u32;
const invalid_value: ValueId = std.math.maxInt(ValueId);
pub const FrameStateId = u32;

pub const BuildDiagnostics = struct {
    unsupported_opcode: ?Op = null,
};

pub const NodeKind = enum {
    block_parameter,
    constant,
    add,
    sub,
    mul,
    strict_eq,
    less_than,
    load_named,
    jump,
    branch,
    return_,
};

pub const Immediate = union(enum) {
    undefined_,
    null_,
    true_,
    false_,
    hole,
    int32: i32,
    constant_pool: u16,
};

pub const BranchCondition = enum {
    truthy,
    falsy,
    nullish,
};

pub const NamedLoad = struct {
    key_constant: u16,
    feedback_index: u16,
};

pub const Payload = union(enum) {
    none,
    immediate: Immediate,
    parameter: u32,
    branch: BranchCondition,
    named_load: NamedLoad,
};

pub const Node = struct {
    kind: NodeKind,
    bytecode_offset: u32,
    input_start: u32,
    input_count: u16,
    payload: Payload = .none,
    frame_state: ?FrameStateId = null,
};

pub const FrameSlot = struct {
    register: u8,
    value: ValueId,
};

/// Interpreter-visible state immediately before a speculative node executes.
/// Deopt resumes at `bytecode_offset`, so the accumulator and register values
/// are the inputs to that opcode, never its partially-computed outputs.
pub const FrameState = struct {
    block: u32,
    bytecode_offset: u32,
    accumulator: ValueId,
    slot_start: u32,
    slot_count: u16,
};

pub const ParamRole = union(enum) {
    accumulator,
    register: u8,
};

pub const Param = struct {
    role: ParamRole,
    value: ValueId,
};

pub const EdgeKind = enum {
    fallthrough,
    jump,
    branch_taken,
    branch_fallthrough,
};

pub const Edge = struct {
    kind: EdgeKind,
    from: usize,
    to: usize,
    argument_start: u32,
    argument_count: u16,
};

pub const Block = struct {
    start: u32,
    end: u32,
    node_start: u32 = 0,
    node_count: u32 = 0,
    param_start: u32 = 0,
    param_count: u16 = 0,
    edge_start: u32 = 0,
    edge_count: u16 = 0,
    predecessor_count: u32 = 0,
    reachable: bool,
};

pub const Graph = struct {
    allocator: std.mem.Allocator,
    register_count: u8,
    blocks: []Block,
    nodes: []Node,
    inputs: []ValueId,
    params: []Param,
    edges: []Edge,
    frame_states: []FrameState,
    frame_slots: []FrameSlot,
    feedback: feedback_mod.Snapshot,

    pub fn build(allocator: std.mem.Allocator, chunk: *const Chunk) !Graph {
        return buildImpl(allocator, chunk, null);
    }

    pub fn buildWithDiagnostics(
        allocator: std.mem.Allocator,
        chunk: *const Chunk,
        diagnostics: *BuildDiagnostics,
    ) !Graph {
        diagnostics.* = .{};
        return buildImpl(allocator, chunk, diagnostics);
    }

    fn buildImpl(
        allocator: std.mem.Allocator,
        chunk: *const Chunk,
        diagnostics: ?*BuildDiagnostics,
    ) !Graph {
        // Handler entry defines accumulator/catch state via the unwinder. It
        // needs an explicit exceptional-edge environment, not a normal phi.
        if (chunk.handlers.len != 0) return error.UnsupportedExceptionFlow;

        var analysis = try liveness.analyze(
            allocator,
            chunk.code,
            chunk.register_count,
            chunk.handlers,
            chunk.switch_tables,
        );
        defer analysis.deinit();

        var feedback = try feedback_mod.Snapshot.capture(allocator, chunk);
        errdefer feedback.deinit();

        var builder: Builder = .{
            .allocator = allocator,
            .chunk = chunk,
            .analysis = &analysis,
            .diagnostics = diagnostics,
        };
        defer builder.deinit();
        try builder.createBlocks();
        try builder.createParameters();
        try builder.translateBlocks();

        const blocks = try builder.blocks.toOwnedSlice(allocator);
        errdefer allocator.free(blocks);
        const nodes = try builder.nodes.toOwnedSlice(allocator);
        errdefer allocator.free(nodes);
        const inputs = try builder.inputs.toOwnedSlice(allocator);
        errdefer allocator.free(inputs);
        const params = try builder.params.toOwnedSlice(allocator);
        errdefer allocator.free(params);
        const edges = try builder.edges.toOwnedSlice(allocator);
        errdefer allocator.free(edges);
        const frame_states = try builder.frame_states.toOwnedSlice(allocator);
        errdefer allocator.free(frame_states);
        const frame_slots = try builder.frame_slots.toOwnedSlice(allocator);
        errdefer allocator.free(frame_slots);

        return .{
            .allocator = allocator,
            .register_count = chunk.register_count,
            .blocks = blocks,
            .nodes = nodes,
            .inputs = inputs,
            .params = params,
            .edges = edges,
            .frame_states = frame_states,
            .frame_slots = frame_slots,
            .feedback = feedback,
        };
    }

    pub fn deinit(self: *Graph) void {
        self.allocator.free(self.blocks);
        self.allocator.free(self.nodes);
        self.allocator.free(self.inputs);
        self.allocator.free(self.params);
        self.allocator.free(self.edges);
        self.allocator.free(self.frame_states);
        self.allocator.free(self.frame_slots);
        self.feedback.deinit();
        self.* = undefined;
    }

    pub fn nodeInputs(self: *const Graph, id: ValueId) []const ValueId {
        const node = self.nodes[id];
        return self.inputs[node.input_start..][0..node.input_count];
    }

    pub fn blockParams(self: *const Graph, block: usize) []const Param {
        const b = self.blocks[block];
        return self.params[b.param_start..][0..b.param_count];
    }

    pub fn edgeArguments(self: *const Graph, edge: Edge) []const ValueId {
        return self.inputs[edge.argument_start..][0..edge.argument_count];
    }

    pub fn blockEdges(self: *const Graph, block: usize) []const Edge {
        const b = self.blocks[block];
        return self.edges[b.edge_start..][0..b.edge_count];
    }

    pub fn frameSlots(self: *const Graph, state: FrameState) []const FrameSlot {
        return self.frame_slots[state.slot_start..][0..state.slot_count];
    }
};

const DeoptLivePoint = struct {
    bytecode_offset: u32,
    register_start: u32,
    register_count: u16,
};

const DeoptLiveness = struct {
    points: std.ArrayListUnmanaged(DeoptLivePoint) = .empty,
    registers: std.ArrayListUnmanaged(u8) = .empty,

    fn deinit(self: *DeoptLiveness, allocator: std.mem.Allocator) void {
        self.points.deinit(allocator);
        self.registers.deinit(allocator);
    }

    /// Points were collected while scanning bytecode backwards, so forward
    /// graph translation consumes them from the end of the array.
    fn take(
        self: *const DeoptLiveness,
        cursor: *usize,
        bytecode_offset: u32,
    ) ![]const u8 {
        if (cursor.* == 0) return error.MalformedBytecode;
        cursor.* -= 1;
        const point = self.points.items[cursor.*];
        if (point.bytecode_offset != bytecode_offset) return error.MalformedBytecode;
        const start: usize = point.register_start;
        const count: usize = point.register_count;
        if (start > self.registers.items.len or count > self.registers.items.len - start) {
            return error.MalformedBytecode;
        }
        return self.registers.items[start..][0..count];
    }
};

const Builder = struct {
    allocator: std.mem.Allocator,
    chunk: *const Chunk,
    analysis: *const liveness.Analysis,
    diagnostics: ?*BuildDiagnostics,
    blocks: std.ArrayListUnmanaged(Block) = .empty,
    nodes: std.ArrayListUnmanaged(Node) = .empty,
    inputs: std.ArrayListUnmanaged(ValueId) = .empty,
    params: std.ArrayListUnmanaged(Param) = .empty,
    edges: std.ArrayListUnmanaged(Edge) = .empty,
    frame_states: std.ArrayListUnmanaged(FrameState) = .empty,
    frame_slots: std.ArrayListUnmanaged(FrameSlot) = .empty,

    fn deinit(self: *Builder) void {
        self.blocks.deinit(self.allocator);
        self.nodes.deinit(self.allocator);
        self.inputs.deinit(self.allocator);
        self.params.deinit(self.allocator);
        self.edges.deinit(self.allocator);
        self.frame_states.deinit(self.allocator);
        self.frame_slots.deinit(self.allocator);
    }

    fn createBlocks(self: *Builder) !void {
        if (self.analysis.blockCount() > std.math.maxInt(u32)) return error.GraphTooLarge;
        try self.blocks.ensureTotalCapacity(self.allocator, self.analysis.blockCount());
        for (self.analysis.leaders, 0..) |start, index| {
            const end: u32 = if (index + 1 < self.analysis.leaders.len)
                self.analysis.leaders[index + 1]
            else
                @intCast(self.chunk.code.len);
            self.blocks.appendAssumeCapacity(.{
                .start = start,
                .end = end,
                .reachable = self.analysis.reachable.isSet(index),
            });
        }

        for (self.analysis.succs, 0..) |successors, from| {
            if (!self.analysis.reachable.isSet(from)) continue;
            for (successors.items) |to| {
                if (!self.analysis.reachable.isSet(to)) continue;
                self.blocks.items[to].predecessor_count +|= 1;
            }
        }
    }

    fn createParameters(self: *Builder) !void {
        for (self.blocks.items, 0..) |*block, block_index| {
            block.param_start = try indexU32(self.params.items.len);
            if (!block.reachable) continue;
            try self.addParameter(block, .accumulator);
            var live = self.analysis.live_in[block_index].iterator(.{});
            while (live.next()) |register| {
                if (register > std.math.maxInt(u8)) return error.GraphTooLarge;
                try self.addParameter(block, .{ .register = @intCast(register) });
            }
        }
    }

    fn addParameter(self: *Builder, block: *Block, role: ParamRole) !void {
        if (block.param_count == std.math.maxInt(u16)) return error.GraphTooLarge;
        const param_index = try indexU32(self.params.items.len);
        const value = try self.addNode(
            .block_parameter,
            block.start,
            &.{},
            .{ .parameter = param_index },
        );
        try self.params.append(self.allocator, .{ .role = role, .value = value });
        block.param_count += 1;
    }

    fn translateBlocks(self: *Builder) !void {
        for (0..self.blocks.items.len) |block_index| {
            if (!self.blocks.items[block_index].reachable) continue;
            try self.translateBlock(block_index);
        }
    }

    fn translateBlock(self: *Builder, block_index: usize) !void {
        const start = self.blocks.items[block_index].start;
        const end = self.blocks.items[block_index].end;
        self.blocks.items[block_index].node_start = try indexU32(self.nodes.items.len);
        self.blocks.items[block_index].edge_start = try indexU32(self.edges.items.len);
        const body_start = self.nodes.items.len;
        const edge_start = self.edges.items.len;

        var deopt_liveness = try self.computeDeoptLiveness(block_index, start, end);
        defer deopt_liveness.deinit(self.allocator);
        var deopt_live_cursor = deopt_liveness.points.items.len;

        const registers = try self.allocator.alloc(ValueId, self.chunk.register_count);
        defer self.allocator.free(registers);
        @memset(registers, invalid_value);
        var accumulator = invalid_value;
        const block = self.blocks.items[block_index];
        for (self.params.items[block.param_start..][0..block.param_count]) |param| {
            switch (param.role) {
                .accumulator => accumulator = param.value,
                .register => |register| registers[register] = param.value,
            }
        }

        var terminated = false;
        var pc: usize = start;
        while (pc < end) {
            const op: Op = @enumFromInt(self.chunk.code[pc]);
            const next = pc + 1 + Op.operandSize(op);
            if (next > end) return error.MalformedBytecode;

            if (op.branchInfo()) |branch_info| {
                const target_offset = liveness.branchTarget(op, self.chunk.code, pc) orelse
                    return error.MalformedBytecode;
                if (target_offset >= self.chunk.code.len) return error.MalformedBytecode;
                const target = self.analysis.blockOf(target_offset);
                switch (branch_info.canonical) {
                    .jmp => {
                        _ = try self.addNode(.jump, @intCast(pc), &.{}, .none);
                        try self.addEdge(.jump, block_index, target, accumulator, registers);
                    },
                    .jmp_if_true, .jmp_if_false, .jmp_if_nullish => |canonical| {
                        const condition: BranchCondition = switch (canonical) {
                            .jmp_if_true => .truthy,
                            .jmp_if_false => .falsy,
                            .jmp_if_nullish => .nullish,
                            else => unreachable,
                        };
                        _ = try self.addNode(
                            .branch,
                            @intCast(pc),
                            &.{accumulator},
                            .{ .branch = condition },
                        );
                        try self.addEdge(.branch_taken, block_index, target, accumulator, registers);
                        if (end >= self.chunk.code.len) return error.MalformedBytecode;
                        try self.addEdge(
                            .branch_fallthrough,
                            block_index,
                            self.analysis.blockOf(end),
                            accumulator,
                            registers,
                        );
                    },
                    .jmp_if_strict_eq, .jmp_if_strict_neq => |canonical| {
                        const lhs = try readRegister(registers, self.chunk.code[pc + 1]);
                        const live_registers = try deopt_liveness.take(
                            &deopt_live_cursor,
                            @intCast(pc),
                        );
                        const comparison = try self.addDeoptNode(
                            .strict_eq,
                            @intCast(pc),
                            &.{ lhs, accumulator },
                            .none,
                            block_index,
                            accumulator,
                            registers,
                            live_registers,
                        );
                        _ = try self.addNode(
                            .branch,
                            @intCast(pc),
                            &.{comparison},
                            .{ .branch = if (canonical == .jmp_if_strict_eq) .truthy else .falsy },
                        );
                        // The fused opcode branches on the comparison but preserves
                        // the accumulator.
                        try self.addEdge(.branch_taken, block_index, target, accumulator, registers);
                        if (end >= self.chunk.code.len) return error.MalformedBytecode;
                        try self.addEdge(
                            .branch_fallthrough,
                            block_index,
                            self.analysis.blockOf(end),
                            accumulator,
                            registers,
                        );
                    },
                    else => {
                        if (self.diagnostics) |diagnostics| {
                            diagnostics.unsupported_opcode = op;
                        }
                        return error.UnsupportedOp;
                    },
                }
                terminated = true;
                pc = next;
                break;
            }

            switch (op) {
                .lda_undefined => accumulator = try self.addConstant(@intCast(pc), .undefined_),
                .lda_null => accumulator = try self.addConstant(@intCast(pc), .null_),
                .lda_true => accumulator = try self.addConstant(@intCast(pc), .true_),
                .lda_false => accumulator = try self.addConstant(@intCast(pc), .false_),
                .lda_hole => accumulator = try self.addConstant(@intCast(pc), .hole),
                .lda_zero => accumulator = try self.addConstant(@intCast(pc), .{ .int32 = 0 }),
                .lda_one => accumulator = try self.addConstant(@intCast(pc), .{ .int32 = 1 }),
                .lda_smi8 => accumulator = try self.addConstant(
                    @intCast(pc),
                    .{ .int32 = readI8(self.chunk.code, pc + 1) },
                ),
                .lda_smi16 => accumulator = try self.addConstant(
                    @intCast(pc),
                    .{ .int32 = readI16(self.chunk.code, pc + 1) },
                ),
                .lda_smi => accumulator = try self.addConstant(
                    @intCast(pc),
                    .{ .int32 = readI32(self.chunk.code, pc + 1) },
                ),
                .lda_constant => accumulator = try self.addConstant(
                    @intCast(pc),
                    .{ .constant_pool = readU16(self.chunk.code, pc + 1) },
                ),
                .ldar => accumulator = try readRegister(registers, self.chunk.code[pc + 1]),
                .ldar_0, .ldar_1, .ldar_2, .ldar_3 => |compact| {
                    const register: u8 = @intCast(@intFromEnum(compact) - @intFromEnum(Op.ldar_0));
                    accumulator = try readRegister(registers, register);
                },
                .star => try writeRegister(registers, self.chunk.code[pc + 1], accumulator),
                .star_0, .star_1, .star_2, .star_3 => |compact| {
                    const register: u8 = @intCast(@intFromEnum(compact) - @intFromEnum(Op.star_0));
                    try writeRegister(registers, register, accumulator);
                },
                .mov => {
                    const value = try readRegister(registers, self.chunk.code[pc + 1]);
                    try writeRegister(registers, self.chunk.code[pc + 2], value);
                },
                .add, .sub, .mul => |binary| {
                    const lhs = try readRegister(registers, self.chunk.code[pc + 1]);
                    const live_registers = try deopt_liveness.take(&deopt_live_cursor, @intCast(pc));
                    accumulator = try self.addDeoptNode(
                        switch (binary) {
                            .add => .add,
                            .sub => .sub,
                            .mul => .mul,
                            else => unreachable,
                        },
                        @intCast(pc),
                        &.{ lhs, accumulator },
                        .none,
                        block_index,
                        accumulator,
                        registers,
                        live_registers,
                    );
                },
                .strict_eq => {
                    const lhs = try readRegister(registers, self.chunk.code[pc + 1]);
                    const live_registers = try deopt_liveness.take(&deopt_live_cursor, @intCast(pc));
                    accumulator = try self.addDeoptNode(
                        .strict_eq,
                        @intCast(pc),
                        &.{ lhs, accumulator },
                        .none,
                        block_index,
                        accumulator,
                        registers,
                        live_registers,
                    );
                },
                .lt => {
                    const lhs = try readRegister(registers, self.chunk.code[pc + 1]);
                    accumulator = try self.addNode(
                        .less_than,
                        @intCast(pc),
                        &.{ lhs, accumulator },
                        .none,
                    );
                },
                .add_smi8, .add_smi16, .add_smi => |add_smi| {
                    const lhs = try readRegister(registers, self.chunk.code[pc + 1]);
                    const immediate: i32 = switch (add_smi) {
                        .add_smi8 => readI8(self.chunk.code, pc + 2),
                        .add_smi16 => readI16(self.chunk.code, pc + 2),
                        .add_smi => readI32(self.chunk.code, pc + 2),
                        else => unreachable,
                    };
                    const rhs = try self.addConstant(@intCast(pc), .{ .int32 = immediate });
                    const live_registers = try deopt_liveness.take(&deopt_live_cursor, @intCast(pc));
                    accumulator = try self.addDeoptNode(
                        .add,
                        @intCast(pc),
                        &.{ lhs, rhs },
                        .none,
                        block_index,
                        accumulator,
                        registers,
                        live_registers,
                    );
                },
                .lda_property8, .lda_property => |load| {
                    const narrow = load == .lda_property8;
                    const key: u16 = if (narrow) self.chunk.code[pc + 1] else readU16(self.chunk.code, pc + 1);
                    const feedback_index: u16 = if (narrow) self.chunk.code[pc + 2] else readU16(self.chunk.code, pc + 3);
                    if (feedback_index >= self.chunk.inline_load_caches.len) return error.MalformedBytecode;
                    const live_registers = try deopt_liveness.take(&deopt_live_cursor, @intCast(pc));
                    accumulator = try self.addDeoptNode(
                        .load_named,
                        @intCast(pc),
                        &.{accumulator},
                        .{ .named_load = .{
                            .key_constant = key,
                            .feedback_index = feedback_index,
                        } },
                        block_index,
                        accumulator,
                        registers,
                        live_registers,
                    );
                },
                .lda_property_reg8, .lda_property_reg => |load| {
                    const narrow = load == .lda_property_reg8;
                    const key: u16 = if (narrow) self.chunk.code[pc + 1] else readU16(self.chunk.code, pc + 1);
                    const register_at = pc + if (narrow) @as(usize, 2) else 3;
                    const receiver = try readRegister(registers, self.chunk.code[register_at]);
                    const feedback_index: u16 = if (narrow)
                        self.chunk.code[register_at + 1]
                    else
                        readU16(self.chunk.code, register_at + 1);
                    if (feedback_index >= self.chunk.inline_load_caches.len) return error.MalformedBytecode;
                    const live_registers = try deopt_liveness.take(&deopt_live_cursor, @intCast(pc));
                    accumulator = try self.addDeoptNode(
                        .load_named,
                        @intCast(pc),
                        &.{receiver},
                        .{ .named_load = .{
                            .key_constant = key,
                            .feedback_index = feedback_index,
                        } },
                        block_index,
                        accumulator,
                        registers,
                        live_registers,
                    );
                },
                .return_ => {
                    _ = try self.addNode(.return_, @intCast(pc), &.{accumulator}, .none);
                    terminated = true;
                },
                else => {
                    if (self.diagnostics) |diagnostics| {
                        diagnostics.unsupported_opcode = op;
                    }
                    return error.UnsupportedOp;
                },
            }
            pc = next;
            if (terminated) break;
        }

        if (!terminated) {
            const successors = self.analysis.succs[block_index].items;
            if (successors.len != 1) return error.MalformedBytecode;
            _ = try self.addNode(.jump, end, &.{}, .none);
            try self.addEdge(.fallthrough, block_index, successors[0], accumulator, registers);
        }
        if (deopt_live_cursor != 0) return error.MalformedBytecode;
        self.blocks.items[block_index].node_count = try indexU32(self.nodes.items.len - body_start);
        const edge_count = self.edges.items.len - edge_start;
        if (edge_count > std.math.maxInt(u16)) return error.GraphTooLarge;
        self.blocks.items[block_index].edge_count = @intCast(edge_count);
    }

    fn addConstant(self: *Builder, pc: u32, immediate: Immediate) !ValueId {
        return self.addNode(.constant, pc, &.{}, .{ .immediate = immediate });
    }

    fn addNode(
        self: *Builder,
        kind: NodeKind,
        pc: u32,
        node_inputs: []const ValueId,
        payload: Payload,
    ) !ValueId {
        if (node_inputs.len > std.math.maxInt(u16)) return error.GraphTooLarge;
        const id = try indexU32(self.nodes.items.len);
        const input_start = try indexU32(self.inputs.items.len);
        try self.inputs.appendSlice(self.allocator, node_inputs);
        try self.nodes.append(self.allocator, .{
            .kind = kind,
            .bytecode_offset = pc,
            .input_start = input_start,
            .input_count = @intCast(node_inputs.len),
            .payload = payload,
        });
        return id;
    }

    fn addDeoptNode(
        self: *Builder,
        kind: NodeKind,
        pc: u32,
        node_inputs: []const ValueId,
        payload: Payload,
        block_index: usize,
        accumulator: ValueId,
        registers: []const ValueId,
        live_registers: []const u8,
    ) !ValueId {
        const frame_state = try self.addFrameState(
            block_index,
            pc,
            accumulator,
            registers,
            live_registers,
        );
        const id = try self.addNode(kind, pc, node_inputs, payload);
        self.nodes.items[id].frame_state = frame_state;
        return id;
    }

    fn addFrameState(
        self: *Builder,
        block_index: usize,
        pc: u32,
        accumulator: ValueId,
        registers: []const ValueId,
        live_registers: []const u8,
    ) !FrameStateId {
        if (accumulator == invalid_value or accumulator >= self.nodes.items.len) {
            return error.MalformedBytecode;
        }
        const state_id = try indexU32(self.frame_states.items.len);
        const slot_start = try indexU32(self.frame_slots.items.len);
        for (live_registers) |register| {
            if (register >= registers.len) return error.MalformedBytecode;
            const value = registers[register];
            if (value >= self.nodes.items.len) return error.MalformedBytecode;
            try self.frame_slots.append(self.allocator, .{
                .register = register,
                .value = value,
            });
        }
        try self.frame_states.append(self.allocator, .{
            .block = try indexU32(block_index),
            .bytecode_offset = pc,
            .accumulator = accumulator,
            .slot_start = slot_start,
            .slot_count = @intCast(live_registers.len),
        });
        return state_id;
    }

    fn computeDeoptLiveness(
        self: *Builder,
        block_index: usize,
        start: u32,
        end: u32,
    ) !DeoptLiveness {
        var result: DeoptLiveness = .{};
        errdefer result.deinit(self.allocator);
        var offsets: std.ArrayListUnmanaged(u32) = .empty;
        defer offsets.deinit(self.allocator);

        var pc: usize = start;
        while (pc < end) {
            const op: Op = @enumFromInt(self.chunk.code[pc]);
            const next = pc + 1 + Op.operandSize(op);
            if (next > end) return error.MalformedBytecode;
            try offsets.append(self.allocator, @intCast(pc));
            pc = next;
        }

        var live = try std.DynamicBitSet.initEmpty(self.allocator, self.chunk.register_count);
        defer live.deinit();
        live.setUnion(self.analysis.live_out[block_index]);
        var offset_index = offsets.items.len;
        while (offset_index > 0) {
            offset_index -= 1;
            const offset = offsets.items[offset_index];
            const op: Op = @enumFromInt(self.chunk.code[offset]);
            liveness.applyReverseEffect(
                &live,
                liveness.effectOf(op, self.chunk.code, offset),
                self.chunk.register_count,
            );
            if (!isDeoptCandidate(op)) continue;

            const register_start = try indexU32(result.registers.items.len);
            var iterator = live.iterator(.{});
            while (iterator.next()) |register| {
                if (register > std.math.maxInt(u8)) return error.GraphTooLarge;
                try result.registers.append(self.allocator, @intCast(register));
            }
            const register_count = result.registers.items.len - register_start;
            if (register_count > std.math.maxInt(u16)) return error.GraphTooLarge;
            try result.points.append(self.allocator, .{
                .bytecode_offset = offset,
                .register_start = register_start,
                .register_count = @intCast(register_count),
            });
        }
        return result;
    }

    fn addEdge(
        self: *Builder,
        kind: EdgeKind,
        from: usize,
        to: usize,
        accumulator: ValueId,
        registers: []const ValueId,
    ) !void {
        for (self.edges.items) |edge| {
            if (edge.kind == kind and edge.from == from and edge.to == to) return;
        }
        const target = self.blocks.items[to];
        const argument_start = try indexU32(self.inputs.items.len);
        const target_params = self.params.items[target.param_start..][0..target.param_count];
        for (target_params) |param| {
            const value = switch (param.role) {
                .accumulator => accumulator,
                .register => |register| try readRegister(registers, register),
            };
            if (value == invalid_value) return error.MalformedBytecode;
            try self.inputs.append(self.allocator, value);
        }
        try self.edges.append(self.allocator, .{
            .kind = kind,
            .from = from,
            .to = to,
            .argument_start = argument_start,
            .argument_count = target.param_count,
        });
    }
};

fn isDeoptCandidate(op: Op) bool {
    return switch (op) {
        .add,
        .sub,
        .mul,
        .strict_eq,
        .add_smi,
        .add_smi8,
        .add_smi16,
        .jmp_if_strict_eq,
        .jmp_if_strict_eq8,
        .jmp_if_strict_eq32,
        .jmp_if_strict_neq,
        .jmp_if_strict_neq8,
        .jmp_if_strict_neq32,
        .lda_property,
        .lda_property8,
        .lda_property_reg,
        .lda_property_reg8,
        => true,
        else => false,
    };
}

fn indexU32(index: usize) !u32 {
    if (index > std.math.maxInt(u32)) return error.GraphTooLarge;
    return @intCast(index);
}

fn readRegister(registers: []const ValueId, register: u8) !ValueId {
    if (register >= registers.len) return error.MalformedBytecode;
    const value = registers[register];
    if (value == invalid_value) return error.MalformedBytecode;
    return value;
}

fn writeRegister(registers: []ValueId, register: u8, value: ValueId) !void {
    if (register >= registers.len or value == invalid_value) return error.MalformedBytecode;
    registers[register] = value;
}

fn readI8(code: []const u8, at: usize) i32 {
    return @as(i8, @bitCast(code[at]));
}

fn readI16(code: []const u8, at: usize) i32 {
    return std.mem.readInt(i16, code[at..][0..2], .little);
}

fn readI32(code: []const u8, at: usize) i32 {
    return std.mem.readInt(i32, code[at..][0..4], .little);
}

fn readU16(code: []const u8, at: usize) u16 {
    return std.mem.readInt(u16, code[at..][0..2], .little);
}
