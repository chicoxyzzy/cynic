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

    /// `cvtsi2sd destination, source32`.
    pub fn cvtI32ToDouble(self: *Masm, destination: Xmm, source: Reg) error{OutOfMemory}!void {
        try self.emitByte(0xF2);
        try self.emitByte(rex(false, isExtendedXmm(destination), false, isExtended(source)));
        try self.emitByte(0x0F);
        try self.emitByte(0x2A);
        try self.emitByte(0xC0 | (lowBitsXmm(destination) << 3) | lowBits(source));
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

    pub fn mulDouble(self: *Masm, destination: Xmm, source: Xmm) error{OutOfMemory}!void {
        try self.emitXmmReg(0xF2, 0x59, destination, source);
    }

    pub fn divDouble(self: *Masm, destination: Xmm, source: Xmm) error{OutOfMemory}!void {
        try self.emitXmmReg(0xF2, 0x5E, destination, source);
    }

    /// `ucomisd left, right` — its parity flag reports an unordered (NaN)
    /// comparison, which native lowering routes back to Lantern for canonical
    /// NaN boxing.
    pub fn ucomisDouble(self: *Masm, left: Xmm, right: Xmm) error{OutOfMemory}!void {
        try self.emitXmmReg(0x66, 0x2E, left, right);
    }

    /// `call target`.
    pub fn callReg(self: *Masm, target: Reg) error{OutOfMemory}!void {
        try self.emitByte(rex(false, false, false, isExtended(target)));
        try self.emitByte(0xFF);
        try self.emitByte(0xD0 | lowBits(target));
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
        prefix: u8,
        opcode: u8,
        destination: Xmm,
        source: Xmm,
    ) error{OutOfMemory}!void {
        try self.emitByte(prefix);
        try self.emitByte(rex(false, isExtendedXmm(destination), false, isExtendedXmm(source)));
        try self.emitByte(0x0F);
        try self.emitByte(opcode);
        try self.emitByte(0xC0 | (lowBitsXmm(destination) << 3) | lowBitsXmm(source));
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
