//! Compact x86_64 leaf lowering for Ohaimark.
//!
//! This matcher accepts constant/formal returns, profiled Number
//! multiply/divide leaves, a fused Int32 strict-equality return diamond, and a
//! monomorphic own-data named load. General control flow and helper boundaries
//! live in `codegen_x86_64.zig`.

const std = @import("std");

const chunk_mod = @import("../../bytecode/chunk.zig");
const Chunk = chunk_mod.Chunk;
const BinaryNumberShape = chunk_mod.BinaryNumberShape;
const x86 = @import("../jit/asm_x86_64.zig");
const layout = @import("../jit/layout.zig");
const Value = @import("../value.zig").Value;
const deopt_physical = @import("deopt_physical.zig");
const ir = @import("ir.zig");
const property_codegen = @import("property_codegen_x86_64.zig");
const representation = @import("representation.zig");
const shared = @import("codegen_x86_64_shared.zig");
const specialize = @import("specialize.zig");
const entry = @import("entry_result.zig");

const Range = shared.Range;
const emitFrameState = shared.emitFrameState;
const immediateValueBits = shared.immediateValueBits;
const nodeInputs = shared.nodeInputs;
const registerOffset = shared.registerOffset;

pub const native_x86_64 = x86.native_x86_64;

/// Unsupported leaves are rejected before installation and fall through to
/// the general backend or lower tiers.
pub const EmitError = error{
    UnsupportedTarget,
    UnsupportedGraph,
    UnsupportedConstant,
    MalformedGraph,
    InvalidRepresentation,
};

/// Emit one `Value` result in the SysV C ABI return register (`rax`).
pub fn emitImmediateReturn(machine: *x86.Masm, bits: u64) !void {
    try machine.movImm64(.rax, bits);
    try machine.ret();
}

/// The third argument of the stable Ohaimark entry ABI is `[ * ]Value` in
/// `rdx` on both SysV x86_64 targets Cynic supports (Linux and macOS).
pub fn emitFrameRegisterReturn(machine: *x86.Masm, register: u8) !void {
    const offset = std.math.cast(i32, @as(u32, register) * @sizeOf(Value)) orelse
        return error.MalformedGraph;
    try machine.load64Disp32(.rax, .rdx, offset);
    try machine.ret();
}

/// The second ABI argument is `CallFrame*` in `rsi`.
pub fn emitFrameAccumulatorReturn(machine: *x86.Masm) !void {
    try machine.load64Disp32(.rax, .rsi, layout.frame.accumulator);
    try machine.ret();
}

/// Lower the initial x86_64 executable subset. Straight-line leaves may contain
/// SSA-only copies and folded pure expressions; the only accepted CFG is the
/// separately verified strict-equality return diamond.
pub fn emitGraph(
    allocator: std.mem.Allocator,
    machine: *x86.Masm,
    chunk: *const Chunk,
    graph: *const ir.Graph,
    specialization: *const specialize.Plan,
    representations: *const representation.Plan,
    physical_deopt: *const deopt_physical.Metadata,
) !void {
    if (comptime !native_x86_64) return error.UnsupportedTarget;
    try specialization.verify(graph);
    try representations.verify(graph, specialization);
    if (try strictEqualityDiamond(graph, specialization, representations)) |diamond| {
        try emitStrictEqualityDiamond(
            allocator,
            machine,
            chunk,
            graph,
            representations,
            physical_deopt,
            diamond,
        );
        return;
    }
    try validateLeafShape(graph, specialization);

    const block = graph.blocks[0];
    const body_start: usize = @intCast(block.node_start);
    const node_count: usize = @intCast(block.node_count);
    if (body_start > graph.nodes.len or node_count == 0 or
        node_count > graph.nodes.len - body_start)
    {
        return error.MalformedGraph;
    }
    const return_index = body_start + node_count - 1;
    const return_node = graph.nodes[return_index];
    const input_start: usize = @intCast(return_node.input_start);
    if (return_node.kind != .return_ or return_node.input_count != 1 or
        input_start >= graph.inputs.len)
    {
        return error.MalformedGraph;
    }
    const producer = graph.inputs[input_start];
    if (producer >= graph.nodes.len or producer >= representations.outputs.len) {
        return error.MalformedGraph;
    }
    const conversion = try representations.conversionAt(graph, input_start);
    const producer_node = graph.nodes[producer];
    const producer_info = specialization.node_info[producer];
    if (isNumberLeaf(producer_node.kind, producer_info.lowering)) {
        try emitNumberLeaf(
            allocator,
            machine,
            chunk,
            graph,
            specialization,
            representations,
            physical_deopt,
            producer,
        );
        return;
    }
    if (producer_node.kind == .load_named and
        producer_info.lowering == .load_named_own)
    {
        if (conversion != .none) return error.InvalidRepresentation;
        try emitNamedOwnLeaf(
            allocator,
            machine,
            chunk,
            graph,
            specialization,
            representations,
            physical_deopt,
            producer,
        );
        return;
    }
    switch (producer_node.kind) {
        .block_parameter => {
            if (representations.outputs[producer] != .tagged or conversion != .none) {
                return error.UnsupportedGraph;
            }
            try emitParameterReturn(machine, graph, producer);
        },
        else => {
            const immediate = try foldedImmediate(graph, specialization, producer);
            const bits = try taggedImmediateBits(chunk, immediate, representations.outputs[producer]);
            if ((representations.outputs[producer] == .tagged and conversion != .none) or
                (representations.outputs[producer] == .int32 and conversion != .box_int32))
            {
                return error.InvalidRepresentation;
            }
            try emitImmediateReturn(machine, bits);
        },
    }
}

const EqualityDiamond = struct {
    comparison: ir.ValueId,
    condition: ir.BranchCondition,
    taken: ir.Edge,
    fallthrough: ir.Edge,
};

fn strictEqualityDiamond(
    graph: *const ir.Graph,
    specialization: *const specialize.Plan,
    representations: *const representation.Plan,
) !?EqualityDiamond {
    if (graph.entry_environment_slots != null or graph.blocks.len != 3 or
        graph.edges.len != 2 or graph.nodes.len == 0 or
        specialization.node_info.len != graph.nodes.len or
        representations.outputs.len != graph.nodes.len)
    {
        return null;
    }
    for (graph.blocks) |block| {
        if (!block.reachable) return null;
        try validateBlockRanges(graph, block);
    }

    const entry_block = graph.blocks[0];
    const entry_body = try blockBody(graph, entry_block);
    if (entry_body.len != 2) return null;
    const comparison = entry_body.start;
    const branch_id = entry_body.start + 1;
    const comparison_node = graph.nodes[comparison];
    const comparison_info = specialization.node_info[comparison];
    const branch_node = graph.nodes[branch_id];
    if (comparison_node.kind != .strict_eq or comparison_node.input_count != 2 or
        comparison_node.frame_state == null or comparison_info.lowering != .strict_eq or
        representations.outputs[comparison] != .tagged or
        branch_node.kind != .branch or branch_node.input_count != 1)
    {
        return null;
    }
    const branch_inputs = try nodeInputs(graph, branch_node);
    if (graph.inputs[branch_inputs.start] != comparison) return null;
    const condition = switch (branch_node.payload) {
        .branch => |value| value,
        else => return null,
    };
    if (condition == .nullish) return null;

    var taken: ?ir.Edge = null;
    var fallthrough: ?ir.Edge = null;
    for (graph.blockEdges(0)) |edge| {
        if (edge.from != 0 or edge.to == 0 or edge.to >= graph.blocks.len or
            edge.argument_count != graph.blocks[edge.to].param_count)
        {
            return error.MalformedGraph;
        }
        switch (edge.kind) {
            .branch_taken => {
                if (taken != null) return error.MalformedGraph;
                taken = edge;
            },
            .branch_fallthrough => {
                if (fallthrough != null) return error.MalformedGraph;
                fallthrough = edge;
            },
            else => return null,
        }
    }
    const taken_edge = taken orelse return null;
    const fallthrough_edge = fallthrough orelse return null;
    if (taken_edge.to == fallthrough_edge.to) return error.MalformedGraph;
    try validateReturnEdge(graph, representations, taken_edge);
    try validateReturnEdge(graph, representations, fallthrough_edge);
    return .{
        .comparison = std.math.cast(ir.ValueId, comparison) orelse
            return error.MalformedGraph,
        .condition = condition,
        .taken = taken_edge,
        .fallthrough = fallthrough_edge,
    };
}

fn validateBlockRanges(graph: *const ir.Graph, block: ir.Block) !void {
    const param_start: usize = @intCast(block.param_start);
    const param_count: usize = @intCast(block.param_count);
    const node_start: usize = @intCast(block.node_start);
    const node_count: usize = @intCast(block.node_count);
    const edge_start: usize = @intCast(block.edge_start);
    const edge_count: usize = @intCast(block.edge_count);
    if (param_start > graph.params.len or param_count > graph.params.len - param_start or
        node_start > graph.nodes.len or node_count > graph.nodes.len - node_start or
        edge_start > graph.edges.len or edge_count > graph.edges.len - edge_start)
    {
        return error.MalformedGraph;
    }
}

fn blockBody(graph: *const ir.Graph, block: ir.Block) !Range {
    try validateBlockRanges(graph, block);
    return .{
        .start = @intCast(block.node_start),
        .len = @intCast(block.node_count),
    };
}

fn validateReturnEdge(
    graph: *const ir.Graph,
    representations: *const representation.Plan,
    edge: ir.Edge,
) !void {
    if (edge.to >= graph.blocks.len) return error.MalformedGraph;
    const block = graph.blocks[edge.to];
    if (block.predecessor_count != 1 or block.edge_count != 0) {
        return error.UnsupportedGraph;
    }
    const body = try blockBody(graph, block);
    if (body.len != 1) return error.UnsupportedGraph;
    const return_node = graph.nodes[body.start];
    const inputs = try nodeInputs(graph, return_node);
    if (return_node.kind != .return_ or inputs.len != 1) return error.UnsupportedGraph;
    _ = try resolveEdgeReturnValue(graph, representations, edge, graph.inputs[inputs.start]);
}

fn resolveEdgeReturnValue(
    graph: *const ir.Graph,
    representations: *const representation.Plan,
    edge: ir.Edge,
    value: ir.ValueId,
) !ir.ValueId {
    if (edge.to >= graph.blocks.len or value >= graph.nodes.len or
        value >= representations.outputs.len)
    {
        return error.MalformedGraph;
    }
    const target = graph.blocks[edge.to];
    const parameter_index: usize = switch (graph.nodes[value].payload) {
        .parameter => |index| index,
        else => return error.UnsupportedGraph,
    };
    const param_start: usize = @intCast(target.param_start);
    const param_count: usize = @intCast(target.param_count);
    if (parameter_index < param_start or parameter_index >= param_start + param_count or
        parameter_index >= graph.params.len or graph.params[parameter_index].value != value)
    {
        return error.MalformedGraph;
    }
    const argument_start: usize = @intCast(edge.argument_start);
    const argument_count: usize = @intCast(edge.argument_count);
    if (argument_start > graph.inputs.len or
        argument_count > graph.inputs.len - argument_start or
        argument_count != param_count)
    {
        return error.MalformedGraph;
    }
    const argument_index = argument_start + parameter_index - param_start;
    const source = graph.inputs[argument_index];
    if (source >= graph.nodes.len or source >= representations.outputs.len or
        representations.outputs[source] != .tagged or
        try representations.conversionAt(graph, argument_index) != .none)
    {
        return error.UnsupportedGraph;
    }
    _ = try entryParameterRole(graph, source);
    return source;
}

fn emitStrictEqualityDiamond(
    allocator: std.mem.Allocator,
    machine: *x86.Masm,
    chunk: *const Chunk,
    graph: *const ir.Graph,
    representations: *const representation.Plan,
    physical_deopt: *const deopt_physical.Metadata,
    diamond: EqualityDiamond,
) !void {
    const comparison = graph.nodes[diamond.comparison];
    const inputs = try nodeInputs(graph, comparison);
    if (inputs.len != 2) return error.MalformedGraph;
    const point_index = try deoptPointIndex(physical_deopt, diamond.comparison);
    var point = try physical_deopt.decode(allocator, point_index);
    defer point.deinit();
    if (point.bytecode_offset != comparison.bytecode_offset) return error.InvalidMetadata;
    try validateEntryOnlyRecovery(point);

    var guard: x86.Masm.Label = .{};
    defer guard.deinit(allocator);
    var taken: x86.Masm.Label = .{};
    defer taken.deinit(allocator);

    try emitCheckedInt32Input(machine, graph, representations, inputs.start, .rax, &guard);
    try emitCheckedInt32Input(machine, graph, representations, inputs.start + 1, .rcx, &guard);
    try machine.cmpReg64(.rax, .rcx);
    try machine.jumpCond(
        if (diamond.condition == .truthy) .equal else .not_equal,
        &taken,
    );
    try emitEdgeReturn(machine, graph, representations, diamond.fallthrough);
    try machine.bind(&taken);
    try emitEdgeReturn(machine, graph, representations, diamond.taken);

    try machine.bind(&guard);
    try emitGuardExit(allocator, machine, chunk, point);
}

fn emitCheckedInt32Input(
    machine: *x86.Masm,
    graph: *const ir.Graph,
    representations: *const representation.Plan,
    input_index: usize,
    destination: x86.Reg,
    guard: *x86.Masm.Label,
) !void {
    if (input_index >= graph.inputs.len or
        input_index >= representations.input_requirements.len)
    {
        return error.MalformedGraph;
    }
    const producer = graph.inputs[input_index];
    if (producer >= graph.nodes.len or producer >= representations.outputs.len or
        representations.outputs[producer] != .tagged or
        try representations.conversionAt(graph, input_index) != .check_int32)
    {
        return error.UnsupportedGraph;
    }
    try emitParameterValue(machine, graph, producer, destination);
    try emitInt32TagGuard(machine, destination, guard);
}

fn emitInt32TagGuard(
    machine: *x86.Masm,
    value: x86.Reg,
    guard: *x86.Masm.Label,
) !void {
    try machine.movReg64(.r10, value);
    try machine.shrImm8(.r10, 48);
    try machine.movImm64(.r11, Value.tag_int32);
    try machine.cmpReg64(.r10, .r11);
    try machine.jumpCond(.not_equal, guard);
}

fn emitEdgeReturn(
    machine: *x86.Masm,
    graph: *const ir.Graph,
    representations: *const representation.Plan,
    edge: ir.Edge,
) !void {
    const block = graph.blocks[edge.to];
    const body = try blockBody(graph, block);
    const return_node = graph.nodes[body.start];
    const inputs = try nodeInputs(graph, return_node);
    if (inputs.len != 1 or
        try representations.conversionAt(graph, inputs.start) != .none)
    {
        return error.UnsupportedGraph;
    }
    const source = try resolveEdgeReturnValue(
        graph,
        representations,
        edge,
        graph.inputs[inputs.start],
    );
    try emitParameterValue(machine, graph, source, .rax);
    try machine.ret();
}

fn validateLeafShape(graph: *const ir.Graph, specialization: *const specialize.Plan) !void {
    if (graph.entry_environment_slots != null or graph.blocks.len != 1 or
        graph.nodes.len == 0 or specialization.node_info.len != graph.nodes.len or
        graph.edges.len != 0)
    {
        return error.UnsupportedGraph;
    }
    const block = graph.blocks[0];
    const body_start: usize = @intCast(block.node_start);
    const body_count: usize = @intCast(block.node_count);
    if (body_start > graph.nodes.len or body_count == 0 or
        body_count > graph.nodes.len - body_start)
    {
        return error.MalformedGraph;
    }
    if (!block.reachable or block.param_start != 0 or
        @as(usize, block.param_count) != graph.params.len or
        body_start != graph.params.len or body_start + body_count != graph.nodes.len or
        block.edge_start != 0 or block.edge_count != 0)
    {
        return error.MalformedGraph;
    }
    for (graph.nodes[0..body_start]) |node| {
        if (node.kind != .block_parameter) return error.MalformedGraph;
    }
    const return_index = body_start + body_count - 1;
    const return_node = graph.nodes[return_index];
    const return_input_start: usize = @intCast(return_node.input_start);
    if (return_node.kind != .return_) return error.UnsupportedGraph;
    if (return_node.input_count != 1 or return_input_start >= graph.inputs.len) {
        return error.MalformedGraph;
    }
    const return_producer = graph.inputs[return_input_start];
    if (return_producer >= graph.nodes.len) return error.MalformedGraph;

    for (graph.nodes, specialization.node_info, 0..) |node, info, index| {
        const terminal = index + 1 == graph.nodes.len;
        switch (node.kind) {
            .block_parameter, .constant => {},
            .add, .sub, .mul, .div, .strict_eq, .logical_not, .less_than => {
                const dynamic_number_leaf = index == return_producer and
                    isNumberLeaf(node.kind, info.lowering);
                if (!dynamic_number_leaf and
                    (info.lowering != .constant or info.folded == null))
                {
                    return error.UnsupportedGraph;
                }
            },
            .load_named => {
                if (index != return_producer or info.lowering != .load_named_own) {
                    return error.UnsupportedGraph;
                }
            },
            .return_ => {
                if (!terminal) return error.MalformedGraph;
            },
            else => return error.UnsupportedGraph,
        }
        if (terminal and node.kind != .return_) return error.MalformedGraph;
        if (!terminal and node.kind == .return_) return error.MalformedGraph;
    }
}

fn isNumberLeaf(kind: ir.NodeKind, lowering: specialize.Lowering) bool {
    return (kind == .mul and lowering == .number_mul) or
        (kind == .div and lowering == .number_div);
}

const NumberInputKind = enum {
    int32,
    double,
};

fn numberInputKind(shape: BinaryNumberShape, operand: usize) !NumberInputKind {
    if (operand >= 2) return error.MalformedGraph;
    return switch (shape) {
        .int32_int32 => .int32,
        .double_int32 => if (operand == 0) .double else .int32,
        .int32_double => if (operand == 0) .int32 else .double,
        .double_double => .double,
        .cold, .polymorphic => error.UnsupportedGraph,
    };
}

fn emitNumberLeaf(
    allocator: std.mem.Allocator,
    machine: *x86.Masm,
    chunk: *const Chunk,
    graph: *const ir.Graph,
    specialization: *const specialize.Plan,
    representations: *const representation.Plan,
    physical_deopt: *const deopt_physical.Metadata,
    node_id: ir.ValueId,
) !void {
    if (node_id >= graph.nodes.len or node_id >= specialization.node_info.len or
        node_id >= representations.outputs.len)
    {
        return error.MalformedGraph;
    }
    const node = graph.nodes[node_id];
    const info = specialization.node_info[node_id];
    if (!isNumberLeaf(node.kind, info.lowering) or
        representations.outputs[node_id] != .tagged or node.input_count != 2)
    {
        return error.UnsupportedGraph;
    }
    const number_shape = info.number_shape orelse return error.UnsupportedGraph;
    const inputs = try nodeInputs(graph, node);
    const point_index = try deoptPointIndex(physical_deopt, node_id);
    var point = try physical_deopt.decode(allocator, point_index);
    defer point.deinit();
    if (point.bytecode_offset != node.bytecode_offset) return error.InvalidMetadata;
    try validateEntryOnlyRecovery(point);

    var guard: x86.Masm.Label = .{};
    defer guard.deinit(allocator);
    try emitTaggedLeafOperand(
        machine,
        chunk,
        graph,
        representations,
        inputs.start,
        .rax,
    );
    try emitTaggedLeafOperand(
        machine,
        chunk,
        graph,
        representations,
        inputs.start + 1,
        .rcx,
    );
    try emitTaggedNumberAsDouble(
        machine,
        .rax,
        .xmm0,
        &guard,
        try numberInputKind(number_shape, 0),
    );
    try emitTaggedNumberAsDouble(
        machine,
        .rcx,
        .xmm1,
        &guard,
        try numberInputKind(number_shape, 1),
    );
    switch (node.kind) {
        .mul => try machine.mulDouble(.xmm0, .xmm1),
        .div => try machine.divDouble(.xmm0, .xmm1),
        else => return error.MalformedGraph,
    }
    // Canonicalize NaN through Lantern. Every other finite/infinite IEEE-754
    // value can be re-boxed by a wrapping add of the NaN-box offset.
    try machine.ucomisDouble(.xmm0, .xmm0);
    try machine.jumpCond(.parity, &guard);
    try machine.movQRegFromXmm(.rax, .xmm0);
    try machine.movImm64(.r10, Value.double_encode_offset);
    try machine.addReg64(.rax, .r10);
    try machine.ret();

    try machine.bind(&guard);
    try emitGuardExit(allocator, machine, chunk, point);
}

fn emitNamedOwnLeaf(
    allocator: std.mem.Allocator,
    machine: *x86.Masm,
    chunk: *const Chunk,
    graph: *const ir.Graph,
    specialization: *const specialize.Plan,
    representations: *const representation.Plan,
    physical_deopt: *const deopt_physical.Metadata,
    node_id: ir.ValueId,
) !void {
    if (node_id >= graph.nodes.len or node_id >= specialization.node_info.len or
        node_id >= representations.outputs.len)
    {
        return error.MalformedGraph;
    }
    const node = graph.nodes[node_id];
    if (representations.outputs[node_id] != .tagged) {
        return error.UnsupportedGraph;
    }
    const site = try property_codegen.ownSite(
        chunk,
        graph,
        specialization,
        node_id,
    );

    const inputs = try nodeInputs(graph, node);
    const point_index = try deoptPointIndex(physical_deopt, node_id);
    var point = try physical_deopt.decode(allocator, point_index);
    defer point.deinit();
    if (point.bytecode_offset != node.bytecode_offset) return error.InvalidMetadata;
    try validateEntryOnlyRecovery(point);

    var guard: x86.Masm.Label = .{};
    defer guard.deinit(allocator);
    try emitTaggedLeafOperand(
        machine,
        chunk,
        graph,
        representations,
        inputs.start,
        .rax,
    );
    try property_codegen.emitOwn(machine, site, .rax, &guard);
    try machine.ret();

    try machine.bind(&guard);
    try emitGuardExit(allocator, machine, chunk, point);
}

fn emitGuardExit(
    allocator: std.mem.Allocator,
    machine: *x86.Masm,
    chunk: *const Chunk,
    point: deopt_physical.DecodedPoint,
) !void {
    try emitFrameState(allocator, machine, chunk, point);
    try machine.movImm64(.r10, point.bytecode_offset);
    try machine.store64Disp32(.rsi, layout.frame.ip, .r10);
    try machine.movImm64(.rax, entry.resume_sentinel_bits);
    try machine.ret();
}

fn deoptPointIndex(
    physical_deopt: *const deopt_physical.Metadata,
    node_id: ir.ValueId,
) !usize {
    for (physical_deopt.points, 0..) |point, index| {
        if (point.node == node_id) return index;
    }
    return error.InvalidMetadata;
}

fn validateEntryOnlyRecovery(point: deopt_physical.DecodedPoint) !void {
    try validateEntryRecovery(point.accumulator);
    for (point.slots) |slot| try validateEntryRecovery(slot.recovery);
}

fn validateEntryRecovery(recovery: deopt_physical.Recovery) !void {
    return switch (recovery) {
        .frame_accumulator, .frame_register, .immediate => {},
        .tagged_stack, .int32_stack => error.UnsupportedGraph,
    };
}

fn emitTaggedLeafOperand(
    machine: *x86.Masm,
    chunk: *const Chunk,
    graph: *const ir.Graph,
    representations: *const representation.Plan,
    input_index: usize,
    destination: x86.Reg,
) !void {
    if (input_index >= graph.inputs.len or input_index >= representations.input_requirements.len) {
        return error.MalformedGraph;
    }
    const producer = graph.inputs[input_index];
    if (producer >= graph.nodes.len or producer >= representations.outputs.len) {
        return error.MalformedGraph;
    }
    const conversion = try representations.conversionAt(graph, input_index);
    switch (graph.nodes[producer].kind) {
        .block_parameter => {
            if (representations.outputs[producer] != .tagged or conversion != .none) {
                return error.InvalidRepresentation;
            }
            try emitParameterValue(machine, graph, producer, destination);
        },
        .constant => {
            const immediate = try foldedImmediateFromNode(graph, producer);
            const bits = try taggedOperandImmediateBits(
                chunk,
                immediate,
                representations.outputs[producer],
                conversion,
            );
            try machine.movImm64(destination, bits);
        },
        else => return error.UnsupportedGraph,
    }
}

fn emitTaggedNumberAsDouble(
    machine: *x86.Masm,
    value: x86.Reg,
    destination: x86.Xmm,
    guard: *x86.Masm.Label,
    input_kind: NumberInputKind,
) !void {
    try machine.movReg64(.r10, value);
    try machine.shrImm8(.r10, 48);
    switch (input_kind) {
        .int32 => {
            try machine.movImm64(.r11, Value.tag_int32);
            try machine.cmpReg64(.r10, .r11);
            try machine.jumpCond(.not_equal, guard);
            try machine.cvtI32ToDouble(destination, value);
        },
        .double => {
            try machine.movImm64(.r11, Value.tag_object);
            try machine.cmpReg64(.r10, .r11);
            try machine.jumpCond(.above_or_equal, guard);
            try machine.movImm64(.r10, Value.double_encode_offset);
            try machine.movReg64(.r11, value);
            try machine.subReg64(.r11, .r10);
            try machine.movQXmmFromReg(destination, .r11);
        },
    }
}

fn emitParameterReturn(machine: *x86.Masm, graph: *const ir.Graph, value: ir.ValueId) !void {
    switch (try entryParameterRole(graph, value)) {
        .accumulator => try emitFrameAccumulatorReturn(machine),
        .register => |register| try emitFrameRegisterReturn(machine, register),
    }
}

fn emitParameterValue(
    machine: *x86.Masm,
    graph: *const ir.Graph,
    value: ir.ValueId,
    destination: x86.Reg,
) !void {
    switch (try entryParameterRole(graph, value)) {
        .accumulator => try machine.load64Disp32(
            destination,
            .rsi,
            layout.frame.accumulator,
        ),
        .register => |register| try machine.load64Disp32(
            destination,
            .rdx,
            try registerOffset(register),
        ),
    }
}

fn entryParameterRole(graph: *const ir.Graph, value: ir.ValueId) !ir.ParamRole {
    if (graph.blocks.len == 0 or value >= graph.nodes.len) return error.MalformedGraph;
    const node = graph.nodes[value];
    const parameter_index: usize = switch (node.payload) {
        .parameter => |index| index,
        else => return error.MalformedGraph,
    };
    const block = graph.blocks[0];
    const parameter_end = @as(usize, block.param_start) + @as(usize, block.param_count);
    if (parameter_index < @as(usize, block.param_start) or parameter_index >= parameter_end or
        parameter_index >= graph.params.len)
    {
        return error.MalformedGraph;
    }
    const parameter = graph.params[parameter_index];
    if (parameter.value != value) return error.MalformedGraph;
    switch (parameter.role) {
        .accumulator => {},
        .register => |register| {
            if (register >= graph.register_count) return error.MalformedGraph;
        },
    }
    return parameter.role;
}

fn foldedImmediate(
    graph: *const ir.Graph,
    specialization: *const specialize.Plan,
    value: ir.ValueId,
) !ir.Immediate {
    if (value >= graph.nodes.len or value >= specialization.node_info.len) {
        return error.MalformedGraph;
    }
    if (specialization.node_info[value].folded) |immediate| return immediate;
    return switch (graph.nodes[value].payload) {
        .immediate => |immediate| immediate,
        else => error.UnsupportedGraph,
    };
}

fn foldedImmediateFromNode(graph: *const ir.Graph, value: ir.ValueId) !ir.Immediate {
    if (value >= graph.nodes.len) return error.MalformedGraph;
    return switch (graph.nodes[value].payload) {
        .immediate => |immediate| immediate,
        else => error.UnsupportedGraph,
    };
}

fn taggedOperandImmediateBits(
    chunk: *const Chunk,
    immediate: ir.Immediate,
    kind: representation.Kind,
    conversion: representation.Conversion,
) !u64 {
    return switch (kind) {
        .tagged => if (conversion == .none)
            taggedImmediateBits(chunk, immediate, .tagged)
        else
            error.InvalidRepresentation,
        .int32 => if (conversion == .box_int32)
            taggedImmediateBits(chunk, immediate, .int32)
        else
            error.InvalidRepresentation,
        .none => error.InvalidRepresentation,
    };
}

fn taggedImmediateBits(
    chunk: *const Chunk,
    immediate: ir.Immediate,
    kind: representation.Kind,
) !u64 {
    return switch (kind) {
        .int32 => switch (immediate) {
            .int32 => |value| Value.fromInt32(value).bits,
            else => error.InvalidRepresentation,
        },
        .tagged => switch (immediate) {
            .int32 => error.InvalidRepresentation,
            else => immediateValueBits(chunk, immediate),
        },
        .none => error.InvalidRepresentation,
    };
}
