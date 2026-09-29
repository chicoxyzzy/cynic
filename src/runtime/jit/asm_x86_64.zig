//! Small x86_64 machine-code writer for the shared JIT substrate.
//!
//! This is intentionally a byte-oriented counterpart to `asm_aarch64.zig`.
//! Bistromath and Ohaimark use it for SysV ABI entries, labels, guard branches,
//! and indirect helper calls. Higher-level tier policy stays in each compiler.

const std = @import("std");
const builtin = @import("builtin");
const code_alloc = @import("code_alloc.zig");

/// General-purpose x86_64 registers. Their discriminants are the architectural
/// register numbers used directly by ModRM and REX.
pub const Reg = enum(u4) {
    rax = 0,
    rcx = 1,
    rdx = 2,
    rbx = 3,
    rsp = 4,
    rbp = 5,
    rsi = 6,
    rdi = 7,
    r8 = 8,
    r9 = 9,
    r10 = 10,
    r11 = 11,
    r12 = 12,
    r13 = 13,
    r14 = 14,
    r15 = 15,
};

pub const Xmm = enum(u4) {
    xmm0 = 0,
    xmm1 = 1,
    xmm2 = 2,
    xmm3 = 3,
    xmm4 = 4,
    xmm5 = 5,
    xmm6 = 6,
    xmm7 = 7,
    xmm8 = 8,
    xmm9 = 9,
    xmm10 = 10,
    xmm11 = 11,
    xmm12 = 12,
    xmm13 = 13,
    xmm14 = 14,
    xmm15 = 15,
};

/// x86 condition-code low nibble, shared by short and near branches. The
/// first x86 lowering uses near branches exclusively so forward guard exits do
/// not depend on final code size.
pub const Cond = enum(u4) {
    overflow = 0,
    not_overflow = 1,
    below = 2,
    above_or_equal = 3,
    equal = 4,
    not_equal = 5,
    below_or_equal = 6,
    above = 7,
    sign = 8,
    not_sign = 9,
    parity = 10,
    not_parity = 11,
    less = 12,
    greater_or_equal = 13,
    less_or_equal = 14,
    greater = 15,
};

/// True only when the code allocator can install and execute x86_64 code on
/// this host. The encoder remains compileable for cross-target builds.
pub const native_x86_64 = code_alloc.supported and builtin.cpu.arch == .x86_64;

pub const Masm = struct {
    gpa: std.mem.Allocator,
    code: std.ArrayListUnmanaged(u8) = .empty,

    pub fn init(gpa: std.mem.Allocator) Masm {
        return .{ .gpa = gpa };
    }

    pub fn deinit(self: *Masm) void {
        self.code.deinit(self.gpa);
        self.* = undefined;
    }

    /// `mov r64, imm64`.
    pub fn movImm64(self: *Masm, destination: Reg, value: u64) error{OutOfMemory}!void {
        try self.emitByte(rex(true, false, false, isExtended(destination)));
        try self.emitByte(0xB8 + lowBits(destination));
        try self.emitU64(value);
    }

    /// `mov destination, source`.
    pub fn movReg64(self: *Masm, destination: Reg, source: Reg) error{OutOfMemory}!void {
        try self.emitRegReg(0x89, destination, source);
    }

    /// `mov destination32, source32`, zero-extending into the destination.
    pub fn movReg32(self: *Masm, destination: Reg, source: Reg) error{OutOfMemory}!void {
        try self.emitRegReg32(0x89, destination, source);
    }

    /// `add destination, source`.
    pub fn addReg64(self: *Masm, destination: Reg, source: Reg) error{OutOfMemory}!void {
        try self.emitRegReg(0x01, destination, source);
    }

    /// `add destination32, source32`.
    pub fn addReg32(self: *Masm, destination: Reg, source: Reg) error{OutOfMemory}!void {
        try self.emitRegReg32(0x01, destination, source);
    }

    /// `add destination32, immediate32`.
    pub fn addReg32Imm32(
        self: *Masm,
        destination: Reg,
        immediate: u32,
    ) error{OutOfMemory}!void {
        try self.emitByte(rex(false, false, false, isExtended(destination)));
        try self.emitByte(0x81);
        try self.emitByte(0xC0 | lowBits(destination));
        try self.emitU32(immediate);
    }

    /// `sub destination, source`.
    pub fn subReg64(self: *Masm, destination: Reg, source: Reg) error{OutOfMemory}!void {
        try self.emitRegReg(0x29, destination, source);
    }

    /// `sub destination32, source32`.
    pub fn subReg32(self: *Masm, destination: Reg, source: Reg) error{OutOfMemory}!void {
        try self.emitRegReg32(0x29, destination, source);
    }

    /// `imul destination32, source32`.
    pub fn imulReg32(self: *Masm, destination: Reg, source: Reg) error{OutOfMemory}!void {
        try self.emitByte(rex(false, isExtended(destination), false, isExtended(source)));
        try self.emitByte(0x0F);
        try self.emitByte(0xAF);
        try self.emitByte(0xC0 | (lowBits(destination) << 3) | lowBits(source));
    }

    /// `imul destination, source` over signed 64-bit operands.
    pub fn imulReg64(self: *Masm, destination: Reg, source: Reg) error{OutOfMemory}!void {
        try self.emitByte(rex(true, isExtended(destination), false, isExtended(source)));
        try self.emitByte(0x0F);
        try self.emitByte(0xAF);
        try self.emitByte(0xC0 | (lowBits(destination) << 3) | lowBits(source));
    }

    /// `movsxd destination, source32` — sign-extend an Int32 payload into
    /// a 64-bit register without involving host-language casts.
    pub fn signExtendReg32To64(
        self: *Masm,
        destination: Reg,
        source: Reg,
    ) error{OutOfMemory}!void {
        try self.emitByte(rex(true, isExtended(destination), false, isExtended(source)));
        try self.emitByte(0x63);
        try self.emitByte(0xC0 | (lowBits(destination) << 3) | lowBits(source));
    }

    /// `bsf destination32, source32` -- index of the least-significant set
    /// bit. The destination is undefined for zero; callers must handle ZF.
    pub fn bitScanForward32(
        self: *Masm,
        destination: Reg,
        source: Reg,
    ) error{OutOfMemory}!void {
        try self.emitBitScan(false, 0xBC, destination, source);
    }

    /// `bsf destination, source` over a 64-bit operand.
    pub fn bitScanForward64(
        self: *Masm,
        destination: Reg,
        source: Reg,
    ) error{OutOfMemory}!void {
        try self.emitBitScan(true, 0xBC, destination, source);
    }

    /// `bsr destination32, source32` -- index of the most-significant set
    /// bit. The destination is undefined for zero; callers must handle ZF.
    pub fn bitScanReverse32(
        self: *Masm,
        destination: Reg,
        source: Reg,
    ) error{OutOfMemory}!void {
        try self.emitBitScan(false, 0xBD, destination, source);
    }

    /// `bsr destination, source` over a 64-bit operand.
    pub fn bitScanReverse64(
        self: *Masm,
        destination: Reg,
        source: Reg,
    ) error{OutOfMemory}!void {
        try self.emitBitScan(true, 0xBD, destination, source);
    }

    /// `add destination, immediate32`.
    pub fn addRegImm32(
        self: *Masm,
        destination: Reg,
        immediate: u32,
    ) error{OutOfMemory}!void {
        try self.emitRegImm32(0, destination, immediate);
    }

    /// `sub destination, immediate32`.
    pub fn subRegImm32(
        self: *Masm,
        destination: Reg,
        immediate: u32,
    ) error{OutOfMemory}!void {
        try self.emitRegImm32(5, destination, immediate);
    }

    /// `and destination, source`.
    pub fn andReg64(self: *Masm, destination: Reg, source: Reg) error{OutOfMemory}!void {
        try self.emitRegReg(0x21, destination, source);
    }

    /// `and destination32, source32`.
    pub fn andReg32(self: *Masm, destination: Reg, source: Reg) error{OutOfMemory}!void {
        try self.emitRegReg32(0x21, destination, source);
    }

    /// `or destination, source`.
    pub fn orReg64(self: *Masm, destination: Reg, source: Reg) error{OutOfMemory}!void {
        try self.emitRegReg(0x09, destination, source);
    }

    /// `or destination32, source32`.
    pub fn orReg32(self: *Masm, destination: Reg, source: Reg) error{OutOfMemory}!void {
        try self.emitRegReg32(0x09, destination, source);
    }

    /// `xor destination, source`.
    pub fn xorReg64(self: *Masm, destination: Reg, source: Reg) error{OutOfMemory}!void {
        try self.emitRegReg(0x31, destination, source);
    }

    /// `xor destination32, source32`.
    pub fn xorReg32(self: *Masm, destination: Reg, source: Reg) error{OutOfMemory}!void {
        try self.emitRegReg32(0x31, destination, source);
    }

    /// `test left, right`.
    pub fn testReg64(self: *Masm, left: Reg, right: Reg) error{OutOfMemory}!void {
        try self.emitRegReg(0x85, left, right);
    }

    /// `test value32, immediate32`.
    pub fn testReg32Imm32(
        self: *Masm,
        value: Reg,
        immediate: u32,
    ) error{OutOfMemory}!void {
        try self.emitByte(rex(false, false, false, isExtended(value)));
        try self.emitByte(0xF7);
        try self.emitByte(0xC0 | lowBits(value));
        try self.emitU32(immediate);
    }

    /// `cmp left, right`.
    pub fn cmpReg64(self: *Masm, left: Reg, right: Reg) error{OutOfMemory}!void {
        try self.emitRegReg(0x39, left, right);
    }

    /// `cmp left32, right32`.
    pub fn cmpReg32(self: *Masm, left: Reg, right: Reg) error{OutOfMemory}!void {
        try self.emitRegReg32(0x39, left, right);
    }

    /// `cmp left, immediate32`.
    pub fn cmpRegImm32(
        self: *Masm,
        left: Reg,
        immediate: u32,
    ) error{OutOfMemory}!void {
        try self.emitRegImm32(7, left, immediate);
    }

    /// `cmp left32, immediate32`.
    pub fn cmpReg32Imm32(
        self: *Masm,
        left: Reg,
        immediate: u32,
    ) error{OutOfMemory}!void {
        try self.emitByte(rex(false, false, false, isExtended(left)));
        try self.emitByte(0x81);
        try self.emitByte(0xF8 | lowBits(left));
        try self.emitU32(immediate);
    }

    /// `cdq` -- sign-extend eax into edx:eax before a signed divide.
    pub fn signExtendAccumulator32(self: *Masm) error{OutOfMemory}!void {
        try self.emitByte(0x99);
    }

    /// `cqo` -- sign-extend rax into rdx:rax before a signed 64-bit divide.
    pub fn signExtendAccumulator64(self: *Masm) error{OutOfMemory}!void {
        try self.emitByte(0x48);
        try self.emitByte(0x99);
    }

    /// `div source32` -- divide edx:eax by the unsigned source.
    pub fn divReg32(self: *Masm, source: Reg) error{OutOfMemory}!void {
        try self.emitByte(rex(false, false, false, isExtended(source)));
        try self.emitByte(0xF7);
        try self.emitByte(0xF0 | lowBits(source));
    }

    /// `idiv source32` -- divide edx:eax by the signed source.
    pub fn idivReg32(self: *Masm, source: Reg) error{OutOfMemory}!void {
        try self.emitByte(rex(false, false, false, isExtended(source)));
        try self.emitByte(0xF7);
        try self.emitByte(0xF8 | lowBits(source));
    }

    /// `div source` -- divide rdx:rax by the unsigned 64-bit source.
    pub fn divReg64(self: *Masm, source: Reg) error{OutOfMemory}!void {
        try self.emitByte(rex(true, false, false, isExtended(source)));
        try self.emitByte(0xF7);
        try self.emitByte(0xF0 | lowBits(source));
    }

    /// `idiv source` -- divide rdx:rax by the signed 64-bit source.
    pub fn idivReg64(self: *Masm, source: Reg) error{OutOfMemory}!void {
        try self.emitByte(rex(true, false, false, isExtended(source)));
        try self.emitByte(0xF7);
        try self.emitByte(0xF8 | lowBits(source));
    }

    pub fn shlReg32Cl(self: *Masm, destination: Reg) error{OutOfMemory}!void {
        try self.emitShiftByCl(false, 4, destination);
    }

    pub fn shrReg32Cl(self: *Masm, destination: Reg) error{OutOfMemory}!void {
        try self.emitShiftByCl(false, 5, destination);
    }

    pub fn sarReg32Cl(self: *Masm, destination: Reg) error{OutOfMemory}!void {
        try self.emitShiftByCl(false, 7, destination);
    }

    pub fn rolReg32Cl(self: *Masm, destination: Reg) error{OutOfMemory}!void {
        try self.emitShiftByCl(false, 0, destination);
    }

    pub fn rorReg32Cl(self: *Masm, destination: Reg) error{OutOfMemory}!void {
        try self.emitShiftByCl(false, 1, destination);
    }

    pub fn shlReg64Cl(self: *Masm, destination: Reg) error{OutOfMemory}!void {
        try self.emitShiftByCl(true, 4, destination);
    }

    pub fn shrReg64Cl(self: *Masm, destination: Reg) error{OutOfMemory}!void {
        try self.emitShiftByCl(true, 5, destination);
    }

    pub fn sarReg64Cl(self: *Masm, destination: Reg) error{OutOfMemory}!void {
        try self.emitShiftByCl(true, 7, destination);
    }

    pub fn rolReg64Cl(self: *Masm, destination: Reg) error{OutOfMemory}!void {
        try self.emitShiftByCl(true, 0, destination);
    }

    pub fn rorReg64Cl(self: *Masm, destination: Reg) error{OutOfMemory}!void {
        try self.emitShiftByCl(true, 1, destination);
    }

    /// `shl destination, amount`.
    pub fn shlImm8(self: *Masm, destination: Reg, amount: u8) error{OutOfMemory}!void {
        try self.emitByte(rex(true, false, false, isExtended(destination)));
        try self.emitByte(0xC1);
        try self.emitByte(0xE0 | lowBits(destination));
        try self.emitByte(amount);
    }

    /// `shr destination, amount`.
    pub fn shrImm8(self: *Masm, destination: Reg, amount: u8) error{OutOfMemory}!void {
        try self.emitByte(rex(true, false, false, isExtended(destination)));
        try self.emitByte(0xC1);
        try self.emitByte(0xE8 | lowBits(destination));
        try self.emitByte(amount);
    }

    /// Materialize one condition bit and zero-extend it to the full
    /// 32-bit destination without clobbering the flags before SETcc.
    pub fn setCond32(
        self: *Masm,
        destination: Reg,
        condition: Cond,
    ) error{OutOfMemory}!void {
        try self.emitByte(rex(false, false, false, isExtended(destination)));
        try self.emitByte(0x0F);
        try self.emitByte(0x90 | @as(u8, @intFromEnum(condition)));
        try self.emitByte(0xC0 | lowBits(destination));

        try self.emitByte(rex(
            false,
            isExtended(destination),
            false,
            isExtended(destination),
        ));
        try self.emitByte(0x0F);
        try self.emitByte(0xB6);
        try self.emitByte(
            0xC0 | (lowBits(destination) << 3) | lowBits(destination),
        );
    }

    /// `lea destination, [base + displacement]`.
    pub fn leaDisp32(
        self: *Masm,
        destination: Reg,
        base: Reg,
        displacement: i32,
    ) error{OutOfMemory}!void {
        try self.emitByte(rex(
            true,
            isExtended(destination),
            false,
            isExtended(base),
        ));
        try self.emitByte(0x8D);
        try self.emitDisp32ModRm(lowBits(destination), base, displacement);
    }

    /// `mov destination, qword ptr [base + displacement]`.
    ///
    /// The tier entry ABIs pass `CallFrame*` and the raw Lantern register file
    /// in GPRs; accepting any GPR here avoids duplicating ModRM mechanics.
    pub fn load64Disp32(
        self: *Masm,
        destination: Reg,
        base: Reg,
        displacement: i32,
    ) error{OutOfMemory}!void {
        try self.emitByte(rex(true, isExtended(destination), false, isExtended(base)));
        try self.emitByte(0x8B);
        try self.emitDisp32ModRm(lowBits(destination), base, displacement);
    }

    /// `mov destination32, dword ptr [base + displacement]`, zero-extending
    /// the loaded value into the full destination register.
    pub fn load32Disp32(
        self: *Masm,
        destination: Reg,
        base: Reg,
        displacement: i32,
    ) error{OutOfMemory}!void {
        try self.emitByte(rex(false, isExtended(destination), false, isExtended(base)));
        try self.emitByte(0x8B);
        try self.emitDisp32ModRm(lowBits(destination), base, displacement);
    }

    /// `movzx destination32, byte ptr [base + displacement]`.
    pub fn load8Disp32(
        self: *Masm,
        destination: Reg,
        base: Reg,
        displacement: i32,
    ) error{OutOfMemory}!void {
        try self.emitByte(rex(false, isExtended(destination), false, isExtended(base)));
        try self.emitByte(0x0F);
        try self.emitByte(0xB6);
        try self.emitDisp32ModRm(lowBits(destination), base, displacement);
    }

    /// `movzx destination32, word ptr [base + displacement]`.
    pub fn load16Disp32(
        self: *Masm,
        destination: Reg,
        base: Reg,
        displacement: i32,
    ) error{OutOfMemory}!void {
        try self.emitByte(rex(false, isExtended(destination), false, isExtended(base)));
        try self.emitByte(0x0F);
        try self.emitByte(0xB7);
        try self.emitDisp32ModRm(lowBits(destination), base, displacement);
    }

    pub fn load8Signed32Disp32(self: *Masm, destination: Reg, base: Reg, displacement: i32) error{OutOfMemory}!void {
        try self.emitSignExtendingLoad(false, 0xBE, destination, base, displacement);
    }

    pub fn load8Signed64Disp32(self: *Masm, destination: Reg, base: Reg, displacement: i32) error{OutOfMemory}!void {
        try self.emitSignExtendingLoad(true, 0xBE, destination, base, displacement);
    }

    pub fn load16Signed32Disp32(self: *Masm, destination: Reg, base: Reg, displacement: i32) error{OutOfMemory}!void {
        try self.emitSignExtendingLoad(false, 0xBF, destination, base, displacement);
    }

    pub fn load16Signed64Disp32(self: *Masm, destination: Reg, base: Reg, displacement: i32) error{OutOfMemory}!void {
        try self.emitSignExtendingLoad(true, 0xBF, destination, base, displacement);
    }

    /// `movsxd destination, dword ptr [base + displacement]`.
    pub fn load32Signed64Disp32(self: *Masm, destination: Reg, base: Reg, displacement: i32) error{OutOfMemory}!void {
        try self.emitByte(rex(true, isExtended(destination), false, isExtended(base)));
        try self.emitByte(0x63);
        try self.emitDisp32ModRm(lowBits(destination), base, displacement);
    }

    /// `cmp qword ptr [base + displacement], source`.
    pub fn cmp64Disp32Reg(
        self: *Masm,
        base: Reg,
        displacement: i32,
        source: Reg,
    ) error{OutOfMemory}!void {
        try self.emitByte(rex(true, isExtended(source), false, isExtended(base)));
        try self.emitByte(0x39);
        try self.emitDisp32ModRm(lowBits(source), base, displacement);
    }

    /// `cmp dword ptr [base + displacement], immediate`.
    pub fn cmp32Disp32Imm32(
        self: *Masm,
        base: Reg,
        displacement: i32,
        immediate: u32,
    ) error{OutOfMemory}!void {
        try self.emitByte(rex(false, false, false, isExtended(base)));
        try self.emitByte(0x81);
        try self.emitDisp32ModRm(7, base, displacement);
        try self.emitU32(immediate);
    }

    /// `cmp qword ptr [base + displacement], immediate8`.
    pub fn cmp64Disp32Imm8(
        self: *Masm,
        base: Reg,
        displacement: i32,
        immediate: u8,
    ) error{OutOfMemory}!void {
        try self.emitByte(rex(true, false, false, isExtended(base)));
        try self.emitByte(0x83);
        try self.emitDisp32ModRm(7, base, displacement);
        try self.emitByte(immediate);
    }

    /// `cmp byte ptr [base + displacement], immediate8`.
    pub fn cmp8Disp32Imm8(
        self: *Masm,
        base: Reg,
        displacement: i32,
        immediate: u8,
    ) error{OutOfMemory}!void {
        try self.emitByte(rex(false, false, false, isExtended(base)));
        try self.emitByte(0x80);
        try self.emitDisp32ModRm(7, base, displacement);
        try self.emitByte(immediate);
    }

    /// `mov qword ptr [base + displacement], source`.
    pub fn store64Disp32(
        self: *Masm,
        base: Reg,
        displacement: i32,
        source: Reg,
    ) error{OutOfMemory}!void {
        try self.emitByte(rex(true, isExtended(source), false, isExtended(base)));
        try self.emitByte(0x89);
        try self.emitDisp32ModRm(lowBits(source), base, displacement);
    }

    /// `mov dword ptr [base + displacement], source32`.
    pub fn store32Disp32(
        self: *Masm,
        base: Reg,
        displacement: i32,
        source: Reg,
    ) error{OutOfMemory}!void {
        try self.emitByte(rex(false, isExtended(source), false, isExtended(base)));
        try self.emitByte(0x89);
        try self.emitDisp32ModRm(lowBits(source), base, displacement);
    }

    /// `mov byte ptr [base + displacement], source8`.
    pub fn store8Disp32(self: *Masm, base: Reg, displacement: i32, source: Reg) error{OutOfMemory}!void {
        // Always emit a REX prefix: it selects spl/bpl/sil/dil for source
        // registers 4..7 and carries the extension bits for r8..r15.
        try self.emitByte(rex(false, isExtended(source), false, isExtended(base)));
        try self.emitByte(0x88);
        try self.emitDisp32ModRm(lowBits(source), base, displacement);
    }

    /// `mov word ptr [base + displacement], source16`.
    pub fn store16Disp32(self: *Masm, base: Reg, displacement: i32, source: Reg) error{OutOfMemory}!void {
        try self.emitByte(0x66);
        try self.emitByte(rex(false, isExtended(source), false, isExtended(base)));
        try self.emitByte(0x89);
        try self.emitDisp32ModRm(lowBits(source), base, displacement);
    }

    /// `cvtsi2sd destination, source32`.
    pub fn cvtI32ToDouble(self: *Masm, destination: Xmm, source: Reg) error{OutOfMemory}!void {
        try self.emitScalarIntToFloat(0xF2, false, destination, source);
    }

    /// `cvtsi2ss destination, source32`.
    pub fn cvtI32ToFloat(self: *Masm, destination: Xmm, source: Reg) error{OutOfMemory}!void {
        try self.emitScalarIntToFloat(0xF3, false, destination, source);
    }

    /// `cvtsi2ss destination, source64`.
    pub fn cvtI64ToFloat(self: *Masm, destination: Xmm, source: Reg) error{OutOfMemory}!void {
        try self.emitScalarIntToFloat(0xF3, true, destination, source);
    }

    /// `cvtsi2sd destination, source64`.
    pub fn cvtI64ToDouble(self: *Masm, destination: Xmm, source: Reg) error{OutOfMemory}!void {
        try self.emitScalarIntToFloat(0xF2, true, destination, source);
    }

    /// `cvttss2si destination32, source` (round toward zero).
    pub fn cvttFloatToI32(self: *Masm, destination: Reg, source: Xmm) error{OutOfMemory}!void {
        try self.emitScalarFloatToInt(0xF3, false, destination, source);
    }

    /// `cvttss2si destination64, source` (round toward zero).
    pub fn cvttFloatToI64(self: *Masm, destination: Reg, source: Xmm) error{OutOfMemory}!void {
        try self.emitScalarFloatToInt(0xF3, true, destination, source);
    }

    /// `cvttsd2si destination32, source` (round toward zero).
    pub fn cvttDoubleToI32(self: *Masm, destination: Reg, source: Xmm) error{OutOfMemory}!void {
        try self.emitScalarFloatToInt(0xF2, false, destination, source);
    }

    /// `cvttsd2si destination64, source` (round toward zero).
    pub fn cvttDoubleToI64(self: *Masm, destination: Reg, source: Xmm) error{OutOfMemory}!void {
        try self.emitScalarFloatToInt(0xF2, true, destination, source);
    }

    /// `movq destination, source` where destination is an XMM register and
    /// source is a 64-bit GPR.
    pub fn movQXmmFromReg(self: *Masm, destination: Xmm, source: Reg) error{OutOfMemory}!void {
        try self.emitByte(0x66);
        try self.emitByte(rex(true, isExtendedXmm(destination), false, isExtended(source)));
        try self.emitByte(0x0F);
        try self.emitByte(0x6E);
        try self.emitByte(0xC0 | (lowBitsXmm(destination) << 3) | lowBits(source));
    }

    /// `movq destination, source` where destination is a 64-bit GPR and
    /// source is an XMM register.
    pub fn movQRegFromXmm(self: *Masm, destination: Reg, source: Xmm) error{OutOfMemory}!void {
        try self.emitByte(0x66);
        try self.emitByte(rex(true, isExtendedXmm(source), false, isExtended(destination)));
        try self.emitByte(0x0F);
        try self.emitByte(0x7E);
        try self.emitByte(0xC0 | (lowBitsXmm(source) << 3) | lowBits(destination));
    }

    /// `movd destination, source32` where destination is an XMM register.
    pub fn movDXmmFromReg(self: *Masm, destination: Xmm, source: Reg) error{OutOfMemory}!void {
        try self.emitByte(0x66);
        try self.emitByte(rex(false, isExtendedXmm(destination), false, isExtended(source)));
        try self.emitByte(0x0F);
        try self.emitByte(0x6E);
        try self.emitByte(0xC0 | (lowBitsXmm(destination) << 3) | lowBits(source));
    }

    /// `movd destination32, source` where source is an XMM register.
    pub fn movDRegFromXmm(self: *Masm, destination: Reg, source: Xmm) error{OutOfMemory}!void {
        try self.emitByte(0x66);
        try self.emitByte(rex(false, isExtendedXmm(source), false, isExtended(destination)));
        try self.emitByte(0x0F);
        try self.emitByte(0x7E);
        try self.emitByte(0xC0 | (lowBitsXmm(source) << 3) | lowBits(destination));
    }

    pub fn loadVector128(self: *Masm, destination: Xmm, base: Reg, displacement: i32) error{OutOfMemory}!void {
        try self.emitVectorMemory(0x6f, destination, base, displacement);
    }

    pub fn storeVector128(self: *Masm, base: Reg, displacement: i32, source: Xmm) error{OutOfMemory}!void {
        try self.emitVectorMemory(0x7f, source, base, displacement);
    }

    pub fn movVector128(self: *Masm, destination: Xmm, source: Xmm) error{OutOfMemory}!void {
        try self.emitXmmReg(0x66, 0x6f, destination, source);
    }

    pub fn addPackedI16(self: *Masm, destination: Xmm, source: Xmm) error{OutOfMemory}!void {
        try self.addPackedInteger(destination, source, .half);
    }

    pub const PackedAddSize = enum(u8) { byte = 0xfc, half = 0xfd, word = 0xfe, double = 0xd4 };

    pub fn addPackedInteger(self: *Masm, destination: Xmm, source: Xmm, size: PackedAddSize) error{OutOfMemory}!void {
        try self.emitXmmReg(0x66, @intFromEnum(size), destination, source);
    }

    pub fn saturatingAddSubtractPacked128(self: *Masm, destination: Xmm, source: Xmm, halfword: bool, signed: bool, subtract: bool) error{OutOfMemory}!void {
        const base: u8 = if (signed) (if (subtract) 0xe8 else 0xec) else (if (subtract) 0xd8 else 0xdc);
        try self.emitXmmReg(0x66, base + @intFromBool(halfword), destination, source);
    }

    pub fn multiplyLowPackedI16(self: *Masm, destination: Xmm, source: Xmm) error{OutOfMemory}!void {
        try self.emitXmmReg(0x66, 0xd5, destination, source);
    }

    pub fn multiplyHighPacked16(self: *Masm, destination: Xmm, source: Xmm, signed: bool) error{OutOfMemory}!void {
        try self.emitXmmReg(0x66, if (signed) 0xe5 else 0xe4, destination, source);
    }

    pub fn multiplyEvenPackedU32(self: *Masm, destination: Xmm, source: Xmm) error{OutOfMemory}!void {
        try self.emitXmmReg(0x66, 0xf4, destination, source);
    }

    pub const PackedShift = enum(u8) {
        shl16 = 0xf1,
        shl32 = 0xf2,
        shl64 = 0xf3,
        shr16 = 0xd1,
        shr32 = 0xd2,
        shr64 = 0xd3,
        sar16 = 0xe1,
        sar32 = 0xe2,
    };

    /// SSE2 packed shifts read the count from the low 64 bits of source.
    pub fn shiftPackedInteger(self: *Masm, destination: Xmm, source: Xmm, op: PackedShift) error{OutOfMemory}!void {
        try self.emitXmmReg(0x66, @intFromEnum(op), destination, source);
    }

    pub fn subtractPackedI16(self: *Masm, destination: Xmm, source: Xmm) error{OutOfMemory}!void {
        try self.subtractPackedInteger(destination, source, .half);
    }

    pub const PackedSubtractSize = enum(u8) { byte = 0xf8, half = 0xf9, word = 0xfa, double = 0xfb };

    pub fn subtractPackedInteger(self: *Masm, destination: Xmm, source: Xmm, size: PackedSubtractSize) error{OutOfMemory}!void {
        try self.emitXmmReg(0x66, @intFromEnum(size), destination, source);
    }

    pub fn roundingAverageUnsigned128(self: *Masm, destination: Xmm, source: Xmm, halfword: bool) error{OutOfMemory}!void {
        try self.emitXmmReg(0x66, if (halfword) 0xe3 else 0xe0, destination, source);
    }

    pub fn shufflePackedI32(self: *Masm, destination: Xmm, source: Xmm, order: u8) error{OutOfMemory}!void {
        try self.emitXmmReg(0x66, 0x70, destination, source);
        try self.emitByte(order);
    }

    pub fn subtractSaturatingPackedU16(self: *Masm, destination: Xmm, source: Xmm) error{OutOfMemory}!void {
        try self.saturatingAddSubtractPacked128(destination, source, true, false, true);
    }

    pub fn addPackedI32(self: *Masm, destination: Xmm, source: Xmm) error{OutOfMemory}!void {
        try self.addPackedInteger(destination, source, .word);
    }

    pub fn andPacked128(self: *Masm, destination: Xmm, source: Xmm) error{OutOfMemory}!void {
        try self.emitXmmReg(0x66, 0xdb, destination, source);
    }

    pub fn orPacked128(self: *Masm, destination: Xmm, source: Xmm) error{OutOfMemory}!void {
        try self.emitXmmReg(0x66, 0xeb, destination, source);
    }

    pub fn andNotPacked128(self: *Masm, destination: Xmm, source: Xmm) error{OutOfMemory}!void {
        try self.emitXmmReg(0x66, 0xdf, destination, source);
    }

    pub fn minMaxPackedFloat128(self: *Masm, destination: Xmm, source: Xmm, double_precision: bool, maximum: bool) error{OutOfMemory}!void {
        try self.emitXmmReg(if (double_precision) 0x66 else null, if (maximum) 0x5f else 0x5d, destination, source);
    }

    pub const PackedFloatComparison = enum(u8) { eq = 0, lt = 1, le = 2, ne = 4 };

    pub const PackedFloatArithmetic = enum(u8) { add = 0x58, sub = 0x5c, mul = 0x59, div = 0x5e, sqrt = 0x51 };

    pub fn arithmeticPackedFloat128(self: *Masm, destination: Xmm, source: Xmm, double_precision: bool, op: PackedFloatArithmetic) error{OutOfMemory}!void {
        try self.emitXmmReg(if (double_precision) @as(u8, 0x66) else null, @intFromEnum(op), destination, source);
    }

    pub fn comparePackedFloat128(self: *Masm, destination: Xmm, source: Xmm, double_precision: bool, relation: PackedFloatComparison) error{OutOfMemory}!void {
        try self.emitXmmReg(if (double_precision) @as(u8, 0x66) else null, 0xc2, destination, source);
        try self.emitByte(@intFromEnum(relation));
    }

    pub fn compareUnorderedPackedFloat128(self: *Masm, destination: Xmm, source: Xmm, double_precision: bool) error{OutOfMemory}!void {
        try self.emitXmmReg(if (double_precision) 0x66 else null, 0xc2, destination, source);
        try self.emitByte(3); // CMPUNORDPS/PD
    }

    pub fn shiftRightLogicalPacked128(self: *Masm, destination: Xmm, amount: u8, quadword: bool) error{OutOfMemory}!void {
        try self.emitByte(0x66);
        try self.emitByte(rex(false, false, false, isExtendedXmm(destination)));
        try self.emitByte(0x0f);
        try self.emitByte(if (quadword) 0x73 else 0x72);
        try self.emitByte(0xd0 | lowBitsXmm(destination)); // PSRLD/Q /2, imm8
        try self.emitByte(amount);
    }

    pub fn xorPacked128(self: *Masm, destination: Xmm, source: Xmm) error{OutOfMemory}!void {
        try self.emitXmmReg(0x66, 0xef, destination, source);
    }

    pub const PackedIntSize = enum(u8) { byte = 0x74, half = 0x75, word = 0x76 };

    /// PUNPCKLBW/WD/DQ: interleave the low halves, retaining the SSE2 baseline.
    pub fn unpackLowPackedInteger(self: *Masm, destination: Xmm, source: Xmm, size: PackedIntSize) error{OutOfMemory}!void {
        const opcode: u8 = switch (size) {
            .byte => 0x60,
            .half => 0x61,
            .word => 0x62,
        };
        try self.emitXmmReg(0x66, opcode, destination, source);
    }

    pub fn compareEqualPacked(self: *Masm, destination: Xmm, source: Xmm, size: PackedIntSize) error{OutOfMemory}!void {
        try self.emitXmmReg(0x66, @intFromEnum(size), destination, source);
    }

    pub fn unpackHighPackedInteger(self: *Masm, destination: Xmm, source: Xmm, size: PackedIntSize) error{OutOfMemory}!void {
        try self.emitXmmReg(0x66, switch (size) {
            .byte => 0x68,
            .half => 0x69,
            .word => 0x6a,
        }, destination, source);
    }

    pub fn compareGreaterSignedPacked(self: *Masm, destination: Xmm, source: Xmm, size: PackedIntSize) error{OutOfMemory}!void {
        try self.emitXmmReg(0x66, switch (size) {
            .byte => 0x64,
            .half => 0x65,
            .word => 0x66,
        }, destination, source);
    }

    pub const PackedMinMax = enum(u8) { min_u8 = 0xda, max_u8 = 0xde, min_i16 = 0xea, max_i16 = 0xee };

    /// The four min/max instructions available without SSE4.1.
    pub fn minMaxPacked128(self: *Masm, destination: Xmm, source: Xmm, op: PackedMinMax) error{OutOfMemory}!void {
        try self.emitXmmReg(0x66, @intFromEnum(op), destination, source);
    }

    pub fn shiftRightArithmeticPackedI32(self: *Masm, destination: Xmm, amount: u8) error{OutOfMemory}!void {
        try self.emitByte(0x66);
        try self.emitByte(rex(false, false, false, isExtendedXmm(destination)));
        try self.emitByte(0x0f);
        try self.emitByte(0x72);
        try self.emitByte(0xe0 | lowBitsXmm(destination)); // PSRAD /4, imm8
        try self.emitByte(amount);
    }

    pub fn packSigned16To8(self: *Masm, destination: Xmm, source: Xmm) error{OutOfMemory}!void {
        try self.emitXmmReg(0x66, 0x63, destination, source);
    }

    pub fn packUnsigned16To8(self: *Masm, destination: Xmm, source: Xmm) error{OutOfMemory}!void {
        try self.emitXmmReg(0x66, 0x67, destination, source);
    }

    pub fn packSigned32To16(self: *Masm, destination: Xmm, source: Xmm) error{OutOfMemory}!void {
        try self.emitXmmReg(0x66, 0x6b, destination, source);
    }

    pub fn multiplyAddPackedI16(self: *Masm, destination: Xmm, source: Xmm) error{OutOfMemory}!void {
        try self.emitXmmReg(0x66, 0xf5, destination, source);
    }

    pub fn movByteMask(self: *Masm, destination: Reg, source: Xmm) error{OutOfMemory}!void {
        try self.emitVectorMask(0x66, 0xd7, destination, source);
    }

    pub fn movFloatMask(self: *Masm, destination: Reg, source: Xmm) error{OutOfMemory}!void {
        try self.emitVectorMask(null, 0x50, destination, source);
    }

    pub fn movDoubleMask(self: *Masm, destination: Reg, source: Xmm) error{OutOfMemory}!void {
        try self.emitVectorMask(0x66, 0x50, destination, source);
    }

    fn emitVectorMask(self: *Masm, prefix: ?u8, opcode: u8, destination: Reg, source: Xmm) error{OutOfMemory}!void {
        if (prefix) |byte| try self.emitByte(byte);
        try self.emitByte(rex(false, isExtended(destination), false, isExtendedXmm(source)));
        try self.emitByte(0x0f);
        try self.emitByte(opcode);
        try self.emitByte(0xc0 | (lowBits(destination) << 3) | lowBitsXmm(source));
    }

    fn emitVectorMemory(self: *Masm, opcode: u8, vector: Xmm, base: Reg, displacement: i32) error{OutOfMemory}!void {
        // SSE2 MOVDQU accepts unaligned linear-memory and Cell addresses.
        try self.emitByte(0xf3);
        try self.emitByte(rex(false, isExtendedXmm(vector), false, isExtended(base)));
        try self.emitByte(0x0f);
        try self.emitByte(opcode);
        try self.emitDisp32ModRm(lowBitsXmm(vector), base, displacement);
    }

    pub fn addFloat(self: *Masm, destination: Xmm, source: Xmm) error{OutOfMemory}!void {
        try self.emitXmmReg(0xF3, 0x58, destination, source);
    }

    pub fn subFloat(self: *Masm, destination: Xmm, source: Xmm) error{OutOfMemory}!void {
        try self.emitXmmReg(0xF3, 0x5C, destination, source);
    }

    pub fn mulFloat(self: *Masm, destination: Xmm, source: Xmm) error{OutOfMemory}!void {
        try self.emitXmmReg(0xF3, 0x59, destination, source);
    }

    pub fn divFloat(self: *Masm, destination: Xmm, source: Xmm) error{OutOfMemory}!void {
        try self.emitXmmReg(0xF3, 0x5E, destination, source);
    }

    pub fn sqrtFloat(self: *Masm, destination: Xmm, source: Xmm) error{OutOfMemory}!void {
        try self.emitXmmReg(0xF3, 0x51, destination, source);
    }

    pub fn addDouble(self: *Masm, destination: Xmm, source: Xmm) error{OutOfMemory}!void {
        try self.emitXmmReg(0xF2, 0x58, destination, source);
    }

    pub fn subDouble(self: *Masm, destination: Xmm, source: Xmm) error{OutOfMemory}!void {
        try self.emitXmmReg(0xF2, 0x5C, destination, source);
    }

    pub fn mulDouble(self: *Masm, destination: Xmm, source: Xmm) error{OutOfMemory}!void {
        try self.emitXmmReg(0xF2, 0x59, destination, source);
    }

    pub fn divDouble(self: *Masm, destination: Xmm, source: Xmm) error{OutOfMemory}!void {
        try self.emitXmmReg(0xF2, 0x5E, destination, source);
    }

    pub fn sqrtDouble(self: *Masm, destination: Xmm, source: Xmm) error{OutOfMemory}!void {
        try self.emitXmmReg(0xF2, 0x51, destination, source);
    }

    /// `cvtss2sd destination, source`.
    pub fn cvtFloatToDouble(self: *Masm, destination: Xmm, source: Xmm) error{OutOfMemory}!void {
        try self.emitXmmReg(0xF3, 0x5A, destination, source);
    }

    /// `cvtsd2ss destination, source`.
    pub fn cvtDoubleToFloat(self: *Masm, destination: Xmm, source: Xmm) error{OutOfMemory}!void {
        try self.emitXmmReg(0xF2, 0x5A, destination, source);
    }

    /// `ucomisd left, right`; PF reports an unordered (NaN) comparison.
    pub fn ucomisDouble(self: *Masm, left: Xmm, right: Xmm) error{OutOfMemory}!void {
        try self.emitXmmReg(0x66, 0x2E, left, right);
    }

    /// `ucomiss left, right`; PF reports an unordered (NaN) comparison.
    pub fn ucomisFloat(self: *Masm, left: Xmm, right: Xmm) error{OutOfMemory}!void {
        try self.emitByte(rex(false, isExtendedXmm(left), false, isExtendedXmm(right)));
        try self.emitByte(0x0F);
        try self.emitByte(0x2E);
        try self.emitByte(0xC0 | (lowBitsXmm(left) << 3) | lowBitsXmm(right));
    }

    /// `call target`.
    pub fn callReg(self: *Masm, target: Reg) error{OutOfMemory}!void {
        try self.emitByte(rex(false, false, false, isExtended(target)));
        try self.emitByte(0xFF);
        try self.emitByte(0xD0 | lowBits(target));
    }

    /// `call rel32` to a local label.
    pub fn call(self: *Masm, label: *Label) !void {
        try self.emitByte(0xE8);
        try self.emitBranchDisplacement(label);
    }

    /// `jmp target`.
    pub fn jumpReg(self: *Masm, target: Reg) error{OutOfMemory}!void {
        try self.emitByte(rex(false, false, false, isExtended(target)));
        try self.emitByte(0xFF);
        try self.emitByte(0xE0 | lowBits(target));
    }

    pub fn ret(self: *Masm) error{OutOfMemory}!void {
        try self.emitByte(0xC3);
    }

    pub const Label = struct {
        bound: ?usize = null,
        fixups: std.ArrayListUnmanaged(usize) = .empty,

        pub fn deinit(self: *Label, gpa: std.mem.Allocator) void {
            self.fixups.deinit(gpa);
            self.* = undefined;
        }
    };

    /// Bind every recorded near-relative branch to this code position.
    pub fn bind(self: *Masm, label: *Label) !void {
        if (label.bound != null) return error.LabelAlreadyBound;
        const target = self.code.items.len;
        // Validate every fixup before changing code or publishing the label.
        // A malformed or out-of-range branch must leave a fully retryable,
        // unbound label so the owning tier can refuse compilation cleanly.
        for (label.fixups.items) |at| _ = try self.rel32Displacement(at, target);
        for (label.fixups.items) |at| try self.patchRel32(at, target);
        label.bound = target;
        label.fixups.clearRetainingCapacity();
    }

    /// `jmp rel32`.
    pub fn jump(self: *Masm, label: *Label) !void {
        try self.emitByte(0xE9);
        try self.emitBranchDisplacement(label);
    }

    /// `jcc rel32`.
    pub fn jumpCond(self: *Masm, condition: Cond, label: *Label) !void {
        try self.emitByte(0x0F);
        try self.emitByte(@as(u8, 0x80) | @as(u8, @intFromEnum(condition)));
        try self.emitBranchDisplacement(label);
    }

    pub fn install(self: *Masm, allocator: *code_alloc.CodeAllocator) code_alloc.Error![]const u8 {
        return allocator.install(self.code.items);
    }

    fn emitByte(self: *Masm, byte: u8) error{OutOfMemory}!void {
        try self.code.append(self.gpa, byte);
    }

    fn emitRegReg(self: *Masm, opcode: u8, destination: Reg, source: Reg) error{OutOfMemory}!void {
        try self.emitByte(rex(true, isExtended(source), false, isExtended(destination)));
        try self.emitByte(opcode);
        try self.emitByte(0xC0 | (lowBits(source) << 3) | lowBits(destination));
    }

    fn emitRegReg32(
        self: *Masm,
        opcode: u8,
        destination: Reg,
        source: Reg,
    ) error{OutOfMemory}!void {
        try self.emitByte(rex(false, isExtended(source), false, isExtended(destination)));
        try self.emitByte(opcode);
        try self.emitByte(0xC0 | (lowBits(source) << 3) | lowBits(destination));
    }

    fn emitBitScan(
        self: *Masm,
        wide: bool,
        opcode: u8,
        destination: Reg,
        source: Reg,
    ) error{OutOfMemory}!void {
        try self.emitByte(rex(wide, isExtended(destination), false, isExtended(source)));
        try self.emitByte(0x0F);
        try self.emitByte(opcode);
        try self.emitByte(0xC0 | (lowBits(destination) << 3) | lowBits(source));
    }

    fn emitRegImm32(
        self: *Masm,
        operation: u3,
        destination: Reg,
        immediate: u32,
    ) error{OutOfMemory}!void {
        try self.emitByte(rex(true, false, false, isExtended(destination)));
        try self.emitByte(0x81);
        try self.emitByte(0xC0 | (@as(u8, operation) << 3) | lowBits(destination));
        try self.emitU32(immediate);
    }

    fn emitShiftByCl(self: *Masm, width64: bool, operation: u3, destination: Reg) error{OutOfMemory}!void {
        try self.emitByte(rex(width64, false, false, isExtended(destination)));
        try self.emitByte(0xD3);
        try self.emitByte(0xC0 | (@as(u8, operation) << 3) | lowBits(destination));
    }

    fn emitSignExtendingLoad(
        self: *Masm,
        width64: bool,
        opcode: u8,
        destination: Reg,
        base: Reg,
        displacement: i32,
    ) error{OutOfMemory}!void {
        try self.emitByte(rex(width64, isExtended(destination), false, isExtended(base)));
        try self.emitByte(0x0F);
        try self.emitByte(opcode);
        try self.emitDisp32ModRm(lowBits(destination), base, displacement);
    }

    fn emitDisp32ModRm(
        self: *Masm,
        reg_field: u8,
        base: Reg,
        displacement: i32,
    ) error{OutOfMemory}!void {
        std.debug.assert(reg_field < 8);
        try self.emitByte(0x80 | (reg_field << 3) | lowBits(base));
        // ModRM r/m=100 selects a SIB byte rather than rsp/r12 directly.
        if (lowBits(base) == 4) try self.emitByte(0x24);
        try self.emitI32(displacement);
    }

    fn emitXmmReg(
        self: *Masm,
        prefix: ?u8,
        opcode: u8,
        destination: Xmm,
        source: Xmm,
    ) error{OutOfMemory}!void {
        if (prefix) |byte| try self.emitByte(byte);
        try self.emitByte(rex(false, isExtendedXmm(destination), false, isExtendedXmm(source)));
        try self.emitByte(0x0F);
        try self.emitByte(opcode);
        try self.emitByte(0xC0 | (lowBitsXmm(destination) << 3) | lowBitsXmm(source));
    }

    fn emitScalarIntToFloat(
        self: *Masm,
        prefix: u8,
        source64: bool,
        destination: Xmm,
        source: Reg,
    ) error{OutOfMemory}!void {
        try self.emitByte(prefix);
        try self.emitByte(rex(source64, isExtendedXmm(destination), false, isExtended(source)));
        try self.emitByte(0x0F);
        try self.emitByte(0x2A);
        try self.emitByte(0xC0 | (lowBitsXmm(destination) << 3) | lowBits(source));
    }

    fn emitScalarFloatToInt(
        self: *Masm,
        prefix: u8,
        destination64: bool,
        destination: Reg,
        source: Xmm,
    ) error{OutOfMemory}!void {
        try self.emitByte(prefix);
        try self.emitByte(rex(destination64, isExtended(destination), false, isExtendedXmm(source)));
        try self.emitByte(0x0F);
        try self.emitByte(0x2C);
        try self.emitByte(0xC0 | (lowBits(destination) << 3) | lowBitsXmm(source));
    }

    fn emitBranchDisplacement(self: *Masm, label: *Label) !void {
        const at = self.code.items.len;
        try self.emitI32(0);
        if (label.bound) |target| {
            try self.patchRel32(at, target);
        } else {
            try label.fixups.append(self.gpa, at);
        }
    }

    fn patchRel32(self: *Masm, at: usize, target: usize) !void {
        const displacement = try self.rel32Displacement(at, target);
        std.mem.writeInt(u32, self.code.items[at..][0..4], @bitCast(displacement), .little);
    }

    fn rel32Displacement(self: *const Masm, at: usize, target: usize) !i32 {
        if (at > self.code.items.len or 4 > self.code.items.len - at) {
            return error.InvalidLabel;
        }
        const delta: i128 = @as(i128, @intCast(target)) - @as(i128, @intCast(at + 4));
        return std.math.cast(i32, delta) orelse error.BranchOutOfRange;
    }

    fn emitI32(self: *Masm, value: i32) error{OutOfMemory}!void {
        var bytes: [4]u8 = undefined;
        std.mem.writeInt(u32, &bytes, @bitCast(value), .little);
        try self.code.appendSlice(self.gpa, &bytes);
    }

    fn emitU32(self: *Masm, value: u32) error{OutOfMemory}!void {
        var bytes: [4]u8 = undefined;
        std.mem.writeInt(u32, &bytes, value, .little);
        try self.code.appendSlice(self.gpa, &bytes);
    }

    fn emitU64(self: *Masm, value: u64) error{OutOfMemory}!void {
        var bytes: [8]u8 = undefined;
        std.mem.writeInt(u64, &bytes, value, .little);
        try self.code.appendSlice(self.gpa, &bytes);
    }
};

fn rex(w: bool, r: bool, x: bool, b: bool) u8 {
    return 0x40 |
        (@as(u8, @intFromBool(w)) << 3) |
        (@as(u8, @intFromBool(r)) << 2) |
        (@as(u8, @intFromBool(x)) << 1) |
        @as(u8, @intFromBool(b));
}

fn isExtended(register: Reg) bool {
    return @intFromEnum(register) >= 8;
}

fn lowBits(register: Reg) u8 {
    return @intFromEnum(register) & 7;
}

fn isExtendedXmm(register: Xmm) bool {
    return @intFromEnum(register) >= 8;
}

fn lowBitsXmm(register: Xmm) u8 {
    return @intFromEnum(register) & 7;
}
test "jit asm_x86_64: emits a native immediate return" {
    if (comptime !native_x86_64) return error.SkipZigTest;
    var machine = Masm.init(std.testing.allocator);
    defer machine.deinit();
    try machine.movImm64(.rax, 42);
    try machine.ret();

    var executable = try code_alloc.CodeAllocator.init(std.testing.allocator, 64 * 1024);
    defer executable.deinit();
    const entry = code_alloc.asFn(
        *const fn () callconv(.c) u64,
        try machine.install(&executable),
    );
    try std.testing.expectEqual(@as(u64, 42), entry());
}

test "jit asm_x86_64: encodes property-load integer primitives" {
    var machine = Masm.init(std.testing.allocator);
    defer machine.deinit();
    try machine.andReg64(.r8, .r11);
    try machine.xorReg64(.r10, .r11);
    try machine.testReg64(.r10, .r11);
    try machine.load32Disp32(.r10, .r9, 0x1234);
    try machine.load8Disp32(.r10, .r9, 0x5678);
    try machine.cmp64Disp32Reg(.r9, 0x1234, .r10);
    try machine.cmp32Disp32Imm32(.r9, 0x1234, 0x7654_3210);
    try machine.cmp64Disp32Imm8(.r9, 0x1234, 0);
    try machine.cmp8Disp32Imm8(.r9, 0x1234, 1);
    try std.testing.expectEqualSlices(u8, &.{
        0x4D, 0x21, 0xD8,
        0x4D, 0x31, 0xDA,
        0x4D, 0x85, 0xDA,
        0x45, 0x8B, 0x91,
        0x34, 0x12, 0x00,
        0x00, 0x45, 0x0F,
        0xB6, 0x91, 0x78,
        0x56, 0x00, 0x00,
        0x4D, 0x39, 0x91,
        0x34, 0x12, 0x00,
        0x00, 0x41, 0x81,
        0xB9, 0x34, 0x12,
        0x00, 0x00, 0x10,
        0x32, 0x54, 0x76,
        0x49, 0x83, 0xB9,
        0x34, 0x12, 0x00,
        0x00, 0x00, 0x41,
        0x80, 0xB9, 0x34,
        0x12, 0x00, 0x00,
        0x01,
    }, machine.code.items);
}

test "jit asm_x86_64: encodes checked loop arithmetic and spill primitives" {
    var machine = Masm.init(std.testing.allocator);
    defer machine.deinit();
    try machine.movReg32(.r11, .r8);
    try machine.addReg32(.r8, .r9);
    try machine.subReg32(.r10, .r8);
    try machine.imulReg32(.r9, .r10);
    try machine.xorReg32(.r11, .r9);
    try machine.cmpReg32(.r8, .r10);
    try machine.cmpRegImm32(.r11, 0x7FF9);
    try machine.testReg32Imm32(.r10, 0x8000_0000);
    try machine.orReg64(.r8, .r9);
    try machine.store32Disp32(.rsi, 0x1234, .r9);
    try machine.subRegImm32(.rsp, 32);
    try machine.addRegImm32(.rsp, 32);
    try std.testing.expectEqualSlices(u8, &.{
        0x45, 0x89, 0xC3,
        0x45, 0x01, 0xC8,
        0x45, 0x29, 0xC2,
        0x45, 0x0F, 0xAF,
        0xCA, 0x45, 0x31,
        0xCB, 0x45, 0x39,
        0xD0, 0x49, 0x81,
        0xFB, 0xF9, 0x7F,
        0x00, 0x00, 0x41,
        0xF7, 0xC2, 0x00,
        0x00, 0x00, 0x80,
        0x4D, 0x09, 0xC8,
        0x44, 0x89, 0x8E,
        0x34, 0x12, 0x00,
        0x00, 0x48, 0x81,
        0xEC, 0x20, 0x00,
        0x00, 0x00, 0x48,
        0x81, 0xC4, 0x20,
        0x00, 0x00, 0x00,
    }, machine.code.items);
}

test "jit asm_x86_64: encodes i64 division, narrow memory, and CL shifts" {
    var machine = Masm.init(std.testing.allocator);
    defer machine.deinit();

    try machine.signExtendAccumulator64();
    try machine.idivReg64(.r9);
    try machine.divReg64(.r10);
    try machine.load16Disp32(.r10, .r9, 0x1234);
    try machine.load8Signed32Disp32(.r10, .r9, 0x1234);
    try machine.load8Signed64Disp32(.r10, .r9, 0x1234);
    try machine.load16Signed32Disp32(.r10, .r9, 0x1234);
    try machine.load16Signed64Disp32(.r10, .r9, 0x1234);
    try machine.load32Signed64Disp32(.r10, .r9, 0x1234);
    try machine.store8Disp32(.r9, 0x1234, .r10);
    try machine.store16Disp32(.r9, 0x1234, .r10);
    try machine.shlReg64Cl(.r10);
    try machine.sarReg64Cl(.r10);
    try machine.rolReg64Cl(.r10);
    try machine.shrReg32Cl(.r10);

    try std.testing.expectEqualSlices(u8, &.{
        0x48, 0x99,
        0x49, 0xF7,
        0xF9, 0x49,
        0xF7, 0xF2,
        0x45, 0x0F,
        0xB7, 0x91,
        0x34, 0x12,
        0x00, 0x00,
        0x45, 0x0F,
        0xBE, 0x91,
        0x34, 0x12,
        0x00, 0x00,
        0x4D, 0x0F,
        0xBE, 0x91,
        0x34, 0x12,
        0x00, 0x00,
        0x45, 0x0F,
        0xBF, 0x91,
        0x34, 0x12,
        0x00, 0x00,
        0x4D, 0x0F,
        0xBF, 0x91,
        0x34, 0x12,
        0x00, 0x00,
        0x4D, 0x63,
        0x91, 0x34,
        0x12, 0x00,
        0x00, 0x45,
        0x88, 0x91,
        0x34, 0x12,
        0x00, 0x00,
        0x66, 0x45,
        0x89, 0x91,
        0x34, 0x12,
        0x00, 0x00,
        0x49, 0xD3,
        0xE2, 0x49,
        0xD3, 0xFA,
        0x49, 0xD3,
        0xC2, 0x41,
        0xD3, 0xEA,
    }, machine.code.items);
}

test "jit asm_x86_64: encodes unaligned SIMD moves and packed i32 addition" {
    var machine = Masm.init(std.testing.allocator);
    defer machine.deinit();
    try machine.loadVector128(.xmm9, .r12, 16);
    try machine.addPackedI32(.xmm9, .xmm10);
    try machine.storeVector128(.r13, -16, .xmm9);
    try std.testing.expectEqualSlices(u8, &.{
        0xf3, 0x45, 0x0f, 0x6f, 0x8c, 0x24, 0x10, 0,    0,    0,
        0x66, 0x45, 0x0f, 0xfe, 0xca, 0xf3, 0x45, 0x0f, 0x7f, 0x8d,
        0xf0, 0xff, 0xff, 0xff,
    }, machine.code.items);
}

test "jit asm_x86_64: SIMD comparison encodings retain SSE2" {
    var machine = Masm.init(std.testing.allocator);
    defer machine.deinit();
    for ([_]bool{ false, true }) |double| {
        for ([_]Masm.PackedFloatComparison{ .eq, .lt, .le, .ne }) |relation| try machine.comparePackedFloat128(.xmm9, .xmm10, double, relation);
    }
    try std.testing.expectEqualSlices(u8, &.{
        0x45, 0x0f, 0xc2, 0xca, 0x00,
        0x45, 0x0f, 0xc2, 0xca, 0x01,
        0x45, 0x0f, 0xc2, 0xca, 0x02,
        0x45, 0x0f, 0xc2, 0xca, 0x04,
        0x66, 0x45, 0x0f, 0xc2, 0xca,
        0x00, 0x66, 0x45, 0x0f, 0xc2,
        0xca, 0x01, 0x66, 0x45, 0x0f,
        0xc2, 0xca, 0x02, 0x66, 0x45,
        0x0f, 0xc2, 0xca, 0x04,
    }, machine.code.items);
}

test "jit asm_x86_64: SIMD widening encodings retain SSE2" {
    var machine = Masm.init(std.testing.allocator);
    defer machine.deinit();
    try machine.unpackLowPackedInteger(.xmm9, .xmm10, .byte);
    try machine.unpackLowPackedInteger(.xmm9, .xmm10, .half);
    try machine.unpackLowPackedInteger(.xmm9, .xmm10, .word);
    try std.testing.expectEqualSlices(u8, &.{
        0x66, 0x45, 0x0f, 0x60, 0xca,
        0x66, 0x45, 0x0f, 0x61, 0xca,
        0x66, 0x45, 0x0f, 0x62, 0xca,
    }, machine.code.items);
}

test "jit asm_x86_64: SIMD product encodings retain SSE2" {
    var m = Masm.init(std.testing.allocator);
    defer m.deinit();
    try m.multiplyHighPacked16(.xmm9, .xmm11, true);
    try m.multiplyHighPacked16(.xmm9, .xmm11, false);
    try std.testing.expectEqualSlices(u8, &.{
        0x66, 0x45, 0x0f, 0xe5, 0xcb,
        0x66, 0x45, 0x0f, 0xe4, 0xcb,
    }, m.code.items);
}

test "jit asm_x86_64: SIMD lane conversion encodings retain SSE2" {
    var m = Masm.init(std.testing.allocator);
    defer m.deinit();
    try m.packUnsigned16To8(.xmm9, .xmm11);
    try m.packSigned32To16(.xmm9, .xmm11);
    try m.multiplyAddPackedI16(.xmm9, .xmm11);
    try std.testing.expectEqualSlices(u8, &.{
        0x66, 0x45, 0x0f, 0x67, 0xcb,
        0x66, 0x45, 0x0f, 0x6b, 0xcb,
        0x66, 0x45, 0x0f, 0xf5, 0xcb,
    }, m.code.items);
}

test "jit asm_x86_64: SIMD packed float arithmetic encodings retain SSE2" {
    var m = Masm.init(std.testing.allocator);
    defer m.deinit();
    for ([_]bool{ false, true }) |double_precision| {
        for ([_]Masm.PackedFloatArithmetic{ .add, .sub, .mul, .div, .sqrt }) |op|
            try m.arithmeticPackedFloat128(.xmm9, .xmm11, double_precision, op);
    }
    try std.testing.expectEqualSlices(u8, &.{
        0x45, 0x0f, 0x58, 0xcb, 0x45, 0x0f, 0x5c, 0xcb,
        0x45, 0x0f, 0x59, 0xcb, 0x45, 0x0f, 0x5e, 0xcb,
        0x45, 0x0f, 0x51, 0xcb, 0x66, 0x45, 0x0f, 0x58,
        0xcb, 0x66, 0x45, 0x0f, 0x5c, 0xcb, 0x66, 0x45,
        0x0f, 0x59, 0xcb, 0x66, 0x45, 0x0f, 0x5e, 0xcb,
        0x66, 0x45, 0x0f, 0x51, 0xcb,
    }, m.code.items);
}

test "jit asm_x86_64: SIMD float minmax encodings retain SSE2" {
    var machine = Masm.init(std.testing.allocator);
    defer machine.deinit();
    try machine.minMaxPackedFloat128(.xmm9, .xmm10, false, false);
    try machine.minMaxPackedFloat128(.xmm9, .xmm10, false, true);
    try machine.minMaxPackedFloat128(.xmm9, .xmm10, true, false);
    try machine.minMaxPackedFloat128(.xmm9, .xmm10, true, true);
    try machine.compareUnorderedPackedFloat128(.xmm9, .xmm10, false);
    try machine.compareUnorderedPackedFloat128(.xmm9, .xmm10, true);
    try machine.orPacked128(.xmm9, .xmm10);
    try machine.andNotPacked128(.xmm9, .xmm10);
    try machine.shiftRightLogicalPacked128(.xmm10, 10, false);
    try machine.shiftRightLogicalPacked128(.xmm10, 13, true);
    try std.testing.expectEqualSlices(u8, &.{
        0x45, 0x0f, 0x5d, 0xca,
        0x45, 0x0f, 0x5f, 0xca,
        0x66, 0x45, 0x0f, 0x5d,
        0xca, 0x66, 0x45, 0x0f,
        0x5f, 0xca, 0x45, 0x0f,
        0xc2, 0xca, 0x03, 0x66,
        0x45, 0x0f, 0xc2, 0xca,
        0x03, 0x66, 0x45, 0x0f,
        0xeb, 0xca, 0x66, 0x45,
        0x0f, 0xdf, 0xca, 0x66,
        0x41, 0x0f, 0x72, 0xd2,
        0x0a, 0x66, 0x41, 0x0f,
        0x73, 0xd2, 0x0d,
    }, machine.code.items);
}

test "jit asm_x86_64: SIMD integer arithmetic and shift encodings retain SSE2" {
    var m = Masm.init(std.testing.allocator);
    defer m.deinit();
    for ([_]Masm.PackedAddSize{ .byte, .half, .word, .double }) |size|
        try m.addPackedInteger(.xmm9, .xmm11, size);
    for ([_]bool{ false, true }) |subtract| {
        for ([_]bool{ false, true }) |halfword| {
            for ([_]bool{ true, false }) |signed|
                try m.saturatingAddSubtractPacked128(.xmm9, .xmm11, halfword, signed, subtract);
        }
    }
    try m.multiplyLowPackedI16(.xmm9, .xmm11);
    try m.multiplyEvenPackedU32(.xmm9, .xmm11);
    for ([_]Masm.PackedIntSize{ .byte, .half, .word }) |size|
        try m.unpackHighPackedInteger(.xmm9, .xmm11, size);
    for ([_]Masm.PackedShift{ .shl16, .shl32, .shl64, .shr16, .shr32, .shr64, .sar16, .sar32 }) |op|
        try m.shiftPackedInteger(.xmm9, .xmm11, op);
    // clang's bytes for the corresponding SSE2 instructions, using high XMMs.
    const opcodes = [_]u8{ 0xfc, 0xfd, 0xfe, 0xd4, 0xec, 0xdc, 0xed, 0xdd, 0xe8, 0xd8, 0xe9, 0xd9, 0xd5, 0xf4, 0x68, 0x69, 0x6a, 0xf1, 0xf2, 0xf3, 0xd1, 0xd2, 0xd3, 0xe1, 0xe2 };
    try std.testing.expectEqual(opcodes.len * 5, m.code.items.len);
    for (opcodes, 0..) |op, index|
        try std.testing.expectEqualSlices(u8, &.{ 0x66, 0x45, 0x0f, op, 0xcb }, m.code.items[index * 5 ..][0..5]);
}

test "jit asm_x86_64: SIMD integer unary and average encodings retain SSE2" {
    var machine = Masm.init(std.testing.allocator);
    defer machine.deinit();
    try machine.subtractPackedInteger(.xmm9, .xmm10, .byte);
    try machine.subtractPackedInteger(.xmm9, .xmm10, .half);
    try machine.subtractPackedInteger(.xmm9, .xmm10, .word);
    try machine.subtractPackedInteger(.xmm9, .xmm10, .double);
    try machine.roundingAverageUnsigned128(.xmm9, .xmm10, false);
    try machine.roundingAverageUnsigned128(.xmm9, .xmm10, true);
    try machine.shufflePackedI32(.xmm9, .xmm10, 0xf5);
    try std.testing.expectEqualSlices(u8, &.{
        0x66, 0x45, 0x0f, 0xf8, 0xca,
        0x66, 0x45, 0x0f, 0xf9, 0xca,
        0x66, 0x45, 0x0f, 0xfa, 0xca,
        0x66, 0x45, 0x0f, 0xfb, 0xca,
        0x66, 0x45, 0x0f, 0xe0, 0xca,
        0x66, 0x45, 0x0f, 0xe3, 0xca,
        0x66, 0x45, 0x0f, 0x70, 0xca,
        0xf5,
    }, machine.code.items);
}

test "jit asm_x86_64: SIMD integer minmax encodings retain SSE2" {
    var machine = Masm.init(std.testing.allocator);
    defer machine.deinit();
    try machine.movVector128(.xmm9, .xmm10);
    try machine.andPacked128(.xmm9, .xmm10);
    try machine.compareGreaterSignedPacked(.xmm9, .xmm10, .byte);
    try machine.compareGreaterSignedPacked(.xmm9, .xmm10, .half);
    try machine.compareGreaterSignedPacked(.xmm9, .xmm10, .word);
    try machine.minMaxPacked128(.xmm9, .xmm10, .min_u8);
    try machine.minMaxPacked128(.xmm9, .xmm10, .max_u8);
    try machine.minMaxPacked128(.xmm9, .xmm10, .min_i16);
    try machine.minMaxPacked128(.xmm9, .xmm10, .max_i16);
    try machine.subtractSaturatingPackedU16(.xmm9, .xmm10);
    try machine.subtractPackedI16(.xmm9, .xmm10);
    try machine.addPackedI16(.xmm9, .xmm10);
    try machine.shiftRightArithmeticPackedI32(.xmm10, 31);
    try std.testing.expectEqualSlices(u8, &.{
        0x66, 0x45, 0x0f, 0x6f, 0xca,
        0x66, 0x45, 0x0f, 0xdb, 0xca,
        0x66, 0x45, 0x0f, 0x64, 0xca,
        0x66, 0x45, 0x0f, 0x65, 0xca,
        0x66, 0x45, 0x0f, 0x66, 0xca,
        0x66, 0x45, 0x0f, 0xda, 0xca,
        0x66, 0x45, 0x0f, 0xde, 0xca,
        0x66, 0x45, 0x0f, 0xea, 0xca,
        0x66, 0x45, 0x0f, 0xee, 0xca,
        0x66, 0x45, 0x0f, 0xd9, 0xca,
        0x66, 0x45, 0x0f, 0xf9, 0xca,
        0x66, 0x45, 0x0f, 0xfd, 0xca,
        0x66, 0x41, 0x0f, 0x72, 0xe2,
        0x1f,
    }, machine.code.items);
}

test "jit asm_x86_64: SIMD reduction encodings retain SSE2" {
    var machine = Masm.init(std.testing.allocator);
    defer machine.deinit();
    try machine.xorPacked128(.xmm9, .xmm10);
    try machine.compareEqualPacked(.xmm9, .xmm10, .byte);
    try machine.compareEqualPacked(.xmm9, .xmm10, .half);
    try machine.compareEqualPacked(.xmm9, .xmm10, .word);
    try machine.packSigned16To8(.xmm9, .xmm10);
    try machine.movByteMask(.r9, .xmm10);
    try machine.movFloatMask(.r9, .xmm10);
    try machine.movDoubleMask(.r9, .xmm10);
    try std.testing.expectEqualSlices(u8, &.{
        0x66, 0x45, 0x0f, 0xef, 0xca,
        0x66, 0x45, 0x0f, 0x74, 0xca,
        0x66, 0x45, 0x0f, 0x75, 0xca,
        0x66, 0x45, 0x0f, 0x76, 0xca,
        0x66, 0x45, 0x0f, 0x63, 0xca,
        0x66, 0x45, 0x0f, 0xd7, 0xca,
        0x45, 0x0f, 0x50, 0xca, 0x66,
        0x45, 0x0f, 0x50, 0xca,
    }, machine.code.items);
}

test "jit asm_x86_64: encodes scalar float bridges, arithmetic, and compares" {
    var machine = Masm.init(std.testing.allocator);
    defer machine.deinit();

    try machine.movDXmmFromReg(.xmm0, .rax);
    try machine.movDRegFromXmm(.rax, .xmm0);
    try machine.addFloat(.xmm0, .xmm1);
    try machine.subFloat(.xmm0, .xmm1);
    try machine.mulFloat(.xmm0, .xmm1);
    try machine.divFloat(.xmm0, .xmm1);
    try machine.addDouble(.xmm0, .xmm1);
    try machine.subDouble(.xmm0, .xmm1);
    try machine.sqrtFloat(.xmm0, .xmm1);
    try machine.sqrtDouble(.xmm0, .xmm1);
    try machine.cvtI32ToFloat(.xmm0, .rax);
    try machine.cvtI64ToFloat(.xmm0, .rax);
    try machine.cvtI32ToDouble(.xmm0, .rax);
    try machine.cvtI64ToDouble(.xmm0, .rax);
    try machine.cvttFloatToI32(.rax, .xmm0);
    try machine.cvttFloatToI64(.rax, .xmm0);
    try machine.cvttDoubleToI32(.rax, .xmm0);
    try machine.cvttDoubleToI64(.rax, .xmm0);
    try machine.cvtFloatToDouble(.xmm0, .xmm1);
    try machine.cvtDoubleToFloat(.xmm0, .xmm1);
    try machine.ucomisFloat(.xmm0, .xmm1);
    try machine.ucomisDouble(.xmm0, .xmm1);

    try std.testing.expectEqualSlices(u8, &.{
        0x66, 0x40, 0x0F, 0x6E, 0xC0,
        0x66, 0x40, 0x0F, 0x7E, 0xC0,
        0xF3, 0x40, 0x0F, 0x58, 0xC1,
        0xF3, 0x40, 0x0F, 0x5C, 0xC1,
        0xF3, 0x40, 0x0F, 0x59, 0xC1,
        0xF3, 0x40, 0x0F, 0x5E, 0xC1,
        0xF2, 0x40, 0x0F, 0x58, 0xC1,
        0xF2, 0x40, 0x0F, 0x5C, 0xC1,
        0xF3, 0x40, 0x0F, 0x51, 0xC1,
        0xF2, 0x40, 0x0F, 0x51, 0xC1,
        0xF3, 0x40, 0x0F, 0x2A, 0xC0,
        0xF3, 0x48, 0x0F, 0x2A, 0xC0,
        0xF2, 0x40, 0x0F, 0x2A, 0xC0,
        0xF2, 0x48, 0x0F, 0x2A, 0xC0,
        0xF3, 0x40, 0x0F, 0x2C, 0xC0,
        0xF3, 0x48, 0x0F, 0x2C, 0xC0,
        0xF2, 0x40, 0x0F, 0x2C, 0xC0,
        0xF2, 0x48, 0x0F, 0x2C, 0xC0,
        0xF3, 0x40, 0x0F, 0x5A, 0xC1,
        0xF2, 0x40, 0x0F, 0x5A, 0xC1,
        0x40, 0x0F, 0x2E, 0xC1, 0x66,
        0x40, 0x0F, 0x2E, 0xC1,
    }, machine.code.items);
}

test "jit asm_x86_64: encodes a SysV helper call with frame preservation" {
    var machine = Masm.init(std.testing.allocator);
    defer machine.deinit();

    // A generated entry starts with rsp % 16 == 8. Reserve one word before
    // `call` both to align the helper boundary and preserve CallFrame* in rsi.
    try machine.subRegImm32(.rsp, 8);
    try machine.store64Disp32(.rsp, 0, .rsi);
    try machine.movImm64(.r11, 0x1122_3344_5566_7788);
    try machine.callReg(.r11);
    try machine.load64Disp32(.rsi, .rsp, 0);
    try machine.addRegImm32(.rsp, 8);

    try std.testing.expectEqualSlices(u8, &.{
        0x48, 0x81, 0xEC, 0x08, 0x00, 0x00, 0x00,
        0x48, 0x89, 0xB4, 0x24, 0x00, 0x00, 0x00,
        0x00, 0x49, 0xBB, 0x88, 0x77, 0x66, 0x55,
        0x44, 0x33, 0x22, 0x11, 0x41, 0xFF, 0xD3,
        0x48, 0x8B, 0xB4, 0x24, 0x00, 0x00, 0x00,
        0x00, 0x48, 0x81, 0xC4, 0x08, 0x00, 0x00,
        0x00,
    }, machine.code.items);
}
