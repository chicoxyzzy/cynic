const std = @import("std");

const chunk_mod = @import("../../bytecode/chunk.zig");
const Builder = chunk_mod.Builder;
const compiler_mod = @import("../../bytecode/compiler.zig");
const Op = @import("../../bytecode/op.zig").Op;
const parser_mod = @import("../../parser/parser.zig");
const Span = @import("../../source.zig").Span;
const bistromath = @import("../bistromath/bistromath.zig");
const heap_mod = @import("../heap.zig");
const lantern = @import("../lantern/interpreter.zig");
const Realm = @import("../realm.zig").Realm;
const Value = @import("../value.zig").Value;
const codegen = @import("codegen_aarch64.zig");
const driver = @import("driver.zig");
const ohaimark_compiler = @import("compiler.zig");

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

fn hasOpcode(chunk: *const chunk_mod.Chunk, wanted: Op) bool {
    var pc: usize = 0;
    while (pc < chunk.code.len) {
        const op: Op = @enumFromInt(chunk.code[pc]);
        if (op == wanted) return true;
        pc += 1 + Op.operandSize(op);
    }
    return false;
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

fn callGlobalFunction(realm: *Realm, name: []const u8, args: []const Value) !Value {
    const function = heap_mod.valueAsFunction(realm.globals.get(name) orelse
        return error.GlobalBindingMissing) orelse return error.GlobalBindingNotFunction;
    return switch (try lantern.callJSFunction(
        testing.allocator,
        realm,
        function,
        Value.undefined_,
        args,
    )) {
        .value, .yielded => |value| value,
        .thrown => error.GlobalCallThrew,
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

test "Ohaimark OSR defaults on and follows child realms" {
    var realm = Realm.init(testing.allocator);
    defer realm.deinit();
    try testing.expect(realm.ohaimark_osr_enabled);
    var child = Realm.initChild(&realm);
    defer child.deinit();
    try testing.expect(child.ohaimark_osr_enabled);
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

test "Ohaimark call_method8 hands an IC-hit bytecode callee back to Lantern" {
    if (comptime !driver.supported) return error.SkipZigTest;
    var realm = Realm.init(testing.allocator);
    defer realm.deinit();
    realm.heap.setGcThreshold(1);

    // The identifier argument deliberately avoids `call_property` fusion.
    // `+ 0` keeps the call out of tail position, so the callee must return to
    // the caller's post-call continuation instead of using `tail_call_method`.
    const source =
        \\function method(x) { return this.value + x; }
        \\const target = { value: 40, method };
        \\function invoke(o, x) { return o.method(x) + 0; }
        \\invoke(target, 1);
    ;
    var chunk = try compileScript(&realm, source);
    defer chunk.deinit(testing.allocator);
    const invoke = templateNamed(&chunk, "invoke");
    try testing.expect(hasOpcode(invoke, .call_method8));

    // Warm the property and call ICs in Lantern before permitting T2 to
    // compile the caller. A cold IC is intentionally a transactional tier
    // down, never a speculative call.
    _ = try runValue(&realm, &chunk);
    realm.jit_enabled = true;
    realm.jit_threshold_override = 1;
    realm.ohaimark_enabled = true;
    realm.ohaimark_threshold_override = 1;

    const invoke_fn = heap_mod.valueAsFunction(realm.globals.get("invoke").?) orelse
        return error.TestUnexpectedResult;
    const target = realm.globals.get("target") orelse return error.TestUnexpectedResult;
    const outcome = try lantern.callJSFunction(
        testing.allocator,
        &realm,
        invoke_fn,
        Value.undefined_,
        &.{ target, Value.fromInt32(2) },
    );
    const value = switch (outcome) {
        .value, .yielded => |result| result,
        .thrown => return error.TestUnexpectedResult,
    };
    try testing.expectEqual(Value.fromInt32(42).bits, value.bits);

    const state = invoke.jit_state.?;
    try testing.expectEqual(chunk_mod.Chunk.JitState.Tier.compiled, state.ohaimark.tier);
    try testing.expect(state.ohaimark.entry() != null);
    try testing.expect(state.ohaimark_requires_frame_scope);
    // A direct IC hit must hand off, not consume a guard-exit strike and
    // silently replay the call in Lantern.
    try testing.expectEqual(@as(u16, 0), state.ohaimark_guard_exits);
}

test "Ohaimark compact free calls hand IC-hit bytecode callees back to Lantern" {
    if (comptime !driver.supported) return error.SkipZigTest;
    var realm = Realm.init(testing.allocator);
    defer realm.deinit();
    realm.heap.setGcThreshold(1);

    // A statement call followed by `return` keeps every call out of tail
    // position. The five callers cover the compact arity forms and the generic
    // `call8` form without introducing a property lookup or constructor path.
    // Each Lantern-only callee validates the direct-call operands before the
    // caller resumes at its post-call continuation.
    const source =
        \\function zero() { if (this !== undefined) throw 0; }
        \\function one(a) { if (a !== 1) throw 0; }
        \\function two(a, b) { if (a !== 1 || b !== 2) throw 0; }
        \\function three(a, b, c) { if (a !== 1 || b !== 2 || c !== 3) throw 0; }
        \\function four(a, b, c, d) { if (a !== 1 || b !== 2 || c !== 3 || d !== 4) throw 0; }
        \\function invoke0(fn) { fn(); return 40; }
        \\function invoke1(fn, a) { fn(a); return 41; }
        \\function invoke2(fn, a, b) { fn(a, b); return 43; }
        \\function invoke3(fn, a, b, c) { fn(a, b, c); return 46; }
        \\function invoke4(fn, a, b, c, d) { fn(a, b, c, d); return 50; }
        \\invoke0(zero); invoke1(one, 1); invoke2(two, 1, 2); invoke3(three, 1, 2, 3); invoke4(four, 1, 2, 3, 4);
    ;
    var chunk = try compileScript(&realm, source);
    defer chunk.deinit(testing.allocator);
    try testing.expect(hasOpcode(templateNamed(&chunk, "invoke0"), .call0_8));
    try testing.expect(hasOpcode(templateNamed(&chunk, "invoke1"), .call1_8));
    try testing.expect(hasOpcode(templateNamed(&chunk, "invoke2"), .call2_8));
    try testing.expect(hasOpcode(templateNamed(&chunk, "invoke3"), .call3_8));
    try testing.expect(hasOpcode(templateNamed(&chunk, "invoke4"), .call8));

    // Populate every callee's CallIC while only Lantern is enabled.
    _ = try runValue(&realm, &chunk);
    // The regression targets a compiled caller handing its bytecode callee to
    // Lantern. Keep the validating leaf functions out of both JIT tiers so an
    // unrelated leaf-body refusal cannot obscure that caller contract.
    for ([_][]const u8{ "zero", "one", "two", "three", "four" }) |name| {
        const state = templateNamed(&chunk, name).jit_state.?;
        state.ohaimark.refuse();
        state.bistromath.refuse();
    }
    realm.jit_enabled = true;
    realm.jit_threshold_override = 1;
    realm.ohaimark_enabled = true;
    realm.ohaimark_threshold_override = 1;
    realm.heap.ohaimark_stats.enabled = true;

    const zero_fn = realm.globals.get("zero") orelse return error.TestUnexpectedResult;
    const one_fn = realm.globals.get("one") orelse return error.TestUnexpectedResult;
    const two_fn = realm.globals.get("two") orelse return error.TestUnexpectedResult;
    const three_fn = realm.globals.get("three") orelse return error.TestUnexpectedResult;
    const four_fn = realm.globals.get("four") orelse return error.TestUnexpectedResult;

    try testing.expectEqual(Value.fromInt32(40).bits, (try callGlobalFunction(&realm, "invoke0", &.{zero_fn})).bits);
    try testing.expectEqual(Value.fromInt32(41).bits, (try callGlobalFunction(&realm, "invoke1", &.{ one_fn, Value.fromInt32(1) })).bits);
    try testing.expectEqual(Value.fromInt32(43).bits, (try callGlobalFunction(&realm, "invoke2", &.{ two_fn, Value.fromInt32(1), Value.fromInt32(2) })).bits);
    try testing.expectEqual(Value.fromInt32(46).bits, (try callGlobalFunction(&realm, "invoke3", &.{ three_fn, Value.fromInt32(1), Value.fromInt32(2), Value.fromInt32(3) })).bits);
    try testing.expectEqual(Value.fromInt32(50).bits, (try callGlobalFunction(&realm, "invoke4", &.{ four_fn, Value.fromInt32(1), Value.fromInt32(2), Value.fromInt32(3), Value.fromInt32(4) })).bits);

    for ([_][]const u8{ "invoke0", "invoke1", "invoke2", "invoke3", "invoke4" }) |name| {
        const state = templateNamed(&chunk, name).jit_state.?;
        try testing.expectEqual(chunk_mod.Chunk.JitState.Tier.compiled, state.ohaimark.tier);
        try testing.expect(state.ohaimark.entry() != null);
        // All five must take the direct handoff rather than silently replaying
        // their call in Lantern through a guard exit.
        try testing.expectEqual(@as(u16, 0), state.ohaimark_guard_exits);
    }
}

test "Ohaimark new_call8 hands an IC-hit constructor back to Lantern" {
    if (comptime !driver.supported) return error.SkipZigTest;
    var realm = Realm.init(testing.allocator);
    defer realm.deinit();
    realm.heap.setGcThreshold(1);

    // The constructor remains interpreted so this exercises the exact frame
    // handoff boundary: `new.target`, the allocated receiver, and the
    // §10.2.2 object-return verdict must all survive before the caller reads
    // the result. `invoke`'s formal constructor argument keeps this focused on
    // `new_call8`, rather than a separate global-load specialization.
    const source =
        \\function Box(x) {
        \\  if (new.target !== Box || x !== 41) throw 0;
        \\  this.value = x;
        \\  return { value: x + 1 };
        \\}
        \\function invoke(C, x) { return new C(x).value; }
        \\invoke(Box, 41);
    ;
    var chunk = try compileScript(&realm, source);
    defer chunk.deinit(testing.allocator);
    const invoke = templateNamed(&chunk, "invoke");
    try testing.expect(hasOpcode(invoke, .new_call8));

    // Warm the constructor and property ICs while Lantern owns all frames.
    _ = try runValue(&realm, &chunk);
    const box_state = templateNamed(&chunk, "Box").jit_state.?;
    box_state.ohaimark.refuse();
    box_state.bistromath.refuse();

    realm.jit_enabled = true;
    realm.jit_threshold_override = 1;
    realm.ohaimark_enabled = true;
    realm.ohaimark_threshold_override = 1;

    const box = realm.globals.get("Box") orelse return error.TestUnexpectedResult;
    try testing.expectEqual(
        Value.fromInt32(42).bits,
        (try callGlobalFunction(&realm, "invoke", &.{ box, Value.fromInt32(41) })).bits,
    );

    const state = invoke.jit_state.?;
    try testing.expectEqual(chunk_mod.Chunk.JitState.Tier.compiled, state.ohaimark.tier);
    try testing.expect(state.ohaimark.entry() != null);
    // A mature constructor IC must hand the child frame off. A tier-down would
    // still produce 42, but it must be observable as a guard exit here.
    try testing.expectEqual(@as(u16, 0), state.ohaimark_guard_exits);
}

test "Ohaimark new_call8 IC misses replay in Lantern" {
    if (comptime !driver.supported) return error.SkipZigTest;
    var realm = Realm.init(testing.allocator);
    defer realm.deinit();
    realm.heap.setGcThreshold(1);

    const source =
        \\function first(x) { this.value = x; }
        \\function second(x) { this.value = x + 40; }
        \\function invoke(C, x) { return new C(x); }
    ;
    var chunk = try compileScript(&realm, source);
    defer chunk.deinit(testing.allocator);
    const invoke = templateNamed(&chunk, "invoke");
    try testing.expect(hasOpcode(invoke, .new_call8));

    // Install globals but leave `invoke` cold so the first T2 entry must
    // reconstruct its pre-construct frame and let Lantern fill the CallIC.
    _ = try runValue(&realm, &chunk);
    for ([_][]const u8{ "first", "second" }) |name| {
        const state = templateNamed(&chunk, name).jit_state.?;
        state.ohaimark.refuse();
        state.bistromath.refuse();
    }
    realm.jit_enabled = true;
    realm.jit_threshold_override = 1;
    realm.ohaimark_enabled = true;
    realm.ohaimark_threshold_override = 1;

    const first = realm.globals.get("first") orelse return error.TestUnexpectedResult;
    const second = realm.globals.get("second") orelse return error.TestUnexpectedResult;

    const cold_result = try callGlobalFunction(&realm, "invoke", &.{ first, Value.fromInt32(1) });
    const cold_instance = heap_mod.valueAsPlainObject(cold_result) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(Value.fromInt32(1).bits, cold_instance.get("value").bits);
    const state = invoke.jit_state.?;
    try testing.expectEqual(chunk_mod.Chunk.JitState.Tier.compiled, state.ohaimark.tier);
    try testing.expectEqual(@as(u16, 1), state.ohaimark_guard_exits);

    // The monomorphic hit allocates and hands off a real construct frame; it
    // must not produce another guard exit.
    const hit_result = try callGlobalFunction(&realm, "invoke", &.{ first, Value.fromInt32(1) });
    const hit_instance = heap_mod.valueAsPlainObject(hit_result) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(Value.fromInt32(1).bits, hit_instance.get("value").bits);
    try testing.expectEqual(@as(u16, 1), state.ohaimark_guard_exits);

    // A different constructor must not use the stale cached prototype or
    // target. Lantern replays the opcode and returns the second constructor's
    // distinguishable result.
    const mismatch_result = try callGlobalFunction(&realm, "invoke", &.{ second, Value.fromInt32(2) });
    const mismatch_instance = heap_mod.valueAsPlainObject(mismatch_result) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(Value.fromInt32(42).bits, mismatch_instance.get("value").bits);
    try testing.expectEqual(@as(u16, 2), state.ohaimark_guard_exits);
}

test "Ohaimark call_property8 hands an own-data IC hit to Lantern" {
    if (comptime !driver.supported) return error.SkipZigTest;
    var realm = Realm.init(testing.allocator);
    defer realm.deinit();
    realm.heap.setGcThreshold(1);

    // The literal argument and `+ 0` keep the call non-tail, so the compiler
    // chooses the fused `call_property8` form. Keep the callee interpreted so
    // this validates the staged caller frame, receiver binding, and child
    // handoff rather than a separately compiled leaf.
    const source =
        \\function addOne(x) {
        \\  if (this.base !== 41 || x !== 1) throw 0;
        \\  return this.base + x;
        \\}
        \\function invoke(receiver) { return receiver.method(1) + 0; }
        \\var receiver = { base: 41, method: addOne };
        \\function getReceiver() { return receiver; }
        \\invoke(receiver);
    ;
    var chunk = try compileScript(&realm, source);
    defer chunk.deinit(testing.allocator);
    const invoke = templateNamed(&chunk, "invoke");
    try testing.expect(hasOpcode(invoke, .call_property8));

    // Populate both the property and call ICs while Lantern owns all frames.
    _ = try runValue(&realm, &chunk);
    const add_state = templateNamed(&chunk, "addOne").jit_state.?;
    add_state.ohaimark.refuse();
    add_state.bistromath.refuse();
    const receiver = try callGlobalFunction(&realm, "getReceiver", &.{});

    realm.jit_enabled = true;
    realm.jit_threshold_override = 1;
    realm.ohaimark_enabled = true;
    realm.ohaimark_threshold_override = 1;

    try testing.expectEqual(
        Value.fromInt32(42).bits,
        (try callGlobalFunction(&realm, "invoke", &.{receiver})).bits,
    );

    const state = invoke.jit_state.?;
    try testing.expectEqual(chunk_mod.Chunk.JitState.Tier.compiled, state.ohaimark.tier);
    try testing.expect(state.ohaimark.entry() != null);
    // A mature own-data load/call pair must hand the callee frame to Lantern
    // directly. A replay would still return 42, but is visible as an exit.
    try testing.expectEqual(@as(u16, 0), state.ohaimark_guard_exits);
}

test "Ohaimark compiled computed own load preserves key recovery under GC pressure" {
    if (comptime !driver.supported) return error.SkipZigTest;
    var realm = Realm.init(testing.allocator);
    defer realm.deinit();

    const source =
        \\function read(receiver, key) { return receiver[key]; }
        \\var record = { x: 42, y: 99 };
        \\read(record, "x");
    ;
    var chunk = try compileScript(&realm, source);
    defer chunk.deinit(testing.allocator);
    const read = templateNamed(&chunk, "read");
    try testing.expect(hasOpcode(read, .lda_computed8));

    // Train the shape/key cell in Lantern first, then force every subsequent
    // allocation through a young-GC boundary while native code is active.
    _ = try runValue(&realm, &chunk);
    realm.jit_enabled = true;
    realm.jit_threshold_override = 1;
    realm.ohaimark_enabled = true;
    realm.ohaimark_threshold_override = 1;
    realm.heap.setGcThreshold(1);
    realm.heap.ohaimark_stats.enabled = true;

    const scope = try realm.heap.openScope();
    defer scope.close();
    const key_x = Value.fromString(try realm.heap.allocateString("x"));
    const key_y = Value.fromString(try realm.heap.allocateString("y"));
    try scope.push(key_x);
    try scope.push(key_y);
    const record = realm.globals.get("record") orelse return error.TestUnexpectedResult;

    try testing.expectEqual(
        Value.fromInt32(42).bits,
        (try callGlobalFunction(&realm, "read", &.{ record, key_x })).bits,
    );
    const state = read.jit_state.?;
    try testing.expectEqual(chunk_mod.Chunk.JitState.Tier.compiled, state.ohaimark.tier);
    try testing.expectEqual(@as(u16, 0), state.ohaimark_guard_exits);

    // The compiled lane must reconstruct the accumulator as the original key
    // so Lantern can perform the full computed property semantics and refill.
    try testing.expectEqual(
        Value.fromInt32(99).bits,
        (try callGlobalFunction(&realm, "read", &.{ record, key_y })).bits,
    );
    try testing.expectEqual(@as(u16, 1), state.ohaimark_guard_exits);
}

test "Ohaimark compiled computed own store preserves value recovery under GC pressure" {
    if (comptime !driver.supported) return error.SkipZigTest;
    var realm = Realm.init(testing.allocator);
    defer realm.deinit();

    const source =
        \\function write(receiver, key, value) { receiver[key] = value; return receiver[key]; }
        \\var record = { x: 0, y: 0 };
        \\write(record, "x", 1);
    ;
    var chunk = try compileScript(&realm, source);
    defer chunk.deinit(testing.allocator);
    const write = templateNamed(&chunk, "write");
    try testing.expect(hasOpcode(write, .sta_computed8));

    // Lantern first trains both the writable-own-data store cell and the
    // following read cell. Native writes then run with allocation-pressure
    // collection enabled so the store barrier is part of the tested contract.
    _ = try runValue(&realm, &chunk);
    realm.jit_enabled = true;
    realm.jit_threshold_override = 1;
    realm.ohaimark_enabled = true;
    realm.ohaimark_threshold_override = 1;
    realm.heap.setGcThreshold(1);
    realm.heap.ohaimark_stats.enabled = true;

    const scope = try realm.heap.openScope();
    defer scope.close();
    const key_x = Value.fromString(try realm.heap.allocateString("x"));
    const key_y = Value.fromString(try realm.heap.allocateString("y"));
    const payload = heap_mod.taggedObject(try realm.heap.allocateObject());
    try scope.push(key_x);
    try scope.push(key_y);
    try scope.push(payload);
    const record = realm.globals.get("record") orelse return error.TestUnexpectedResult;

    try testing.expectEqual(
        payload.bits,
        (try callGlobalFunction(&realm, "write", &.{ record, key_x, payload })).bits,
    );
    const state = write.jit_state.?;
    try testing.expectEqual(chunk_mod.Chunk.JitState.Tier.compiled, state.ohaimark.tier);
    try testing.expectEqual(@as(u16, 0), state.ohaimark_guard_exits);

    // The generated store is compiled for x. A y key must reconstruct the
    // assignment value in the accumulator so Lantern writes and returns it;
    // restoring the key here would corrupt `receiver[key] = value`.
    try testing.expectEqual(
        Value.fromInt32(99).bits,
        (try callGlobalFunction(&realm, "write", &.{ record, key_y, Value.fromInt32(99) })).bits,
    );
    try testing.expectEqual(@as(u16, 1), state.ohaimark_guard_exits);
}

test "Ohaimark compiles checked relational operators and fused less-than branches" {
    if (comptime !driver.supported) return error.SkipZigTest;
    var realm = Realm.init(testing.allocator);
    defer realm.deinit();

    const source =
        \\function greater(a, b) { return a > b; }
        \\function atLeast(a, b) { return a >= b; }
        \\function choose(a, b) { if (a < b) return 11; return 22; }
        \\greater(9, 8); atLeast(8, 8); choose(7, 8);
    ;
    var chunk = try compileScript(&realm, source);
    defer chunk.deinit(testing.allocator);
    const greater = templateNamed(&chunk, "greater");
    const at_least = templateNamed(&chunk, "atLeast");
    const choose = templateNamed(&chunk, "choose");
    try testing.expect(hasOpcode(greater, .gt));
    try testing.expect(hasOpcode(at_least, .ge));
    try testing.expect(
        hasOpcode(choose, .jmp_if_not_lt8) or
            hasOpcode(choose, .jmp_if_not_lt) or
            hasOpcode(choose, .jmp_if_not_lt32),
    );

    // Establish the normal Lantern behavior first, then compile the same
    // bytecodes. A Double later must reconstruct the original relational op.
    _ = try runValue(&realm, &chunk);
    realm.jit_enabled = true;
    realm.jit_threshold_override = 1;
    realm.ohaimark_enabled = true;
    realm.ohaimark_threshold_override = 1;

    try testing.expectEqual(Value.true_.bits, (try callGlobalFunction(&realm, "greater", &.{ Value.fromInt32(9), Value.fromInt32(8) })).bits);
    try testing.expectEqual(Value.true_.bits, (try callGlobalFunction(&realm, "atLeast", &.{ Value.fromInt32(8), Value.fromInt32(8) })).bits);
    try testing.expectEqual(Value.fromInt32(11).bits, (try callGlobalFunction(&realm, "choose", &.{ Value.fromInt32(7), Value.fromInt32(8) })).bits);

    for ([_]*const chunk_mod.Chunk{ greater, at_least, choose }) |function| {
        const state = function.jit_state.?;
        try testing.expectEqual(chunk_mod.Chunk.JitState.Tier.compiled, state.ohaimark.tier);
        try testing.expect(state.ohaimark.entry() != null);
        try testing.expectEqual(@as(u16, 0), state.ohaimark_guard_exits);
    }

    const low = Value.fromDouble(1.5);
    const high = Value.fromDouble(2.5);
    try testing.expectEqual(Value.false_.bits, (try callGlobalFunction(&realm, "greater", &.{ low, high })).bits);
    try testing.expectEqual(Value.false_.bits, (try callGlobalFunction(&realm, "atLeast", &.{ low, high })).bits);
    try testing.expectEqual(Value.fromInt32(11).bits, (try callGlobalFunction(&realm, "choose", &.{ low, high })).bits);
    try testing.expectEqual(@as(u16, 1), greater.jit_state.?.ohaimark_guard_exits);
    try testing.expectEqual(@as(u16, 1), at_least.jit_state.?.ohaimark_guard_exits);
    try testing.expectEqual(@as(u16, 1), choose.jit_state.?.ohaimark_guard_exits);
}

test "Ohaimark compiles register updates and replays overflow in Lantern" {
    if (comptime !driver.supported) return error.SkipZigTest;
    var realm = Realm.init(testing.allocator);
    defer realm.deinit();

    const source =
        \\function increment(value) { value++; return value; }
        \\function decrement(value) { value--; return value; }
    ;
    var chunk = try compileScript(&realm, source);
    defer chunk.deinit(testing.allocator);
    _ = try runValue(&realm, &chunk);
    const increment = templateNamed(&chunk, "increment");
    const decrement = templateNamed(&chunk, "decrement");
    try testing.expect(hasOpcode(increment, .inc_reg));
    try testing.expect(hasOpcode(decrement, .dec_reg));

    realm.jit_enabled = true;
    realm.jit_threshold_override = 1;
    realm.ohaimark_enabled = true;
    realm.ohaimark_threshold_override = 1;

    try testing.expectEqual(
        Value.fromInt32(42).bits,
        (try callGlobalFunction(&realm, "increment", &.{Value.fromInt32(41)})).bits,
    );
    try testing.expectEqual(
        Value.fromInt32(40).bits,
        (try callGlobalFunction(&realm, "decrement", &.{Value.fromInt32(41)})).bits,
    );
    for ([_]*const chunk_mod.Chunk{ increment, decrement }) |function| {
        const state = function.jit_state.?;
        try testing.expectEqual(chunk_mod.Chunk.JitState.Tier.compiled, state.ohaimark.tier);
        try testing.expect(state.ohaimark.entry() != null);
        try testing.expectEqual(@as(u16, 0), state.ohaimark_guard_exits);
    }

    try testing.expectEqual(
        Value.fromDouble(@as(f64, @floatFromInt(std.math.maxInt(i32))) + 1.0).bits,
        (try callGlobalFunction(&realm, "increment", &.{Value.fromInt32(std.math.maxInt(i32))})).bits,
    );
    try testing.expectEqual(
        Value.fromDouble(@as(f64, @floatFromInt(std.math.minInt(i32))) - 1.0).bits,
        (try callGlobalFunction(&realm, "decrement", &.{Value.fromInt32(std.math.minInt(i32))})).bits,
    );
    try testing.expectEqual(@as(u16, 1), increment.jit_state.?.ohaimark_guard_exits);
    try testing.expectEqual(@as(u16, 1), decrement.jit_state.?.ohaimark_guard_exits);
}

test "Ohaimark compiles result-preserving register updates and replays overflow in Lantern" {
    if (comptime !driver.supported) return error.SkipZigTest;
    var realm = Realm.init(testing.allocator);
    defer realm.deinit();

    const source =
        \\function postfixIncrement(value) { return value++; }
        \\function postfixDecrement(value) { return value--; }
    ;
    var chunk = try compileScript(&realm, source);
    defer chunk.deinit(testing.allocator);
    _ = try runValue(&realm, &chunk);
    const increment = templateNamed(&chunk, "postfixIncrement");
    const postfix = templateNamed(&chunk, "postfixDecrement");
    try testing.expect(hasOpcode(increment, .post_inc_reg));
    try testing.expect(hasOpcode(postfix, .post_dec_reg));

    realm.jit_enabled = true;
    realm.jit_threshold_override = 1;
    realm.ohaimark_enabled = true;
    realm.ohaimark_threshold_override = 1;

    try testing.expectEqual(
        Value.fromInt32(41).bits,
        (try callGlobalFunction(&realm, "postfixIncrement", &.{Value.fromInt32(41)})).bits,
    );
    try testing.expectEqual(
        Value.fromInt32(41).bits,
        (try callGlobalFunction(&realm, "postfixDecrement", &.{Value.fromInt32(41)})).bits,
    );
    for ([_]*const chunk_mod.Chunk{ increment, postfix }) |function| {
        const state = function.jit_state.?;
        try testing.expectEqual(chunk_mod.Chunk.JitState.Tier.compiled, state.ohaimark.tier);
        try testing.expect(state.ohaimark.entry() != null);
        try testing.expectEqual(@as(u16, 0), state.ohaimark_guard_exits);
    }

    try testing.expectEqual(
        Value.fromInt32(std.math.maxInt(i32)).bits,
        (try callGlobalFunction(&realm, "postfixIncrement", &.{Value.fromInt32(std.math.maxInt(i32))})).bits,
    );
    try testing.expectEqual(
        Value.fromInt32(std.math.minInt(i32)).bits,
        (try callGlobalFunction(&realm, "postfixDecrement", &.{Value.fromInt32(std.math.minInt(i32))})).bits,
    );
    try testing.expectEqual(@as(u16, 1), increment.jit_state.?.ohaimark_guard_exits);
    try testing.expectEqual(@as(u16, 1), postfix.jit_state.?.ohaimark_guard_exits);
}

test "Ohaimark tail dispatch preserves Lantern proper-tail-call reuse" {
    if (comptime !driver.supported) return error.SkipZigTest;
    var realm = Realm.init(testing.allocator);
    defer realm.deinit();

    const source =
        \\function leaf(value) { return value + 1; }
        \\function tailPlain(fn, value) { return fn(value); }
        \\function tailMethod(receiver, value) { return receiver.step(value); }
    ;
    var chunk = try compileScript(&realm, source);
    defer chunk.deinit(testing.allocator);
    _ = try runValue(&realm, &chunk);
    const plain = templateNamed(&chunk, "tailPlain");
    const method = templateNamed(&chunk, "tailMethod");
    try testing.expect(hasOpcode(plain, .tail_call));
    try testing.expect(hasOpcode(method, .tail_call_method));

    const scope = try realm.heap.openScope();
    defer scope.close();
    const target = try realm.heap.allocateObject();
    realm.heap.setObjectPrototype(target, realm.intrinsics.object_prototype);
    const leaf = realm.globals.get("leaf") orelse return error.GlobalBindingMissing;
    try realm.heap.storeProperty(target, realm.allocator, "step", leaf);
    const target_value = heap_mod.taggedObject(target);
    try scope.push(target_value);

    // Prime the method path's named-load IC in Lantern before T2 owns the
    // optimized prefixes.
    _ = try callGlobalFunction(&realm, "tailPlain", &.{ leaf, Value.fromInt32(41) });
    _ = try callGlobalFunction(&realm, "tailMethod", &.{ target_value, Value.fromInt32(41) });
    const leaf_state = templateNamed(&chunk, "leaf").jit_state.?;
    leaf_state.ohaimark.refuse();
    leaf_state.bistromath.refuse();

    realm.jit_enabled = true;
    realm.jit_threshold_override = 1;
    realm.ohaimark_enabled = true;
    realm.ohaimark_threshold_override = 1;

    try testing.expectEqual(
        Value.fromInt32(42).bits,
        (try callGlobalFunction(&realm, "tailPlain", &.{ leaf, Value.fromInt32(41) })).bits,
    );
    try testing.expectEqual(
        Value.fromInt32(42).bits,
        (try callGlobalFunction(&realm, "tailMethod", &.{ target_value, Value.fromInt32(41) })).bits,
    );
    const plain_state = plain.jit_state.?;
    try testing.expectEqual(chunk_mod.Chunk.JitState.Tier.compiled, plain_state.ohaimark.tier);
    try testing.expect(plain_state.ohaimark.entry() != null);
    // Tail dispatch is intentionally a terminal Lantern resume, not a native
    // call, so it consumes one normal guard-exit budget.
    try testing.expectEqual(@as(u16, 1), plain_state.ohaimark_guard_exits);
    const method_state = method.jit_state.?;
    try testing.expectEqual(chunk_mod.Chunk.JitState.Tier.compiled, method_state.ohaimark.tier);
    try testing.expect(method_state.ohaimark.entry() != null);
    try testing.expectEqual(@as(u16, 1), method_state.ohaimark_guard_exits);
}

test "Ohaimark computed delete uses the ordinary fast path and replays observable cases" {
    if (comptime !driver.supported) return error.SkipZigTest;
    var realm = Realm.init(testing.allocator);
    defer realm.deinit();
    realm.heap.setGcThreshold(1);

    const source =
        \\function erase(receiver, key) { return delete receiver[key]; }
        \\var coercible = { toString: function() { return "y"; } };
    ;
    var chunk = try compileScript(&realm, source);
    defer chunk.deinit(testing.allocator);
    _ = try runValue(&realm, &chunk);
    const erase = templateNamed(&chunk, "erase");
    try testing.expect(hasOpcode(erase, .del_computed_property));

    const scope = try realm.heap.openScope();
    defer scope.close();
    const key_x = Value.fromString(try realm.heap.allocateString("x"));
    try scope.push(key_x);
    const ordinary = try realm.heap.allocateObject();
    const missing = try realm.heap.allocateObject();
    const locked = try realm.heap.allocateObject();
    realm.heap.setObjectPrototype(ordinary, realm.intrinsics.object_prototype);
    realm.heap.setObjectPrototype(missing, realm.intrinsics.object_prototype);
    realm.heap.setObjectPrototype(locked, realm.intrinsics.object_prototype);
    try realm.heap.storeProperty(ordinary, realm.allocator, "x", Value.fromInt32(1));
    try locked.setWithFlags(realm.allocator, "x", Value.fromInt32(1), .{
        .configurable = false,
    });
    const ordinary_value = heap_mod.taggedObject(ordinary);
    const missing_value = heap_mod.taggedObject(missing);
    const locked_value = heap_mod.taggedObject(locked);
    try scope.push(ordinary_value);
    try scope.push(missing_value);
    try scope.push(locked_value);

    realm.jit_enabled = true;
    realm.jit_threshold_override = 1;
    realm.ohaimark_enabled = true;
    realm.ohaimark_threshold_override = 1;

    // Deleting an own data property demotes shape storage under allocation
    // pressure, so the staged frame must keep both receiver and key alive.
    try testing.expectEqual(
        Value.true_.bits,
        (try callGlobalFunction(&realm, "erase", &.{ ordinary_value, key_x })).bits,
    );
    try testing.expect(!ordinary.ownDataContains("x"));
    // A missing ordinary key is also a native success and must not allocate.
    try testing.expectEqual(
        Value.true_.bits,
        (try callGlobalFunction(&realm, "erase", &.{ missing_value, key_x })).bits,
    );
    const state = erase.jit_state.?;
    try testing.expectEqual(chunk_mod.Chunk.JitState.Tier.compiled, state.ohaimark.tier);
    try testing.expectEqual(@as(u16, 0), state.ohaimark_guard_exits);

    // The helper must decline before touching a non-configurable property so
    // Lantern owns the strict-mode TypeError path and the property survives.
    try testing.expectError(
        error.GlobalCallThrew,
        callGlobalFunction(&realm, "erase", &.{ locked_value, key_x }),
    );
    try testing.expect(locked.ownDataContains("x"));
    try testing.expectEqual(@as(u16, 1), state.ohaimark_guard_exits);

    // An object key runs ToPropertyKey and can execute user code. The native
    // helper must restore the exact pre-op state before Lantern calls it.
    const coercion_target = try realm.heap.allocateObject();
    realm.heap.setObjectPrototype(coercion_target, realm.intrinsics.object_prototype);
    try realm.heap.storeProperty(coercion_target, realm.allocator, "y", Value.fromInt32(1));
    const coercion_target_value = heap_mod.taggedObject(coercion_target);
    try scope.push(coercion_target_value);
    const coercible = realm.globals.get("coercible") orelse return error.TestUnexpectedResult;
    try testing.expectEqual(
        Value.true_.bits,
        (try callGlobalFunction(&realm, "erase", &.{ coercion_target_value, coercible })).bits,
    );
    try testing.expect(!coercion_target.ownDataContains("y"));
    try testing.expectEqual(@as(u16, 2), state.ohaimark_guard_exits);
}

test "Ohaimark call_property8 cold and prototype IC misses replay in Lantern" {
    if (comptime !driver.supported) return error.SkipZigTest;
    var realm = Realm.init(testing.allocator);
    defer realm.deinit();
    realm.heap.setGcThreshold(1);

    // `+ 0` keeps the property call non-tail, where the compiler may emit its
    // fused `call_property8` form instead of the tail-call opcode.
    const source =
        \\function first(x) { return this.base + x; }
        \\function second(x) { return this.base + x + 40; }
        \\function FirstBox() { this.base = 1; }
        \\function SecondBox() { this.base = 1; }
        \\FirstBox.prototype.method = first;
        \\SecondBox.prototype.method = second;
        \\function invoke(receiver) { return receiver.method(1) + 0; }
        \\var firstReceiver = new FirstBox();
        \\var secondReceiver = new SecondBox();
        \\function getFirstReceiver() { return firstReceiver; }
        \\function getSecondReceiver() { return secondReceiver; }
    ;
    var chunk = try compileScript(&realm, source);
    defer chunk.deinit(testing.allocator);
    const invoke = templateNamed(&chunk, "invoke");
    try testing.expect(hasOpcode(invoke, .call_property8));

    // Install the objects but deliberately leave this site's LoadIC and
    // CallIC cold. The first T2 entry must reconstruct the pre-op frame and
    // let Lantern perform EvaluateCall and populate both cells.
    _ = try runValue(&realm, &chunk);
    for ([_][]const u8{ "first", "second" }) |name| {
        const state = templateNamed(&chunk, name).jit_state.?;
        state.ohaimark.refuse();
        state.bistromath.refuse();
    }
    const first_receiver = try callGlobalFunction(&realm, "getFirstReceiver", &.{});
    const second_receiver = try callGlobalFunction(&realm, "getSecondReceiver", &.{});
    realm.jit_enabled = true;
    realm.jit_threshold_override = 1;
    realm.ohaimark_enabled = true;
    realm.ohaimark_threshold_override = 1;

    const first_object = heap_mod.valueAsPlainObject(first_receiver) orelse return error.TestUnexpectedResult;
    const second_object = heap_mod.valueAsPlainObject(second_receiver) orelse return error.TestUnexpectedResult;
    // Same own shape isolates the second miss to the immediate-prototype
    // identity guard rather than a receiver-shape transition.
    try testing.expect(first_object.shape == second_object.shape);
    try testing.expect(first_object.prototype != second_object.prototype);

    try testing.expectEqual(
        Value.fromInt32(2).bits,
        (try callGlobalFunction(&realm, "invoke", &.{first_receiver})).bits,
    );
    const state = invoke.jit_state.?;
    try testing.expectEqual(chunk_mod.Chunk.JitState.Tier.compiled, state.ohaimark.tier);
    try testing.expectEqual(@as(u16, 1), state.ohaimark_guard_exits);

    // Both cells are now monomorphic for FirstBox.prototype, so the child
    // method frame is handed off without another guard exit.
    try testing.expectEqual(
        Value.fromInt32(2).bits,
        (try callGlobalFunction(&realm, "invoke", &.{first_receiver})).bits,
    );
    try testing.expectEqual(@as(u16, 1), state.ohaimark_guard_exits);

    // The receiver has the same own shape but a different immediate
    // prototype and method. Replaying prevents calling the stale target.
    try testing.expectEqual(
        Value.fromInt32(42).bits,
        (try callGlobalFunction(&realm, "invoke", &.{second_receiver})).bits,
    );
    try testing.expectEqual(@as(u16, 2), state.ohaimark_guard_exits);
}

test "Ohaimark compact free-call IC misses replay in Lantern" {
    if (comptime !driver.supported) return error.SkipZigTest;
    var realm = Realm.init(testing.allocator);
    defer realm.deinit();
    realm.heap.setGcThreshold(1);

    const source =
        \\function first(a) { if (this !== undefined || a !== 1) throw 0; }
        \\function second(a) { if (a !== 2) throw 0; }
        \\function invoke(fn, a) { fn(a); return 42; }
    ;
    var chunk = try compileScript(&realm, source);
    defer chunk.deinit(testing.allocator);
    const invoke = templateNamed(&chunk, "invoke");
    try testing.expect(hasOpcode(invoke, .call1_8));

    // Install the global bindings without executing the inner call. Both
    // leaves stay interpreted so a successful fallback proves that Lantern
    // retried the original bytecode operation.
    _ = try runValue(&realm, &chunk);
    for ([_][]const u8{ "first", "second" }) |name| {
        const state = templateNamed(&chunk, name).jit_state.?;
        state.ohaimark.refuse();
        state.bistromath.refuse();
    }
    realm.jit_enabled = true;
    realm.jit_threshold_override = 1;
    realm.ohaimark_enabled = true;
    realm.ohaimark_threshold_override = 1;

    const first_fn = realm.globals.get("first") orelse return error.TestUnexpectedResult;
    const second_fn = realm.globals.get("second") orelse return error.TestUnexpectedResult;

    // The first entry compiles `invoke`, sees a cold CallIC, and resumes
    // Lantern at `call1_8`, which executes `first` and fills the cache.
    try testing.expectEqual(Value.fromInt32(42).bits, (try callGlobalFunction(&realm, "invoke", &.{ first_fn, Value.fromInt32(1) })).bits);
    const state = invoke.jit_state.?;
    try testing.expectEqual(chunk_mod.Chunk.JitState.Tier.compiled, state.ohaimark.tier);
    try testing.expectEqual(@as(u16, 1), state.ohaimark_guard_exits);

    // The monomorphic hit now hands the same caller off without a new exit.
    try testing.expectEqual(Value.fromInt32(42).bits, (try callGlobalFunction(&realm, "invoke", &.{ first_fn, Value.fromInt32(1) })).bits);
    try testing.expectEqual(@as(u16, 1), state.ohaimark_guard_exits);

    // A different callable at the same site must replay, rather than invoke
    // the stale cached target or skip the call.
    try testing.expectEqual(Value.fromInt32(42).bits, (try callGlobalFunction(&realm, "invoke", &.{ second_fn, Value.fromInt32(2) })).bits);
    try testing.expectEqual(@as(u16, 2), state.ohaimark_guard_exits);
}

test "Ohaimark explicit throw resumes Lantern catch and finally under GC pressure" {
    if (comptime !driver.supported) return error.SkipZigTest;
    var realm = Realm.init(testing.allocator);
    defer realm.deinit();

    const source =
        \\function makePair() {
        \\  var finalizations = 0;
        \\  function guarded(shouldThrow, value) {
        \\    try {
        \\      if (shouldThrow) throw value;
        \\      return 1;
        \\    } catch (caught) {
        \\      return caught === value ? 47 : 0;
        \\    } finally {
        \\      finalizations = finalizations + 1;
        \\    }
        \\  }
        \\  function finalizationCount() { return finalizations; }
        \\  return [guarded, finalizationCount];
        \\  }
        \\var pair = makePair();
        \\var guarded = pair[0];
        \\var finalizationCount = pair[1];
    ;
    var chunk = try compileScript(&realm, source);
    defer chunk.deinit(testing.allocator);
    _ = try runValue(&realm, &chunk);

    const guarded_function = heap_mod.valueAsFunction(realm.globals.get("guarded") orelse
        return error.GlobalBindingMissing) orelse return error.GlobalBindingNotFunction;
    const guarded = guarded_function.chunk orelse return error.TestUnexpectedResult;
    try testing.expect(hasOpcode(guarded, .throw_));
    const guarded_state = guarded.jit_state.?;
    const counter_function = heap_mod.valueAsFunction(realm.globals.get("finalizationCount") orelse
        return error.GlobalBindingMissing) orelse return error.GlobalBindingNotFunction;
    const counter_state = (counter_function.chunk orelse return error.TestUnexpectedResult).jit_state.?;
    counter_state.ohaimark.refuse();
    counter_state.bistromath.refuse();

    realm.jit_enabled = true;
    realm.jit_threshold_override = 1;
    realm.ohaimark_enabled = true;
    realm.ohaimark_threshold_override = 1;
    realm.heap.ohaimark_stats.enabled = true;
    realm.heap.setGcThreshold(1);

    try testing.expectEqual(
        Value.fromInt32(1).bits,
        (try callGlobalFunction(&realm, "guarded", &.{ Value.false_, Value.undefined_ })).bits,
    );
    try testing.expectEqual(chunk_mod.Chunk.JitState.Tier.compiled, guarded_state.ohaimark.tier);
    // The normal path reaches the closure-backed `finally` counter, whose
    // environment store is an existing Lantern safepoint. The explicit throw
    // below must add exactly one further replay at its own bytecode offset.
    const guard_exits_before_throw = guarded_state.ohaimark_guard_exits;
    try testing.expectEqual(@as(u32, 1), guard_exits_before_throw);

    const scope = try realm.heap.openScope();
    defer scope.close();
    const thrown = heap_mod.taggedObject(try realm.heap.allocateObject());
    try scope.push(thrown);
    try testing.expectEqual(
        Value.fromInt32(47).bits,
        (try callGlobalFunction(&realm, "guarded", &.{ Value.true_, thrown })).bits,
    );
    try testing.expectEqual(
        Value.fromInt32(2).bits,
        (try callGlobalFunction(&realm, "finalizationCount", &.{})).bits,
    );
    try testing.expectEqual(guard_exits_before_throw + 1, guarded_state.ohaimark_guard_exits);
}

test "Ohaimark explicit throw restores a register required by a catch handler" {
    if (comptime !driver.supported) return error.SkipZigTest;
    var realm = Realm.init(testing.allocator);
    defer realm.deinit();

    const source =
        \\function caughtLocal(value) {
        \\  var local = 42;
        \\  try {
        \\    throw value;
        \\  } catch (caught) {
        \\    return local;
        \\  }
        \\}
    ;
    var chunk = try compileScript(&realm, source);
    defer chunk.deinit(testing.allocator);
    _ = try runValue(&realm, &chunk);

    const caught_local_function = heap_mod.valueAsFunction(realm.globals.get("caughtLocal") orelse
        return error.GlobalBindingMissing) orelse return error.GlobalBindingNotFunction;
    const caught_local = caught_local_function.chunk orelse return error.TestUnexpectedResult;
    try testing.expect(hasOpcode(caught_local, .throw_));
    const state = caught_local.jit_state.?;

    realm.jit_enabled = true;
    realm.jit_threshold_override = 1;
    realm.ohaimark_enabled = true;
    realm.ohaimark_threshold_override = 1;

    try testing.expectEqual(
        Value.fromInt32(42).bits,
        (try callGlobalFunction(&realm, "caughtLocal", &.{Value.undefined_})).bits,
    );
    try testing.expectEqual(chunk_mod.Chunk.JitState.Tier.compiled, state.ohaimark.tier);
    try testing.expectEqual(@as(u32, 1), state.ohaimark_guard_exits);
}

test "Ohaimark materializes fresh arguments objects under GC pressure" {
    if (comptime !driver.supported) return error.SkipZigTest;
    var realm = Realm.init(testing.allocator);
    defer realm.deinit();

    const source =
        \\function expose() { return arguments; }
    ;
    var chunk = try compileScript(&realm, source);
    defer chunk.deinit(testing.allocator);
    _ = try runValue(&realm, &chunk);
    const expose = templateNamed(&chunk, "expose");
    try testing.expect(hasOpcode(expose, .lda_arguments));
    const state = expose.jit_state.?;

    realm.jit_enabled = true;
    realm.jit_threshold_override = 1;
    realm.ohaimark_enabled = true;
    realm.ohaimark_threshold_override = 1;
    realm.heap.setGcThreshold(1);

    const scope = try realm.heap.openScope();
    defer scope.close();
    const first_arg = heap_mod.taggedObject(try realm.heap.allocateObject());
    const second_arg = heap_mod.taggedObject(try realm.heap.allocateObject());
    try scope.push(first_arg);
    try scope.push(second_arg);

    const first = try callGlobalFunction(&realm, "expose", &.{ first_arg, second_arg });
    try scope.push(first);
    const first_arguments = heap_mod.valueAsPlainObject(first) orelse return error.TestUnexpectedResult;
    try testing.expect(first_arguments.brand.is_arguments_exotic);
    try testing.expectEqual(first_arg.bits, first_arguments.lookupOwn("0").?.bits);
    try testing.expectEqual(second_arg.bits, first_arguments.lookupOwn("1").?.bits);

    const replacement = heap_mod.taggedObject(try realm.heap.allocateObject());
    try scope.push(replacement);
    const second = try callGlobalFunction(&realm, "expose", &.{replacement});
    const second_arguments = heap_mod.valueAsPlainObject(second) orelse return error.TestUnexpectedResult;
    try testing.expect(first.bits != second.bits);
    try testing.expectEqual(replacement.bits, second_arguments.lookupOwn("0").?.bits);
    try testing.expectEqual(Value.fromInt32(1).bits, second_arguments.lookupOwn("length").?.bits);
    try testing.expectEqual(chunk_mod.Chunk.JitState.Tier.compiled, state.ohaimark.tier);
    try testing.expectEqual(@as(u16, 0), state.ohaimark_guard_exits);
}

test "Ohaimark compiles static data object literals under GC pressure" {
    if (comptime !driver.supported) return error.SkipZigTest;
    var realm = Realm.init(testing.allocator);
    defer realm.deinit();

    const source =
        \\function empty() { return {}; }
        \\function pair(left, right) { return { left: left, right: right }; }
    ;
    var chunk = try compileScript(&realm, source);
    defer chunk.deinit(testing.allocator);
    _ = try runValue(&realm, &chunk);
    const empty = templateNamed(&chunk, "empty");
    const pair = templateNamed(&chunk, "pair");
    try testing.expect(hasOpcode(empty, .make_object));
    try testing.expect(hasOpcode(pair, .make_object_shape));
    try testing.expect(hasOpcode(pair, .def_template_property));
    const empty_state = empty.jit_state.?;
    const pair_state = pair.jit_state.?;

    realm.jit_enabled = true;
    realm.jit_threshold_override = 1;
    realm.ohaimark_enabled = true;
    realm.ohaimark_threshold_override = 1;
    realm.heap.setGcThreshold(1);

    const scope = try realm.heap.openScope();
    defer scope.close();
    const first_empty = try callGlobalFunction(&realm, "empty", &.{});
    try scope.push(first_empty);
    const second_empty = try callGlobalFunction(&realm, "empty", &.{});
    try scope.push(second_empty);
    try testing.expect(first_empty.bits != second_empty.bits);

    const first_pair = try callGlobalFunction(
        &realm,
        "pair",
        &.{ Value.fromInt32(7), Value.fromInt32(9) },
    );
    try scope.push(first_pair);
    const first_object = heap_mod.valueAsPlainObject(first_pair) orelse
        return error.TestUnexpectedResult;
    try testing.expectEqual(Value.fromInt32(7).bits, first_object.get("left").bits);
    try testing.expectEqual(Value.fromInt32(9).bits, first_object.get("right").bits);

    const second_pair = try callGlobalFunction(
        &realm,
        "pair",
        &.{ Value.fromInt32(11), Value.fromInt32(13) },
    );
    const second_object = heap_mod.valueAsPlainObject(second_pair) orelse
        return error.TestUnexpectedResult;
    try testing.expect(first_pair.bits != second_pair.bits);
    try testing.expectEqual(Value.fromInt32(11).bits, second_object.get("left").bits);
    try testing.expectEqual(Value.fromInt32(13).bits, second_object.get("right").bits);
    try testing.expectEqual(chunk_mod.Chunk.JitState.Tier.compiled, empty_state.ohaimark.tier);
    try testing.expectEqual(chunk_mod.Chunk.JitState.Tier.compiled, pair_state.ohaimark.tier);
    try testing.expectEqual(@as(u16, 0), empty_state.ohaimark_guard_exits);
    try testing.expectEqual(@as(u16, 0), pair_state.ohaimark_guard_exits);
}

test "Ohaimark compiles fused dense array literals under GC pressure" {
    if (comptime !driver.supported) return error.SkipZigTest;
    var realm = Realm.init(testing.allocator);
    defer realm.deinit();

    const source =
        \\function pair(first, second) { return [first, 7, second]; }
    ;
    var chunk = try compileScript(&realm, source);
    defer chunk.deinit(testing.allocator);
    _ = try runValue(&realm, &chunk);
    const pair = templateNamed(&chunk, "pair");
    try testing.expect(hasOpcode(pair, .make_array_n));
    const state = pair.jit_state.?;

    realm.jit_enabled = true;
    realm.jit_threshold_override = 1;
    realm.ohaimark_enabled = true;
    realm.ohaimark_threshold_override = 1;
    realm.heap.setGcThreshold(1);

    const scope = try realm.heap.openScope();
    defer scope.close();
    const first = heap_mod.taggedObject(try realm.heap.allocateObject());
    const second = heap_mod.taggedObject(try realm.heap.allocateObject());
    try scope.push(first);
    try scope.push(second);
    const result = try callGlobalFunction(&realm, "pair", &.{ first, second });
    try scope.push(result);
    const array = heap_mod.valueAsPlainObject(result) orelse return error.TestUnexpectedResult;
    try testing.expect(array.brand.is_array_exotic);
    const items = array.elementItems();
    try testing.expectEqual(first.bits, items[0].bits);
    try testing.expectEqual(Value.fromInt32(7).bits, items[1].bits);
    try testing.expectEqual(second.bits, items[2].bits);
    try testing.expectEqual(chunk_mod.Chunk.JitState.Tier.compiled, state.ohaimark.tier);
    try testing.expectEqual(@as(u16, 0), state.ohaimark_guard_exits);
}

test "Ohaimark compiles un-fused dense array literals under GC pressure" {
    if (comptime !driver.supported) return error.SkipZigTest;
    var realm = Realm.init(testing.allocator);
    defer realm.deinit();

    const source =
        \\function build(first, second) {
        \\  return [first, second, first, second, first, second, first, second, first,
        \\    second, first, second, first, second, first, second, first];
        \\}
    ;
    var chunk = try compileScript(&realm, source);
    defer chunk.deinit(testing.allocator);
    _ = try runValue(&realm, &chunk);
    const build = templateNamed(&chunk, "build");
    try testing.expect(hasOpcode(build, .make_array));
    try testing.expect(hasOpcode(build, .def_property));
    const state = build.jit_state.?;

    realm.jit_enabled = true;
    realm.jit_threshold_override = 1;
    realm.ohaimark_enabled = true;
    realm.ohaimark_threshold_override = 1;
    realm.heap.setGcThreshold(1);

    const scope = try realm.heap.openScope();
    defer scope.close();
    const first = heap_mod.taggedObject(try realm.heap.allocateObject());
    const second = heap_mod.taggedObject(try realm.heap.allocateObject());
    try scope.push(first);
    try scope.push(second);
    const result = try callGlobalFunction(&realm, "build", &.{ first, second });
    try scope.push(result);
    const array = heap_mod.valueAsPlainObject(result) orelse return error.TestUnexpectedResult;
    try testing.expect(array.brand.is_array_exotic);
    const items = array.elementItems();
    try testing.expectEqual(@as(usize, 17), items.len);
    for (items, 0..) |element, index| {
        try testing.expectEqual(if (index % 2 == 0) first.bits else second.bits, element.bits);
    }
    try testing.expectEqual(chunk_mod.Chunk.JitState.Tier.compiled, state.ohaimark.tier);
    try testing.expectEqual(@as(u16, 0), state.ohaimark_guard_exits);
}

test "Ohaimark compiles ordinary closure creation under GC pressure" {
    if (comptime !driver.supported) return error.SkipZigTest;
    var realm = Realm.init(testing.allocator);
    defer realm.deinit();

    const source =
        \\function make(seed) {
        \\  function add(value) { return seed + value; }
        \\  return add;
        \\}
    ;
    var chunk = try compileScript(&realm, source);
    defer chunk.deinit(testing.allocator);
    _ = try runValue(&realm, &chunk);
    const make = templateNamed(&chunk, "make");
    try testing.expect(hasOpcode(make, .make_function));
    const state = make.jit_state.?;

    realm.jit_enabled = true;
    realm.jit_threshold_override = 1;
    realm.ohaimark_enabled = true;
    realm.ohaimark_threshold_override = 1;
    realm.heap.setGcThreshold(1);
    realm.heap.ohaimark_stats.enabled = true;

    const scope = try realm.heap.openScope();
    defer scope.close();
    const first = try callGlobalFunction(&realm, "make", &.{Value.fromInt32(7)});
    try scope.push(first);
    const second = try callGlobalFunction(&realm, "make", &.{Value.fromInt32(11)});
    try scope.push(second);
    try testing.expect(first.bits != second.bits);

    realm.collectGarbage();
    const first_function = heap_mod.valueAsFunction(first) orelse return error.TestUnexpectedResult;
    const second_function = heap_mod.valueAsFunction(second) orelse return error.TestUnexpectedResult;
    const first_result = switch (try lantern.callJSFunction(
        testing.allocator,
        &realm,
        first_function,
        Value.undefined_,
        &.{Value.fromInt32(3)},
    )) {
        .value, .yielded => |value| value,
        .thrown => return error.TestUnexpectedResult,
    };
    const second_result = switch (try lantern.callJSFunction(
        testing.allocator,
        &realm,
        second_function,
        Value.undefined_,
        &.{Value.fromInt32(5)},
    )) {
        .value, .yielded => |value| value,
        .thrown => return error.TestUnexpectedResult,
    };
    try testing.expectEqual(Value.fromInt32(10).bits, first_result.bits);
    try testing.expectEqual(Value.fromInt32(16).bits, second_result.bits);
    try testing.expectEqual(chunk_mod.Chunk.JitState.Tier.compiled, state.ohaimark.tier);
    try testing.expectEqual(@as(u16, 0), state.ohaimark_guard_exits);
}

test "Ohaimark compiles ordinary object method creation under GC pressure" {
    if (comptime !driver.supported) return error.SkipZigTest;
    var realm = Realm.init(testing.allocator);
    defer realm.deinit();

    const source =
        \\function make() { return { method() { return super.value; } }; }
    ;
    var chunk = try compileScript(&realm, source);
    defer chunk.deinit(testing.allocator);
    _ = try runValue(&realm, &chunk);
    const make = templateNamed(&chunk, "make");
    try testing.expect(hasOpcode(make, .make_function));
    try testing.expect(hasOpcode(make, .set_home));
    try testing.expect(hasOpcode(make, .def_property));
    const state = make.jit_state.?;

    realm.jit_enabled = true;
    realm.jit_threshold_override = 1;
    realm.ohaimark_enabled = true;
    realm.ohaimark_threshold_override = 1;
    realm.heap.setGcThreshold(1);

    const scope = try realm.heap.openScope();
    defer scope.close();
    const created = try callGlobalFunction(&realm, "make", &.{});
    try scope.push(created);
    const object = heap_mod.valueAsPlainObject(created) orelse return error.TestUnexpectedResult;
    const method = heap_mod.valueAsFunction(object.get("method")) orelse
        return error.TestUnexpectedResult;
    const method_flags = object.flagsFor("method");
    try testing.expect(method_flags.writable);
    try testing.expect(method_flags.enumerable);
    try testing.expect(method_flags.configurable);
    const parent = try realm.heap.allocateObject();
    realm.heap.setObjectPrototype(parent, realm.intrinsics.object_prototype);
    try realm.heap.storeProperty(parent, realm.allocator, "value", Value.fromInt32(42));
    const parent_value = heap_mod.taggedObject(parent);
    try scope.push(parent_value);
    realm.heap.setObjectPrototype(object, parent);
    try testing.expect(method.home_object == object);
    try testing.expect(!method.has_construct);
    try testing.expect(method.prototype == null);
    const result = switch (try lantern.callJSFunction(
        testing.allocator,
        &realm,
        method,
        created,
        &.{},
    )) {
        .value, .yielded => |value| value,
        .thrown => return error.TestUnexpectedResult,
    };
    try testing.expectEqual(Value.fromInt32(42).bits, result.bits);
    try testing.expectEqual(chunk_mod.Chunk.JitState.Tier.compiled, state.ohaimark.tier);
    try testing.expectEqual(@as(u16, 0), state.ohaimark_guard_exits);
}

test "Ohaimark entry environment helper preserves captured lexical depth" {
    if (comptime !driver.supported) return error.SkipZigTest;
    var realm = Realm.init(testing.allocator);
    defer realm.deinit();
    realm.jit_enabled = true;
    realm.jit_threshold_override = 1;
    realm.ohaimark_enabled = true;
    realm.ohaimark_threshold_override = 1;
    realm.heap.setGcThreshold(1);

    const source =
        \\function outer() {
        \\  // Keep this fixture on the entry-allocation/lda_env path; `let`
        \\  // would add the separately unsupported throw_if_hole opcode.
        \\  var captured = 73;
        \\  return function inner() { return captured; };
        \\}
        \\const f = outer();
        \\f();
        \\f();
    ;
    var chunk = try compileScript(&realm, source);
    defer chunk.deinit(testing.allocator);
    const value = try runValue(&realm, &chunk);
    try testing.expectEqual(Value.fromInt32(73).bits, value.bits);

    const outer = templateNamed(&chunk, "outer");
    const inner = templateNamed(outer, "inner");
    const state = inner.jit_state.?;
    try testing.expectEqual(chunk_mod.Chunk.JitState.Tier.compiled, state.ohaimark.tier);
    try testing.expect(state.ohaimark.entry() != null);
}

test "Ohaimark forced function entry compiles StarLdar" {
    if (comptime !driver.supported) return error.SkipZigTest;
    var realm = Realm.init(testing.allocator);
    defer realm.deinit();
    realm.jit_enabled = true;
    realm.jit_threshold_override = 1;
    realm.ohaimark_enabled = true;
    realm.ohaimark_threshold_override = 1;

    const source =
        \\function mix() {
        \\  let a = 1; let b = 2; let c = 3; let d = 4;
        \\  return (a + b) + (c + d);
        \\}
        \\mix();
        \\mix();
    ;
    var chunk = try compileScript(&realm, source);
    defer chunk.deinit(testing.allocator);
    const body = templateNamed(&chunk, "mix");
    var saw_star_ldar = false;
    var pc: usize = 0;
    while (pc < body.code.len) {
        const op: Op = @enumFromInt(body.code[pc]);
        saw_star_ldar = saw_star_ldar or op == .star_ldar;
        pc += 1 + Op.operandSize(op);
    }
    try testing.expect(saw_star_ldar);

    const value = try runValue(&realm, &chunk);
    try testing.expectEqual(Value.fromInt32(10).bits, value.bits);
    const state = body.jit_state.?;
    try testing.expectEqual(chunk_mod.Chunk.JitState.Tier.compiled, state.ohaimark.tier);
    try testing.expect(state.ohaimark.entry() != null);
}

test "Ohaimark environment store helper compiles a var write" {
    if (comptime !driver.supported) return error.SkipZigTest;
    var realm = Realm.init(testing.allocator);
    defer realm.deinit();
    realm.jit_enabled = true;
    realm.jit_threshold_override = 1;
    realm.ohaimark_enabled = true;
    realm.ohaimark_threshold_override = 1;
    realm.heap.setGcThreshold(1);

    const source =
        \\function stored() { var value = 0; value = 73; return value; }
        \\stored();
        \\stored();
    ;
    var chunk = try compileScript(&realm, source);
    defer chunk.deinit(testing.allocator);
    const value = try runValue(&realm, &chunk);
    try testing.expectEqual(Value.fromInt32(73).bits, value.bits);

    const state = templateNamed(&chunk, "stored").jit_state.?;
    try testing.expectEqual(chunk_mod.Chunk.JitState.Tier.compiled, state.ohaimark.tier);
    try testing.expect(state.ohaimark.entry() != null);
}

test "Ohaimark warmth continues through the active lower-tier caller" {
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
    if (comptime bistromath.supported) {
        try testing.expectEqual(
            chunk_mod.Chunk.JitState.Tier.compiled,
            caller_state.bistromath.code.tier,
        );
        try testing.expect(caller_state.bistromath.entry() != null);
    } else {
        try testing.expectEqual(
            chunk_mod.Chunk.JitState.Tier.cold,
            caller_state.bistromath.code.tier,
        );
        try testing.expect(caller_state.bistromath.entry() == null);
    }
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

test "Ohaimark refusal preserves the active lower-tier fallback" {
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
    if (comptime bistromath.supported) {
        try testing.expectEqual(chunk_mod.Chunk.JitState.Tier.compiled, state.bistromath.code.tier);
        try testing.expect(state.bistromath.entry() != null);
    } else {
        try testing.expectEqual(chunk_mod.Chunk.JitState.Tier.cold, state.bistromath.code.tier);
        try testing.expect(state.bistromath.entry() == null);
    }
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

test "Ohaimark retries a cold named property IC after feedback warms" {
    if (comptime !driver.supported) return error.SkipZigTest;
    var realm = Realm.init(testing.allocator);
    defer realm.deinit();
    // Keep T1 cold so the first T2 refusal falls through to Lantern, which
    // owns the IC fill that makes the second T2 attempt compilable.
    realm.jit_enabled = true;
    realm.jit_threshold_override = std.math.maxInt(u32);
    realm.ohaimark_enabled = true;
    realm.ohaimark_threshold_override = 1;
    realm.heap.ohaimark_stats.enabled = true;

    const source =
        \\function f(object, value) { object.x = value; return object.x; }
        \\const target = { x: 0 };
    ;
    var chunk = try compileScript(&realm, source);
    defer chunk.deinit(testing.allocator);
    _ = try runValue(&realm, &chunk);

    const function_chunk = templateNamed(&chunk, "f");
    try testing.expect(hasOpcode(function_chunk, .sta_property8));
    const target = realm.globals.get("target") orelse return error.TestUnexpectedResult;

    try testing.expectEqual(Value.fromInt32(1).bits, (try callGlobalFunction(
        &realm,
        "f",
        &.{ target, Value.fromInt32(1) },
    )).bits);

    const state = function_chunk.jit_state.?;
    try testing.expectEqual(chunk_mod.Chunk.JitState.Tier.dont_compile, state.ohaimark.tier);
    const retry_site = state.ohaimark.retryFeedbackSite() orelse return error.TestUnexpectedResult;
    const expected_retry_site = (codegen.RetryableFeedback{ .named_store = 0 }).key();
    try testing.expectEqual(expected_retry_site, retry_site);
    try testing.expectEqual(@as(?u64, 0), state.ohaimark.retryFeedbackFingerprint());
    try testing.expect(function_chunk.inline_store_caches[0].shape != null);
    try testing.expect(function_chunk.inline_store_caches[0].post_shape == null);
    try testing.expectEqual(
        @as(?u64, 1),
        codegen.retryFeedbackFingerprint(function_chunk, retry_site),
    );
    const first_attempts = realm.heap.ohaimark_stats.compile_attempts;
    try testing.expectEqual(@as(u64, 1), first_attempts);

    try testing.expectEqual(Value.fromInt32(2).bits, (try callGlobalFunction(
        &realm,
        "f",
        &.{ target, Value.fromInt32(2) },
    )).bits);
    try testing.expectEqual(chunk_mod.Chunk.JitState.Tier.compiled, state.ohaimark.tier);
    try testing.expect(state.ohaimark.entry() != null);
    try testing.expect(state.ohaimark.retryFeedbackSite() == null);
    try testing.expect(state.ohaimark.retryFeedbackFingerprint() == null);
    try testing.expectEqual(first_attempts + 1, realm.heap.ohaimark_stats.compile_attempts);
    try testing.expectEqual(@as(u64, 1), realm.heap.ohaimark_stats.compile_successes);
}

test "Ohaimark retry feedback ignores unrelated property ICs" {
    var realm = Realm.init(testing.allocator);
    defer realm.deinit();
    const source =
        \\function f(first, second) { first.x; return second.y; }
    ;
    var chunk = try compileScript(&realm, source);
    defer chunk.deinit(testing.allocator);
    const function_chunk = @constCast(templateNamed(&chunk, "f"));
    try testing.expectEqual(@as(usize, 2), function_chunk.inline_load_caches.len);

    const object = try realm.heap.allocateObject();
    try realm.heap.storeProperty(object, realm.allocator, "x", Value.undefined_);
    const shape = object.shape orelse return error.TestUnexpectedResult;
    const deferred = codegen.RetryableFeedback{ .named_load = 0 };
    const site = deferred.key();
    const cold = codegen.retryFeedbackFingerprint(function_chunk, site) orelse
        return error.TestUnexpectedResult;
    try testing.expectEqual(@as(u64, 0), cold);

    var tier: chunk_mod.Chunk.JitState.TierCode = .{};
    tier.deferForFeedback(site, cold);
    function_chunk.inline_load_caches[1].fillOwnData(shape, 0);
    const unrelated = codegen.retryFeedbackFingerprint(function_chunk, site) orelse
        return error.TestUnexpectedResult;
    try testing.expectEqual(@as(u64, 0), unrelated);
    try testing.expect(!tier.canRetryForFeedback(unrelated));

    function_chunk.inline_load_caches[0].fillOwnData(shape, 0);
    const warmed = codegen.retryFeedbackFingerprint(function_chunk, site) orelse
        return error.TestUnexpectedResult;
    try testing.expectEqual(@as(u64, 1), warmed);
    try testing.expect(tier.canRetryForFeedback(warmed));
}

test "Ohaimark retry feedback accepts only supported property IC modes" {
    var realm = Realm.init(testing.allocator);
    defer realm.deinit();
    const source =
        \\function f(object, key, value) {
        \\  object.first;
        \\  object.second = value;
        \\  object[key];
        \\  object[key] = value;
        \\}
    ;
    var chunk = try compileScript(&realm, source);
    defer chunk.deinit(testing.allocator);
    const function_chunk = @constCast(templateNamed(&chunk, "f"));
    try testing.expectEqual(@as(usize, 1), function_chunk.inline_load_caches.len);
    try testing.expectEqual(@as(usize, 1), function_chunk.inline_store_caches.len);
    try testing.expectEqual(@as(usize, 2), function_chunk.inline_computed_caches.len);

    const object = try realm.heap.allocateObject();
    try realm.heap.storeProperty(object, realm.allocator, "seed", Value.undefined_);
    const shape = object.shape orelse return error.TestUnexpectedResult;

    const named_load = (codegen.RetryableFeedback{ .named_load = 0 }).key();
    try testing.expectEqual(
        @as(?u64, 0),
        codegen.retryFeedbackFingerprint(function_chunk, named_load),
    );
    function_chunk.inline_load_caches[0].fillOwnData(shape, 0);
    try testing.expectEqual(
        @as(?u64, 1),
        codegen.retryFeedbackFingerprint(function_chunk, named_load),
    );

    const named_store = (codegen.RetryableFeedback{ .named_store = 0 }).key();
    function_chunk.inline_store_caches[0] = .{ .shape = shape, .slot = 0 };
    try testing.expectEqual(
        @as(?u64, 1),
        codegen.retryFeedbackFingerprint(function_chunk, named_store),
    );
    function_chunk.inline_store_caches[0].post_shape = shape;
    try testing.expectEqual(
        @as(?u64, 0),
        codegen.retryFeedbackFingerprint(function_chunk, named_store),
    );

    inline for (.{
        codegen.RetryableFeedback{ .computed_load = 0 },
        codegen.RetryableFeedback{ .computed_store = 1 },
    }, 0..) |feedback, index| {
        const key = feedback.key();
        try testing.expectEqual(
            @as(?u64, 0),
            codegen.retryFeedbackFingerprint(function_chunk, key),
        );
        const cell = &function_chunk.inline_computed_caches[index];
        cell.* = .{ .shape = shape, .slot = 0, .cached_key_len = 1 };
        cell.cached_key_buf[0] = 'k';
        try testing.expectEqual(
            @as(?u64, 1),
            codegen.retryFeedbackFingerprint(function_chunk, key),
        );
        cell.cached_key_len = chunk_mod.computed_key_megamorphic;
        try testing.expectEqual(
            @as(?u64, 0),
            codegen.retryFeedbackFingerprint(function_chunk, key),
        );
    }
}

/// Truthiness loop with only ops the current Ohaimark AArch64 subset can emit
/// (no relational ops, no loop-carried generic arithmetic). Same shape as the
/// native safepoint OSR tests: one body trip then exit.
fn osrTruthinessLoopChunk() !struct { chunk: chunk_mod.Chunk, header: u32, root: u8 } {
    var builder = Builder.init(testing.allocator);
    defer builder.deinit();
    const root = try builder.reserveRegister();
    try builder.emitOp(.lda_one, span);
    const header = builder.here();
    try builder.emitOp(.jmp_if_false, span);
    const exit_patch = builder.here();
    try builder.emitI16(0);
    try builder.emitOp(.lda_zero, span);
    try builder.emitOp(.jmp, span);
    const back_patch = builder.here();
    try builder.emitI16(0);
    const exit_target = builder.here();
    try builder.emitLoadReg(span, root);
    try builder.emitOp(.return_, span);
    try builder.patchI16(exit_patch, exit_target);
    try builder.patchI16(back_patch, header);
    return .{
        .chunk = try builder.finish(),
        .header = @intCast(header),
        .root = root,
    };
}

fn osrFrame(
    chunk: *const chunk_mod.Chunk,
    registers: []Value,
    ip: usize,
    acc: Value,
) lantern.CallFrame {
    @memset(registers, Value.undefined_);
    return .{
        .chunk = chunk,
        .ip = ip,
        .accumulator = acc,
        .registers = registers,
        .env = null,
        .this_value = Value.undefined_,
        .owns_registers = false,
    };
}

test "Ohaimark OSR: publishes stub and completes via driver" {
    if (comptime !driver.supported) return error.SkipZigTest;
    var realm = Realm.init(testing.allocator);
    defer realm.deinit();
    realm.jit_enabled = true;
    realm.ohaimark_enabled = true;
    realm.ohaimark_osr_enabled = true;
    realm.ohaimark_threshold_override = 1;
    realm.heap.ohaimark_stats.enabled = true;

    var loop = try osrTruthinessLoopChunk();
    defer loop.chunk.deinit(testing.allocator);
    const state = loop.chunk.jit_state.?;
    state.warmth = driver.tierUpThreshold(loop.chunk.code.len);

    try testing.expect(ohaimark_compiler.compile(&realm, &loop.chunk));
    try testing.expectEqual(chunk_mod.Chunk.JitState.Tier.compiled, state.ohaimark.tier);
    try testing.expect(state.hasOhaimarkOsr());
    try testing.expect(state.ohaimarkOsrCodeOffset(loop.header) != null);

    const registers = try testing.allocator.alloc(Value, loop.chunk.register_count);
    defer testing.allocator.free(registers);
    var frames: std.ArrayListUnmanaged(lantern.CallFrame) = .empty;
    defer frames.deinit(testing.allocator);
    try frames.append(testing.allocator, osrFrame(
        &loop.chunk,
        registers,
        loop.header,
        Value.fromInt32(1),
    ));
    frames.items[0].registers[loop.root] = Value.null_;
    realm.step_budget = std.math.maxInt(u64);

    const outcome = try driver.tryOsrEnterTop(testing.allocator, &realm, &frames);
    switch (outcome) {
        .completed => |value| try testing.expectEqual(Value.null_.bits, value.bits),
        else => return error.TestUnexpectedResult,
    }
    try testing.expectEqual(@as(usize, 0), frames.items.len);
    try testing.expect(realm.heap.ohaimark_stats.executed_entries >= 1);
    try testing.expectEqual(@as(u8, 0), state.ohaimark_osr_strikes);
}

test "Ohaimark OSR: cooperative fuel resume does not burn strikes or entry exits" {
    if (comptime !driver.supported) return error.SkipZigTest;
    var realm = Realm.init(testing.allocator);
    defer realm.deinit();
    realm.jit_enabled = true;
    realm.ohaimark_enabled = true;
    realm.ohaimark_osr_enabled = true;
    realm.ohaimark_threshold_override = 1;
    realm.heap.ohaimark_stats.enabled = true;

    var loop = try osrTruthinessLoopChunk();
    defer loop.chunk.deinit(testing.allocator);
    const state = loop.chunk.jit_state.?;
    state.warmth = driver.tierUpThreshold(loop.chunk.code.len);
    try testing.expect(ohaimark_compiler.compile(&realm, &loop.chunk));
    try testing.expect(state.hasOhaimarkOsr());

    const registers = try testing.allocator.alloc(Value, loop.chunk.register_count);
    defer testing.allocator.free(registers);
    var frames: std.ArrayListUnmanaged(lantern.CallFrame) = .empty;
    defer frames.deinit(testing.allocator);
    try frames.append(testing.allocator, osrFrame(
        &loop.chunk,
        registers,
        loop.header,
        Value.fromInt32(1),
    ));
    frames.items[0].registers[loop.root] = Value.fromInt32(42);
    // Zero fuel: first optimized backedge takes the safepoint slow path.
    realm.step_budget = 0;

    const outcome = try driver.tryOsrEnterTop(testing.allocator, &realm, &frames);
    try testing.expect(outcome == .safe_point);
    try testing.expectEqual(@as(usize, 1), frames.items.len);
    try testing.expectEqual(loop.header, frames.items[0].ip);
    try testing.expectEqual(Value.fromInt32(0).bits, frames.items[0].accumulator.bits);
    try testing.expectEqual(Value.fromInt32(42).bits, frames.items[0].registers[loop.root].bits);
    // Safepoint resume must not charge enter-and-bail strikes or function-entry exits.
    try testing.expectEqual(@as(u8, 0), state.ohaimark_osr_strikes);
    try testing.expectEqual(@as(u8, 0), state.ohaimark_guard_exits);
}

test "Ohaimark safepoint handoff polls before an immediate header return" {
    if (comptime !driver.supported) return error.SkipZigTest;
    var realm = Realm.init(testing.allocator);
    defer realm.deinit();
    realm.jit_enabled = true;
    realm.jit_threshold_override = std.math.maxInt(u32);
    realm.ohaimark_enabled = true;
    realm.ohaimark_threshold_override = 1;
    realm.ohaimark_osr_enabled = true;

    const definition =
        \\function once(n) {
        \\  while (n) { n = n - 1; }
        \\  return 42;
        \\}
    ;
    var definition_chunk = try compileScript(&realm, definition);
    defer definition_chunk.deinit(testing.allocator);
    _ = try runValue(&realm, &definition_chunk);
    try testing.expectEqual(
        Value.fromInt32(42).bits,
        (try callGlobalFunction(&realm, "once", &.{Value.fromInt32(1)})).bits,
    );
    try testing.expectEqual(
        chunk_mod.Chunk.JitState.Tier.compiled,
        templateNamed(&definition_chunk, "once").jit_state.?.ohaimark.tier,
    );

    var call_chunk = try compileScript(&realm, "once(1);");
    defer call_chunk.deinit(testing.allocator);
    // The script-entry poll consumes the one unit. Native code then exits at
    // the loop header, where the condition is already false. The handoff must
    // poll before Lantern can execute that immediate return.
    realm.step_budget = 1;
    const outcome = try lantern.run(testing.allocator, &realm, &call_chunk);
    try testing.expect(outcome == .thrown);
    try testing.expectEqual(@as(u64, 0), realm.step_budget);
}

test "Ohaimark fresh-entry safepoint keeps frame registers rooted during GC" {
    if (comptime !driver.supported) return error.SkipZigTest;
    var realm = Realm.init(testing.allocator);
    defer realm.deinit();
    realm.jit_enabled = true;
    realm.jit_threshold_override = std.math.maxInt(u32);
    realm.ohaimark_enabled = true;
    realm.ohaimark_threshold_override = 1;

    const definition =
        \\function keep(value, n) {
        \\  while (n) { n = n - 1; }
        \\  return value;
        \\}
    ;
    var definition_chunk = try compileScript(&realm, definition);
    defer definition_chunk.deinit(testing.allocator);
    _ = try runValue(&realm, &definition_chunk);
    try testing.expectEqual(
        Value.null_.bits,
        (try callGlobalFunction(&realm, "keep", &.{ Value.null_, Value.fromInt32(1) })).bits,
    );
    try testing.expectEqual(
        chunk_mod.Chunk.JitState.Tier.compiled,
        templateNamed(&definition_chunk, "keep").jit_state.?.ohaimark.tier,
    );

    realm.collectGarbage();
    const baseline_objects = realm.heap.objectCount();
    const object = try realm.heap.allocateObject();
    const value = heap_mod.taggedObject(object);
    realm.heap.setGcThreshold(1);

    const result = try callGlobalFunction(
        &realm,
        "keep",
        &.{ value, Value.fromInt32(1) },
    );
    try testing.expectEqual(value.bits, result.bits);
    try testing.expectEqual(baseline_objects + 1, realm.heap.objectCount());
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

    // Keep a genuinely unsupported opcode in the loop body so the first OSR
    // compile refusal must stick rather than retrying on every backedge.
    const source =
        \\function f(n) {
        \\  var i = n;
        \\  while (i) { i = (i - 1) | 0; }
        \\  return i;
        \\}
        \\f(20);
    ;
    var chunk = try compileScript(&realm, source);
    defer chunk.deinit(testing.allocator);
    const value = try runValue(&realm, &chunk);
    try testing.expectEqual(Value.fromInt32(0).bits, value.bits);

    const state = templateNamed(&chunk, "f").jit_state.?;
    try testing.expectEqual(chunk_mod.Chunk.JitState.Tier.dont_compile, state.ohaimark.tier);
    const attempts_before = realm.heap.ohaimark_stats.compile_attempts;
    try testing.expect(attempts_before >= 1);
    const value2 = try runValue(&realm, &chunk);
    try testing.expectEqual(Value.fromInt32(0).bits, value2.bits);
    try testing.expectEqual(attempts_before, realm.heap.ohaimark_stats.compile_attempts);
}

test "Ohaimark OSR: completed result matches the known loop result" {
    if (comptime !driver.supported) return error.SkipZigTest;
    // Truthiness loop body stores zero then backedges once; exit returns root.
    // OSR entry at the header with acc=1 must complete with root (null).
    // Realm must outlive the chunk so InstalledCode can return slots.
    var t2_realm = Realm.init(testing.allocator);
    defer t2_realm.deinit();
    t2_realm.jit_enabled = true;
    t2_realm.ohaimark_enabled = true;
    t2_realm.ohaimark_osr_enabled = true;
    t2_realm.ohaimark_threshold_override = 1;

    var loop = try osrTruthinessLoopChunk();
    defer loop.chunk.deinit(testing.allocator);
    const state = loop.chunk.jit_state.?;
    state.warmth = driver.tierUpThreshold(loop.chunk.code.len);
    try testing.expect(ohaimark_compiler.compile(&t2_realm, &loop.chunk));

    const registers = try testing.allocator.alloc(Value, loop.chunk.register_count);
    defer testing.allocator.free(registers);
    var frames: std.ArrayListUnmanaged(lantern.CallFrame) = .empty;
    defer frames.deinit(testing.allocator);
    try frames.append(testing.allocator, osrFrame(
        &loop.chunk,
        registers,
        loop.header,
        Value.fromInt32(1),
    ));
    frames.items[0].registers[loop.root] = Value.null_;
    t2_realm.step_budget = std.math.maxInt(u64);
    const outcome = try driver.tryOsrEnterTop(testing.allocator, &t2_realm, &frames);
    switch (outcome) {
        .completed => |value| try testing.expectEqual(Value.null_.bits, value.bits),
        else => return error.TestUnexpectedResult,
    }
}

test "Ohaimark OSR countdown with negative int32 start completes" {
    // Negative int32 is truthy. Climb toward zero (i = i + 1); i = i - 1 from
    // a negative start never hits 0 and is an infinite loop in every engine.
    if (comptime !driver.supported) return error.SkipZigTest;
    var realm = Realm.init(testing.allocator);
    defer realm.deinit();
    realm.jit_enabled = true;
    realm.jit_threshold_override = 1;
    realm.ohaimark_enabled = true;
    realm.ohaimark_threshold_override = 1;
    realm.ohaimark_osr_enabled = true;

    const source =
        \\function countUp(n) {
        \\  let i = n;
        \\  let acc = 0;
        \\  while (i) {
        \\    acc = acc + 1;
        \\    i = i + 1;
        \\  }
        \\  return acc;
        \\}
        \\countUp(-3);
    ;
    var chunk = try compileScript(&realm, source);
    defer chunk.deinit(testing.allocator);
    const value = try runValue(&realm, &chunk);
    try testing.expectEqual(Value.fromInt32(3).bits, value.bits);
}

test "Ohaimark OSR countdown with non-int32 formal still completes" {
    // Boolean formal deopts int32-only truthiness / arithmetic; Lantern finishes.
    if (comptime !driver.supported) return error.SkipZigTest;
    var realm = Realm.init(testing.allocator);
    defer realm.deinit();
    realm.jit_enabled = true;
    realm.jit_threshold_override = 1;
    realm.ohaimark_enabled = true;
    realm.ohaimark_threshold_override = 1;
    realm.ohaimark_osr_enabled = true;

    const source =
        \\function once(flag) {
        \\  let i = flag;
        \\  let acc = 0;
        \\  while (i) {
        \\    acc = acc + 1;
        \\    i = false;
        \\  }
        \\  return acc;
        \\}
        \\once(true);
    ;
    var chunk = try compileScript(&realm, source);
    defer chunk.deinit(testing.allocator);
    const value = try runValue(&realm, &chunk);
    try testing.expectEqual(Value.fromInt32(1).bits, value.bits);
}

test "Ohaimark does not miscompile nullish coalesce on open formals" {
    // Regression for checked_branch + nullish always-fallthrough: with T2
    // enabled, `x ?? 1` must still return 1 when x is null (either refuse T2
    // and fall back, or emit a real nullish test — never always-fallthrough).
    if (comptime !driver.supported) return error.SkipZigTest;
    var realm = Realm.init(testing.allocator);
    defer realm.deinit();
    realm.jit_enabled = true;
    realm.jit_threshold_override = 1;
    realm.ohaimark_enabled = true;
    realm.ohaimark_threshold_override = 1;
    realm.ohaimark_osr_enabled = true;

    const source =
        \\function coalesce(x) {
        \\  return x ?? 1;
        \\}
        \\coalesce(null);
    ;
    var chunk = try compileScript(&realm, source);
    defer chunk.deinit(testing.allocator);
    const value = try runValue(&realm, &chunk);
    try testing.expectEqual(Value.fromInt32(1).bits, value.bits);
}

test "Ohaimark OSR: real JS countdown compiles, OSR-enters, and completes" {
    if (comptime !driver.supported) return error.SkipZigTest;
    var realm = Realm.init(testing.allocator);
    defer realm.deinit();
    realm.jit_enabled = true;
    realm.jit_threshold_override = 1;
    realm.ohaimark_enabled = true;
    realm.ohaimark_threshold_override = 1;
    realm.ohaimark_osr_enabled = true;
    realm.heap.ohaimark_stats.enabled = true;

    const source =
        \\function count(n) {
        \\  let i = n;
        \\  let acc = 0;
        \\  while (i) {
        \\    acc = acc + 1;
        \\    i = i - 1;
        \\  }
        \\  return acc;
        \\}
        \\count(100);
    ;
    var chunk = try compileScript(&realm, source);
    defer chunk.deinit(testing.allocator);
    const value = try runValue(&realm, &chunk);
    try testing.expectEqual(Value.fromInt32(100).bits, value.bits);

    const state = templateNamed(&chunk, "count").jit_state.?;
    try testing.expectEqual(chunk_mod.Chunk.JitState.Tier.compiled, state.ohaimark.tier);
    try testing.expect(state.hasOhaimarkOsr());
    try testing.expect(realm.heap.ohaimark_stats.compile_successes >= 1);
    try testing.expect(realm.heap.ohaimark_stats.executed_entries >= 1);
}

test "Ohaimark OSR: real JS multiply loop compiles and OSR-enters" {
    if (comptime !driver.supported) return error.SkipZigTest;
    var realm = Realm.init(testing.allocator);
    defer realm.deinit();
    realm.jit_enabled = true;
    realm.ohaimark_enabled = true;
    realm.ohaimark_osr_enabled = true;
    realm.heap.ohaimark_stats.enabled = true;

    const source =
        \\function mulAcc(n) {
        \\  let i = n;
        \\  let acc = 1;
        \\  while (i) {
        \\    acc = acc * 1;
        \\    i = i - 1;
        \\  }
        \\  return acc + n;
        \\}
        \\mulAcc(20_000);
    ;
    var chunk = try compileScript(&realm, source);
    defer chunk.deinit(testing.allocator);
    const value = try runValue(&realm, &chunk);
    try testing.expectEqual(Value.fromInt32(20_001).bits, value.bits);

    const state = templateNamed(&chunk, "mulAcc").jit_state.?;
    try testing.expectEqual(chunk_mod.Chunk.JitState.Tier.compiled, state.ohaimark.tier);
    try testing.expect(state.hasOhaimarkOsr());
    try testing.expect(realm.heap.ohaimark_stats.compile_successes >= 1);
    try testing.expect(realm.heap.ohaimark_stats.executed_entries >= 1);
}

test "Ohaimark OSR: folded loop phi survives a mid-body guard exit" {
    if (comptime !driver.supported) return error.SkipZigTest;
    var realm = Realm.init(testing.allocator);
    defer realm.deinit();
    realm.jit_enabled = true;
    realm.jit_threshold_override = std.math.maxInt(u32);
    realm.ohaimark_enabled = true;
    realm.ohaimark_threshold_override = 64;
    realm.ohaimark_osr_enabled = true;
    realm.heap.ohaimark_stats.enabled = true;

    const source =
        \\function foldedPhiOverflow(n) {
        \\  let i = n;
        \\  let folded = 1;
        \\  let value = 2_147_483_548;
        \\  while (i) {
        \\    folded = folded * 1;
        \\    value = value + 1;
        \\    i = i - 1;
        \\  }
        \\  return folded + value;
        \\}
        \\foldedPhiOverflow(100);
    ;
    var chunk = try compileScript(&realm, source);
    defer chunk.deinit(testing.allocator);
    const value = try runValue(&realm, &chunk);
    try testing.expect(value.isDouble());
    try testing.expectEqual(@as(f64, 2_147_483_649), value.asDouble());

    const state = templateNamed(&chunk, "foldedPhiOverflow").jit_state.?;
    try testing.expectEqual(chunk_mod.Chunk.JitState.Tier.compiled, state.ohaimark.tier);
    try testing.expect(state.hasOhaimarkOsr());
    try testing.expect(realm.heap.ohaimark_stats.executed_entries >= 1);
    try testing.expect(realm.heap.ohaimark_stats.guard_exits >= 1);
}

test "Ohaimark OSR stops re-entering after repeated mid-body shape guards" {
    if (comptime !driver.supported) return error.SkipZigTest;
    var realm = Realm.init(testing.allocator);
    defer realm.deinit();
    realm.jit_enabled = true;
    realm.jit_threshold_override = std.math.maxInt(u32);
    realm.ohaimark_enabled = true;
    realm.ohaimark_threshold_override = 32;
    realm.ohaimark_osr_enabled = true;
    realm.heap.ohaimark_stats.enabled = true;

    const source =
        \\const target = { x: 1 };
        \\function readLoop(object, n) {
        \\  let sum = 0;
        \\  while (n) {
        \\    sum = sum + object.x;
        \\    n = n - 1;
        \\  }
        \\  return sum;
        \\}
        \\readLoop(target, 100);
    ;
    var chunk = try compileScript(&realm, source);
    defer chunk.deinit(testing.allocator);
    try testing.expectEqual(Value.fromInt32(100).bits, (try runValue(&realm, &chunk)).bits);

    const function_chunk = templateNamed(&chunk, "readLoop");
    const state = function_chunk.jit_state.?;
    try testing.expectEqual(chunk_mod.Chunk.JitState.Tier.compiled, state.ohaimark.tier);
    try testing.expect(state.hasOhaimarkOsr());
    const target = heap_mod.valueAsPlainObject(realm.globals.get("target") orelse
        return error.TestUnexpectedResult) orelse return error.TestUnexpectedResult;
    try realm.heap.storeProperty(target, realm.allocator, "y", Value.fromInt32(2));

    // Keep this call on the OSR path. The compiled property assumption is now
    // stale, so each native entry guards mid-body until the bounded strike
    // budget disables this OSR entry.
    state.ohaimark_guard_exits = driver.guard_exit_limit;
    state.ohaimark_osr_strikes = 0;
    const entries_before = realm.heap.ohaimark_stats.executed_entries;
    try testing.expectEqual(
        Value.fromInt32(20).bits,
        (try callGlobalFunction(&realm, "readLoop", &.{
            heap_mod.taggedObject(target),
            Value.fromInt32(20),
        })).bits,
    );
    try testing.expectEqual(driver.osr_strike_limit, state.ohaimark_osr_strikes);
    try testing.expectEqual(
        @as(u64, driver.osr_strike_limit),
        realm.heap.ohaimark_stats.executed_entries - entries_before,
    );

    const entries_at_limit = realm.heap.ohaimark_stats.executed_entries;
    _ = try callGlobalFunction(&realm, "readLoop", &.{
        heap_mod.taggedObject(target),
        Value.fromInt32(2),
    });
    try testing.expectEqual(entries_at_limit, realm.heap.ohaimark_stats.executed_entries);
}
