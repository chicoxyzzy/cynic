//! AArch64 emission for Ohaimark's monomorphic computed own-data accesses.
//!
//! The existing `ComputedICCell` only represents a flat-string, own-data
//! hit. This emitter deliberately stays inside that contract: it verifies the
//! live cell against the compiler snapshot, proves the dynamic key is the
//! same flat string, and otherwise takes the caller's deopt exit before
//! `ToPropertyKey` or any user-observable lookup can occur.

const std = @import("std");

const chunk_mod = @import("../../bytecode/chunk.zig");
const ComputedICCell = chunk_mod.ComputedICCell;
const a64 = @import("../jit/asm_aarch64.zig");
const layout = @import("../jit/layout.zig");
const Masm = @import("../jit/masm.zig").Masm;
const property_codegen = @import("property_codegen_aarch64.zig");
const Shape = @import("../shape.zig").Shape;

const key_value: a64.Reg = .x12;
const object: a64.Reg = .x13;
const cell_scratch: a64.Reg = .x14;
const guard_scratch: a64.Reg = .x15;
const expected_shape_scratch: a64.Reg = .x9;
const slot_scratch: a64.Reg = .x10;
const key_string_scratch: a64.Reg = .x11;

pub const Expected = struct {
    receiver_shape: *Shape,
    slot: u32,
    key: []const u8,
};

/// `key_value` initially contains the tagged dynamic key and contains the
/// tagged property result on success. `object` must already be a decoded plain
/// object from `property_codegen.emitPlainObject`; x9-x11 and x14-x15 are
/// clobbered. Every failed guard branches without changing Lantern state.
pub fn emit(
    allocator: std.mem.Allocator,
    machine: *Masm,
    cell: *const ComputedICCell,
    expected: Expected,
    guard: *Masm.Label,
) !a64.Reg {
    const slot = try emitGuards(allocator, machine, cell, expected, guard);
    try property_codegen.emitSlotRead(
        allocator,
        machine,
        key_value,
        object,
        slot,
    );
    return key_value;
}

/// Emit the live-cell and flat-key guards shared by computed own-data loads
/// and stores. On success, `object` remains the decoded receiver and the
/// returned x10 register holds the verified logical slot. `key_value` remains
/// the tagged runtime key so a store can replace it with its assignment value
/// only after every speculative guard has succeeded.
pub fn emitGuards(
    allocator: std.mem.Allocator,
    machine: *Masm,
    cell: *const ComputedICCell,
    expected: Expected,
    guard: *Masm.Label,
) !a64.Reg {
    if (expected.key.len == 0 or expected.key.len > chunk_mod.computed_key_cap or
        expected.slot >= expected.receiver_shape.property_count)
    {
        return error.InvalidMetadata;
    }

    try machine.movImm64(cell_scratch, @intFromPtr(cell));

    // Both the copied fact and the mutable cell must still identify the same
    // own-data shape/slot. In particular, a later `obj["y"]` refill must not
    // leave code compiled for `obj["x"]` reading a stale slot.
    try machine.emit(a64.ldrImm(
        guard_scratch,
        cell_scratch,
        layout.computed_ic_cell.shape,
    ));
    try machine.movImm64(expected_shape_scratch, @intFromPtr(expected.receiver_shape));
    try machine.emit(a64.cmpReg(guard_scratch, expected_shape_scratch));
    try jumpToGuardIf(allocator, machine, .ne, guard);
    try machine.emit(a64.ldrImm(
        key_string_scratch,
        object,
        layout.object.shape,
    ));
    try machine.emit(a64.cmpReg(key_string_scratch, guard_scratch));
    try jumpToGuardIf(allocator, machine, .ne, guard);
    try machine.emit(a64.ldrImmW(
        slot_scratch,
        cell_scratch,
        layout.computed_ic_cell.slot,
    ));
    try machine.movImm64(guard_scratch, expected.slot);
    try machine.emit(a64.cmpReg(slot_scratch, guard_scratch));
    try jumpToGuardIf(allocator, machine, .ne, guard);
    try machine.emit(a64.ldrbImm(
        guard_scratch,
        cell_scratch,
        layout.computed_ic_cell.key_len,
    ));
    try machine.emit(a64.cmpImm(guard_scratch, @intCast(expected.key.len), false));
    try jumpToGuardIf(allocator, machine, .ne, guard);

    // `Value` stores the tag in the high 16 bits and the pointer in the low
    // 48. Only a flat JSString can make §7.1.19 an identity without calling
    // Lantern; ropes and every non-string value deopt before user code runs.
    try machine.emit(a64.lsrImm(guard_scratch, key_value, 48));
    try machine.movImm64(key_string_scratch, layout.value_bits.tag_string);
    try machine.emit(a64.cmpReg(guard_scratch, key_string_scratch));
    try jumpToGuardIf(allocator, machine, .ne, guard);
    try machine.emit(a64.lslImm(key_string_scratch, key_value, 16));
    try machine.emit(a64.lsrImm(key_string_scratch, key_string_scratch, 16));
    try jumpToGuardIfZero(allocator, machine, key_string_scratch, guard);
    try machine.emit(a64.ldrImmW(
        guard_scratch,
        key_string_scratch,
        layout.string.byte_len,
    ));
    try machine.emit(a64.cmpImm(guard_scratch, @intCast(expected.key.len), false));
    try jumpToGuardIf(allocator, machine, .ne, guard);
    try machine.emit(a64.ldrbImm(
        guard_scratch,
        key_string_scratch,
        layout.string.depth,
    ));
    try jumpToGuardIfNonzero(allocator, machine, guard_scratch, guard);
    try machine.emit(a64.ldrbImm(
        guard_scratch,
        key_string_scratch,
        layout.string.depth + 1,
    ));
    try jumpToGuardIfNonzero(allocator, machine, guard_scratch, guard);
    try machine.emit(a64.ldrImm(
        key_string_scratch,
        key_string_scratch,
        layout.string.flat_bytes_ptr,
    ));

    for (expected.key, 0..) |byte, index| {
        const offset: u12 = @intCast(index);
        try machine.emit(a64.ldrbImm(
            guard_scratch,
            cell_scratch,
            layout.computed_ic_cell.key_buf + offset,
        ));
        try machine.emit(a64.cmpImm(guard_scratch, @intCast(byte), false));
        try jumpToGuardIf(allocator, machine, .ne, guard);
        try machine.emit(a64.ldrbImm(guard_scratch, key_string_scratch, offset));
        try machine.emit(a64.cmpImm(guard_scratch, @intCast(byte), false));
        try jumpToGuardIf(allocator, machine, .ne, guard);
    }

    return slot_scratch;
}

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
    try machine.bind(&passed);
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
    try machine.bind(&zero);
}

fn jumpToGuardIfZero(
    allocator: std.mem.Allocator,
    machine: *Masm,
    value: a64.Reg,
    guard: *Masm.Label,
) !void {
    var nonzero: Masm.Label = .{};
    defer nonzero.deinit(allocator);
    try machine.jumpCbnz(value, &nonzero);
    try machine.jump(guard);
    try machine.bind(&nonzero);
}
