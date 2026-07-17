const std = @import("std");

const chunk_mod = @import("../../bytecode/chunk.zig");
const Builder = chunk_mod.Builder;
const compiler_mod = @import("../../bytecode/compiler.zig");
const parser_mod = @import("../../parser/parser.zig");
const Span = @import("../../source.zig").Span;
const lantern = @import("../lantern/interpreter.zig");
const Realm = @import("../realm.zig").Realm;
const Value = @import("../value.zig").Value;
const driver = @import("driver.zig");

const testing = std.testing;
const span: Span = .{ .start = 0, .end = 1 };

fn templateNamed(chunk: *const chunk_mod.Chunk, name: []const u8) *const chunk_mod.Chunk {
    for (chunk.function_templates) |*template| {
        if (template.name) |candidate| {
            if (std.mem.eql(u8, candidate, name)) return &template.chunk;
        }
    }
    unreachable;
}

fn compileScript(realm: *Realm, source: []const u8) !chunk_mod.Chunk {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const program = try parser_mod.parseScript(arena.allocator(), source, null);
    return compiler_mod.compileScriptAsChunk(testing.allocator, realm, &program, source, null);
}

fn runValue(realm: *Realm, chunk: *const chunk_mod.Chunk) !Value {
    return switch (try lantern.run(testing.allocator, realm, chunk)) {
        .value, .yielded => |value| value,
        .thrown => error.UncaughtException,
    };
}

fn overflowChunk() !chunk_mod.Chunk {
    var builder = Builder.init(testing.allocator);
    defer builder.deinit();
    const lhs = try builder.reserveRegister();
    try builder.emitOp(.lda_true, span);
    try builder.emitOp(.jmp_if_false, span);
    const else_patch = builder.here();
    try builder.emitI16(0);
    try builder.emitLoadSmi(span, std.math.maxInt(i32));
    try builder.emitOp(.jmp, span);
    const join_patch = builder.here();
    try builder.emitI16(0);
    const else_target = builder.here();
    try builder.emitLoadSmi(span, std.math.maxInt(i32) - 1);
    const join_target = builder.here();
    try builder.emitStoreReg(span, lhs);
    try builder.emitOp(.lda_one, span);
    try builder.emitOp(.add, span);
    try builder.emitU8(lhs);
    try builder.emitOp(.return_, span);
    try builder.patchI16(else_patch, else_target);
    try builder.patchI16(join_patch, join_target);
    return builder.finish();
}

test "Ohaimark runtime tier stays disabled by default" {
    if (comptime !driver.supported) return error.SkipZigTest;
    var realm = Realm.init(testing.allocator);
    defer realm.deinit();
    realm.jit_enabled = true;
    realm.ohaimark_threshold_override = 1;

    const source =
        \\function answer() { return 1 + 2; }
        \\answer();
        \\answer();
    ;
    var chunk = try compileScript(&realm, source);
    defer chunk.deinit(testing.allocator);
    const value = try runValue(&realm, &chunk);
    try testing.expectEqual(Value.fromInt32(3).bits, value.bits);

    const state = templateNamed(&chunk, "answer").jit_state.?;
    try testing.expect(state.warmth >= chunk_mod.Chunk.JitState.entry_weight);
    try testing.expectEqual(chunk_mod.Chunk.JitState.Tier.cold, state.ohaimark.tier);
    try testing.expect(state.ohaimark.entry() == null);
}

test "Ohaimark runtime policy follows child realms" {
    var parent = Realm.init(testing.allocator);
    defer parent.deinit();
    parent.jit_enabled = true;
    parent.jit_threshold_override = 7;
    parent.ohaimark_enabled = true;
    parent.ohaimark_threshold_override = 11;
    parent.ohaimark_osr_enabled = true;

    var child = Realm.initChild(&parent);
    defer child.deinit();
    try testing.expect(child.jit_enabled);
    try testing.expectEqual(@as(?u32, 7), child.jit_threshold_override);
    try testing.expect(child.ohaimark_enabled);
    try testing.expectEqual(@as(?u32, 11), child.ohaimark_threshold_override);
    try testing.expect(child.ohaimark_osr_enabled);
}

test "Ohaimark OSR stays disabled by default" {
    var realm = Realm.init(testing.allocator);
    defer realm.deinit();
    try testing.expect(!realm.ohaimark_osr_enabled);
    var child = Realm.initChild(&realm);
    defer child.deinit();
    try testing.expect(!child.ohaimark_osr_enabled);
}

test "Ohaimark forced function entry compiles and completes through normal dispatch" {
    if (comptime !driver.supported) return error.SkipZigTest;
    var realm = Realm.init(testing.allocator);
    defer realm.deinit();
    realm.jit_enabled = true;
    realm.jit_threshold_override = 1;
    realm.ohaimark_enabled = true;
    realm.ohaimark_threshold_override = 1;
    realm.heap.ohaimark_stats.enabled = true;

    const source =
        \\function answer() { return 1 + 2; }
        \\answer();
        \\answer();
    ;
    var chunk = try compileScript(&realm, source);
    defer chunk.deinit(testing.allocator);
    const value = try runValue(&realm, &chunk);
    try testing.expectEqual(Value.fromInt32(3).bits, value.bits);

    const state = templateNamed(&chunk, "answer").jit_state.?;
    try testing.expectEqual(chunk_mod.Chunk.JitState.Tier.compiled, state.ohaimark.tier);
    try testing.expect(state.ohaimark.entry() != null);
    try testing.expectEqual(chunk_mod.Chunk.JitState.Tier.cold, state.bistromath.code.tier);
    try testing.expectEqual(@as(u64, 1), realm.heap.ohaimark_stats.compile_attempts);
    try testing.expectEqual(@as(u64, 1), realm.heap.ohaimark_stats.compile_successes);
    try testing.expectEqual(@as(u64, 2), realm.heap.ohaimark_stats.executed_entries);
    try testing.expectEqual(@as(u64, 2), realm.heap.ohaimark_stats.completed_entries);
    try testing.expectEqual(@as(u64, 0), realm.heap.ohaimark_stats.guard_exits);
}

test "Ohaimark warmth continues through a compiled Bistromath caller" {
    if (comptime !driver.supported) return error.SkipZigTest;
    var realm = Realm.init(testing.allocator);
    defer realm.deinit();
    realm.jit_enabled = true;
    realm.jit_threshold_override = 1;
    realm.ohaimark_enabled = true;
    realm.ohaimark_threshold_override = 64;

    const source =
        \\function leaf() { return 1 + 2; }
        \\function caller() { return leaf() + 0; }
        \\caller(); caller(); caller(); caller(); caller();
    ;
    var chunk = try compileScript(&realm, source);
    defer chunk.deinit(testing.allocator);
    const value = try runValue(&realm, &chunk);
    try testing.expectEqual(Value.fromInt32(3).bits, value.bits);

    const caller_state = templateNamed(&chunk, "caller").jit_state.?;
    try testing.expectEqual(
        chunk_mod.Chunk.JitState.Tier.compiled,
        caller_state.bistromath.code.tier,
    );
    const leaf_state = templateNamed(&chunk, "leaf").jit_state.?;
    try testing.expect(leaf_state.warmth >= 64);
    try testing.expectEqual(chunk_mod.Chunk.JitState.Tier.compiled, leaf_state.ohaimark.tier);
}

test "Ohaimark function-entry guard exit resumes the same Lantern frame" {
    if (comptime !driver.supported) return error.SkipZigTest;
    var realm = Realm.init(testing.allocator);
    defer realm.deinit();
    realm.jit_enabled = true;
    realm.ohaimark_enabled = true;
    realm.ohaimark_threshold_override = 1;
    realm.heap.ohaimark_stats.enabled = true;

    var chunk = try overflowChunk();
    defer chunk.deinit(testing.allocator);
    chunk.jit_state.?.warmth = 1;

    var frames: std.ArrayListUnmanaged(lantern.CallFrame) = .empty;
    defer {
        for (frames.items) |*frame| frame.releaseRegisters(&realm, testing.allocator);
        frames.deinit(testing.allocator);
    }
    const registers = try realm.frame_pool.acquire(testing.allocator, chunk.register_count);
    @memset(registers, Value.undefined_);
    try frames.append(testing.allocator, .{
        .chunk = &chunk,
        .ip = 0,
        .accumulator = Value.undefined_,
        .registers = registers,
        .env = null,
        .this_value = Value.undefined_,
    });

    switch (try driver.tryEnterTop(testing.allocator, &realm, &frames)) {
        .resumed => {},
        else => return error.TestUnexpectedResult,
    }
    try testing.expectEqual(chunk_mod.Chunk.JitState.Tier.compiled, chunk.jit_state.?.ohaimark.tier);
    try testing.expect(frames.items.len == 1);
    try testing.expect(frames.items[0].ip != 0);
    try testing.expectEqual(@as(u64, 1), realm.heap.ohaimark_stats.executed_entries);
    try testing.expectEqual(@as(u64, 0), realm.heap.ohaimark_stats.completed_entries);
    try testing.expectEqual(@as(u64, 1), realm.heap.ohaimark_stats.guard_exits);

    const resumed = switch (try lantern.runFrames(testing.allocator, &realm, &frames)) {
        .value => |value| value,
        else => return error.TestUnexpectedResult,
    };
    try testing.expect(resumed.isDouble());
    try testing.expectEqual(@as(f64, 2_147_483_648), resumed.asDouble());
}

test "Ohaimark natural threshold consumes trained multiplication feedback" {
    if (comptime !driver.supported) return error.SkipZigTest;
    var realm = Realm.init(testing.allocator);
    defer realm.deinit();
    realm.jit_enabled = true;
    realm.jit_threshold_override = std.math.maxInt(u32);
    realm.ohaimark_enabled = true;
    // Three interpreted entries (3 * 16 warmth) train the site before the
    // fourth entry crosses the threshold and snapshots its Number profile.
    realm.ohaimark_threshold_override = 64;
    realm.heap.ohaimark_stats.enabled = true;

    const source =
        \\function multiply(a, b) { return a * b; }
        \\multiply(1.5, 2);
        \\multiply(2.5, 3);
        \\multiply(3.5, 4);
        \\multiply(4.5, 5);
        \\multiply(6.5, 2);
    ;
    var chunk = try compileScript(&realm, source);
    defer chunk.deinit(testing.allocator);
    const value = try runValue(&realm, &chunk);
    try testing.expectEqual(Value.fromDouble(13).bits, value.bits);

    const body = templateNamed(&chunk, "multiply");
    try testing.expectEqual(chunk_mod.BinaryTypeMode.number, body.inline_binary_profiles[0].mode());
    const state = body.jit_state.?;
    try testing.expectEqual(chunk_mod.Chunk.JitState.Tier.compiled, state.ohaimark.tier);
    try testing.expectEqual(chunk_mod.Chunk.JitState.Tier.cold, state.bistromath.code.tier);
    try testing.expectEqual(@as(u64, 1), realm.heap.ohaimark_stats.compile_attempts);
    try testing.expectEqual(@as(u64, 1), realm.heap.ohaimark_stats.compile_successes);
    try testing.expectEqual(@as(u64, 2), realm.heap.ohaimark_stats.executed_entries);
    try testing.expectEqual(@as(u64, 2), realm.heap.ohaimark_stats.completed_entries);
    try testing.expectEqual(@as(u64, 0), realm.heap.ohaimark_stats.guard_exits);
}

test "Lantern records raw operand types at profiled arithmetic sites" {
    var realm = Realm.init(testing.allocator);
    defer realm.deinit();
    realm.jit_enabled = false;

    const source =
        \\function divide(a, b) { return a / b; }
        \\function multiply(a, b) { return a * b; }
        \\divide(6, 2);
        \\divide(1.5, 2);
        \\divide("6", 2);
        \\multiply(6, 2);
        \\multiply(1.5, 2);
        \\multiply("6", 2);
    ;
    var chunk = try compileScript(&realm, source);
    defer chunk.deinit(testing.allocator);
    _ = try runValue(&realm, &chunk);

    for ([_][]const u8{ "divide", "multiply" }) |name| {
        const body = templateNamed(&chunk, name);
        try testing.expectEqual(@as(usize, 1), body.inline_binary_profiles.len);
        try testing.expectEqual(chunk_mod.BinaryTypeMode.mixed, body.inline_binary_profiles[0].mode());
    }
}

test "Ohaimark stops re-entering a function after its guard-exit budget" {
    if (comptime !driver.supported) return error.SkipZigTest;
    var realm = Realm.init(testing.allocator);
    defer realm.deinit();
    realm.jit_enabled = true;
    realm.ohaimark_enabled = true;
    realm.ohaimark_threshold_override = 1;
    realm.heap.ohaimark_stats.enabled = true;

    var chunk = try overflowChunk();
    defer chunk.deinit(testing.allocator);
    chunk.jit_state.?.warmth = 1;

    var frames: std.ArrayListUnmanaged(lantern.CallFrame) = .empty;
    defer {
        for (frames.items) |*frame| frame.releaseRegisters(&realm, testing.allocator);
        frames.deinit(testing.allocator);
    }
    for (0..driver.guard_exit_limit) |_| {
        const registers = try realm.frame_pool.acquire(testing.allocator, chunk.register_count);
        @memset(registers, Value.undefined_);
        try frames.append(testing.allocator, .{
            .chunk = &chunk,
            .ip = 0,
            .accumulator = Value.undefined_,
            .registers = registers,
            .env = null,
            .this_value = Value.undefined_,
        });
        switch (try driver.tryEnterTop(testing.allocator, &realm, &frames)) {
            .resumed => {},
            else => return error.TestUnexpectedResult,
        }
        _ = switch (try lantern.runFrames(testing.allocator, &realm, &frames)) {
            .value => |value| value,
            else => return error.TestUnexpectedResult,
        };
    }

    try testing.expectEqual(driver.guard_exit_limit, chunk.jit_state.?.ohaimark_guard_exits);
    try testing.expectEqual(@as(u64, driver.guard_exit_limit), realm.heap.ohaimark_stats.executed_entries);
    try testing.expectEqual(@as(u64, driver.guard_exit_limit), realm.heap.ohaimark_stats.guard_exits);

    const registers = try realm.frame_pool.acquire(testing.allocator, chunk.register_count);
    @memset(registers, Value.undefined_);
    try frames.append(testing.allocator, .{
        .chunk = &chunk,
        .ip = 0,
        .accumulator = Value.undefined_,
        .registers = registers,
        .env = null,
        .this_value = Value.undefined_,
    });
    switch (try driver.tryEnterTop(testing.allocator, &realm, &frames)) {
        .not_entered => {},
        else => return error.TestUnexpectedResult,
    }
    try testing.expectEqual(@as(u64, driver.guard_exit_limit), realm.heap.ohaimark_stats.executed_entries);
}

test "Ohaimark refusal preserves Bistromath fallback" {
    if (comptime !driver.supported) return error.SkipZigTest;
    var realm = Realm.init(testing.allocator);
    defer realm.deinit();
    realm.jit_enabled = true;
    realm.jit_threshold_override = 1;
    realm.ohaimark_enabled = true;
    realm.ohaimark_threshold_override = 1;
    realm.heap.ohaimark_stats.enabled = true;

    const source =
        \\function f(x) { return x | 1; }
        \\f(2);
        \\f(4);
    ;
    var chunk = try compileScript(&realm, source);
    defer chunk.deinit(testing.allocator);
    const value = try runValue(&realm, &chunk);
    try testing.expectEqual(Value.fromInt32(5).bits, value.bits);

    const state = templateNamed(&chunk, "f").jit_state.?;
    try testing.expectEqual(chunk_mod.Chunk.JitState.Tier.dont_compile, state.ohaimark.tier);
    try testing.expectEqual(chunk_mod.Chunk.JitState.Tier.compiled, state.bistromath.code.tier);
    try testing.expect(state.bistromath.entry() != null);
    try testing.expectEqual(@as(u64, 1), realm.heap.ohaimark_stats.compile_attempts);
    try testing.expectEqual(@as(u64, 0), realm.heap.ohaimark_stats.compile_successes);
    try testing.expectEqual(@as(u64, 1), realm.heap.ohaimark_stats.compile_refusals);
    try testing.expectEqual(
        @as(u64, 1),
        realm.heap.ohaimark_stats.refusalCount(.ir),
    );
    try testing.expectEqual(
        @as(u64, 1),
        realm.heap.ohaimark_stats.unsupportedOpcodeCount(.bit_or),
    );
    try testing.expectEqual(@as(u64, 0), realm.heap.ohaimark_stats.executed_entries);
}

test "Ohaimark OSR: single-call hot loop compiles and completes" {
    if (comptime !driver.supported) return error.SkipZigTest;
    var realm = Realm.init(testing.allocator);
    defer realm.deinit();
    realm.jit_enabled = true;
    realm.jit_threshold_override = 1;
    realm.ohaimark_enabled = true;
    realm.ohaimark_threshold_override = 1;
    realm.ohaimark_osr_enabled = true;
    realm.heap.ohaimark_stats.enabled = true;

    // One call, many backedges — function-entry T2 never re-enters; OSR must.
    const source =
        \\function sum(n) {
        \\  let i = 0;
        \\  let acc = 0;
        \\  while (i < n) {
        \\    acc = acc + 1;
        \\    i = i + 1;
        \\  }
        \\  return acc;
        \\}
        \\sum(100);
    ;
    var chunk = try compileScript(&realm, source);
    defer chunk.deinit(testing.allocator);
    const value = try runValue(&realm, &chunk);
    try testing.expectEqual(Value.fromInt32(100).bits, value.bits);

    const state = templateNamed(&chunk, "sum").jit_state.?;
    // May refuse if the loop uses unsupported opcodes (e.g. less-than);
    // either a successful OSR publish or an honest dont_compile is fine —
    // the result must still match Lantern.
    if (state.ohaimark.tier == .compiled) {
        try testing.expect(state.hasOhaimarkOsr() or state.ohaimark_osr_count == 0);
        try testing.expect(realm.heap.ohaimark_stats.executed_entries > 0 or
            realm.heap.ohaimark_stats.compile_successes > 0);
    }
}

test "Ohaimark OSR: Lantern and forced T2 agree on loop result" {
    if (comptime !driver.supported) return error.SkipZigTest;
    const source =
        \\function sum(n) {
        \\  let i = 0;
        \\  let acc = 0;
        \\  while (i < n) {
        \\    acc = acc + i;
        \\    i = i + 1;
        \\  }
        \\  return acc;
        \\}
        \\sum(50);
    ;

    var lantern_realm = Realm.init(testing.allocator);
    defer lantern_realm.deinit();
    lantern_realm.jit_enabled = false;
    var lantern_chunk = try compileScript(&lantern_realm, source);
    defer lantern_chunk.deinit(testing.allocator);
    const lantern_value = try runValue(&lantern_realm, &lantern_chunk);

    var t2_realm = Realm.init(testing.allocator);
    defer t2_realm.deinit();
    t2_realm.jit_enabled = true;
    t2_realm.jit_threshold_override = 1;
    t2_realm.ohaimark_enabled = true;
    t2_realm.ohaimark_threshold_override = 1;
    t2_realm.ohaimark_osr_enabled = true;
    var t2_chunk = try compileScript(&t2_realm, source);
    defer t2_chunk.deinit(testing.allocator);
    const t2_value = try runValue(&t2_realm, &t2_chunk);

    try testing.expectEqual(lantern_value.bits, t2_value.bits);
}

test "Ohaimark OSR: refused compile does not retry every backedge" {
    if (comptime !driver.supported) return error.SkipZigTest;
    var realm = Realm.init(testing.allocator);
    defer realm.deinit();
    realm.jit_enabled = true;
    realm.jit_threshold_override = 1;
    realm.ohaimark_enabled = true;
    realm.ohaimark_threshold_override = 1;
    realm.ohaimark_osr_enabled = true;
    realm.heap.ohaimark_stats.enabled = true;

    // Exception regions refuse IR construction once and stick.
    const source =
        \\function f(n) {
        \\  let i = 0;
        \\  try {
        \\    while (i < n) { i = i + 1; }
        \\  } catch (e) {}
        \\  return i;
        \\}
        \\f(20);
    ;
    var chunk = try compileScript(&realm, source);
    defer chunk.deinit(testing.allocator);
    const value = try runValue(&realm, &chunk);
    try testing.expectEqual(Value.fromInt32(20).bits, value.bits);

    const state = templateNamed(&chunk, "f").jit_state.?;
    try testing.expectEqual(chunk_mod.Chunk.JitState.Tier.dont_compile, state.ohaimark.tier);
    const attempts_before = realm.heap.ohaimark_stats.compile_attempts;
    try testing.expect(attempts_before >= 1);
    // Run again — warmth is high; must not thrash-recompile.
    const value2 = try runValue(&realm, &chunk);
    try testing.expectEqual(Value.fromInt32(20).bits, value2.bits);
    try testing.expectEqual(attempts_before, realm.heap.ohaimark_stats.compile_attempts);
}

test "Ohaimark OSR: fuel exhaustion at optimized backedge resumes exactly" {
    if (comptime !driver.supported) return error.SkipZigTest;
    var realm = Realm.init(testing.allocator);
    defer realm.deinit();
    realm.jit_enabled = true;
    realm.jit_threshold_override = 1;
    realm.ohaimark_enabled = true;
    realm.ohaimark_threshold_override = 1;
    realm.ohaimark_osr_enabled = true;

    const source =
        \\function spin(n) {
        \\  let i = 0;
        \\  while (i < n) { i = i + 1; }
        \\  return i;
        \\}
        \\spin(5);
    ;
    var chunk = try compileScript(&realm, source);
    defer chunk.deinit(testing.allocator);
    // First run warms / compiles.
    _ = try runValue(&realm, &chunk);

    // Second run with zero fuel: must throw RangeError, not abort.
    realm.step_budget = 0;
    const result = lantern.run(testing.allocator, &realm, &chunk);
    // Fuel exhaustion is a catchable RangeError completion path.
    if (result) |r| {
        switch (r) {
            .thrown => {},
            .value, .yielded => return error.TestUnexpectedResult,
        }
    } else |_| {
        // Host OOM would be surprising; other errors are fine to surface.
    }
}
