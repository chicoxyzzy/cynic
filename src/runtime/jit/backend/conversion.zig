//! Scalar numeric conversions, distinct from reinterpretation and JS ToInt32.
//! Inputs/results use GP scratch words; only caller-saved FP temporaries are
//! touched. Checked conversions branch to frontend-owned ordered trap exits.
const builtin = @import("builtin");
const ir = @import("ir.zig");
const arm = @import("../asm_aarch64.zig");
const arm_masm = @import("../masm.zig");
const x86 = @import("../asm_x86_64.zig");
const is_x86 = builtin.cpu.arch == .x86_64;
const Machine = if (is_x86) x86.Masm else arm_masm.Masm;

pub fn emit(m: *Machine, op: ir.Op, input: ir.Type, output: ir.Type, invalid: *Machine.Label, overflow: *Machine.Label) !void {
    if (op == .convert_s or op == .convert_u) return fromInteger(m, op == .convert_s, input, output);
    const signed = op == .trunc_s or op == .trunc_sat_s;
    const saturating = op == .trunc_sat_s or op == .trunc_sat_u;
    const single = input == .f32;
    const wide = output == .i64;
    if (comptime is_x86) {
        if (single) try m.movDXmmFromReg(.xmm0, .rax) else try m.movQXmmFromReg(.xmm0, .rax);
    } else try m.emit(if (single) arm.fmovWtoS(.x16, .x2) else arm.fmovXtoD(.x16, .x2));

    // FCVTZ already implements saturating semantics, including NaN -> zero.
    if (saturating and !is_x86) return toInteger(m, signed, single, wide);
    var nan: Machine.Label = .{};
    defer nan.deinit(m.gpa);
    var low: Machine.Label = .{};
    defer low.deinit(m.gpa);
    var high: Machine.Label = .{};
    defer high.deinit(m.gpa);
    var done: Machine.Label = .{};
    defer done.deinit(m.gpa);

    if (comptime is_x86) {
        if (single) try m.ucomisFloat(.xmm0, .xmm0) else try m.ucomisDouble(.xmm0, .xmm0);
        try m.jumpCond(.parity, if (saturating) &nan else invalid);
    } else {
        try m.emit(if (single) arm.fcmpS(.x16, .x16) else arm.fcmpD(.x16, .x16));
        try m.jumpCond(.vs, invalid);
    }
    // Truncation accepts fractions just below MIN when representable. Only
    // f64 -> i32 can represent that open interval; other signed lower bounds
    // are inclusive MIN. Unsigned truncation accepts (-1, 0).
    const minimum: f64 = if (wide) -9223372036854775808.0 else -2147483648.0;
    const lower: f64 = if (saturating) (if (signed) minimum else 0) else if (!signed) -1 else if (!single and !wide) -2147483649.0 else minimum;
    const lower_inclusive = !saturating and signed and (single or wide);
    const upper: f64 = if (wide) (if (signed) 9223372036854775808.0 else 18446744073709551616.0) else (if (signed) 2147483648.0 else 4294967296.0);
    try compareBound(m, single, lower);
    if (comptime is_x86) {
        try m.jumpCond(if (lower_inclusive) .below else .below_or_equal, if (saturating) &low else overflow);
    } else try m.jumpCond(if (lower_inclusive) .mi else .ls, overflow);
    try compareBound(m, single, upper);
    if (comptime is_x86) {
        try m.jumpCond(.above_or_equal, if (saturating) &high else overflow);
    } else try m.jumpCond(.ge, overflow);
    try toInteger(m, signed, single, wide);
    if (comptime is_x86) if (saturating) {
        try m.jump(&done);
        try m.bind(&nan);
        try m.movImm64(.rax, 0);
        try m.jump(&done);
        try m.bind(&low);
        try m.movImm64(.rax, if (!signed) 0 else if (wide) 0x8000_0000_0000_0000 else 0x8000_0000);
        try m.jump(&done);
        try m.bind(&high);
        try m.movImm64(.rax, if (wide) (if (signed) @as(u64, 0x7fff_ffff_ffff_ffff) else 0xffff_ffff_ffff_ffff) else (if (signed) @as(u64, 0x7fff_ffff) else 0xffff_ffff));
        try m.bind(&done);
    };
}

fn compareBound(m: *Machine, single: bool, value: f64) !void {
    const bits: u64 = if (single) @as(u32, @bitCast(@as(f32, @floatCast(value)))) else @bitCast(value);
    if (comptime is_x86) {
        try m.movImm64(.r10, bits);
        if (single) {
            try m.movDXmmFromReg(.xmm1, .r10);
            try m.ucomisFloat(.xmm0, .xmm1);
        } else {
            try m.movQXmmFromReg(.xmm1, .r10);
            try m.ucomisDouble(.xmm0, .xmm1);
        }
    } else {
        try m.movImm64(.x16, bits);
        try m.emit(if (single) arm.fmovWtoS(.x17, .x16) else arm.fmovXtoD(.x17, .x16));
        try m.emit(if (single) arm.fcmpS(.x16, .x17) else arm.fcmpD(.x16, .x17));
    }
}

fn toInteger(m: *Machine, signed: bool, single: bool, wide: bool) !void {
    if (comptime !is_x86) {
        try m.emit(if (single)
            (if (wide) (if (signed) arm.fcvtzsXfromS(.x2, .x16) else arm.fcvtzuXfromS(.x2, .x16)) else (if (signed) arm.fcvtzsWfromS(.x2, .x16) else arm.fcvtzuWfromS(.x2, .x16)))
        else
            (if (wide) (if (signed) arm.fcvtzsXfromD(.x2, .x16) else arm.fcvtzuXfromD(.x2, .x16)) else (if (signed) arm.fcvtzsWfromD(.x2, .x16) else arm.fcvtzuWfromD(.x2, .x16))));
        return;
    }
    var low_half: Machine.Label = .{};
    defer low_half.deinit(m.gpa);
    var done: Machine.Label = .{};
    defer done.deinit(m.gpa);
    if (!signed and wide) {
        // SSE2 has no unsigned conversion. Subtract exactly 2^63 in the
        // upper half, convert the remainder, then restore the high bit.
        try compareBound(m, single, 9223372036854775808.0);
        try m.jumpCond(.below, &low_half);
        if (single) {
            try m.subFloat(.xmm0, .xmm1);
            try m.cvttFloatToI64(.rax, .xmm0);
        } else {
            try m.subDouble(.xmm0, .xmm1);
            try m.cvttDoubleToI64(.rax, .xmm0);
        }
        try m.movImm64(.r10, 0x8000_0000_0000_0000);
        try m.orReg64(.rax, .r10);
        try m.jump(&done);
        try m.bind(&low_half);
    }
    if (single) {
        if (signed and !wide) try m.cvttFloatToI32(.rax, .xmm0) else try m.cvttFloatToI64(.rax, .xmm0);
    } else {
        if (signed and !wide) try m.cvttDoubleToI32(.rax, .xmm0) else try m.cvttDoubleToI64(.rax, .xmm0);
    }
    try m.bind(&done);
}

fn fromInteger(m: *Machine, signed: bool, input: ir.Type, output: ir.Type) !void {
    const narrow = input == .i32;
    const single = output == .f32;
    if (comptime !is_x86) {
        try m.emit(if (single)
            (if (narrow) (if (signed) arm.scvtfSfromW(.x16, .x2) else arm.ucvtfSfromW(.x16, .x2)) else (if (signed) arm.scvtfSfromX(.x16, .x2) else arm.ucvtfSfromX(.x16, .x2)))
        else
            (if (narrow) (if (signed) arm.scvtfDfromW(.x16, .x2) else arm.ucvtfDfromW(.x16, .x2)) else (if (signed) arm.scvtfDfromX(.x16, .x2) else arm.ucvtfDfromX(.x16, .x2))));
        try m.emit(if (single) arm.fmovStoW(.x2, .x16) else arm.fmovDtoX(.x2, .x16));
        return;
    }
    var ordinary: Machine.Label = .{};
    defer ordinary.deinit(m.gpa);
    var done: Machine.Label = .{};
    defer done.deinit(m.gpa);
    if (!signed and !narrow) {
        // Preserve the discarded low bit before rounding the upper half.
        // Unlike Spasm's local lowering, RCX is a live allocated home here.
        try m.testReg64(.rax, .rax);
        try m.jumpCond(.not_sign, &ordinary);
        try m.movReg64(.r10, .rax);
        try m.shrImm8(.rax, 1);
        try m.movImm64(.r11, 1);
        try m.andReg64(.r10, .r11);
        try m.orReg64(.rax, .r10);
        if (single) {
            try m.cvtI64ToFloat(.xmm0, .rax);
            try m.addFloat(.xmm0, .xmm0);
        } else {
            try m.cvtI64ToDouble(.xmm0, .rax);
            try m.addDouble(.xmm0, .xmm0);
        }
        try m.jump(&done);
        try m.bind(&ordinary);
    }
    if (single) {
        if (signed and narrow) try m.cvtI32ToFloat(.xmm0, .rax) else try m.cvtI64ToFloat(.xmm0, .rax);
    } else {
        if (signed and narrow) try m.cvtI32ToDouble(.xmm0, .rax) else try m.cvtI64ToDouble(.xmm0, .rax);
    }
    try m.bind(&done);
    if (single) try m.movDRegFromXmm(.rax, .xmm0) else try m.movQRegFromXmm(.rax, .xmm0);
}
