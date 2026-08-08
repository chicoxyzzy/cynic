const std = @import("std");

const code_alloc = @import("../jit/code_alloc.zig");
const x86 = @import("../jit/asm_x86_64.zig");
const Value = @import("../value.zig").Value;
const codegen = @import("codegen_x86_64.zig");

const testing = std.testing;

const Entry = *const fn (
    ?*anyopaque,
    ?*anyopaque,
    [*]Value,
) callconv(.c) u64;

test "Ohaimark x86_64 leaf emitter returns a tagged immediate" {
    if (comptime !codegen.native_x86_64) return error.SkipZigTest;
    var machine = x86.Masm.init(testing.allocator);
    defer machine.deinit();
    try codegen.emitImmediateReturn(&machine, Value.fromInt32(42).bits);

    var executable = try code_alloc.CodeAllocator.init(testing.allocator, 64 * 1024);
    defer executable.deinit();
    const entry = code_alloc.asFn(Entry, try machine.install(&executable));
    var registers = [_]Value{Value.undefined_};
    try testing.expectEqual(Value.fromInt32(42).bits, entry(null, null, registers[0..].ptr));
}

test "Ohaimark x86_64 leaf emitter reads the Lantern register-file argument" {
    if (comptime !codegen.native_x86_64) return error.SkipZigTest;
    var machine = x86.Masm.init(testing.allocator);
    defer machine.deinit();
    try codegen.emitFrameRegisterReturn(&machine, 1);

    var executable = try code_alloc.CodeAllocator.init(testing.allocator, 64 * 1024);
    defer executable.deinit();
    const entry = code_alloc.asFn(Entry, try machine.install(&executable));
    var registers = [_]Value{ Value.undefined_, Value.fromInt32(42) };
    try testing.expectEqual(Value.fromInt32(42).bits, entry(null, null, registers[0..].ptr));
}
