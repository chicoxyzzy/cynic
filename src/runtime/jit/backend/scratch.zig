//! Invocation scratch addressing. Packed vectors need only eight-byte alignment.
//! AArch64 uses x17 for offsets outside an instruction's immediate range.
const builtin = @import("builtin");
const arm = @import("../asm_aarch64.zig");
const arm_masm = @import("../masm.zig");
const x86 = @import("../asm_x86_64.zig");
const is_x86 = builtin.cpu.arch == .x86_64;
pub const Machine = if (is_x86) x86.Masm else arm_masm.Masm;
pub const Reg = if (is_x86) x86.Reg else arm.Reg;
pub const VectorReg = if (is_x86) x86.Xmm else arm.Reg;

pub fn load(m: *Machine, destination: Reg, slot: usize) !void {
    if (comptime is_x86) {
        try m.load64Disp32(destination, .rdi, @intCast(slot * 8));
    } else if (slot < 4096) {
        try m.emit(arm.ldrImm(destination, .x0, @intCast(slot * 8)));
    } else {
        try m.movImm64(.x17, slot * 8);
        try m.emit(arm.ldrReg(destination, .x0, .x17));
    }
}

pub fn store(m: *Machine, source: Reg, slot: usize) !void {
    if (comptime is_x86) {
        try m.store64Disp32(.rdi, @intCast(slot * 8), source);
    } else if (slot < 4096) {
        try m.emit(arm.strImm(source, .x0, @intCast(slot * 8)));
    } else {
        try m.movImm64(.x17, slot * 8);
        try m.emit(arm.strReg(source, .x0, .x17));
    }
}

pub fn loadVector(m: *Machine, destination: VectorReg, slot: usize) !void {
    if (comptime is_x86) {
        try m.loadVector128(destination, .rdi, @intCast(slot * 8));
    } else if (slot % 2 == 0 and slot < 8192) {
        try m.emit(arm.ldrQImm(destination, .x0, @intCast(slot * 8)));
    } else {
        try m.movImm64(.x17, slot * 8);
        try m.emit(arm.addReg(.x17, .x0, .x17));
        try m.emit(arm.ldrQImm(destination, .x17, 0));
    }
}

pub fn storeVector(m: *Machine, source: VectorReg, slot: usize) !void {
    if (comptime is_x86) {
        try m.storeVector128(.rdi, @intCast(slot * 8), source);
    } else if (slot % 2 == 0 and slot < 8192) {
        try m.emit(arm.strQImm(source, .x0, @intCast(slot * 8)));
    } else {
        try m.movImm64(.x17, slot * 8);
        try m.emit(arm.addReg(.x17, .x0, .x17));
        try m.emit(arm.strQImm(source, .x17, 0));
    }
}
