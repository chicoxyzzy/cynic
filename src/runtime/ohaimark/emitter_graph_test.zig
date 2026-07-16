const std = @import("std");

const chunk_mod = @import("../../bytecode/chunk.zig");
const Builder = chunk_mod.Builder;
const Op = @import("../../bytecode/op.zig").Op;
const Span = @import("../../source.zig").Span;
const code_alloc = @import("../jit/code_alloc.zig");
const lantern = @import("../lantern/interpreter.zig");
const masm = @import("../jit/masm.zig");
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

fn executeNative(
    native: *const NativeGraph,
    realm: *Realm,
    frame: *lantern.CallFrame,
) !u32 {
    var machine = masm.Masm.init(testing.allocator);
    defer machine.deinit();
    try native.emit(&machine, frame.chunk);
    var executable = try code_alloc.CodeAllocator.init(testing.allocator, 64 * 1024);
    defer executable.deinit();
    const entry = code_alloc.asFn(
        *const fn (*Realm, *lantern.CallFrame, [*]Value) callconv(.c) u32,
        try machine.install(&executable),
    );
    return entry(realm, frame, frame.registers.ptr);
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
