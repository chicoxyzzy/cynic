const std = @import("std");

const a64 = @import("../jit/asm_aarch64.zig");
const code_alloc = @import("../jit/code_alloc.zig");
const masm = @import("../jit/masm.zig");
const Value = @import("../value.zig").Value;
const emitter = @import("emitter_aarch64.zig");
const lowering = @import("lowering_aarch64.zig");

const testing = std.testing;

fn wordAt(code: []const u8, instruction: usize) u32 {
    return std.mem.readInt(u32, code[instruction * 4 ..][0..4], .little);
}

test "Ohaimark AArch64 emitter builds and validates the native frame" {
    var machine = masm.Masm.init(testing.allocator);
    defer machine.deinit();

    var corrupt = try lowering.FrameLayout.build(3, 2);
    corrupt.native_frame_bytes += 16;
    try testing.expectError(error.InvalidLowering, emitter.emitPrologue(&machine, corrupt));
    try testing.expectEqual(@as(usize, 0), machine.code.items.len);

    const frame = try lowering.FrameLayout.build(3, 2);
    try emitter.emitPrologue(&machine, frame);
    try testing.expectEqual(a64.stpPreIdxSp(.fp, .lr, -16), wordAt(machine.code.items, 0));
    try testing.expectEqual(a64.addRegSp(.fp, 0), wordAt(machine.code.items, 1));
    try testing.expectEqual(a64.stpPreIdxSp(.x19, .x20, -16), wordAt(machine.code.items, 2));
    try testing.expectEqual(a64.subSpImm(32), wordAt(machine.code.items, 7));
    try testing.expectEqual(
        a64.addRegSp(lowering.spill_base_register, 0),
        wordAt(machine.code.items, 8),
    );
    try testing.expectEqual(
        a64.movReg(lowering.realm_register, .x0),
        wordAt(machine.code.items, 9),
    );
    try testing.expectEqual(
        a64.movReg(lowering.lantern_frame_register, .x1),
        wordAt(machine.code.items, 10),
    );
    try testing.expectEqual(
        a64.movReg(lowering.lantern_registers_register, .x2),
        wordAt(machine.code.items, 11),
    );
    const prologue_bytes = machine.code.items.len;
    try emitter.emitEpilogue(&machine, frame);
    try testing.expect(machine.code.items.len > prologue_bytes);
    try testing.expectEqual(
        a64.ret(),
        wordAt(machine.code.items, machine.code.items.len / 4 - 1),
    );
}

test "Ohaimark AArch64 emitter chunks large stack reservations" {
    var machine = masm.Masm.init(testing.allocator);
    defer machine.deinit();
    const frame = try lowering.FrameLayout.build(512, 0);
    try testing.expectEqual(@as(u32, 4096), frame.spill_bytes);
    try emitter.emitPrologue(&machine, frame);
    try testing.expectEqual(a64.subSpImm(4080), wordAt(machine.code.items, 7));
    try testing.expectEqual(a64.subSpImm(16), wordAt(machine.code.items, 8));
}

test "Ohaimark AArch64 emitter initializes tagged spills on native hardware" {
    if (comptime !masm.native_aarch64) return error.SkipZigTest;
    var allocator = try code_alloc.CodeAllocator.init(testing.allocator, 64 * 1024);
    defer allocator.deinit();
    var machine = masm.Masm.init(testing.allocator);
    defer machine.deinit();

    const frame = try lowering.FrameLayout.build(3, 2);
    try emitter.emitPrologue(&machine, frame);
    try machine.emit(a64.ldrImm(
        .x0,
        lowering.spill_base_register,
        @intCast(try frame.taggedByteOffset(2)),
    ));
    try emitter.emitEpilogue(&machine, frame);
    const entry = code_alloc.asFn(
        *const fn (u64, u64, u64) callconv(.c) u64,
        try machine.install(&allocator),
    );
    try testing.expectEqual(Value.undefined_.bits, entry(11, 22, 33));
}
