//! Bounded scalar accesses; frontend-owned views may overlap. No address or
//! length is embedded in code, and every access retains its own bounds check.
const builtin = @import("builtin");
const ir = @import("ir.zig");
const arm = @import("../asm_aarch64.zig");
const arm_masm = @import("../masm.zig");
const x86 = @import("../asm_x86_64.zig");
const is_x86 = builtin.cpu.arch == .x86_64;
const Machine = if (is_x86) x86.Masm else arm_masm.Masm;

/// The host keeps both descriptors and backing bytes live throughout the leaf
/// call. Rebuild views after growth/detachment; no concurrent resize is allowed.
pub const View = extern struct {
    base: [*]u8,
    length: usize,

    pub fn fromSlice(bytes: []u8) View {
        return .{ .base = bytes.ptr, .length = bytes.len };
    }
};

pub fn emit(m: *Machine, op: ir.Op, ty: ir.Type, access: ir.MemoryAccess, views_slot: usize, oob: *Machine.Label) !void {
    const descriptor = access.region * @sizeOf(View);
    const length_offset = descriptor + @offsetOf(View, "length");
    const slot_offset = views_slot * 8;
    if (comptime is_x86) {
        if (access.offset != 0) {
            try m.movImm64(.r11, access.offset);
            try m.addReg64(.rax, .r11);
            try m.jumpCond(.below, oob);
        }
        try m.load64Disp32(.r11, .rdi, @intCast(slot_offset));
        try m.load64Disp32(.r11, .r11, @intCast(length_offset));
        // Compare against length - width, never an overflowing address + width.
        try m.subRegImm32(.r11, @intCast(access.width.bytes()));
        try m.jumpCond(.below, oob);
        try m.cmpReg64(.rax, .r11);
        try m.jumpCond(.above, oob);
        try m.load64Disp32(.r11, .rdi, @intCast(slot_offset));
        try m.load64Disp32(.r11, .r11, @intCast(descriptor));
        try m.addReg64(.r11, .rax);
        if (op == .store) {
            switch (access.width) {
                .byte => try m.store8Disp32(.r11, 0, .r10),
                .half => try m.store16Disp32(.r11, 0, .r10),
                .word => try m.store32Disp32(.r11, 0, .r10),
                .double => try m.store64Disp32(.r11, 0, .r10),
            }
        } else if (access.signed) {
            switch (access.width) {
                .byte => if (ir.is32(ty)) try m.load8Signed32Disp32(.rax, .r11, 0) else try m.load8Signed64Disp32(.rax, .r11, 0),
                .half => if (ir.is32(ty)) try m.load16Signed32Disp32(.rax, .r11, 0) else try m.load16Signed64Disp32(.rax, .r11, 0),
                .word => try m.load32Signed64Disp32(.rax, .r11, 0),
                .double => return error.InvalidGraph,
            }
        } else switch (access.width) {
            .byte => try m.load8Disp32(.rax, .r11, 0),
            .half => try m.load16Disp32(.rax, .r11, 0),
            .word => try m.load32Disp32(.rax, .r11, 0),
            .double => try m.load64Disp32(.rax, .r11, 0),
        }
    } else {
        if (access.offset != 0) {
            try m.movImm64(.x16, access.offset);
            try m.emit(arm.addsReg(.x2, .x2, .x16));
            try m.jumpCond(.cs, oob);
        }
        try m.emit(arm.ldrImm(.x16, .x0, @intCast(slot_offset)));
        try m.emit(arm.ldrImm(.x16, .x16, @intCast(length_offset)));
        try m.movImm64(.x17, access.width.bytes());
        try m.emit(arm.subsReg(.x16, .x16, .x17));
        try m.jumpCond(.cc, oob);
        try m.emit(arm.cmpReg(.x2, .x16));
        try m.jumpCond(.hi, oob);
        try m.emit(arm.ldrImm(.x16, .x0, @intCast(slot_offset)));
        try m.emit(arm.ldrImm(.x16, .x16, @intCast(descriptor)));
        try m.emit(if (op == .store) switch (access.width) {
            .byte => arm.strbRegW(.x3, .x16, .x2),
            .half => arm.strhRegW(.x3, .x16, .x2),
            .word => arm.strRegW(.x3, .x16, .x2),
            .double => arm.strReg(.x3, .x16, .x2),
        } else if (access.signed) switch (access.width) {
            .byte => if (ir.is32(ty)) arm.ldrsbRegW(.x2, .x16, .x2) else arm.ldrsbReg(.x2, .x16, .x2),
            .half => if (ir.is32(ty)) arm.ldrshRegW(.x2, .x16, .x2) else arm.ldrshReg(.x2, .x16, .x2),
            .word => arm.ldrswReg(.x2, .x16, .x2),
            .double => return error.InvalidGraph,
        } else switch (access.width) {
            .byte => arm.ldrbRegW(.x2, .x16, .x2),
            .half => arm.ldrhRegW(.x2, .x16, .x2),
            .word => arm.ldrRegW(.x2, .x16, .x2),
            .double => arm.ldrReg(.x2, .x16, .x2),
        });
    }
}
