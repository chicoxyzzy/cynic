//! Strict scalar floating-point emission. Inputs/results are raw words in the
//! native backend's GP scratch registers; FP temporaries never hold live homes.
const builtin = @import("builtin");
const ir = @import("ir.zig");
const arm = @import("../asm_aarch64.zig");
const arm_masm = @import("../masm.zig");
const x86 = @import("../asm_x86_64.zig");
const is_x86 = builtin.cpu.arch == .x86_64;
const Machine = if (is_x86) x86.Masm else arm_masm.Masm;

pub fn emit(m: *Machine, op: ir.Op, input: ir.Type) !void {
    const single = input == .f32;
    if (op == .fabs or op == .fneg or op == .fcopysign) return sign(m, op, single);
    if (comptime is_x86) return emitX86(m, op, single);
    return emitArm(m, op, single);
}

fn sign(m: *Machine, op: ir.Op, single: bool) !void {
    // These operations change only the sign bit, including for signaling NaNs.
    const sign_bit: u64 = if (single) 0x8000_0000 else 0x8000_0000_0000_0000;
    const magnitude = ir.normalize(if (single) .f32 else .f64, ~sign_bit);
    if (comptime is_x86) {
        try m.movImm64(.r11, if (op == .fabs) magnitude else sign_bit);
        switch (op) {
            .fabs => try m.andReg64(.rax, .r11),
            .fneg => try m.xorReg64(.rax, .r11),
            .fcopysign => {
                try m.andReg64(.r10, .r11);
                try m.movImm64(.r11, magnitude);
                try m.andReg64(.rax, .r11);
                try m.orReg64(.rax, .r10);
            },
            else => return error.InvalidGraph,
        }
    } else {
        try m.movImm64(.x16, if (op == .fabs) magnitude else sign_bit);
        switch (op) {
            .fabs => try m.emit(arm.andReg(.x2, .x2, .x16)),
            .fneg => try m.emit(arm.eorReg(.x2, .x2, .x16)),
            .fcopysign => {
                try m.emit(arm.andReg(.x3, .x3, .x16));
                try m.movImm64(.x16, magnitude);
                try m.emit(arm.andReg(.x2, .x2, .x16));
                try m.emit(arm.orrReg(.x2, .x2, .x3));
            },
            else => return error.InvalidGraph,
        }
    }
}

fn emitArm(m: *arm_masm.Masm, op: ir.Op, single: bool) !void {
    try m.emit(if (single) arm.fmovWtoS(.x16, .x2) else arm.fmovXtoD(.x16, .x2));
    if (ir.inputCount(op) == 2)
        try m.emit(if (single) arm.fmovWtoS(.x17, .x3) else arm.fmovXtoD(.x17, .x3));
    if (ir.isComparison(op)) {
        try m.emit(if (single) arm.fcmpS(.x16, .x17) else arm.fcmpD(.x16, .x17));
        const condition: arm.Cond = switch (op) {
            .feq => .eq,
            .fne => .ne,
            .flt => .mi,
            .fgt => .gt,
            .fle => .ls,
            .fge => .ge,
            else => return error.InvalidGraph,
        };
        try m.emit(arm.csetW(.x2, condition));
        return;
    }
    try m.emit(switch (op) {
        .fadd => if (single) arm.faddS(.x16, .x16, .x17) else arm.faddD(.x16, .x16, .x17),
        .fsub => if (single) arm.fsubS(.x16, .x16, .x17) else arm.fsubD(.x16, .x16, .x17),
        .fmul => if (single) arm.fmulS(.x16, .x16, .x17) else arm.fmulD(.x16, .x16, .x17),
        .fdiv => if (single) arm.fdivS(.x16, .x16, .x17) else arm.fdivD(.x16, .x16, .x17),
        .fmin => if (single) arm.fminS(.x16, .x16, .x17) else arm.fminD(.x16, .x16, .x17),
        .fmax => if (single) arm.fmaxS(.x16, .x16, .x17) else arm.fmaxD(.x16, .x16, .x17),
        .fsqrt => if (single) arm.fsqrtS(.x16, .x16) else arm.fsqrtD(.x16, .x16),
        .fceil => if (single) arm.frintpS(.x16, .x16) else arm.frintpD(.x16, .x16),
        .ffloor => if (single) arm.frintmS(.x16, .x16) else arm.frintmD(.x16, .x16),
        .ftrunc => if (single) arm.frintzS(.x16, .x16) else arm.frintzD(.x16, .x16),
        .fnearest => if (single) arm.frintnS(.x16, .x16) else arm.frintnD(.x16, .x16),
        .promote_f32 => arm.fcvtStoD(.x16, .x16),
        .demote_f64 => arm.fcvtDtoS(.x16, .x16),
        else => return error.InvalidGraph,
    });
    const output_single = if (ir.conversionTypes(op)) |conversion| conversion.output == .f32 else single;
    try m.emit(if (output_single) arm.fmovStoW(.x2, .x16) else arm.fmovDtoX(.x2, .x16));
}

fn emitX86(m: *x86.Masm, op: ir.Op, single: bool) !void {
    if (op == .fceil or op == .ffloor or op == .ftrunc or op == .fnearest) return roundX86(m, op, single);
    if (single) try m.movDXmmFromReg(.xmm0, .rax) else try m.movQXmmFromReg(.xmm0, .rax);
    if (ir.inputCount(op) == 2) {
        if (single) try m.movDXmmFromReg(.xmm1, .r10) else try m.movQXmmFromReg(.xmm1, .r10);
    }
    if (ir.isComparison(op) or op == .fmin or op == .fmax) {
        if (single) try m.ucomisFloat(.xmm0, .xmm1) else try m.ucomisDouble(.xmm0, .xmm1);
        if (ir.isComparison(op)) return compareX86(m, op);
        return minmaxX86(m, op, single);
    }
    switch (op) {
        .fadd => if (single) try m.addFloat(.xmm0, .xmm1) else try m.addDouble(.xmm0, .xmm1),
        .fsub => if (single) try m.subFloat(.xmm0, .xmm1) else try m.subDouble(.xmm0, .xmm1),
        .fmul => if (single) try m.mulFloat(.xmm0, .xmm1) else try m.mulDouble(.xmm0, .xmm1),
        .fdiv => if (single) try m.divFloat(.xmm0, .xmm1) else try m.divDouble(.xmm0, .xmm1),
        .fsqrt => if (single) try m.sqrtFloat(.xmm0, .xmm0) else try m.sqrtDouble(.xmm0, .xmm0),
        .promote_f32 => try m.cvtFloatToDouble(.xmm0, .xmm0),
        .demote_f64 => try m.cvtDoubleToFloat(.xmm0, .xmm0),
        else => return error.InvalidGraph,
    }
    const output_single = if (ir.conversionTypes(op)) |conversion| conversion.output == .f32 else single;
    if (output_single) try m.movDRegFromXmm(.rax, .xmm0) else try m.movQRegFromXmm(.rax, .xmm0);
}

fn roundX86(m: *x86.Masm, op: ir.Op, single: bool) !void {
    // SSE2 baseline: round the finite magnitude through an exactly representable
    // integer, then restore the sign (including zero). No SSE4.1 or host calls.
    const sign_bit: u64 = if (single) 0x8000_0000 else 0x8000_0000_0000_0000;
    var ordinary: x86.Masm.Label = .{};
    defer ordinary.deinit(m.gpa);
    var assemble: x86.Masm.Label = .{};
    defer assemble.deinit(m.gpa);
    var increment: x86.Masm.Label = .{};
    defer increment.deinit(m.gpa);
    var done: x86.Masm.Label = .{};
    defer done.deinit(m.gpa);
    try m.movReg64(.r10, .rax);
    try m.movImm64(.r11, sign_bit - 1);
    try m.andReg64(.r10, .r11);
    try m.movImm64(.r11, if (single) 0x4b00_0000 else 0x4330_0000_0000_0000);
    try m.cmpReg64(.r10, .r11);
    try m.jumpCond(.below, &ordinary);
    // Large finite inputs are already integral. Infinities stay unchanged;
    // signaling NaNs must become arithmetic NaNs, not leak unchanged bits.
    try m.movImm64(.r11, if (single) 0x7f80_0000 else 0x7ff0_0000_0000_0000);
    try m.cmpReg64(.r10, .r11);
    try m.jumpCond(.below_or_equal, &done);
    try m.movImm64(.r11, if (single) 0x0040_0000 else 0x0008_0000_0000_0000);
    try m.orReg64(.rax, .r11);
    try m.jump(&done);
    try m.bind(&ordinary);
    try m.movImm64(.r11, sign_bit);
    try m.andReg64(.r11, .rax);
    if (single) {
        try m.movDXmmFromReg(.xmm0, .r10);
        try m.cvtFloatToDouble(.xmm0, .xmm0);
    } else try m.movQXmmFromReg(.xmm0, .r10);
    try m.cvttDoubleToI64(.rax, .xmm0);
    if (op != .ftrunc) {
        try m.cvtI64ToDouble(.xmm1, .rax);
        if (op == .fnearest) {
            try m.subDouble(.xmm0, .xmm1);
            try m.movImm64(.r10, 0x3fe0_0000_0000_0000);
            try m.movQXmmFromReg(.xmm1, .r10);
            try m.ucomisDouble(.xmm0, .xmm1);
            try m.jumpCond(.below, &assemble);
            try m.jumpCond(.above, &increment);
            try m.movReg64(.r10, .rax);
            try m.movImm64(.rax, 1);
            try m.andReg64(.rax, .r10);
            try m.testReg64(.rax, .rax);
            try m.movReg64(.rax, .r10);
            try m.jumpCond(.equal, &assemble);
        } else {
            try m.ucomisDouble(.xmm0, .xmm1);
            try m.jumpCond(.equal, &assemble);
            try m.testReg64(.r11, .r11);
            try m.jumpCond(if (op == .fceil) .not_equal else .equal, &assemble);
        }
        try m.bind(&increment);
        try m.movImm64(.r10, 1);
        try m.addReg64(.rax, .r10);
    }
    try m.bind(&assemble);
    try m.cvtI64ToDouble(.xmm0, .rax);
    if (single) {
        try m.cvtDoubleToFloat(.xmm0, .xmm0);
        try m.movDRegFromXmm(.rax, .xmm0);
    } else try m.movQRegFromXmm(.rax, .xmm0);
    try m.orReg64(.rax, .r11);
    try m.bind(&done);
}

fn compareX86(m: *x86.Masm, op: ir.Op) !void {
    // UCOMIS sets ZF and CF for unordered operands too. Only != accepts NaN.
    var ordered: x86.Masm.Label = .{};
    defer ordered.deinit(m.gpa);
    var done: x86.Masm.Label = .{};
    defer done.deinit(m.gpa);
    try m.jumpCond(.not_parity, &ordered);
    try m.movImm32(.rax, @intFromBool(op == .fne));
    try m.jump(&done);
    try m.bind(&ordered);
    const condition: x86.Cond = switch (op) {
        .feq => .equal,
        .fne => .not_equal,
        .flt => .below,
        .fgt => .above,
        .fle => .below_or_equal,
        .fge => .above_or_equal,
        else => return error.InvalidGraph,
    };
    try m.setCond32(.rax, condition);
    try m.bind(&done);
}

fn minmaxX86(m: *x86.Masm, op: ir.Op, single: bool) !void {
    // SSE MIN/MAX select the right operand on equality or NaN. Strict
    // min/max instead propagate NaN and select the right signed zero.
    var unordered: x86.Masm.Label = .{};
    defer unordered.deinit(m.gpa);
    var equal: x86.Masm.Label = .{};
    defer equal.deinit(m.gpa);
    var done: x86.Masm.Label = .{};
    defer done.deinit(m.gpa);
    try m.jumpCond(.parity, &unordered);
    try m.jumpCond(.equal, &equal);
    try m.jumpCond(if (op == .fmin) .below else .above, &done);
    try m.movReg64(.rax, .r10);
    try m.jump(&done);
    try m.bind(&equal);
    if (op == .fmin) try m.orReg64(.rax, .r10) else try m.andReg64(.rax, .r10);
    try m.jump(&done);
    try m.bind(&unordered);
    if (single) {
        try m.addFloat(.xmm0, .xmm1);
        try m.movDRegFromXmm(.rax, .xmm0);
    } else {
        try m.addDouble(.xmm0, .xmm1);
        try m.movQRegFromXmm(.rax, .xmm0);
    }
    try m.bind(&done);
}
