//! Native 128-bit values. Lane interpretation belongs to operations, not homes.
const builtin = @import("builtin");
const ir = @import("ir.zig");
const scratch = @import("scratch.zig");
const arm = @import("../asm_aarch64.zig");
const is_x86 = builtin.cpu.arch == .x86_64;
const Machine = scratch.Machine;
const Reg = scratch.VectorReg;

pub fn temporary(rhs: bool) Reg {
    return if (comptime is_x86) (if (rhs) .xmm1 else .xmm0) else (if (rhs) .x1 else .x0);
}

pub fn allocated(index: u8) Reg {
    // Scalar FP helpers use v16-v17/xmm0-xmm1. This bank is caller-saved
    // on both supported native ABIs and explicitly preserved around calls.
    return if (comptime is_x86)
        ([_]Reg{ .xmm4, .xmm5, .xmm6, .xmm7 })[index]
    else
        ([_]Reg{ .x4, .x5, .x6, .x7 })[index];
}

pub fn move(m: *Machine, destination: Reg, source: Reg) !void {
    if (comptime is_x86) try m.movVector128(destination, source) else try m.emit(arm.orV16b(destination, source, source));
}

pub fn constant(m: *Machine, low: u64, high: u64) !void {
    if (comptime is_x86) {
        try m.movImm64(.rax, low);
        try m.movQXmmFromReg(.xmm0, .rax);
        try m.movImm64(.rax, high);
        try m.movQXmmFromReg(.xmm1, .rax);
        try m.unpackLowPackedInteger(.xmm0, .xmm1, .word);
        try m.shufflePackedI32(.xmm0, .xmm0, 0xd8);
    } else {
        try m.movImm64(.x2, low);
        try m.emit(arm.insDFromX(.x0, 0, .x2));
        try m.movImm64(.x2, high);
        try m.emit(arm.insDFromX(.x0, 1, .x2));
    }
}

pub fn emit(m: *Machine, node: ir.Node) !void {
    if (comptime is_x86) switch (node.op) {
        .bit_and => try m.andPacked128(.xmm0, .xmm1),
        .bit_or => try m.orPacked128(.xmm0, .xmm1),
        .bit_xor => try m.xorPacked128(.xmm0, .xmm1),
        .vector_add => switch (node.vector_lane.?) {
            .i8x16 => try m.addPackedInteger(.xmm0, .xmm1, .byte),
            .i16x8 => try m.addPackedInteger(.xmm0, .xmm1, .half),
            .i32x4 => try m.addPackedInteger(.xmm0, .xmm1, .word),
            .i64x2 => try m.addPackedInteger(.xmm0, .xmm1, .double),
            .f32x4, .f64x2 => try m.arithmeticPackedFloat128(.xmm0, .xmm1, node.vector_lane.? == .f64x2, .add),
        },
        else => return error.InvalidGraph,
    } else switch (node.op) {
        .bit_and => try m.emit(arm.andV16b(.x0, .x0, .x1)),
        .bit_or => try m.emit(arm.orV16b(.x0, .x0, .x1)),
        .bit_xor => try m.emit(arm.xorV16b(.x0, .x0, .x1)),
        .vector_add => switch (node.vector_lane.?) {
            .i8x16 => try m.emit(arm.addSubtractV128(.x0, .x0, .x1, .byte, false)),
            .i16x8 => try m.emit(arm.addSubtractV128(.x0, .x0, .x1, .half, false)),
            .i32x4 => try m.emit(arm.addSubtractV128(.x0, .x0, .x1, .word, false)),
            .i64x2 => try m.emit(arm.addSubtractV128(.x0, .x0, .x1, .double, false)),
            .f32x4, .f64x2 => try m.emit(arm.arithmeticFloatV128(.x0, .x0, .x1, node.vector_lane.? == .f64x2, .add)),
        },
        else => return error.InvalidGraph,
    }
}
