const std = @import("std");

const chunk_mod = @import("../../bytecode/chunk.zig");
const Op = @import("../../bytecode/op.zig").Op;
const Builder = chunk_mod.Builder;
const Span = @import("../../source.zig").Span;
const code_alloc = @import("../jit/code_alloc.zig");
const heap_mod = @import("../heap.zig");
const lantern = @import("../lantern/interpreter.zig");
const Realm = @import("../realm.zig").Realm;
const Value = @import("../value.zig").Value;
const compiler = @import("compiler.zig");
const codegen = @import("codegen_aarch64.zig");
const codegen_x86_64 = @import("codegen_x86_64.zig");
const deopt = @import("deopt.zig");
const deopt_physical = @import("deopt_physical.zig");
const ir = @import("ir.zig");
const representation = @import("representation.zig");
const specialize = @import("specialize.zig");

const testing = std.testing;
const span: Span = .{ .start = 0, .end = 1 };
const EntryFn = *const fn (
    *Realm,
    *lantern.CallFrame,
    [*]Value,
) callconv(.c) u64;

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

fn formalReturnChunk() !chunk_mod.Chunk {
    var builder = Builder.init(testing.allocator);
    defer builder.deinit();
    const formal = try builder.reserveRegister();
    try builder.emitLoadReg(span, formal);
    try builder.emitOp(.return_, span);
    return builder.finish();
}

const NumberBinaryChunk = struct {
    chunk: chunk_mod.Chunk,
    operation_pc: u32,
    lhs: u8,
    rhs: u8,
};

fn numberBinaryChunk(op: Op) !NumberBinaryChunk {
    var builder = Builder.init(testing.allocator);
    defer builder.deinit();
    const lhs = try builder.reserveRegister();
    const rhs = try builder.reserveRegister();
    try builder.emitLoadReg(span, rhs);
    const operation_pc: u32 = @intCast(builder.here());
    try builder.emitBinary(op, span, lhs);
    try builder.emitOp(.return_, span);
    var chunk = try builder.finish();
    chunk.inline_binary_profiles[0].observe(Value.fromDouble(1.5), Value.fromInt32(2));
    return .{
        .chunk = chunk,
        .operation_pc = operation_pc,
        .lhs = lhs,
        .rhs = rhs,
    };
}

const StrictSelectChunk = struct {
    chunk: chunk_mod.Chunk,
    branch_pc: u32,
    lhs: u8,
    rhs: u8,
};

fn strictSelectChunk() !StrictSelectChunk {
    var builder = Builder.init(testing.allocator);
    defer builder.deinit();
    const lhs = try builder.reserveRegister();
    const rhs = try builder.reserveRegister();
    try builder.emitLoadReg(span, rhs);
    const branch_pc: u32 = @intCast(builder.here());
    try builder.emitOp(.jmp_if_strict_neq, span);
    try builder.emitU8(lhs);
    const different_patch = builder.here();
    try builder.emitI16(0);
    try builder.emitLoadReg(span, lhs);
    try builder.emitOp(.return_, span);
    const different_target = builder.here();
    try builder.emitLoadReg(span, rhs);
    try builder.emitOp(.return_, span);
    try builder.patchI16(different_patch, different_target);
    return .{
        .chunk = try builder.finish(),
        .branch_pc = branch_pc,
        .lhs = lhs,
        .rhs = rhs,
    };
}

const NamedLoadChunk = struct {
    chunk: chunk_mod.Chunk,
    load_pc: u32,
    receiver: u8,
};

fn namedLoadChunk(realm: *Realm) !NamedLoadChunk {
    var builder = Builder.init(testing.allocator);
    defer builder.deinit();
    const receiver = try builder.reserveRegister();
    const key = try builder.addConstant(Value.fromString(
        try realm.heap.allocateString("x"),
    ));
    try builder.emitLoadReg(span, receiver);
    const load_pc: u32 = @intCast(builder.here());
    try builder.emitLdaProperty(span, key);
    try builder.emitOp(.return_, span);
    return .{
        .chunk = try builder.finish(),
        .load_pc = load_pc,
        .receiver = receiver,
    };
}

const X86LoopChunk = struct {
    chunk: chunk_mod.Chunk,
    header: u32,
    counter: u8,
    total: u8,
    update_pc: ?u32 = null,
};

fn x86TruthinessLoopChunk() !X86LoopChunk {
    var builder = Builder.init(testing.allocator);
    defer builder.deinit();
    const root = try builder.reserveRegister();
    try builder.emitOp(.lda_one, span);
    const header: u32 = @intCast(builder.here());
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
        .header = header,
        .counter = root,
        .total = root,
    };
}

const X86LoopKind = enum { count, sum, product };

fn x86IntegerLoopChunk(kind: X86LoopKind) !X86LoopChunk {
    var builder = Builder.init(testing.allocator);
    defer builder.deinit();
    const counter = try builder.reserveRegister();
    const total = try builder.reserveRegister();
    try builder.emitOp(if (kind == .product) .lda_one else .lda_zero, span);
    try builder.emitStoreReg(span, total);
    try builder.emitLoadReg(span, counter);
    const header: u32 = @intCast(builder.here());
    try builder.emitOp(.jmp_if_false, span);
    const exit_patch = builder.here();
    try builder.emitI16(0);

    switch (kind) {
        .count => {
            try builder.emitUpdateReg(.inc_reg, span, total);
        },
        .sum, .product => {
            try builder.emitLoadReg(span, counter);
            try builder.emitBinary(
                if (kind == .sum) .add else .mul,
                span,
                total,
            );
            try builder.emitStoreReg(span, total);
        },
    }
    try builder.emitUpdateReg(.dec_reg, span, counter);
    try builder.emitOp(.jmp, span);
    const back_patch = builder.here();
    try builder.emitI16(0);

    const exit_target = builder.here();
    try builder.emitLoadReg(span, total);
    try builder.emitOp(.return_, span);
    try builder.patchI16(exit_patch, exit_target);
    try builder.patchI16(back_patch, header);
    var chunk = try builder.finish();
    errdefer chunk.deinit(testing.allocator);
    const update_pc = findOpcode(
        &chunk,
        switch (kind) {
            .count => .inc_reg,
            .sum => .add,
            .product => .mul,
        },
    ) orelse return error.TestUnexpectedResult;
    return .{
        .chunk = chunk,
        .header = header,
        .counter = counter,
        .total = total,
        .update_pc = update_pc,
    };
}

fn findOpcode(chunk: *const chunk_mod.Chunk, wanted: Op) ?u32 {
    var pc: usize = 0;
    while (pc < chunk.code.len) {
        const op: Op = @enumFromInt(chunk.code[pc]);
        if (op == wanted) return std.math.cast(u32, pc);
        const width = 1 + @as(usize, Op.operandSize(op));
        if (width > chunk.code.len - pc) return null;
        pc += width;
    }
    return null;
}

fn x86LoopFrame(
    loop: *const X86LoopChunk,
    registers: []Value,
    ip: usize,
    accumulator: Value,
) lantern.CallFrame {
    @memset(registers, Value.undefined_);
    return .{
        .chunk = &loop.chunk,
        .ip = ip,
        .accumulator = accumulator,
        .registers = registers,
        .env = null,
        .this_value = Value.undefined_,
        .owns_registers = false,
    };
}

fn x86OsrEntry(loop: *const X86LoopChunk) !EntryFn {
    const state = loop.chunk.jit_state orelse return error.TestUnexpectedResult;
    const offset = state.ohaimarkOsrCodeOffset(loop.header) orelse
        return error.TestUnexpectedResult;
    const base: [*]const u8 = @ptrCast(state.ohaimark.entry() orelse
        return error.TestUnexpectedResult);
    return @ptrCast(@alignCast(base + offset));
}

test "Ohaimark x86_64 compiler publishes a formal-return leaf entry" {
    if (comptime !codegen_x86_64.native_x86_64) return error.SkipZigTest;
    var realm = Realm.init(testing.allocator);
    defer realm.deinit();
    realm.jit_enabled = false;
    var chunk = try formalReturnChunk();
    defer chunk.deinit(testing.allocator);

    try testing.expect(compiler.compile(&realm, &chunk));
    const state = chunk.jit_state.?;
    try testing.expect(!state.ohaimark_requires_frame_scope);
    const entry: EntryFn = @ptrCast(@alignCast(state.ohaimark.entry().?));
    var registers = [_]Value{Value.fromInt32(42)};
    var frame: lantern.CallFrame = .{
        .chunk = &chunk,
        .ip = 0,
        .accumulator = Value.undefined_,
        .registers = registers[0..],
        .env = null,
        .this_value = Value.undefined_,
        .owns_registers = false,
    };
    try testing.expectEqual(Value.fromInt32(42).bits, entry(&realm, &frame, registers[0..].ptr));
}

test "Ohaimark x86_64 compiler executes profiled Number leaves and restores guard state" {
    if (comptime !codegen_x86_64.native_x86_64) return error.SkipZigTest;
    const cases = [_]struct {
        op: Op,
        expected: Value,
    }{
        .{ .op = .mul, .expected = Value.fromDouble(3) },
        .{ .op = .div, .expected = Value.fromDouble(0.75) },
    };
    for (cases) |case| {
        var realm = Realm.init(testing.allocator);
        defer realm.deinit();
        realm.jit_enabled = false;
        var binary = try numberBinaryChunk(case.op);
        defer binary.chunk.deinit(testing.allocator);
        try testing.expect(compiler.compile(&realm, &binary.chunk));
        const entry: EntryFn = @ptrCast(@alignCast(binary.chunk.jit_state.?.ohaimark.entry().?));

        var registers = [_]Value{ Value.fromDouble(1.5), Value.fromInt32(2) };
        var frame: lantern.CallFrame = .{
            .chunk = &binary.chunk,
            .ip = 0,
            .accumulator = Value.undefined_,
            .registers = registers[0..],
            .env = null,
            .this_value = Value.undefined_,
            .owns_registers = false,
        };
        try testing.expectEqual(case.expected.bits, entry(&realm, &frame, registers[0..].ptr));

        registers[0] = Value.true_;
        frame.ip = 0;
        frame.accumulator = Value.undefined_;
        try testing.expectEqual(
            codegen.resume_sentinel_bits,
            entry(&realm, &frame, registers[0..].ptr),
        );
        try testing.expectEqual(binary.operation_pc, frame.ip);
        try testing.expectEqual(Value.fromInt32(2).bits, frame.accumulator.bits);
        try testing.expectEqual(Value.true_.bits, frame.registers[binary.lhs].bits);
        try testing.expectEqual(Value.fromInt32(2).bits, frame.registers[binary.rhs].bits);
    }
}

test "Ohaimark x86_64 compiler executes strict-equality diamonds and restores guard state" {
    if (comptime !codegen_x86_64.native_x86_64) return error.SkipZigTest;
    var realm = Realm.init(testing.allocator);
    defer realm.deinit();
    realm.jit_enabled = false;
    var select = try strictSelectChunk();
    defer select.chunk.deinit(testing.allocator);
    try testing.expect(compiler.compile(&realm, &select.chunk));
    const entry: EntryFn = @ptrCast(@alignCast(select.chunk.jit_state.?.ohaimark.entry().?));

    var registers = [_]Value{ Value.fromInt32(17), Value.fromInt32(17) };
    var frame: lantern.CallFrame = .{
        .chunk = &select.chunk,
        .ip = 0,
        .accumulator = Value.undefined_,
        .registers = registers[0..],
        .env = null,
        .this_value = Value.undefined_,
        .owns_registers = false,
    };
    try testing.expectEqual(
        Value.fromInt32(17).bits,
        entry(&realm, &frame, registers[0..].ptr),
    );

    registers[select.rhs] = Value.fromInt32(23);
    try testing.expectEqual(
        Value.fromInt32(23).bits,
        entry(&realm, &frame, registers[0..].ptr),
    );

    registers[select.lhs] = Value.true_;
    frame.ip = 0;
    frame.accumulator = Value.undefined_;
    try testing.expectEqual(
        codegen.resume_sentinel_bits,
        entry(&realm, &frame, registers[0..].ptr),
    );
    try testing.expectEqual(select.branch_pc, frame.ip);
    try testing.expectEqual(Value.fromInt32(23).bits, frame.accumulator.bits);
    try testing.expectEqual(Value.true_.bits, frame.registers[select.lhs].bits);
    try testing.expectEqual(Value.fromInt32(23).bits, frame.registers[select.rhs].bits);
}

test "Ohaimark x86_64 compiler executes own named loads and guards live IC state" {
    if (comptime !codegen_x86_64.native_x86_64) return error.SkipZigTest;
    var realm = Realm.init(testing.allocator);
    defer realm.deinit();
    realm.jit_enabled = false;
    var named = try namedLoadChunk(&realm);
    defer named.chunk.deinit(testing.allocator);

    const receiver = try realm.heap.allocateObject();
    try realm.heap.storeProperty(receiver, realm.allocator, "x", Value.fromInt32(42));
    const receiver_shape = receiver.shape orelse return error.TestUnexpectedResult;
    const slot = (receiver_shape.lookup("x") orelse return error.TestUnexpectedResult).slot;
    named.chunk.inline_load_caches[0].fillOwnData(receiver_shape, slot);
    try testing.expect(compiler.compile(&realm, &named.chunk));
    const entry: EntryFn = @ptrCast(@alignCast(named.chunk.jit_state.?.ohaimark.entry().?));

    var registers = [_]Value{heap_mod.taggedObject(receiver)};
    var frame: lantern.CallFrame = .{
        .chunk = &named.chunk,
        .ip = 0,
        .accumulator = Value.undefined_,
        .registers = registers[0..],
        .env = null,
        .this_value = Value.undefined_,
        .owns_registers = false,
    };
    try testing.expectEqual(
        Value.fromInt32(42).bits,
        entry(&realm, &frame, registers[0..].ptr),
    );

    registers[named.receiver] = Value.fromInt32(5);
    frame.ip = 0;
    frame.accumulator = Value.undefined_;
    try testing.expectEqual(
        codegen.resume_sentinel_bits,
        entry(&realm, &frame, registers[0..].ptr),
    );
    try testing.expectEqual(named.load_pc, frame.ip);
    try testing.expectEqual(Value.fromInt32(5).bits, frame.accumulator.bits);

    const other = try realm.heap.allocateObject();
    try realm.heap.storeProperty(other, realm.allocator, "y", Value.fromInt32(1));
    try realm.heap.storeProperty(other, realm.allocator, "x", Value.fromInt32(99));
    registers[named.receiver] = heap_mod.taggedObject(other);
    frame.ip = 0;
    frame.accumulator = Value.undefined_;
    try testing.expectEqual(
        codegen.resume_sentinel_bits,
        entry(&realm, &frame, registers[0..].ptr),
    );
    try testing.expectEqual(heap_mod.taggedObject(other).bits, frame.accumulator.bits);

    named.chunk.inline_load_caches[0].invalidate();
    registers[named.receiver] = heap_mod.taggedObject(receiver);
    frame.ip = 0;
    frame.accumulator = Value.undefined_;
    try testing.expectEqual(
        codegen.resume_sentinel_bits,
        entry(&realm, &frame, registers[0..].ptr),
    );
    try testing.expectEqual(heap_mod.taggedObject(receiver).bits, frame.accumulator.bits);
}

test "Ohaimark x86_64 compiler publishes loop-header OSR and restores a zero-fuel header" {
    if (comptime !codegen_x86_64.native_x86_64) return error.SkipZigTest;
    var realm = Realm.init(testing.allocator);
    defer realm.deinit();
    realm.jit_enabled = false;
    var loop = try x86TruthinessLoopChunk();
    defer loop.chunk.deinit(testing.allocator);

    try testing.expect(compiler.compile(&realm, &loop.chunk));
    try testing.expect(loop.chunk.jit_state.?.hasOhaimarkOsr());
    const stub = try x86OsrEntry(&loop);
    var registers = [_]Value{Value.fromInt32(42)};
    var frame = x86LoopFrame(
        &loop,
        registers[0..],
        loop.header,
        Value.fromInt32(1),
    );
    frame.registers[loop.counter] = Value.fromInt32(42);
    realm.step_budget = std.math.maxInt(u64);
    try testing.expectEqual(
        Value.fromInt32(42).bits,
        stub(&realm, &frame, frame.registers.ptr),
    );
    try testing.expectEqual(std.math.maxInt(u64), realm.step_budget);

    frame = x86LoopFrame(
        &loop,
        registers[0..],
        loop.header,
        Value.fromInt32(1),
    );
    frame.registers[loop.counter] = Value.fromInt32(42);
    realm.step_budget = 0;
    try testing.expectEqual(
        codegen.safepoint_sentinel_bits,
        stub(&realm, &frame, frame.registers.ptr),
    );
    try testing.expectEqual(loop.header, frame.ip);
    try testing.expectEqual(Value.fromInt32(0).bits, frame.accumulator.bits);
    try testing.expectEqual(Value.fromInt32(42).bits, frame.registers[loop.counter].bits);
}

test "Ohaimark x86_64 backedge interrupt restores the exact loop header" {
    if (comptime !codegen_x86_64.native_x86_64) return error.SkipZigTest;
    var realm = Realm.init(testing.allocator);
    defer realm.deinit();
    realm.jit_enabled = false;
    var loop = try x86TruthinessLoopChunk();
    defer loop.chunk.deinit(testing.allocator);
    try testing.expect(compiler.compile(&realm, &loop.chunk));
    const stub = try x86OsrEntry(&loop);

    var registers = [_]Value{Value.fromInt32(42)};
    var frame = x86LoopFrame(
        &loop,
        registers[0..],
        loop.header,
        Value.fromInt32(1),
    );
    frame.registers[loop.counter] = Value.fromInt32(42);
    const budget = realm.step_budget;
    realm.requestInterrupt();
    try testing.expectEqual(
        codegen.safepoint_sentinel_bits,
        stub(&realm, &frame, frame.registers.ptr),
    );
    try testing.expectEqual(budget, realm.step_budget);
    try testing.expectEqual(loop.header, frame.ip);
    try testing.expectEqual(Value.fromInt32(0).bits, frame.accumulator.bits);
    try testing.expectEqual(Value.fromInt32(42).bits, frame.registers[loop.counter].bits);
}

test "Ohaimark x86_64 GC poll transfers a tagged root to the Lantern frame" {
    if (comptime !codegen_x86_64.native_x86_64) return error.SkipZigTest;
    var realm = Realm.init(testing.allocator);
    defer realm.deinit();
    realm.jit_enabled = false;
    var loop = try x86TruthinessLoopChunk();
    defer loop.chunk.deinit(testing.allocator);
    try testing.expect(compiler.compile(&realm, &loop.chunk));
    const stub = try x86OsrEntry(&loop);

    realm.heap.setGcThreshold(1);
    const root = try realm.heap.allocateObject();
    _ = try realm.heap.allocateObject();
    var registers = [_]Value{heap_mod.taggedObject(root)};
    var frame = x86LoopFrame(
        &loop,
        registers[0..],
        loop.header,
        Value.fromInt32(1),
    );
    frame.registers[loop.counter] = heap_mod.taggedObject(root);
    const budget = realm.step_budget;
    try testing.expectEqual(
        codegen.safepoint_sentinel_bits,
        stub(&realm, &frame, frame.registers.ptr),
    );
    try testing.expectEqual(budget, realm.step_budget);
    try testing.expectEqual(loop.header, frame.ip);
    try testing.expectEqual(Value.fromInt32(0).bits, frame.accumulator.bits);
    try testing.expectEqual(
        heap_mod.taggedObject(root).bits,
        frame.registers[loop.counter].bits,
    );
}

test "Ohaimark x86_64 compiler executes count sum and product loops through OSR" {
    if (comptime !codegen_x86_64.native_x86_64) return error.SkipZigTest;
    const cases = [_]struct {
        kind: X86LoopKind,
        start: i32,
        initial_total: i32,
        expected: i32,
    }{
        .{ .kind = .count, .start = 5, .initial_total = 0, .expected = 5 },
        .{ .kind = .sum, .start = 5, .initial_total = 0, .expected = 15 },
        .{ .kind = .product, .start = 5, .initial_total = 1, .expected = 120 },
    };
    for (cases) |case| {
        var realm = Realm.init(testing.allocator);
        defer realm.deinit();
        realm.jit_enabled = false;
        var loop = try x86IntegerLoopChunk(case.kind);
        defer loop.chunk.deinit(testing.allocator);
        try testing.expect(compiler.compile(&realm, &loop.chunk));
        const stub = try x86OsrEntry(&loop);

        var registers = [_]Value{ Value.undefined_, Value.undefined_ };
        var frame = x86LoopFrame(
            &loop,
            registers[0..],
            loop.header,
            Value.fromInt32(case.start),
        );
        frame.registers[loop.counter] = Value.fromInt32(case.start);
        frame.registers[loop.total] = Value.fromInt32(case.initial_total);
        realm.step_budget = std.math.maxInt(u64);
        try testing.expectEqual(
            Value.fromInt32(case.expected).bits,
            stub(&realm, &frame, frame.registers.ptr),
        );
    }
}

test "Ohaimark x86_64 loop overflow restores the exact pre-update frame" {
    if (comptime !codegen_x86_64.native_x86_64) return error.SkipZigTest;
    var realm = Realm.init(testing.allocator);
    defer realm.deinit();
    realm.jit_enabled = false;
    var loop = try x86IntegerLoopChunk(.count);
    defer loop.chunk.deinit(testing.allocator);
    try testing.expect(compiler.compile(&realm, &loop.chunk));
    const stub = try x86OsrEntry(&loop);

    var registers = [_]Value{ Value.undefined_, Value.undefined_ };
    var frame = x86LoopFrame(
        &loop,
        registers[0..],
        loop.header,
        Value.fromInt32(1),
    );
    frame.registers[loop.counter] = Value.fromInt32(1);
    frame.registers[loop.total] = Value.fromInt32(std.math.maxInt(i32));
    realm.step_budget = std.math.maxInt(u64);
    try testing.expectEqual(
        codegen.resume_sentinel_bits,
        stub(&realm, &frame, frame.registers.ptr),
    );
    try testing.expectEqual(loop.update_pc.?, frame.ip);
    try testing.expectEqual(Value.fromInt32(1).bits, frame.accumulator.bits);
    try testing.expectEqual(Value.fromInt32(1).bits, frame.registers[loop.counter].bits);
    try testing.expectEqual(
        Value.fromInt32(std.math.maxInt(i32)).bits,
        frame.registers[loop.total].bits,
    );
}

test "Ohaimark x86_64 loop fixture records physical deopt at the update opcode" {
    var loop = try x86IntegerLoopChunk(.count);
    defer loop.chunk.deinit(testing.allocator);
    var graph = try ir.Graph.build(testing.allocator, &loop.chunk);
    defer graph.deinit();
    var specialization = try specialize.Plan.build(testing.allocator, &graph);
    defer specialization.deinit();
    var representations = try representation.Plan.build(
        testing.allocator,
        &graph,
        &specialization,
    );
    defer representations.deinit();
    var logical = try deopt.Metadata.build(
        testing.allocator,
        &graph,
        &specialization,
    );
    defer logical.deinit();
    var homes = try deopt_physical.Homes.build(
        testing.allocator,
        &graph,
        &specialization,
        &representations,
        &logical,
    );
    defer homes.deinit();
    var physical = try deopt_physical.Metadata.build(
        testing.allocator,
        &graph,
        &specialization,
        &representations,
        &logical,
        &homes,
    );
    defer physical.deinit();

    var update_node: ?ir.ValueId = null;
    for (graph.nodes, 0..) |node, index| {
        if (node.kind == .add and node.bytecode_offset == loop.update_pc.?) {
            update_node = @intCast(index);
            break;
        }
    }
    const expected_node = update_node orelse return error.TestUnexpectedResult;
    var point_index: ?usize = null;
    for (physical.points, 0..) |point, index| {
        if (point.node == expected_node) {
            point_index = index;
            break;
        }
    }
    var point = try physical.decode(
        testing.allocator,
        point_index orelse return error.TestUnexpectedResult,
    );
    defer point.deinit();
    try testing.expectEqual(loop.update_pc.?, point.bytecode_offset);
}

test "Ohaimark compiler publishes owned code after temporary plans die" {
    if (comptime !compiler.supported) return error.SkipZigTest;
    var realm = Realm.init(testing.allocator);
    defer realm.deinit();
    realm.jit_enabled = false;
    realm.heap.ohaimark_stats.enabled = true;
    var chunk = try foldedAddChunk();
    defer chunk.deinit(testing.allocator);

    try testing.expect(compiler.compile(&realm, &chunk));
    const state = chunk.jit_state.?;
    try testing.expectEqual(chunk_mod.Chunk.JitState.Tier.compiled, state.ohaimark.tier);
    const published_entry = state.ohaimark.entry().?;
    try testing.expect(compiler.compile(&realm, &chunk));
    try testing.expectEqual(published_entry, state.ohaimark.entry().?);
    try testing.expectEqual(@as(u64, 1), realm.heap.ohaimark_stats.compile_attempts);
    try testing.expectEqual(@as(u64, 1), realm.heap.ohaimark_stats.compile_successes);
    try testing.expectEqual(@as(u64, 0), realm.heap.ohaimark_stats.compile_refusals);
    try testing.expect(realm.heap.ohaimark_stats.code_bytes_installed > 0);
    try testing.expect(
        realm.heap.ohaimark_stats.compile_time_ns_total >=
            realm.heap.ohaimark_stats.compile_time_ns_max,
    );

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
    const result_bits = entry(&realm, &frame, registers.ptr);
    try testing.expectEqual(Value.fromInt32(3).bits, result_bits);
    try testing.expectEqual(Value.undefined_.bits, frame.accumulator.bits);
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
