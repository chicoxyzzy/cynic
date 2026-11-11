//! Floating vector semantics, including native SSE2 lane-wise rounding and
//! conversions where the baseline ISA has no corresponding packed operation.
const builtin = @import("builtin");
const ir = @import("ir.zig");
const scratch = @import("scratch.zig");
const scalar_float = @import("float.zig");
const scalar_conversion = @import("conversion.zig");
const arm = @import("../asm_aarch64.zig");
const x86 = @import("../simd_float_x86_64.zig");

pub fn emit(m: *scratch.Machine, node: ir.Node) !void {
    const op = node.op;
    const wide = node.vector_lane == .f64x2;
    if (comptime builtin.cpu.arch == .x86_64) switch (op) {
        .vector_fabs, .vector_fneg, .vector_fsqrt, .vector_fsub, .vector_fmul, .vector_fdiv => try x86.arithmetic(m, wide, switch (op) {
            .vector_fabs => .abs,
            .vector_fneg => .neg,
            .vector_fsqrt => .sqrt,
            .vector_fsub => .sub,
            .vector_fmul => .mul,
            .vector_fdiv => .div,
            else => return error.InvalidGraph,
        }),
        .vector_fmin, .vector_fmax, .vector_fpmin, .vector_fpmax => try x86.minMax(m, wide, op == .vector_fmax or op == .vector_fpmax, op == .vector_fpmin or op == .vector_fpmax),
        else => try scalarLanesX86(m, node),
    } else switch (op) {
        .vector_fabs, .vector_fneg, .vector_fsqrt => try m.emit(arm.unaryFloatV128(.x0, .x0, wide, switch (op) {
            .vector_fabs => .abs,
            .vector_fneg => .neg,
            .vector_fsqrt => .sqrt,
            else => return error.InvalidGraph,
        })),
        .vector_fsub, .vector_fmul, .vector_fdiv => try m.emit(arm.arithmeticFloatV128(.x0, .x0, .x1, wide, switch (op) {
            .vector_fsub => .sub,
            .vector_fmul => .mul,
            .vector_fdiv => .div,
            else => return error.InvalidGraph,
        })),
        .vector_fmin, .vector_fmax => try m.emit(arm.minMaxFloatV128(.x0, .x0, .x1, wide, op == .vector_fmax)),
        .vector_fpmin, .vector_fpmax => {
            const maximum = op == .vector_fpmax;
            try m.emit(arm.compareFloatV128(.x2, if (maximum) .x1 else .x0, if (maximum) .x0 else .x1, wide, .gt));
            try m.emit(arm.bitSelectV128(.x2, .x1, .x0));
            try m.emit(arm.orV16b(.x0, .x2, .x2));
        },
        .vector_fceil, .vector_ffloor, .vector_ftrunc, .vector_fnearest => try m.emit(arm.roundFloatV128(.x0, .x0, wide, switch (op) {
            .vector_fceil => .ceil,
            .vector_ffloor => .floor,
            .vector_ftrunc => .trunc,
            .vector_fnearest => .nearest,
            else => return error.InvalidGraph,
        })),
        .vector_promote_f32, .vector_demote_f64 => try m.emit(arm.convertPrecisionV128(.x0, .x0, op == .vector_promote_f32)),
        .vector_convert_s, .vector_convert_u => {
            if (wide) try m.emit(arm.widenLowV128(.x0, .x0, .word, op == .vector_convert_s));
            try m.emit(arm.convertIntegerV128(.x0, .x0, wide, op == .vector_convert_s));
        },
        .vector_trunc_sat_s, .vector_trunc_sat_u => {
            try m.emit(arm.truncSatFloatV128(.x0, .x0, wide, op == .vector_trunc_sat_s));
            if (wide) try m.emit(if (op == .vector_trunc_sat_s) arm.narrowIntegerV128(.x0, .x0, .word, true, false) else arm.narrowUnsignedV128(.x0, .x0, .word));
        },
        else => return error.InvalidGraph,
    }
}

fn scalarLanesX86(m: *scratch.Machine, node: ir.Node) !void {
    const scalar: ir.Op = switch (node.op) {
        .vector_fceil => .fceil,
        .vector_ffloor => .ffloor,
        .vector_ftrunc => .ftrunc,
        .vector_fnearest => .fnearest,
        .vector_convert_s => .convert_s,
        .vector_convert_u => .convert_u,
        .vector_trunc_sat_s => .trunc_sat_s,
        .vector_trunc_sat_u => .trunc_sat_u,
        .vector_promote_f32 => .promote_f32,
        .vector_demote_f64 => .demote_f64,
        else => return error.InvalidGraph,
    };
    const lane_type = node.vector_lane.?.scalarType();
    const converting = scalar == .convert_s or scalar == .convert_u;
    const truncating = scalar == .trunc_sat_s or scalar == .trunc_sat_u;
    const input: ir.Type = if (converting) .i32 else lane_type;
    const output: ir.Type = if (truncating) .i32 else if (scalar == .promote_f32) .f64 else if (scalar == .demote_f64) .f32 else lane_type;
    const input_wide = input == .f64;
    const output_wide = output == .f64;
    const count: usize = if (input_wide or output_wide) 2 else 4;
    // Scalar helpers own XMM0/XMM1 and RAX/R10/R11. Keep the vector input
    // and assembled result outside both their scratch and allocated homes.
    try m.movVector128(.xmm8, .xmm0);
    try m.xorPacked128(.xmm9, .xmm9);
    for (0..count) |lane| {
        try m.shufflePackedI32(.xmm2, .xmm8, if (input_wide) (if (lane == 0) @as(u8, 0x44) else 0xee) else @intCast(lane * 0x55));
        if (input_wide) try m.movQRegFromXmm(.rax, .xmm2) else try m.movDRegFromXmm(.rax, .xmm2);
        if (converting or truncating) {
            var unused: scratch.Machine.Label = .{};
            defer unused.deinit(m.gpa);
            try scalar_conversion.emit(m, scalar, input, output, &unused, &unused);
            try m.bind(&unused);
        } else try scalar_float.emit(m, scalar, input);
        if (output_wide) {
            try m.movQXmmFromReg(.xmm2, .rax);
            if (lane == 1) try m.shufflePackedI32(.xmm2, .xmm2, 0x4e);
        } else {
            try m.movDXmmFromReg(.xmm2, .rax);
            try m.shufflePackedI32(.xmm2, .xmm2, @as(u8, 0x55) & ~(@as(u8, 3) << @as(u3, @intCast(2 * lane))));
        }
        try m.orPacked128(.xmm9, .xmm2);
    }
    try m.movVector128(.xmm0, .xmm9);
}
