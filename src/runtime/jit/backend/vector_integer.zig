//! Lane-wise integer operations. No frontend decoding or runtime helpers.
const builtin = @import("builtin");
const ir = @import("ir.zig");
const scratch = @import("scratch.zig");
const arm = @import("../asm_aarch64.zig");
const x86 = @import("../simd_integer_x86_64.zig");

pub fn emit(m: *scratch.Machine, node: ir.Node) !void {
    const width: u4 = @intCast(node.vector_lane.?.bytes());
    const subtract = node.op == .vector_sub or node.op == .vector_sub_sat_s or node.op == .vector_sub_sat_u;
    const saturating = node.op == .vector_add_sat_s or node.op == .vector_add_sat_u or node.op == .vector_sub_sat_s or node.op == .vector_sub_sat_u;
    const signed = node.op == .vector_add_sat_s or node.op == .vector_sub_sat_s or node.op == .vector_min_s or node.op == .vector_max_s;
    const maximum = node.op == .vector_max_s or node.op == .vector_max_u;
    if (comptime builtin.cpu.arch == .x86_64) switch (node.op) {
        .vector_sub, .vector_mul, .vector_add_sat_s, .vector_add_sat_u, .vector_sub_sat_s, .vector_sub_sat_u => try x86.binary(m, width, if (node.op == .vector_mul) .mul else if (subtract) .sub else .add, saturating, signed),
        .vector_abs, .vector_neg => try x86.unary(m, width, node.op == .vector_neg),
        .vector_popcnt => try x86.popcount(m),
        .vector_min_s, .vector_min_u, .vector_max_s, .vector_max_u => try x86.minMax(m, width, signed, maximum),
        .vector_avgr_u => try m.roundingAverageUnsigned128(.xmm0, .xmm1, width == 2),
        .vector_shl, .vector_shr_s, .vector_shr_u => try x86.shift(m, width, if (node.op == .vector_shl) .shl else if (node.op == .vector_shr_s) .shr_s else .shr_u),
        else => return error.InvalidGraph,
    } else {
        const size: arm.VectorIntegerSize = switch (width) {
            1 => .byte,
            2 => .half,
            4 => .word,
            8 => .double,
            else => return error.InvalidGraph,
        };
        switch (node.op) {
            .vector_sub => try m.emit(arm.addSubtractV128(.x0, .x0, .x1, size, true)),
            .vector_add_sat_s, .vector_add_sat_u, .vector_sub_sat_s, .vector_sub_sat_u => try m.emit(arm.saturatingAddSubtractV128(.x0, .x0, .x1, size, signed, subtract)),
            .vector_mul => {
                if (width == 8) {
                    for (0..2) |half| {
                        try m.emit(arm.extractUnsignedIntegerLane(.x2, .x0, .double, @intCast(half)));
                        try m.emit(arm.extractUnsignedIntegerLane(.x3, .x1, .double, @intCast(half)));
                        try m.emit(arm.mul(.x2, .x2, .x3));
                        try m.emit(arm.insDFromX(.x0, @intCast(half), .x2));
                    }
                } else try m.emit(arm.multiplyV128(.x0, .x0, .x1, if (width == 2) .half else .word));
            },
            .vector_abs, .vector_neg => try m.emit(arm.integerUnaryV128(.x0, .x0, size, node.op == .vector_neg)),
            .vector_popcnt => try m.emit(arm.populationCountV128(.x0, .x0)),
            .vector_min_s, .vector_min_u, .vector_max_s, .vector_max_u => try m.emit(arm.minMaxV128(.x0, .x0, .x1, if (width == 1) .byte else if (width == 2) .half else .word, signed, maximum)),
            .vector_avgr_u => try m.emit(arm.roundingAverageUnsignedV128(.x0, .x0, .x1, width == 2)),
            .vector_shl, .vector_shr_s, .vector_shr_u => {
                try m.movImm64(.x2, @as(u8, width) * 8 - 1);
                try m.emit(arm.andReg(.x3, .x3, .x2));
                if (node.op != .vector_shl) {
                    try m.movImm64(.x2, 0);
                    try m.emit(arm.subReg(.x3, .x2, .x3));
                }
                try m.emit(arm.duplicateIntegerV128(.x1, .x3, size));
                try m.emit(arm.shiftIntegerV128(.x0, .x0, .x1, size, node.op == .vector_shr_s));
            },
            else => return error.InvalidGraph,
        }
    }
}
