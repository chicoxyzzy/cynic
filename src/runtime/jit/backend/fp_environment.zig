//! Entry/callback FP state. Saved per invocation, outside SSA spill/transfer slots.
const builtin = @import("builtin");
const ir = @import("ir.zig");
const scratch = @import("scratch.zig");
const arm = @import("../asm_aarch64.zig");
const arm_masm = @import("../masm.zig");
const x86 = @import("../asm_x86_64.zig");
const is_x86 = builtin.cpu.arch == .x86_64;
const Machine = if (is_x86) x86.Masm else arm_masm.Masm;

pub const slot_count = 2;
pub const enter_loads = if (is_x86) 1 else 0;
pub const enter_stores = 2;
pub const leave_loads = if (is_x86) 1 else 2;

pub fn required(graph: ir.Graph) bool {
    for (graph.blocks) |block| for (block.nodes) |node| {
        if (ir.isFloatOp(node.op) or ir.isNumericConversion(node.op) or node.op == .call) return true;
        if (node.vector_lane == .f32x4 or node.vector_lane == .f64x2) return true;
        // NEON saturating integer instructions update FPSR.QC without any FP
        // values. The caller's sticky saturation flag must not leak or change.
        if (!is_x86 and (node.op == .vector_narrow_s or node.op == .vector_narrow_u)) return true;
    };
    return false;
}

pub fn enter(m: *Machine, slot: usize) !void {
    const offset = slot * 8;
    if (comptime is_x86) {
        try m.storeMxcsr(.rdi, @intCast(offset));
        // Nearest-even, gradual underflow, masked exceptions, clear flags.
        // No x87 instructions are emitted, so its independent state is untouched.
        try m.movImm64(.rax, 0x1f80);
        try m.store64Disp32(.rdi, @intCast(offset + 8), .rax);
        try m.loadMxcsr(.rdi, @intCast(offset + 8));
    } else {
        try m.emit(arm.readFpcr(.x16));
        try scratch.store(m, .x16, slot);
        // Clear AH/FIZ/NEP, exception enables, rounding, FZ and DN. Preserve
        // unrelated/reserved controls rather than assuming their reset value.
        try m.movImm64(.x17, ~@as(u64, 0x03c0_9f07));
        try m.emit(arm.andReg(.x16, .x16, .x17));
        try m.emit(arm.writeFpcr(.x16));
        try m.emit(arm.readFpsr(.x16));
        try scratch.store(m, .x16, slot + 1);
        try m.movImm64(.x17, ~@as(u64, 0x0800_009f));
        try m.emit(arm.andReg(.x16, .x16, .x17));
        try m.emit(arm.writeFpsr(.x16));
    }
}

pub fn leave(m: *Machine, slot: usize) !void {
    const offset = slot * 8;
    if (comptime is_x86) {
        try m.loadMxcsr(.rdi, @intCast(offset));
    } else {
        // Restore status before re-enabling any caller exception traps.
        try scratch.load(m, .x16, slot + 1);
        try m.emit(arm.writeFpsr(.x16));
        try scratch.load(m, .x16, slot);
        try m.emit(arm.writeFpcr(.x16));
    }
}

/// Re-establish strict arithmetic after a callback without overwriting the
/// original caller state. Callback changes must not leak through our return.
pub fn reenter(m: *Machine, slot: usize) !void {
    const offset = slot * 8;
    if (comptime is_x86) {
        try m.loadMxcsr(.rdi, @intCast(offset + 8));
    } else {
        try scratch.load(m, .x16, slot);
        try m.movImm64(.x17, ~@as(u64, 0x03c0_9f07));
        try m.emit(arm.andReg(.x16, .x16, .x17));
        try m.emit(arm.writeFpcr(.x16));
        try scratch.load(m, .x16, slot + 1);
        try m.movImm64(.x17, ~@as(u64, 0x0800_009f));
        try m.emit(arm.andReg(.x16, .x16, .x17));
        try m.emit(arm.writeFpsr(.x16));
    }
}
