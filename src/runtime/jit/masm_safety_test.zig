const std = @import("std");

const a64 = @import("asm_aarch64.zig");
const Masm = @import("masm.zig").Masm;

test "jit masm: binding a label twice fails without aborting" {
    var machine = Masm.init(std.testing.allocator);
    defer machine.deinit();
    var label = Masm.Label{};
    defer label.deinit(std.testing.allocator);

    try machine.bind(&label);
    try std.testing.expectError(error.LabelAlreadyBound, machine.bind(&label));
}

test "jit masm: an out-of-range AArch64 conditional fixup fails without a cast trap" {
    var machine = Masm.init(std.testing.allocator);
    defer machine.deinit();
    var far = Masm.Label{};
    defer far.deinit(std.testing.allocator);

    try machine.jumpTbz(.x0, 0, &far);
    for (0..8192) |_| try machine.emit(a64.nop());

    try std.testing.expectError(error.BranchOutOfRange, machine.bind(&far));
}
