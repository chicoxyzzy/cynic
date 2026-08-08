//! Bistromath-local MacroAssembler facade.
//!
//! The bytecode compiler stays one pass and target-neutral.  This adapter owns
//! the only details that differ between its supported hosts: physical register
//! assignment, two- versus three-address integer operations, condition codes,
//! entry/call ABI, and prologue/epilogue layout.  The raw encoders and W^X code
//! allocator remain shared under `runtime/jit/`.

const std = @import("std");
const builtin = @import("builtin");

const a64 = @import("../jit/asm_aarch64.zig");
const a64_masm = @import("../jit/masm.zig");
const x64 = @import("../jit/asm_x86_64.zig");
const safepoint_a64 = @import("../ohaimark/safepoint_codegen_aarch64.zig");
const safepoint_x64 = @import("../ohaimark/safepoint_codegen_x86_64.zig");

const use_x64 = builtin.cpu.arch == .x86_64;
const BackendMasm = if (use_x64) x64.Masm else a64_masm.Masm;

pub const supported_isa = switch (builtin.cpu.arch) {
    .aarch64, .x86_64 => true,
    else => false,
};

/// Logical registers used by the shared Bistromath emitter.  The names retain
/// the original A64 spelling so the bytecode/compiler correspondence stays
/// reviewable; `xreg` below assigns their x86_64 physical homes.
pub const Reg = enum {
    x0,
    x1,
    x2,
    x3,
    x4,
    x5,
    x6,
    x9,
    x10,
    x11,
    x12,
    x13,
    x14,
    x16,
    x19,
    x20,
    x21,
    x22,
    x23,
    x24,
};

/// A64 condition names form the target-neutral vocabulary used by the
/// compiler.  `xCond` maps their flag meaning to x86 condition codes.
pub const Cond = enum {
    eq,
    ne,
    cs,
    cc,
    mi,
    pl,
    vs,
    vc,
    hi,
    ls,
    ge,
    lt,
    gt,
    le,
    al,
    nv,
};

pub const Error = error{
    OutOfMemory,
    LabelAlreadyBound,
    InvalidLabel,
    BranchOutOfRange,
    UnsupportedInstruction,
};

const Binary = struct { rd: Reg, rn: Reg, rm: Reg };
const Unary = struct { rd: Reg, rn: Reg };

pub const Instruction = union(enum) {
    movz: struct { rd: Reg, imm16: u16, hw: u2 },
    movn: struct { rd: Reg, imm16: u16, hw: u2 },
    mov_reg: Unary,
    mov_reg_w: Unary,
    add_reg: Binary,
    add_imm: struct { rd: Reg, rn: Reg, imm12: u12, lsl12: bool },
    sub_imm: struct { rd: Reg, rn: Reg, imm12: u12, lsl12: bool },
    cmp_imm: struct { rn: Reg, imm12: u12, lsl12: bool },
    adds_reg_w: Binary,
    subs_reg_w: Binary,
    cmp_reg: struct { rn: Reg, rm: Reg },
    cmp_reg_w: struct { rn: Reg, rm: Reg },
    adds_imm_w: struct { rd: Reg, rn: Reg, imm12: u12 },
    cset_w: struct { rd: Reg, cond: Cond },
    smull: Binary,
    sxtw: Unary,
    and_reg_w: Binary,
    orr_reg_w: Binary,
    eor_reg_w: Binary,
    orr_reg: Binary,
    eor_reg: Binary,
    lsl_imm: struct { rd: Reg, rn: Reg, shift: u6 },
    lsr_imm: struct { rd: Reg, rn: Reg, shift: u6 },
    ldr_imm: struct { rt: Reg, rn: Reg, byte_off: u15 },
    str_imm: struct { rt: Reg, rn: Reg, byte_off: u15 },
    ldr_imm_w: struct { rt: Reg, rn: Reg, byte_off: u14 },
    ldrb_imm: struct { rt: Reg, rn: Reg, imm12: u12 },
    ret,
};

pub fn movz(rd: Reg, imm16: u16, hw: u2) Instruction {
    return .{ .movz = .{ .rd = rd, .imm16 = imm16, .hw = hw } };
}

pub fn movn(rd: Reg, imm16: u16, hw: u2) Instruction {
    return .{ .movn = .{ .rd = rd, .imm16 = imm16, .hw = hw } };
}

pub fn movReg(rd: Reg, rm: Reg) Instruction {
    return .{ .mov_reg = .{ .rd = rd, .rn = rm } };
}

pub fn movRegW(rd: Reg, rm: Reg) Instruction {
    return .{ .mov_reg_w = .{ .rd = rd, .rn = rm } };
}

pub fn addReg(rd: Reg, rn: Reg, rm: Reg) Instruction {
    return .{ .add_reg = .{ .rd = rd, .rn = rn, .rm = rm } };
}

pub fn addImm(rd: Reg, rn: Reg, imm12: u12, lsl12: bool) Instruction {
    return .{ .add_imm = .{ .rd = rd, .rn = rn, .imm12 = imm12, .lsl12 = lsl12 } };
}

pub fn subImm(rd: Reg, rn: Reg, imm12: u12, lsl12: bool) Instruction {
    return .{ .sub_imm = .{ .rd = rd, .rn = rn, .imm12 = imm12, .lsl12 = lsl12 } };
}

pub fn cmpImm(rn: Reg, imm12: u12, lsl12: bool) Instruction {
    return .{ .cmp_imm = .{ .rn = rn, .imm12 = imm12, .lsl12 = lsl12 } };
}

pub fn addsRegW(rd: Reg, rn: Reg, rm: Reg) Instruction {
    return .{ .adds_reg_w = .{ .rd = rd, .rn = rn, .rm = rm } };
}

pub fn subsRegW(rd: Reg, rn: Reg, rm: Reg) Instruction {
    return .{ .subs_reg_w = .{ .rd = rd, .rn = rn, .rm = rm } };
}

pub fn cmpReg(rn: Reg, rm: Reg) Instruction {
    return .{ .cmp_reg = .{ .rn = rn, .rm = rm } };
}

pub fn cmpRegW(rn: Reg, rm: Reg) Instruction {
    return .{ .cmp_reg_w = .{ .rn = rn, .rm = rm } };
}

pub fn addsImmW(rd: Reg, rn: Reg, imm12: u12) Instruction {
    return .{ .adds_imm_w = .{ .rd = rd, .rn = rn, .imm12 = imm12 } };
}

pub fn csetW(rd: Reg, cond: Cond) Instruction {
    return .{ .cset_w = .{ .rd = rd, .cond = cond } };
}

pub fn smull(rd: Reg, rn: Reg, rm: Reg) Instruction {
    return .{ .smull = .{ .rd = rd, .rn = rn, .rm = rm } };
}

pub fn sxtw(rd: Reg, rn: Reg) Instruction {
    return .{ .sxtw = .{ .rd = rd, .rn = rn } };
}

pub fn andRegW(rd: Reg, rn: Reg, rm: Reg) Instruction {
    return .{ .and_reg_w = .{ .rd = rd, .rn = rn, .rm = rm } };
}

pub fn orrRegW(rd: Reg, rn: Reg, rm: Reg) Instruction {
    return .{ .orr_reg_w = .{ .rd = rd, .rn = rn, .rm = rm } };
}

pub fn eorRegW(rd: Reg, rn: Reg, rm: Reg) Instruction {
    return .{ .eor_reg_w = .{ .rd = rd, .rn = rn, .rm = rm } };
}

pub fn orrReg(rd: Reg, rn: Reg, rm: Reg) Instruction {
    return .{ .orr_reg = .{ .rd = rd, .rn = rn, .rm = rm } };
}

pub fn eorReg(rd: Reg, rn: Reg, rm: Reg) Instruction {
    return .{ .eor_reg = .{ .rd = rd, .rn = rn, .rm = rm } };
}

pub fn lslImm(rd: Reg, rn: Reg, shift: u6) Instruction {
    return .{ .lsl_imm = .{ .rd = rd, .rn = rn, .shift = shift } };
}

pub fn lsrImm(rd: Reg, rn: Reg, shift: u6) Instruction {
    return .{ .lsr_imm = .{ .rd = rd, .rn = rn, .shift = shift } };
}

pub fn ldrImm(rt: Reg, rn: Reg, byte_off: u15) Instruction {
    return .{ .ldr_imm = .{ .rt = rt, .rn = rn, .byte_off = byte_off } };
}

pub fn strImm(rt: Reg, rn: Reg, byte_off: u15) Instruction {
    return .{ .str_imm = .{ .rt = rt, .rn = rn, .byte_off = byte_off } };
}

pub fn ldrImmW(rt: Reg, rn: Reg, byte_off: u14) Instruction {
    return .{ .ldr_imm_w = .{ .rt = rt, .rn = rn, .byte_off = byte_off } };
}

pub fn ldrbImm(rt: Reg, rn: Reg, imm12: u12) Instruction {
    return .{ .ldrb_imm = .{ .rt = rt, .rn = rn, .imm12 = imm12 } };
}

pub fn ret() Instruction {
    return .ret;
}

pub const Masm = struct {
    gpa: std.mem.Allocator,
    backend: BackendMasm,

    pub const Label = BackendMasm.Label;

    pub fn init(gpa: std.mem.Allocator) Masm {
        return .{ .gpa = gpa, .backend = BackendMasm.init(gpa) };
    }

    pub fn deinit(self: *Masm) void {
        self.backend.deinit();
        self.* = undefined;
    }

    pub fn bytes(self: *const Masm) []const u8 {
        return self.backend.code.items;
    }

    pub fn offset(self: *const Masm) usize {
        return self.backend.code.items.len;
    }

    /// Save Bistromath's pinned state and establish the platform call
    /// alignment.  x86 reserves `[rsp+0]` permanently for SysV argument 7.
    pub fn enterFrame(self: *Masm) Error!void {
        if (comptime use_x64) {
            try self.backend.subRegImm32(.rsp, 56);
            try self.backend.store64Disp32(.rsp, 8, .r12);
            try self.backend.store64Disp32(.rsp, 16, .r13);
            try self.backend.store64Disp32(.rsp, 24, .r14);
            try self.backend.store64Disp32(.rsp, 32, .r15);
            try self.backend.store64Disp32(.rsp, 40, .rbx);
            try self.backend.store64Disp32(.rsp, 48, .rbp);
        } else {
            try self.backend.emit(a64.stpPreIdxSp(.fp, .lr, -16));
            try self.backend.emit(a64.stpPreIdxSp(.x19, .x20, -16));
            try self.backend.emit(a64.stpPreIdxSp(.x21, .x22, -16));
            try self.backend.emit(a64.stpPreIdxSp(.x23, .x24, -16));
        }
    }

    pub fn leaveFrame(self: *Masm) Error!void {
        if (comptime use_x64) {
            try self.backend.load64Disp32(.r12, .rsp, 8);
            try self.backend.load64Disp32(.r13, .rsp, 16);
            try self.backend.load64Disp32(.r14, .rsp, 24);
            try self.backend.load64Disp32(.r15, .rsp, 32);
            try self.backend.load64Disp32(.rbx, .rsp, 40);
            try self.backend.load64Disp32(.rbp, .rsp, 48);
            try self.backend.addRegImm32(.rsp, 56);
        } else {
            try self.backend.emit(a64.ldpPostIdxSp(.x23, .x24, 16));
            try self.backend.emit(a64.ldpPostIdxSp(.x21, .x22, 16));
            try self.backend.emit(a64.ldpPostIdxSp(.x19, .x20, 16));
            try self.backend.emit(a64.ldpPostIdxSp(.fp, .lr, 16));
        }
    }

    /// Move one C entry argument into a logical pinned register.  x0 is the
    /// A64 argument/return register but x86 separates rdi input from rax
    /// output, so entry moves must be explicit at this boundary.
    pub fn moveEntryArg(self: *Masm, destination: Reg, argument: u2) Error!void {
        if (comptime use_x64) {
            const source: x64.Reg = switch (argument) {
                0 => .rdi,
                1 => .rsi,
                2 => .rdx,
                else => return error.UnsupportedInstruction,
            };
            try self.backend.movReg64(xreg(destination), source);
        } else {
            const source: a64.Reg = switch (argument) {
                0 => .x0,
                1 => .x1,
                2 => .x2,
                else => return error.UnsupportedInstruction,
            };
            try self.backend.emit(a64.movReg(areg(destination), source));
        }
    }

    pub fn emit(self: *Masm, instruction: Instruction) Error!void {
        if (comptime use_x64) {
            try self.emitX64(instruction);
        } else {
            try self.emitA64(instruction);
        }
    }

    pub fn movImm64(self: *Masm, destination: Reg, value: u64) Error!void {
        if (comptime use_x64) {
            try self.backend.movImm64(xreg(destination), value);
        } else {
            try self.backend.movImm64(areg(destination), value);
        }
    }

    pub fn bind(self: *Masm, label: *Label) Error!void {
        try self.backend.bind(label);
    }

    pub fn jump(self: *Masm, label: *Label) Error!void {
        try self.backend.jump(label);
    }

    pub fn jumpCond(self: *Masm, condition: Cond, label: *Label) Error!void {
        if (comptime use_x64) {
            try self.backend.jumpCond(xCond(condition), label);
        } else {
            try self.backend.jumpCond(aCond(condition), label);
        }
    }

    pub fn jumpCbz(self: *Masm, register: Reg, label: *Label) Error!void {
        if (comptime use_x64) {
            const physical = xreg(register);
            try self.backend.testReg64(physical, physical);
            try self.backend.jumpCond(.equal, label);
        } else {
            try self.backend.jumpCbz(areg(register), label);
        }
    }

    pub fn jumpCbnz(self: *Masm, register: Reg, label: *Label) Error!void {
        if (comptime use_x64) {
            const physical = xreg(register);
            try self.backend.testReg64(physical, physical);
            try self.backend.jumpCond(.not_equal, label);
        } else {
            try self.backend.jumpCbnz(areg(register), label);
        }
    }

    pub fn jumpTbz(self: *Masm, register: Reg, bit: u6, label: *Label) Error!void {
        if (comptime use_x64) {
            if (bit >= 32) return error.UnsupportedInstruction;
            try self.backend.testReg32Imm32(xreg(register), @as(u32, 1) << @intCast(bit));
            try self.backend.jumpCond(.equal, label);
        } else {
            try self.backend.jumpTbz(areg(register), bit, label);
        }
    }

    pub fn jumpTbnz(self: *Masm, register: Reg, bit: u6, label: *Label) Error!void {
        if (comptime use_x64) {
            if (bit >= 32) return error.UnsupportedInstruction;
            try self.backend.testReg32Imm32(xreg(register), @as(u32, 1) << @intCast(bit));
            try self.backend.jumpCond(.not_equal, label);
        } else {
            try self.backend.jumpTbnz(areg(register), bit, label);
        }
    }

    /// Absolute C call.  The shared compiler stages logical x0..x6; x86
    /// moves x0 from rax to SysV rdi and writes x6 to the reserved stack slot.
    pub fn callAbs(self: *Masm, scratch: Reg, target: usize) Error!void {
        if (comptime use_x64) {
            const target_reg = xreg(scratch);
            try self.backend.store64Disp32(.rsp, 0, xreg(.x6));
            try self.backend.movReg64(.rdi, xreg(.x0));
            try self.backend.movImm64(target_reg, @intCast(target));
            try self.backend.callReg(target_reg);
        } else {
            try self.backend.callAbs(areg(scratch), target);
        }
    }

    /// Emit the helper-free half of Lantern's GC/fuel/interrupt backedge
    /// contract through the selected native backend.
    pub fn emitSafePointPoll(
        self: *Masm,
        realm_register: Reg,
        slow: *Label,
    ) !void {
        if (comptime use_x64) {
            try safepoint_x64.emitPoll(&self.backend, xreg(realm_register), slow);
        } else {
            try safepoint_a64.emitPoll(&self.backend, areg(realm_register), slow);
        }
    }

    pub fn labelResolved(label: *const Label) bool {
        return label.bound != null and label.fixups.items.len == 0;
    }

    fn emitA64(self: *Masm, instruction: Instruction) Error!void {
        const word: u32 = switch (instruction) {
            .movz => |v| a64.movz(areg(v.rd), v.imm16, v.hw),
            .movn => |v| a64.movn(areg(v.rd), v.imm16, v.hw),
            .mov_reg => |v| a64.movReg(areg(v.rd), areg(v.rn)),
            .mov_reg_w => |v| a64.movRegW(areg(v.rd), areg(v.rn)),
            .add_reg => |v| a64.addReg(areg(v.rd), areg(v.rn), areg(v.rm)),
            .add_imm => |v| a64.addImm(areg(v.rd), areg(v.rn), v.imm12, v.lsl12),
            .sub_imm => |v| a64.subImm(areg(v.rd), areg(v.rn), v.imm12, v.lsl12),
            .cmp_imm => |v| a64.cmpImm(areg(v.rn), v.imm12, v.lsl12),
            .adds_reg_w => |v| a64.addsRegW(areg(v.rd), areg(v.rn), areg(v.rm)),
            .subs_reg_w => |v| a64.subsRegW(areg(v.rd), areg(v.rn), areg(v.rm)),
            .cmp_reg => |v| a64.cmpReg(areg(v.rn), areg(v.rm)),
            .cmp_reg_w => |v| a64.cmpRegW(areg(v.rn), areg(v.rm)),
            .adds_imm_w => |v| a64.addsImmW(areg(v.rd), areg(v.rn), v.imm12),
            .cset_w => |v| a64.csetW(areg(v.rd), aCond(v.cond)),
            .smull => |v| a64.smull(areg(v.rd), areg(v.rn), areg(v.rm)),
            .sxtw => |v| a64.sxtw(areg(v.rd), areg(v.rn)),
            .and_reg_w => |v| a64.andRegW(areg(v.rd), areg(v.rn), areg(v.rm)),
            .orr_reg_w => |v| a64.orrRegW(areg(v.rd), areg(v.rn), areg(v.rm)),
            .eor_reg_w => |v| a64.eorRegW(areg(v.rd), areg(v.rn), areg(v.rm)),
            .orr_reg => |v| a64.orrReg(areg(v.rd), areg(v.rn), areg(v.rm)),
            .eor_reg => |v| a64.eorReg(areg(v.rd), areg(v.rn), areg(v.rm)),
            .lsl_imm => |v| a64.lslImm(areg(v.rd), areg(v.rn), v.shift),
            .lsr_imm => |v| a64.lsrImm(areg(v.rd), areg(v.rn), v.shift),
            .ldr_imm => |v| a64.ldrImm(areg(v.rt), areg(v.rn), v.byte_off),
            .str_imm => |v| a64.strImm(areg(v.rt), areg(v.rn), v.byte_off),
            .ldr_imm_w => |v| a64.ldrImmW(areg(v.rt), areg(v.rn), v.byte_off),
            .ldrb_imm => |v| a64.ldrbImm(areg(v.rt), areg(v.rn), v.imm12),
            .ret => a64.ret(),
        };
        try self.backend.emit(word);
    }

    fn emitX64(self: *Masm, instruction: Instruction) Error!void {
        switch (instruction) {
            .movz => |v| try self.backend.movImm64(
                xreg(v.rd),
                @as(u64, v.imm16) << (@as(u6, v.hw) * 16),
            ),
            .movn => |v| try self.backend.movImm64(
                xreg(v.rd),
                ~(@as(u64, v.imm16) << (@as(u6, v.hw) * 16)),
            ),
            .mov_reg => |v| try self.backend.movReg64(xreg(v.rd), xreg(v.rn)),
            .mov_reg_w => |v| try self.backend.movReg32(xreg(v.rd), xreg(v.rn)),
            .add_reg => |v| try self.emitCommutative64(v, .add),
            .add_imm => |v| {
                const rd = xreg(v.rd);
                const rn = xreg(v.rn);
                if (rd != rn) try self.backend.movReg64(rd, rn);
                const amount: u32 = @as(u32, v.imm12) << (if (v.lsl12) 12 else 0);
                try self.backend.addRegImm32(rd, amount);
            },
            .sub_imm => |v| {
                const rd = xreg(v.rd);
                const rn = xreg(v.rn);
                if (rd != rn) try self.backend.movReg64(rd, rn);
                const amount: u32 = @as(u32, v.imm12) << (if (v.lsl12) 12 else 0);
                try self.backend.subRegImm32(rd, amount);
            },
            .cmp_imm => |v| {
                const amount: u32 = @as(u32, v.imm12) << (if (v.lsl12) 12 else 0);
                try self.backend.cmpRegImm32(xreg(v.rn), amount);
            },
            .adds_reg_w => |v| try self.emitCommutative32(v, .add),
            .subs_reg_w => |v| try self.emitSub32(v),
            .cmp_reg => |v| try self.backend.cmpReg64(xreg(v.rn), xreg(v.rm)),
            .cmp_reg_w => |v| try self.backend.cmpReg32(xreg(v.rn), xreg(v.rm)),
            .adds_imm_w => |v| {
                const rd = xreg(v.rd);
                const rn = xreg(v.rn);
                if (rd != rn) try self.backend.movReg32(rd, rn);
                try self.backend.addReg32Imm32(rd, v.imm12);
            },
            .cset_w => |v| try self.backend.setCond32(xreg(v.rd), xCond(v.cond)),
            .smull => |v| {
                const rd = xreg(v.rd);
                const rm = xreg(v.rm);
                if (rd == .rax or rd == rm) return error.UnsupportedInstruction;
                // x0/rax is call-clobbered and never carries bytecode state.
                // It is the private second operand for the full signed product.
                try self.backend.signExtendReg32To64(rd, xreg(v.rn));
                try self.backend.signExtendReg32To64(.rax, rm);
                try self.backend.imulReg64(rd, .rax);
            },
            .sxtw => |v| try self.backend.signExtendReg32To64(xreg(v.rd), xreg(v.rn)),
            .and_reg_w => |v| try self.emitCommutative32(v, .and_),
            .orr_reg_w => |v| try self.emitCommutative32(v, .or_),
            .eor_reg_w => |v| try self.emitCommutative32(v, .xor_),
            .orr_reg => |v| try self.emitCommutative64(v, .or_),
            .eor_reg => |v| try self.emitCommutative64(v, .xor_),
            .lsl_imm => |v| {
                const rd = xreg(v.rd);
                const rn = xreg(v.rn);
                if (rd != rn) try self.backend.movReg64(rd, rn);
                try self.backend.shlImm8(rd, v.shift);
            },
            .lsr_imm => |v| {
                const rd = xreg(v.rd);
                const rn = xreg(v.rn);
                if (rd != rn) try self.backend.movReg64(rd, rn);
                try self.backend.shrImm8(rd, v.shift);
            },
            .ldr_imm => |v| try self.backend.load64Disp32(
                xreg(v.rt),
                xreg(v.rn),
                v.byte_off,
            ),
            .str_imm => |v| try self.backend.store64Disp32(
                xreg(v.rn),
                v.byte_off,
                xreg(v.rt),
            ),
            .ldr_imm_w => |v| try self.backend.load32Disp32(
                xreg(v.rt),
                xreg(v.rn),
                v.byte_off,
            ),
            .ldrb_imm => |v| try self.backend.load8Disp32(
                xreg(v.rt),
                xreg(v.rn),
                v.imm12,
            ),
            .ret => try self.backend.ret(),
        }
    }

    const BinaryOp = enum { add, and_, or_, xor_ };

    fn emitCommutative64(self: *Masm, value: Binary, operation: BinaryOp) Error!void {
        const rd = xreg(value.rd);
        const rn = xreg(value.rn);
        const rm = xreg(value.rm);
        if (rd == rn) {
            try self.apply64(operation, rd, rm);
        } else if (rd == rm) {
            try self.apply64(operation, rd, rn);
        } else {
            try self.backend.movReg64(rd, rn);
            try self.apply64(operation, rd, rm);
        }
    }

    fn emitCommutative32(self: *Masm, value: Binary, operation: BinaryOp) Error!void {
        const rd = xreg(value.rd);
        const rn = xreg(value.rn);
        const rm = xreg(value.rm);
        if (rd == rn) {
            try self.apply32(operation, rd, rm);
        } else if (rd == rm) {
            try self.apply32(operation, rd, rn);
        } else {
            try self.backend.movReg32(rd, rn);
            try self.apply32(operation, rd, rm);
        }
    }

    fn emitSub32(self: *Masm, value: Binary) Error!void {
        const rd = xreg(value.rd);
        const rn = xreg(value.rn);
        const rm = xreg(value.rm);
        if (rd == rn) {
            try self.backend.subReg32(rd, rm);
        } else if (rd == rm) {
            if (rd == .rax or rn == .rax) return error.UnsupportedInstruction;
            // Preserve the right operand in call-clobbered rax.  The shared
            // compiler has no live ABI argument/result across an ALU opcode.
            try self.backend.movReg32(.rax, rm);
            try self.backend.movReg32(rd, rn);
            try self.backend.subReg32(rd, .rax);
        } else {
            try self.backend.movReg32(rd, rn);
            try self.backend.subReg32(rd, rm);
        }
    }

    fn apply64(self: *Masm, operation: BinaryOp, destination: x64.Reg, source: x64.Reg) Error!void {
        switch (operation) {
            .add => try self.backend.addReg64(destination, source),
            .and_ => try self.backend.andReg64(destination, source),
            .or_ => try self.backend.orReg64(destination, source),
            .xor_ => try self.backend.xorReg64(destination, source),
        }
    }

    fn apply32(self: *Masm, operation: BinaryOp, destination: x64.Reg, source: x64.Reg) Error!void {
        switch (operation) {
            .add => try self.backend.addReg32(destination, source),
            .and_ => try self.backend.andReg32(destination, source),
            .or_ => try self.backend.orReg32(destination, source),
            .xor_ => try self.backend.xorReg32(destination, source),
        }
    }
};

fn areg(register: Reg) a64.Reg {
    return switch (register) {
        .x0 => .x0,
        .x1 => .x1,
        .x2 => .x2,
        .x3 => .x3,
        .x4 => .x4,
        .x5 => .x5,
        .x6 => .x6,
        .x9 => .x9,
        .x10 => .x10,
        .x11 => .x11,
        .x12 => .x12,
        .x13 => .x13,
        .x14 => .x14,
        .x16 => .x16,
        .x19 => .x19,
        .x20 => .x20,
        .x21 => .x21,
        .x22 => .x22,
        .x23 => .x23,
        .x24 => .x24,
    };
}

fn xreg(register: Reg) x64.Reg {
    return switch (register) {
        // Logical argument staging. x0 doubles as the C return register;
        // `callAbs` moves it to SysV rdi only at the call boundary.
        .x0 => .rax,
        .x1 => .rsi,
        .x2 => .rdx,
        .x3 => .rcx,
        .x4 => .r8,
        .x5 => .r9,
        .x6 => .r10,
        // Bytecode scratch set.
        .x9 => .rdi,
        .x10 => .r10,
        .x11 => .r11,
        .x12 => .rdx,
        .x13 => .rcx,
        .x14 => .r8,
        .x16 => .r11,
        // Callee-saved frame state and tags.
        .x19 => .r12,
        .x20 => .r13,
        .x21 => .r14,
        .x22 => .r15,
        .x23 => .rbx,
        .x24 => .rbp,
    };
}

fn aCond(condition: Cond) a64.Cond {
    return switch (condition) {
        .eq => .eq,
        .ne => .ne,
        .cs => .cs,
        .cc => .cc,
        .mi => .mi,
        .pl => .pl,
        .vs => .vs,
        .vc => .vc,
        .hi => .hi,
        .ls => .ls,
        .ge => .ge,
        .lt => .lt,
        .gt => .gt,
        .le => .le,
        .al => .al,
        .nv => .nv,
    };
}

fn xCond(condition: Cond) x64.Cond {
    return switch (condition) {
        .eq => .equal,
        .ne => .not_equal,
        .cs => .above_or_equal,
        .cc => .below,
        .mi => .sign,
        .pl => .not_sign,
        .vs => .overflow,
        .vc => .not_overflow,
        .hi => .above,
        .ls => .below_or_equal,
        .ge => .greater_or_equal,
        .lt => .less,
        .gt => .greater,
        .le => .less_or_equal,
        .al, .nv => unreachable,
    };
}
