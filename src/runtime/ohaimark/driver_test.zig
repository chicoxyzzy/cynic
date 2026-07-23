const std = @import("std");

const chunk_mod = @import("../../bytecode/chunk.zig");
const Builder = chunk_mod.Builder;
const compiler_mod = @import("../../bytecode/compiler.zig");
const Op = @import("../../bytecode/op.zig").Op;
const parser_mod = @import("../../parser/parser.zig");
const Span = @import("../../source.zig").Span;
const heap_mod = @import("../heap.zig");
const lantern = @import("../lantern/interpreter.zig");
const Realm = @import("../realm.zig").Realm;
const Value = @import("../value.zig").Value;
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
    try testing.expect(outcome == .resumed);
    try testing.expectEqual(@as(usize, 1), frames.items.len);
    try testing.expectEqual(loop.header, frames.items[0].ip);
    try testing.expectEqual(Value.fromInt32(0).bits, frames.items[0].accumulator.bits);
    try testing.expectEqual(Value.fromInt32(42).bits, frames.items[0].registers[loop.root].bits);
    // Safepoint resume must not charge enter-and-bail strikes or function-entry exits.
    try testing.expectEqual(@as(u8, 0), state.ohaimark_osr_strikes);
    try testing.expectEqual(@as(u8, 0), state.ohaimark_guard_exits);
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
        \\  let i = n;
        \\  try {
        \\    while (i) { i = i - 1; }
        \\  } catch (e) {}
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
