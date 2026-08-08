const std = @import("std");
const builtin = @import("builtin");

const bistromath = @import("bistromath.zig");
const bistro_masm = @import("masm.zig");
const Chunk = @import("../../bytecode/chunk.zig").Chunk;
const code_alloc = @import("../jit/code_alloc.zig");
const lantern = @import("../lantern/interpreter.zig");
const CallFrame = lantern.CallFrame;
const Realm = @import("../realm.zig").Realm;
const Value = @import("../value.zig").Value;

const testing = std.testing;

/// These tests are executable-ABI tests, not cross-assembly tests. Keep them
/// off hosts that cannot execute x86_64 code, but fail (rather than silently
/// skip) on an executable x86_64 target until the backend is enabled.
fn requireNativeBackend() !void {
    if (comptime builtin.cpu.arch != .x86_64 or !code_alloc.supported) {
        return error.SkipZigTest;
    }
    try testing.expect(bistromath.supported);
}

fn evaluateValue(realm: *Realm, source: []const u8) !Value {
    return switch (try lantern.evaluateScript(testing.allocator, realm, source)) {
        .value, .yielded => |value| value,
        .thrown => error.UncaughtException,
    };
}

fn functionNamed(chunk: *const Chunk, name: []const u8) ?*const Chunk {
    for (chunk.function_templates) |*template| {
        if (template.name) |candidate| {
            if (std.mem.eql(u8, candidate, name)) return &template.chunk;
        }
    }
    return null;
}

fn expectCompiledFunction(chunk: *const Chunk, name: []const u8) !*const Chunk {
    const body = functionNamed(chunk, name) orelse return error.FunctionTemplateMissing;
    const state = body.jit_state orelse return error.MissingJitState;
    try testing.expectEqual(Chunk.JitState.Tier.compiled, state.bistromath.code.tier);
    try testing.expect(state.bistromath.entry() != null);
    return body;
}

test "Bistromath x86_64: supported native hosts have a backend" {
    if (comptime builtin.cpu.arch != .x86_64 or !code_alloc.supported) {
        return error.SkipZigTest;
    }

    try testing.expect(bistromath.supported);
}

test "Bistromath x86_64: three-address multiply rejects its private-scratch alias" {
    if (comptime builtin.cpu.arch != .x86_64) return error.SkipZigTest;
    var machine = bistro_masm.Masm.init(testing.allocator);
    defer machine.deinit();

    try testing.expectError(
        error.UnsupportedInstruction,
        machine.emit(bistro_masm.smull(.x0, .x9, .x22)),
    );
}

test "Bistromath x86_64: three-address subtract rejects its private-scratch alias" {
    if (comptime builtin.cpu.arch != .x86_64) return error.SkipZigTest;
    var machine = bistro_masm.Masm.init(testing.allocator);
    defer machine.deinit();

    try testing.expectError(
        error.UnsupportedInstruction,
        machine.emit(bistro_masm.subsRegW(.x0, .x13, .x0)),
    );
}

test "Bistromath x86_64: entry prologue returns done with the accumulator result" {
    try requireNativeBackend();

    var realm = Realm.init(testing.allocator);
    defer realm.deinit();
    realm.jit_enabled = true;
    realm.jit_threshold_override = 1;
    realm.heap.bistromath_stats.enabled = true;

    const value = try evaluateValue(&realm,
        \\function answer() { return 42; }
        \\answer();
        \\answer();
    );
    try testing.expectEqual(Value.fromInt32(42).bits, value.bits);
    try testing.expect(realm.heap.bistromath_stats.executed_entries >= 1);

    const script = realm.script_chunks.items[0];
    const body = try expectCompiledFunction(script, "answer");

    // Invoke the published entry directly once as an ABI probe. This pins the
    // SysV prologue/epilogue contract and the `EntryResult.done` value instead
    // of accepting a result Lantern could have produced after a tier-down.
    const registers = try realm.frame_pool.acquire(testing.allocator, body.register_count);
    defer realm.frame_pool.release(testing.allocator, registers);
    @memset(registers, Value.undefined_);
    var frame: CallFrame = .{
        .chunk = body,
        .ip = 0,
        .accumulator = Value.undefined_,
        .registers = registers,
        .env = null,
        .this_value = Value.undefined_,
    };
    const entry: bistromath.EntryFn = @ptrCast(@alignCast(body.jit_state.?.bistromath.entry().?));
    const verdict: bistromath.EntryResult = @enumFromInt(entry(&realm, &frame, registers.ptr));
    try testing.expectEqual(bistromath.EntryResult.done, verdict);
    try testing.expectEqual(Value.fromInt32(42).bits, frame.accumulator.bits);
}

test "Bistromath x86_64: int32 arithmetic and overflow tier-down stay equivalent" {
    try requireNativeBackend();

    var realm = Realm.init(testing.allocator);
    defer realm.deinit();
    realm.jit_enabled = true;
    realm.jit_threshold_override = 1;

    const value = try evaluateValue(&realm,
        \\function add(a, b) { return a + b; }
        \\add(1, 2);
        \\let fast = add(20, 22);
        \\let overflow = add(2147483647, 1);
        \\(fast === 42 && overflow === 2147483648) ? 1 : 0;
    );
    try testing.expectEqual(Value.fromInt32(1).bits, value.bits);
    _ = try expectCompiledFunction(realm.script_chunks.items[0], "add");
}

test "Bistromath x86_64: forward conditionals and backward loop branches" {
    try requireNativeBackend();

    var realm = Realm.init(testing.allocator);
    defer realm.deinit();
    realm.jit_enabled = true;
    realm.jit_threshold_override = 1;

    const value = try evaluateValue(&realm,
        \\function branchLoop(n) {
        \\  let i = 0;
        \\  let sum = 0;
        \\  while (i < n) {
        \\    if (i < 3) sum = sum + 1;
        \\    else sum = sum + 2;
        \\    i = i + 1;
        \\  }
        \\  return sum;
        \\}
        \\branchLoop(1);
        \\branchLoop(5);
    );
    try testing.expectEqual(Value.fromInt32(7).bits, value.bits);
    _ = try expectCompiledFunction(realm.script_chunks.items[0], "branchLoop");
}

test "Bistromath x86_64: SysV helper call returns a value" {
    try requireNativeBackend();

    var realm = Realm.init(testing.allocator);
    defer realm.deinit();
    realm.jit_enabled = true;
    realm.jit_threshold_override = 1;
    try realm.installBuiltins();

    // Bound functions deliberately cannot occupy a direct-call IC. A
    // compiled `site` therefore reaches `boundAdd` through helperCall,
    // exercising the SysV argument registers and stack alignment.
    const value = try evaluateValue(&realm,
        \\function add(a, b) { return a + b; }
        \\const boundAdd = add.bind(null);
        \\function site(a, b) { return boundAdd(a, b) + 0; }
        \\site(1, 2);
        \\site(20, 22);
    );
    try testing.expectEqual(Value.fromInt32(42).bits, value.bits);
    _ = try expectCompiledFunction(realm.script_chunks.items[0], "site");
}

test "Bistromath x86_64: helper-call exception verdict unwinds" {
    try requireNativeBackend();

    var realm = Realm.init(testing.allocator);
    defer realm.deinit();
    realm.jit_enabled = true;
    realm.jit_threshold_override = 1;
    try realm.installBuiltins();

    const value = try evaluateValue(&realm,
        \\function maybe(flag) { if (flag) throw 9; return 3; }
        \\const boundMaybe = maybe.bind(null);
        \\function site(flag) { return boundMaybe(flag) + 0; }
        \\site(false);
        \\let caught = 0;
        \\try { site(true); } catch (error) { caught = error; }
        \\caught;
    );
    try testing.expectEqual(Value.fromInt32(9).bits, value.bits);
    _ = try expectCompiledFunction(realm.script_chunks.items[0], "site");
}

test "Bistromath x86_64: helper-call host OOM verdict propagates" {
    try requireNativeBackend();

    var realm = Realm.init(testing.allocator);
    defer realm.deinit();
    realm.jit_enabled = true;
    realm.jit_threshold_override = 1;
    try realm.installBuiltins();

    _ = try evaluateValue(&realm,
        \\function allocate(flag) {
        \\  if (flag) return "x".repeat(524288);
        \\  return 0;
        \\}
        \\const boundAllocate = allocate.bind(null);
        \\function oomSite(flag) { return boundAllocate(flag); }
        \\oomSite(false);
        \\oomSite(false);
    );
    _ = try expectCompiledFunction(realm.script_chunks.items[0], "oomSite");

    // Leave room for the tiny follow-up Script and call frame, but not the
    // 512 KiB String payload. helperCall must return `host_oom`; the compiled
    // driver must propagate it as a Zig OOM rather than re-executing the call
    // or turning it into an arbitrary JS exception.
    realm.setMemoryLimit(realm.heap.bytes_live + 64 * 1024);
    try testing.expectError(
        error.OutOfMemory,
        lantern.evaluateScript(testing.allocator, &realm, "oomSite(true);"),
    );
    try testing.expect(realm.terminationReason() == null);
}

test "Bistromath x86_64: helper re-entry roots arguments under GC pressure" {
    try requireNativeBackend();

    var realm = Realm.init(testing.allocator);
    defer realm.deinit();
    realm.jit_enabled = true;
    realm.jit_threshold_override = 1;
    try realm.installBuiltins();
    realm.heap.setGcThreshold(1);

    // `site` is compiled and invokes a bound target through helperCall. The
    // target allocates on every loop iteration, forcing nested runFrames GC
    // safepoints while `rooted` is still live in the compiled caller's
    // register file and in the helper's argument window.
    const value = try evaluateValue(&realm,
        \\function churn(object, n) {
        \\  let i = 0;
        \\  let sum = 0;
        \\  while (i < n) {
        \\    const temporary = { value: i };
        \\    sum = (sum + temporary.value) | 0;
        \\    i = i + 1;
        \\  }
        \\  return (object.value + sum) | 0;
        \\}
        \\const boundChurn = churn.bind(null);
        \\function site(object, n) { return boundChurn(object, n) + 0; }
        \\const rooted = { value: 42 };
        \\site(rooted, 1);
        \\site(rooted, 50);
    );
    try testing.expectEqual(Value.fromInt32(1267).bits, value.bits);
    _ = try expectCompiledFunction(realm.script_chunks.items[0], "site");

    realm.collectGarbage();
    const after_full_gc = try evaluateValue(&realm, "site(rooted, 2);");
    try testing.expectEqual(Value.fromInt32(43).bits, after_full_gc.bits);
}
