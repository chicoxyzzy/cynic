//! Initial AArch64 machine-frame emission for Ohaimark.
//!
//! This checkpoint emits only the verified prologue and epilogue. It preserves
//! every callee-saved register claimed by the lowering convention, pins the
//! entry ABI, reserves the aligned spill area, and initializes all tagged
//! slots before optimized code can reach a safepoint.

const std = @import("std");

const a64 = @import("../jit/asm_aarch64.zig");
const Masm = @import("../jit/masm.zig").Masm;
const Value = @import("../value.zig").Value;
const lowering = @import("lowering_aarch64.zig");

const max_stack_adjust: u32 = 4_080;

pub fn emitPrologue(machine: *Masm, frame: lowering.FrameLayout) !void {
    try frame.verify();
    const code_start = machine.code.items.len;
    errdefer machine.code.shrinkRetainingCapacity(code_start);

    try machine.emit(a64.stpPreIdxSp(.fp, .lr, -16));
    try machine.emit(a64.addRegSp(.fp, 0));
    try machine.emit(a64.stpPreIdxSp(.x19, .x20, -16));
    try machine.emit(a64.stpPreIdxSp(.x21, .x22, -16));
    try machine.emit(a64.stpPreIdxSp(.x23, .x24, -16));
    try machine.emit(a64.stpPreIdxSp(.x25, .x26, -16));
    try machine.emit(a64.stpPreIdxSp(.x27, .x28, -16));
    try adjustStack(machine, frame.spill_bytes, .reserve);
    try machine.emit(a64.addRegSp(lowering.spill_base_register, 0));
    try machine.emit(a64.movReg(lowering.realm_register, .x0));
    try machine.emit(a64.movReg(lowering.lantern_frame_register, .x1));
    try machine.emit(a64.movReg(lowering.lantern_registers_register, .x2));

    if (frame.tagged_slot_count != 0) {
        try machine.movImm64(lowering.transfer_scratch, Value.undefined_.bits);
        for (0..frame.tagged_slot_count) |slot| {
            const byte_offset: u15 = @intCast(try frame.taggedByteOffset(@intCast(slot)));
            try machine.emit(a64.strImm(
                lowering.transfer_scratch,
                lowering.spill_base_register,
                byte_offset,
            ));
        }
    }
}

pub fn emitEpilogue(machine: *Masm, frame: lowering.FrameLayout) !void {
    try frame.verify();
    const code_start = machine.code.items.len;
    errdefer machine.code.shrinkRetainingCapacity(code_start);

    try adjustStack(machine, frame.spill_bytes, .release);
    try machine.emit(a64.ldpPostIdxSp(.x27, .x28, 16));
    try machine.emit(a64.ldpPostIdxSp(.x25, .x26, 16));
    try machine.emit(a64.ldpPostIdxSp(.x23, .x24, 16));
    try machine.emit(a64.ldpPostIdxSp(.x21, .x22, 16));
    try machine.emit(a64.ldpPostIdxSp(.x19, .x20, 16));
    try machine.emit(a64.ldpPostIdxSp(.fp, .lr, 16));
    try machine.emit(a64.ret());
}

const StackAdjustment = enum {
    reserve,
    release,
};

fn adjustStack(machine: *Masm, byte_count: u32, direction: StackAdjustment) !void {
    if (byte_count % 16 != 0) return error.InvalidLowering;
    var remaining = byte_count;
    while (remaining != 0) {
        const chunk: u12 = @intCast(@min(remaining, max_stack_adjust));
        try machine.emit(switch (direction) {
            .reserve => a64.subSpImm(chunk),
            .release => a64.addSpImm(chunk),
        });
        remaining -= chunk;
    }
}

comptime {
    std.debug.assert(lowering.callee_save_bytes == 6 * 16);
}
