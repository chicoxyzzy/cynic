//! x86_64 emission for Ohaimark's monomorphic own-data named loads.
//!
//! Both the compact leaf matcher and the general CFG backend use this module,
//! so mutable IC validation and scratch-register policy stay identical.

const std = @import("std");

const chunk_mod = @import("../../bytecode/chunk.zig");
const Chunk = chunk_mod.Chunk;
const LoadICCell = chunk_mod.LoadICCell;
const x86 = @import("../jit/asm_x86_64.zig");
const layout = @import("../jit/layout.zig");
const Shape = @import("../shape.zig").Shape;
const ir = @import("ir.zig");
const specialize = @import("specialize.zig");

pub const OwnSite = struct {
    cell: *const LoadICCell,
    receiver_shape: *Shape,
    slot: u32,
};

/// Validate the immutable specialization facts and retain only the live IC
/// cell pointer needed by generated code. The weak cell is rechecked at every
/// execution; this function merely rejects inconsistent compiler metadata.
pub fn ownSite(
    chunk: *const Chunk,
    graph: *const ir.Graph,
    specialization: *const specialize.Plan,
    node_id: ir.ValueId,
) !OwnSite {
    if (node_id >= graph.nodes.len or
        node_id >= specialization.node_info.len)
    {
        return error.MalformedGraph;
    }
    const node = graph.nodes[node_id];
    const info = specialization.node_info[node_id];
    if (node.kind != .load_named or
        info.lowering != .load_named_own or
        node.input_count != 1)
    {
        return error.UnsupportedGraph;
    }
    const site = switch (node.payload) {
        .named_load => |value| value,
        else => return error.MalformedGraph,
    };
    if (site.key_constant >= chunk.constants.len or
        !chunk.constants[site.key_constant].isString() or
        site.feedback_index >= chunk.inline_load_caches.len)
    {
        return error.InvalidMetadata;
    }
    const assumption_index = info.assumption orelse
        return error.InvalidMetadata;
    if (assumption_index >= specialization.assumptions.len) {
        return error.InvalidMetadata;
    }
    const assumption = specialization.assumptions[assumption_index];
    const receiver_shape = assumption.receiver_shape orelse
        return error.InvalidMetadata;
    if (assumption.kind != .load_own or
        assumption.feedback_index != site.feedback_index or
        assumption.holder_shape != null or
        assumption.revision != 0 or
        assumption.slot >= receiver_shape.property_count)
    {
        return error.InvalidMetadata;
    }
    return .{
        .cell = &chunk.inline_load_caches[site.feedback_index],
        .receiver_shape = receiver_shape,
        .slot = assumption.slot,
    };
}

/// Guard and load one own data slot. `value` contains the tagged receiver on
/// entry and the tagged property value on success. rcx/r11 are clobbered;
/// every miss branches before mutating Lantern frame state.
pub fn emitOwn(
    machine: *x86.Masm,
    site: OwnSite,
    value: x86.Reg,
    guard: *x86.Masm.Label,
) !void {
    if (value == .rcx or value == .r11 or
        site.slot >= site.receiver_shape.property_count)
    {
        return error.InvalidMetadata;
    }

    try emitPlainObject(machine, value, value, guard);

    try machine.movImm64(.r11, @intFromPtr(site.cell));
    try machine.movImm64(.rcx, @intFromPtr(site.receiver_shape));
    try machine.cmp64Disp32Reg(
        .r11,
        layout.load_ic_cell.shape,
        .rcx,
    );
    try machine.jumpCond(.not_equal, guard);
    try machine.cmp64Disp32Reg(value, layout.object.shape, .rcx);
    try machine.jumpCond(.not_equal, guard);
    try machine.cmp32Disp32Imm32(
        .r11,
        layout.load_ic_cell.slot,
        site.slot,
    );
    try machine.jumpCond(.not_equal, guard);
    try machine.cmp64Disp32Imm8(
        .r11,
        layout.load_ic_cell.proto,
        0,
    );
    try machine.jumpCond(.not_equal, guard);
    try machine.cmp8Disp32Imm8(
        .r11,
        layout.load_ic_cell.kind,
        layout.load_ic_cell.kind_data,
    );
    try machine.jumpCond(.not_equal, guard);

    try emitSlotRead(machine, value, value, site.slot);
}

/// Prove `source` is a plain-object Value and decode its pointer into
/// `destination`. r11 is clobbered; every miss precedes any heap mutation.
pub fn emitPlainObject(
    machine: *x86.Masm,
    source: x86.Reg,
    destination: x86.Reg,
    guard: *x86.Masm.Label,
) !void {
    if (source == .r11 or destination == .r11) {
        return error.InvalidMetadata;
    }
    if (source != destination) try machine.movReg64(destination, source);
    const expected = layout.value_bits.tag_object_shifted |
        layout.value_bits.kind_object;
    const tag_and_kind_mask = ~layout.value_bits.pointer_mask |
        layout.value_bits.kind_mask;
    try machine.movImm64(.r11, expected);
    try machine.xorReg64(destination, .r11);
    try machine.movImm64(.r11, tag_and_kind_mask);
    try machine.testReg64(destination, .r11);
    try machine.jumpCond(.not_equal, guard);
}

pub fn emitSlotRead(
    machine: *x86.Masm,
    destination: x86.Reg,
    object: x86.Reg,
    slot: u32,
) !void {
    const displacement = try slotDisplacement(slot);
    if (slot < layout.object.inline_slot_cap) {
        try machine.load64Disp32(destination, object, displacement);
        return;
    }
    if (object == .r11) return error.InvalidMetadata;
    try machine.load64Disp32(
        .r11,
        object,
        layout.object.overflow_items_ptr,
    );
    try machine.load64Disp32(destination, .r11, displacement);
}

pub fn emitSlotWrite(
    machine: *x86.Masm,
    source: x86.Reg,
    object: x86.Reg,
    slot: u32,
) !void {
    const displacement = try slotDisplacement(slot);
    if (slot < layout.object.inline_slot_cap) {
        try machine.store64Disp32(object, displacement, source);
        return;
    }
    if (object == .r11 or source == .r11) return error.InvalidMetadata;
    try machine.load64Disp32(
        .r11,
        object,
        layout.object.overflow_items_ptr,
    );
    try machine.store64Disp32(.r11, displacement, source);
}

fn slotDisplacement(slot: u32) !i32 {
    const index: usize = slot;
    if (slot < layout.object.inline_slot_cap) {
        const bytes = std.math.mul(usize, index, @sizeOf(u64)) catch
            return error.InvalidMetadata;
        const offset = std.math.add(
            usize,
            layout.object.inline_slots,
            bytes,
        ) catch return error.InvalidMetadata;
        return std.math.cast(i32, offset) orelse error.InvalidMetadata;
    }
    const overflow_index = index - layout.object.inline_slot_cap;
    const bytes = std.math.mul(
        usize,
        overflow_index,
        @sizeOf(u64),
    ) catch return error.InvalidMetadata;
    return std.math.cast(i32, bytes) orelse error.InvalidMetadata;
}
