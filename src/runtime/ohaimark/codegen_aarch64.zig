//! Verified AArch64 graph emission for Ohaimark's first executable subset.
//!
//! The compiler consumes only finished specialization, representation,
//! deoptimization, allocation, and physical-lowering plans. Guard exits write
//! the pre-operation state back into the existing Lantern `CallFrame`, then
//! return `resume_interp`; no helper call, allocation, or second frame format
//! exists on the bailout path. Taken backedges poll host/GC state and use the
//! same frame-compatible exit before Lantern performs any slow work.

const std = @import("std");

const BinaryNumberShape = @import("../../bytecode/chunk.zig").BinaryNumberShape;
const Chunk = @import("../../bytecode/chunk.zig").Chunk;
const a64 = @import("../jit/asm_aarch64.zig");
const layout = @import("../jit/layout.zig");
const Masm = @import("../jit/masm.zig").Masm;
const arith = @import("../lantern/arith.zig");
const Value = @import("../value.zig").Value;
const allocation = @import("allocation.zig");
const control_fusion = @import("control_fusion.zig");
const deopt = @import("deopt.zig");
const deopt_physical = @import("deopt_physical.zig");
const emitter = @import("emitter_aarch64.zig");
const ir = @import("ir.zig");
const lowering = @import("lowering_aarch64.zig");
const parallel_moves = @import("parallel_moves.zig");
const osr_mod = @import("osr.zig");
const property_codegen = @import("property_codegen_aarch64.zig");
const representation = @import("representation.zig");
const safepoint_codegen = @import("safepoint_codegen_aarch64.zig");
const specialize = @import("specialize.zig");

/// Matches the established Bistromath dispatcher contract. Ohaimark remains
/// test-only, but uses the production ABI now so tier-up needs no frame shim.
pub const EntryResult = enum(u32) {
    resume_interp = 0,
    done = 1,
};

/// Generated entries return one word in x0: a canonical tagged `Value` on
/// completion, or this noncanonical encoded-NaN payload after reconstructing
/// the Lantern frame. `Value.fromDouble` canonicalizes every NaN to payload
/// zero, and non-double values occupy the 0xFFF9..0xFFFF tag range, so valid JS
/// values cannot collide with this internal control sentinel.
pub const resume_sentinel_bits: u64 = 0x7FFA_0000_0000_0001;

comptime {
    const decoded: f64 = @bitCast(resume_sentinel_bits -% Value.double_encode_offset);
    std.debug.assert(std.math.isNan(decoded));
    std.debug.assert(resume_sentinel_bits != Value.fromDouble(std.math.nan(f64)).bits);
}

const max_graph_items = 16 * 1024;
const max_graph_nodes = 4 * 1024;

const lhs_scratch: a64.Reg = .x12;
const rhs_scratch: a64.Reg = .x13;
const result_scratch: a64.Reg = .x14;
const guard_scratch: a64.Reg = .x15;

const NumberInputKind = enum {
    generic,
    int32,
    double,
};

fn numberInputKind(shape: ?BinaryNumberShape, operand: usize) NumberInputKind {
    const exact = shape orelse return .generic;
    return switch (exact) {
        .int32_int32 => .int32,
        .double_int32 => if (operand == 0) .double else .int32,
        .int32_double => if (operand == 0) .int32 else .double,
        .double_double => .double,
        .cold, .polymorphic => .generic,
    };
}

const FrameLocation = union(enum) {
    accumulator,
    register: u8,
};

const FrameMoveSource = union(enum) {
    frame: FrameLocation,
    cycle_scratch,
};

const FrameMove = struct {
    source: FrameMoveSource,
    destination: FrameLocation,
};

pub fn emitGraph(
    allocator: std.mem.Allocator,
    machine: *Masm,
    chunk: *const Chunk,
    graph: *const ir.Graph,
    specialization: *const specialize.Plan,
    representations: *const representation.Plan,
    fused_control: *const control_fusion.Plan,
    logical: *const deopt.Metadata,
    homes: *const deopt_physical.Homes,
    physical_deopt: *const deopt_physical.Metadata,
    allocated: *const allocation.Plan,
    lowered: *const lowering.Plan,
) !void {
    var osr_entries: std.ArrayListUnmanaged(Chunk.JitState.OsrEntry) = .empty;
    defer osr_entries.deinit(allocator);
    try emitGraphCollectingOsr(
        allocator,
        machine,
        chunk,
        graph,
        specialization,
        representations,
        fused_control,
        logical,
        homes,
        physical_deopt,
        allocated,
        lowered,
        &osr_entries,
    );
}

/// Emit optimized code and append loop-header OSR stubs. Each successful
/// stub records `{bc, code_off}` relative to `machine.code` at the start of
/// emission (the published entry base). Callers that publish the table pass
/// a non-null `osr_entries` list; tests may leave it empty-consuming.
pub fn emitGraphCollectingOsr(
    allocator: std.mem.Allocator,
    machine: *Masm,
    chunk: *const Chunk,
    graph: *const ir.Graph,
    specialization: *const specialize.Plan,
    representations: *const representation.Plan,
    fused_control: *const control_fusion.Plan,
    logical: *const deopt.Metadata,
    homes: *const deopt_physical.Homes,
    physical_deopt: *const deopt_physical.Metadata,
    allocated: *const allocation.Plan,
    lowered: *const lowering.Plan,
    osr_entries: *std.ArrayListUnmanaged(Chunk.JitState.OsrEntry),
) !void {
    if (graph.blocks.len == 0) return error.MalformedGraph;
    if (graph.blocks.len > max_graph_items or graph.nodes.len > max_graph_nodes or
        graph.inputs.len > max_graph_items or graph.params.len > max_graph_items or
        graph.edges.len > max_graph_items or lowered.moves.len > max_graph_items or
        physical_deopt.points.len > max_graph_nodes or
        physical_deopt.stream.len > max_graph_items)
    {
        return error.GraphTooLarge;
    }
    try specialization.verify(graph);
    try fused_control.verify(graph, specialization, representations);
    try physical_deopt.verify(graph, specialization, representations, logical, homes);
    try allocated.verify(graph, specialization, representations, fused_control, homes);
    try lowered.verify(
        graph,
        specialization,
        representations,
        fused_control,
        homes,
        allocated,
    );

    var osr_meta = try osr_mod.Metadata.build(allocator, graph);
    defer osr_meta.deinit();
    try osr_meta.verify(graph);

    const block_labels = try allocator.alloc(Masm.Label, graph.blocks.len);
    defer {
        for (block_labels) |*label| label.deinit(allocator);
        allocator.free(block_labels);
    }
    for (block_labels) |*label| label.* = .{};

    const guard_labels = try allocator.alloc(Masm.Label, physical_deopt.points.len);
    defer {
        for (guard_labels) |*label| label.deinit(allocator);
        allocator.free(guard_labels);
    }
    for (guard_labels) |*label| label.* = .{};

    const point_for_node = try allocator.alloc(?usize, graph.nodes.len);
    defer allocator.free(point_for_node);
    @memset(point_for_node, null);
    for (physical_deopt.points, 0..) |point, point_index| {
        if (point.node >= point_for_node.len or point_for_node[point.node] != null) {
            return error.InvalidMetadata;
        }
        point_for_node[point.node] = point_index;
    }

    var compiler: Compiler = .{
        .allocator = allocator,
        .machine = machine,
        .chunk = chunk,
        .graph = graph,
        .specialization = specialization,
        .representations = representations,
        .fused_control = fused_control,
        .homes = homes,
        .physical_deopt = physical_deopt,
        .lowered = lowered,
        .block_labels = block_labels,
        .guard_labels = guard_labels,
        .point_for_node = point_for_node,
        .osr_meta = &osr_meta,
        .osr_entries = osr_entries,
    };
    const code_start = machine.code.items.len;
    errdefer machine.code.shrinkRetainingCapacity(code_start);
    try compiler.emit();
}

const Compiler = struct {
    allocator: std.mem.Allocator,
    machine: *Masm,
    chunk: *const Chunk,
    graph: *const ir.Graph,
    specialization: *const specialize.Plan,
    representations: *const representation.Plan,
    fused_control: *const control_fusion.Plan,
    homes: *const deopt_physical.Homes,
    physical_deopt: *const deopt_physical.Metadata,
    lowered: *const lowering.Plan,
    block_labels: []Masm.Label,
    guard_labels: []Masm.Label,
    point_for_node: []const ?usize,
    osr_meta: *const osr_mod.Metadata,
    osr_entries: *std.ArrayListUnmanaged(Chunk.JitState.OsrEntry),

    fn emit(self: *Compiler) !void {
        try emitter.emitPrologue(self.machine, self.lowered.frame);
        try self.emitEntryParameters();
        for (self.graph.blocks, 0..) |block, block_index| {
            if (!block.reachable) continue;
            self.machine.bind(&self.block_labels[block_index]);
            try self.emitBlock(block_index, block);
        }
        // OSR stubs after the ordinary body so fallthrough never lands in one.
        // Each stub shares the same spill layout and block labels as entry.
        try self.emitOsrEntries();
        for (self.physical_deopt.points, 0..) |_, point_index| {
            self.machine.bind(&self.guard_labels[point_index]);
            try self.emitGuardExit(point_index);
        }
    }

    fn emitEntryParameters(self: *Compiler) !void {
        const entry = self.graph.blocks[0];
        if (!entry.reachable) return error.MalformedGraph;
        try self.materializeBlockParametersFromFrame(0, null);
    }

    /// Map the live Lantern frame into the SSA parameters of `block_index`.
    /// Function entry requires tagged destinations (the frame is always
    /// NaN-boxed). OSR headers may need int32 unboxing; a failed check
    /// branches to `int32_fail` when provided, otherwise refuses compilation.
    fn materializeBlockParametersFromFrame(
        self: *Compiler,
        block_index: usize,
        int32_fail: ?*Masm.Label,
    ) !void {
        if (block_index >= self.graph.blocks.len) return error.MalformedGraph;
        const block = self.graph.blocks[block_index];
        if (!block.reachable) return error.MalformedGraph;
        const params = try checkedRange(self.graph.params.len, block.param_start, block.param_count);
        for (self.graph.params[params.start..params.end()]) |param| {
            if (param.value >= self.lowered.locations.len or
                param.value >= self.representations.outputs.len)
            {
                return error.MalformedGraph;
            }
            const destination = self.lowered.locations[param.value];
            if (destination == .none) continue;
            if (destination == .immediate) return error.UnsupportedNode;
            const kind = self.representations.outputs[param.value];
            switch (param.role) {
                .accumulator => try self.machine.emit(a64.ldrImm(
                    lhs_scratch,
                    lowering.lantern_frame_register,
                    layout.frame.accumulator,
                )),
                .register => |register| try self.machine.emit(a64.ldrImm(
                    lhs_scratch,
                    lowering.lantern_registers_register,
                    try registerOffset(register),
                )),
            }
            switch (kind) {
                .tagged => {
                    try emitter.emitMove(self.machine, .{
                        .source = .{ .register = lhs_scratch },
                        .destination = destination,
                        .source_kind = .tagged,
                        .destination_kind = .tagged,
                        .conversion = .none,
                    }, self.chunk.constants);
                },
                .int32 => {
                    const fail = int32_fail orelse return error.UnsupportedNode;
                    try self.machine.movImm64(
                        guard_scratch,
                        @as(u64, Value.tag_int32) << 48,
                    );
                    try self.machine.emit(a64.eorReg(guard_scratch, lhs_scratch, guard_scratch));
                    try self.machine.emit(a64.lsrImm(guard_scratch, guard_scratch, 48));
                    try self.machine.jumpCbnz(guard_scratch, fail);
                    try emitter.emitMove(self.machine, .{
                        .source = .{ .register = lhs_scratch },
                        .destination = destination,
                        .source_kind = .int32,
                        .destination_kind = .int32,
                        .conversion = .none,
                    }, self.chunk.constants);
                },
                .none => return error.MalformedGraph,
            }
            try self.emitDefinitionHome(param.value);
        }
    }

    fn emitOsrEntries(self: *Compiler) !void {
        for (self.osr_meta.headers, 0..) |header, header_index| {
            if (header.block_index >= self.block_labels.len or
                header.block_index >= self.graph.blocks.len or
                !self.graph.blocks[header.block_index].reachable)
            {
                return error.InvalidMetadata;
            }
            // Offsets are relative to the buffer start, which becomes the
            // published entry base after installOwned.
            const code_off: u32 = @intCast(self.machine.code.items.len);
            try self.osr_entries.append(self.allocator, .{
                .bc = header.bytecode_offset,
                .code_off = code_off,
            });

            var int32_fail: Masm.Label = .{};
            defer int32_fail.deinit(self.allocator);
            const needs_int32 = try self.osr_meta.headerNeedsInt32Checks(
                self.graph,
                self.representations,
                header_index,
            );

            try emitter.emitPrologue(self.machine, self.lowered.frame);
            try self.materializeBlockParametersFromFrame(
                header.block_index,
                if (needs_int32) &int32_fail else null,
            );
            try self.machine.jump(&self.block_labels[header.block_index]);

            if (needs_int32) {
                // Frame already holds loop-header state (OSR loads never
                // write it). Release the spill area and resume Lantern.
                self.machine.bind(&int32_fail);
                try self.machine.movImm64(.x0, resume_sentinel_bits);
                try emitter.emitEpilogue(self.machine, self.lowered.frame);
            }
        }
    }

    fn emitBlock(self: *Compiler, block_index: usize, block: ir.Block) !void {
        const nodes = try checkedRange(self.graph.nodes.len, block.node_start, block.node_count);
        if (nodes.len == 0) return error.MalformedGraph;
        var terminated = false;
        for (nodes.start..nodes.end()) |node_index| {
            if (terminated) return error.MalformedGraph;
            terminated = try self.emitNode(block_index, @intCast(node_index));
        }
        if (!terminated) return error.MalformedGraph;
    }

    fn emitNode(self: *Compiler, block_index: usize, node_id: ir.ValueId) !bool {
        if (node_id >= self.graph.nodes.len or node_id >= self.specialization.node_info.len) {
            return error.MalformedGraph;
        }
        const node = self.graph.nodes[node_id];
        const info = self.specialization.node_info[node_id];
        switch (node.kind) {
            .block_parameter => return error.MalformedGraph,
            .constant => {
                if (self.homes.values[node_id] != null) return error.InvalidMetadata;
                return false;
            },
            .add, .sub, .mul, .div => {
                if (info.lowering == .constant) return false;
                try self.emitCheckedArithmetic(node_id, node.kind, info.lowering);
                return false;
            },
            .strict_eq => {
                if (try self.fused_control.valueIsElided(node_id)) {
                    if (info.lowering != .strict_eq or
                        self.representations.outputs[node_id] != .tagged or
                        self.lowered.locations[node_id] != .none or
                        self.homes.values[node_id] != null)
                    {
                        return error.InvalidControlFusion;
                    }
                    return false;
                }
                if (info.lowering == .constant) return false;
                try self.emitStrictEqual(node_id, info.lowering);
                return false;
            },
            .logical_not => {
                if (info.lowering == .constant) return false;
                try self.emitLogicalNot(node_id, info.lowering);
                return false;
            },
            .jump => {
                const edge_index = try self.singleEdge(block_index);
                try self.emitEdgeAndJump(edge_index);
                return true;
            },
            .branch => {
                try self.emitBranch(block_index, node_id);
                return true;
            },
            .load_named => {
                try self.emitNamedLoad(node_id, info.lowering);
                return false;
            },
            .load_this => {
                try self.emitThisLoad(node_id, info.lowering);
                return false;
            },
            .load_global => {
                try self.emitGlobalLoad(node_id, info.lowering);
                return false;
            },
            .load_global_slot => {
                try self.emitGlobalSlotLoad(node_id, info.lowering);
                return false;
            },
            .load_environment => {
                try self.emitEnvironmentLoad(node_id, info.lowering);
                return false;
            },
            .return_ => {
                try self.emitReturn(node_id);
                return true;
            },
            .less_than => return error.UnsupportedNode,
        }
    }

    fn emitCheckedArithmetic(
        self: *Compiler,
        node_id: ir.ValueId,
        kind: ir.NodeKind,
        lowering_kind: specialize.Lowering,
    ) !void {
        const number_arithmetic =
            (kind == .mul and lowering_kind == .number_mul) or
            (kind == .div and lowering_kind == .number_div);
        if (number_arithmetic) {
            try self.emitNumberArithmetic(node_id, kind);
            return;
        }
        const expected: specialize.Lowering = switch (kind) {
            .add => .checked_int32_add,
            .sub => .checked_int32_sub,
            .mul => .checked_int32_mul,
            .div => .checked_int32_div,
            else => return error.MalformedGraph,
        };
        if (lowering_kind != expected or self.representations.outputs[node_id] != .int32) {
            return error.UnsupportedNode;
        }
        const guard = try self.guardFor(node_id);
        try self.emitInt32Input(node_id, 0, lhs_scratch, guard);
        try self.emitInt32Input(node_id, 1, rhs_scratch, guard);
        switch (kind) {
            .add => {
                try self.machine.emit(a64.addsRegW(result_scratch, lhs_scratch, rhs_scratch));
                try self.jumpToGuardIf(.vs, guard);
            },
            .sub => {
                try self.machine.emit(a64.subsRegW(result_scratch, lhs_scratch, rhs_scratch));
                try self.jumpToGuardIf(.vs, guard);
            },
            .mul => try self.emitCheckedMultiply(guard),
            .div => try self.emitCheckedDivide(guard),
            else => unreachable,
        }

        const destination = try self.valueLocation(node_id);
        try emitter.emitMove(self.machine, .{
            .source = .{ .register = result_scratch },
            .destination = destination,
            .source_kind = .int32,
            .destination_kind = .int32,
            .conversion = .none,
        }, self.chunk.constants);
        try self.emitDefinitionHome(node_id);
    }

    fn emitStrictEqual(
        self: *Compiler,
        node_id: ir.ValueId,
        lowering_kind: specialize.Lowering,
    ) !void {
        if (lowering_kind != .strict_eq or self.representations.outputs[node_id] != .tagged) {
            return error.UnsupportedNode;
        }
        const guard = try self.guardFor(node_id);
        try self.emitInt32Input(node_id, 0, lhs_scratch, guard);
        try self.emitInt32Input(node_id, 1, rhs_scratch, guard);
        try self.machine.emit(a64.cmpRegW(lhs_scratch, rhs_scratch));
        try self.machine.emit(a64.csetW(result_scratch, .eq));
        try self.machine.movImm64(guard_scratch, Value.false_.bits);
        try self.machine.emit(a64.orrReg(result_scratch, result_scratch, guard_scratch));

        try emitter.emitMove(self.machine, .{
            .source = .{ .register = result_scratch },
            .destination = try self.valueLocation(node_id),
            .source_kind = .tagged,
            .destination_kind = .tagged,
            .conversion = .none,
        }, self.chunk.constants);
        try self.emitDefinitionHome(node_id);
    }

    fn emitLogicalNot(
        self: *Compiler,
        node_id: ir.ValueId,
        lowering_kind: specialize.Lowering,
    ) !void {
        if ((lowering_kind != .logical_not and lowering_kind != .checked_boolean_not) or
            self.representations.outputs[node_id] != .tagged)
        {
            return error.UnsupportedNode;
        }
        try self.emitTaggedInput(node_id, 0, lhs_scratch);
        if (lowering_kind == .checked_boolean_not) {
            const guard = try self.guardFor(node_id);
            try self.machine.movImm64(guard_scratch, Value.false_.bits);
            try self.machine.emit(a64.eorReg(guard_scratch, lhs_scratch, guard_scratch));
            try self.machine.emit(a64.cmpImm(guard_scratch, 1, false));
            try self.jumpToGuardIf(.hi, guard);
        }
        try self.machine.emit(a64.movz(rhs_scratch, 1, 0));
        try self.machine.emit(a64.eorReg(result_scratch, lhs_scratch, rhs_scratch));
        try self.emitTaggedResult(node_id, result_scratch);
    }

    fn emitCheckedMultiply(self: *Compiler, guard: *Masm.Label) !void {
        var nonzero: Masm.Label = .{};
        defer nonzero.deinit(self.allocator);
        try self.machine.emit(a64.smull(result_scratch, lhs_scratch, rhs_scratch));
        try self.machine.emit(a64.sxtw(guard_scratch, result_scratch));
        try self.machine.emit(a64.cmpReg(result_scratch, guard_scratch));
        try self.jumpToGuardIf(.ne, guard);
        try self.machine.emit(a64.cmpImm(result_scratch, 0, false));
        try self.machine.jumpCond(.ne, &nonzero);
        try self.machine.emit(a64.eorReg(guard_scratch, lhs_scratch, rhs_scratch));
        try self.jumpToGuardIfBitSet(guard_scratch, 31, guard);
        self.machine.bind(&nonzero);
    }

    /// §6.1.6.1.5 Number::divide, exact-int32 subset. AArch64 `sdiv` is
    /// non-trapping for zero and INT_MIN/-1; explicit guards preserve the JS
    /// infinity/-0 cases, while the widened product catches overflow and any
    /// fractional remainder before the int32 result becomes observable.
    fn emitCheckedDivide(self: *Compiler, guard: *Masm.Label) !void {
        var nonzero_lhs: Masm.Label = .{};
        defer nonzero_lhs.deinit(self.allocator);

        try self.machine.emit(a64.cmpImm(rhs_scratch, 0, false));
        try self.jumpToGuardIf(.eq, guard);
        try self.machine.emit(a64.cmpImm(lhs_scratch, 0, false));
        try self.machine.jumpCond(.ne, &nonzero_lhs);
        try self.jumpToGuardIfBitSet(rhs_scratch, 31, guard);
        self.machine.bind(&nonzero_lhs);

        try self.machine.emit(a64.sdivW(result_scratch, lhs_scratch, rhs_scratch));
        try self.machine.emit(a64.smull(guard_scratch, result_scratch, rhs_scratch));
        try self.machine.emit(a64.sxtw(lhs_scratch, lhs_scratch));
        try self.machine.emit(a64.cmpReg(guard_scratch, lhs_scratch));
        try self.jumpToGuardIf(.ne, guard);
    }

    /// §6.1.6.1.4/.5 Number::multiply/divide. Tagged Int32 and Double
    /// operands bridge through caller-saved v16/v17, and the result is
    /// immediately re-boxed. Coercion, BigInt, and NaN canonicalization stay
    /// on Lantern's slow path.
    fn emitNumberArithmetic(
        self: *Compiler,
        node_id: ir.ValueId,
        kind: ir.NodeKind,
    ) !void {
        if (self.representations.outputs[node_id] != .tagged) {
            return error.InvalidRepresentation;
        }
        const guard = try self.guardFor(node_id);
        const number_shape = self.specialization.node_info[node_id].number_shape;
        try self.emitTaggedInput(node_id, 0, lhs_scratch);
        try self.emitTaggedInput(node_id, 1, rhs_scratch);
        try self.emitTaggedNumberAsDouble(
            lhs_scratch,
            .x16,
            guard,
            numberInputKind(number_shape, 0),
        );
        try self.emitTaggedNumberAsDouble(
            rhs_scratch,
            .x17,
            guard,
            numberInputKind(number_shape, 1),
        );
        try self.machine.emit(switch (kind) {
            .mul => a64.fmulD(.x16, .x16, .x17),
            .div => a64.fdivD(.x16, .x16, .x17),
            else => return error.MalformedGraph,
        });
        try self.machine.emit(a64.fcmpD(.x16, .x16));
        try self.jumpToGuardIf(.vs, guard);
        try self.machine.emit(a64.fmovDtoX(result_scratch, .x16));
        try self.machine.movImm64(guard_scratch, Value.double_encode_offset);
        try self.machine.emit(a64.addReg(
            result_scratch,
            result_scratch,
            guard_scratch,
        ));
        try self.emitTaggedResult(node_id, result_scratch);
    }

    fn emitTaggedNumberAsDouble(
        self: *Compiler,
        value: a64.Reg,
        fp: a64.Reg,
        guard: *Masm.Label,
        input_kind: NumberInputKind,
    ) !void {
        if (input_kind == .int32) {
            try self.machine.emit(a64.lsrImm(result_scratch, value, 48));
            try self.machine.movImm64(guard_scratch, Value.tag_int32);
            try self.machine.emit(a64.cmpReg(result_scratch, guard_scratch));
            try self.jumpToGuardIf(.ne, guard);
            try self.machine.emit(a64.scvtfDfromW(fp, value));
            return;
        }
        if (input_kind == .double) {
            try self.machine.emit(a64.lsrImm(result_scratch, value, 48));
            try self.machine.movImm64(guard_scratch, Value.tag_object);
            try self.machine.emit(a64.cmpReg(result_scratch, guard_scratch));
            try self.jumpToGuardIf(.cs, guard);
            try self.machine.movImm64(guard_scratch, Value.double_encode_offset);
            try self.machine.emit(a64.subReg(result_scratch, value, guard_scratch));
            try self.machine.emit(a64.fmovXtoD(fp, result_scratch));
            return;
        }

        var int32_value: Masm.Label = .{};
        defer int32_value.deinit(self.allocator);
        var done: Masm.Label = .{};
        defer done.deinit(self.allocator);

        try self.machine.emit(a64.lsrImm(result_scratch, value, 48));
        try self.machine.movImm64(guard_scratch, Value.tag_int32);
        try self.machine.emit(a64.cmpReg(result_scratch, guard_scratch));
        try self.machine.jumpCond(.eq, &int32_value);
        try self.machine.movImm64(guard_scratch, Value.tag_object);
        try self.machine.emit(a64.cmpReg(result_scratch, guard_scratch));
        try self.jumpToGuardIf(.cs, guard);

        try self.machine.movImm64(guard_scratch, Value.double_encode_offset);
        try self.machine.emit(a64.subReg(result_scratch, value, guard_scratch));
        try self.machine.emit(a64.fmovXtoD(fp, result_scratch));
        try self.machine.jump(&done);

        self.machine.bind(&int32_value);
        try self.machine.emit(a64.scvtfDfromW(fp, value));
        self.machine.bind(&done);
    }

    fn emitInt32Input(
        self: *Compiler,
        node_id: ir.ValueId,
        operand: usize,
        destination: a64.Reg,
        guard: *Masm.Label,
    ) !void {
        if (node_id >= self.graph.nodes.len) return error.MalformedGraph;
        const node = self.graph.nodes[node_id];
        const inputs = try checkedRange(self.graph.inputs.len, node.input_start, node.input_count);
        if (operand >= inputs.len) return error.MalformedGraph;
        const input_index = inputs.start + operand;
        const producer = self.graph.inputs[input_index];
        if (producer >= self.representations.outputs.len) return error.MalformedGraph;
        const source_kind = self.representations.outputs[producer];
        const conversion = try self.representations.conversionAt(self.graph, input_index);
        switch (conversion) {
            .none => if (source_kind != .int32) return error.InvalidRepresentation,
            .check_int32 => if (source_kind != .tagged) return error.InvalidRepresentation,
            .box_int32 => return error.InvalidRepresentation,
        }
        try emitter.emitMove(self.machine, .{
            .source = try self.valueLocation(producer),
            .destination = .{ .register = destination },
            .source_kind = source_kind,
            .destination_kind = source_kind,
            .conversion = .none,
        }, self.chunk.constants);
        if (conversion == .check_int32) {
            try self.machine.movImm64(
                guard_scratch,
                @as(u64, Value.tag_int32) << 48,
            );
            try self.machine.emit(a64.eorReg(guard_scratch, destination, guard_scratch));
            try self.machine.emit(a64.lsrImm(guard_scratch, guard_scratch, 48));
            try self.jumpToGuardIfNonzero(guard_scratch, guard);
        }
    }

    fn emitNamedLoad(
        self: *Compiler,
        node_id: ir.ValueId,
        lowering_kind: specialize.Lowering,
    ) !void {
        const assumption_kind: specialize.AssumptionKind, const mode: property_codegen.Mode = switch (lowering_kind) {
            .load_named_own => .{ .load_own, .own_data },
            .load_named_prototype => .{ .load_prototype, .prototype_data },
            .load_named_synthetic => .{ .load_synthetic, .synthetic_accessor },
            else => return error.UnsupportedNode,
        };
        const assumption = try self.assumptionFor(node_id, assumption_kind);
        const receiver_shape = assumption.receiver_shape orelse return error.InvalidMetadata;
        const cell_index: usize = assumption.feedback_index;
        if (cell_index >= self.chunk.inline_load_caches.len) return error.InvalidMetadata;
        const cell = &self.chunk.inline_load_caches[cell_index];
        const guard = try self.guardFor(node_id);
        try self.emitTaggedInput(node_id, 0, lhs_scratch);
        const result = try property_codegen.emit(
            self.allocator,
            self.machine,
            lowering.realm_register,
            cell,
            .{
                .mode = mode,
                .receiver_shape = receiver_shape,
                .holder_shape = assumption.holder_shape,
                .slot = assumption.slot,
                .revision = assumption.revision,
            },
            lhs_scratch,
            guard,
        );
        try self.emitTaggedResult(node_id, result);
    }

    fn emitThisLoad(
        self: *Compiler,
        node_id: ir.ValueId,
        lowering_kind: specialize.Lowering,
    ) !void {
        if (lowering_kind != .load_this) return error.UnsupportedNode;
        const guard = try self.guardFor(node_id);
        try self.machine.emit(a64.ldrImm(
            lhs_scratch,
            lowering.lantern_frame_register,
            layout.frame.super_called_cell,
        ));
        try self.jumpToGuardIfNonzero(lhs_scratch, guard);
        try self.machine.emit(a64.ldrImm(
            lhs_scratch,
            lowering.lantern_frame_register,
            layout.frame.this_value,
        ));
        try self.emitTaggedResult(node_id, lhs_scratch);
    }

    fn emitGlobalLoad(
        self: *Compiler,
        node_id: ir.ValueId,
        lowering_kind: specialize.Lowering,
    ) !void {
        if (lowering_kind == .load_global_generic) return error.UnsupportedNode;
        if (lowering_kind != .load_global) return error.MalformedGraph;
        const assumption = try self.assumptionFor(node_id, .load_global);
        const expected_shape = assumption.receiver_shape orelse return error.InvalidMetadata;
        if (assumption.holder_shape != null or assumption.slot >= expected_shape.property_count) {
            return error.InvalidMetadata;
        }
        const site = switch (self.graph.nodes[node_id].payload) {
            .global_load => |global| global,
            else => return error.MalformedGraph,
        };
        if (site.feedback_index >= self.chunk.inline_load_caches.len) {
            return error.InvalidMetadata;
        }
        const cell = &self.chunk.inline_load_caches[site.feedback_index];
        const guard = try self.guardFor(node_id);

        // x9 keeps the executing Realm, x10 the global object, and x11 the
        // live IC cell. x12-x15 remain ordinary value/guard temporaries.
        var have_running_realm: Masm.Label = .{};
        defer have_running_realm.deinit(self.allocator);
        try self.machine.emit(a64.ldrImm(
            .x9,
            lowering.lantern_frame_register,
            layout.frame.running_realm,
        ));
        try self.machine.jumpCbnz(.x9, &have_running_realm);
        try self.machine.emit(a64.movReg(.x9, lowering.realm_register));
        self.machine.bind(&have_running_realm);

        try property_codegen.emitRealmU64(
            self.machine,
            .x9,
            .x10,
            layout.realm.globals_target,
        );
        try self.machine.emit(a64.cmpImm(.x10, 0, false));
        try self.jumpToGuardIf(.eq, guard);
        try self.machine.movImm64(.x11, @intFromPtr(cell));

        try self.machine.emit(a64.ldrImm(.x13, .x11, layout.load_ic_cell.shape));
        try self.machine.emit(a64.cmpImm(.x13, 0, false));
        try self.jumpToGuardIf(.eq, guard);
        try self.machine.movImm64(lhs_scratch, @intFromPtr(expected_shape));
        try self.machine.emit(a64.cmpReg(.x13, lhs_scratch));
        try self.jumpToGuardIf(.ne, guard);
        try self.machine.emit(a64.ldrImm(lhs_scratch, .x10, layout.object.shape));
        try self.machine.emit(a64.cmpReg(.x13, lhs_scratch));
        try self.jumpToGuardIf(.ne, guard);

        try self.machine.emit(a64.ldrImm(lhs_scratch, .x11, layout.load_ic_cell.proto));
        try self.machine.emit(a64.cmpImm(lhs_scratch, 0, false));
        try self.jumpToGuardIf(.ne, guard);
        try self.machine.emit(a64.ldrImm(lhs_scratch, .x11, layout.load_ic_cell.proto_rev));
        try self.machine.movImm64(result_scratch, assumption.revision);
        try self.machine.emit(a64.cmpReg(lhs_scratch, result_scratch));
        try self.jumpToGuardIf(.ne, guard);
        try property_codegen.emitRealmU64(
            self.machine,
            .x9,
            result_scratch,
            layout.realm.globals_decl_revision,
        );
        try self.machine.emit(a64.cmpReg(lhs_scratch, result_scratch));
        try self.jumpToGuardIf(.ne, guard);

        try self.machine.emit(a64.ldrImmW(result_scratch, .x11, layout.load_ic_cell.slot));
        try self.machine.movImm64(lhs_scratch, assumption.slot);
        try self.machine.emit(a64.cmpReg(result_scratch, lhs_scratch));
        try self.jumpToGuardIf(.ne, guard);
        try property_codegen.emitSlotRead(
            self.allocator,
            self.machine,
            lhs_scratch,
            .x10,
            result_scratch,
        );
        try self.emitTaggedResult(node_id, lhs_scratch);
    }

    fn emitGlobalSlotLoad(
        self: *Compiler,
        node_id: ir.ValueId,
        lowering_kind: specialize.Lowering,
    ) !void {
        if (lowering_kind != .load_global_slot) return error.UnsupportedNode;
        const absolute_index = switch (self.graph.nodes[node_id].payload) {
            .global_slot => |slot| slot,
            else => return error.MalformedGraph,
        };
        const guard = try self.guardFor(node_id);
        var have_running_realm: Masm.Label = .{};
        defer have_running_realm.deinit(self.allocator);
        try self.machine.emit(a64.ldrImm(
            lhs_scratch,
            lowering.lantern_frame_register,
            layout.frame.running_realm,
        ));
        try self.machine.jumpCbnz(lhs_scratch, &have_running_realm);
        try self.machine.emit(a64.movReg(lhs_scratch, lowering.realm_register));
        self.machine.bind(&have_running_realm);

        try property_codegen.emitRealmU64(
            self.machine,
            lhs_scratch,
            rhs_scratch,
            layout.realm.globals_decl_slots_len,
        );
        try self.machine.movImm64(result_scratch, absolute_index);
        try self.machine.emit(a64.cmpReg(rhs_scratch, result_scratch));
        try self.jumpToGuardIf(.ls, guard);
        try property_codegen.emitRealmU64(
            self.machine,
            lhs_scratch,
            rhs_scratch,
            layout.realm.globals_decl_slots_ptr,
        );
        try self.machine.emit(a64.lslImm(result_scratch, result_scratch, 3));
        try self.machine.emit(a64.addReg(rhs_scratch, rhs_scratch, result_scratch));
        try self.machine.emit(a64.ldrImm(lhs_scratch, rhs_scratch, 0));
        try self.emitTaggedResult(node_id, lhs_scratch);
    }

    fn emitEnvironmentLoad(
        self: *Compiler,
        node_id: ir.ValueId,
        lowering_kind: specialize.Lowering,
    ) !void {
        if (lowering_kind != .load_environment) return error.UnsupportedNode;
        const site = switch (self.graph.nodes[node_id].payload) {
            .environment_load => |environment| environment,
            else => return error.MalformedGraph,
        };
        if (site.depth > 8) return error.InvalidMetadata;
        const guard = try self.guardFor(node_id);
        try self.machine.emit(a64.ldrImm(
            lhs_scratch,
            lowering.lantern_frame_register,
            layout.frame.env,
        ));
        try self.machine.emit(a64.cmpImm(lhs_scratch, 0, false));
        try self.jumpToGuardIf(.eq, guard);
        var depth = site.depth;
        while (depth > 0) : (depth -= 1) {
            try self.machine.emit(a64.ldrImm(lhs_scratch, lhs_scratch, layout.env.parent));
            try self.machine.emit(a64.cmpImm(lhs_scratch, 0, false));
            try self.jumpToGuardIf(.eq, guard);
        }
        try self.machine.emit(a64.ldrImm(rhs_scratch, lhs_scratch, layout.env.slots_len));
        try self.machine.emit(a64.cmpImm(rhs_scratch, site.slot, false));
        try self.jumpToGuardIf(.ls, guard);
        try self.machine.emit(a64.ldrImm(lhs_scratch, lhs_scratch, layout.env.slots));
        try self.machine.emit(a64.ldrImm(
            lhs_scratch,
            lhs_scratch,
            @as(u15, site.slot) * 8,
        ));
        try self.emitTaggedResult(node_id, lhs_scratch);
    }

    fn emitTaggedInput(
        self: *Compiler,
        node_id: ir.ValueId,
        operand: usize,
        destination: a64.Reg,
    ) !void {
        if (node_id >= self.graph.nodes.len) return error.MalformedGraph;
        const node = self.graph.nodes[node_id];
        const inputs = try checkedRange(self.graph.inputs.len, node.input_start, node.input_count);
        if (operand >= inputs.len) return error.MalformedGraph;
        const input_index = inputs.start + operand;
        const producer = self.graph.inputs[input_index];
        if (producer >= self.representations.outputs.len) return error.MalformedGraph;
        try emitter.emitMove(self.machine, .{
            .source = try self.valueLocation(producer),
            .destination = .{ .register = destination },
            .source_kind = self.representations.outputs[producer],
            .destination_kind = .tagged,
            .conversion = try self.representations.conversionAt(self.graph, input_index),
        }, self.chunk.constants);
    }

    fn emitTaggedResult(self: *Compiler, node_id: ir.ValueId, source: a64.Reg) !void {
        if (node_id >= self.representations.outputs.len or
            self.representations.outputs[node_id] != .tagged)
        {
            return error.InvalidRepresentation;
        }
        try emitter.emitMove(self.machine, .{
            .source = .{ .register = source },
            .destination = try self.valueLocation(node_id),
            .source_kind = .tagged,
            .destination_kind = .tagged,
            .conversion = .none,
        }, self.chunk.constants);
        try self.emitDefinitionHome(node_id);
    }

    fn assumptionFor(
        self: *const Compiler,
        node_id: ir.ValueId,
        expected_kind: specialize.AssumptionKind,
    ) !specialize.Assumption {
        if (node_id >= self.graph.nodes.len or node_id >= self.specialization.node_info.len) {
            return error.MalformedGraph;
        }
        const info = self.specialization.node_info[node_id];
        const assumption_index = info.assumption orelse return error.InvalidMetadata;
        if (assumption_index >= self.specialization.assumptions.len) {
            return error.InvalidMetadata;
        }
        const assumption = self.specialization.assumptions[assumption_index];
        if (assumption.kind != expected_kind) return error.InvalidMetadata;
        const feedback_index = switch (self.graph.nodes[node_id].payload) {
            .named_load => |named| named.feedback_index,
            .global_load => |global| global.feedback_index,
            else => return error.MalformedGraph,
        };
        if (assumption.feedback_index != feedback_index) return error.InvalidMetadata;
        return assumption;
    }

    /// AArch64 conditional branches reach only +/-1 MiB. Keep the conditional
    /// local, then use the +/-128 MiB unconditional form for the cold exit.
    fn jumpToGuardIf(self: *Compiler, condition: a64.Cond, guard: *Masm.Label) !void {
        var passed: Masm.Label = .{};
        defer passed.deinit(self.allocator);
        const inverse: a64.Cond = @enumFromInt(@intFromEnum(condition) ^ 1);
        try self.machine.jumpCond(inverse, &passed);
        try self.machine.jump(guard);
        self.machine.bind(&passed);
    }

    fn jumpToGuardIfNonzero(
        self: *Compiler,
        value: a64.Reg,
        guard: *Masm.Label,
    ) !void {
        var zero: Masm.Label = .{};
        defer zero.deinit(self.allocator);
        try self.machine.jumpCbz(value, &zero);
        try self.machine.jump(guard);
        self.machine.bind(&zero);
    }

    fn jumpToGuardIfBitSet(
        self: *Compiler,
        value: a64.Reg,
        bit: u6,
        guard: *Masm.Label,
    ) !void {
        var clear: Masm.Label = .{};
        defer clear.deinit(self.allocator);
        try self.machine.jumpTbz(value, bit, &clear);
        try self.machine.jump(guard);
        self.machine.bind(&clear);
    }

    fn emitReturn(self: *Compiler, node_id: ir.ValueId) !void {
        const node = self.graph.nodes[node_id];
        const inputs = try checkedRange(self.graph.inputs.len, node.input_start, node.input_count);
        if (inputs.len != 1) return error.MalformedGraph;
        const producer = self.graph.inputs[inputs.start];
        if (producer >= self.representations.outputs.len) return error.MalformedGraph;
        const expected_conversion = try self.taggedConversion(producer);
        if (try self.representations.conversionAt(self.graph, inputs.start) != expected_conversion) {
            return error.InvalidRepresentation;
        }
        try self.emitTaggedValue(producer, .x0);
        try emitter.emitEpilogue(self.machine, self.lowered.frame);
    }

    fn emitBranch(self: *Compiler, block_index: usize, node_id: ir.ValueId) !void {
        const node = self.graph.nodes[node_id];
        const inputs = try checkedRange(self.graph.inputs.len, node.input_start, node.input_count);
        if (inputs.len != 1) return error.MalformedGraph;
        const condition = switch (node.payload) {
            .branch => |value| value,
            else => return error.MalformedGraph,
        };
        if (try self.fused_control.strictEqualForBranch(node_id)) |comparison| {
            try self.emitFusedStrictEqualBranch(block_index, comparison, condition);
            return;
        }
        const producer = self.graph.inputs[inputs.start];
        const location = try self.valueLocation(producer);
        if (location == .immediate) {
            const edge_index = try self.selectedStaticBranchEdge(block_index, node_id);
            try self.emitEdgeAndJump(edge_index);
            return;
        }
        if (producer >= self.graph.nodes.len or producer >= self.representations.outputs.len) {
            return error.MalformedGraph;
        }
        const output_kind = self.representations.outputs[producer];
        const input_conversion = try self.representations.conversionAt(self.graph, inputs.start);
        const boxed_int32 = output_kind == .int32 and input_conversion == .box_int32;
        const strict_boolean = output_kind == .tagged and input_conversion == .none and switch (self.graph.nodes[producer].kind) {
            .strict_eq, .logical_not => true,
            else => false,
        };
        if (!boxed_int32 and !strict_boolean) {
            return error.UnsupportedNode;
        }
        if (condition == .nullish) {
            try self.emitEdgeAndJump(try self.edgeForKind(block_index, .branch_fallthrough));
            return;
        }

        try emitter.emitMove(self.machine, .{
            .source = location,
            .destination = .{ .register = lhs_scratch },
            .source_kind = output_kind,
            .destination_kind = output_kind,
            .conversion = .none,
        }, self.chunk.constants);
        if (boxed_int32) {
            try self.machine.emit(a64.cmpImm(lhs_scratch, 0, false));
        } else {
            try self.machine.movImm64(rhs_scratch, Value.false_.bits);
            try self.machine.emit(a64.cmpReg(lhs_scratch, rhs_scratch));
        }
        try self.emitConditionalEdges(
            block_index,
            if (condition == .truthy) .ne else .eq,
        );
    }

    fn emitFusedStrictEqualBranch(
        self: *Compiler,
        block_index: usize,
        comparison: ir.ValueId,
        condition: ir.BranchCondition,
    ) !void {
        if (condition == .nullish or comparison >= self.graph.nodes.len or
            comparison >= self.specialization.node_info.len or
            comparison >= self.representations.outputs.len or
            comparison >= self.lowered.locations.len or comparison >= self.homes.values.len)
        {
            return error.InvalidControlFusion;
        }
        const node = self.graph.nodes[comparison];
        const info = self.specialization.node_info[comparison];
        if (node.kind != .strict_eq or node.frame_state == null or
            info.lowering != .strict_eq or self.representations.outputs[comparison] != .tagged or
            self.lowered.locations[comparison] != .none or self.homes.values[comparison] != null)
        {
            return error.InvalidControlFusion;
        }

        const guard = try self.guardFor(comparison);
        try self.emitInt32Input(comparison, 0, lhs_scratch, guard);
        try self.emitInt32Input(comparison, 1, rhs_scratch, guard);
        try self.machine.emit(a64.eorRegW(result_scratch, lhs_scratch, rhs_scratch));
        try self.emitZeroConditionalEdges(
            block_index,
            result_scratch,
            condition == .truthy,
        );
    }

    fn emitZeroConditionalEdges(
        self: *Compiler,
        block_index: usize,
        value: a64.Reg,
        take_if_zero: bool,
    ) !void {
        if (try self.canElideFallthroughEdge(block_index)) {
            var fallthrough: Masm.Label = .{};
            defer fallthrough.deinit(self.allocator);
            if (take_if_zero) {
                try self.machine.jumpCbnz(value, &fallthrough);
            } else {
                try self.machine.jumpCbz(value, &fallthrough);
            }
            try self.emitEdgeAndJump(try self.edgeForKind(block_index, .branch_taken));
            self.machine.bind(&fallthrough);
            return;
        }
        var taken: Masm.Label = .{};
        defer taken.deinit(self.allocator);
        if (take_if_zero) {
            try self.machine.jumpCbz(value, &taken);
        } else {
            try self.machine.jumpCbnz(value, &taken);
        }
        try self.emitEdgeAndJump(try self.edgeForKind(block_index, .branch_fallthrough));
        self.machine.bind(&taken);
        try self.emitEdgeAndJump(try self.edgeForKind(block_index, .branch_taken));
    }

    fn emitConditionalEdges(
        self: *Compiler,
        block_index: usize,
        taken_condition: a64.Cond,
    ) !void {
        if (try self.canElideFallthroughEdge(block_index)) {
            var fallthrough: Masm.Label = .{};
            defer fallthrough.deinit(self.allocator);
            const inverse: a64.Cond = @enumFromInt(@intFromEnum(taken_condition) ^ 1);
            try self.machine.jumpCond(inverse, &fallthrough);
            try self.emitEdgeAndJump(try self.edgeForKind(block_index, .branch_taken));
            self.machine.bind(&fallthrough);
            return;
        }
        var taken: Masm.Label = .{};
        defer taken.deinit(self.allocator);
        try self.machine.jumpCond(taken_condition, &taken);
        try self.emitEdgeAndJump(try self.edgeForKind(block_index, .branch_fallthrough));
        self.machine.bind(&taken);
        try self.emitEdgeAndJump(try self.edgeForKind(block_index, .branch_taken));
    }

    /// Blocks are emitted in bytecode order. When the fallthrough successor is
    /// physically next and its verified transfer is empty, branch over only
    /// the taken-edge transfer and let execution enter that block directly.
    fn canElideFallthroughEdge(self: *const Compiler, block_index: usize) !bool {
        if (block_index >= self.graph.blocks.len) return error.MalformedGraph;
        var next = block_index + 1;
        while (next < self.graph.blocks.len and !self.graph.blocks[next].reachable) : (next += 1) {}
        if (next >= self.graph.blocks.len) return false;

        const edge_index = try self.edgeForKind(block_index, .branch_fallthrough);
        if (edge_index >= self.graph.edges.len or edge_index >= self.lowered.edges.len) {
            return error.MalformedGraph;
        }
        const edge = self.graph.edges[edge_index];
        if (edge.from != block_index or edge.to != next) return false;
        const edge_plan = self.lowered.edges[edge_index];
        _ = try checkedRange(
            self.lowered.moves.len,
            edge_plan.move_start,
            edge_plan.move_count,
        );
        if (edge_plan.move_count != 0) return false;

        const target = self.graph.blocks[edge.to];
        const params = try checkedRange(self.graph.params.len, target.param_start, target.param_count);
        for (self.graph.params[params.start..params.end()]) |param| {
            if (param.value >= self.homes.values.len) return error.InvalidMetadata;
            if (self.homes.values[param.value] != null) return false;
        }
        return true;
    }

    fn emitEdgeAndJump(self: *Compiler, edge_index: usize) !void {
        if (edge_index >= self.graph.edges.len) return error.MalformedGraph;
        const edge = self.graph.edges[edge_index];
        try self.emitEdge(edge_index);
        const target = edge.to;
        if (target >= self.block_labels.len or !self.graph.blocks[target].reachable) {
            return error.MalformedGraph;
        }
        if (try self.isBackEdge(edge)) {
            var slow: Masm.Label = .{};
            defer slow.deinit(self.allocator);
            try safepoint_codegen.emitPoll(
                self.machine,
                lowering.realm_register,
                &slow,
            );
            try self.machine.jump(&self.block_labels[target]);
            self.machine.bind(&slow);
            try self.emitSafepointExit(target);
            return;
        }
        try self.machine.jump(&self.block_labels[target]);
    }

    fn emitEdge(self: *Compiler, edge_index: usize) !void {
        if (edge_index >= self.graph.edges.len or edge_index >= self.lowered.edges.len) {
            return error.MalformedGraph;
        }
        const edge_plan = self.lowered.edges[edge_index];
        const moves = try checkedRange(
            self.lowered.moves.len,
            edge_plan.move_start,
            edge_plan.move_count,
        );
        for (self.lowered.moves[moves.start..moves.end()]) |move| {
            try emitter.emitMove(self.machine, move, self.chunk.constants);
        }

        const edge = self.graph.edges[edge_index];
        if (edge.to >= self.graph.blocks.len) return error.MalformedGraph;
        const target = self.graph.blocks[edge.to];
        const params = try checkedRange(self.graph.params.len, target.param_start, target.param_count);
        for (self.graph.params[params.start..params.end()]) |param| {
            try self.emitDefinitionHome(param.value);
        }
    }

    fn emitDefinitionHome(self: *Compiler, value: ir.ValueId) !void {
        if (value >= self.homes.values.len or value >= self.representations.outputs.len) {
            return error.InvalidMetadata;
        }
        const home = self.homes.values[value] orelse return;
        const source = try self.valueLocation(value);
        const destination: parallel_moves.Location = switch (home) {
            .tagged_stack => |slot| .{
                .tagged_stack = try self.lowered.frame.taggedByteOffset(slot),
            },
            .int32_stack => |slot| .{
                .int32_stack = try self.lowered.frame.int32ByteOffset(slot),
            },
        };
        if (parallel_moves.eql(source, destination)) return;
        const kind = self.representations.outputs[value];
        if (source == .none or source == .immediate or kind == .none) {
            return error.InvalidMetadata;
        }
        try emitter.emitMove(self.machine, .{
            .source = source,
            .destination = destination,
            .source_kind = kind,
            .destination_kind = kind,
            .conversion = .none,
        }, self.chunk.constants);
    }

    /// A slow backedge has already applied its edge moves, so target block
    /// parameters are the exact interpreter-visible loop-header state. Copy
    /// the accumulator and every live-in register back to the Lantern frame
    /// before returning; GC then sees only its normal precise root set.
    fn emitSafepointExit(self: *Compiler, target_index: usize) !void {
        if (target_index >= self.graph.blocks.len) return error.MalformedGraph;
        const target = self.graph.blocks[target_index];
        const params = try checkedRange(
            self.graph.params.len,
            target.param_start,
            target.param_count,
        );
        var saw_accumulator = false;
        var seen_registers: [256]bool = @splat(false);
        for (self.graph.params[params.start..params.end()]) |param| {
            try self.emitTaggedValue(param.value, lhs_scratch);
            const destination_base: a64.Reg, const destination: u15 = switch (param.role) {
                .accumulator => blk: {
                    if (saw_accumulator) return error.MalformedGraph;
                    saw_accumulator = true;
                    break :blk .{
                        lowering.lantern_frame_register,
                        layout.frame.accumulator,
                    };
                },
                .register => |register| blk: {
                    if (register >= self.graph.register_count or
                        register >= self.chunk.register_count or
                        seen_registers[register])
                    {
                        return error.MalformedGraph;
                    }
                    seen_registers[register] = true;
                    break :blk .{
                        lowering.lantern_registers_register,
                        try registerOffset(register),
                    };
                },
            };
            try self.machine.emit(a64.strImm(
                lhs_scratch,
                destination_base,
                destination,
            ));
        }
        if (!saw_accumulator) return error.MalformedGraph;
        if (target.start >= self.chunk.code.len) return error.MalformedGraph;
        try self.machine.movImm64(lhs_scratch, target.start);
        try self.machine.emit(a64.strImm(
            lhs_scratch,
            lowering.lantern_frame_register,
            layout.frame.ip,
        ));
        try self.machine.movImm64(.x0, resume_sentinel_bits);
        try emitter.emitEpilogue(self.machine, self.lowered.frame);
    }

    fn emitTaggedValue(
        self: *Compiler,
        value: ir.ValueId,
        destination: a64.Reg,
    ) !void {
        if (value >= self.representations.outputs.len) return error.MalformedGraph;
        const source_kind = self.representations.outputs[value];
        try emitter.emitMove(self.machine, .{
            .source = try self.valueLocation(value),
            .destination = .{ .register = destination },
            .source_kind = source_kind,
            .destination_kind = .tagged,
            .conversion = try self.taggedConversion(value),
        }, self.chunk.constants);
    }

    fn taggedConversion(self: *const Compiler, value: ir.ValueId) !representation.Conversion {
        if (value >= self.representations.outputs.len) return error.MalformedGraph;
        return switch (self.representations.outputs[value]) {
            .tagged => .none,
            .int32 => .box_int32,
            .none => error.InvalidRepresentation,
        };
    }

    fn emitGuardExit(self: *Compiler, point_index: usize) !void {
        var point = try self.physical_deopt.decode(self.allocator, point_index);
        defer point.deinit();
        try self.emitDirectFrameRecoveries(point);
        try self.emitExternalRecovery(point.accumulator, .accumulator);
        for (point.slots) |slot| {
            try self.emitExternalRecovery(
                slot.recovery,
                .{ .register = slot.register },
            );
        }
        try self.machine.movImm64(lhs_scratch, point.bytecode_offset);
        try self.machine.emit(a64.strImm(
            lhs_scratch,
            lowering.lantern_frame_register,
            layout.frame.ip,
        ));
        try self.machine.movImm64(.x0, resume_sentinel_bits);
        try emitter.emitEpilogue(self.machine, self.lowered.frame);
    }

    /// Entry-frame recoveries are parallel assignments: a destination may
    /// still hold another recipe's source. Resolve those moves before any
    /// spill/immediate write can overwrite an original Lantern value.
    fn emitDirectFrameRecoveries(
        self: *Compiler,
        point: deopt_physical.DecodedPoint,
    ) !void {
        var pending: std.ArrayListUnmanaged(FrameMove) = .empty;
        defer pending.deinit(self.allocator);
        try appendFrameMove(&pending, self.allocator, point.accumulator, .accumulator);
        for (point.slots) |slot| {
            try appendFrameMove(
                &pending,
                self.allocator,
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
                if (!frameDestinationIsSource(move.destination, pending.items)) {
                    ready = index;
                    break;
                }
            }
            if (ready) |index| {
                try self.emitFrameMove(pending.orderedRemove(index));
                continue;
            }

            var cycle_source: ?FrameLocation = null;
            for (pending.items) |move| switch (move.source) {
                .frame => |source| {
                    cycle_source = source;
                    break;
                },
                .cycle_scratch => {},
            };
            const source = cycle_source orelse return error.InvalidMetadata;
            try self.emitFrameLoad(source, guard_scratch);
            for (pending.items) |*move| switch (move.source) {
                .frame => |candidate| {
                    if (frameLocationEql(candidate, source)) {
                        move.source = .cycle_scratch;
                    }
                },
                .cycle_scratch => {},
            };
        }
    }

    fn emitFrameMove(self: *Compiler, move: FrameMove) !void {
        switch (move.source) {
            .frame => |source| try self.emitFrameLoad(source, lhs_scratch),
            .cycle_scratch => try self.machine.emit(a64.movReg(
                lhs_scratch,
                guard_scratch,
            )),
        }
        try self.emitFrameStore(move.destination, lhs_scratch);
    }

    fn emitFrameLoad(
        self: *Compiler,
        source: FrameLocation,
        destination: a64.Reg,
    ) !void {
        const base: a64.Reg, const offset: u15 = switch (source) {
            .accumulator => .{
                lowering.lantern_frame_register,
                layout.frame.accumulator,
            },
            .register => |register| .{
                lowering.lantern_registers_register,
                try registerOffset(register),
            },
        };
        try self.machine.emit(a64.ldrImm(destination, base, offset));
    }

    fn emitFrameStore(
        self: *Compiler,
        destination: FrameLocation,
        source: a64.Reg,
    ) !void {
        const base: a64.Reg, const offset: u15 = switch (destination) {
            .accumulator => .{
                lowering.lantern_frame_register,
                layout.frame.accumulator,
            },
            .register => |register| .{
                lowering.lantern_registers_register,
                try registerOffset(register),
            },
        };
        try self.machine.emit(a64.strImm(source, base, offset));
    }

    fn emitExternalRecovery(
        self: *Compiler,
        recovery: deopt_physical.Recovery,
        destination: FrameLocation,
    ) !void {
        switch (recovery) {
            .frame_accumulator, .frame_register => return,
            .tagged_stack, .int32_stack, .immediate => {},
        }
        try self.emitRecovery(recovery);
        try self.emitFrameStore(destination, lhs_scratch);
    }

    fn emitRecovery(self: *Compiler, recovery: deopt_physical.Recovery) !void {
        const source: parallel_moves.Location, const source_kind: representation.Kind = switch (recovery) {
            .frame_accumulator, .frame_register => return error.InvalidMetadata,
            .tagged_stack => |slot| .{
                .{ .tagged_stack = try self.lowered.frame.taggedByteOffset(slot) },
                .tagged,
            },
            .int32_stack => |slot| .{
                .{ .int32_stack = try self.lowered.frame.int32ByteOffset(slot) },
                .int32,
            },
            .immediate => |immediate| .{
                .{ .immediate = immediate },
                if (immediate == .int32) .int32 else .tagged,
            },
        };
        try emitter.emitMove(self.machine, .{
            .source = source,
            .destination = .{ .register = lhs_scratch },
            .source_kind = source_kind,
            .destination_kind = .tagged,
            .conversion = if (source_kind == .int32) .box_int32 else .none,
        }, self.chunk.constants);
    }

    fn guardFor(self: *Compiler, node_id: ir.ValueId) !*Masm.Label {
        if (node_id >= self.point_for_node.len) return error.InvalidMetadata;
        const point_index = self.point_for_node[node_id] orelse return error.InvalidMetadata;
        if (point_index >= self.guard_labels.len) return error.InvalidMetadata;
        return &self.guard_labels[point_index];
    }

    fn valueLocation(self: *const Compiler, value: ir.ValueId) !parallel_moves.Location {
        if (value >= self.lowered.locations.len) return error.MalformedGraph;
        const location = self.lowered.locations[value];
        if (location == .none) return error.InvalidAllocation;
        return location;
    }

    fn singleEdge(self: *const Compiler, block_index: usize) !usize {
        const edges = try self.blockEdges(block_index);
        if (edges.len != 1) return error.MalformedGraph;
        return edges.start;
    }

    fn selectedStaticBranchEdge(
        self: *const Compiler,
        block_index: usize,
        node_id: ir.ValueId,
    ) !usize {
        const node = self.graph.nodes[node_id];
        const inputs = try checkedRange(self.graph.inputs.len, node.input_start, node.input_count);
        if (inputs.len != 1) return error.MalformedGraph;
        const producer = self.graph.inputs[inputs.start];
        const location = try self.valueLocation(producer);
        const immediate = switch (location) {
            .immediate => |value| value,
            else => return error.UnsupportedNode,
        };
        const condition = switch (node.payload) {
            .branch => |value| value,
            else => return error.MalformedGraph,
        };
        const value = try immediateValue(self.chunk, immediate);
        if (value.isHole()) return error.UnsupportedNode;
        const taken = switch (condition) {
            .truthy => arith.toBoolean(value),
            .falsy => !arith.toBoolean(value),
            .nullish => value.isNullish(),
        };
        const wanted: ir.EdgeKind = if (taken) .branch_taken else .branch_fallthrough;
        return self.edgeForKind(block_index, wanted);
    }

    fn edgeForKind(
        self: *const Compiler,
        block_index: usize,
        wanted: ir.EdgeKind,
    ) !usize {
        const edges = try self.blockEdges(block_index);
        var found: ?usize = null;
        for (edges.start..edges.end()) |edge_index| {
            if (self.graph.edges[edge_index].kind != wanted) continue;
            if (found != null) return error.MalformedGraph;
            found = edge_index;
        }
        return found orelse error.MalformedGraph;
    }

    fn blockEdges(self: *const Compiler, block_index: usize) !Range {
        if (block_index >= self.graph.blocks.len) return error.MalformedGraph;
        const block = self.graph.blocks[block_index];
        return checkedRange(self.graph.edges.len, block.edge_start, block.edge_count);
    }

    fn isBackEdge(self: *const Compiler, edge: ir.Edge) !bool {
        if (edge.from >= self.graph.blocks.len or edge.to >= self.graph.blocks.len) {
            return error.MalformedGraph;
        }
        const source = self.graph.blocks[edge.from];
        const target = self.graph.blocks[edge.to];
        return target.start <= source.start;
    }
};

fn appendFrameMove(
    pending: *std.ArrayListUnmanaged(FrameMove),
    allocator: std.mem.Allocator,
    recovery: deopt_physical.Recovery,
    destination: FrameLocation,
) !void {
    const source = switch (recovery) {
        .frame_accumulator => FrameLocation.accumulator,
        .frame_register => |register| FrameLocation{ .register = register },
        .tagged_stack, .int32_stack, .immediate => return,
    };
    if (frameLocationEql(source, destination)) return;
    try pending.append(allocator, .{
        .source = .{ .frame = source },
        .destination = destination,
    });
}

fn frameDestinationIsSource(
    destination: FrameLocation,
    pending: []const FrameMove,
) bool {
    for (pending) |move| switch (move.source) {
        .frame => |source| if (frameLocationEql(destination, source)) return true,
        .cycle_scratch => {},
    };
    return false;
}

fn frameLocationEql(lhs: FrameLocation, rhs: FrameLocation) bool {
    if (std.meta.activeTag(lhs) != std.meta.activeTag(rhs)) return false;
    return switch (lhs) {
        .accumulator => true,
        .register => |register| register == rhs.register,
    };
}

fn immediateValue(chunk: *const Chunk, immediate: ir.Immediate) !Value {
    return switch (immediate) {
        .undefined_ => Value.undefined_,
        .null_ => Value.null_,
        .true_ => Value.true_,
        .false_ => Value.false_,
        .hole => Value.hole_,
        .int32 => |value| Value.fromInt32(value),
        .constant_pool => |index| if (index < chunk.constants.len)
            chunk.constants[index]
        else
            error.MalformedGraph,
    };
}

fn registerOffset(register: u8) !u15 {
    const offset = @as(u32, register) * @sizeOf(Value);
    if (offset > 32_760) return error.FrameTooLarge;
    return @intCast(offset);
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
