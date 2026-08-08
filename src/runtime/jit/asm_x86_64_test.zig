const std = @import("std");
const builtin = @import("builtin");

const x64 = @import("asm_x86_64.zig");
const code_alloc = @import("code_alloc.zig");

test "jit asm_x86_64: Bistromath integer primitives have stable encodings" {
    var machine = x64.Masm.init(std.testing.allocator);
    defer machine.deinit();

    try machine.addReg32Imm32(.r8, 1);
    try machine.andReg32(.r8, .r9);
    try machine.orReg32(.r10, .r11);
    try machine.shlImm8(.r12, 3);
    try machine.setCond32(.r9, .less);
    try machine.leaDisp32(.r10, .r13, 0x1234);
    try machine.signExtendReg32To64(.r10, .r9);
    try machine.imulReg64(.r11, .r10);

    try std.testing.expectEqualSlices(u8, &.{
        0x41, 0x81, 0xC0, 0x01, 0x00, 0x00, 0x00,
        0x45, 0x21, 0xC8, 0x45, 0x09, 0xDA, 0x49,
        0xC1, 0xE4, 0x03, 0x41, 0x0F, 0x9C, 0xC1,
        0x45, 0x0F, 0xB6, 0xC9, 0x4D, 0x8D, 0x95,
        0x34, 0x12, 0x00, 0x00, 0x4D, 0x63, 0xD1,
        0x4D, 0x0F, 0xAF, 0xDA,
    }, machine.code.items);
}

test "jit asm_x86_64: rel32 labels handle forward and backward edges" {
    var machine = x64.Masm.init(std.testing.allocator);
    defer machine.deinit();

    var body = x64.Masm.Label{};
    defer body.deinit(std.testing.allocator);
    var loop = x64.Masm.Label{};
    defer loop.deinit(std.testing.allocator);

    try machine.jump(&body);
    try machine.movImm64(.rax, 99);
    try machine.bind(&body);
    try machine.movImm64(.rax, 2);
    try machine.bind(&loop);
    try machine.subRegImm32(.rax, 1);
    try machine.jumpCond(.not_equal, &loop);
    try machine.ret();

    try std.testing.expectEqualSlices(u8, &.{
        0xE9, 0x0A, 0x00, 0x00, 0x00,
        0x48, 0xB8, 0x63, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00,
        0x48, 0xB8, 0x02, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00, 0x00,
        0x48, 0x81, 0xE8, 0x01, 0x00,
        0x00, 0x00, 0x0F, 0x85, 0xF3,
        0xFF, 0xFF, 0xFF, 0xC3,
    }, machine.code.items);
}

test "jit asm_x86_64: a failed bind does not publish the label" {
    var machine = x64.Masm.init(std.testing.allocator);
    defer machine.deinit();
    var label = x64.Masm.Label{};
    defer label.deinit(std.testing.allocator);

    // Model a corrupt/stale fixup without touching machine memory. Binding
    // must fail transactionally so a JIT compiler can refuse the chunk rather
    // than observing a label that claims to have been installed.
    try label.fixups.append(std.testing.allocator, 1);
    try std.testing.expectError(error.InvalidLabel, machine.bind(&label));
    try std.testing.expectEqual(@as(?usize, null), label.bound);
}

test "jit asm_x86_64: installed rel32 loop executes natively" {
    if (comptime builtin.cpu.arch != .x86_64 or !code_alloc.supported) {
        return error.SkipZigTest;
    }

    var machine = x64.Masm.init(std.testing.allocator);
    defer machine.deinit();
    var loop = x64.Masm.Label{};
    defer loop.deinit(std.testing.allocator);

    try machine.movImm64(.rax, 2);
    try machine.bind(&loop);
    try machine.subRegImm32(.rax, 1);
    try machine.jumpCond(.not_equal, &loop);
    try machine.ret();

    var executable = try code_alloc.CodeAllocator.init(std.testing.allocator, 64 * 1024);
    defer executable.deinit();
    const entry = code_alloc.asFn(
        *const fn () callconv(.c) u64,
        try machine.install(&executable),
    );
    try std.testing.expectEqual(@as(u64, 0), entry());
}
