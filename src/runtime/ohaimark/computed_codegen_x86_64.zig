//! x86_64 emission for monomorphic computed own-data accesses.

const chunk_mod = @import("../../bytecode/chunk.zig");
const ComputedICCell = chunk_mod.ComputedICCell;
const x86 = @import("../jit/asm_x86_64.zig");
const layout = @import("../jit/layout.zig");
const Shape = @import("../shape.zig").Shape;

pub const Expected = struct {
    receiver_shape: *Shape,
    slot: u32,
    key: []const u8,
};

/// Validate the live cell and decoded receiver before loading the dynamic key.
/// `scratch` and r11 are clobbered.
pub fn emitCellAndReceiverGuards(
    machine: *x86.Masm,
    cell: *const ComputedICCell,
    expected: Expected,
    object: x86.Reg,
    scratch: x86.Reg,
    guard: *x86.Masm.Label,
) !void {
    try validateExpected(expected);
    if (object == scratch or object == .r11 or scratch == .r11) {
        return error.InvalidMetadata;
    }

    try machine.movImm64(.r11, @intFromPtr(cell));
    try machine.movImm64(scratch, @intFromPtr(expected.receiver_shape));
    try machine.cmp64Disp32Reg(
        .r11,
        layout.computed_ic_cell.shape,
        scratch,
    );
    try machine.jumpCond(.not_equal, guard);
    try machine.cmp64Disp32Reg(
        object,
        layout.object.shape,
        scratch,
    );
    try machine.jumpCond(.not_equal, guard);
    try machine.cmp32Disp32Imm32(
        .r11,
        layout.computed_ic_cell.slot,
        expected.slot,
    );
    try machine.jumpCond(.not_equal, guard);
    try machine.cmp8Disp32Imm8(
        .r11,
        layout.computed_ic_cell.key_len,
        @intCast(expected.key.len),
    );
    try machine.jumpCond(.not_equal, guard);
    for (expected.key, 0..) |byte, index| {
        try machine.cmp8Disp32Imm8(
            .r11,
            @intCast(layout.computed_ic_cell.key_buf + index),
            byte,
        );
        try machine.jumpCond(.not_equal, guard);
    }
}

/// Prove the runtime property key is the same flat JSString as the cell's
/// copied key. `key` is decoded in place and r11 is clobbered.
pub fn emitKeyGuards(
    machine: *x86.Masm,
    expected: Expected,
    key: x86.Reg,
    guard: *x86.Masm.Label,
) !void {
    try validateExpected(expected);
    if (key == .r11) return error.InvalidMetadata;

    try machine.movReg64(.r11, key);
    try machine.shrImm8(.r11, 48);
    try machine.cmpRegImm32(.r11, @intCast(layout.value_bits.tag_string));
    try machine.jumpCond(.not_equal, guard);
    try machine.movImm64(
        .r11,
        @as(u64, layout.value_bits.tag_string) << 48,
    );
    try machine.xorReg64(key, .r11);
    try machine.testReg64(key, key);
    try machine.jumpCond(.equal, guard);
    try machine.cmp32Disp32Imm32(
        key,
        layout.string.byte_len,
        @intCast(expected.key.len),
    );
    try machine.jumpCond(.not_equal, guard);
    try machine.cmp8Disp32Imm8(key, layout.string.depth, 0);
    try machine.jumpCond(.not_equal, guard);
    try machine.cmp8Disp32Imm8(key, layout.string.depth + 1, 0);
    try machine.jumpCond(.not_equal, guard);
    try machine.load64Disp32(
        .r11,
        key,
        layout.string.flat_bytes_ptr,
    );
    for (expected.key, 0..) |byte, index| {
        try machine.cmp8Disp32Imm8(
            .r11,
            @intCast(index),
            byte,
        );
        try machine.jumpCond(.not_equal, guard);
    }
}

fn validateExpected(expected: Expected) !void {
    if (expected.key.len == 0 or
        expected.key.len > chunk_mod.computed_key_cap or
        expected.slot >= expected.receiver_shape.property_count)
    {
        return error.InvalidMetadata;
    }
}
