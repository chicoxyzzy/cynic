//! x86_64 lowering for Ohaimark.
//!
//! The x86_64 backend is intentionally narrower than the established AArch64
//! backend. Its compact entry matcher accepts constant/formal returns, profiled
//! Number multiply/divide leaves, a fused Int32 strict-equality return diamond,
//! and a monomorphic own-data named load. Its general CFG path adds typed
//! native spills, checked Int32 add/sub/mul, block-argument transfers,
//! equality/truthiness control, backedge polls, loop-header OSR, and compact
//! call/construct handoff through rooted SysV helpers. Every speculative or
//! slow exit reconstructs the shared physical deopt state before resuming
//! Lantern.

const std = @import("std");

const allocation = @import("allocation.zig");
const chunk_mod = @import("../../bytecode/chunk.zig");
const Chunk = chunk_mod.Chunk;
const control_fusion = @import("control_fusion.zig");
const deopt = @import("deopt.zig");
const x86 = @import("../jit/asm_x86_64.zig");
const layout = @import("../jit/layout.zig");
const arith = @import("../lantern/arith.zig");
const Value = @import("../value.zig").Value;
const heap_mod = @import("../heap.zig");
const call_handoff = @import("call_handoff.zig");
const call_mod = @import("../lantern/call.zig");
const computed_codegen = @import("computed_codegen_x86_64.zig");
const deopt_physical = @import("deopt_physical.zig");
const frame_recovery = @import("frame_recovery.zig");
const frame_safepoint = @import("frame_safepoint.zig");
const ir = @import("ir.zig");
const leaf = @import("codegen_x86_64_leaf.zig");
const osr_mod = @import("osr.zig");
const property_codegen = @import("property_codegen_x86_64.zig");
const representation = @import("representation.zig");
const safepoint_codegen = @import("safepoint_codegen_x86_64.zig");
const shared = @import("codegen_x86_64_shared.zig");
const specialize = @import("specialize.zig");
const entry = @import("entry_result.zig");
const feedback_retry = @import("feedback_retry.zig");

const FrameLocation = shared.FrameLocation;
const emitFrameLoad = shared.emitFrameLoad;
const emitFrameMove = shared.emitFrameMove;
const emitFrameStore = shared.emitFrameStore;
const immediateValueBits = shared.immediateValueBits;
const nodeInputs = shared.nodeInputs;
const registerOffset = shared.registerOffset;

pub const native_x86_64 = x86.native_x86_64;
pub const value_register_count: u8 = 3;

/// Unsupported operations are deliberately rejected before installation. The
/// general path may use typed native spills and the compact call handoff, but
/// every other observable operation remains a normal T2 refusal and leaves
/// Bistromath/Lantern intact.
pub const EmitError = error{
    UnsupportedTarget,
    UnsupportedGraph,
    UnsupportedConstant,
    MalformedGraph,
    InvalidRepresentation,
    RetryableFeedback,
};
pub const RetryableFeedback = feedback_retry.Site;
pub const retryFeedbackFingerprint = feedback_retry.fingerprint;

pub const emitImmediateReturn = leaf.emitImmediateReturn;
pub const emitFrameRegisterReturn = leaf.emitFrameRegisterReturn;
pub const emitFrameAccumulatorReturn = leaf.emitFrameAccumulatorReturn;
pub const emitGraph = leaf.emitGraph;

/// Emit the general CFG subset and append loop-header OSR stubs. Helper-free
/// graphs without loops retain the smaller leaf/diamond matcher above.
pub fn emitGraphCollectingOsr(
    allocator: std.mem.Allocator,
    machine: *x86.Masm,
    chunk: *const Chunk,
    graph: *const ir.Graph,
    specialization: *const specialize.Plan,
    representations: *const representation.Plan,
    fused_control: *const control_fusion.Plan,
    logical: *const deopt.Metadata,
    homes: *const deopt_physical.Homes,
    physical_deopt: *const deopt_physical.Metadata,
    allocated: *const allocation.Plan,
    osr_entries: *std.ArrayListUnmanaged(Chunk.JitState.OsrEntry),
) !void {
    var retryable_feedback: ?RetryableFeedback = null;
    return emitGraphCollectingOsrDiagnosed(
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
        osr_entries,
        &retryable_feedback,
    );
}

pub fn emitGraphCollectingOsrDiagnosed(
    allocator: std.mem.Allocator,
    machine: *x86.Masm,
    chunk: *const Chunk,
    graph: *const ir.Graph,
    specialization: *const specialize.Plan,
    representations: *const representation.Plan,
    fused_control: *const control_fusion.Plan,
    logical: *const deopt.Metadata,
    homes: *const deopt_physical.Homes,
    physical_deopt: *const deopt_physical.Metadata,
    allocated: *const allocation.Plan,
    osr_entries: *std.ArrayListUnmanaged(Chunk.JitState.OsrEntry),
    retryable_feedback: *?RetryableFeedback,
) !void {
    if (comptime !native_x86_64) return error.UnsupportedTarget;
    if (graph.blocks.len == 0) return error.UnsupportedGraph;
    try specialization.verify(graph);
    try representations.verify(graph, specialization);
    try fused_control.verify(graph, specialization, representations);
    try physical_deopt.verify(
        graph,
        specialization,
        representations,
        logical,
        homes,
    );
    try allocated.verify(
        graph,
        specialization,
        representations,
        fused_control,
        homes,
    );

    var osr_meta = try osr_mod.Metadata.build(allocator, graph);
    defer osr_meta.deinit();
    try osr_meta.verify(graph);
    if (osr_meta.headers.len == 0 and !graphRequiresFrameScope(graph)) {
        const leaf_code_start = machine.code.items.len;
        emitGraph(
            allocator,
            machine,
            chunk,
            graph,
            specialization,
            representations,
            physical_deopt,
        ) catch |err| switch (err) {
            error.UnsupportedGraph, error.UnsupportedConstant => {
                machine.code.shrinkRetainingCapacity(leaf_code_start);
            },
            else => return err,
        };
        if (machine.code.items.len != leaf_code_start) return;
    }

    const frame = try SpillFrame.build(
        allocated.tagged_slot_count,
        allocated.int32_slot_count,
    );
    const locations = try allocator.alloc(PhysicalLocation, graph.nodes.len);
    defer allocator.free(locations);
    try mapPhysicalLocations(allocated, frame, locations);

    const block_labels = try allocator.alloc(x86.Masm.Label, graph.blocks.len);
    defer {
        for (block_labels) |*label| label.deinit(allocator);
        allocator.free(block_labels);
    }
    for (block_labels) |*label| label.* = .{};

    const guard_labels = try allocator.alloc(
        x86.Masm.Label,
        physical_deopt.points.len,
    );
    defer {
        for (guard_labels) |*label| label.deinit(allocator);
        allocator.free(guard_labels);
    }
    for (guard_labels) |*label| label.* = .{};

    const point_for_node = try allocator.alloc(?usize, graph.nodes.len);
    defer allocator.free(point_for_node);
    @memset(point_for_node, null);
    for (physical_deopt.points, 0..) |point, point_index| {
        if (point.node >= point_for_node.len or
            point_for_node[point.node] != null)
        {
            return error.InvalidMetadata;
        }
        point_for_node[point.node] = point_index;
    }

    var compiler: CfgCompiler = .{
        .allocator = allocator,
        .machine = machine,
        .chunk = chunk,
        .graph = graph,
        .specialization = specialization,
        .representations = representations,
        .fused_control = fused_control,
        .homes = homes,
        .physical_deopt = physical_deopt,
        .allocated = allocated,
        .frame = frame,
        .locations = locations,
        .block_labels = block_labels,
        .guard_labels = guard_labels,
        .point_for_node = point_for_node,
        .osr_meta = &osr_meta,
        .osr_entries = osr_entries,
        .retryable_feedback = retryable_feedback,
    };
    const code_start = machine.code.items.len;
    const osr_start = osr_entries.items.len;
    errdefer {
        machine.code.shrinkRetainingCapacity(code_start);
        osr_entries.shrinkRetainingCapacity(osr_start);
    }
    try compiler.emit();
}

/// Generated x86 helpers first reconstruct the exact Lantern frame, then rely
/// on the runtime entry scope to keep that frame reachable across allocation
/// and callee handoff. Helper-free graphs need no entry bookkeeping.
pub fn graphRequiresFrameScope(graph: *const ir.Graph) bool {
    if (graph.entry_environment_slots != null) return true;
    for (graph.nodes) |node| {
        if (node.kind == .direct_call or
            frame_safepoint.nodeRequiresScope(node.kind))
        {
            return true;
        }
    }
    return false;
}

const value_registers = [_]x86.Reg{ .r8, .r9, .r10 };
const cycle_scratch = shared.frame_cycle_scratch;
const lhs_scratch = shared.frame_move_scratch;
const rhs_scratch: x86.Reg = .rcx;

comptime {
    for (value_registers) |register| {
        if (register == cycle_scratch or
            register == lhs_scratch or
            register == rhs_scratch)
        {
            @compileError("x86 Ohaimark value and recovery registers overlap");
        }
    }
}

const SpillFrame = struct {
    tagged_slot_count: u32,
    int32_slot_count: u32,
    int32_start: u32,
    bytes: u32,

    fn build(tagged_slot_count: u32, int32_slot_count: u32) !SpillFrame {
        const tagged_bytes = try std.math.mul(u64, tagged_slot_count, @sizeOf(Value));
        const int32_bytes = try std.math.mul(u64, int32_slot_count, @sizeOf(i32));
        const raw = try std.math.add(u64, tagged_bytes, int32_bytes);
        const padded = try std.math.add(u64, raw, 15);
        const aligned = padded & ~@as(u64, 15);
        if (aligned > std.math.maxInt(i32)) return error.FrameTooLarge;
        return .{
            .tagged_slot_count = tagged_slot_count,
            .int32_slot_count = int32_slot_count,
            .int32_start = std.math.cast(u32, tagged_bytes) orelse
                return error.FrameTooLarge,
            .bytes = @intCast(aligned),
        };
    }

    fn taggedOffset(self: SpillFrame, slot: u32) !i32 {
        if (slot >= self.tagged_slot_count) return error.InvalidMetadata;
        const bytes = try std.math.mul(u64, slot, @sizeOf(Value));
        return std.math.cast(i32, bytes) orelse error.FrameTooLarge;
    }

    fn int32Offset(self: SpillFrame, slot: u32) !i32 {
        if (slot >= self.int32_slot_count) return error.InvalidMetadata;
        const relative = try std.math.mul(u64, slot, @sizeOf(i32));
        const bytes = try std.math.add(u64, self.int32_start, relative);
        return std.math.cast(i32, bytes) orelse error.FrameTooLarge;
    }
};

const PhysicalLocation = union(enum) {
    none,
    immediate: ir.Immediate,
    register: x86.Reg,
    tagged_stack: i32,
    int32_stack: i32,
};

fn mapPhysicalLocations(
    allocated: *const allocation.Plan,
    frame: SpillFrame,
    output: []PhysicalLocation,
) !void {
    if (output.len != allocated.locations.len) return error.MalformedGraph;
    for (allocated.locations, output) |source, *destination| {
        destination.* = switch (source) {
            .none => .none,
            .immediate => |value| .{ .immediate = value },
            .register => |index| .{
                .register = if (index < value_registers.len)
                    value_registers[index]
                else
                    return error.UnsupportedGraph,
            },
            .tagged_stack => |slot| .{
                .tagged_stack = try frame.taggedOffset(slot),
            },
            .int32_stack => |slot| .{
                .int32_stack = try frame.int32Offset(slot),
            },
        };
    }
}

const CfgCompiler = struct {
    allocator: std.mem.Allocator,
    machine: *x86.Masm,
    chunk: *const Chunk,
    graph: *const ir.Graph,
    specialization: *const specialize.Plan,
    representations: *const representation.Plan,
    fused_control: *const control_fusion.Plan,
    homes: *const deopt_physical.Homes,
    physical_deopt: *const deopt_physical.Metadata,
    allocated: *const allocation.Plan,
    frame: SpillFrame,
    locations: []const PhysicalLocation,
    block_labels: []x86.Masm.Label,
    guard_labels: []x86.Masm.Label,
    point_for_node: []const ?usize,
    osr_meta: *const osr_mod.Metadata,
    osr_entries: *std.ArrayListUnmanaged(Chunk.JitState.OsrEntry),
    retryable_feedback: *?RetryableFeedback,

    fn emit(self: *CfgCompiler) !void {
        try self.emitPrologue();
        if (self.graph.entry_environment_slots) |slot_count| {
            try self.emitEntryEnvironment(slot_count);
        }
        try self.materializeBlockParametersFromFrame(0, null);
        for (self.graph.blocks, 0..) |block, block_index| {
            if (!block.reachable) continue;
            try self.machine.bind(&self.block_labels[block_index]);
            try self.emitBlock(block_index, block);
        }
        try self.emitOsrEntries();
        for (self.physical_deopt.points, 0..) |_, point_index| {
            try self.machine.bind(&self.guard_labels[point_index]);
            try self.emitGuardExit(point_index);
        }
    }

    fn emitPrologue(self: *CfgCompiler) !void {
        if (self.frame.bytes != 0) {
            try self.machine.subRegImm32(.rsp, self.frame.bytes);
        }
    }

    fn emitEpilogue(self: *CfgCompiler) !void {
        if (self.frame.bytes != 0) {
            try self.machine.addRegImm32(.rsp, self.frame.bytes);
        }
        try self.machine.ret();
    }

    fn emitEntryEnvironment(
        self: *CfgCompiler,
        slot_count: u8,
    ) !void {
        var succeeded: x86.Masm.Label = .{};
        defer succeeded.deinit(self.allocator);
        try self.emitNonReentrantCall(.{
            .allocate = .{ .slot_count = slot_count },
        });
        try self.machine.testReg64(cycle_scratch, cycle_scratch);
        try self.machine.jumpCond(.equal, &succeeded);

        // The original frame is still authoritative. Replay bytecode zero so
        // Lantern owns allocation failure and exception materialization.
        try self.machine.movImm64(lhs_scratch, 0);
        try self.machine.store64Disp32(
            .rsi,
            layout.frame.ip,
            lhs_scratch,
        );
        try self.machine.movImm64(.rax, entry.resume_sentinel_bits);
        try self.emitEpilogue();

        try self.machine.bind(&succeeded);
    }

    fn emitBlock(
        self: *CfgCompiler,
        block_index: usize,
        block: ir.Block,
    ) !void {
        const body = try checkedGraphRange(
            self.graph.nodes.len,
            block.node_start,
            block.node_count,
        );
        if (body.len == 0) return error.MalformedGraph;
        var terminated = false;
        for (body.start..body.end()) |node_index| {
            if (terminated) return error.MalformedGraph;
            terminated = try self.emitNode(block_index, @intCast(node_index));
        }
        if (!terminated) return error.MalformedGraph;
    }

    fn emitNode(
        self: *CfgCompiler,
        block_index: usize,
        node_id: ir.ValueId,
    ) !bool {
        if (node_id >= self.graph.nodes.len or
            node_id >= self.specialization.node_info.len)
        {
            return error.MalformedGraph;
        }
        const node = self.graph.nodes[node_id];
        const info = self.specialization.node_info[node_id];
        switch (node.kind) {
            .constant => return false,
            .add, .sub, .mul => {
                if (info.lowering != .constant) {
                    try self.emitCheckedArithmetic(node_id, node.kind, info.lowering);
                }
                return false;
            },
            .strict_eq => {
                if (info.lowering == .constant) return false;
                if (!(try self.fused_control.valueIsElided(node_id))) {
                    return error.UnsupportedGraph;
                }
                return false;
            },
            .logical_not => {
                if (info.lowering != .constant) {
                    try self.emitLogicalNot(node_id, info.lowering);
                }
                return false;
            },
            .to_numeric => {
                try self.emitToNumeric(node_id, info.lowering);
                return false;
            },
            .less_than => {
                if (info.lowering != .constant) {
                    try self.emitLessThan(node_id, info.lowering);
                }
                return false;
            },
            .direct_call => {
                // Every outcome returns to the driver. Keep the bytecode
                // continuation structurally present for Lantern to re-enter
                // after the child frame completes.
                try self.emitDirectCall(node_id, info.lowering);
                return false;
            },
            .load_named => {
                try self.emitNamedLoad(node_id, info.lowering);
                return false;
            },
            .store_named => {
                try self.emitNamedStore(node_id, info.lowering);
                return false;
            },
            .load_computed => {
                try self.emitComputedLoad(node_id, info.lowering);
                return false;
            },
            .store_computed => {
                try self.emitComputedStore(node_id, info.lowering);
                return false;
            },
            .allocate_environment => {
                try self.emitEnvironmentAllocate(node_id, info.lowering);
                return false;
            },
            .load_environment => {
                try self.emitEnvironmentLoad(node_id, info.lowering);
                return false;
            },
            .store_environment => {
                try self.emitEnvironmentStore(node_id, info.lowering);
                return false;
            },
            .pop_environment => {
                try self.emitEnvironmentPop(node_id, info.lowering);
                return false;
            },
            .create_unmapped_arguments_object => {
                try self.emitUnmappedArgumentsObject(node_id, info.lowering);
                return false;
            },
            .create_ordinary_function => {
                try self.emitOrdinaryFunction(node_id, info.lowering);
                return false;
            },
            .set_home => {
                try self.emitSetHome(node_id, info.lowering);
                return false;
            },
            .define_object_method_property => {
                try self.emitObjectMethodProperty(node_id, info.lowering);
                return false;
            },
            .create_object_literal => {
                try self.emitObjectLiteral(node_id, info.lowering);
                return false;
            },
            .create_dense_array_literal => {
                try self.emitDenseArrayLiteral(node_id, info.lowering);
                return false;
            },
            .create_array_literal => {
                try self.emitArrayLiteral(node_id, info.lowering);
                return false;
            },
            .append_dense_array_literal_element => {
                try self.emitDenseArrayAppend(node_id, info.lowering);
                return false;
            },
            .define_template_property => {
                try self.emitTemplateProperty(node_id, info.lowering);
                return false;
            },
            .delete_computed_property => {
                try self.emitComputedDelete(node_id, info.lowering);
                return false;
            },
            .tail_dispatch => {
                try self.emitTailDispatch(node_id, info.lowering);
                return true;
            },
            .throw_ => {
                try self.emitThrow(node_id, info.lowering);
                return true;
            },
            .throw_if_hole => {
                try self.emitThrowIfHole(node_id, info.lowering);
                return false;
            },
            .jump => {
                try self.emitEdgeAndJump(try self.singleEdge(block_index));
                return true;
            },
            .branch => {
                try self.emitBranch(block_index, node_id);
                return true;
            },
            .return_ => {
                try self.emitReturn(node_id);
                return true;
            },
            .block_parameter => return error.MalformedGraph,
            else => return error.UnsupportedGraph,
        }
    }

    /// §7.1.4's already-numeric Int32 lane. Every exception-capable coercion
    /// resumes the original ToNumeric bytecode through the physical guard.
    fn emitToNumeric(
        self: *CfgCompiler,
        node_id: ir.ValueId,
        lowering_kind: specialize.Lowering,
    ) !void {
        if (lowering_kind != .checked_int32_to_numeric or
            self.representations.outputs[node_id] != .int32)
        {
            return error.UnsupportedGraph;
        }
        const guard = try self.guardFor(node_id);
        try self.emitInt32Input(node_id, 0, lhs_scratch, guard);
        if (self.locations[node_id] == .none) return;
        try self.storeLocation(
            self.locations[node_id],
            .int32,
            lhs_scratch,
        );
        try self.emitDefinitionHome(node_id);
    }

    fn emitNamedLoad(
        self: *CfgCompiler,
        node_id: ir.ValueId,
        lowering_kind: specialize.Lowering,
    ) !void {
        const site = try self.namedLoadSite(node_id);
        if (lowering_kind == .load_named_generic) {
            return self.deferForFeedback(.{
                .named_load = site.feedback_index,
            });
        }
        if (lowering_kind != .load_named_own or
            self.representations.outputs[node_id] != .tagged)
        {
            return error.UnsupportedGraph;
        }
        const node = self.graph.nodes[node_id];
        const inputs = try nodeInputs(self.graph, node);
        if (inputs.len != 1) return error.MalformedGraph;
        const producer = self.graph.inputs[inputs.start];
        if (producer >= self.locations.len or
            producer >= self.representations.outputs.len)
        {
            return error.MalformedGraph;
        }
        if (self.representations.outputs[producer] != .tagged or
            try self.representations.conversionAt(
                self.graph,
                inputs.start,
            ) != .none)
        {
            return error.InvalidRepresentation;
        }

        const guard = try self.guardFor(node_id);
        try self.loadLocation(
            self.locations[producer],
            .tagged,
            lhs_scratch,
        );
        try property_codegen.emitOwn(
            self.machine,
            try property_codegen.ownSite(
                self.chunk,
                self.graph,
                self.specialization,
                node_id,
            ),
            lhs_scratch,
            guard,
        );
        if (self.locations[node_id] == .none) return;
        try self.storeLocation(
            self.locations[node_id],
            .tagged,
            lhs_scratch,
        );
        try self.emitDefinitionHome(node_id);
    }

    fn emitNamedStore(
        self: *CfgCompiler,
        node_id: ir.ValueId,
        lowering_kind: specialize.Lowering,
    ) !void {
        const site = try self.namedStoreSite(node_id);
        if (lowering_kind == .store_named_generic) {
            return self.deferForFeedback(.{
                .named_store = site.feedback_index,
            });
        }
        if (lowering_kind != .store_named_own or
            self.representations.outputs[node_id] != .none)
        {
            return error.UnsupportedGraph;
        }
        const assumption = try self.assumptionFor(
            node_id,
            .store_named_own,
        );
        const receiver_shape = assumption.receiver_shape orelse
            return error.InvalidMetadata;
        const observed = self.graph.feedback.stores[site.feedback_index];
        if (observed.mode != .own_data or
            observed.receiver_shape == null or
            observed.receiver_shape.? != receiver_shape or
            observed.slot != assumption.slot or
            assumption.holder_shape != null or
            assumption.revision != 0 or
            assumption.slot >= receiver_shape.property_count)
        {
            return error.InvalidMetadata;
        }
        const guard = try self.guardFor(node_id);
        try self.emitTaggedInput(node_id, 0, lhs_scratch);
        try property_codegen.emitPlainObject(
            self.machine,
            lhs_scratch,
            rhs_scratch,
            guard,
        );
        const cell =
            &self.chunk.inline_store_caches[site.feedback_index];
        try self.machine.movImm64(cycle_scratch, @intFromPtr(cell));
        try self.machine.movImm64(
            lhs_scratch,
            @intFromPtr(receiver_shape),
        );
        try self.machine.cmp64Disp32Reg(
            cycle_scratch,
            layout.store_ic_cell.shape,
            lhs_scratch,
        );
        try self.machine.jumpCond(.not_equal, guard);
        try self.machine.cmp64Disp32Reg(
            rhs_scratch,
            layout.object.shape,
            lhs_scratch,
        );
        try self.machine.jumpCond(.not_equal, guard);
        try self.machine.cmp32Disp32Imm32(
            cycle_scratch,
            layout.store_ic_cell.slot,
            assumption.slot,
        );
        try self.machine.jumpCond(.not_equal, guard);
        try self.emitTaggedInput(node_id, 1, lhs_scratch);
        try property_codegen.emitSlotWrite(
            self.machine,
            lhs_scratch,
            rhs_scratch,
            assumption.slot,
        );
        try self.emitStoreBarrier(rhs_scratch, lhs_scratch);
    }

    fn emitComputedLoad(
        self: *CfgCompiler,
        node_id: ir.ValueId,
        lowering_kind: specialize.Lowering,
    ) !void {
        const site = try self.computedLoadSite(node_id);
        if (lowering_kind == .load_computed_generic) {
            return self.deferForFeedback(.{
                .computed_load = site.feedback_index,
            });
        }
        if (lowering_kind != .load_computed_own or
            self.representations.outputs[node_id] != .tagged)
        {
            return error.UnsupportedGraph;
        }
        const assumption = try self.assumptionFor(
            node_id,
            .load_computed_own,
        );
        const receiver_shape = assumption.receiver_shape orelse
            return error.InvalidMetadata;
        const observed = self.graph.feedback.computed[site.feedback_index];
        if (observed.mode != .monomorphic or
            observed.receiver_shape == null or
            observed.receiver_shape.? != receiver_shape or
            observed.slot != assumption.slot or
            assumption.holder_shape != null or
            assumption.revision != 0 or
            observed.key_len == 0 or
            observed.key_len > observed.key_buf.len)
        {
            return error.InvalidMetadata;
        }
        const expected: computed_codegen.Expected = .{
            .receiver_shape = receiver_shape,
            .slot = assumption.slot,
            .key = observed.key_buf[0..observed.key_len],
        };
        const guard = try self.guardFor(node_id);
        try self.emitTaggedInput(node_id, 0, lhs_scratch);
        try property_codegen.emitPlainObject(
            self.machine,
            lhs_scratch,
            rhs_scratch,
            guard,
        );
        try computed_codegen.emitCellAndReceiverGuards(
            self.machine,
            &self.chunk.inline_computed_caches[site.feedback_index],
            expected,
            rhs_scratch,
            lhs_scratch,
            guard,
        );
        try self.emitTaggedInput(node_id, 1, lhs_scratch);
        try computed_codegen.emitKeyGuards(
            self.machine,
            expected,
            lhs_scratch,
            guard,
        );
        try property_codegen.emitSlotRead(
            self.machine,
            lhs_scratch,
            rhs_scratch,
            assumption.slot,
        );
        try self.emitTaggedResult(node_id, lhs_scratch);
    }

    fn emitComputedStore(
        self: *CfgCompiler,
        node_id: ir.ValueId,
        lowering_kind: specialize.Lowering,
    ) !void {
        const site = try self.computedStoreSite(node_id);
        if (lowering_kind == .store_computed_generic) {
            return self.deferForFeedback(.{
                .computed_store = site.feedback_index,
            });
        }
        if (lowering_kind != .store_computed_own or
            self.representations.outputs[node_id] != .none)
        {
            return error.UnsupportedGraph;
        }
        const assumption = try self.assumptionFor(
            node_id,
            .store_computed_own,
        );
        const receiver_shape = assumption.receiver_shape orelse
            return error.InvalidMetadata;
        const observed = self.graph.feedback.computed[site.feedback_index];
        if (observed.mode != .monomorphic or
            observed.receiver_shape == null or
            observed.receiver_shape.? != receiver_shape or
            observed.slot != assumption.slot or
            assumption.holder_shape != null or
            assumption.revision != 0 or
            observed.key_len == 0 or
            observed.key_len > observed.key_buf.len)
        {
            return error.InvalidMetadata;
        }
        const expected: computed_codegen.Expected = .{
            .receiver_shape = receiver_shape,
            .slot = assumption.slot,
            .key = observed.key_buf[0..observed.key_len],
        };
        const guard = try self.guardFor(node_id);
        try self.emitTaggedInput(node_id, 0, lhs_scratch);
        try property_codegen.emitPlainObject(
            self.machine,
            lhs_scratch,
            rhs_scratch,
            guard,
        );
        try computed_codegen.emitCellAndReceiverGuards(
            self.machine,
            &self.chunk.inline_computed_caches[site.feedback_index],
            expected,
            rhs_scratch,
            lhs_scratch,
            guard,
        );
        try self.emitTaggedInput(node_id, 1, lhs_scratch);
        try computed_codegen.emitKeyGuards(
            self.machine,
            expected,
            lhs_scratch,
            guard,
        );
        try self.emitTaggedInput(node_id, 2, lhs_scratch);
        try property_codegen.emitSlotWrite(
            self.machine,
            lhs_scratch,
            rhs_scratch,
            assumption.slot,
        );
        try self.emitStoreBarrier(rhs_scratch, lhs_scratch);
    }

    fn deferForFeedback(
        self: *CfgCompiler,
        site: RetryableFeedback,
    ) feedback_retry.Error {
        if (self.retryable_feedback.* == null) {
            self.retryable_feedback.* = site;
        }
        return error.RetryableFeedback;
    }

    fn namedLoadSite(
        self: *const CfgCompiler,
        node_id: ir.ValueId,
    ) !ir.NamedLoad {
        if (node_id >= self.graph.nodes.len) return error.MalformedGraph;
        const node = self.graph.nodes[node_id];
        if (node.input_count != 1) return error.MalformedGraph;
        const site = switch (node.payload) {
            .named_load => |value| value,
            else => return error.MalformedGraph,
        };
        if (site.key_constant >= self.chunk.constants.len or
            !self.chunk.constants[site.key_constant].isString() or
            site.feedback_index >= self.chunk.inline_load_caches.len or
            site.feedback_index >= self.graph.feedback.loads.len)
        {
            return error.InvalidMetadata;
        }
        return site;
    }

    fn namedStoreSite(
        self: *const CfgCompiler,
        node_id: ir.ValueId,
    ) !ir.NamedStore {
        if (node_id >= self.graph.nodes.len) return error.MalformedGraph;
        const node = self.graph.nodes[node_id];
        if (node.input_count != 2) return error.MalformedGraph;
        const site = switch (node.payload) {
            .named_store => |value| value,
            else => return error.MalformedGraph,
        };
        if (site.key_constant >= self.chunk.constants.len or
            !self.chunk.constants[site.key_constant].isString() or
            site.feedback_index >= self.chunk.inline_store_caches.len or
            site.feedback_index >= self.graph.feedback.stores.len)
        {
            return error.InvalidMetadata;
        }
        return site;
    }

    fn computedLoadSite(
        self: *const CfgCompiler,
        node_id: ir.ValueId,
    ) !ir.ComputedLoad {
        if (node_id >= self.graph.nodes.len) return error.MalformedGraph;
        const node = self.graph.nodes[node_id];
        if (node.input_count != 2) return error.MalformedGraph;
        const site = switch (node.payload) {
            .computed_load => |value| value,
            else => return error.MalformedGraph,
        };
        if (site.feedback_index >= self.chunk.inline_computed_caches.len or
            site.feedback_index >= self.graph.feedback.computed.len)
        {
            return error.InvalidMetadata;
        }
        return site;
    }

    fn computedStoreSite(
        self: *const CfgCompiler,
        node_id: ir.ValueId,
    ) !ir.ComputedStore {
        if (node_id >= self.graph.nodes.len) return error.MalformedGraph;
        const node = self.graph.nodes[node_id];
        if (node.input_count != 3) return error.MalformedGraph;
        const site = switch (node.payload) {
            .computed_store => |value| value,
            else => return error.MalformedGraph,
        };
        if (site.feedback_index >= self.chunk.inline_computed_caches.len or
            site.feedback_index >= self.graph.feedback.computed.len)
        {
            return error.InvalidMetadata;
        }
        return site;
    }

    fn assumptionFor(
        self: *const CfgCompiler,
        node_id: ir.ValueId,
        expected_kind: specialize.AssumptionKind,
    ) !specialize.Assumption {
        if (node_id >= self.graph.nodes.len or
            node_id >= self.specialization.node_info.len)
        {
            return error.MalformedGraph;
        }
        const info = self.specialization.node_info[node_id];
        const assumption_index = info.assumption orelse
            return error.InvalidMetadata;
        if (assumption_index >= self.specialization.assumptions.len) {
            return error.InvalidMetadata;
        }
        const assumption =
            self.specialization.assumptions[assumption_index];
        if (assumption.kind != expected_kind) {
            return error.InvalidMetadata;
        }
        const feedback_index = switch (self.graph.nodes[node_id].payload) {
            .named_load => |value| value.feedback_index,
            .named_store => |value| value.feedback_index,
            .computed_load => |value| value.feedback_index,
            .computed_store => |value| value.feedback_index,
            else => return error.MalformedGraph,
        };
        if (assumption.feedback_index != feedback_index) {
            return error.InvalidMetadata;
        }
        return assumption;
    }

    fn emitLogicalNot(
        self: *CfgCompiler,
        node_id: ir.ValueId,
        lowering_kind: specialize.Lowering,
    ) !void {
        if ((lowering_kind != .logical_not and
            lowering_kind != .checked_boolean_not) or
            self.representations.outputs[node_id] != .tagged)
        {
            return error.UnsupportedGraph;
        }
        try self.emitTaggedInput(node_id, 0, lhs_scratch);
        if (lowering_kind == .checked_boolean_not) {
            const guard = try self.guardFor(node_id);
            try self.machine.movReg64(cycle_scratch, lhs_scratch);
            try self.machine.movImm64(rhs_scratch, Value.false_.bits);
            try self.machine.xorReg64(cycle_scratch, rhs_scratch);
            try self.machine.cmpRegImm32(cycle_scratch, 1);
            try self.machine.jumpCond(.above, guard);
        }
        try self.machine.movImm64(rhs_scratch, 1);
        try self.machine.xorReg64(lhs_scratch, rhs_scratch);
        try self.emitTaggedResult(node_id, lhs_scratch);
    }

    /// §7.2.13 IsLessThan's tagged-Int32 subset. Every coercing or wider
    /// numeric case resumes the original bytecode through the physical guard.
    fn emitLessThan(
        self: *CfgCompiler,
        node_id: ir.ValueId,
        lowering_kind: specialize.Lowering,
    ) !void {
        if (lowering_kind != .less_than or
            self.representations.outputs[node_id] != .tagged)
        {
            return error.UnsupportedGraph;
        }
        const guard = try self.guardFor(node_id);
        try self.emitInt32Input(node_id, 0, lhs_scratch, guard);
        try self.emitInt32Input(node_id, 1, rhs_scratch, guard);
        try self.machine.cmpReg32(lhs_scratch, rhs_scratch);
        try self.emitBooleanResult(node_id, .less);
    }

    fn emitTailDispatch(
        self: *CfgCompiler,
        node_id: ir.ValueId,
        lowering_kind: specialize.Lowering,
    ) !void {
        const node = self.graph.nodes[node_id];
        if (lowering_kind != .tail_dispatch or
            self.representations.outputs[node_id] != .none or
            node.input_count != 0 or node.payload != .none)
        {
            return error.UnsupportedGraph;
        }
        try self.machine.jump(try self.guardFor(node_id));
    }

    fn emitThrow(
        self: *CfgCompiler,
        node_id: ir.ValueId,
        lowering_kind: specialize.Lowering,
    ) !void {
        const node = self.graph.nodes[node_id];
        if (lowering_kind != .throw_ or
            self.representations.outputs[node_id] != .none or
            node.input_count != 0 or node.payload != .none)
        {
            return error.UnsupportedGraph;
        }
        try self.machine.jump(try self.guardFor(node_id));
    }

    fn emitThrowIfHole(
        self: *CfgCompiler,
        node_id: ir.ValueId,
        lowering_kind: specialize.Lowering,
    ) !void {
        if (lowering_kind != .throw_if_hole or
            self.representations.outputs[node_id] != .tagged)
        {
            return error.UnsupportedGraph;
        }
        try self.emitTaggedInput(node_id, 0, lhs_scratch);
        try self.machine.movImm64(rhs_scratch, Value.hole_.bits);
        try self.machine.cmpReg64(lhs_scratch, rhs_scratch);
        try self.machine.jumpCond(.equal, try self.guardFor(node_id));
        try self.emitTaggedResult(node_id, lhs_scratch);
    }

    fn emitBooleanResult(
        self: *CfgCompiler,
        node_id: ir.ValueId,
        truth_condition: x86.Cond,
    ) !void {
        var truthy: x86.Masm.Label = .{};
        defer truthy.deinit(self.allocator);
        var done: x86.Masm.Label = .{};
        defer done.deinit(self.allocator);
        try self.machine.jumpCond(truth_condition, &truthy);
        try self.machine.movImm64(lhs_scratch, Value.false_.bits);
        try self.machine.jump(&done);
        try self.machine.bind(&truthy);
        try self.machine.movImm64(lhs_scratch, Value.true_.bits);
        try self.machine.bind(&done);
        try self.emitTaggedResult(node_id, lhs_scratch);
    }

    fn emitTaggedResult(
        self: *CfgCompiler,
        node_id: ir.ValueId,
        source: x86.Reg,
    ) !void {
        if (self.locations[node_id] == .none) return;
        try self.storeLocation(self.locations[node_id], .tagged, source);
        try self.emitDefinitionHome(node_id);
    }

    fn emitEnvironmentLoad(
        self: *CfgCompiler,
        node_id: ir.ValueId,
        lowering_kind: specialize.Lowering,
    ) !void {
        if (lowering_kind != .load_environment or
            self.representations.outputs[node_id] != .tagged)
        {
            return error.UnsupportedGraph;
        }
        const site = switch (self.graph.nodes[node_id].payload) {
            .environment_load => |value| value,
            else => return error.MalformedGraph,
        };
        if (site.depth > 8) return error.InvalidMetadata;
        const guard = try self.guardFor(node_id);
        try self.machine.load64Disp32(
            lhs_scratch,
            .rsi,
            layout.frame.env,
        );
        try self.machine.testReg64(lhs_scratch, lhs_scratch);
        try self.machine.jumpCond(.equal, guard);
        var depth = site.depth;
        while (depth > 0) : (depth -= 1) {
            try self.machine.load64Disp32(
                lhs_scratch,
                lhs_scratch,
                layout.env.parent,
            );
            try self.machine.testReg64(lhs_scratch, lhs_scratch);
            try self.machine.jumpCond(.equal, guard);
        }
        try self.machine.load64Disp32(
            cycle_scratch,
            lhs_scratch,
            layout.env.slots_len,
        );
        try self.machine.cmpRegImm32(cycle_scratch, site.slot);
        try self.machine.jumpCond(.below_or_equal, guard);
        try self.machine.load64Disp32(
            lhs_scratch,
            lhs_scratch,
            layout.env.slots,
        );
        const slot_offset = std.math.cast(
            i32,
            @as(u32, site.slot) * @sizeOf(Value),
        ) orelse return error.InvalidMetadata;
        try self.machine.load64Disp32(
            lhs_scratch,
            lhs_scratch,
            slot_offset,
        );
        try self.emitTaggedResult(node_id, lhs_scratch);
    }

    fn emitEnvironmentAllocate(
        self: *CfgCompiler,
        node_id: ir.ValueId,
        lowering_kind: specialize.Lowering,
    ) !void {
        if (lowering_kind != .allocate_environment) {
            return error.UnsupportedGraph;
        }
        const site = switch (self.graph.nodes[node_id].payload) {
            .environment_allocation => |value| value,
            else => return error.MalformedGraph,
        };
        try self.emitFrameSafepoint(node_id, .{ .allocate = site });
    }

    fn emitEnvironmentStore(
        self: *CfgCompiler,
        node_id: ir.ValueId,
        lowering_kind: specialize.Lowering,
    ) !void {
        if (lowering_kind != .store_environment) {
            return error.UnsupportedGraph;
        }
        const site = switch (self.graph.nodes[node_id].payload) {
            .environment_store => |value| value,
            else => return error.MalformedGraph,
        };
        try self.emitFrameSafepoint(node_id, .{ .store = site });
    }

    fn emitEnvironmentPop(
        self: *CfgCompiler,
        node_id: ir.ValueId,
        lowering_kind: specialize.Lowering,
    ) !void {
        const node = self.graph.nodes[node_id];
        if (lowering_kind != .pop_environment or
            self.representations.outputs[node_id] != .none or
            node.input_count != 0 or node.payload != .none)
        {
            return error.UnsupportedGraph;
        }
        var done: x86.Masm.Label = .{};
        defer done.deinit(self.allocator);
        try self.machine.load64Disp32(
            lhs_scratch,
            .rsi,
            layout.frame.env,
        );
        try self.machine.testReg64(lhs_scratch, lhs_scratch);
        try self.machine.jumpCond(.equal, &done);
        try self.machine.load64Disp32(
            lhs_scratch,
            lhs_scratch,
            layout.env.parent,
        );
        try self.machine.store64Disp32(
            .rsi,
            layout.frame.env,
            lhs_scratch,
        );
        try self.machine.bind(&done);
    }

    fn emitUnmappedArgumentsObject(
        self: *CfgCompiler,
        node_id: ir.ValueId,
        lowering_kind: specialize.Lowering,
    ) !void {
        const node = self.graph.nodes[node_id];
        if (lowering_kind != .create_unmapped_arguments_object or
            self.representations.outputs[node_id] != .tagged or
            node.input_count != 0 or node.payload != .none)
        {
            return error.UnsupportedGraph;
        }
        try self.emitFrameSafepoint(node_id, .unmapped_arguments_object);
    }

    fn emitOrdinaryFunction(
        self: *CfgCompiler,
        node_id: ir.ValueId,
        lowering_kind: specialize.Lowering,
    ) !void {
        const node = self.graph.nodes[node_id];
        if (lowering_kind != .create_ordinary_function or
            self.representations.outputs[node_id] != .tagged or
            node.input_count != 0)
        {
            return error.UnsupportedGraph;
        }
        const template: ir.FunctionTemplateRef = switch (node.payload) {
            .function_template => |value| value,
            else => return error.MalformedGraph,
        };
        if (template.template_index >= self.chunk.function_templates.len) {
            return error.MalformedGraph;
        }
        const function_template =
            &self.chunk.function_templates[template.template_index];
        if (function_template.is_arrow or
            function_template.is_generator or
            function_template.is_async)
        {
            return error.MalformedGraph;
        }
        try self.emitFrameSafepoint(
            node_id,
            .{ .ordinary_function = template },
        );
    }

    fn emitSetHome(
        self: *CfgCompiler,
        node_id: ir.ValueId,
        lowering_kind: specialize.Lowering,
    ) !void {
        const node = self.graph.nodes[node_id];
        if (lowering_kind != .set_home or
            self.representations.outputs[node_id] != .none or
            node.input_count != 2)
        {
            return error.UnsupportedGraph;
        }
        const home = switch (node.payload) {
            .home_object => |value| value,
            else => return error.MalformedGraph,
        };
        try self.emitFrameSafepoint(node_id, .{ .set_home = home });
    }

    fn emitObjectMethodProperty(
        self: *CfgCompiler,
        node_id: ir.ValueId,
        lowering_kind: specialize.Lowering,
    ) !void {
        const node = self.graph.nodes[node_id];
        if (lowering_kind != .define_object_method_property or
            self.representations.outputs[node_id] != .none or
            node.input_count != 2)
        {
            return error.UnsupportedGraph;
        }
        const property: ir.ObjectMethodProperty = switch (node.payload) {
            .object_method_property => |value| value,
            else => return error.MalformedGraph,
        };
        if (property.key_constant >= self.chunk.constants.len or
            !self.chunk.constants[property.key_constant].isString())
        {
            return error.MalformedGraph;
        }
        try self.emitFrameSafepoint(
            node_id,
            .{ .object_method_property = property },
        );
    }

    fn emitObjectLiteral(
        self: *CfgCompiler,
        node_id: ir.ValueId,
        lowering_kind: specialize.Lowering,
    ) !void {
        const node = self.graph.nodes[node_id];
        if (lowering_kind != .create_object_literal or
            self.representations.outputs[node_id] != .tagged or
            node.input_count != 0)
        {
            return error.UnsupportedGraph;
        }
        const literal: ir.ObjectLiteral = switch (node.payload) {
            .object_literal => |value| value,
            else => return error.MalformedGraph,
        };
        try self.emitFrameSafepoint(
            node_id,
            .{ .object_literal = literal },
        );
    }

    fn emitDenseArrayLiteral(
        self: *CfgCompiler,
        node_id: ir.ValueId,
        lowering_kind: specialize.Lowering,
    ) !void {
        const node = self.graph.nodes[node_id];
        if (lowering_kind != .create_dense_array_literal or
            self.representations.outputs[node_id] != .tagged or
            node.input_count != 0)
        {
            return error.UnsupportedGraph;
        }
        const literal: ir.DenseArrayLiteral = switch (node.payload) {
            .dense_array_literal => |value| value,
            else => return error.MalformedGraph,
        };
        const base: usize = literal.base;
        const count: usize = literal.count;
        if (literal.count == 0 or
            count > heap_mod.Heap.element_buf_cap or
            base > self.chunk.register_count or
            count > self.chunk.register_count - base)
        {
            return error.MalformedGraph;
        }
        try self.emitFrameSafepoint(
            node_id,
            .{ .dense_array_literal = literal },
        );
    }

    fn emitArrayLiteral(
        self: *CfgCompiler,
        node_id: ir.ValueId,
        lowering_kind: specialize.Lowering,
    ) !void {
        const node = self.graph.nodes[node_id];
        if (lowering_kind != .create_array_literal or
            self.representations.outputs[node_id] != .tagged or
            node.input_count != 0 or node.payload != .none)
        {
            return error.UnsupportedGraph;
        }
        try self.emitFrameSafepoint(node_id, .array_literal);
    }

    fn emitDenseArrayAppend(
        self: *CfgCompiler,
        node_id: ir.ValueId,
        lowering_kind: specialize.Lowering,
    ) !void {
        const node = self.graph.nodes[node_id];
        if (lowering_kind != .append_dense_array_literal_element or
            self.representations.outputs[node_id] != .none or
            node.input_count != 2)
        {
            return error.UnsupportedGraph;
        }
        const append: ir.DenseArrayAppend = switch (node.payload) {
            .dense_array_append => |value| value,
            else => return error.MalformedGraph,
        };
        if (append.key_constant >= self.chunk.constants.len or
            !self.chunk.constants[append.key_constant].isString() or
            append.object_register >= self.chunk.register_count)
        {
            return error.MalformedGraph;
        }
        const inputs = self.graph.nodeInputs(node_id);
        if (inputs.len != 2 or
            inputs[0] >= self.graph.nodes.len or
            self.graph.nodes[inputs[0]].kind != .create_array_literal)
        {
            return error.MalformedGraph;
        }
        try self.emitFrameSafepoint(
            node_id,
            .{ .dense_array_append = append },
        );
    }

    fn emitTemplateProperty(
        self: *CfgCompiler,
        node_id: ir.ValueId,
        lowering_kind: specialize.Lowering,
    ) !void {
        const node = self.graph.nodes[node_id];
        if (lowering_kind != .define_template_property or
            self.representations.outputs[node_id] != .none or
            node.input_count != 2)
        {
            return error.UnsupportedGraph;
        }
        const property: ir.TemplateProperty = switch (node.payload) {
            .template_property => |value| value,
            else => return error.MalformedGraph,
        };
        if (property.key_constant >= self.chunk.constants.len or
            !self.chunk.constants[property.key_constant].isString())
        {
            return error.MalformedGraph;
        }
        try self.emitFrameSafepoint(
            node_id,
            .{ .template_property = property },
        );
    }

    fn emitComputedDelete(
        self: *CfgCompiler,
        node_id: ir.ValueId,
        lowering_kind: specialize.Lowering,
    ) !void {
        const node = self.graph.nodes[node_id];
        if (lowering_kind != .delete_computed_property or
            self.representations.outputs[node_id] != .tagged or
            node.input_count != 2)
        {
            return error.UnsupportedGraph;
        }
        const delete: ir.ComputedDelete = switch (node.payload) {
            .computed_delete => |value| value,
            else => return error.MalformedGraph,
        };
        if (delete.object_register >= self.chunk.register_count or
            delete.key_register >= self.chunk.register_count)
        {
            return error.MalformedGraph;
        }
        try self.emitFrameSafepoint(
            node_id,
            .{ .computed_delete = delete },
        );
    }

    fn emitFrameSafepoint(
        self: *CfgCompiler,
        node_id: ir.ValueId,
        helper: frame_safepoint.Helper,
    ) !void {
        const point_index = try self.pointIndexForNode(node_id);
        var point = try self.physical_deopt.decode(
            self.allocator,
            point_index,
        );
        defer point.deinit();
        if (point.bytecode_offset != self.graph.nodes[node_id].bytecode_offset) {
            return error.InvalidMetadata;
        }

        var succeeded: x86.Masm.Label = .{};
        defer succeeded.deinit(self.allocator);
        try self.emitRecoveredFrame(point);
        try self.emitNonReentrantCall(helper);
        try self.machine.testReg64(cycle_scratch, cycle_scratch);
        try self.machine.jumpCond(.equal, &succeeded);

        if (frame_safepoint.outOfMemoryStatus(helper)) |status| {
            var tier_down: x86.Masm.Label = .{};
            defer tier_down.deinit(self.allocator);
            try self.machine.cmpRegImm32(
                cycle_scratch,
                @intCast(status),
            );
            try self.machine.jumpCond(.not_equal, &tier_down);
            try self.machine.movImm64(.rax, entry.host_oom_sentinel_bits);
            try self.emitEpilogue();
            try self.machine.bind(&tier_down);
        }
        try self.emitResumeAt(point.bytecode_offset);

        try self.machine.bind(&succeeded);
        if (frame_safepoint.returnsTaggedResult(helper)) {
            try self.machine.load64Disp32(
                lhs_scratch,
                .rsi,
                layout.frame.accumulator,
            );
            try self.emitTaggedResult(node_id, lhs_scratch);
        }
    }

    /// Preserve every SysV caller-saved location that carries Ohaimark state.
    /// The 56-byte save changes entry's rsp%16 from 8 to 0 for the C call.
    fn emitNonReentrantCall(
        self: *CfgCompiler,
        helper: frame_safepoint.Helper,
    ) !void {
        const helper_call = frame_safepoint.call(helper);
        try self.emitVolatileSave();

        if (helper_call.arg2) |arg2| {
            try self.machine.movImm64(.rdx, arg2);
        }
        if (helper_call.arg3) |arg3| {
            try self.machine.movImm64(.rcx, arg3);
        }
        try self.machine.movImm64(cycle_scratch, helper_call.target);
        try self.machine.callReg(cycle_scratch);
        try self.machine.movReg64(cycle_scratch, .rax);
        try self.emitVolatileRestore();
    }

    fn emitStoreBarrier(
        self: *CfgCompiler,
        object: x86.Reg,
        value: x86.Reg,
    ) !void {
        if (object == value or object == .r11 or value == .r11) {
            return error.InvalidMetadata;
        }
        try self.emitVolatileSave();

        try self.machine.movReg64(.rsi, object);
        try self.machine.movReg64(.rdx, value);
        try self.machine.movImm64(
            cycle_scratch,
            @intFromPtr(&frame_safepoint.storeBarrier),
        );
        try self.machine.callReg(cycle_scratch);
        try self.emitVolatileRestore();
    }

    fn emitVolatileSave(self: *CfgCompiler) !void {
        try self.machine.subRegImm32(.rsp, 56);
        try self.machine.store64Disp32(.rsp, 0, .rdi);
        try self.machine.store64Disp32(.rsp, 8, .rsi);
        try self.machine.store64Disp32(.rsp, 16, .rdx);
        try self.machine.store64Disp32(.rsp, 24, .r8);
        try self.machine.store64Disp32(.rsp, 32, .r9);
        try self.machine.store64Disp32(.rsp, 40, .r10);
    }

    fn emitVolatileRestore(self: *CfgCompiler) !void {
        try self.machine.load64Disp32(.r10, .rsp, 40);
        try self.machine.load64Disp32(.r9, .rsp, 32);
        try self.machine.load64Disp32(.r8, .rsp, 24);
        try self.machine.load64Disp32(.rdx, .rsp, 16);
        try self.machine.load64Disp32(.rsi, .rsp, 8);
        try self.machine.load64Disp32(.rdi, .rsp, 0);
        try self.machine.addRegImm32(.rsp, 56);
    }

    fn emitResumeAt(
        self: *CfgCompiler,
        bytecode_offset: u32,
    ) !void {
        try self.machine.movImm64(lhs_scratch, bytecode_offset);
        try self.machine.store64Disp32(
            .rsi,
            layout.frame.ip,
            lhs_scratch,
        );
        try self.machine.movImm64(.rax, entry.resume_sentinel_bits);
        try self.emitEpilogue();
    }

    fn emitDirectCall(
        self: *CfgCompiler,
        node_id: ir.ValueId,
        lowering_kind: specialize.Lowering,
    ) !void {
        if (lowering_kind != .direct_call or
            self.representations.outputs[node_id] != .tagged)
        {
            return error.UnsupportedGraph;
        }
        const node = self.graph.nodes[node_id];
        if (node.input_count != 0) return error.MalformedGraph;
        const site: ir.DirectCallSite = switch (node.payload) {
            .direct_call => |direct_call| direct_call,
            else => return error.MalformedGraph,
        };
        const point_index = try self.pointIndexForNode(node_id);
        var point = try self.physical_deopt.decode(
            self.allocator,
            point_index,
        );
        defer point.deinit();
        if (point.bytecode_offset != node.bytecode_offset) {
            return error.InvalidMetadata;
        }
        try call_handoff.validateRoots(point, site);
        const after_bytecode = try call_handoff.afterBytecode(
            self.chunk,
            node.bytecode_offset,
            site,
        );

        // The helper reads every operand from this rooted Lantern frame and
        // may relocate the frame list while appending the callee.
        try self.emitRecoveredFrame(point);
        try self.machine.movImm64(lhs_scratch, after_bytecode);
        try self.machine.store64Disp32(
            .rsi,
            layout.frame.ip,
            lhs_scratch,
        );

        var pushed: x86.Masm.Label = .{};
        defer pushed.deinit(self.allocator);
        var tier_down: x86.Masm.Label = .{};
        defer tier_down.deinit(self.allocator);

        // SysV enters with rsp % 16 == 8. One saved pointer both aligns the
        // helper call and retains the only frame address needed on tier-down.
        try self.machine.subRegImm32(.rsp, 8);
        try self.machine.store64Disp32(.rsp, 0, .rsi);
        switch (site) {
            .direct => |direct| {
                try self.machine.movImm64(
                    .rdx,
                    if (direct.this_register) |receiver|
                        receiver
                    else
                        call_handoff.no_this_register,
                );
                try self.machine.movImm64(.rcx, direct.callee);
                try self.machine.movImm64(.r8, direct.argc);
                try self.machine.movImm64(.r9, direct.feedback_index);
                try self.machine.movImm64(
                    cycle_scratch,
                    switch (direct.kind) {
                        .call => @intFromPtr(
                            &call_handoff.pushMonomorphicDirectCall,
                        ),
                        .construct => @intFromPtr(
                            &call_handoff.pushMonomorphicConstruct,
                        ),
                    },
                );
            },
            .property => |property| {
                try self.machine.movImm64(.rdx, property.receiver);
                try self.machine.movImm64(.rcx, property.argc);
                try self.machine.movImm64(
                    .r8,
                    property.load_feedback_index,
                );
                try self.machine.movImm64(
                    .r9,
                    property.call_feedback_index,
                );
                try self.machine.movImm64(
                    cycle_scratch,
                    @intFromPtr(
                        &call_handoff.pushMonomorphicPropertyCall,
                    ),
                );
            },
        }
        try self.machine.callReg(cycle_scratch);
        try self.machine.load64Disp32(.rsi, .rsp, 0);
        try self.machine.addRegImm32(.rsp, 8);

        try self.machine.testReg64(.rax, .rax);
        try self.machine.jumpCond(.equal, &pushed);
        try self.machine.cmpRegImm32(
            .rax,
            @intFromEnum(call_mod.JitPushStatus.tier_down),
        );
        try self.machine.jumpCond(.equal, &tier_down);

        // Allocation may have happened before host OOM, so do not replay the
        // staged bytecode or dereference the possibly relocated frame.
        try self.machine.movImm64(.rax, entry.host_oom_sentinel_bits);
        try self.emitEpilogue();

        try self.machine.bind(&pushed);
        // The append may have relocated `CallFrame`; only unwind native stack.
        try self.machine.movImm64(.rax, entry.call_pushed_sentinel_bits);
        try self.emitEpilogue();

        try self.machine.bind(&tier_down);
        try self.machine.movImm64(lhs_scratch, point.bytecode_offset);
        try self.machine.store64Disp32(
            .rsi,
            layout.frame.ip,
            lhs_scratch,
        );
        try self.machine.movImm64(.rax, entry.resume_sentinel_bits);
        try self.emitEpilogue();
    }

    fn emitCheckedArithmetic(
        self: *CfgCompiler,
        node_id: ir.ValueId,
        kind: ir.NodeKind,
        lowering_kind: specialize.Lowering,
    ) !void {
        const expected: specialize.Lowering = switch (kind) {
            .add => .checked_int32_add,
            .sub => .checked_int32_sub,
            .mul => .checked_int32_mul,
            else => return error.MalformedGraph,
        };
        if (lowering_kind != expected or
            self.representations.outputs[node_id] != .int32)
        {
            return error.UnsupportedGraph;
        }
        const guard = try self.guardFor(node_id);
        try self.emitInt32Input(node_id, 0, lhs_scratch, guard);
        try self.emitInt32Input(node_id, 1, rhs_scratch, guard);
        switch (kind) {
            .add => {
                try self.machine.addReg32(lhs_scratch, rhs_scratch);
                try self.machine.jumpCond(.overflow, guard);
            },
            .sub => {
                try self.machine.subReg32(lhs_scratch, rhs_scratch);
                try self.machine.jumpCond(.overflow, guard);
            },
            .mul => {
                var nonzero: x86.Masm.Label = .{};
                defer nonzero.deinit(self.allocator);
                try self.machine.movReg32(cycle_scratch, lhs_scratch);
                try self.machine.xorReg32(cycle_scratch, rhs_scratch);
                try self.machine.imulReg32(lhs_scratch, rhs_scratch);
                try self.machine.jumpCond(.overflow, guard);
                try self.machine.testReg64(lhs_scratch, lhs_scratch);
                try self.machine.jumpCond(.not_equal, &nonzero);
                try self.machine.testReg32Imm32(cycle_scratch, 0x8000_0000);
                try self.machine.jumpCond(.not_equal, guard);
                try self.machine.bind(&nonzero);
            },
            else => unreachable,
        }

        if (self.locations[node_id] == .none) return;
        try self.storeLocation(
            self.locations[node_id],
            .int32,
            lhs_scratch,
        );
        try self.emitDefinitionHome(node_id);
    }

    fn emitInt32Input(
        self: *CfgCompiler,
        node_id: ir.ValueId,
        operand_index: usize,
        destination: x86.Reg,
        guard: *x86.Masm.Label,
    ) !void {
        if (node_id >= self.graph.nodes.len) return error.MalformedGraph;
        const node = self.graph.nodes[node_id];
        const inputs = try nodeInputs(self.graph, node);
        if (operand_index >= inputs.len) return error.MalformedGraph;
        const input_index = inputs.start + operand_index;
        const producer = self.graph.inputs[input_index];
        if (producer >= self.locations.len or
            producer >= self.representations.outputs.len)
        {
            return error.MalformedGraph;
        }
        const output = self.representations.outputs[producer];
        const conversion = try self.representations.conversionAt(
            self.graph,
            input_index,
        );
        switch (output) {
            .int32 => {
                if (conversion != .none) return error.InvalidRepresentation;
                try self.loadLocation(
                    self.locations[producer],
                    .int32,
                    destination,
                );
            },
            .tagged => {
                if (conversion != .check_int32) {
                    return error.InvalidRepresentation;
                }
                try self.loadLocation(
                    self.locations[producer],
                    .tagged,
                    destination,
                );
                try self.emitInt32Guard(destination, guard);
                try self.machine.movReg32(destination, destination);
            },
            .none => return error.InvalidRepresentation,
        }
    }

    fn emitTaggedInput(
        self: *CfgCompiler,
        node_id: ir.ValueId,
        operand_index: usize,
        destination: x86.Reg,
    ) !void {
        if (node_id >= self.graph.nodes.len) return error.MalformedGraph;
        const inputs = try nodeInputs(self.graph, self.graph.nodes[node_id]);
        if (operand_index >= inputs.len) return error.MalformedGraph;
        const input_index = inputs.start + operand_index;
        const producer = self.graph.inputs[input_index];
        if (producer >= self.locations.len or
            producer >= self.representations.outputs.len)
        {
            return error.MalformedGraph;
        }
        if (self.representations.outputs[producer] != .tagged or
            try self.representations.conversionAt(
                self.graph,
                input_index,
            ) != .none)
        {
            return error.InvalidRepresentation;
        }
        try self.loadLocation(
            self.locations[producer],
            .tagged,
            destination,
        );
    }

    fn emitInt32Guard(
        self: *CfgCompiler,
        value: x86.Reg,
        guard: *x86.Masm.Label,
    ) !void {
        try self.machine.movReg64(cycle_scratch, value);
        try self.machine.shrImm8(cycle_scratch, 48);
        try self.machine.cmpRegImm32(cycle_scratch, Value.tag_int32);
        try self.machine.jumpCond(.not_equal, guard);
    }

    fn emitBranch(
        self: *CfgCompiler,
        block_index: usize,
        node_id: ir.ValueId,
    ) !void {
        if (try self.fused_control.strictEqualForBranch(node_id)) |comparison| {
            try self.emitFusedStrictEqualBranch(block_index, comparison, node_id);
            return;
        }
        const node = self.graph.nodes[node_id];
        const inputs = try nodeInputs(self.graph, node);
        if (inputs.len != 1) return error.MalformedGraph;
        const condition = switch (node.payload) {
            .branch => |value| value,
            else => return error.MalformedGraph,
        };
        const producer = self.graph.inputs[inputs.start];
        if (producer >= self.locations.len or
            producer >= self.representations.outputs.len)
        {
            return error.MalformedGraph;
        }
        if (self.locations[producer] == .immediate) {
            try self.emitEdgeAndJump(try self.selectedStaticBranchEdge(
                block_index,
                node_id,
            ));
            return;
        }
        if (condition == .nullish) return error.UnsupportedGraph;
        const output = self.representations.outputs[producer];
        const conversion = try self.representations.conversionAt(
            self.graph,
            inputs.start,
        );
        switch (output) {
            .int32 => {
                if (conversion != .box_int32) {
                    return error.InvalidRepresentation;
                }
                try self.loadLocation(
                    self.locations[producer],
                    .int32,
                    lhs_scratch,
                );
            },
            .tagged => {
                if (conversion != .none) return error.InvalidRepresentation;
                try self.loadLocation(
                    self.locations[producer],
                    .tagged,
                    lhs_scratch,
                );
                const strict_boolean = producer < self.graph.nodes.len and
                    switch (self.graph.nodes[producer].kind) {
                        .strict_eq, .logical_not, .less_than => true,
                        else => false,
                    };
                if (strict_boolean) {
                    try self.machine.movImm64(rhs_scratch, Value.false_.bits);
                    try self.machine.cmpReg64(lhs_scratch, rhs_scratch);
                    try self.emitConditionalEdges(
                        block_index,
                        if (condition == .truthy) .not_equal else .equal,
                    );
                    return;
                }
                if (self.specialization.node_info[node_id].lowering !=
                    .checked_branch)
                {
                    return error.UnsupportedGraph;
                }
                try self.emitInt32Guard(
                    lhs_scratch,
                    try self.guardFor(node_id),
                );
                try self.machine.movReg32(lhs_scratch, lhs_scratch);
            },
            .none => return error.InvalidRepresentation,
        }
        try self.machine.testReg64(lhs_scratch, lhs_scratch);
        try self.emitConditionalEdges(
            block_index,
            if (condition == .truthy) .not_equal else .equal,
        );
    }

    fn emitFusedStrictEqualBranch(
        self: *CfgCompiler,
        block_index: usize,
        comparison: ir.ValueId,
        branch: ir.ValueId,
    ) !void {
        if (comparison >= self.graph.nodes.len or branch >= self.graph.nodes.len) {
            return error.MalformedGraph;
        }
        const branch_condition = switch (self.graph.nodes[branch].payload) {
            .branch => |value| value,
            else => return error.MalformedGraph,
        };
        if (branch_condition == .nullish) return error.UnsupportedGraph;
        const comparison_node = self.graph.nodes[comparison];
        if (comparison_node.kind != .strict_eq or
            self.specialization.node_info[comparison].lowering != .strict_eq)
        {
            return error.UnsupportedGraph;
        }
        const guard = try self.guardFor(comparison);
        try self.emitInt32Input(comparison, 0, lhs_scratch, guard);
        try self.emitInt32Input(comparison, 1, rhs_scratch, guard);
        try self.machine.cmpReg32(lhs_scratch, rhs_scratch);
        try self.emitConditionalEdges(
            block_index,
            if (branch_condition == .truthy) .equal else .not_equal,
        );
    }

    fn emitConditionalEdges(
        self: *CfgCompiler,
        block_index: usize,
        taken_condition: x86.Cond,
    ) !void {
        var taken: x86.Masm.Label = .{};
        defer taken.deinit(self.allocator);
        try self.machine.jumpCond(taken_condition, &taken);
        try self.emitEdgeAndJump(
            try self.edgeForKind(block_index, .branch_fallthrough),
        );
        try self.machine.bind(&taken);
        try self.emitEdgeAndJump(
            try self.edgeForKind(block_index, .branch_taken),
        );
    }

    fn emitReturn(self: *CfgCompiler, node_id: ir.ValueId) !void {
        const node = self.graph.nodes[node_id];
        const inputs = try nodeInputs(self.graph, node);
        if (inputs.len != 1) return error.MalformedGraph;
        const input_index = inputs.start;
        const producer = self.graph.inputs[input_index];
        if (producer >= self.locations.len or
            producer >= self.representations.outputs.len)
        {
            return error.MalformedGraph;
        }
        const output = self.representations.outputs[producer];
        const conversion = try self.representations.conversionAt(
            self.graph,
            input_index,
        );
        switch (output) {
            .tagged => {
                if (conversion != .none) return error.InvalidRepresentation;
                try self.loadLocation(
                    self.locations[producer],
                    .tagged,
                    .rax,
                );
            },
            .int32 => {
                if (conversion != .box_int32) {
                    return error.InvalidRepresentation;
                }
                try self.loadLocation(
                    self.locations[producer],
                    .int32,
                    .rax,
                );
                try self.boxInt32(.rax);
            },
            .none => return error.InvalidRepresentation,
        }
        try self.emitEpilogue();
    }

    fn pointIndexForNode(
        self: *CfgCompiler,
        node_id: ir.ValueId,
    ) !usize {
        if (node_id >= self.point_for_node.len) return error.MalformedGraph;
        const point = self.point_for_node[node_id] orelse
            return error.InvalidMetadata;
        if (point >= self.guard_labels.len) return error.InvalidMetadata;
        return point;
    }

    fn guardFor(
        self: *CfgCompiler,
        node_id: ir.ValueId,
    ) !*x86.Masm.Label {
        return &self.guard_labels[try self.pointIndexForNode(node_id)];
    }

    fn singleEdge(self: *CfgCompiler, block_index: usize) !usize {
        if (block_index >= self.graph.blocks.len) return error.MalformedGraph;
        const block = self.graph.blocks[block_index];
        if (block.edge_count != 1 or block.edge_start >= self.graph.edges.len) {
            return error.MalformedGraph;
        }
        return block.edge_start;
    }

    fn selectedStaticBranchEdge(
        self: *CfgCompiler,
        block_index: usize,
        node_id: ir.ValueId,
    ) !usize {
        const node = self.graph.nodes[node_id];
        const inputs = try nodeInputs(self.graph, node);
        if (inputs.len != 1) return error.MalformedGraph;
        const producer = self.graph.inputs[inputs.start];
        if (producer >= self.locations.len) return error.MalformedGraph;
        const immediate = switch (self.locations[producer]) {
            .immediate => |value| value,
            else => return error.UnsupportedGraph,
        };
        const condition = switch (node.payload) {
            .branch => |value| value,
            else => return error.MalformedGraph,
        };
        const value = Value{
            .bits = try immediateValueBits(self.chunk, immediate),
        };
        if (value.isHole()) return error.UnsupportedGraph;
        const taken = switch (condition) {
            .truthy => arith.toBoolean(value),
            .falsy => !arith.toBoolean(value),
            .nullish => value.isNullish(),
        };
        return self.edgeForKind(
            block_index,
            if (taken) .branch_taken else .branch_fallthrough,
        );
    }

    fn edgeForKind(
        self: *CfgCompiler,
        block_index: usize,
        kind: ir.EdgeKind,
    ) !usize {
        if (block_index >= self.graph.blocks.len) return error.MalformedGraph;
        const block = self.graph.blocks[block_index];
        const edges = try checkedGraphRange(
            self.graph.edges.len,
            block.edge_start,
            block.edge_count,
        );
        var found: ?usize = null;
        for (edges.start..edges.end()) |edge_index| {
            if (self.graph.edges[edge_index].kind != kind) continue;
            if (found != null) return error.MalformedGraph;
            found = edge_index;
        }
        return found orelse error.MalformedGraph;
    }

    fn emitEdgeAndJump(
        self: *CfgCompiler,
        edge_index: usize,
    ) !void {
        if (edge_index >= self.graph.edges.len) return error.MalformedGraph;
        const edge = self.graph.edges[edge_index];
        try self.emitEdge(edge);
        if (edge.to >= self.block_labels.len or
            !self.graph.blocks[edge.to].reachable)
        {
            return error.MalformedGraph;
        }
        if (try self.isBackEdge(edge)) {
            var slow: x86.Masm.Label = .{};
            defer slow.deinit(self.allocator);
            try safepoint_codegen.emitPoll(self.machine, .rdi, &slow);
            try self.machine.jump(&self.block_labels[edge.to]);
            try self.machine.bind(&slow);
            try self.emitSafepointExit(edge.to);
            return;
        }
        try self.machine.jump(&self.block_labels[edge.to]);
    }

    fn isBackEdge(self: *CfgCompiler, edge: ir.Edge) !bool {
        if (edge.from >= self.graph.blocks.len or edge.to >= self.graph.blocks.len) {
            return error.MalformedGraph;
        }
        return self.graph.blocks[edge.to].start <=
            self.graph.blocks[edge.from].start;
    }

    fn emitEdge(self: *CfgCompiler, edge: ir.Edge) !void {
        if (edge.to >= self.graph.blocks.len) return error.MalformedGraph;
        const target = self.graph.blocks[edge.to];
        const params = try checkedGraphRange(
            self.graph.params.len,
            target.param_start,
            target.param_count,
        );
        const arguments = try checkedGraphRange(
            self.graph.inputs.len,
            edge.argument_start,
            edge.argument_count,
        );
        if (params.len != arguments.len) return error.MalformedGraph;

        var pending: std.ArrayListUnmanaged(EdgeAssignment) = .empty;
        defer pending.deinit(self.allocator);
        for (0..params.len) |offset| {
            const parameter = self.graph.params[params.start + offset];
            const input_index = arguments.start + offset;
            const producer = self.graph.inputs[input_index];
            if (parameter.value >= self.locations.len or
                producer >= self.locations.len or
                producer >= self.representations.outputs.len or
                parameter.value >= self.representations.outputs.len)
            {
                return error.MalformedGraph;
            }
            const destination = self.locations[parameter.value];
            if (destination == .none or destination == .immediate) continue;
            const assignment: EdgeAssignment = .{
                .source = self.locations[producer],
                .destination = destination,
                .source_kind = self.representations.outputs[producer],
                .destination_kind = self.representations.outputs[parameter.value],
                .conversion = try self.representations.conversionAt(
                    self.graph,
                    input_index,
                ),
            };
            if (assignment.conversion == .none and
                storageLocationEql(assignment.source, assignment.destination))
            {
                continue;
            }
            try pending.append(self.allocator, assignment);
        }
        try self.emitParallelMoves(&pending);
        for (self.graph.params[params.start..params.end()]) |parameter| {
            try self.emitDefinitionHome(parameter.value);
        }
    }

    fn emitParallelMoves(
        self: *CfgCompiler,
        pending: *std.ArrayListUnmanaged(EdgeAssignment),
    ) !void {
        var steps_left = pending.items.len * 2 + 1;
        while (pending.items.len != 0) {
            if (steps_left == 0) return error.InvalidMetadata;
            steps_left -= 1;
            var ready: ?usize = null;
            for (pending.items, 0..) |assignment, index| {
                if (!edgeDestinationIsSource(
                    assignment.destination,
                    pending.items,
                )) {
                    ready = index;
                    break;
                }
            }
            if (ready) |index| {
                try self.emitLocationMove(pending.orderedRemove(index));
                continue;
            }

            var cycle_source: ?struct {
                location: PhysicalLocation,
                kind: representation.Kind,
            } = null;
            for (pending.items) |assignment| {
                if (!isStorageLocation(assignment.source)) continue;
                cycle_source = .{
                    .location = assignment.source,
                    .kind = assignment.source_kind,
                };
                break;
            }
            const source = cycle_source orelse return error.InvalidMetadata;
            try self.emitLocationMove(.{
                .source = source.location,
                .destination = .{ .register = cycle_scratch },
                .source_kind = source.kind,
                .destination_kind = source.kind,
                .conversion = .none,
            });
            for (pending.items) |*assignment| {
                if (storageLocationEql(assignment.source, source.location)) {
                    assignment.source = .{ .register = cycle_scratch };
                }
            }
        }
    }

    fn emitLocationMove(
        self: *CfgCompiler,
        assignment: EdgeAssignment,
    ) !void {
        if (assignment.source_kind == .none or
            assignment.destination_kind == .none)
        {
            return error.InvalidRepresentation;
        }
        const conversion_valid = switch (assignment.conversion) {
            .none => assignment.source_kind == assignment.destination_kind,
            .box_int32 => assignment.source_kind == .int32 and
                assignment.destination_kind == .tagged,
            .check_int32 => false,
        };
        if (!conversion_valid) return error.InvalidRepresentation;
        try self.loadLocation(
            assignment.source,
            assignment.source_kind,
            lhs_scratch,
        );
        if (assignment.conversion == .box_int32) {
            try self.boxInt32(lhs_scratch);
        }
        try self.storeLocation(
            assignment.destination,
            assignment.destination_kind,
            lhs_scratch,
        );
    }

    fn loadLocation(
        self: *CfgCompiler,
        location: PhysicalLocation,
        kind: representation.Kind,
        destination: x86.Reg,
    ) !void {
        switch (location) {
            .none => return error.InvalidMetadata,
            .immediate => |immediate| switch (kind) {
                .tagged => try self.machine.movImm64(
                    destination,
                    try immediateValueBits(self.chunk, immediate),
                ),
                .int32 => switch (immediate) {
                    .int32 => |value| try self.machine.movImm64(
                        destination,
                        @as(u32, @bitCast(value)),
                    ),
                    else => return error.InvalidRepresentation,
                },
                .none => return error.InvalidRepresentation,
            },
            .register => |source| switch (kind) {
                .tagged => try self.machine.movReg64(destination, source),
                .int32 => try self.machine.movReg32(destination, source),
                .none => return error.InvalidRepresentation,
            },
            .tagged_stack => |offset| {
                if (kind != .tagged) return error.InvalidRepresentation;
                try self.machine.load64Disp32(destination, .rsp, offset);
            },
            .int32_stack => |offset| {
                if (kind != .int32) return error.InvalidRepresentation;
                try self.machine.load32Disp32(destination, .rsp, offset);
            },
        }
    }

    fn storeLocation(
        self: *CfgCompiler,
        location: PhysicalLocation,
        kind: representation.Kind,
        source: x86.Reg,
    ) !void {
        switch (location) {
            .none, .immediate => return error.InvalidMetadata,
            .register => |destination| switch (kind) {
                .tagged => try self.machine.movReg64(destination, source),
                .int32 => try self.machine.movReg32(destination, source),
                .none => return error.InvalidRepresentation,
            },
            .tagged_stack => |offset| {
                if (kind != .tagged) return error.InvalidRepresentation;
                try self.machine.store64Disp32(.rsp, offset, source);
            },
            .int32_stack => |offset| {
                if (kind != .int32) return error.InvalidRepresentation;
                try self.machine.store32Disp32(.rsp, offset, source);
            },
        }
    }

    fn boxInt32(self: *CfgCompiler, value: x86.Reg) !void {
        try self.machine.movReg32(value, value);
        try self.machine.movImm64(
            rhs_scratch,
            @as(u64, Value.tag_int32) << 48,
        );
        try self.machine.orReg64(value, rhs_scratch);
    }

    fn emitDefinitionHome(
        self: *CfgCompiler,
        value: ir.ValueId,
    ) !void {
        if (value >= self.homes.values.len or
            value >= self.locations.len or
            value >= self.representations.outputs.len)
        {
            return error.InvalidMetadata;
        }
        const home = self.homes.values[value] orelse return;
        const destination: PhysicalLocation = switch (home) {
            .tagged_stack => |slot| .{
                .tagged_stack = try self.frame.taggedOffset(slot),
            },
            .int32_stack => |slot| .{
                .int32_stack = try self.frame.int32Offset(slot),
            },
        };
        const source = self.locations[value];
        if (storageLocationEql(source, destination)) return;
        try self.emitLocationMove(.{
            .source = source,
            .destination = destination,
            .source_kind = self.representations.outputs[value],
            .destination_kind = self.representations.outputs[value],
            .conversion = .none,
        });
    }

    fn materializeBlockParametersFromFrame(
        self: *CfgCompiler,
        block_index: usize,
        int32_fail: ?*x86.Masm.Label,
    ) !void {
        if (block_index >= self.graph.blocks.len) return error.MalformedGraph;
        const block = self.graph.blocks[block_index];
        if (!block.reachable) return error.MalformedGraph;
        const params = try checkedGraphRange(
            self.graph.params.len,
            block.param_start,
            block.param_count,
        );
        for (self.graph.params[params.start..params.end()]) |parameter| {
            if (parameter.value >= self.locations.len or
                parameter.value >= self.representations.outputs.len)
            {
                return error.MalformedGraph;
            }
            const destination = self.locations[parameter.value];
            if (destination == .none or destination == .immediate) continue;
            try self.loadFrameRole(parameter.role, lhs_scratch);
            switch (self.representations.outputs[parameter.value]) {
                .tagged => try self.storeLocation(
                    destination,
                    .tagged,
                    lhs_scratch,
                ),
                .int32 => {
                    const fail = int32_fail orelse
                        return error.UnsupportedGraph;
                    try self.emitInt32Guard(lhs_scratch, fail);
                    try self.machine.movReg32(lhs_scratch, lhs_scratch);
                    try self.storeLocation(
                        destination,
                        .int32,
                        lhs_scratch,
                    );
                },
                .none => return error.InvalidRepresentation,
            }
            try self.emitDefinitionHome(parameter.value);
        }
    }

    fn loadFrameRole(
        self: *CfgCompiler,
        role: ir.ParamRole,
        destination: x86.Reg,
    ) !void {
        switch (role) {
            .accumulator => try self.machine.load64Disp32(
                destination,
                .rsi,
                layout.frame.accumulator,
            ),
            .register => |register| try self.machine.load64Disp32(
                destination,
                .rdx,
                try registerOffset(register),
            ),
        }
    }

    fn emitOsrEntries(self: *CfgCompiler) !void {
        for (self.osr_meta.headers, 0..) |header, header_index| {
            if (header.block_index >= self.block_labels.len or
                header.block_index >= self.graph.blocks.len or
                !self.graph.blocks[header.block_index].reachable)
            {
                return error.InvalidMetadata;
            }
            const code_off = std.math.cast(
                u32,
                self.machine.code.items.len,
            ) orelse return error.GraphTooLarge;
            try self.osr_entries.append(self.allocator, .{
                .bc = header.bytecode_offset,
                .code_off = code_off,
            });

            var int32_fail: x86.Masm.Label = .{};
            defer int32_fail.deinit(self.allocator);
            const needs_int32 = try self.osr_meta.headerNeedsInt32Checks(
                self.graph,
                self.representations,
                header_index,
            );
            try self.emitPrologue();
            try self.materializeBlockParametersFromFrame(
                header.block_index,
                if (needs_int32) &int32_fail else null,
            );
            try self.machine.jump(&self.block_labels[header.block_index]);

            if (needs_int32) {
                try self.machine.bind(&int32_fail);
                try self.machine.movImm64(
                    .rax,
                    entry.osr_bail_sentinel_bits,
                );
                try self.emitEpilogue();
            }
        }
    }

    fn emitSafepointExit(
        self: *CfgCompiler,
        target_index: usize,
    ) !void {
        if (target_index >= self.graph.blocks.len) return error.MalformedGraph;
        const target = self.graph.blocks[target_index];
        const params = try checkedGraphRange(
            self.graph.params.len,
            target.param_start,
            target.param_count,
        );
        var saw_accumulator = false;
        var seen_registers: [256]bool = @splat(false);
        for (self.graph.params[params.start..params.end()]) |parameter| {
            if (parameter.value >= self.locations.len) return error.MalformedGraph;
            if (self.locations[parameter.value] == .none) {
                try validateFrameRole(
                    parameter.role,
                    &saw_accumulator,
                    &seen_registers,
                    self.graph.register_count,
                    self.chunk.register_count,
                );
                continue;
            }
            try self.emitTaggedValue(parameter.value, lhs_scratch);
            try validateFrameRole(
                parameter.role,
                &saw_accumulator,
                &seen_registers,
                self.graph.register_count,
                self.chunk.register_count,
            );
            switch (parameter.role) {
                .accumulator => try self.machine.store64Disp32(
                    .rsi,
                    layout.frame.accumulator,
                    lhs_scratch,
                ),
                .register => |register| try self.machine.store64Disp32(
                    .rdx,
                    try registerOffset(register),
                    lhs_scratch,
                ),
            }
        }
        if (!saw_accumulator or target.start >= self.chunk.code.len) {
            return error.MalformedGraph;
        }
        try self.machine.movImm64(lhs_scratch, target.start);
        try self.machine.store64Disp32(
            .rsi,
            layout.frame.ip,
            lhs_scratch,
        );
        try self.machine.movImm64(.rax, entry.safepoint_sentinel_bits);
        try self.emitEpilogue();
    }

    fn emitTaggedValue(
        self: *CfgCompiler,
        value: ir.ValueId,
        destination: x86.Reg,
    ) !void {
        if (value >= self.locations.len or
            value >= self.representations.outputs.len)
        {
            return error.MalformedGraph;
        }
        switch (self.representations.outputs[value]) {
            .tagged => try self.loadLocation(
                self.locations[value],
                .tagged,
                destination,
            ),
            .int32 => {
                try self.loadLocation(
                    self.locations[value],
                    .int32,
                    destination,
                );
                try self.boxInt32(destination);
            },
            .none => return error.InvalidRepresentation,
        }
    }

    fn emitGuardExit(
        self: *CfgCompiler,
        point_index: usize,
    ) !void {
        var point = try self.physical_deopt.decode(
            self.allocator,
            point_index,
        );
        defer point.deinit();
        if (point.bytecode_offset >= self.chunk.code.len) {
            return error.InvalidMetadata;
        }
        try self.emitRecoveredFrame(point);
        try self.machine.movImm64(lhs_scratch, point.bytecode_offset);
        try self.machine.store64Disp32(
            .rsi,
            layout.frame.ip,
            lhs_scratch,
        );
        try self.machine.movImm64(.rax, entry.resume_sentinel_bits);
        try self.emitEpilogue();
    }

    fn emitRecoveredFrame(
        self: *CfgCompiler,
        point: deopt_physical.DecodedPoint,
    ) !void {
        var plan = try frame_recovery.Plan.build(self.allocator, point);
        defer plan.deinit();
        for (plan.steps) |step| switch (step) {
            .save_cycle => |source| try emitFrameLoad(
                self.machine,
                source,
                cycle_scratch,
            ),
            .move => |move| try emitFrameMove(self.machine, move),
        };
        for (plan.externals) |external| {
            try self.emitExternalRecovery(
                external.recovery,
                external.destination,
            );
        }
    }

    fn emitExternalRecovery(
        self: *CfgCompiler,
        recovery: deopt_physical.Recovery,
        destination: FrameLocation,
    ) !void {
        switch (recovery) {
            .frame_accumulator, .frame_register => return,
            .immediate => |value| try self.machine.movImm64(
                lhs_scratch,
                try immediateValueBits(self.chunk, value),
            ),
            .tagged_stack => |slot| try self.machine.load64Disp32(
                lhs_scratch,
                .rsp,
                try self.frame.taggedOffset(slot),
            ),
            .int32_stack => |slot| {
                try self.machine.load32Disp32(
                    lhs_scratch,
                    .rsp,
                    try self.frame.int32Offset(slot),
                );
                try self.boxInt32(lhs_scratch);
            },
        }
        try emitFrameStore(self.machine, destination, lhs_scratch);
    }
};

const EdgeAssignment = struct {
    source: PhysicalLocation,
    destination: PhysicalLocation,
    source_kind: representation.Kind,
    destination_kind: representation.Kind,
    conversion: representation.Conversion,
};

fn isStorageLocation(location: PhysicalLocation) bool {
    return switch (location) {
        .register, .tagged_stack, .int32_stack => true,
        .none, .immediate => false,
    };
}

fn storageLocationEql(
    lhs: PhysicalLocation,
    rhs: PhysicalLocation,
) bool {
    if (!isStorageLocation(lhs) or !isStorageLocation(rhs) or
        std.meta.activeTag(lhs) != std.meta.activeTag(rhs))
    {
        return false;
    }
    return switch (lhs) {
        .register => |value| value == rhs.register,
        .tagged_stack => |value| value == rhs.tagged_stack,
        .int32_stack => |value| value == rhs.int32_stack,
        .none, .immediate => false,
    };
}

fn edgeDestinationIsSource(
    destination: PhysicalLocation,
    assignments: []const EdgeAssignment,
) bool {
    for (assignments) |assignment| {
        if (storageLocationEql(destination, assignment.source)) return true;
    }
    return false;
}

const GraphRange = struct {
    start: usize,
    len: usize,

    fn end(self: GraphRange) usize {
        return self.start + self.len;
    }
};

fn checkedGraphRange(
    total: usize,
    raw_start: anytype,
    raw_len: anytype,
) !GraphRange {
    const start: usize = @intCast(raw_start);
    const len: usize = @intCast(raw_len);
    if (start > total or len > total - start) return error.MalformedGraph;
    return .{ .start = start, .len = len };
}

fn validateFrameRole(
    role: ir.ParamRole,
    saw_accumulator: *bool,
    seen_registers: *[256]bool,
    graph_register_count: u8,
    chunk_register_count: u8,
) !void {
    switch (role) {
        .accumulator => {
            if (saw_accumulator.*) return error.MalformedGraph;
            saw_accumulator.* = true;
        },
        .register => |register| {
            if (register >= graph_register_count or
                register >= chunk_register_count or
                seen_registers[register])
            {
                return error.MalformedGraph;
            }
            seen_registers[register] = true;
        },
    }
}
