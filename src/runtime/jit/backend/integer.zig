//! Integer emission uses the native backend's fixed arithmetic scratch words.
//! x86 RCX/RDX are allocated homes: fixed-register instructions save/restore
//! them in R11. No stack writes, calls, or optional CPU features are required.
const builtin = @import("builtin");
const ir = @import("ir.zig");
const arm = @import("../asm_aarch64.zig");
const arm_masm = @import("../masm.zig");
const x86 = @import("../asm_x86_64.zig");
const is_x86 = builtin.cpu.arch == .x86_64;
const Machine = if (is_x86) x86.Masm else arm_masm.Masm;

pub fn emit(m: *Machine, op: ir.Op, ty: ir.Type) !void {
    if (comptime is_x86) return emitX86(m, op, ty == .i32);
    return emitArm(m, op, ty == .i32);
}

pub fn divide(m: *Machine, op: ir.Op, ty: ir.Type, zero: *Machine.Label, overflow: *Machine.Label) !void {
    const narrow = ty == .i32;
    const signed = op == .div_s or op == .rem_s;
    const remainder = op == .rem_s or op == .rem_u;
    const minimum: u64 = if (narrow) 0x8000_0000 else 0x8000_0000_0000_0000;
    const minus_one: u64 = if (narrow) 0xffff_ffff else 0xffff_ffff_ffff_ffff;
    var ordinary: Machine.Label = .{};
    defer ordinary.deinit(m.gpa);
    var done: Machine.Label = .{};
    defer done.deinit(m.gpa);
    if (comptime is_x86) {
        try m.testReg64(.r10, .r10);
        try m.jumpCond(.equal, zero);
        if (signed) {
            try m.movImm64(.r11, minus_one);
            try m.cmpReg64(.r10, .r11);
            try m.jumpCond(.not_equal, &ordinary);
            try m.movImm64(.r11, minimum);
            try m.cmpReg64(.rax, .r11);
            try m.jumpCond(.not_equal, &ordinary);
            if (remainder) {
                try m.movImm32(.rax, 0);
                try m.jump(&done);
            } else try m.jump(overflow);
        }
        try m.bind(&ordinary);
        try m.movReg64(.r11, .rdx);
        if (signed) {
            if (narrow) {
                try m.signExtendAccumulator32();
                try m.idivReg32(.r10);
            } else {
                try m.signExtendAccumulator64();
                try m.idivReg64(.r10);
            }
        } else {
            try m.xorReg32(.rdx, .rdx);
            if (narrow) try m.divReg32(.r10) else try m.divReg64(.r10);
        }
        if (remainder) try m.movReg64(.rax, .rdx);
        try m.movReg64(.rdx, .r11);
    } else {
        try m.jumpCbz(.x3, zero);
        if (op == .div_s) {
            try m.movImm64(.x16, minus_one);
            try m.emit(arm.cmpReg(.x3, .x16));
            try m.jumpCond(.ne, &ordinary);
            try m.movImm64(.x16, minimum);
            try m.emit(arm.cmpReg(.x2, .x16));
            try m.jumpCond(.eq, overflow);
        }
        try m.bind(&ordinary);
        // AArch64 SDIV returns MIN for MIN/-1; MSUB then yields the required
        // zero remainder without a hardware trap or an overflow exception.
        if (signed) {
            try m.emit(if (narrow) arm.sdivW(.x16, .x2, .x3) else arm.sdiv(.x16, .x2, .x3));
        } else try m.emit(if (narrow) arm.udivW(.x16, .x2, .x3) else arm.udiv(.x16, .x2, .x3));
        if (remainder) {
            try m.emit(if (narrow) arm.msubW(.x2, .x16, .x3, .x2) else arm.msub(.x2, .x16, .x3, .x2));
        } else try m.emit(arm.movReg(.x2, .x16));
    }
    try m.bind(&done);
}

fn emitX86(m: *x86.Masm, op: ir.Op, narrow: bool) !void {
    switch (op) {
        .add => if (narrow) try m.addReg32(.rax, .r10) else try m.addReg64(.rax, .r10),
        .sub => if (narrow) try m.subReg32(.rax, .r10) else try m.subReg64(.rax, .r10),
        .mul => if (narrow) try m.imulReg32(.rax, .r10) else try m.imulReg64(.rax, .r10),
        .bit_and => if (narrow) try m.andReg32(.rax, .r10) else try m.andReg64(.rax, .r10),
        .bit_or => if (narrow) try m.orReg32(.rax, .r10) else try m.orReg64(.rax, .r10),
        .bit_xor => if (narrow) try m.xorReg32(.rax, .r10) else try m.xorReg64(.rax, .r10),
        .shl, .shr_s, .shr_u, .rotl, .rotr => {
            try m.movReg64(.r11, .rcx);
            try m.movReg64(.rcx, .r10);
            switch (op) {
                .shl => if (narrow) try m.shlReg32Cl(.rax) else try m.shlReg64Cl(.rax),
                .shr_s => if (narrow) try m.sarReg32Cl(.rax) else try m.sarReg64Cl(.rax),
                .shr_u => if (narrow) try m.shrReg32Cl(.rax) else try m.shrReg64Cl(.rax),
                .rotl => if (narrow) try m.rolReg32Cl(.rax) else try m.rolReg64Cl(.rax),
                else => if (narrow) try m.rorReg32Cl(.rax) else try m.rorReg64Cl(.rax),
            }
            try m.movReg64(.rcx, .r11);
        },
        .sext8, .sext16, .sext32 => {
            const shift: u8 = if (op == .sext8) 56 else if (op == .sext16) 48 else 32;
            try m.movReg64(.r11, .rcx);
            try m.movImm32(.rcx, shift);
            try m.shlImm8(.rax, shift);
            try m.sarReg64Cl(.rax);
            try m.movReg64(.rcx, .r11);
            if (narrow) try m.movReg32(.rax, .rax);
        },
        .clz, .ctz => {
            var zero: x86.Masm.Label = .{};
            defer zero.deinit(m.gpa);
            var done: x86.Masm.Label = .{};
            defer done.deinit(m.gpa);
            try m.testReg64(.rax, .rax);
            try m.jumpCond(.equal, &zero);
            if (op == .ctz) {
                try m.bitScanForward64(.rax, .rax);
            } else {
                try m.bitScanReverse64(.rax, .rax);
                try m.movImm32(.r10, if (narrow) 31 else 63);
                try m.xorReg64(.rax, .r10);
            }
            try m.jump(&done);
            try m.bind(&zero);
            try m.movImm32(.rax, if (narrow) 32 else 64);
            try m.bind(&done);
        },
        .popcnt => {
            // SWAR count: POPCNT is not part of the x86-64 baseline.
            try m.movReg64(.r10, .rax);
            try m.shrImm8(.r10, 1);
            try m.movImm64(.r11, 0x5555_5555_5555_5555);
            try m.andReg64(.r10, .r11);
            try m.subReg64(.rax, .r10);
            try m.movReg64(.r10, .rax);
            try m.shrImm8(.r10, 2);
            try m.movImm64(.r11, 0x3333_3333_3333_3333);
            try m.andReg64(.rax, .r11);
            try m.andReg64(.r10, .r11);
            try m.addReg64(.rax, .r10);
            try m.movReg64(.r10, .rax);
            try m.shrImm8(.r10, 4);
            try m.addReg64(.rax, .r10);
            try m.movImm64(.r11, 0x0f0f_0f0f_0f0f_0f0f);
            try m.andReg64(.rax, .r11);
            try m.movImm64(.r11, 0x0101_0101_0101_0101);
            try m.imulReg64(.rax, .r11);
            try m.shrImm8(.rax, 56);
        },
        else => {
            if (narrow) try m.cmpReg32(.rax, .r10) else try m.cmpReg64(.rax, .r10);
            const condition: x86.Cond = switch (op) {
                .eq => .equal,
                .ne => .not_equal,
                .lt_s => .less,
                .lt_u => .below,
                .gt_s => .greater,
                .gt_u => .above,
                .le_s => .less_or_equal,
                .le_u => .below_or_equal,
                .ge_s => .greater_or_equal,
                .ge_u => .above_or_equal,
                else => return error.InvalidGraph,
            };
            try m.setCond32(.rax, condition);
        },
    }
}

fn emitArm(m: *arm_masm.Masm, op: ir.Op, narrow: bool) !void {
    switch (op) {
        .add => try m.emit(arm.addReg(.x2, .x2, .x3)),
        .sub => try m.emit(arm.subReg(.x2, .x2, .x3)),
        .mul => try m.emit(arm.mul(.x2, .x2, .x3)),
        .bit_and => try m.emit(arm.andReg(.x2, .x2, .x3)),
        .bit_or => try m.emit(arm.orrReg(.x2, .x2, .x3)),
        .bit_xor => try m.emit(arm.eorReg(.x2, .x2, .x3)),
        .shl => try m.emit(if (narrow) arm.lslvW(.x2, .x2, .x3) else arm.lslv(.x2, .x2, .x3)),
        .shr_s => try m.emit(if (narrow) arm.asrvW(.x2, .x2, .x3) else arm.asrv(.x2, .x2, .x3)),
        .shr_u => try m.emit(if (narrow) arm.lsrvW(.x2, .x2, .x3) else arm.lsrv(.x2, .x2, .x3)),
        .rotl, .rotr => {
            if (op == .rotl) {
                try m.movImm64(.x16, 0);
                try m.emit(arm.subReg(.x3, .x16, .x3));
            }
            try m.emit(if (narrow) arm.rorvW(.x2, .x2, .x3) else arm.rorv(.x2, .x2, .x3));
        },
        .clz, .ctz => {
            if (op == .ctz) try m.emit(if (narrow) arm.rbitW(.x2, .x2) else arm.rbitX(.x2, .x2));
            try m.emit(if (narrow) arm.clzW(.x2, .x2) else arm.clzX(.x2, .x2));
        },
        .popcnt => {
            try m.emit(arm.fmovXtoD(.x16, .x2));
            try m.emit(arm.cnt8b(.x16, .x16));
            try m.emit(arm.addvB(.x16, .x16));
            try m.emit(arm.fmovDtoX(.x2, .x16));
        },
        .sext8 => try m.emit(if (narrow) arm.sxtbW(.x2, .x2) else arm.sxtbX(.x2, .x2)),
        .sext16 => try m.emit(if (narrow) arm.sxthW(.x2, .x2) else arm.sxthX(.x2, .x2)),
        .sext32 => try m.emit(arm.sxtwX(.x2, .x2)),
        else => {
            try m.emit(if (narrow) arm.cmpRegW(.x2, .x3) else arm.cmpReg(.x2, .x3));
            const condition: arm.Cond = switch (op) {
                .eq => .eq,
                .ne => .ne,
                .lt_s => .lt,
                .lt_u => .cc,
                .gt_s => .gt,
                .gt_u => .hi,
                .le_s => .le,
                .le_u => .ls,
                .ge_s => .ge,
                .ge_u => .cs,
                else => return error.InvalidGraph,
            };
            try m.emit(arm.csetW(.x2, condition));
        },
    }
    if (narrow) try m.emit(arm.movRegW(.x2, .x2));
}
