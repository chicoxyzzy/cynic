//! Isolated shared-backend smoke experiment, not a throughput benchmark.
const std = @import("std");
const cynic = @import("cynic");
const wasm = cynic.wasm;
const prototype = wasm.backend_prototype;
const js = cynic.runtime.ohaimark_backend_prototype;
const Value = cynic.runtime.Value;
const no_optimization = (prototype.native.Options{ .optimization = .{ .constant_folding = false, .dead_code_elimination = false } }).optimization;

// (i32 n) -> sum(i*i, i=0..n), with two zero-initialized i32 locals.
const body = [_]u8{
    1,    2,    0x7f,
    0x02, 0x40, 0x03,
    0x40, 0x20, 1,
    0x20, 0,    0x4e,
    0x0d, 1,    0x20,
    2,    0x20, 1,
    0x20, 1,    0x6c,
    0x6a, 0x21, 2,
    0x20, 1,    0x41,
    1,    0x6a, 0x21,
    1,    0x0c, 0,
    0x0b, 0x0b, 0x20,
    2,    0x0b,
};
const module_bytes = [_]u8{
    0, 0x61, 0x73, 0x6d, 1,  0,            0, 0,
    1, 6,    1,    0x60, 1,  0x7f,         1, 0x7f,
    3, 2,    1,    0,    10, body.len + 2, 1, body.len,
} ++ body;

pub fn main(init: std.process.Init) !void {
    if (comptime !prototype.native.supported) return error.UnsupportedTarget;
    const a = init.gpa;
    const lower_start = std.Io.Clock.now(.awake, init.io);
    var graph = try prototype.lowerModule(a, &module_bytes, 0);
    defer graph.deinit();
    const lower_us = lower_start.untilNow(init.io, .awake).toMicroseconds();
    var owner = try prototype.CodeAllocator.init(a, 256 * 1024);
    defer owner.deinit();
    const compile_start = std.Io.Clock.now(.awake, init.io);
    var compiled = try prototype.native.compile(a, &owner, graph.graph);
    defer compiled.deinit();
    const compile_us = compile_start.untilNow(init.io, .awake).toMicroseconds();
    const allocated_start = std.Io.Clock.now(.awake, init.io);
    var allocated = try prototype.native.compileWithOptions(a, &owner, graph.graph, .{ .optimization = no_optimization });
    defer allocated.deinit();
    const allocated_us = allocated_start.untilNow(init.io, .awake).toMicroseconds();
    const oracle_start = std.Io.Clock.now(.awake, init.io);
    var oracle = try prototype.native.compileWithOptions(a, &owner, graph.graph, .{ .allocation = .scratch, .optimization = no_optimization });
    defer oracle.deinit();
    const oracle_us = oracle_start.untilNow(init.io, .awake).toMicroseconds();

    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const module = try wasm.decode(arena.allocator(), &module_bytes);
    var instance: wasm.Instance = undefined;
    try wasm.instantiate(&instance, arena.allocator(), a, &module, .{});
    defer instance.deinit();
    instance.spasm_diagnostics = true;
    var native_entries: u32 = 0;
    for ([_]u32{ 0, 1, 2, 10, 100, 1000 }) |n| {
        var expected: u32 = 0;
        for (0..n) |i| expected +%= @as(u32, @intCast(i)) *% @as(u32, @intCast(i));
        const actual = try compiled.run(&.{n}, 10_000);
        native_entries += 1;
        if (actual != expected or actual != try oracle.run(&.{n}, 10_000) or actual != try allocated.run(&.{n}, 10_000)) return error.ResultMismatch;
        for ([_]bool{ false, true }) |spasm| {
            instance.spasm_enabled = spasm;
            const result = try wasm.invoke(&instance, a, 0, &.{n});
            defer a.free(result);
            if (result.len != 1 or result[0] != actual) return error.ResultMismatch;
        }
    }
    if (instance.spasm_runs != native_entries) return error.MissingSpasmEntry;
    const run_start = std.Io.Clock.now(.awake, init.io);
    var checksum: u64 = 0;
    for (0..100) |_| checksum +%= try compiled.run(&.{1000}, 10_000);
    const run_us = run_start.untilNow(init.io, .awake).toMicroseconds();
    const allocated_run_start = std.Io.Clock.now(.awake, init.io);
    var allocated_checksum: u64 = 0;
    for (0..100) |_| allocated_checksum +%= try allocated.run(&.{1000}, 10_000);
    const allocated_run_us = allocated_run_start.untilNow(init.io, .awake).toMicroseconds();
    const oracle_run_start = std.Io.Clock.now(.awake, init.io);
    var oracle_checksum: u64 = 0;
    for (0..100) |_| oracle_checksum +%= try oracle.run(&.{1000}, 10_000);
    const oracle_run_us = oracle_run_start.untilNow(init.io, .awake).toMicroseconds();
    if (checksum != oracle_checksum or checksum != allocated_checksum) return error.ResultMismatch;
    std.debug.print(
        "Shared backend experiment (not a production tier)\n" ++
            "Columns: optimized / allocation-only / unoptimized scratch\n" ++
            "Wasm frontend:\n" ++
            "  verified SSA: {d} blocks, {d} values\n" ++
            "  decode + validate + lower: {d} us; optimize + allocate + emit: {d} / {d} / {d} us\n" ++
            "  matching results: {d}; entries per variant: {d}; Spasm entries: {d}\n" ++
            "  100 bounded calls, including scratch allocation: {d} / {d} / {d} us; checksum: {d}\n",
        .{ graph.graph.blocks.len, graph.graph.types.len, lower_us, compile_us, allocated_us, oracle_us, native_entries, native_entries, instance.spasm_runs, run_us, allocated_run_us, oracle_run_us, checksum },
    );
    try reportAllocation(&compiled, &allocated, &oracle);
    try runJavascriptDemo(init, &owner);
    std.debug.print("Normal tier selection is unchanged. These are diagnostics, not a speedup claim.\n", .{});
}

fn runJavascriptDemo(init: std.process.Init, owner: *prototype.CodeAllocator) !void {
    const a = init.gpa;
    const source = "function sum(n) { var i = 0, s = 0; while (i < n) { s = s + i * i; i = i + 1; } return s; }";
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    var realm = cynic.runtime.Realm.init(a);
    defer realm.deinit();
    const frontend_start = std.Io.Clock.now(.awake, init.io);
    const parsed = try cynic.parser.parseScript(arena.allocator(), source, null);
    var outer = try cynic.bytecode.compiler.compileScriptAsChunk(a, &realm, &parsed, source, null);
    defer outer.deinit(a);
    const chunk = &outer.function_templates[0].chunk;
    const frontend_us = frontend_start.untilNow(init.io, .awake).toMicroseconds();
    const compile_start = std.Io.Clock.now(.awake, init.io);
    var program = try js.Program.build(a, owner, chunk);
    defer program.deinit();
    const compile_us = compile_start.untilNow(init.io, .awake).toMicroseconds();
    const allocated_start = std.Io.Clock.now(.awake, init.io);
    var allocated = try js.Program.buildWithOptions(a, owner, chunk, .{ .optimization = no_optimization });
    defer allocated.deinit();
    const allocated_us = allocated_start.untilNow(init.io, .awake).toMicroseconds();
    const oracle_start = std.Io.Clock.now(.awake, init.io);
    var oracle = try js.Program.buildWithOptions(a, owner, chunk, .{ .allocation = .scratch, .optimization = no_optimization });
    defer oracle.deinit();
    const oracle_us = oracle_start.untilNow(init.io, .awake).toMicroseconds();
    const registers = try a.alloc(Value, chunk.register_count);
    defer a.free(registers);
    var native_entries: u32 = 0;
    var recoveries: u32 = 0;
    for ([_]i32{ 0, 1, 2, 10, 100, 1000, 2000 }) |n| {
        @memset(registers, Value.undefined_);
        registers[0] = Value.fromInt32(n);
        var outcome = try program.run(.{ .accumulator = Value.undefined_, .registers = registers, .block_budget = 10_000 });
        defer outcome.deinit();
        var oracle_outcome = try oracle.run(.{ .accumulator = Value.undefined_, .registers = registers, .block_budget = 10_000 });
        defer oracle_outcome.deinit();
        var allocated_outcome = try allocated.run(.{ .accumulator = Value.undefined_, .registers = registers, .block_budget = 10_000 });
        defer allocated_outcome.deinit();
        try compareOutcomes(outcome, allocated_outcome);
        try compareOutcomes(outcome, oracle_outcome);
        native_entries += 1;
        const actual = switch (outcome) {
            .returned => |value| blk: {
                if (n == 2000) return error.MissingGuardExit;
                break :blk value;
            },
            .deopt => |*state| blk: {
                if (n != 2000 or state.bytecode_offset == 0) return error.UnexpectedGuardExit;
                const resumed = try state.resumeLantern(a, &realm, chunk);
                if (resumed != .value) return error.ResultMismatch;
                recoveries += 1;
                break :blk resumed.value;
            },
        };
        const reference = try runLantern(a, &realm, chunk, registers);
        const count: f64 = @floatFromInt(n);
        const expected = count * (count - 1) * (2 * count - 1) / 6;
        const numeric = if (actual.isInt32()) @as(f64, @floatFromInt(actual.asInt32())) else if (actual.isDouble()) actual.asDouble() else return error.ResultMismatch;
        if (numeric != expected or actual.bits != reference.bits) return error.ResultMismatch;
    }
    std.debug.print(
        "JS frontend (same sum-of-squares loop, checked Int32):\n" ++
            "  verified SSA: {d} blocks, {d} values\n" ++
            "  parse + bytecode: {d} us; specialize + lower + optimize + allocate + emit: {d} / {d} / {d} us\n" ++
            "  matching Lantern/oracle results: {d}; entries per variant: {d}; resumed guard exits: {d}\n",
        .{ program.graph.blocks.len, program.graph.types.len, frontend_us, compile_us, allocated_us, oracle_us, native_entries, native_entries, recoveries },
    );
    try reportAllocation(&program.compiled, &allocated.compiled, &oracle.compiled);
}

fn compareOutcomes(actual: anytype, expected: @TypeOf(actual)) !void {
    if (std.meta.activeTag(actual) != std.meta.activeTag(expected)) return error.ResultMismatch;
    switch (actual) {
        .returned => |value| if (value.bits != expected.returned.bits) {
            return error.ResultMismatch;
        },
        .deopt => |state| {
            if (state.node != expected.deopt.node or state.bytecode_offset != expected.deopt.bytecode_offset or
                state.accumulator.bits != expected.deopt.accumulator.bits or state.this_value.bits != expected.deopt.this_value.bits or
                state.registers.len != expected.deopt.registers.len) return error.RecoveryMismatch;
            for (state.registers, expected.deopt.registers) |value, reference| {
                if (value.bits != reference.bits) return error.RecoveryMismatch;
            }
        },
    }
}

fn reportAllocation(compiled: *const prototype.native.Compiled, allocated: *const prototype.native.Compiled, oracle: *const prototype.native.Compiled) !void {
    const memory_ops = compiled.stats.loads + compiled.stats.stores;
    const oracle_memory_ops = oracle.stats.loads + oracle.stats.stores;
    if (compiled.scratchSlotCount() >= oracle.scratchSlotCount() or memory_ops >= oracle_memory_ops)
        return error.MissingAllocationImprovement;
    std.debug.print(
        "  IR nodes: {d} -> {d}; folded: {d}; removed: {d}\n" ++
            "  code: {d} / {d} / {d} bytes; call scratch: {d} / {d} / {d} bytes\n" ++
            "  static emitted loads + stores: {d} / {d} / {d}; register moves: {d} / {d} / {d}\n",
        .{ compiled.optimization.input_nodes, compiled.optimization.output_nodes, compiled.optimization.folded_nodes, compiled.optimization.removed_nodes, compiled.code.bytes().?.len, allocated.code.bytes().?.len, oracle.code.bytes().?.len, compiled.scratchSlotCount() * 8, allocated.scratchSlotCount() * 8, oracle.scratchSlotCount() * 8, memory_ops, allocated.stats.loads + allocated.stats.stores, oracle_memory_ops, compiled.stats.register_moves, allocated.stats.register_moves, oracle.stats.register_moves },
    );
}

fn runLantern(a: std.mem.Allocator, realm: *cynic.runtime.Realm, chunk: *const cynic.bytecode.Chunk, registers: []Value) !Value {
    const lantern = cynic.runtime.lantern;
    var frames: std.ArrayList(lantern.CallFrame) = .empty;
    defer {
        for (frames.items) |*frame| frame.releaseRegisters(realm, a);
        frames.deinit(a);
    }
    try frames.append(a, .{
        .chunk = chunk,
        .ip = 0,
        .accumulator = Value.undefined_,
        .registers = registers,
        .env = null,
        .this_value = Value.undefined_,
        .owns_registers = false,
        .argc = 1,
    });
    const result = try lantern.runFrames(a, realm, &frames);
    if (result != .value) return error.ResultMismatch;
    return result.value;
}
