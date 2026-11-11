//! Native 128-bit values. Lane interpretation belongs to operations, not homes.
const builtin = @import("builtin");
const ir = @import("ir.zig");
const scratch = @import("scratch.zig");
const arm = @import("../asm_aarch64.zig");
const x86_simd = @import("../simd_x86_64.zig");
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
        try constantX86(m, .xmm0, .xmm1, low, high);
    } else {
        try m.movImm64(.x2, low);
        try m.emit(arm.insDFromX(.x0, 0, .x2));
        try m.movImm64(.x2, high);
        try m.emit(arm.insDFromX(.x0, 1, .x2));
    }
}

pub fn emit(m: *Machine, node: ir.Node) !void {
    if (comptime is_x86) switch (node.op) {
        .vector_extend_s, .vector_extend_u => try x86_simd.extend(m, @intCast(node.vector_lane.?.bytes()), node.op == .vector_extend_s, node.immediate == 1),
        .vector_narrow_s, .vector_narrow_u => try x86_simd.narrow(m, @intCast(node.vector_lane.?.bytes()), node.op == .vector_narrow_s),
        .vector_pairwise_add_s, .vector_pairwise_add_u => try x86_simd.pairwiseAdd(m, @intCast(node.vector_lane.?.bytes()), node.op == .vector_pairwise_add_s),
        .vector_splat => try splatX86(m, .xmm0, node.vector_lane.?.bytes()),
        .vector_extract => try extractX86(m, .xmm0, node.vector_lane.?.bytes(), @intCast(node.immediate)),
        .vector_replace => try replaceX86(m, node.vector_lane.?.bytes(), @intCast(node.immediate)),
        .vector_shuffle => try shuffleX86(m, node.immediate, node.immediate_hi),
        .vector_swizzle => try swizzleX86(m),
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
        .vector_extend_s, .vector_extend_u => try m.emit(arm.extendIntegerV128(.x0, .x0, try armSmallSize(node.vector_lane.?), node.op == .vector_extend_s, node.immediate == 1)),
        .vector_narrow_s, .vector_narrow_u => {
            const size = try armSmallSize(node.vector_lane.?);
            try m.emit(arm.narrowIntegerV128(.x0, .x0, size, node.op == .vector_narrow_s, false));
            try m.emit(arm.narrowIntegerV128(.x0, .x1, size, node.op == .vector_narrow_s, true));
        },
        .vector_pairwise_add_s, .vector_pairwise_add_u => try m.emit(arm.pairwiseAddLongV128(.x0, .x0, try armSmallSize(node.vector_lane.?), node.op == .vector_pairwise_add_s)),
        .vector_splat => try m.emit(arm.duplicateIntegerV128(.x0, .x2, armSize(node.vector_lane.?))),
        .vector_extract => try m.emit(arm.extractUnsignedIntegerLane(.x2, .x0, armSize(node.vector_lane.?), @intCast(node.immediate))),
        .vector_replace => try m.emit(arm.insertIntegerLane(.x0, .x3, armSize(node.vector_lane.?), @intCast(node.immediate))),
        .vector_shuffle => {
            try m.movImm64(.x2, node.immediate);
            try m.emit(arm.insDFromX(.x2, 0, .x2));
            try m.movImm64(.x2, node.immediate_hi);
            try m.emit(arm.insDFromX(.x2, 1, .x2));
            try m.emit(arm.tableLookupV128(.x0, .x0, .x2, true));
        },
        .vector_swizzle => try m.emit(arm.tableLookupV128(.x0, .x0, .x1, false)),
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

fn armSmallSize(lane: ir.VectorLane) !arm.VectorLaneSize {
    return switch (lane) {
        .i8x16 => .byte,
        .i16x8 => .half,
        .i32x4 => .word,
        else => error.InvalidGraph,
    };
}

fn armSize(lane: ir.VectorLane) arm.VectorIntegerSize {
    return switch (lane) {
        .i8x16 => .byte,
        .i16x8 => .half,
        .i32x4, .f32x4 => .word,
        .i64x2, .f64x2 => .double,
    };
}

fn constantX86(m: *Machine, destination: Reg, temp: Reg, low: u64, high: u64) !void {
    try m.movImm64(.rax, low);
    try m.movQXmmFromReg(destination, .rax);
    try m.movImm64(.rax, high);
    try m.movQXmmFromReg(temp, .rax);
    try m.unpackLowPackedInteger(destination, temp, .word);
    try m.shufflePackedI32(destination, destination, 0xd8);
}

/// Scalar bits arrive in RAX, including floats. Only SSE2 is required.
fn splatX86(m: *Machine, destination: Reg, width: usize) !void {
    try m.movQXmmFromReg(destination, .rax);
    if (width == 1) try m.unpackLowPackedInteger(destination, destination, .byte);
    if (width <= 2) try m.unpackLowPackedInteger(destination, destination, .half);
    try m.shufflePackedI32(destination, destination, if (width == 8) 0x44 else 0);
}

/// XMM3 and R11 are scratch; allocated GP homes (RCX/RDX/R8/R9) stay intact.
fn extractX86(m: *Machine, source: Reg, width: usize, lane: usize) !void {
    if (width == 8) {
        try m.shufflePackedI32(.xmm3, source, if (lane == 0) 0x44 else 0xee);
        try m.movQRegFromXmm(.rax, .xmm3);
    } else {
        const offset = lane * width;
        try m.shufflePackedI32(.xmm3, source, @intCast((offset / 4) * 0x55));
        try m.movDRegFromXmm(.rax, .xmm3);
        if (offset % 4 != 0) try m.shrImm8(.rax, @intCast((offset % 4) * 8));
        if (width < 4) {
            try m.movImm32(.r11, if (width == 1) 255 else 65535);
            try m.andReg64(.rax, .r11);
        }
    }
}

fn replaceX86(m: *Machine, width: usize, lane: usize) !void {
    const bits: u7 = @intCast(width * 8);
    const scalar_mask: u64 = @intCast((@as(u128, 1) << bits) - 1);
    const mask = ~(@as(u128, scalar_mask) << @as(u7, @intCast(lane * width * 8)));
    try constantX86(m, .xmm1, .xmm2, @truncate(mask), @truncate(mask >> 64));
    try m.andPacked128(.xmm0, .xmm1);
    try m.movImm64(.r11, scalar_mask);
    try m.andReg64(.r10, .r11);
    const offset = lane * width;
    if (offset % 8 != 0) try m.shlImm8(.r10, @intCast((offset % 8) * 8));
    try m.movQXmmFromReg(.xmm1, .r10);
    if (offset >= 8) try m.shufflePackedI32(.xmm1, .xmm1, 0x4e);
    try m.orPacked128(.xmm0, .xmm1);
}

fn shuffleX86(m: *Machine, low: u64, high: u64) !void {
    // Constant selectors permit fixed native extracts without a stack table,
    // bounds branches, or an SSSE3-only PSHUFB requirement.
    for ([_]u64{ low, high }, 0..) |word, half| {
        try m.movImm32(.r10, 0);
        for (0..8) |byte| {
            const selector: u8 = @truncate(word >> @as(u6, @intCast(byte * 8)));
            try extractX86(m, if (selector < 16) .xmm0 else .xmm1, 1, selector % 16);
            if (byte != 0) try m.shlImm8(.rax, @intCast(byte * 8));
            try m.orReg64(.r10, .rax);
        }
        try m.movQXmmFromReg(if (half == 0) .xmm2 else .xmm3, .r10);
    }
    try m.unpackLowPackedInteger(.xmm2, .xmm3, .word);
    try m.shufflePackedI32(.xmm0, .xmm2, 0xd8);
}

fn swizzleX86(m: *Machine) !void {
    // SSE2 equality masks preserve strict out-of-range-zero semantics for all
    // 256 index bytes. XMM8 is scratch, outside the allocated XMM4-XMM7 bank.
    try m.xorPacked128(.xmm2, .xmm2);
    for (0..16) |index| {
        try extractX86(m, .xmm0, 1, index);
        try splatX86(m, .xmm8, 1);
        try m.movImm32(.rax, @intCast(index));
        try splatX86(m, .xmm3, 1);
        try m.compareEqualPacked(.xmm3, .xmm1, .byte);
        try m.andPacked128(.xmm3, .xmm8);
        try m.orPacked128(.xmm2, .xmm3);
    }
    try m.movVector128(.xmm0, .xmm2);
}
