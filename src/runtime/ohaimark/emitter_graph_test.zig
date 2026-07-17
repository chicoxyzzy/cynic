const std = @import("std");

const chunk_mod = @import("../../bytecode/chunk.zig");
const Builder = chunk_mod.Builder;
const Op = @import("../../bytecode/op.zig").Op;
const Span = @import("../../source.zig").Span;
const a64 = @import("../jit/asm_aarch64.zig");
const code_alloc = @import("../jit/code_alloc.zig");
const heap_mod = @import("../heap.zig");
const lantern = @import("../lantern/interpreter.zig");
const masm = @import("../jit/masm.zig");
const object_mod = @import("../object.zig");
const Realm = @import("../realm.zig").Realm;
const Value = @import("../value.zig").Value;
const allocation = @import("allocation.zig");
const codegen = @import("codegen_aarch64.zig");
const control_fusion = @import("control_fusion.zig");
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
    control_fusion: control_fusion.Plan,
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
        var fused_control = try control_fusion.Plan.build(
            testing.allocator,
            &graph,
            &specialization,
            &representations,
        );
        errdefer fused_control.deinit();
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
            &fused_control,
            &homes,
            .{ .register_count = lowering.value_registers.len },
        );
        errdefer allocated.deinit();
        var lowered = try lowering.Plan.build(
            testing.allocator,
            &graph,
            &specialization,
            &representations,
            &fused_control,
            &homes,
            &allocated,
        );
        errdefer lowered.deinit();
        return .{
            .graph = graph,
            .specialization = specialization,
            .representations = representations,
            .control_fusion = fused_control,
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
        self.control_fusion.deinit();
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
            &self.control_fusion,
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
    if (op != .add and op != .sub and op != .mul and op != .div) {
        return error.TestUnexpectedResult;
    }
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
    try builder.emitBinary(op, span, lhs);
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

const StrictBranchChunk = struct {
    chunk: chunk_mod.Chunk,
    branch_pc: u32,
    lhs: u8,
    rhs: u8,
};

const StrictComparisonChunk = struct {
    chunk: chunk_mod.Chunk,
    comparison_pc: u32,
    lhs: u8,
    rhs: u8,
};

const DynamicBinaryChunk = struct {
    chunk: chunk_mod.Chunk,
    lhs: u8,
    rhs: u8,
};

fn dynamicBinaryChunk(op: Op) !DynamicBinaryChunk {
    var builder = Builder.init(testing.allocator);
    defer builder.deinit();
    const lhs = try builder.reserveRegister();
    const rhs = try builder.reserveRegister();
    try builder.emitLoadReg(span, rhs);
    try builder.emitBinary(op, span, lhs);
    try builder.emitOp(.return_, span);
    var chunk = try builder.finish();
    if (op == .mul or op == .div) {
        chunk.inline_binary_profiles[0].observe(Value.fromDouble(1.5), Value.fromInt32(2));
    }
    return .{ .chunk = chunk, .lhs = lhs, .rhs = rhs };
}

fn polymorphicDynamicBinaryChunk(op: Op) !DynamicBinaryChunk {
    var binary = try dynamicBinaryChunk(op);
    if (op == .mul or op == .div) {
        const profile = &binary.chunk.inline_binary_profiles[0];
        profile.observe(Value.fromInt32(1), Value.fromInt32(2));
        profile.observe(Value.fromInt32(1), Value.fromDouble(2.5));
        profile.observe(Value.fromDouble(1.5), Value.fromDouble(2.5));
    }
    return binary;
}

fn strictComparisonChunk(op: Op) !StrictComparisonChunk {
    if (op != .strict_eq and op != .strict_neq) return error.TestUnexpectedResult;

    var builder = Builder.init(testing.allocator);
    defer builder.deinit();
    const lhs = try builder.reserveRegister();
    const rhs = try builder.reserveRegister();
    try builder.emitLoadReg(span, rhs);
    const comparison_pc = builder.here();
    try builder.emitOp(op, span);
    try builder.emitU8(lhs);
    try builder.emitOp(.return_, span);
    return .{
        .chunk = try builder.finish(),
        .comparison_pc = @intCast(comparison_pc),
        .lhs = lhs,
        .rhs = rhs,
    };
}

fn logicalNotChunk() !chunk_mod.Chunk {
    var builder = Builder.init(testing.allocator);
    defer builder.deinit();
    try builder.emitOp(.logical_not, span);
    try builder.emitOp(.return_, span);
    return builder.finish();
}

const DirectRecoveryCycleChunk = struct {
    chunk: chunk_mod.Chunk,
    guard_pc: u32,
    lhs: u8,
    rhs: u8,
};

fn directRecoveryCycleChunk() !DirectRecoveryCycleChunk {
    var builder = Builder.init(testing.allocator);
    defer builder.deinit();
    const lhs = try builder.reserveRegister();
    const rhs = try builder.reserveRegister();
    const temporary = try builder.reserveRegister();

    try builder.emitLoadReg(span, lhs);
    try builder.emitStoreReg(span, temporary);
    try builder.emitLoadReg(span, rhs);
    try builder.emitStoreReg(span, lhs);
    try builder.emitLoadReg(span, temporary);
    try builder.emitStoreReg(span, rhs);
    try builder.emitLoadReg(span, lhs);
    const guard_pc = builder.here();
    try builder.emitOp(.logical_not, span);
    try builder.emitOp(.jmp_if_false, span);
    const false_patch = builder.here();
    try builder.emitI16(0);
    try builder.emitLoadReg(span, rhs);
    try builder.emitOp(.return_, span);
    const false_target = builder.here();
    try builder.emitLoadReg(span, lhs);
    try builder.emitOp(.return_, span);
    try builder.patchI16(false_patch, false_target);
    return .{
        .chunk = try builder.finish(),
        .guard_pc = @intCast(guard_pc),
        .lhs = lhs,
        .rhs = rhs,
    };
}

fn strictBranchChunk(op: Op) !StrictBranchChunk {
    const info = op.branchInfo() orelse return error.TestUnexpectedResult;
    if (info.canonical != .jmp_if_strict_eq and info.canonical != .jmp_if_strict_neq) {
        return error.TestUnexpectedResult;
    }

    var builder = Builder.init(testing.allocator);
    defer builder.deinit();
    const lhs = try builder.reserveRegister();
    const rhs = try builder.reserveRegister();
    try builder.emitLoadReg(span, rhs);
    const branch_pc = builder.here();
    try builder.emitOp(op, span);
    try builder.emitU8(lhs);
    switch (info.width) {
        .i8 => try builder.emitI8(3),
        .i16 => try builder.emitI16(3),
        .i32 => try builder.emitI32(3),
    }
    try builder.emitLoadSmi(span, 11);
    try builder.emitOp(.return_, span);
    try builder.emitLoadSmi(span, 22);
    try builder.emitOp(.return_, span);
    return .{
        .chunk = try builder.finish(),
        .branch_pc = @intCast(branch_pc),
        .lhs = lhs,
        .rhs = rhs,
    };
}

fn selectStrictBranchChunk() !chunk_mod.Chunk {
    var builder = Builder.init(testing.allocator);
    defer builder.deinit();
    const lhs = try builder.reserveRegister();
    const rhs = try builder.reserveRegister();
    try builder.emitLoadReg(span, rhs);
    try builder.emitOp(.jmp_if_strict_neq, span);
    try builder.emitU8(lhs);
    const target_patch = builder.here();
    try builder.emitI16(0);
    try builder.emitLoadReg(span, lhs);
    try builder.emitOp(.return_, span);
    const target = builder.here();
    try builder.emitLoadReg(span, rhs);
    try builder.emitOp(.return_, span);
    try builder.patchI16(target_patch, target);
    return builder.finish();
}

fn materializedStrictBranchChunk() !chunk_mod.Chunk {
    var builder = Builder.init(testing.allocator);
    defer builder.deinit();
    const lhs = try builder.reserveRegister();
    const rhs = try builder.reserveRegister();
    try builder.emitLoadReg(span, rhs);
    try builder.emitOp(.strict_eq, span);
    try builder.emitU8(lhs);
    try builder.emitOp(.jmp_if_true, span);
    try builder.emitI16(3);
    try builder.emitLoadSmi(span, 11);
    try builder.emitOp(.return_, span);
    try builder.emitLoadSmi(span, 22);
    try builder.emitOp(.return_, span);
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

fn thisLoadChunk(with_empty_environment: bool) !chunk_mod.Chunk {
    var builder = Builder.init(testing.allocator);
    defer builder.deinit();
    if (with_empty_environment) {
        try builder.emitOp(.make_environment, span);
        try builder.emitU8(0);
    }
    try builder.emitOp(.lda_this, span);
    try builder.emitOp(.return_, span);
    return builder.finish();
}

fn environmentLoadChunk(depth: u8, slot: u8) !chunk_mod.Chunk {
    var builder = Builder.init(testing.allocator);
    defer builder.deinit();
    try builder.emitOp(.lda_env, span);
    try builder.emitU8(depth);
    try builder.emitU8(slot);
    try builder.emitOp(.return_, span);
    return builder.finish();
}

fn globalLoadChunk(realm: *Realm, or_undefined: bool) !chunk_mod.Chunk {
    var builder = Builder.init(testing.allocator);
    defer builder.deinit();
    const key = try builder.addConstant(Value.fromString(
        try realm.heap.allocateString("ohaimarkGlobal"),
    ));
    if (or_undefined) {
        try builder.emitLdaGlobalOrUndef(span, key);
    } else {
        try builder.emitLdaGlobal(span, key);
    }
    try builder.emitOp(.return_, span);
    return builder.finish();
}

fn globalSlotLoadChunk(slot: u32) !chunk_mod.Chunk {
    var builder = Builder.init(testing.allocator);
    defer builder.deinit();
    try builder.emitOp(.lda_global_slot, span);
    try builder.emitU32(slot);
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

const NativeEntry = *const fn (
    *Realm,
    *lantern.CallFrame,
    [*]Value,
) callconv(.c) u64;

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
    return executeEntry(entry, realm, frame);
}

fn executeEntry(entry: NativeEntry, realm: *Realm, frame: *lantern.CallFrame) u32 {
    const result_bits = entry(realm, frame, frame.registers.ptr);
    if (result_bits == codegen.resume_sentinel_bits) {
        return @intFromEnum(codegen.EntryResult.resume_interp);
    }
    frame.accumulator = .{ .bits = result_bits };
    return @intFromEnum(codegen.EntryResult.done);
}

fn findNode(native: *const NativeGraph, kind: ir.NodeKind) !ir.ValueId {
    for (native.graph.nodes, 0..) |node, index| {
        if (node.kind == kind) return @intCast(index);
    }
    return error.TestUnexpectedResult;
}

fn findNodeInGraph(graph: *const ir.Graph, kind: ir.NodeKind) ?ir.ValueId {
    for (graph.nodes, 0..) |node, index| {
        if (node.kind == kind) return @intCast(index);
    }
    return null;
}

fn codeContainsWord(code: []const u8, expected: u32) bool {
    if (code.len % 4 != 0) return false;
    var instruction: usize = 0;
    while (instruction < code.len / 4) : (instruction += 1) {
        const word = std.mem.readInt(
            u32,
            code[instruction * 4 ..][0..4],
            .little,
        );
        if (word == expected) return true;
    }
    return false;
}

fn codeContainsMaskedTriple(
    code: []const u8,
    first: u32,
    second: u32,
    second_mask: u32,
    third: u32,
    third_mask: u32,
) bool {
    if (code.len % 4 != 0 or code.len < 12) return false;
    var instruction: usize = 0;
    while (instruction + 2 < code.len / 4) : (instruction += 1) {
        const first_word = std.mem.readInt(
            u32,
            code[instruction * 4 ..][0..4],
            .little,
        );
        const second_word = std.mem.readInt(
            u32,
            code[(instruction + 1) * 4 ..][0..4],
            .little,
        );
        const third_word = std.mem.readInt(
            u32,
            code[(instruction + 2) * 4 ..][0..4],
            .little,
        );
        if (first_word == first and
            (second_word & second_mask) == (second & second_mask) and
            (third_word & third_mask) == (third & third_mask))
        {
            return true;
        }
    }
    return false;
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
    var fused_control = try control_fusion.Plan.build(
        testing.allocator,
        &graph,
        &specialization,
        &representations,
    );
    defer fused_control.deinit();
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
        &fused_control,
        &homes,
        .{ .register_count = 0 },
    );
    defer allocated.deinit();
    var physical = try lowering.Plan.build(
        testing.allocator,
        &graph,
        &specialization,
        &representations,
        &fused_control,
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

test "Ohaimark AArch64 graph executes exact int32 division" {
    if (comptime !masm.native_aarch64) return error.SkipZigTest;
    var chunk = try diamondBinaryChunk(.div, 84, 86, 2);
    defer chunk.deinit(testing.allocator);
    var native = try NativeGraph.build(&chunk);
    defer native.deinit();
    const div_id = try findNode(&native, .div);
    try testing.expectEqual(
        specialize.Lowering.checked_int32_div,
        native.specialization.node_info[div_id].lowering,
    );

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
    try testing.expectEqual(Value.fromInt32(42).bits, frame.accumulator.bits);
}

test "Ohaimark AArch64 int32 division guards every non-int32 result" {
    if (comptime !masm.native_aarch64) return error.SkipZigTest;
    const cases = [_]struct {
        lhs: i32,
        other_lhs: i32,
        rhs: i32,
        expected: f64,
    }{
        .{ .lhs = 7, .other_lhs = 9, .rhs = 2, .expected = 3.5 },
        .{ .lhs = 1, .other_lhs = 2, .rhs = 0, .expected = std.math.inf(f64) },
        .{ .lhs = 0, .other_lhs = 2, .rhs = -1, .expected = -0.0 },
        .{
            .lhs = std.math.minInt(i32),
            .other_lhs = std.math.minInt(i32) + 1,
            .rhs = -1,
            .expected = 2_147_483_648,
        },
    };
    for (cases) |case| {
        var chunk = try diamondBinaryChunk(.div, case.lhs, case.other_lhs, case.rhs);
        defer chunk.deinit(testing.allocator);
        var native = try NativeGraph.build(&chunk);
        defer native.deinit();
        const div_id = try findNode(&native, .div);

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
        try testing.expectEqual(native.graph.nodes[div_id].bytecode_offset, frame.ip);
        try testing.expectEqual(Value.fromInt32(case.rhs).bits, frame.accumulator.bits);
        try testing.expectEqual(Value.fromInt32(case.lhs).bits, frame.registers[0].bits);

        const resumed = try resumeLantern(&realm, frame);
        try testing.expectEqual(Value.fromDouble(case.expected).bits, resumed.bits);
        const interpreted = switch (try lantern.run(testing.allocator, &realm, &chunk)) {
            .value => |value| value,
            else => return error.TestUnexpectedResult,
        };
        try testing.expectEqual(interpreted.bits, resumed.bits);
    }
}

test "Ohaimark AArch64 profiled Number shape omits impossible conversions" {
    var binary = try dynamicBinaryChunk(.div);
    defer binary.chunk.deinit(testing.allocator);
    var native = try NativeGraph.build(&binary.chunk);
    defer native.deinit();
    const div_id = try findNode(&native, .div);
    try testing.expectEqual(
        @as(?chunk_mod.BinaryNumberShape, .double_int32),
        native.specialization.node_info[div_id].number_shape,
    );

    var machine = masm.Masm.init(testing.allocator);
    defer machine.deinit();
    try native.emit(&machine, &binary.chunk);
    try testing.expect(codeContainsWord(
        machine.code.items,
        a64.fmovXtoD(.x16, .x14),
    ));
    try testing.expect(codeContainsWord(
        machine.code.items,
        a64.scvtfDfromW(.x17, .x13),
    ));
    try testing.expect(!codeContainsWord(
        machine.code.items,
        a64.scvtfDfromW(.x16, .x12),
    ));
    try testing.expect(!codeContainsWord(
        machine.code.items,
        a64.fmovXtoD(.x17, .x14),
    ));
}

test "Ohaimark AArch64 profiled Number shape executes and deopts exactly" {
    if (comptime !masm.native_aarch64) return error.SkipZigTest;
    var binary = try dynamicBinaryChunk(.div);
    defer binary.chunk.deinit(testing.allocator);
    var native = try NativeGraph.build(&binary.chunk);
    defer native.deinit();
    const div_id = try findNode(&native, .div);

    var realm = Realm.init(testing.allocator);
    defer realm.deinit();
    realm.jit_enabled = false;
    const registers = try testing.allocator.alloc(Value, binary.chunk.register_count);
    defer testing.allocator.free(registers);
    var machine = masm.Masm.init(testing.allocator);
    defer machine.deinit();
    var executable = try code_alloc.CodeAllocator.init(testing.allocator, 64 * 1024);
    defer executable.deinit();
    var frame = testFrame(&binary.chunk, registers);
    const entry = try installNative(&native, &frame, &machine, &executable);

    frame.registers[binary.lhs] = Value.fromDouble(7.5);
    frame.registers[binary.rhs] = Value.fromInt32(2);
    try testing.expectEqual(
        @intFromEnum(codegen.EntryResult.done),
        executeEntry(entry, &realm, &frame),
    );
    try testing.expectEqual(Value.fromDouble(3.75).bits, frame.accumulator.bits);

    frame = testFrame(&binary.chunk, registers);
    frame.registers[binary.lhs] = Value.fromInt32(7);
    frame.registers[binary.rhs] = Value.fromDouble(2.5);
    try testing.expectEqual(
        @intFromEnum(codegen.EntryResult.resume_interp),
        executeEntry(entry, &realm, &frame),
    );
    try testing.expectEqual(native.graph.nodes[div_id].bytecode_offset, frame.ip);
    try testing.expectEqual(Value.fromDouble(2.5).bits, frame.accumulator.bits);
    try testing.expectEqual(Value.fromInt32(7).bits, frame.registers[binary.lhs].bits);
    try testing.expectEqual(Value.fromDouble(2.8).bits, (try resumeLantern(&realm, frame)).bits);
}

test "Ohaimark AArch64 tagged Number arithmetic handles finite and infinite paths" {
    if (comptime !masm.native_aarch64) return error.SkipZigTest;
    const Case = struct { lhs: Value, rhs: Value, expected: Value };
    const Operation = struct {
        op: Op,
        kind: ir.NodeKind,
        lowering: specialize.Lowering,
        cases: []const Case,
    };
    const operations = [_]Operation{
        .{
            .op = .mul,
            .kind = .mul,
            .lowering = .number_mul,
            .cases = &.{
                .{ .lhs = Value.fromInt32(7), .rhs = Value.fromInt32(2), .expected = Value.fromDouble(14) },
                .{ .lhs = Value.fromDouble(7.5), .rhs = Value.fromInt32(2), .expected = Value.fromDouble(15) },
                .{ .lhs = Value.fromInt32(0), .rhs = Value.fromInt32(-1), .expected = Value.fromDouble(-0.0) },
                .{
                    .lhs = Value.fromDouble(std.math.inf(f64)),
                    .rhs = Value.fromInt32(-2),
                    .expected = Value.fromDouble(-std.math.inf(f64)),
                },
                .{
                    .lhs = Value.fromInt32(std.math.maxInt(i32)),
                    .rhs = Value.fromInt32(2),
                    .expected = Value.fromDouble(4_294_967_294),
                },
            },
        },
        .{
            .op = .div,
            .kind = .div,
            .lowering = .number_div,
            .cases = &.{
                .{ .lhs = Value.fromInt32(7), .rhs = Value.fromInt32(2), .expected = Value.fromDouble(3.5) },
                .{ .lhs = Value.fromDouble(7.5), .rhs = Value.fromInt32(2), .expected = Value.fromDouble(3.75) },
                .{
                    .lhs = Value.fromInt32(1),
                    .rhs = Value.fromInt32(0),
                    .expected = Value.fromDouble(std.math.inf(f64)),
                },
                .{
                    .lhs = Value.fromInt32(1),
                    .rhs = Value.fromDouble(-0.0),
                    .expected = Value.fromDouble(-std.math.inf(f64)),
                },
                .{ .lhs = Value.fromInt32(0), .rhs = Value.fromInt32(-1), .expected = Value.fromDouble(-0.0) },
                .{
                    .lhs = Value.fromInt32(std.math.minInt(i32)),
                    .rhs = Value.fromInt32(-1),
                    .expected = Value.fromDouble(2_147_483_648),
                },
            },
        },
    };
    for (operations) |operation| {
        var binary = try polymorphicDynamicBinaryChunk(operation.op);
        defer binary.chunk.deinit(testing.allocator);
        var native = try NativeGraph.build(&binary.chunk);
        defer native.deinit();
        const node_id = try findNode(&native, operation.kind);
        try testing.expectEqual(
            operation.lowering,
            native.specialization.node_info[node_id].lowering,
        );

        var realm = Realm.init(testing.allocator);
        defer realm.deinit();
        realm.jit_enabled = false;
        const registers = try testing.allocator.alloc(Value, binary.chunk.register_count);
        defer testing.allocator.free(registers);
        var machine = masm.Masm.init(testing.allocator);
        defer machine.deinit();
        var executable = try code_alloc.CodeAllocator.init(testing.allocator, 64 * 1024);
        defer executable.deinit();
        var frame = testFrame(&binary.chunk, registers);
        const entry = try installNative(&native, &frame, &machine, &executable);

        for (operation.cases) |case| {
            frame = testFrame(&binary.chunk, registers);
            frame.registers[binary.lhs] = case.lhs;
            frame.registers[binary.rhs] = case.rhs;
            try testing.expectEqual(
                @intFromEnum(codegen.EntryResult.done),
                executeEntry(entry, &realm, &frame),
            );
            try testing.expectEqual(case.expected.bits, frame.accumulator.bits);
        }
    }
}

test "Ohaimark AArch64 tagged Number arithmetic deopts NaN and coercion exactly" {
    if (comptime !masm.native_aarch64) return error.SkipZigTest;
    const Operation = struct {
        op: Op,
        kind: ir.NodeKind,
        nan_lhs: Value,
        nan_rhs: Value,
        coercive_expected: Value,
    };
    const operations = [_]Operation{
        .{
            .op = .mul,
            .kind = .mul,
            .nan_lhs = Value.fromInt32(0),
            .nan_rhs = Value.fromDouble(std.math.inf(f64)),
            .coercive_expected = Value.fromDouble(12),
        },
        .{
            .op = .div,
            .kind = .div,
            .nan_lhs = Value.fromInt32(0),
            .nan_rhs = Value.fromInt32(0),
            .coercive_expected = Value.fromDouble(3),
        },
    };
    for (operations) |operation| {
        var binary = try dynamicBinaryChunk(operation.op);
        defer binary.chunk.deinit(testing.allocator);
        var native = try NativeGraph.build(&binary.chunk);
        defer native.deinit();
        const node_id = try findNode(&native, operation.kind);

        var realm = Realm.init(testing.allocator);
        defer realm.deinit();
        realm.jit_enabled = false;
        const registers = try testing.allocator.alloc(Value, binary.chunk.register_count);
        defer testing.allocator.free(registers);
        var machine = masm.Masm.init(testing.allocator);
        defer machine.deinit();
        var executable = try code_alloc.CodeAllocator.init(testing.allocator, 64 * 1024);
        defer executable.deinit();
        var frame = testFrame(&binary.chunk, registers);
        const entry = try installNative(&native, &frame, &machine, &executable);
        const cases = [_]struct { lhs: Value, rhs: Value, expected: Value }{
            .{
                .lhs = operation.nan_lhs,
                .rhs = operation.nan_rhs,
                .expected = Value.fromDouble(std.math.nan(f64)),
            },
            .{
                .lhs = Value.fromString(try realm.heap.allocateString("6")),
                .rhs = Value.fromInt32(2),
                .expected = operation.coercive_expected,
            },
        };
        for (cases) |case| {
            frame = testFrame(&binary.chunk, registers);
            frame.registers[binary.lhs] = case.lhs;
            frame.registers[binary.rhs] = case.rhs;
            try testing.expectEqual(
                @intFromEnum(codegen.EntryResult.resume_interp),
                executeEntry(entry, &realm, &frame),
            );
            try testing.expectEqual(native.graph.nodes[node_id].bytecode_offset, frame.ip);
            try testing.expectEqual(case.rhs.bits, frame.accumulator.bits);
            try testing.expectEqual(case.lhs.bits, frame.registers[binary.lhs].bits);
            try testing.expectEqual(case.expected.bits, (try resumeLantern(&realm, frame)).bits);
        }
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

test "Ohaimark IR models every fused strict equality branch width with deopt state" {
    const ops = [_]Op{
        .jmp_if_strict_eq8,
        .jmp_if_strict_eq,
        .jmp_if_strict_eq32,
        .jmp_if_strict_neq8,
        .jmp_if_strict_neq,
        .jmp_if_strict_neq32,
    };
    for (ops) |op| {
        var branch_chunk = try strictBranchChunk(op);
        defer branch_chunk.chunk.deinit(testing.allocator);
        var graph = try ir.Graph.build(testing.allocator, &branch_chunk.chunk);
        defer graph.deinit();

        const strict_eq_id = findNodeInGraph(&graph, .strict_eq) orelse
            return error.TestUnexpectedResult;
        const strict_eq = graph.nodes[strict_eq_id];
        const frame_state_id = strict_eq.frame_state orelse
            return error.TestUnexpectedResult;
        try testing.expectEqual(branch_chunk.branch_pc, strict_eq.bytecode_offset);
        try testing.expectEqual(branch_chunk.branch_pc, graph.frame_states[frame_state_id].bytecode_offset);

        const branch_id = findNodeInGraph(&graph, .branch) orelse
            return error.TestUnexpectedResult;
        try testing.expectEqualSlices(
            ir.ValueId,
            &.{strict_eq_id},
            graph.nodeInputs(branch_id),
        );
        try testing.expectEqual(
            ir.Payload{ .branch = if (op.branchInfo().?.canonical == .jmp_if_strict_eq) .truthy else .falsy },
            graph.nodes[branch_id].payload,
        );
    }
}

test "Ohaimark control fusion elides only branch-exclusive strict equality values" {
    const ops = [_]Op{
        .jmp_if_strict_eq8,
        .jmp_if_strict_eq,
        .jmp_if_strict_eq32,
        .jmp_if_strict_neq8,
        .jmp_if_strict_neq,
        .jmp_if_strict_neq32,
    };
    for (ops) |op| {
        var branch_chunk = try strictBranchChunk(op);
        defer branch_chunk.chunk.deinit(testing.allocator);
        var native = try NativeGraph.build(&branch_chunk.chunk);
        defer native.deinit();

        const strict_eq_id = try findNode(&native, .strict_eq);
        const branch_id = try findNode(&native, .branch);
        try testing.expectEqual(
            strict_eq_id,
            (try native.control_fusion.strictEqualForBranch(branch_id)).?,
        );
        try testing.expect(try native.control_fusion.valueIsElided(strict_eq_id));
        try testing.expectEqual(allocation.Location.none, native.allocated.locations[strict_eq_id]);
        try native.control_fusion.verify(
            &native.graph,
            &native.specialization,
            &native.representations,
        );

        const original = native.control_fusion.strict_eq_branches[branch_id];
        native.control_fusion.strict_eq_branches[branch_id] = null;
        try testing.expectError(
            error.InvalidControlFusion,
            native.control_fusion.verify(
                &native.graph,
                &native.specialization,
                &native.representations,
            ),
        );
        native.control_fusion.strict_eq_branches[branch_id] = original;

        native.control_fusion.elided_values[strict_eq_id] = false;
        try testing.expectError(
            error.InvalidControlFusion,
            native.control_fusion.verify(
                &native.graph,
                &native.specialization,
                &native.representations,
            ),
        );
        native.control_fusion.elided_values[strict_eq_id] = true;
    }

    var standalone_chunk = try strictComparisonChunk(.strict_eq);
    defer standalone_chunk.chunk.deinit(testing.allocator);
    var standalone = try NativeGraph.build(&standalone_chunk.chunk);
    defer standalone.deinit();
    const standalone_eq = try findNode(&standalone, .strict_eq);
    try testing.expect(!(try standalone.control_fusion.valueIsElided(standalone_eq)));

    var materialized_chunk = try materializedStrictBranchChunk();
    defer materialized_chunk.deinit(testing.allocator);
    var materialized = try NativeGraph.build(&materialized_chunk);
    defer materialized.deinit();
    const materialized_eq = try findNode(&materialized, .strict_eq);
    const materialized_branch = try findNode(&materialized, .branch);
    try testing.expectEqual(
        @as(?ir.ValueId, null),
        try materialized.control_fusion.strictEqualForBranch(materialized_branch),
    );
    try testing.expect(!(try materialized.control_fusion.valueIsElided(materialized_eq)));
}

test "Ohaimark AArch64 fused strict equality branch omits Boolean materialization" {
    const cases = [_]struct { op: Op, fallthrough_branch: u32 }{
        .{ .op = .jmp_if_strict_eq8, .fallthrough_branch = a64.cbnz(.x14, 0) },
        .{ .op = .jmp_if_strict_neq8, .fallthrough_branch = a64.cbz(.x14, 0) },
    };
    for (cases) |case| {
        var branch_chunk = try strictBranchChunk(case.op);
        defer branch_chunk.chunk.deinit(testing.allocator);
        var fused = try NativeGraph.build(&branch_chunk.chunk);
        defer fused.deinit();
        var fused_machine = masm.Masm.init(testing.allocator);
        defer fused_machine.deinit();
        try fused.emit(&fused_machine, &branch_chunk.chunk);
        try testing.expect(!codeContainsWord(
            fused_machine.code.items,
            a64.csetW(.x14, .eq),
        ));
        try testing.expect(codeContainsMaskedTriple(
            fused_machine.code.items,
            a64.eorRegW(.x14, .x12, .x13),
            case.fallthrough_branch,
            0xFF00_001F,
            a64.b(0),
            0xFC00_0000,
        ));
    }

    var comparison = try strictComparisonChunk(.strict_eq);
    defer comparison.chunk.deinit(testing.allocator);
    var standalone = try NativeGraph.build(&comparison.chunk);
    defer standalone.deinit();
    var standalone_machine = masm.Masm.init(testing.allocator);
    defer standalone_machine.deinit();
    try standalone.emit(&standalone_machine, &comparison.chunk);
    try testing.expect(codeContainsWord(
        standalone_machine.code.items,
        a64.csetW(.x14, .eq),
    ));
}

test "Ohaimark coalesces and falls through empty strict equality edges" {
    var chunk = try selectStrictBranchChunk();
    defer chunk.deinit(testing.allocator);
    var native = try NativeGraph.build(&chunk);
    defer native.deinit();

    var saw_taken = false;
    var saw_fallthrough = false;
    for (native.graph.edges, 0..) |edge, edge_index| switch (edge.kind) {
        .branch_taken => {
            saw_taken = true;
            try testing.expectEqual(@as(u32, 0), native.lowered.edges[edge_index].move_count);
        },
        .branch_fallthrough => {
            saw_fallthrough = true;
            try testing.expectEqual(@as(u32, 0), native.lowered.edges[edge_index].move_count);
        },
        .fallthrough, .jump => {},
    };
    try testing.expect(saw_taken);
    try testing.expect(saw_fallthrough);

    var machine = masm.Masm.init(testing.allocator);
    defer machine.deinit();
    try native.emit(&machine, &chunk);
    try testing.expect(codeContainsMaskedTriple(
        machine.code.items,
        a64.eorRegW(.x14, .x12, .x13),
        a64.cbz(.x14, 0),
        0xFF00_001F,
        a64.b(0),
        0xFC00_0000,
    ));
}

test "Ohaimark AArch64 executes every fused strict equality branch width" {
    if (comptime !masm.native_aarch64) return error.SkipZigTest;
    const ops = [_]Op{
        .jmp_if_strict_eq8,
        .jmp_if_strict_eq,
        .jmp_if_strict_eq32,
        .jmp_if_strict_neq8,
        .jmp_if_strict_neq,
        .jmp_if_strict_neq32,
    };
    for (ops) |op| {
        for ([_]bool{ false, true }) |equal| {
            var branch_chunk = try strictBranchChunk(op);
            defer branch_chunk.chunk.deinit(testing.allocator);
            var native = try NativeGraph.build(&branch_chunk.chunk);
            defer native.deinit();
            var realm = Realm.init(testing.allocator);
            defer realm.deinit();
            realm.jit_enabled = false;
            const registers = try testing.allocator.alloc(Value, branch_chunk.chunk.register_count);
            defer testing.allocator.free(registers);
            var frame = testFrame(&branch_chunk.chunk, registers);
            frame.registers[branch_chunk.lhs] = Value.fromInt32(7);
            frame.registers[branch_chunk.rhs] = Value.fromInt32(if (equal) 7 else 8);

            try testing.expectEqual(
                @intFromEnum(codegen.EntryResult.done),
                try executeNative(&native, &realm, &frame),
            );
            const takes_branch = (op.branchInfo().?.canonical == .jmp_if_strict_eq) == equal;
            try testing.expectEqual(
                Value.fromInt32(if (takes_branch) 22 else 11).bits,
                frame.accumulator.bits,
            );
        }
    }
}

test "Ohaimark AArch64 fused strict equality deopts non-int32 operands at the exact opcode" {
    if (comptime !masm.native_aarch64) return error.SkipZigTest;
    var branch_chunk = try strictBranchChunk(.jmp_if_strict_neq8);
    defer branch_chunk.chunk.deinit(testing.allocator);
    var native = try NativeGraph.build(&branch_chunk.chunk);
    defer native.deinit();
    var realm = Realm.init(testing.allocator);
    defer realm.deinit();
    realm.jit_enabled = false;
    const registers = try testing.allocator.alloc(Value, branch_chunk.chunk.register_count);
    defer testing.allocator.free(registers);
    var frame = testFrame(&branch_chunk.chunk, registers);
    const lhs = Value.fromDouble(1.5);
    const rhs = Value.fromDouble(2.5);
    frame.registers[branch_chunk.lhs] = lhs;
    frame.registers[branch_chunk.rhs] = rhs;

    var machine = masm.Masm.init(testing.allocator);
    defer machine.deinit();
    var executable = try code_alloc.CodeAllocator.init(testing.allocator, 64 * 1024);
    defer executable.deinit();
    const entry = try installNative(&native, &frame, &machine, &executable);
    const result_bits = entry(&realm, &frame, frame.registers.ptr);
    try testing.expectEqual(codegen.resume_sentinel_bits, result_bits);
    try testing.expectEqual(branch_chunk.branch_pc, frame.ip);
    try testing.expectEqual(rhs.bits, frame.accumulator.bits);
    try testing.expectEqual(lhs.bits, frame.registers[branch_chunk.lhs].bits);
    try testing.expectEqual(rhs.bits, frame.registers[branch_chunk.rhs].bits);
    try testing.expectEqual(Value.fromInt32(22).bits, (try resumeLantern(&realm, frame)).bits);
}

test "Ohaimark IR lowers strict inequality through reusable logical not" {
    var comparison = try strictComparisonChunk(.strict_neq);
    defer comparison.chunk.deinit(testing.allocator);
    var native = try NativeGraph.build(&comparison.chunk);
    defer native.deinit();

    const strict_eq_id = try findNode(&native, .strict_eq);
    const logical_not_id = try findNode(&native, .logical_not);
    try testing.expectEqualSlices(
        ir.ValueId,
        &.{strict_eq_id},
        native.graph.nodeInputs(logical_not_id),
    );
    try testing.expect(native.graph.nodes[strict_eq_id].frame_state != null);
    try testing.expectEqual(comparison.comparison_pc, native.graph.nodes[strict_eq_id].bytecode_offset);
    try testing.expectEqual(specialize.Lowering.logical_not, native.specialization.node_info[logical_not_id].lowering);
}

test "Ohaimark IR gives direct logical not a checked Boolean deopt point" {
    var chunk = try logicalNotChunk();
    defer chunk.deinit(testing.allocator);
    var native = try NativeGraph.build(&chunk);
    defer native.deinit();

    const node_id = try findNode(&native, .logical_not);
    const node = native.graph.nodes[node_id];
    const frame_state = native.graph.frame_states[
        node.frame_state orelse
            return error.TestUnexpectedResult
    ];
    try testing.expectEqual(@as(u32, 0), node.bytecode_offset);
    try testing.expectEqual(node.bytecode_offset, frame_state.bytecode_offset);
    try testing.expectEqual(specialize.Lowering.checked_boolean_not, native.specialization.node_info[node_id].lowering);
}

test "Ohaimark AArch64 executes strict inequality for int32 operands" {
    if (comptime !masm.native_aarch64) return error.SkipZigTest;
    for ([_]bool{ false, true }) |equal| {
        var comparison = try strictComparisonChunk(.strict_neq);
        defer comparison.chunk.deinit(testing.allocator);
        var native = try NativeGraph.build(&comparison.chunk);
        defer native.deinit();
        var realm = Realm.init(testing.allocator);
        defer realm.deinit();
        realm.jit_enabled = false;
        const registers = try testing.allocator.alloc(Value, comparison.chunk.register_count);
        defer testing.allocator.free(registers);
        var frame = testFrame(&comparison.chunk, registers);
        frame.registers[comparison.lhs] = Value.fromInt32(7);
        frame.registers[comparison.rhs] = Value.fromInt32(if (equal) 7 else 8);

        try testing.expectEqual(
            @intFromEnum(codegen.EntryResult.done),
            try executeNative(&native, &realm, &frame),
        );
        try testing.expectEqual(Value.fromBool(!equal).bits, frame.accumulator.bits);
    }
}

test "Ohaimark AArch64 strict inequality deopts non-int32 operands at the exact opcode" {
    if (comptime !masm.native_aarch64) return error.SkipZigTest;
    var comparison = try strictComparisonChunk(.strict_neq);
    defer comparison.chunk.deinit(testing.allocator);
    var native = try NativeGraph.build(&comparison.chunk);
    defer native.deinit();
    var realm = Realm.init(testing.allocator);
    defer realm.deinit();
    realm.jit_enabled = false;
    const registers = try testing.allocator.alloc(Value, comparison.chunk.register_count);
    defer testing.allocator.free(registers);
    var frame = testFrame(&comparison.chunk, registers);
    const lhs = Value.fromDouble(1.5);
    const rhs = Value.fromDouble(2.5);
    frame.registers[comparison.lhs] = lhs;
    frame.registers[comparison.rhs] = rhs;

    try testing.expectEqual(
        @intFromEnum(codegen.EntryResult.resume_interp),
        try executeNative(&native, &realm, &frame),
    );
    try testing.expectEqual(comparison.comparison_pc, frame.ip);
    try testing.expectEqual(rhs.bits, frame.accumulator.bits);
    try testing.expectEqual(lhs.bits, frame.registers[comparison.lhs].bits);
    try testing.expectEqual(rhs.bits, frame.registers[comparison.rhs].bits);
    try testing.expectEqual(Value.true_.bits, (try resumeLantern(&realm, frame)).bits);
}

test "Ohaimark AArch64 executes logical not for Boolean input" {
    if (comptime !masm.native_aarch64) return error.SkipZigTest;
    for ([_]bool{ false, true }) |input| {
        var chunk = try logicalNotChunk();
        defer chunk.deinit(testing.allocator);
        var native = try NativeGraph.build(&chunk);
        defer native.deinit();
        var realm = Realm.init(testing.allocator);
        defer realm.deinit();
        realm.jit_enabled = false;
        const registers = try testing.allocator.alloc(Value, chunk.register_count);
        defer testing.allocator.free(registers);
        var frame = testFrame(&chunk, registers);
        frame.accumulator = Value.fromBool(input);

        try testing.expectEqual(
            @intFromEnum(codegen.EntryResult.done),
            try executeNative(&native, &realm, &frame),
        );
        try testing.expectEqual(Value.fromBool(!input).bits, frame.accumulator.bits);
    }
}

test "Ohaimark AArch64 logical not deopts non-Boolean input at the exact opcode" {
    if (comptime !masm.native_aarch64) return error.SkipZigTest;
    var chunk = try logicalNotChunk();
    defer chunk.deinit(testing.allocator);
    var native = try NativeGraph.build(&chunk);
    defer native.deinit();
    var realm = Realm.init(testing.allocator);
    defer realm.deinit();
    realm.jit_enabled = false;
    const registers = try testing.allocator.alloc(Value, chunk.register_count);
    defer testing.allocator.free(registers);
    var frame = testFrame(&chunk, registers);
    const input = Value.fromInt32(0);
    frame.accumulator = input;

    try testing.expectEqual(
        @intFromEnum(codegen.EntryResult.resume_interp),
        try executeNative(&native, &realm, &frame),
    );
    try testing.expectEqual(@as(u32, 0), frame.ip);
    try testing.expectEqual(input.bits, frame.accumulator.bits);
    try testing.expectEqual(Value.true_.bits, (try resumeLantern(&realm, frame)).bits);
}

test "Ohaimark direct entry recovery eliminates homes and reconstructs cycles" {
    var cycle = try directRecoveryCycleChunk();
    defer cycle.chunk.deinit(testing.allocator);
    var native = try NativeGraph.build(&cycle.chunk);
    defer native.deinit();

    try testing.expectEqual(@as(u32, 0), native.homes.tagged_slot_count);
    try testing.expectEqual(@as(u32, 0), native.homes.int32_slot_count);
    try testing.expectEqual(@as(u32, 0), native.allocated.tagged_slot_count);
    try testing.expectEqual(@as(u32, 0), native.allocated.int32_slot_count);
    try testing.expectEqual(@as(u32, 0), native.lowered.frame.spill_bytes);

    var point = try native.physical_deopt.decode(testing.allocator, 0);
    defer point.deinit();
    try testing.expectEqual(
        deopt_physical.Recovery{ .frame_register = cycle.rhs },
        point.accumulator,
    );
    try testing.expectEqual(@as(usize, 2), point.slots.len);
    try testing.expectEqual(cycle.lhs, point.slots[0].register);
    try testing.expectEqual(
        deopt_physical.Recovery{ .frame_register = cycle.rhs },
        point.slots[0].recovery,
    );
    try testing.expectEqual(cycle.rhs, point.slots[1].register);
    try testing.expectEqual(
        deopt_physical.Recovery{ .frame_register = cycle.lhs },
        point.slots[1].recovery,
    );

    if (comptime !masm.native_aarch64) return error.SkipZigTest;
    var realm = Realm.init(testing.allocator);
    defer realm.deinit();
    realm.jit_enabled = false;
    const registers = try testing.allocator.alloc(Value, cycle.chunk.register_count);
    defer testing.allocator.free(registers);
    var frame = testFrame(&cycle.chunk, registers);
    const lhs = Value.fromInt32(7);
    const rhs = Value.fromInt32(9);
    frame.registers[cycle.lhs] = lhs;
    frame.registers[cycle.rhs] = rhs;

    try testing.expectEqual(
        @intFromEnum(codegen.EntryResult.resume_interp),
        try executeNative(&native, &realm, &frame),
    );
    try testing.expectEqual(cycle.guard_pc, frame.ip);
    try testing.expectEqual(rhs.bits, frame.accumulator.bits);
    try testing.expectEqual(rhs.bits, frame.registers[cycle.lhs].bits);
    try testing.expectEqual(lhs.bits, frame.registers[cycle.rhs].bits);
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

test "Ohaimark IR elides only unobservable empty environments" {
    var safe = try thisLoadChunk(true);
    defer safe.deinit(testing.allocator);
    var safe_graph = try ir.Graph.build(testing.allocator, &safe);
    defer safe_graph.deinit();
    try testing.expect(findNodeInGraph(&safe_graph, .load_this) != null);

    var mixed_builder = Builder.init(testing.allocator);
    defer mixed_builder.deinit();
    try mixed_builder.emitOp(.make_environment, span);
    try mixed_builder.emitU8(0);
    try mixed_builder.emitOp(.lda_env, span);
    try mixed_builder.emitU8(1);
    try mixed_builder.emitU8(0);
    try mixed_builder.emitOp(.return_, span);
    var mixed = try mixed_builder.finish();
    defer mixed.deinit(testing.allocator);
    var diagnostics: ir.BuildDiagnostics = .{};
    try testing.expectError(
        error.UnsupportedOp,
        ir.Graph.buildWithDiagnostics(testing.allocator, &mixed, &diagnostics),
    );
    try testing.expectEqual(Op.make_environment, diagnostics.unsupported_opcode.?);

    var real_builder = Builder.init(testing.allocator);
    defer real_builder.deinit();
    try real_builder.emitOp(.make_environment, span);
    try real_builder.emitU8(1);
    try real_builder.emitOp(.return_, span);
    var real = try real_builder.finish();
    defer real.deinit(testing.allocator);
    diagnostics = .{};
    try testing.expectError(
        error.UnsupportedOp,
        ir.Graph.buildWithDiagnostics(testing.allocator, &real, &diagnostics),
    );
    try testing.expectEqual(Op.make_environment, diagnostics.unsupported_opcode.?);
}

test "Ohaimark AArch64 frame this load guards derived-constructor state" {
    if (comptime !masm.native_aarch64) return error.SkipZigTest;
    var chunk = try thisLoadChunk(false);
    defer chunk.deinit(testing.allocator);
    var native = try NativeGraph.build(&chunk);
    defer native.deinit();
    const node_id = try findNode(&native, .load_this);

    var realm = Realm.init(testing.allocator);
    defer realm.deinit();
    realm.jit_enabled = false;
    const registers = try testing.allocator.alloc(Value, chunk.register_count);
    defer testing.allocator.free(registers);
    var frame = testFrame(&chunk, registers);
    frame.this_value = Value.fromInt32(42);
    try testing.expectEqual(
        @intFromEnum(codegen.EntryResult.done),
        try executeNative(&native, &realm, &frame),
    );
    try testing.expectEqual(Value.fromInt32(42).bits, frame.accumulator.bits);

    var super_called = true;
    frame = testFrame(&chunk, registers);
    frame.accumulator = Value.null_;
    frame.this_value = Value.fromInt32(77);
    frame.super_called_cell = &super_called;
    try testing.expectEqual(
        @intFromEnum(codegen.EntryResult.resume_interp),
        try executeNative(&native, &realm, &frame),
    );
    try testing.expectEqual(native.graph.nodes[node_id].bytecode_offset, frame.ip);
    try testing.expectEqual(Value.null_.bits, frame.accumulator.bits);
    try testing.expectEqual(Value.fromInt32(77).bits, (try resumeLantern(&realm, frame)).bits);
}

test "Ohaimark AArch64 inherited environment load walks and guards the chain" {
    if (comptime !masm.native_aarch64) return error.SkipZigTest;
    var chunk = try environmentLoadChunk(1, 0);
    defer chunk.deinit(testing.allocator);
    var native = try NativeGraph.build(&chunk);
    defer native.deinit();
    const node_id = try findNode(&native, .load_environment);

    var realm = Realm.init(testing.allocator);
    defer realm.deinit();
    realm.jit_enabled = false;
    const outer = try realm.heap.allocateEnvironment(null, 1);
    realm.heap.storeEnvSlot(outer, 0, Value.fromInt32(42));
    const inner = try realm.heap.allocateEnvironment(outer, 0);
    const registers = try testing.allocator.alloc(Value, chunk.register_count);
    defer testing.allocator.free(registers);
    var frame = testFrame(&chunk, registers);
    frame.env = inner;
    try testing.expectEqual(
        @intFromEnum(codegen.EntryResult.done),
        try executeNative(&native, &realm, &frame),
    );
    try testing.expectEqual(Value.fromInt32(42).bits, frame.accumulator.bits);

    frame = testFrame(&chunk, registers);
    frame.accumulator = Value.null_;
    try testing.expectEqual(
        @intFromEnum(codegen.EntryResult.resume_interp),
        try executeNative(&native, &realm, &frame),
    );
    try testing.expectEqual(native.graph.nodes[node_id].bytecode_offset, frame.ip);
    try testing.expectEqual(Value.null_.bits, frame.accumulator.bits);
}

test "Ohaimark AArch64 global load guards live target shape and declaration revision" {
    if (comptime !masm.native_aarch64) return error.SkipZigTest;
    var realm = Realm.init(testing.allocator);
    defer realm.deinit();
    realm.hardened = false;
    try realm.installBuiltins();
    realm.jit_enabled = false;
    try realm.globals.put(realm.allocator, "ohaimarkGlobal", Value.fromInt32(42));

    var chunk = try globalLoadChunk(&realm, false);
    defer chunk.deinit(testing.allocator);
    const target = realm.globals.target orelse return error.TestUnexpectedResult;
    const target_shape = target.shape orelse return error.TestUnexpectedResult;
    const slot = (target_shape.lookup("ohaimarkGlobal") orelse
        return error.TestUnexpectedResult).slot;
    chunk.inline_load_caches[0].fillOwnData(target_shape, slot);
    chunk.inline_load_caches[0].proto_rev = realm.globals.decl_revision;
    var native = try NativeGraph.build(&chunk);
    defer native.deinit();
    const node_id = try findNode(&native, .load_global);
    try testing.expectEqual(
        specialize.Lowering.load_global,
        native.specialization.node_info[node_id].lowering,
    );

    const registers = try testing.allocator.alloc(Value, chunk.register_count);
    defer testing.allocator.free(registers);
    var frame = testFrame(&chunk, registers);
    try testing.expectEqual(
        @intFromEnum(codegen.EntryResult.done),
        try executeNative(&native, &realm, &frame),
    );
    try testing.expectEqual(Value.fromInt32(42).bits, frame.accumulator.bits);

    // `typeof`'s unresolved-global variant shares the hit predicate and only
    // differs after a miss has returned to Lantern.
    var or_undefined_chunk = try globalLoadChunk(&realm, true);
    defer or_undefined_chunk.deinit(testing.allocator);
    or_undefined_chunk.inline_load_caches[0].fillOwnData(target_shape, slot);
    or_undefined_chunk.inline_load_caches[0].proto_rev = realm.globals.decl_revision;
    var or_undefined_native = try NativeGraph.build(&or_undefined_chunk);
    defer or_undefined_native.deinit();
    const or_undefined_id = try findNode(&or_undefined_native, .load_global);
    try testing.expect(or_undefined_native.graph.nodes[or_undefined_id].payload.global_load.or_undefined);
    const or_undefined_registers = try testing.allocator.alloc(
        Value,
        or_undefined_chunk.register_count,
    );
    defer testing.allocator.free(or_undefined_registers);
    var or_undefined_frame = testFrame(&or_undefined_chunk, or_undefined_registers);
    try testing.expectEqual(
        @intFromEnum(codegen.EntryResult.done),
        try executeNative(&or_undefined_native, &realm, &or_undefined_frame),
    );
    try testing.expectEqual(Value.fromInt32(42).bits, or_undefined_frame.accumulator.bits);

    try realm.globals.installScriptLexBinding(realm.allocator, "ohaimarkGlobal", false);
    try realm.globals.putDecl(realm.allocator, "ohaimarkGlobal", Value.fromInt32(99));
    frame = testFrame(&chunk, registers);
    frame.accumulator = Value.null_;
    try testing.expectEqual(
        @intFromEnum(codegen.EntryResult.resume_interp),
        try executeNative(&native, &realm, &frame),
    );
    try testing.expectEqual(native.graph.nodes[node_id].bytecode_offset, frame.ip);
    try testing.expectEqual(Value.null_.bits, frame.accumulator.bits);
    try testing.expectEqual(Value.fromInt32(99).bits, (try resumeLantern(&realm, frame)).bits);
}

test "Ohaimark AArch64 global lexical slot load guards the live slice" {
    if (comptime !masm.native_aarch64) return error.SkipZigTest;
    var chunk = try globalSlotLoadChunk(0);
    defer chunk.deinit(testing.allocator);
    var native = try NativeGraph.build(&chunk);
    defer native.deinit();
    const node_id = try findNode(&native, .load_global_slot);

    var realm = Realm.init(testing.allocator);
    defer realm.deinit();
    realm.jit_enabled = false;
    try realm.globals.installScriptLexBinding(realm.allocator, "slot", false);
    try realm.globals.putDecl(realm.allocator, "slot", Value.fromInt32(42));
    const registers = try testing.allocator.alloc(Value, chunk.register_count);
    defer testing.allocator.free(registers);
    var frame = testFrame(&chunk, registers);
    try testing.expectEqual(
        @intFromEnum(codegen.EntryResult.done),
        try executeNative(&native, &realm, &frame),
    );
    try testing.expectEqual(Value.fromInt32(42).bits, frame.accumulator.bits);

    var empty_realm = Realm.init(testing.allocator);
    defer empty_realm.deinit();
    frame = testFrame(&chunk, registers);
    frame.accumulator = Value.null_;
    frame.running_realm = &empty_realm;
    try testing.expectEqual(
        @intFromEnum(codegen.EntryResult.resume_interp),
        try executeNative(&native, &realm, &frame),
    );
    try testing.expectEqual(native.graph.nodes[node_id].bytecode_offset, frame.ip);
    try testing.expectEqual(Value.null_.bits, frame.accumulator.bits);
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
        executeEntry(entry, &realm, &frame),
    );
    try testing.expectEqual(Value.fromInt32(42).bits, frame.accumulator.bits);

    frame = testFrame(&chunk, registers);
    frame.registers[0] = Value.fromInt32(5);
    try testing.expectEqual(
        @intFromEnum(codegen.EntryResult.resume_interp),
        executeEntry(entry, &realm, &frame),
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
        executeEntry(entry, &realm, &frame),
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
        executeEntry(entry, &realm, &frame),
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
        executeEntry(entry, &realm, &frame),
    );
    try testing.expectEqual(Value.fromInt32(41).bits, frame.accumulator.bits);
    try realm.heap.storeProperty(proto, realm.allocator, "x", Value.fromInt32(42));
    frame = testFrame(&chunk, registers);
    frame.registers[0] = heap_mod.taggedObject(receiver);
    try testing.expectEqual(
        @intFromEnum(codegen.EntryResult.done),
        executeEntry(entry, &realm, &frame),
    );
    try testing.expectEqual(Value.fromInt32(42).bits, frame.accumulator.bits);

    const other_proto = try overflowNamedObject(&realm, 77);
    realm.heap.setObjectPrototype(receiver, other_proto);
    frame = testFrame(&chunk, registers);
    frame.registers[0] = heap_mod.taggedObject(receiver);
    try testing.expectEqual(
        @intFromEnum(codegen.EntryResult.resume_interp),
        executeEntry(entry, &realm, &frame),
    );
    try testing.expectEqual(Value.fromInt32(77).bits, (try resumeLantern(&realm, frame)).bits);

    // Refill changed only the GC-managed holder pointer. Its shape/slot/revision
    // still satisfy the immutable assumption, so the installed code may hit.
    frame = testFrame(&chunk, registers);
    frame.registers[0] = heap_mod.taggedObject(receiver);
    try testing.expectEqual(
        @intFromEnum(codegen.EntryResult.done),
        executeEntry(entry, &realm, &frame),
    );
    try testing.expectEqual(Value.fromInt32(77).bits, frame.accumulator.bits);

    try realm.heap.storeProperty(other_proto, realm.allocator, "y", Value.fromInt32(2));
    frame = testFrame(&chunk, registers);
    frame.registers[0] = heap_mod.taggedObject(receiver);
    try testing.expectEqual(
        @intFromEnum(codegen.EntryResult.resume_interp),
        executeEntry(entry, &realm, &frame),
    );
    try testing.expectEqual(Value.fromInt32(77).bits, (try resumeLantern(&realm, frame)).bits);

    realm.proto_revision_counter +%= 1;
    frame = testFrame(&chunk, registers);
    frame.registers[0] = heap_mod.taggedObject(receiver);
    try testing.expectEqual(
        @intFromEnum(codegen.EntryResult.resume_interp),
        executeEntry(entry, &realm, &frame),
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
        executeEntry(entry, &realm, &frame),
    );
    try testing.expectEqual(Value.fromInt32(70).bits, frame.accumulator.bits);
    chunk.inline_load_caches[0].synthetic_value = Value.fromInt32(71);
    frame = testFrame(&chunk, registers);
    frame.registers[0] = heap_mod.taggedObject(receiver);
    try testing.expectEqual(
        @intFromEnum(codegen.EntryResult.done),
        executeEntry(entry, &realm, &frame),
    );
    try testing.expectEqual(Value.fromInt32(71).bits, frame.accumulator.bits);

    chunk.inline_load_caches[0].kind = .data;
    chunk.inline_load_caches[0].slot = slot;
    frame = testFrame(&chunk, registers);
    frame.registers[0] = heap_mod.taggedObject(receiver);
    try testing.expectEqual(
        @intFromEnum(codegen.EntryResult.resume_interp),
        executeEntry(entry, &realm, &frame),
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
    try testing.expectError(error.InvalidSpecialization, native.emit(&machine, &chunk));
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

test "Ohaimark AArch64 OSR entry completes a single-backedge loop" {
    if (comptime !masm.native_aarch64) return error.SkipZigTest;
    var loop = try safepointLoopChunk();
    defer loop.chunk.deinit(testing.allocator);
    var native = try NativeGraph.build(&loop.chunk);
    defer native.deinit();

    var machine = masm.Masm.init(testing.allocator);
    defer machine.deinit();
    var osr_entries: std.ArrayListUnmanaged(chunk_mod.Chunk.JitState.OsrEntry) = .empty;
    defer osr_entries.deinit(testing.allocator);
    try codegen.emitGraphCollectingOsr(
        testing.allocator,
        &machine,
        &loop.chunk,
        &native.graph,
        &native.specialization,
        &native.representations,
        &native.control_fusion,
        &native.logical,
        &native.homes,
        &native.physical_deopt,
        &native.allocated,
        &native.lowered,
        &osr_entries,
    );
    try testing.expectEqual(@as(usize, 1), osr_entries.items.len);
    try testing.expectEqual(loop.header, osr_entries.items[0].bc);

    var executable = try code_alloc.CodeAllocator.init(testing.allocator, 64 * 1024);
    defer executable.deinit();
    const entry = code_alloc.asFn(NativeEntry, try machine.install(&executable));
    const base: [*]const u8 = @ptrCast(entry);
    const stub: NativeEntry = @ptrCast(@alignCast(base + osr_entries.items[0].code_off));

    var realm = Realm.init(testing.allocator);
    defer realm.deinit();
    realm.jit_enabled = false;
    const registers = try testing.allocator.alloc(Value, loop.chunk.register_count);
    defer testing.allocator.free(registers);
    var frame = testFrame(&loop.chunk, registers);
    frame.ip = loop.header;
    frame.accumulator = Value.fromInt32(1);
    frame.registers[loop.root] = Value.null_;
    realm.step_budget = 10;

    try testing.expectEqual(
        @intFromEnum(codegen.EntryResult.done),
        executeEntry(stub, &realm, &frame),
    );
    try testing.expectEqual(Value.null_.bits, frame.accumulator.bits);
}

test "Ohaimark AArch64 OSR entry then backedge safepoint restores exact header" {
    if (comptime !masm.native_aarch64) return error.SkipZigTest;
    // Enter mid-loop via OSR with a live object in a register, force the
    // first optimized backedge's safepoint (zero fuel), and prove Lantern
    // recovers the header bytecode offset + exact live state.
    var loop = try safepointLoopChunk();
    defer loop.chunk.deinit(testing.allocator);
    var native = try NativeGraph.build(&loop.chunk);
    defer native.deinit();

    var machine = masm.Masm.init(testing.allocator);
    defer machine.deinit();
    var osr_entries: std.ArrayListUnmanaged(chunk_mod.Chunk.JitState.OsrEntry) = .empty;
    defer osr_entries.deinit(testing.allocator);
    try codegen.emitGraphCollectingOsr(
        testing.allocator,
        &machine,
        &loop.chunk,
        &native.graph,
        &native.specialization,
        &native.representations,
        &native.control_fusion,
        &native.logical,
        &native.homes,
        &native.physical_deopt,
        &native.allocated,
        &native.lowered,
        &osr_entries,
    );
    try testing.expectEqual(@as(usize, 1), osr_entries.items.len);

    var executable = try code_alloc.CodeAllocator.init(testing.allocator, 64 * 1024);
    defer executable.deinit();
    const entry = code_alloc.asFn(NativeEntry, try machine.install(&executable));
    const base: [*]const u8 = @ptrCast(entry);
    const stub: NativeEntry = @ptrCast(@alignCast(base + osr_entries.items[0].code_off));

    var realm = Realm.init(testing.allocator);
    defer realm.deinit();
    realm.jit_enabled = false;
    const root = try realm.heap.allocateObject();
    const registers = try testing.allocator.alloc(Value, loop.chunk.register_count);
    defer testing.allocator.free(registers);
    var frame = testFrame(&loop.chunk, registers);
    frame.ip = loop.header;
    // Truthy accumulator takes the loop body once; body stores zero and
    // backedges into the header, where the safepoint fires.
    frame.accumulator = Value.fromInt32(1);
    frame.registers[loop.root] = heap_mod.taggedObject(root);
    realm.step_budget = 0;

    try testing.expectEqual(
        @intFromEnum(codegen.EntryResult.resume_interp),
        executeEntry(stub, &realm, &frame),
    );
    try testing.expectEqual(loop.header, frame.ip);
    try testing.expectEqual(Value.fromInt32(0).bits, frame.accumulator.bits);
    try testing.expectEqual(heap_mod.taggedObject(root).bits, frame.registers[loop.root].bits);
}
