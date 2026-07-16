const std = @import("std");

const chunk_mod = @import("../../bytecode/chunk.zig");
const Builder = chunk_mod.Builder;
const Span = @import("../../source.zig").Span;
const code_alloc = @import("../jit/code_alloc.zig");
const lantern = @import("../lantern/interpreter.zig");
const Realm = @import("../realm.zig").Realm;
const Value = @import("../value.zig").Value;
const compiler = @import("compiler.zig");
const codegen = @import("codegen_aarch64.zig");

const testing = std.testing;
const span: Span = .{ .start = 0, .end = 1 };
const EntryFn = *const fn (*Realm, *lantern.CallFrame, [*]Value) callconv(.c) u32;

fn foldedAddChunk() !chunk_mod.Chunk {
    var builder = Builder.init(testing.allocator);
    defer builder.deinit();
    const lhs = try builder.reserveRegister();
    try builder.emitLoadSmi(span, 1);
    try builder.emitStoreReg(span, lhs);
    try builder.emitLoadSmi(span, 2);
    try builder.emitOp(.add, span);
    try builder.emitU8(lhs);
    try builder.emitOp(.return_, span);
    return builder.finish();
}

test "Ohaimark compiler publishes owned code after temporary plans die" {
    if (comptime !compiler.supported) return error.SkipZigTest;
    var realm = Realm.init(testing.allocator);
    defer realm.deinit();
    realm.jit_enabled = false;
    var chunk = try foldedAddChunk();
    defer chunk.deinit(testing.allocator);

    try testing.expect(compiler.compile(&realm, &chunk));
    const state = chunk.jit_state.?;
    try testing.expectEqual(chunk_mod.Chunk.JitState.Tier.compiled, state.ohaimark.tier);
    const published_entry = state.ohaimark.entry().?;
    try testing.expect(compiler.compile(&realm, &chunk));
    try testing.expectEqual(published_entry, state.ohaimark.entry().?);

    const registers = try testing.allocator.alloc(Value, chunk.register_count);
    defer testing.allocator.free(registers);
    @memset(registers, Value.undefined_);
    var frame: lantern.CallFrame = .{
        .chunk = &chunk,
        .ip = 0,
        .accumulator = Value.undefined_,
        .registers = registers,
        .env = null,
        .this_value = Value.undefined_,
        .owns_registers = false,
    };
    const entry: EntryFn = @ptrCast(@alignCast(published_entry));
    try testing.expectEqual(
        @intFromEnum(codegen.EntryResult.done),
        entry(&realm, &frame, registers.ptr),
    );
    try testing.expectEqual(Value.fromInt32(3).bits, frame.accumulator.bits);
}

test "Ohaimark install failure leaves Bistromath published and T2 empty" {
    if (comptime !compiler.supported) return error.SkipZigTest;
    var baseline_allocator = try code_alloc.CodeAllocator.init(testing.allocator, 64 * 1024);
    defer baseline_allocator.deinit();
    var exhausted = try code_alloc.CodeAllocator.init(testing.allocator, 1);
    defer exhausted.deinit();
    var chunk = try foldedAddChunk();
    defer chunk.deinit(testing.allocator);

    var baseline = try baseline_allocator.installOwned(code_alloc.ret42_stub);
    defer baseline.deinit();
    chunk.jit_state.?.bistromath.publish(&baseline, null, 0);
    const baseline_entry = chunk.jit_state.?.bistromath.entry().?;

    const filler = try testing.allocator.alloc(u8, std.heap.pageSize());
    defer testing.allocator.free(filler);
    @memset(filler, 0);
    _ = try exhausted.install(filler);

    try testing.expect(!compiler.compileAndInstall(testing.allocator, &chunk, &exhausted));
    const state = chunk.jit_state.?;
    try testing.expectEqual(chunk_mod.Chunk.JitState.Tier.dont_compile, state.ohaimark.tier);
    try testing.expect(state.ohaimark.entry() == null);
    try testing.expectEqual(chunk_mod.Chunk.JitState.Tier.compiled, state.bistromath.code.tier);
    try testing.expectEqual(baseline_entry, state.bistromath.entry().?);
}
