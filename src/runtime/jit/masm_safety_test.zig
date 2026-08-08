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

test "jit masm: a failed mixed-fixup bind is transactional and retryable" {
    var machine = Masm.init(std.testing.allocator);
    defer machine.deinit();
    var far = Masm.Label{};
    defer far.deinit(std.testing.allocator);

    // The first fixup (`B`, imm26) can reach the final target; the second
    // (`TBZ`, imm14) cannot. Binding must preflight both before patching the
    // first instruction, otherwise a later retry ORs a new displacement into
    // the already-mutated branch word.
    try machine.jump(&far);
    try machine.jumpTbz(.x0, 0, &far);
    for (0..8192) |_| try machine.emit(a64.nop());

    const before = try std.testing.allocator.dupe(u8, machine.code.items);
    defer std.testing.allocator.free(before);
    try std.testing.expectError(error.BranchOutOfRange, machine.bind(&far));
    try std.testing.expectEqualSlices(u8, before, machine.code.items);
    try std.testing.expectEqual(@as(?usize, null), far.bound);
    try std.testing.expectEqual(@as(usize, 2), far.fixups.items.len);

    // Bring the target into range and prove the same label/buffer can bind
    // correctly after the failed attempt.
    machine.code.shrinkRetainingCapacity(8);
    try machine.bind(&far);
    try std.testing.expectEqual(@as(?usize, 8), far.bound);
    try std.testing.expectEqual(@as(usize, 0), far.fixups.items.len);
    try std.testing.expectEqual(
        a64.b(2),
        std.mem.readInt(u32, machine.code.items[0..4], .little),
    );
    try std.testing.expectEqual(
        a64.tbz(.x0, 0, 1),
        std.mem.readInt(u32, machine.code.items[4..8], .little),
    );
}
