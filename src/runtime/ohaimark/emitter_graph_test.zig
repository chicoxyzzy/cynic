const std = @import("std");

const chunk_mod = @import("../../bytecode/chunk.zig");
const Builder = chunk_mod.Builder;
const Op = @import("../../bytecode/op.zig").Op;
const Span = @import("../../source.zig").Span;
const code_alloc = @import("../jit/code_alloc.zig");
const heap_mod = @import("../heap.zig");
const lantern = @import("../lantern/interpreter.zig");
const masm = @import("../jit/masm.zig");
const object_mod = @import("../object.zig");
const Realm = @import("../realm.zig").Realm;
const Value = @import("../value.zig").Value;
const allocation = @import("allocation.zig");
const codegen = @import("codegen_aarch64.zig");
const deopt = @import("deopt.zig");
const deopt_physical = @import("deopt_physical.zig");
const emitter = @import("emitter_aarch64.zig");
const ir = @import("ir.zig");
const lowering = @import("lowering_aarch64.zig");
const representation = @import("representation.zig");
const specialize = @import("specialize.zig");

const testing = std.testing;
const span: Span = .{ .start = 0, .end = 1 };

const NativeGraph = struct {
    graph: ir.Graph,
    specialization: specialize.Plan,
    representations: representation.Plan,
    logical: deopt.Metadata,
    homes: deopt_physical.Homes,
    physical_deopt: deopt_physical.Metadata,
    allocated: allocation.Plan,
    lowered: lowering.Plan,

    fn build(chunk: *const chunk_mod.Chunk) !NativeGraph {
        var graph = try ir.Graph.build(testing.allocator, chunk);
        errdefer graph.deinit();
        var specialization = try specialize.Plan.build(testing.allocator, &graph);
        errdefer specialization.deinit();
        var representations = try representation.Plan.build(
            testing.allocator,
            &graph,
            &specialization,
        );
        errdefer representations.deinit();
        var logical = try deopt.Metadata.build(testing.allocator, &graph, &specialization);
        errdefer logical.deinit();
        var homes = try deopt_physical.Homes.build(
            testing.allocator,
            &graph,
            &specialization,
            &representations,
            &logical,
        );
        errdefer homes.deinit();
        var physical_deopt = try deopt_physical.Metadata.build(
            testing.allocator,
            &graph,
            &specialization,
            &representations,
            &logical,
            &homes,
        );
        errdefer physical_deopt.deinit();
        var allocated = try allocation.Plan.build(
            testing.allocator,
            &graph,
            &specialization,
            &representations,
            &homes,
            .{ .register_count = lowering.value_registers.len },
        );
        errdefer allocated.deinit();
        var lowered = try lowering.Plan.build(
            testing.allocator,
            &graph,
            &specialization,
            &representations,
            &homes,
            &allocated,
        );
        errdefer lowered.deinit();
        return .{
            .graph = graph,
            .specialization = specialization,
            .representations = representations,
            .logical = logical,
            .homes = homes,
            .physical_deopt = physical_deopt,
            .allocated = allocated,
            .lowered = lowered,
        };
    }

    fn deinit(self: *NativeGraph) void {
        self.lowered.deinit();
        self.allocated.deinit();
        self.physical_deopt.deinit();
        self.homes.deinit();
        self.logical.deinit();
        self.representations.deinit();
        self.specialization.deinit();
        self.graph.deinit();
        self.* = undefined;
    }

    fn emit(self: *const NativeGraph, machine: *masm.Masm, chunk: *const chunk_mod.Chunk) !void {
        try codegen.emitGraph(
            testing.allocator,
            machine,
            chunk,
            &self.graph,
            &self.specialization,
            &self.representations,
            &self.logical,
            &self.homes,
            &self.physical_deopt,
            &self.allocated,
            &self.lowered,
        );
    }
};

fn diamondBinaryChunk(
    op: Op,
    then_value: i32,
    else_value: i32,
    rhs: i32,
) !chunk_mod.Chunk {
    if (op != .add and op != .sub and op != .mul) return error.TestUnexpectedResult;
    var builder = Builder.init(testing.allocator);
    defer builder.deinit();
    const lhs = try builder.reserveRegister();
    try builder.emitOp(.lda_true, span);
    try builder.emitOp(.jmp_if_false, span);
    const else_patch = builder.here();
    try builder.emitI16(0);
    try builder.emitLoadSmi(span, then_value);
    try builder.emitOp(.jmp, span);
    const join_patch = builder.here();
    try builder.emitI16(0);
    const else_target = builder.here();
    try builder.emitLoadSmi(span, else_value);
    const join_target = builder.here();
    try builder.emitStoreReg(span, lhs);
    try builder.emitLoadSmi(span, rhs);
    try builder.emitOp(op, span);
    try builder.emitU8(lhs);
    try builder.emitOp(.return_, span);
    try builder.patchI16(else_patch, else_target);
    try builder.patchI16(join_patch, join_target);
    return builder.finish();
}

fn checkedAddBranchChunk(rhs: i32) !chunk_mod.Chunk {
    var builder = Builder.init(testing.allocator);
    defer builder.deinit();
    const lhs = try builder.reserveRegister();
    try builder.emitOp(.lda_true, span);
    try builder.emitOp(.jmp_if_false, span);
    const else_patch = builder.here();
    try builder.emitI16(0);
    try builder.emitLoadSmi(span, 10);
    try builder.emitOp(.jmp, span);
    const join_patch = builder.here();
    try builder.emitI16(0);
    const else_target = builder.here();
    try builder.emitLoadSmi(span, 20);
    const join_target = builder.here();
    try builder.emitStoreReg(span, lhs);
    try builder.emitLoadSmi(span, rhs);
    try builder.emitOp(.add, span);
    try builder.emitU8(lhs);
    try builder.emitOp(.jmp_if_false, span);
    const false_patch = builder.here();
    try builder.emitI16(0);
    try builder.emitLoadSmi(span, 111);
    try builder.emitOp(.return_, span);
    const false_target = builder.here();
    try builder.emitLoadSmi(span, 222);
    try builder.emitOp(.return_, span);
    try builder.patchI16(else_patch, else_target);
    try builder.patchI16(join_patch, join_target);
    try builder.patchI16(false_patch, false_target);
    return builder.finish();
}

fn namedLoadChunk(realm: *Realm) !chunk_mod.Chunk {
    var builder = Builder.init(testing.allocator);
    defer builder.deinit();
    const receiver = try builder.reserveRegister();
    const key = try builder.addConstant(Value.fromString(
        try realm.heap.allocateString("x"),
    ));
    try builder.emitLoadReg(span, receiver);
    try builder.emitLdaProperty(span, key);
    try builder.emitOp(.return_, span);
    return builder.finish();
}

const SafepointLoop = struct {
    chunk: chunk_mod.Chunk,
    header: u32,
    root: u8,
};

fn safepointLoopChunk() !SafepointLoop {
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

fn countingIdleHook(ctx: ?*anyopaque) Realm.InterruptAction {
    const count: *u32 = @ptrCast(@alignCast(ctx.?));
    count.* += 1;
    return .proceed;
}

fn overflowNamedObject(realm: *Realm, value: i32) !*object_mod.JSObject {
    const object = try realm.heap.allocateObject();
    var key_buf: [32]u8 = undefined;
    for (0..object_mod.inline_slot_cap) |index| {
        const key = try std.fmt.bufPrint(&key_buf, "padding{d}", .{index});
        try realm.heap.storeProperty(
            object,
            realm.allocator,
            key,
            Value.fromInt32(@intCast(index)),
        );
    }
    try realm.heap.storeProperty(object, realm.allocator, "x", Value.fromInt32(value));
    return object;
}

fn testFrame(chunk: *const chunk_mod.Chunk, registers: []Value) lantern.CallFrame {
    @memset(registers, Value.undefined_);
    return .{
        .chunk = chunk,
        .ip = 0,
        .accumulator = Value.undefined_,
        .registers = registers,
        .env = null,
        .this_value = Value.undefined_,
        .owns_registers = false,
    };
}

const NativeEntry = *const fn (*Realm, *lantern.CallFrame, [*]Value) callconv(.c) u32;

fn installNative(
    native: *const NativeGraph,
    frame: *lantern.CallFrame,
    machine: *masm.Masm,
    executable: *code_alloc.CodeAllocator,
) !NativeEntry {
    try native.emit(machine, frame.chunk);
    return code_alloc.asFn(NativeEntry, try machine.install(executable));
}

fn executeNative(
    native: *const NativeGraph,
    realm: *Realm,
    frame: *lantern.CallFrame,
) !u32 {
    var machine = masm.Masm.init(testing.allocator);
    defer machine.deinit();
    var executable = try code_alloc.CodeAllocator.init(testing.allocator, 64 * 1024);
    defer executable.deinit();
    const entry = try installNative(native, frame, &machine, &executable);
    return entry(realm, frame, frame.registers.ptr);
}

fn findNode(native: *const NativeGraph, kind: ir.NodeKind) !ir.ValueId {
    for (native.graph.nodes, 0..) |node, index| {
        if (node.kind == kind) return @intCast(index);
    }
    return error.TestUnexpectedResult;
}

fn resumeLantern(realm: *Realm, frame: lantern.CallFrame) !Value {
    var frames: std.ArrayListUnmanaged(lantern.CallFrame) = .empty;
    defer frames.deinit(testing.allocator);
    try frames.append(testing.allocator, frame);
    return switch (try lantern.runFrames(testing.allocator, realm, &frames)) {
        .value => |value| value,
        else => error.TestUnexpectedResult,
    };
}

test "Ohaimark AArch64 emitter returns a folded graph value" {
    if (comptime !masm.native_aarch64) return error.SkipZigTest;
    var builder = Builder.init(testing.allocator);
    defer builder.deinit();
    const lhs = try builder.reserveRegister();
    try builder.emitLoadSmi(span, 1);
    try builder.emitStoreReg(span, lhs);
    try builder.emitLoadSmi(span, 2);
    try builder.emitOp(.add, span);
    try builder.emitU8(lhs);
    try builder.emitOp(.return_, span);
    var chunk = try builder.finish();
    defer chunk.deinit(testing.allocator);

    var graph = try ir.Graph.build(testing.allocator, &chunk);
    defer graph.deinit();
    var specialization = try specialize.Plan.build(testing.allocator, &graph);
    defer specialization.deinit();
    var representations = try representation.Plan.build(
        testing.allocator,
        &graph,
        &specialization,
    );
    defer representations.deinit();
    var logical = try deopt.Metadata.build(testing.allocator, &graph, &specialization);
    defer logical.deinit();
    var homes = try deopt_physical.Homes.build(
        testing.allocator,
        &graph,
        &specialization,
        &representations,
        &logical,
    );
    defer homes.deinit();
    var allocated = try allocation.Plan.build(
        testing.allocator,
        &graph,
        &specialization,
        &representations,
        &homes,
        .{ .register_count = 0 },
    );
    defer allocated.deinit();
    var physical = try lowering.Plan.build(
        testing.allocator,
        &graph,
        &specialization,
        &representations,
        &homes,
        &allocated,
    );
    defer physical.deinit();

    var return_id: ?ir.ValueId = null;
    for (graph.nodes, 0..) |node, node_index| {
        if (node.kind == .return_) return_id = @intCast(node_index);
    }
    const node_id = return_id.?;
    const node = graph.nodes[node_id];
    try testing.expectEqual(@as(u16, 1), node.input_count);
    const input_index: usize = node.input_start;
    const producer = graph.inputs[input_index];
    try testing.expectEqual(
        ir.Immediate{ .int32 = 3 },
        physical.locations[producer].immediate,
    );

    var machine = masm.Masm.init(testing.allocator);
    defer machine.deinit();
    try emitter.emitConstantReturn(
        &machine,
        physical.frame,
        physical.locations[producer],
        representations.outputs[producer],
        try representations.conversionAt(&graph, input_index),
        chunk.constants,
    );
    var executable = try code_alloc.CodeAllocator.init(testing.allocator, 64 * 1024);
    defer executable.deinit();
    const entry = code_alloc.asFn(
        *const fn (u64, u64, u64) callconv(.c) u64,
        try machine.install(&executable),
    );
    try testing.expectEqual(Value.fromInt32(3).bits, entry(0, 0, 0));
}

test "Ohaimark AArch64 graph executes checked int32 add" {
    if (comptime !masm.native_aarch64) return error.SkipZigTest;
    var chunk = try diamondBinaryChunk(.add, 10, 20, 1);
    defer chunk.deinit(testing.allocator);
    var native = try NativeGraph.build(&chunk);
    defer native.deinit();

    var realm = Realm.init(testing.allocator);
    defer realm.deinit();
    realm.jit_enabled = false;
    const registers = try testing.allocator.alloc(Value, chunk.register_count);
    defer testing.allocator.free(registers);
    var frame = testFrame(&chunk, registers);
    try testing.expectEqual(
        @intFromEnum(codegen.EntryResult.done),
        try executeNative(&native, &realm, &frame),
    );
    try testing.expectEqual(Value.fromInt32(11).bits, frame.accumulator.bits);
}

test "Ohaimark AArch64 graph executes checked int32 sub and mul" {
    if (comptime !masm.native_aarch64) return error.SkipZigTest;
    const cases = [_]struct {
        op: Op,
        then_value: i32,
        else_value: i32,
        rhs: i32,
        expected: i32,
    }{
        .{ .op = .sub, .then_value = 10, .else_value = 20, .rhs = 3, .expected = 7 },
        .{ .op = .mul, .then_value = 6, .else_value = 7, .rhs = 7, .expected = 42 },
    };
    for (cases) |case| {
        var chunk = try diamondBinaryChunk(
            case.op,
            case.then_value,
            case.else_value,
            case.rhs,
        );
        defer chunk.deinit(testing.allocator);
        var native = try NativeGraph.build(&chunk);
        defer native.deinit();
        var realm = Realm.init(testing.allocator);
        defer realm.deinit();
        realm.jit_enabled = false;
        const registers = try testing.allocator.alloc(Value, chunk.register_count);
        defer testing.allocator.free(registers);
        var frame = testFrame(&chunk, registers);
        try testing.expectEqual(
            @intFromEnum(codegen.EntryResult.done),
            try executeNative(&native, &realm, &frame),
        );
        try testing.expectEqual(Value.fromInt32(case.expected).bits, frame.accumulator.bits);
    }
}

test "Ohaimark AArch64 graph branches on a checked int32 result" {
    if (comptime !masm.native_aarch64) return error.SkipZigTest;
    const cases = [_]struct { rhs: i32, expected: i32 }{
        .{ .rhs = -10, .expected = 222 },
        .{ .rhs = -9, .expected = 111 },
    };
    for (cases) |case| {
        var chunk = try checkedAddBranchChunk(case.rhs);
        defer chunk.deinit(testing.allocator);
        var native = try NativeGraph.build(&chunk);
        defer native.deinit();
        var realm = Realm.init(testing.allocator);
        defer realm.deinit();
        realm.jit_enabled = false;
        const registers = try testing.allocator.alloc(Value, chunk.register_count);
        defer testing.allocator.free(registers);
        var frame = testFrame(&chunk, registers);
        try testing.expectEqual(
            @intFromEnum(codegen.EntryResult.done),
            try executeNative(&native, &realm, &frame),
        );
        try testing.expectEqual(Value.fromInt32(case.expected).bits, frame.accumulator.bits);
    }
}

test "Ohaimark AArch64 backedge safepoint exhausts fuel with exact loop-header state" {
    if (comptime !masm.native_aarch64) return error.SkipZigTest;
    var loop = try safepointLoopChunk();
    defer loop.chunk.deinit(testing.allocator);
    var native = try NativeGraph.build(&loop.chunk);
    defer native.deinit();

    var realm = Realm.init(testing.allocator);
    defer realm.deinit();
    realm.jit_enabled = false;
    const root = try realm.heap.allocateObject();
    const registers = try testing.allocator.alloc(Value, loop.chunk.register_count);
    defer testing.allocator.free(registers);
    var frame = testFrame(&loop.chunk, registers);
    frame.registers[loop.root] = heap_mod.taggedObject(root);
    realm.step_budget = 0;

    try testing.expectEqual(
        @intFromEnum(codegen.EntryResult.resume_interp),
        try executeNative(&native, &realm, &frame),
    );
    try testing.expectEqual(@as(u64, 0), realm.step_budget);
    try testing.expectEqual(loop.header, frame.ip);
    try testing.expectEqual(Value.fromInt32(0).bits, frame.accumulator.bits);
    try testing.expectEqual(heap_mod.taggedObject(root).bits, frame.registers[loop.root].bits);

    realm.step_budget = std.math.maxInt(u64);
    try testing.expectEqual(
        heap_mod.taggedObject(root).bits,
        (try resumeLantern(&realm, frame)).bits,
    );
}

test "Ohaimark AArch64 backedge safepoint fast path completes and consumes one unit" {
    if (comptime !masm.native_aarch64) return error.SkipZigTest;
    var loop = try safepointLoopChunk();
    defer loop.chunk.deinit(testing.allocator);
    var native = try NativeGraph.build(&loop.chunk);
    defer native.deinit();

    var realm = Realm.init(testing.allocator);
    defer realm.deinit();
    realm.jit_enabled = false;
    const registers = try testing.allocator.alloc(Value, loop.chunk.register_count);
    defer testing.allocator.free(registers);
    var frame = testFrame(&loop.chunk, registers);
    frame.registers[loop.root] = Value.null_;
    realm.step_budget = 5;

    try testing.expectEqual(
        @intFromEnum(codegen.EntryResult.done),
        try executeNative(&native, &realm, &frame),
    );
    try testing.expectEqual(@as(u64, 4), realm.step_budget);
    try testing.expectEqual(Value.null_.bits, frame.accumulator.bits);
}

test "Ohaimark AArch64 backedge safepoint preserves cooperative interrupt state" {
    if (comptime !masm.native_aarch64) return error.SkipZigTest;
    var loop = try safepointLoopChunk();
    defer loop.chunk.deinit(testing.allocator);
    var native = try NativeGraph.build(&loop.chunk);
    defer native.deinit();

    var realm = Realm.init(testing.allocator);
    defer realm.deinit();
    realm.jit_enabled = false;
    const registers = try testing.allocator.alloc(Value, loop.chunk.register_count);
    defer testing.allocator.free(registers);
    var frame = testFrame(&loop.chunk, registers);
    frame.registers[loop.root] = Value.null_;
    const budget = realm.step_budget;
    realm.requestInterrupt();

    try testing.expectEqual(
        @intFromEnum(codegen.EntryResult.resume_interp),
        try executeNative(&native, &realm, &frame),
    );
    try testing.expectEqual(budget - 1, realm.step_budget);
    try testing.expectEqual(loop.header, frame.ip);
    try testing.expectEqual(Value.fromInt32(0).bits, frame.accumulator.bits);
    realm.clearInterrupt();
}

test "Ohaimark AArch64 backedge safepoint defers interrupt hooks to Lantern" {
    if (comptime !masm.native_aarch64) return error.SkipZigTest;
    var loop = try safepointLoopChunk();
    defer loop.chunk.deinit(testing.allocator);
    var native = try NativeGraph.build(&loop.chunk);
    defer native.deinit();

    var realm = Realm.init(testing.allocator);
    defer realm.deinit();
    realm.jit_enabled = false;
    const registers = try testing.allocator.alloc(Value, loop.chunk.register_count);
    defer testing.allocator.free(registers);
    var frame = testFrame(&loop.chunk, registers);
    frame.registers[loop.root] = Value.null_;
    var polls: u32 = 0;
    const budget = realm.step_budget;
    realm.setInterruptHook(countingIdleHook, &polls);

    try testing.expectEqual(
        @intFromEnum(codegen.EntryResult.resume_interp),
        try executeNative(&native, &realm, &frame),
    );
    try testing.expectEqual(@as(u32, 0), polls);
    try testing.expectEqual(budget, realm.step_budget);
    try testing.expectEqual(loop.header, frame.ip);
    try testing.expectEqual(Value.fromInt32(0).bits, frame.accumulator.bits);
    try testing.expectEqual(Value.null_.bits, (try resumeLantern(&realm, frame)).bits);
    try testing.expect(polls > 0);
}

test "Ohaimark AArch64 GC safepoint transfers a tagged root before collection" {
    if (comptime !masm.native_aarch64) return error.SkipZigTest;
    var loop = try safepointLoopChunk();
    defer loop.chunk.deinit(testing.allocator);
    var native = try NativeGraph.build(&loop.chunk);
    defer native.deinit();

    var realm = Realm.init(testing.allocator);
    defer realm.deinit();
    realm.jit_enabled = false;
    realm.heap.setGcThreshold(1);
    const root = try realm.heap.allocateObject();
    _ = try realm.heap.allocateObject();
    try testing.expectEqual(@as(usize, 2), realm.heap.objectCount());
    const registers = try testing.allocator.alloc(Value, loop.chunk.register_count);
    defer testing.allocator.free(registers);
    var frame = testFrame(&loop.chunk, registers);
    frame.registers[loop.root] = heap_mod.taggedObject(root);
    const budget = realm.step_budget;

    try testing.expectEqual(
        @intFromEnum(codegen.EntryResult.resume_interp),
        try executeNative(&native, &realm, &frame),
    );
    try testing.expectEqual(budget, realm.step_budget);
    try testing.expectEqual(loop.header, frame.ip);
    try testing.expectEqual(Value.fromInt32(0).bits, frame.accumulator.bits);
    try testing.expectEqual(heap_mod.taggedObject(root).bits, frame.registers[loop.root].bits);

    try testing.expectEqual(
        heap_mod.taggedObject(root).bits,
        (try resumeLantern(&realm, frame)).bits,
    );
    try testing.expectEqual(@as(usize, 1), realm.heap.objectCount());
}

test "Ohaimark AArch64 own named load guards live IC state" {
    if (comptime !masm.native_aarch64) return error.SkipZigTest;
    var realm = Realm.init(testing.allocator);
    defer realm.deinit();
    realm.jit_enabled = false;

    var chunk = try namedLoadChunk(&realm);
    defer chunk.deinit(testing.allocator);
    const receiver = try realm.heap.allocateObject();
    try realm.heap.storeProperty(receiver, realm.allocator, "x", Value.fromInt32(42));
    const receiver_shape = receiver.shape orelse return error.TestUnexpectedResult;
    const slot = (receiver_shape.lookup("x") orelse return error.TestUnexpectedResult).slot;
    chunk.inline_load_caches[0].fillOwnData(receiver_shape, slot);

    var native = try NativeGraph.build(&chunk);
    defer native.deinit();
    const load_id = try findNode(&native, .load_named);
    try testing.expectEqual(
        specialize.Lowering.load_named_own,
        native.specialization.node_info[load_id].lowering,
    );
    const registers = try testing.allocator.alloc(Value, chunk.register_count);
    defer testing.allocator.free(registers);
    var frame = testFrame(&chunk, registers);
    frame.registers[0] = heap_mod.taggedObject(receiver);

    var machine = masm.Masm.init(testing.allocator);
    defer machine.deinit();
    var executable = try code_alloc.CodeAllocator.init(testing.allocator, 64 * 1024);
    defer executable.deinit();
    const entry = try installNative(&native, &frame, &machine, &executable);

    try testing.expectEqual(
        @intFromEnum(codegen.EntryResult.done),
        entry(&realm, &frame, frame.registers.ptr),
    );
    try testing.expectEqual(Value.fromInt32(42).bits, frame.accumulator.bits);

    frame = testFrame(&chunk, registers);
    frame.registers[0] = Value.fromInt32(5);
    try testing.expectEqual(
        @intFromEnum(codegen.EntryResult.resume_interp),
        entry(&realm, &frame, frame.registers.ptr),
    );
    try testing.expectEqual(native.graph.nodes[load_id].bytecode_offset, frame.ip);
    try testing.expectEqual(Value.fromInt32(5).bits, frame.accumulator.bits);

    const other = try realm.heap.allocateObject();
    try realm.heap.storeProperty(other, realm.allocator, "y", Value.fromInt32(1));
    try realm.heap.storeProperty(other, realm.allocator, "x", Value.fromInt32(99));
    frame = testFrame(&chunk, registers);
    frame.registers[0] = heap_mod.taggedObject(other);
    try testing.expectEqual(
        @intFromEnum(codegen.EntryResult.resume_interp),
        entry(&realm, &frame, frame.registers.ptr),
    );
    try testing.expectEqual(native.graph.nodes[load_id].bytecode_offset, frame.ip);
    try testing.expectEqual(heap_mod.taggedObject(other).bits, frame.accumulator.bits);
    try testing.expectEqual(Value.fromInt32(99).bits, (try resumeLantern(&realm, frame)).bits);

    chunk.inline_load_caches[0].fillOwnData(receiver_shape, slot);
    frame = testFrame(&chunk, registers);
    frame.registers[0] = heap_mod.taggedObject(receiver);
    chunk.inline_load_caches[0].invalidate();
    try testing.expectEqual(
        @intFromEnum(codegen.EntryResult.resume_interp),
        entry(&realm, &frame, frame.registers.ptr),
    );
    try testing.expectEqual(heap_mod.taggedObject(receiver).bits, frame.accumulator.bits);
    try testing.expectEqual(Value.fromInt32(42).bits, (try resumeLantern(&realm, frame)).bits);
}

test "Ohaimark AArch64 prototype named load guards holder and revision" {
    if (comptime !masm.native_aarch64) return error.SkipZigTest;
    var realm = Realm.init(testing.allocator);
    defer realm.deinit();
    realm.jit_enabled = false;

    var chunk = try namedLoadChunk(&realm);
    defer chunk.deinit(testing.allocator);
    const proto = try overflowNamedObject(&realm, 41);
    const receiver = try realm.heap.allocateObject();
    try realm.heap.storeProperty(receiver, realm.allocator, "own", Value.fromInt32(1));
    realm.heap.setObjectPrototype(receiver, proto);
    const receiver_shape = receiver.shape orelse return error.TestUnexpectedResult;
    const proto_shape = proto.shape orelse return error.TestUnexpectedResult;
    const slot = (proto_shape.lookup("x") orelse return error.TestUnexpectedResult).slot;
    try testing.expect(slot >= object_mod.inline_slot_cap);
    chunk.inline_load_caches[0].fillPrototypeData(
        receiver_shape,
        slot,
        proto,
        proto_shape,
        realm.proto_revision_counter,
    );

    var native = try NativeGraph.build(&chunk);
    defer native.deinit();
    const load_id = try findNode(&native, .load_named);
    try testing.expectEqual(
        specialize.Lowering.load_named_prototype,
        native.specialization.node_info[load_id].lowering,
    );
    const registers = try testing.allocator.alloc(Value, chunk.register_count);
    defer testing.allocator.free(registers);
    var frame = testFrame(&chunk, registers);
    frame.registers[0] = heap_mod.taggedObject(receiver);

    var machine = masm.Masm.init(testing.allocator);
    defer machine.deinit();
    var executable = try code_alloc.CodeAllocator.init(testing.allocator, 64 * 1024);
    defer executable.deinit();
    const entry = try installNative(&native, &frame, &machine, &executable);

    try testing.expectEqual(
        @intFromEnum(codegen.EntryResult.done),
        entry(&realm, &frame, frame.registers.ptr),
    );
    try testing.expectEqual(Value.fromInt32(41).bits, frame.accumulator.bits);
    try realm.heap.storeProperty(proto, realm.allocator, "x", Value.fromInt32(42));
    frame = testFrame(&chunk, registers);
    frame.registers[0] = heap_mod.taggedObject(receiver);
    try testing.expectEqual(
        @intFromEnum(codegen.EntryResult.done),
        entry(&realm, &frame, frame.registers.ptr),
    );
    try testing.expectEqual(Value.fromInt32(42).bits, frame.accumulator.bits);

    const other_proto = try overflowNamedObject(&realm, 77);
    realm.heap.setObjectPrototype(receiver, other_proto);
    frame = testFrame(&chunk, registers);
    frame.registers[0] = heap_mod.taggedObject(receiver);
    try testing.expectEqual(
        @intFromEnum(codegen.EntryResult.resume_interp),
        entry(&realm, &frame, frame.registers.ptr),
    );
    try testing.expectEqual(Value.fromInt32(77).bits, (try resumeLantern(&realm, frame)).bits);

    // Refill changed only the GC-managed holder pointer. Its shape/slot/revision
    // still satisfy the immutable assumption, so the installed code may hit.
    frame = testFrame(&chunk, registers);
    frame.registers[0] = heap_mod.taggedObject(receiver);
    try testing.expectEqual(
        @intFromEnum(codegen.EntryResult.done),
        entry(&realm, &frame, frame.registers.ptr),
    );
    try testing.expectEqual(Value.fromInt32(77).bits, frame.accumulator.bits);

    try realm.heap.storeProperty(other_proto, realm.allocator, "y", Value.fromInt32(2));
    frame = testFrame(&chunk, registers);
    frame.registers[0] = heap_mod.taggedObject(receiver);
    try testing.expectEqual(
        @intFromEnum(codegen.EntryResult.resume_interp),
        entry(&realm, &frame, frame.registers.ptr),
    );
    try testing.expectEqual(Value.fromInt32(77).bits, (try resumeLantern(&realm, frame)).bits);

    realm.proto_revision_counter +%= 1;
    frame = testFrame(&chunk, registers);
    frame.registers[0] = heap_mod.taggedObject(receiver);
    try testing.expectEqual(
        @intFromEnum(codegen.EntryResult.resume_interp),
        entry(&realm, &frame, frame.registers.ptr),
    );
    try testing.expectEqual(Value.fromInt32(77).bits, (try resumeLantern(&realm, frame)).bits);
}

test "Ohaimark AArch64 synthetic named load reads live value and guards mode" {
    if (comptime !masm.native_aarch64) return error.SkipZigTest;
    var realm = Realm.init(testing.allocator);
    defer realm.deinit();
    realm.jit_enabled = false;

    var chunk = try namedLoadChunk(&realm);
    defer chunk.deinit(testing.allocator);
    const proto = try realm.heap.allocateObject();
    try realm.heap.storeProperty(proto, realm.allocator, "x", Value.fromInt32(88));
    const receiver = try realm.heap.allocateObject();
    try realm.heap.storeProperty(receiver, realm.allocator, "own", Value.fromInt32(1));
    realm.heap.setObjectPrototype(receiver, proto);
    const receiver_shape = receiver.shape orelse return error.TestUnexpectedResult;
    const proto_shape = proto.shape orelse return error.TestUnexpectedResult;
    const slot = (proto_shape.lookup("x") orelse return error.TestUnexpectedResult).slot;
    chunk.inline_load_caches[0].fillSyntheticAccessor(
        receiver_shape,
        proto,
        proto_shape,
        realm.proto_revision_counter,
        Value.fromInt32(70),
    );

    var native = try NativeGraph.build(&chunk);
    defer native.deinit();
    const load_id = try findNode(&native, .load_named);
    try testing.expectEqual(
        specialize.Lowering.load_named_synthetic,
        native.specialization.node_info[load_id].lowering,
    );
    const registers = try testing.allocator.alloc(Value, chunk.register_count);
    defer testing.allocator.free(registers);
    var frame = testFrame(&chunk, registers);
    frame.registers[0] = heap_mod.taggedObject(receiver);

    var machine = masm.Masm.init(testing.allocator);
    defer machine.deinit();
    var executable = try code_alloc.CodeAllocator.init(testing.allocator, 64 * 1024);
    defer executable.deinit();
    const entry = try installNative(&native, &frame, &machine, &executable);

    try testing.expectEqual(
        @intFromEnum(codegen.EntryResult.done),
        entry(&realm, &frame, frame.registers.ptr),
    );
    try testing.expectEqual(Value.fromInt32(70).bits, frame.accumulator.bits);
    chunk.inline_load_caches[0].synthetic_value = Value.fromInt32(71);
    frame = testFrame(&chunk, registers);
    frame.registers[0] = heap_mod.taggedObject(receiver);
    try testing.expectEqual(
        @intFromEnum(codegen.EntryResult.done),
        entry(&realm, &frame, frame.registers.ptr),
    );
    try testing.expectEqual(Value.fromInt32(71).bits, frame.accumulator.bits);

    chunk.inline_load_caches[0].kind = .data;
    chunk.inline_load_caches[0].slot = slot;
    frame = testFrame(&chunk, registers);
    frame.registers[0] = heap_mod.taggedObject(receiver);
    try testing.expectEqual(
        @intFromEnum(codegen.EntryResult.resume_interp),
        entry(&realm, &frame, frame.registers.ptr),
    );
    try testing.expectEqual(Value.fromInt32(88).bits, (try resumeLantern(&realm, frame)).bits);
}

test "Ohaimark AArch64 guard exit reconstructs and resumes Lantern before overflow" {
    if (comptime !masm.native_aarch64) return error.SkipZigTest;
    var chunk = try diamondBinaryChunk(
        .add,
        std.math.maxInt(i32),
        std.math.maxInt(i32) - 1,
        1,
    );
    defer chunk.deinit(testing.allocator);
    var native = try NativeGraph.build(&chunk);
    defer native.deinit();
    const add_id = blk: {
        for (native.graph.nodes, 0..) |node, index| {
            if (node.kind == .add) break :blk @as(ir.ValueId, @intCast(index));
        }
        return error.TestUnexpectedResult;
    };
    try testing.expectEqual(
        specialize.Lowering.checked_int32_add,
        native.specialization.node_info[add_id].lowering,
    );

    var realm = Realm.init(testing.allocator);
    defer realm.deinit();
    realm.jit_enabled = false;
    const registers = try testing.allocator.alloc(Value, chunk.register_count);
    defer testing.allocator.free(registers);
    var frame = testFrame(&chunk, registers);
    try testing.expectEqual(
        @intFromEnum(codegen.EntryResult.resume_interp),
        try executeNative(&native, &realm, &frame),
    );
    try testing.expectEqual(native.graph.nodes[add_id].bytecode_offset, frame.ip);
    try testing.expectEqual(Value.fromInt32(1).bits, frame.accumulator.bits);
    try testing.expectEqual(
        Value.fromInt32(std.math.maxInt(i32)).bits,
        frame.registers[0].bits,
    );

    var frames: std.ArrayListUnmanaged(lantern.CallFrame) = .empty;
    defer frames.deinit(testing.allocator);
    try frames.append(testing.allocator, frame);
    const resumed = switch (try lantern.runFrames(testing.allocator, &realm, &frames)) {
        .value => |value| value,
        else => return error.TestUnexpectedResult,
    };
    const interpreted = switch (try lantern.run(testing.allocator, &realm, &chunk)) {
        .value => |value| value,
        else => return error.TestUnexpectedResult,
    };
    try testing.expectEqual(interpreted.bits, resumed.bits);
    try testing.expect(resumed.isDouble());
    try testing.expectEqual(@as(f64, 2_147_483_648), resumed.asDouble());
}

test "Ohaimark AArch64 guard exits cover sub, mul overflow, and negative zero" {
    if (comptime !masm.native_aarch64) return error.SkipZigTest;
    const cases = [_]struct {
        op: Op,
        then_value: i32,
        else_value: i32,
        rhs: i32,
        expected: f64,
        negative_zero: bool = false,
    }{
        .{
            .op = .sub,
            .then_value = std.math.minInt(i32),
            .else_value = std.math.minInt(i32) + 1,
            .rhs = 1,
            .expected = -2_147_483_649,
        },
        .{
            .op = .mul,
            .then_value = std.math.maxInt(i32),
            .else_value = std.math.maxInt(i32) - 1,
            .rhs = 2,
            .expected = 4_294_967_294,
        },
        .{
            .op = .mul,
            .then_value = -1,
            .else_value = 1,
            .rhs = 0,
            .expected = -0.0,
            .negative_zero = true,
        },
    };
    for (cases) |case| {
        var chunk = try diamondBinaryChunk(
            case.op,
            case.then_value,
            case.else_value,
            case.rhs,
        );
        defer chunk.deinit(testing.allocator);
        var native = try NativeGraph.build(&chunk);
        defer native.deinit();
        var realm = Realm.init(testing.allocator);
        defer realm.deinit();
        realm.jit_enabled = false;
        const registers = try testing.allocator.alloc(Value, chunk.register_count);
        defer testing.allocator.free(registers);
        var frame = testFrame(&chunk, registers);
        try testing.expectEqual(
            @intFromEnum(codegen.EntryResult.resume_interp),
            try executeNative(&native, &realm, &frame),
        );
        try testing.expectEqual(Value.fromInt32(case.rhs).bits, frame.accumulator.bits);
        try testing.expectEqual(Value.fromInt32(case.then_value).bits, frame.registers[0].bits);

        var frames: std.ArrayListUnmanaged(lantern.CallFrame) = .empty;
        defer frames.deinit(testing.allocator);
        try frames.append(testing.allocator, frame);
        const resumed = switch (try lantern.runFrames(testing.allocator, &realm, &frames)) {
            .value => |value| value,
            else => return error.TestUnexpectedResult,
        };
        const interpreted = switch (try lantern.run(testing.allocator, &realm, &chunk)) {
            .value => |value| value,
            else => return error.TestUnexpectedResult,
        };
        try testing.expectEqual(interpreted.bits, resumed.bits);
        try testing.expect(resumed.isDouble());
        try testing.expectEqual(case.expected, resumed.asDouble());
        if (case.negative_zero) {
            try testing.expectEqual(Value.fromDouble(-0.0).bits, resumed.bits);
        }
    }
}

test "Ohaimark AArch64 cold named load rejection is transactional" {
    var realm = Realm.init(testing.allocator);
    defer realm.deinit();
    var chunk = try namedLoadChunk(&realm);
    defer chunk.deinit(testing.allocator);
    var native = try NativeGraph.build(&chunk);
    defer native.deinit();
    const load_id = try findNode(&native, .load_named);
    try testing.expectEqual(
        specialize.Lowering.load_named_generic,
        native.specialization.node_info[load_id].lowering,
    );

    var machine = masm.Masm.init(testing.allocator);
    defer machine.deinit();
    try testing.expectError(error.UnsupportedNode, native.emit(&machine, &chunk));
    try testing.expectEqual(@as(usize, 0), machine.code.items.len);
}

test "Ohaimark AArch64 malformed named-load assumption is transactional" {
    var realm = Realm.init(testing.allocator);
    defer realm.deinit();
    var chunk = try namedLoadChunk(&realm);
    defer chunk.deinit(testing.allocator);
    const receiver = try realm.heap.allocateObject();
    try realm.heap.storeProperty(receiver, realm.allocator, "x", Value.fromInt32(1));
    const receiver_shape = receiver.shape orelse return error.TestUnexpectedResult;
    const slot = (receiver_shape.lookup("x") orelse return error.TestUnexpectedResult).slot;
    chunk.inline_load_caches[0].fillOwnData(receiver_shape, slot);
    var native = try NativeGraph.build(&chunk);
    defer native.deinit();
    try testing.expectEqual(@as(usize, 1), native.specialization.assumptions.len);
    native.specialization.assumptions[0].slot = std.math.maxInt(u32);

    var machine = masm.Masm.init(testing.allocator);
    defer machine.deinit();
    try testing.expectError(error.InvalidMetadata, native.emit(&machine, &chunk));
    try testing.expectEqual(@as(usize, 0), machine.code.items.len);
}

test "Ohaimark AArch64 malformed safepoint state is transactional" {
    var loop = try safepointLoopChunk();
    defer loop.chunk.deinit(testing.allocator);
    var native = try NativeGraph.build(&loop.chunk);
    defer native.deinit();
    const header_index = blk: {
        for (native.graph.blocks, 0..) |block, index| {
            if (block.start == loop.header) break :blk index;
        }
        return error.TestUnexpectedResult;
    };
    const header = native.graph.blocks[header_index];
    if (header.param_count < 2) return error.TestUnexpectedResult;
    native.graph.params[header.param_start].role = .{ .register = loop.root };

    var machine = masm.Masm.init(testing.allocator);
    defer machine.deinit();
    try testing.expectError(error.MalformedGraph, native.emit(&machine, &loop.chunk));
    try testing.expectEqual(@as(usize, 0), machine.code.items.len);
}

test "Ohaimark AArch64 graph rejection is transactional" {
    var builder = Builder.init(testing.allocator);
    defer builder.deinit();
    const unknown_lhs = try builder.reserveRegister();
    try builder.emitLoadSmi(span, 1);
    try builder.emitOp(.add, span);
    try builder.emitU8(unknown_lhs);
    try builder.emitOp(.return_, span);
    var chunk = try builder.finish();
    defer chunk.deinit(testing.allocator);
    var native = try NativeGraph.build(&chunk);
    defer native.deinit();

    var machine = masm.Masm.init(testing.allocator);
    defer machine.deinit();
    try testing.expectError(error.UnsupportedNode, native.emit(&machine, &chunk));
    try testing.expectEqual(@as(usize, 0), machine.code.items.len);
}
