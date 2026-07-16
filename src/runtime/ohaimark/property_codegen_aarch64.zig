//! AArch64 emission for Ohaimark's speculative named-property loads.
//!
//! The graph compiler supplies a verified, pointer-light assumption and the
//! live chunk-owned IC cell. This module validates the immutable shape/slot/
//! revision facts against that cell, reads GC-managed state only through the
//! cell, and jumps to the caller's frame-reconstructing guard exit on a miss.

const std = @import("std");

const LoadICCell = @import("../../bytecode/chunk.zig").LoadICCell;
const a64 = @import("../jit/asm_aarch64.zig");
const layout = @import("../jit/layout.zig");
const Masm = @import("../jit/masm.zig").Masm;
const Shape = @import("../shape.zig").Shape;

const object_scratch: a64.Reg = .x13;
const cell_scratch: a64.Reg = .x14;
const guard_scratch: a64.Reg = .x15;

pub const Mode = enum {
    own_data,
    prototype_data,
    synthetic_accessor,
};

pub const Expected = struct {
    mode: Mode,
    receiver_shape: *Shape,
    holder_shape: ?*Shape,
    slot: u32,
    revision: u64,
};

/// Emit a guarded property load. `receiver_value` initially contains the
/// tagged receiver and contains the tagged result on success. x13-x15 are
/// clobbered; all failures branch to `guard` without modifying Lantern state.
pub fn emit(
    allocator: std.mem.Allocator,
    machine: *Masm,
    realm_register: a64.Reg,
    cell: *const LoadICCell,
    expected: Expected,
    receiver_value: a64.Reg,
    guard: *Masm.Label,
) !a64.Reg {
    if (receiver_value == object_scratch or
        receiver_value == cell_scratch or
        receiver_value == guard_scratch)
    {
        return error.InvalidRegister;
    }
    const holder_shape: ?*Shape = switch (expected.mode) {
        .own_data => blk: {
            if (expected.holder_shape != null or
                expected.slot >= expected.receiver_shape.property_count)
            {
                return error.InvalidMetadata;
            }
            break :blk null;
        },
        .prototype_data => blk: {
            const holder = expected.holder_shape orelse return error.InvalidMetadata;
            if (expected.slot >= holder.property_count) return error.InvalidMetadata;
            break :blk holder;
        },
        .synthetic_accessor => blk: {
            if (expected.slot != 0) return error.InvalidMetadata;
            break :blk expected.holder_shape orelse return error.InvalidMetadata;
        },
    };

    try emitPlainObject(allocator, machine, receiver_value, object_scratch, guard);
    try machine.movImm64(cell_scratch, @intFromPtr(cell));

    // The copied assumption and mutable side table must still describe the
    // same site. Prototype identity and synthetic value deliberately are not
    // copied assumptions; their live checks happen below.
    try machine.emit(a64.ldrImm(
        guard_scratch,
        cell_scratch,
        layout.load_ic_cell.shape,
    ));
    try machine.movImm64(receiver_value, @intFromPtr(expected.receiver_shape));
    try machine.emit(a64.cmpReg(guard_scratch, receiver_value));
    try jumpToGuardIf(allocator, machine, .ne, guard);
    try machine.emit(a64.ldrImm(
        receiver_value,
        object_scratch,
        layout.object.shape,
    ));
    try machine.emit(a64.cmpReg(receiver_value, guard_scratch));
    try jumpToGuardIf(allocator, machine, .ne, guard);
    try machine.emit(a64.ldrImmW(
        guard_scratch,
        cell_scratch,
        layout.load_ic_cell.slot,
    ));
    try machine.movImm64(receiver_value, expected.slot);
    try machine.emit(a64.cmpReg(guard_scratch, receiver_value));
    try jumpToGuardIf(allocator, machine, .ne, guard);

    switch (expected.mode) {
        .own_data => {
            try machine.emit(a64.ldrImm(
                receiver_value,
                cell_scratch,
                layout.load_ic_cell.proto,
            ));
            try machine.emit(a64.cmpImm(receiver_value, 0, false));
            try jumpToGuardIf(allocator, machine, .ne, guard);
            try machine.emit(a64.ldrbImm(
                receiver_value,
                cell_scratch,
                layout.load_ic_cell.kind,
            ));
            try machine.emit(a64.cmpImm(
                receiver_value,
                layout.load_ic_cell.kind_data,
                false,
            ));
            try jumpToGuardIf(allocator, machine, .ne, guard);
            try machine.emit(a64.ldrImmW(
                guard_scratch,
                cell_scratch,
                layout.load_ic_cell.slot,
            ));
            try emitSlotRead(
                allocator,
                machine,
                receiver_value,
                object_scratch,
                guard_scratch,
            );
        },
        .prototype_data, .synthetic_accessor => {
            const expected_holder = holder_shape orelse return error.InvalidMetadata;
            try emitPrototypeGuards(
                allocator,
                machine,
                realm_register,
                cell_scratch,
                object_scratch,
                receiver_value,
                expected_holder,
                expected.revision,
                expected.mode,
                guard,
            );
            if (expected.mode == .synthetic_accessor) {
                try machine.emit(a64.ldrImm(
                    receiver_value,
                    cell_scratch,
                    layout.load_ic_cell.synthetic_value,
                ));
            } else {
                try machine.emit(a64.ldrImmW(
                    guard_scratch,
                    cell_scratch,
                    layout.load_ic_cell.slot,
                ));
                try emitSlotRead(
                    allocator,
                    machine,
                    object_scratch,
                    receiver_value,
                    guard_scratch,
                );
                try machine.emit(a64.movReg(receiver_value, object_scratch));
            }
        },
    }
    return receiver_value;
}

fn emitPrototypeGuards(
    allocator: std.mem.Allocator,
    machine: *Masm,
    realm_register: a64.Reg,
    cell: a64.Reg,
    receiver: a64.Reg,
    holder: a64.Reg,
    expected_holder_shape: *const Shape,
    expected_revision: u64,
    mode: Mode,
    guard: *Masm.Label,
) !void {
    try machine.emit(a64.ldrImm(holder, cell, layout.load_ic_cell.proto));
    try machine.emit(a64.cmpImm(holder, 0, false));
    try jumpToGuardIf(allocator, machine, .eq, guard);
    try machine.emit(a64.ldrImm(guard_scratch, receiver, layout.object.prototype));
    try machine.emit(a64.cmpReg(guard_scratch, holder));
    try jumpToGuardIf(allocator, machine, .ne, guard);

    try machine.emit(a64.ldrImm(
        guard_scratch,
        cell,
        layout.load_ic_cell.proto_shape,
    ));
    try machine.movImm64(object_scratch, @intFromPtr(expected_holder_shape));
    try machine.emit(a64.cmpReg(guard_scratch, object_scratch));
    try jumpToGuardIf(allocator, machine, .ne, guard);
    try machine.emit(a64.ldrImm(object_scratch, holder, layout.object.shape));
    try machine.emit(a64.cmpReg(object_scratch, guard_scratch));
    try jumpToGuardIf(allocator, machine, .ne, guard);

    try machine.emit(a64.ldrImm(
        guard_scratch,
        cell,
        layout.load_ic_cell.proto_rev,
    ));
    try machine.movImm64(object_scratch, expected_revision);
    try machine.emit(a64.cmpReg(guard_scratch, object_scratch));
    try jumpToGuardIf(allocator, machine, .ne, guard);
    try emitRealmU64(machine, realm_register, object_scratch, layout.realm.proto_revision_counter);
    try machine.emit(a64.cmpReg(object_scratch, guard_scratch));
    try jumpToGuardIf(allocator, machine, .ne, guard);

    try machine.emit(a64.ldrbImm(guard_scratch, cell, layout.load_ic_cell.kind));
    const expected_kind: u8 = switch (mode) {
        .prototype_data => layout.load_ic_cell.kind_data,
        .synthetic_accessor => layout.load_ic_cell.kind_synthetic_accessor,
        .own_data => return error.InvalidMetadata,
    };
    try machine.emit(a64.cmpImm(guard_scratch, expected_kind, false));
    try jumpToGuardIf(allocator, machine, .ne, guard);
}

fn emitPlainObject(
    allocator: std.mem.Allocator,
    machine: *Masm,
    source: a64.Reg,
    destination: a64.Reg,
    guard: *Masm.Label,
) !void {
    try machine.movImm64(guard_scratch, layout.value_bits.tag_object_shifted);
    try machine.emit(a64.eorReg(guard_scratch, source, guard_scratch));
    try machine.emit(a64.lsrImm(cell_scratch, guard_scratch, 48));
    try jumpToGuardIfNonzero(allocator, machine, cell_scratch, guard);
    try machine.emit(a64.lslImm(cell_scratch, guard_scratch, 62));
    try machine.emit(a64.lsrImm(cell_scratch, cell_scratch, 62));
    try machine.emit(a64.cmpImm(
        cell_scratch,
        @intCast(layout.value_bits.kind_object),
        false,
    ));
    try jumpToGuardIf(allocator, machine, .ne, guard);
    try machine.emit(a64.lsrImm(destination, guard_scratch, 2));
    try machine.emit(a64.lslImm(destination, destination, 2));
}

fn emitSlotRead(
    allocator: std.mem.Allocator,
    machine: *Masm,
    destination: a64.Reg,
    object: a64.Reg,
    slot: a64.Reg,
) !void {
    if (destination == object or destination == slot or object == slot) {
        return error.InvalidRegister;
    }
    var overflow: Masm.Label = .{};
    defer overflow.deinit(allocator);
    var done: Masm.Label = .{};
    defer done.deinit(allocator);
    try machine.emit(a64.cmpImm(
        slot,
        @intCast(layout.object.inline_slot_cap),
        false,
    ));
    try machine.jumpCond(.cs, &overflow);
    try machine.emit(a64.lslImm(destination, slot, 3));
    try machine.emit(a64.addReg(destination, destination, object));
    try machine.emit(a64.ldrImm(destination, destination, layout.object.inline_slots));
    try machine.jump(&done);
    machine.bind(&overflow);
    try machine.emit(a64.ldrImm(destination, object, layout.object.overflow_items_ptr));
    try machine.emit(a64.subImm(
        slot,
        slot,
        @intCast(layout.object.inline_slot_cap),
        false,
    ));
    try machine.emit(a64.lslImm(slot, slot, 3));
    try machine.emit(a64.addReg(destination, destination, slot));
    try machine.emit(a64.ldrImm(destination, destination, 0));
    machine.bind(&done);
}

fn emitRealmU64(
    machine: *Masm,
    realm_register: a64.Reg,
    destination: a64.Reg,
    offset: usize,
) !void {
    if (offset % 8 != 0) return error.InvalidLayout;
    if (offset <= 32_760) {
        try machine.emit(a64.ldrImm(destination, realm_register, @intCast(offset)));
        return;
    }
    const pages = offset >> 12;
    if (pages > std.math.maxInt(u12)) return error.InvalidLayout;
    try machine.emit(a64.addImm(destination, realm_register, @intCast(pages), true));
    try machine.emit(a64.ldrImm(destination, destination, @intCast(offset & 0xFFF)));
}

/// Conditional branches reach only +/-1 MiB. Keep the condition local and
/// use the +/-128 MiB unconditional form for the caller's cold guard exit.
fn jumpToGuardIf(
    allocator: std.mem.Allocator,
    machine: *Masm,
    condition: a64.Cond,
    guard: *Masm.Label,
) !void {
    var passed: Masm.Label = .{};
    defer passed.deinit(allocator);
    const inverse: a64.Cond = @enumFromInt(@intFromEnum(condition) ^ 1);
    try machine.jumpCond(inverse, &passed);
    try machine.jump(guard);
    machine.bind(&passed);
}

fn jumpToGuardIfNonzero(
    allocator: std.mem.Allocator,
    machine: *Masm,
    value: a64.Reg,
    guard: *Masm.Label,
) !void {
    var zero: Masm.Label = .{};
    defer zero.deinit(allocator);
    try machine.jumpCbz(value, &zero);
    try machine.jump(guard);
    machine.bind(&zero);
}
