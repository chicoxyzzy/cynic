const std = @import("std");

const chunk_mod = @import("../../bytecode/chunk.zig");
const Builder = chunk_mod.Builder;
const Op = @import("../../bytecode/op.zig").Op;
const Span = @import("../../source.zig").Span;
const a64 = @import("../jit/asm_aarch64.zig");
const code_alloc = @import("../jit/code_alloc.zig");
const NativeError = @import("../function.zig").NativeError;
const heap_mod = @import("../heap.zig");
const JSString = @import("../string.zig").JSString;
const lantern = @import("../lantern/interpreter.zig");
const arith = @import("../lantern/arith.zig");
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

const RegisterUpdateChunk = struct {
    chunk: chunk_mod.Chunk,
    register: u8,
    update_pc: u32,
};

/// One §13.4 register update with a deliberately distinct incoming
/// accumulator. Guard exits must restore that accumulator and leave the
/// binding untouched before Lantern replays the original opcode.
fn registerUpdateChunk(op: Op) !RegisterUpdateChunk {
    if (op != .inc_reg and op != .dec_reg) return error.TestUnexpectedResult;
    var builder = Builder.init(testing.allocator);
    defer builder.deinit();
    const register = try builder.reserveRegister();
    try builder.emitLoadSmi(span, 99);
    const update_pc = builder.here();
    try builder.emitUpdateReg(op, span, register);
    // Consume the binding after the update. Native completion need not spill a
    // dead virtual register back to the Lantern frame, but this load proves
    // the update changed the SSA binding seen by the next bytecode operation.
    try builder.emitLoadReg(span, register);
    try builder.emitOp(.return_, span);
    return .{
        .chunk = try builder.finish(),
        .register = register,
        .update_pc = update_pc,
    };
}

const ToNumericUpdateChunk = struct {
    chunk: chunk_mod.Chunk,
    register: u8,
    to_numeric_pc: u32,
    update_pc: u32,
};

/// Result-preserving §13.4 update shape: `ToNumeric` has a distinct deopt
/// point from the subsequent Int32 bump. A non-Int32 input must replay the
/// coercion, while an overflow after a successful coercion replays only Inc or
/// Dec with the coerced accumulator.
fn toNumericUpdateChunk(op: Op) !ToNumericUpdateChunk {
    if (op != .inc and op != .dec) return error.TestUnexpectedResult;
    var builder = Builder.init(testing.allocator);
    defer builder.deinit();
    const register = try builder.reserveRegister();
    try builder.emitLoadReg(span, register);
    const to_numeric_pc = builder.here();
    try builder.emitOp(.to_numeric, span);
    const update_pc = builder.here();
    try builder.emitOp(op, span);
    try builder.emitOp(.return_, span);
    return .{
        .chunk = try builder.finish(),
        .register = register,
        .to_numeric_pc = to_numeric_pc,
        .update_pc = update_pc,
    };
}

/// The bytecode emitted for a consumed postfix result: save the coerced old
/// value, compute the bump for PutValue, then reload the saved value as the
/// expression result.
fn toNumericPostfixUpdateChunk(op: Op) !chunk_mod.Chunk {
    if (op != .inc and op != .dec) return error.TestUnexpectedResult;
    var builder = Builder.init(testing.allocator);
    defer builder.deinit();
    const input = try builder.reserveRegister();
    const original = try builder.reserveRegister();
    try builder.emitLoadReg(span, input);
    try builder.emitOp(.to_numeric, span);
    try builder.emitStoreReg(span, original);
    try builder.emitOp(op, span);
    try builder.emitLoadReg(span, original);
    try builder.emitOp(.return_, span);
    return builder.finish();
}

const UnaryGuardChunk = struct {
    chunk: chunk_mod.Chunk,
    input: u8,
    operation_pc: u32,
};

fn unaryGuardChunk(op: Op) !UnaryGuardChunk {
    if (op != .to_string and op != .require_object_coercible) {
        return error.TestUnexpectedResult;
    }
    var builder = Builder.init(testing.allocator);
    defer builder.deinit();
    const input = try builder.reserveRegister();
    try builder.emitLoadReg(span, input);
    const operation_pc: u32 = @intCast(builder.here());
    try builder.emitOp(op, span);
    try builder.emitOp(.return_, span);
    return .{
        .chunk = try builder.finish(),
        .input = input,
        .operation_pc = operation_pc,
    };
}

const TailDispatchChunk = struct {
    chunk: chunk_mod.Chunk,
    tail_pc: u32,
    receiver: ?u8,
    callee: u8,
    argument: u8,
};

/// §15.10 terminals are deliberately resumed in Lantern: it owns frame reuse
/// and therefore preserves constant native stack for all callee shapes.
fn tailDispatchChunk(op: Op) !TailDispatchChunk {
    if (op != .tail_call and op != .tail_call_method) return error.TestUnexpectedResult;
    var builder = Builder.init(testing.allocator);
    defer builder.deinit();
    const receiver: ?u8 = if (op == .tail_call_method) try builder.reserveRegister() else null;
    const callee = try builder.reserveRegister();
    const argument = try builder.reserveRegister();
    try builder.emitLoadSmi(span, 99);
    const tail_pc = builder.here();
    try builder.emitOp(op, span);
    if (receiver) |register| try builder.emitU8(register);
    try builder.emitU8(callee);
    try builder.emitU8(1);
    return .{
        .chunk = try builder.finish(),
        .tail_pc = tail_pc,
        .receiver = receiver,
        .callee = callee,
        .argument = argument,
    };
}

fn malformedTailDispatchChunk() !chunk_mod.Chunk {
    var builder = Builder.init(testing.allocator);
    defer builder.deinit();
    try builder.emitLoadSmi(span, 1);
    try builder.emitOp(.tail_call, span);
    try builder.emitU8(255);
    try builder.emitU8(1);
    return builder.finish();
}

const ComputedDeleteChunk = struct {
    chunk: chunk_mod.Chunk,
    delete_pc: u32,
    object_register: u8,
    key_register: u8,
};

fn computedDeleteChunk() !ComputedDeleteChunk {
    var builder = Builder.init(testing.allocator);
    defer builder.deinit();
    const object_register = try builder.reserveRegister();
    const key_register = try builder.reserveRegister();
    try builder.emitLoadSmi(span, 41);
    try builder.emitStoreReg(span, object_register);
    try builder.emitLoadSmi(span, 17);
    try builder.emitStoreReg(span, key_register);
    const delete_pc: u32 = @intCast(builder.here());
    try builder.emitOp(.del_computed_property, span);
    try builder.emitU8(object_register);
    try builder.emitU8(key_register);
    try builder.emitOp(.return_, span);
    return .{
        .chunk = try builder.finish(),
        .delete_pc = delete_pc,
        .object_register = object_register,
        .key_register = key_register,
    };
}

fn malformedComputedDeleteChunk() !chunk_mod.Chunk {
    var builder = Builder.init(testing.allocator);
    defer builder.deinit();
    _ = try builder.reserveRegister();
    try builder.emitOp(.del_computed_property, span);
    try builder.emitU8(0);
    try builder.emitU8(255);
    try builder.emitOp(.return_, span);
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

const RelationalComparisonChunk = struct {
    chunk: chunk_mod.Chunk,
    comparison_pc: u32,
    lhs: u8,
    rhs: u8,
};

const RelationalBranchChunk = struct {
    chunk: chunk_mod.Chunk,
    branch_pc: u32,
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

fn relationalComparisonChunk(op: Op) !RelationalComparisonChunk {
    if (op != .lt and op != .gt and op != .ge) return error.TestUnexpectedResult;

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

fn relationalBranchChunk(op: Op) !RelationalBranchChunk {
    const info = op.branchInfo() orelse return error.TestUnexpectedResult;
    switch (info.canonical) {
        .jmp_if_not_lt,
        .jmp_if_not_le,
        .jmp_if_not_gt,
        .jmp_if_not_ge,
        => {},
        else => return error.TestUnexpectedResult,
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

fn relationalBranchResult(op: Op, lhs: i32, rhs: i32) bool {
    return switch (op.branchInfo().?.canonical) {
        .jmp_if_not_lt => lhs < rhs,
        .jmp_if_not_le => lhs <= rhs,
        .jmp_if_not_gt => lhs > rhs,
        .jmp_if_not_ge => lhs >= rhs,
        else => unreachable,
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

fn namedStoreChunk(realm: *Realm) !chunk_mod.Chunk {
    var builder = Builder.init(testing.allocator);
    defer builder.deinit();
    const receiver = try builder.reserveRegister();
    const key = try builder.addConstant(Value.fromString(
        try realm.heap.allocateString("x"),
    ));
    try builder.emitStaProperty(span, key, receiver);
    try builder.emitOp(.return_, span);
    var chunk = try builder.finish();
    errdefer chunk.deinit(testing.allocator);
    try realm.heap.pinChunk(&chunk);
    return chunk;
}

fn computedLoadChunk() !chunk_mod.Chunk {
    var builder = Builder.init(testing.allocator);
    defer builder.deinit();
    const receiver = try builder.reserveRegister();
    try builder.emitLdaComputed(span, receiver);
    try builder.emitOp(.return_, span);
    return builder.finish();
}

fn computedStoreChunk() !chunk_mod.Chunk {
    var builder = Builder.init(testing.allocator);
    defer builder.deinit();
    const receiver = try builder.reserveRegister();
    const key = try builder.reserveRegister();
    const value = try builder.reserveRegister();
    try builder.emitLoadReg(span, value);
    try builder.emitStaComputed(span, receiver, key);
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

fn argumentsChunk() !chunk_mod.Chunk {
    var builder = Builder.init(testing.allocator);
    defer builder.deinit();
    // Model two incoming caller arguments. The native helper reads the
    // CallFrame window directly, rather than accepting unrooted values from
    // generated registers across its allocation boundary.
    _ = try builder.reserveRegister();
    _ = try builder.reserveRegister();
    try builder.emitOp(.lda_arguments, span);
    try builder.emitOp(.return_, span);
    return builder.finish();
}

fn plainObjectChunk() !chunk_mod.Chunk {
    var builder = Builder.init(testing.allocator);
    defer builder.deinit();
    try builder.emitOp(.make_object, span);
    try builder.emitOp(.return_, span);
    return builder.finish();
}

const DenseArrayLiteralChunk = struct {
    chunk: chunk_mod.Chunk,
    base: u8,
    count: u8,
    make_array_pc: u32,
};

fn denseArrayLiteralChunk(count: u8) !DenseArrayLiteralChunk {
    if (count == 0) return error.TestUnexpectedResult;
    var builder = Builder.init(testing.allocator);
    defer builder.deinit();
    const base = try builder.reserveRegister();
    var index: u8 = 1;
    while (index < count) : (index += 1) {
        _ = try builder.reserveRegister();
    }
    const make_array_pc: u32 = @intCast(builder.here());
    try builder.emitOp(.make_array_n, span);
    try builder.emitU8(base);
    try builder.emitU8(count);
    try builder.emitOp(.return_, span);
    return .{
        .chunk = try builder.finish(),
        .base = base,
        .count = count,
        .make_array_pc = make_array_pc,
    };
}

fn malformedDenseArrayLiteralChunk() !chunk_mod.Chunk {
    var builder = Builder.init(testing.allocator);
    defer builder.deinit();
    _ = try builder.reserveRegister();
    try builder.emitOp(.make_array_n, span);
    try builder.emitU8(0);
    try builder.emitU8(2);
    try builder.emitOp(.return_, span);
    return builder.finish();
}

const UnfusedDenseArrayLiteralChunk = struct {
    chunk: chunk_mod.Chunk,
    element_registers: [17]u8,
    array_register: u8,
    make_array_pc: u32,
};

fn unfusedDenseArrayLiteralChunk() !UnfusedDenseArrayLiteralChunk {
    var builder = Builder.init(testing.allocator);
    defer builder.deinit();
    var element_registers: [17]u8 = undefined;
    for (&element_registers) |*register| {
        register.* = try builder.reserveRegister();
    }
    const array_register = try builder.reserveRegister();
    const make_array_pc: u32 = @intCast(builder.here());
    try builder.emitOp(.make_array, span);
    try builder.emitStoreReg(span, array_register);
    for (element_registers, 0..) |element_register, index| {
        const key = try builder.addConstant(Value.fromString(@ptrFromInt(0x1000 + index * 16)));
        try builder.emitLoadReg(span, element_register);
        try builder.emitOp(.def_property, span);
        try builder.emitU16(key);
        try builder.emitU8(array_register);
    }
    try builder.emitLoadReg(span, array_register);
    try builder.emitOp(.return_, span);
    return .{
        .chunk = try builder.finish(),
        .element_registers = element_registers,
        .array_register = array_register,
        .make_array_pc = make_array_pc,
    };
}

fn ordinaryFunctionChunk() !chunk_mod.Chunk {
    var builder = Builder.init(testing.allocator);
    defer builder.deinit();
    var body_builder = Builder.init(testing.allocator);
    defer body_builder.deinit();
    // The function's own call frame begins at its captured environment, so
    // this makes the native test prove the closure owns that environment after
    // the creator frame drops it.
    try body_builder.emitOp(.lda_env, span);
    try body_builder.emitU8(0);
    try body_builder.emitU8(0);
    try body_builder.emitOp(.return_, span);
    const body = try body_builder.finish();
    const template = builder.addFunctionTemplate(.{
        .chunk = body,
        .param_count = 2,
        .spec_length = 1,
        .name = "captured",
        .is_arrow = false,
    }) catch |err| {
        var owned_body = body;
        owned_body.deinit(testing.allocator);
        return err;
    };
    try builder.emitOp(.make_function, span);
    try builder.emitU16(template);
    try builder.emitOp(.return_, span);
    return builder.finish();
}

fn shapedObjectChunk(realm: *Realm) !chunk_mod.Chunk {
    var builder = Builder.init(testing.allocator);
    defer builder.deinit();
    const object_register = try builder.reserveRegister();
    const key = try builder.addConstant(Value.fromString(
        try realm.heap.allocateString("answer"),
    ));
    const keys = try testing.allocator.dupe(u16, &.{key});
    const shape = builder.addLiteralShapeTemplate(keys) catch |err| {
        testing.allocator.free(keys);
        return err;
    };
    try builder.emitOp(.make_object_shape, span);
    try builder.emitU16(shape);
    try builder.emitStoreReg(span, object_register);
    try builder.emitLoadSmi(span, 42);
    try builder.emitDefTemplateProperty(span, key, object_register, 0);
    try builder.emitLoadReg(span, object_register);
    try builder.emitOp(.return_, span);
    var chunk = try builder.finish();
    errdefer chunk.deinit(testing.allocator);
    try realm.heap.pinChunk(&chunk);
    return chunk;
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

fn globalStoreChunk(realm: *Realm) !chunk_mod.Chunk {
    var builder = Builder.init(testing.allocator);
    defer builder.deinit();
    const key = try builder.addConstant(Value.fromString(
        try realm.heap.allocateString("ohaimarkGlobal"),
    ));
    try builder.emitOp(.sta_global, span);
    try builder.emitU16(key);
    try builder.emitOp(.return_, span);
    var chunk = try builder.finish();
    errdefer chunk.deinit(testing.allocator);
    try realm.heap.pinChunk(&chunk);
    return chunk;
}

fn globalSlotLoadChunk(slot: u32) !chunk_mod.Chunk {
    var builder = Builder.init(testing.allocator);
    defer builder.deinit();
    try builder.emitOp(.lda_global_slot, span);
    try builder.emitU32(slot);
    try builder.emitOp(.return_, span);
    return builder.finish();
}

fn globalSlotStoreChunk(op: Op, slot: u32, value: i32) !chunk_mod.Chunk {
    var builder = Builder.init(testing.allocator);
    defer builder.deinit();
    try builder.emitLoadSmi(span, value);
    try builder.emitOp(op, span);
    try builder.emitU32(slot);
    try builder.emitOp(.lda_global_slot, span);
    try builder.emitU32(slot);
    try builder.emitOp(.return_, span);
    return builder.finish();
}

fn popEnvironmentChunk(allocation_slots: ?u8) !chunk_mod.Chunk {
    var builder = Builder.init(testing.allocator);
    defer builder.deinit();
    if (allocation_slots) |slot_count| {
        try builder.emitOp(.make_environment, span);
        try builder.emitU8(slot_count);
    }
    try builder.emitOp(.pop_env, span);
    try builder.emitOp(.return_, span);
    return builder.finish();
}

fn throwIfHoleChunk() !chunk_mod.Chunk {
    var builder = Builder.init(testing.allocator);
    defer builder.deinit();
    try builder.emitOp(.throw_if_hole, span);
    try builder.emitOp(.return_, span);
    return builder.finish();
}

const ThrowChunk = struct {
    chunk: chunk_mod.Chunk,
    throw_pc: u32,
};

fn throwChunk() !ThrowChunk {
    var builder = Builder.init(testing.allocator);
    defer builder.deinit();
    try builder.emitLoadSmi(span, 42);
    const throw_pc = builder.here();
    try builder.emitOp(.throw_, span);
    return .{
        .chunk = try builder.finish(),
        .throw_pc = @intCast(throw_pc),
    };
}

fn typeOfChunk() !chunk_mod.Chunk {
    var builder = Builder.init(testing.allocator);
    defer builder.deinit();
    try builder.emitOp(.typeof_, span);
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
    if (result_bits == codegen.safepoint_sentinel_bits) {
        return @intFromEnum(codegen.EntryResult.safe_point);
    }
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

fn resumeLanternResult(realm: *Realm, frame: lantern.CallFrame) !lantern.RunResult {
    var frames: std.ArrayListUnmanaged(lantern.CallFrame) = .empty;
    defer frames.deinit(testing.allocator);
    try frames.append(testing.allocator, frame);
    return lantern.runFrames(testing.allocator, realm, &frames);
}

fn resumeLantern(realm: *Realm, frame: lantern.CallFrame) !Value {
    return switch (try resumeLanternResult(realm, frame)) {
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

test "Ohaimark IR gives checked relational comparisons exact deopt state" {
    for ([_]Op{ .lt, .gt, .ge }) |op| {
        var comparison = try relationalComparisonChunk(op);
        defer comparison.chunk.deinit(testing.allocator);
        var native = try NativeGraph.build(&comparison.chunk);
        defer native.deinit();

        const less_than_id = try findNode(&native, .less_than);
        const less_than = native.graph.nodes[less_than_id];
        const frame_state = native.graph.frame_states[
            less_than.frame_state orelse return error.TestUnexpectedResult
        ];
        try testing.expectEqual(comparison.comparison_pc, less_than.bytecode_offset);
        try testing.expectEqual(less_than.bytecode_offset, frame_state.bytecode_offset);

        if (op == .ge) {
            const logical_not_id = try findNode(&native, .logical_not);
            try testing.expectEqualSlices(
                ir.ValueId,
                &.{less_than_id},
                native.graph.nodeInputs(logical_not_id),
            );
            try testing.expectEqual(
                specialize.Lowering.logical_not,
                native.specialization.node_info[logical_not_id].lowering,
            );
        }
    }
}

test "Ohaimark representation rejects checked comparison without deopt state cleanly" {
    var comparison = try relationalComparisonChunk(.lt);
    defer comparison.chunk.deinit(testing.allocator);
    var graph = try ir.Graph.build(testing.allocator, &comparison.chunk);
    defer graph.deinit();
    const less_than_id = findNodeInGraph(&graph, .less_than) orelse
        return error.TestUnexpectedResult;
    graph.nodes[less_than_id].frame_state = null;

    var specialization = try specialize.Plan.build(testing.allocator, &graph);
    defer specialization.deinit();
    try testing.expectError(
        error.InvalidRepresentation,
        representation.Plan.build(testing.allocator, &graph, &specialization),
    );
}

test "Ohaimark AArch64 executes checked relational comparisons for int32 operands" {
    if (comptime !masm.native_aarch64) return error.SkipZigTest;
    const cases = [_]struct {
        op: Op,
        lhs: i32,
        rhs: i32,
        expected: bool,
    }{
        .{ .op = .lt, .lhs = 7, .rhs = 8, .expected = true },
        .{ .op = .gt, .lhs = 9, .rhs = 8, .expected = true },
        .{ .op = .ge, .lhs = 7, .rhs = 8, .expected = false },
        .{ .op = .ge, .lhs = 8, .rhs = 8, .expected = true },
    };
    for (cases) |case| {
        var comparison = try relationalComparisonChunk(case.op);
        defer comparison.chunk.deinit(testing.allocator);
        var native = try NativeGraph.build(&comparison.chunk);
        defer native.deinit();
        var realm = Realm.init(testing.allocator);
        defer realm.deinit();
        realm.jit_enabled = false;
        const registers = try testing.allocator.alloc(Value, comparison.chunk.register_count);
        defer testing.allocator.free(registers);
        var frame = testFrame(&comparison.chunk, registers);
        frame.registers[comparison.lhs] = Value.fromInt32(case.lhs);
        frame.registers[comparison.rhs] = Value.fromInt32(case.rhs);

        try testing.expectEqual(
            @intFromEnum(codegen.EntryResult.done),
            try executeNative(&native, &realm, &frame),
        );
        try testing.expectEqual(Value.fromBool(case.expected).bits, frame.accumulator.bits);
    }
}

test "Ohaimark AArch64 relational comparisons deopt non-int32 operands at the exact opcode" {
    if (comptime !masm.native_aarch64) return error.SkipZigTest;
    for ([_]struct { op: Op, expected: bool }{
        .{ .op = .lt, .expected = true },
        .{ .op = .gt, .expected = false },
        .{ .op = .ge, .expected = false },
    }) |case| {
        var comparison = try relationalComparisonChunk(case.op);
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
        try testing.expectEqual(Value.fromBool(case.expected).bits, (try resumeLantern(&realm, frame)).bits);
    }
}

test "Ohaimark IR models every fused relational branch width with deopt state" {
    const ops = [_]Op{
        .jmp_if_not_lt8,
        .jmp_if_not_lt,
        .jmp_if_not_lt32,
        .jmp_if_not_le8,
        .jmp_if_not_le,
        .jmp_if_not_le32,
        .jmp_if_not_gt8,
        .jmp_if_not_gt,
        .jmp_if_not_gt32,
        .jmp_if_not_ge8,
        .jmp_if_not_ge,
        .jmp_if_not_ge32,
    };
    for (ops) |op| {
        var branch_chunk = try relationalBranchChunk(op);
        defer branch_chunk.chunk.deinit(testing.allocator);
        var graph = try ir.Graph.build(testing.allocator, &branch_chunk.chunk);
        defer graph.deinit();

        const less_than_id = findNodeInGraph(&graph, .less_than) orelse
            return error.TestUnexpectedResult;
        const less_than = graph.nodes[less_than_id];
        const frame_state = graph.frame_states[
            less_than.frame_state orelse return error.TestUnexpectedResult
        ];
        try testing.expectEqual(branch_chunk.branch_pc, less_than.bytecode_offset);
        try testing.expectEqual(less_than.bytecode_offset, frame_state.bytecode_offset);

        const branch_id = findNodeInGraph(&graph, .branch) orelse
            return error.TestUnexpectedResult;
        try testing.expectEqualSlices(
            ir.ValueId,
            &.{less_than_id},
            graph.nodeInputs(branch_id),
        );
        const expected_condition: ir.BranchCondition = switch (op.branchInfo().?.canonical) {
            .jmp_if_not_lt, .jmp_if_not_gt => .falsy,
            .jmp_if_not_le, .jmp_if_not_ge => .truthy,
            else => unreachable,
        };
        try testing.expectEqual(
            ir.Payload{ .branch = expected_condition },
            graph.nodes[branch_id].payload,
        );
    }
}

test "Ohaimark AArch64 executes every fused relational branch width" {
    if (comptime !masm.native_aarch64) return error.SkipZigTest;
    const ops = [_]Op{
        .jmp_if_not_lt8,
        .jmp_if_not_lt,
        .jmp_if_not_lt32,
        .jmp_if_not_le8,
        .jmp_if_not_le,
        .jmp_if_not_le32,
        .jmp_if_not_gt8,
        .jmp_if_not_gt,
        .jmp_if_not_gt32,
        .jmp_if_not_ge8,
        .jmp_if_not_ge,
        .jmp_if_not_ge32,
    };
    for (ops) |op| {
        for ([_]struct { lhs: i32, rhs: i32 }{
            .{ .lhs = 7, .rhs = 8 },
            .{ .lhs = 8, .rhs = 7 },
            .{ .lhs = 8, .rhs = 8 },
        }) |case| {
            var branch_chunk = try relationalBranchChunk(op);
            defer branch_chunk.chunk.deinit(testing.allocator);
            var native = try NativeGraph.build(&branch_chunk.chunk);
            defer native.deinit();
            var realm = Realm.init(testing.allocator);
            defer realm.deinit();
            realm.jit_enabled = false;
            const registers = try testing.allocator.alloc(Value, branch_chunk.chunk.register_count);
            defer testing.allocator.free(registers);
            var frame = testFrame(&branch_chunk.chunk, registers);
            frame.registers[branch_chunk.lhs] = Value.fromInt32(case.lhs);
            frame.registers[branch_chunk.rhs] = Value.fromInt32(case.rhs);

            try testing.expectEqual(
                @intFromEnum(codegen.EntryResult.done),
                try executeNative(&native, &realm, &frame),
            );
            try testing.expectEqual(
                Value.fromInt32(if (relationalBranchResult(op, case.lhs, case.rhs)) 11 else 22).bits,
                frame.accumulator.bits,
            );
        }
    }
}

test "Ohaimark AArch64 fused relational branches deopt non-int32 operands at the exact opcode" {
    if (comptime !masm.native_aarch64) return error.SkipZigTest;
    const cases = [_]struct { op: Op, expected: i32 }{
        .{ .op = .jmp_if_not_lt8, .expected = 11 },
        .{ .op = .jmp_if_not_le8, .expected = 11 },
        .{ .op = .jmp_if_not_gt8, .expected = 22 },
        .{ .op = .jmp_if_not_ge8, .expected = 22 },
    };
    for (cases) |case| {
        var branch_chunk = try relationalBranchChunk(case.op);
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

        try testing.expectEqual(
            @intFromEnum(codegen.EntryResult.resume_interp),
            try executeNative(&native, &realm, &frame),
        );
        try testing.expectEqual(branch_chunk.branch_pc, frame.ip);
        try testing.expectEqual(rhs.bits, frame.accumulator.bits);
        try testing.expectEqual(lhs.bits, frame.registers[branch_chunk.lhs].bits);
        try testing.expectEqual(rhs.bits, frame.registers[branch_chunk.rhs].bits);
        try testing.expectEqual(Value.fromInt32(case.expected).bits, (try resumeLantern(&realm, frame)).bits);
    }
}

test "Ohaimark IR gives fused dense array literals exact rooted frame state" {
    var literal = try denseArrayLiteralChunk(3);
    defer literal.chunk.deinit(testing.allocator);
    var graph = try ir.Graph.build(testing.allocator, &literal.chunk);
    defer graph.deinit();

    const node_id = findNodeInGraph(&graph, .create_dense_array_literal) orelse
        return error.TestUnexpectedResult;
    const node = graph.nodes[node_id];
    const frame_state = graph.frame_states[
        node.frame_state orelse
            return error.TestUnexpectedResult
    ];
    const site: ir.DenseArrayLiteral = switch (node.payload) {
        .dense_array_literal => |value| value,
        else => return error.TestUnexpectedResult,
    };
    try testing.expectEqual(literal.make_array_pc, node.bytecode_offset);
    try testing.expectEqual(node.bytecode_offset, frame_state.bytecode_offset);
    try testing.expectEqual(literal.base, site.base);
    try testing.expectEqual(literal.count, site.count);
    try testing.expectEqual(@as(u16, literal.count), frame_state.slot_count);
}

test "Ohaimark rejects malformed fused dense array literal operands" {
    var chunk = try malformedDenseArrayLiteralChunk();
    defer chunk.deinit(testing.allocator);
    try testing.expectError(error.MalformedBytecode, ir.Graph.build(testing.allocator, &chunk));
}

test "Ohaimark AArch64 allocates fused dense array literals through rooted frames" {
    if (comptime !masm.native_aarch64) return error.SkipZigTest;
    var literal = try denseArrayLiteralChunk(3);
    defer literal.chunk.deinit(testing.allocator);
    var native = try NativeGraph.build(&literal.chunk);
    defer native.deinit();

    var realm = Realm.init(testing.allocator);
    defer realm.deinit();
    realm.jit_enabled = false;
    realm.heap.setGcThreshold(1);
    const scope = try realm.heap.openScope();
    defer scope.close();
    const first = heap_mod.taggedObject(try realm.heap.allocateObject());
    const second = heap_mod.taggedObject(try realm.heap.allocateObject());
    try scope.push(first);
    try scope.push(second);

    const registers = try testing.allocator.alloc(Value, literal.chunk.register_count);
    defer testing.allocator.free(registers);
    var frames: std.ArrayListUnmanaged(lantern.CallFrame) = .empty;
    defer frames.deinit(testing.allocator);
    try frames.append(testing.allocator, testFrame(&literal.chunk, registers));
    try realm.frame_stacks.append(realm.allocator, &frames);
    defer _ = realm.frame_stacks.pop();
    const frame = &frames.items[0];
    frame.registers[literal.base] = first;
    frame.registers[literal.base + 1] = Value.fromInt32(7);
    frame.registers[literal.base + 2] = second;

    try testing.expectEqual(
        @intFromEnum(codegen.EntryResult.done),
        try executeNative(&native, &realm, frame),
    );
    try scope.push(frame.accumulator);
    const array = heap_mod.valueAsPlainObject(frame.accumulator) orelse
        return error.TestUnexpectedResult;
    try testing.expect(array.brand.is_array_exotic);
    const items = array.elementItems();
    try testing.expectEqual(@as(usize, literal.count), items.len);
    try testing.expectEqual(first.bits, items[0].bits);
    try testing.expectEqual(Value.fromInt32(7).bits, items[1].bits);
    try testing.expectEqual(second.bits, items[2].bits);

    realm.collectGarbage();
    const items_after_gc = array.elementItems();
    try testing.expectEqual(first.bits, items_after_gc[0].bits);
    try testing.expectEqual(second.bits, items_after_gc[2].bits);
}

test "Ohaimark IR admits un-fused dense array literal allocation and appends" {
    var literal = try unfusedDenseArrayLiteralChunk();
    defer literal.chunk.deinit(testing.allocator);
    var graph = try ir.Graph.build(testing.allocator, &literal.chunk);
    defer graph.deinit();

    const array_id = findNodeInGraph(&graph, .create_array_literal) orelse
        return error.TestUnexpectedResult;
    const array = graph.nodes[array_id];
    try testing.expectEqual(literal.make_array_pc, array.bytecode_offset);
    try testing.expect(array.frame_state != null);

    var appends: usize = 0;
    for (graph.nodes, 0..) |node, index| {
        if (node.kind != .append_dense_array_literal_element) continue;
        appends += 1;
        try testing.expect(node.frame_state != null);
        try testing.expectEqualSlices(
            ir.ValueId,
            &.{array_id},
            graph.nodeInputs(@intCast(index))[0..1],
        );
    }
    try testing.expectEqual(literal.element_registers.len, appends);
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
        @intFromEnum(codegen.EntryResult.safe_point),
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

test "Ohaimark AArch64 backedge safepoint preserves disabled fuel" {
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
    realm.step_budget = std.math.maxInt(u64);

    try testing.expectEqual(
        @intFromEnum(codegen.EntryResult.done),
        try executeNative(&native, &realm, &frame),
    );
    try testing.expectEqual(std.math.maxInt(u64), realm.step_budget);
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
        @intFromEnum(codegen.EntryResult.safe_point),
        try executeNative(&native, &realm, &frame),
    );
    try testing.expectEqual(budget, realm.step_budget);
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
        @intFromEnum(codegen.EntryResult.safe_point),
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
        @intFromEnum(codegen.EntryResult.safe_point),
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
    var mixed_graph = try ir.Graph.build(testing.allocator, &mixed);
    defer mixed_graph.deinit();
    try testing.expectEqual(@as(?u8, 0), mixed_graph.entry_environment_slots);
    try testing.expect(findNodeInGraph(&mixed_graph, .load_environment) != null);

    var real_builder = Builder.init(testing.allocator);
    defer real_builder.deinit();
    try real_builder.emitOp(.make_environment, span);
    try real_builder.emitU8(1);
    try real_builder.emitOp(.return_, span);
    var real = try real_builder.finish();
    defer real.deinit(testing.allocator);
    var real_graph = try ir.Graph.build(testing.allocator, &real);
    defer real_graph.deinit();
    try testing.expectEqual(@as(?u8, 1), real_graph.entry_environment_slots);

    var late_builder = Builder.init(testing.allocator);
    defer late_builder.deinit();
    try late_builder.emitOp(.lda_undefined, span);
    try late_builder.emitOp(.make_environment, span);
    try late_builder.emitU8(1);
    try late_builder.emitOp(.return_, span);
    var late = try late_builder.finish();
    defer late.deinit(testing.allocator);
    var late_graph = try ir.Graph.build(testing.allocator, &late);
    defer late_graph.deinit();
    try testing.expectEqual(@as(?u8, null), late_graph.entry_environment_slots);
    const allocation_node = findNodeInGraph(&late_graph, .allocate_environment) orelse
        return error.TestUnexpectedResult;
    try testing.expect(late_graph.nodes[allocation_node].frame_state != null);
    var late_native = try NativeGraph.build(&late);
    defer late_native.deinit();
}

test "Ohaimark AArch64 rooted entry environment allocation preserves frame roots" {
    if (comptime !masm.native_aarch64) return error.SkipZigTest;

    var builder = Builder.init(testing.allocator);
    defer builder.deinit();
    const root_register = try builder.reserveRegister();
    try builder.emitOp(.make_environment, span);
    try builder.emitU8(1);
    try builder.emitLoadReg(span, root_register);
    try builder.emitOp(.return_, span);
    var chunk = try builder.finish();
    defer chunk.deinit(testing.allocator);

    var native = try NativeGraph.build(&chunk);
    defer native.deinit();
    try testing.expectEqual(@as(?u8, 1), native.graph.entry_environment_slots);

    var emitted = masm.Masm.init(testing.allocator);
    defer emitted.deinit();
    try native.emit(&emitted, &chunk);
    try testing.expect(codeContainsWord(
        emitted.code.items,
        a64.stpPreIdxSp(.x0, .x1, -16),
    ));
    try testing.expect(codeContainsWord(
        emitted.code.items,
        a64.stpPreIdxSp(.x2, .x16, -16),
    ));
    try testing.expect(codeContainsWord(emitted.code.items, a64.strPreIdxSp(.lr, -16)));
    try testing.expect(codeContainsWord(emitted.code.items, a64.ldrPostIdxSp(.lr, 16)));
    try testing.expect(codeContainsWord(
        emitted.code.items,
        a64.ldpPostIdxSp(.x2, .x16, 16),
    ));
    try testing.expect(codeContainsWord(
        emitted.code.items,
        a64.ldpPostIdxSp(.x0, .x1, 16),
    ));

    var realm = Realm.init(testing.allocator);
    defer realm.deinit();
    realm.jit_enabled = false;
    realm.heap.setGcThreshold(1);
    const root = try realm.heap.allocateObject();
    _ = try realm.heap.allocateObject();
    try testing.expectEqual(@as(usize, 2), realm.heap.objectCount());
    const parent = try realm.heap.allocateEnvironment(null, 1);

    const registers = try testing.allocator.alloc(Value, chunk.register_count);
    defer testing.allocator.free(registers);
    var frames: std.ArrayListUnmanaged(lantern.CallFrame) = .empty;
    defer frames.deinit(testing.allocator);
    try frames.append(testing.allocator, testFrame(&chunk, registers));
    try realm.frame_stacks.append(realm.allocator, &frames);
    defer _ = realm.frame_stacks.pop();
    const frame = &frames.items[0];
    frame.env = parent;
    frame.registers[root_register] = heap_mod.taggedObject(root);

    try testing.expectEqual(
        @intFromEnum(codegen.EntryResult.done),
        try executeNative(&native, &realm, frame),
    );
    try testing.expectEqual(heap_mod.taggedObject(root).bits, frame.accumulator.bits);
    const env = frame.env orelse return error.TestUnexpectedResult;
    try testing.expect(env.parent == parent);
    try testing.expectEqual(@as(usize, 1), env.slots.len);
    try testing.expectEqual(Value.hole_.bits, env.slots[0].bits);

    realm.collectGarbage();
    try testing.expectEqual(@as(usize, 1), realm.heap.objectCount());
    try testing.expectEqual(@as(usize, 2), realm.heap.environmentCount());
    try testing.expectEqual(heap_mod.taggedObject(root).bits, frame.registers[root_register].bits);
    const live_env = frame.env orelse return error.TestUnexpectedResult;
    try testing.expect(live_env.parent == parent);
    try testing.expectEqual(@as(usize, 1), live_env.slots.len);
}

test "Ohaimark AArch64 rooted mid-body environment allocation preserves live values" {
    if (comptime !masm.native_aarch64) return error.SkipZigTest;

    var builder = Builder.init(testing.allocator);
    defer builder.deinit();
    const root_register = try builder.reserveRegister();
    try builder.emitLoadReg(span, root_register);
    try builder.emitOp(.make_environment, span);
    try builder.emitU8(1);
    try builder.emitLoadReg(span, root_register);
    try builder.emitOp(.return_, span);
    var chunk = try builder.finish();
    defer chunk.deinit(testing.allocator);

    var native = try NativeGraph.build(&chunk);
    defer native.deinit();
    try testing.expectEqual(@as(?u8, null), native.graph.entry_environment_slots);

    var emitted = masm.Masm.init(testing.allocator);
    defer emitted.deinit();
    try native.emit(&emitted, &chunk);
    try testing.expect(codeContainsWord(
        emitted.code.items,
        a64.stpPreIdxSp(.x0, .x1, -16),
    ));
    try testing.expect(codeContainsWord(
        emitted.code.items,
        a64.stpPreIdxSp(.x2, .x3, -16),
    ));
    try testing.expect(codeContainsWord(
        emitted.code.items,
        a64.stpPreIdxSp(.x4, .x5, -16),
    ));
    try testing.expect(codeContainsWord(
        emitted.code.items,
        a64.stpPreIdxSp(.x6, .x7, -16),
    ));
    try testing.expect(codeContainsWord(
        emitted.code.items,
        a64.stpPreIdxSp(.x8, .x16, -16),
    ));
    try testing.expect(codeContainsWord(emitted.code.items, a64.strPreIdxSp(.lr, -16)));
    try testing.expect(codeContainsWord(emitted.code.items, a64.ldrPostIdxSp(.lr, 16)));
    try testing.expect(codeContainsWord(
        emitted.code.items,
        a64.ldpPostIdxSp(.x8, .x16, 16),
    ));
    try testing.expect(codeContainsWord(
        emitted.code.items,
        a64.ldpPostIdxSp(.x6, .x7, 16),
    ));
    try testing.expect(codeContainsWord(
        emitted.code.items,
        a64.ldpPostIdxSp(.x4, .x5, 16),
    ));
    try testing.expect(codeContainsWord(
        emitted.code.items,
        a64.ldpPostIdxSp(.x2, .x3, 16),
    ));
    try testing.expect(codeContainsWord(
        emitted.code.items,
        a64.ldpPostIdxSp(.x0, .x1, 16),
    ));

    var realm = Realm.init(testing.allocator);
    defer realm.deinit();
    realm.jit_enabled = false;
    realm.heap.setGcThreshold(1);
    const root = try realm.heap.allocateObject();
    _ = try realm.heap.allocateObject();
    const parent = try realm.heap.allocateEnvironment(null, 1);

    const registers = try testing.allocator.alloc(Value, chunk.register_count);
    defer testing.allocator.free(registers);
    var frames: std.ArrayListUnmanaged(lantern.CallFrame) = .empty;
    defer frames.deinit(testing.allocator);
    try frames.append(testing.allocator, testFrame(&chunk, registers));
    try realm.frame_stacks.append(realm.allocator, &frames);
    defer _ = realm.frame_stacks.pop();
    const frame = &frames.items[0];
    frame.env = parent;
    frame.registers[root_register] = heap_mod.taggedObject(root);

    try testing.expectEqual(
        @intFromEnum(codegen.EntryResult.done),
        try executeNative(&native, &realm, frame),
    );
    try testing.expectEqual(heap_mod.taggedObject(root).bits, frame.accumulator.bits);
    const env = frame.env orelse return error.TestUnexpectedResult;
    try testing.expect(env.parent == parent);
    try testing.expectEqual(@as(usize, 1), env.slots.len);

    realm.collectGarbage();
    try testing.expectEqual(@as(usize, 1), realm.heap.objectCount());
    try testing.expectEqual(heap_mod.taggedObject(root).bits, frame.registers[root_register].bits);
}

test "Ohaimark AArch64 environment store preserves the accumulator and writes through the barrier" {
    if (comptime !masm.native_aarch64) return error.SkipZigTest;

    var builder = Builder.init(testing.allocator);
    defer builder.deinit();
    const root_register = try builder.reserveRegister();
    try builder.emitLoadReg(span, root_register);
    try builder.emitOp(.sta_env, span);
    try builder.emitU8(0);
    try builder.emitU8(0);
    try builder.emitOp(.lda_env, span);
    try builder.emitU8(0);
    try builder.emitU8(0);
    try builder.emitOp(.return_, span);
    var chunk = try builder.finish();
    defer chunk.deinit(testing.allocator);

    var native = try NativeGraph.build(&chunk);
    defer native.deinit();

    var realm = Realm.init(testing.allocator);
    defer realm.deinit();
    realm.jit_enabled = false;
    const root = try realm.heap.allocateObject();
    const environment = try realm.heap.allocateEnvironment(null, 1);
    const registers = try testing.allocator.alloc(Value, chunk.register_count);
    defer testing.allocator.free(registers);
    var frame = testFrame(&chunk, registers);
    frame.env = environment;
    frame.registers[root_register] = heap_mod.taggedObject(root);

    try testing.expectEqual(
        @intFromEnum(codegen.EntryResult.done),
        try executeNative(&native, &realm, &frame),
    );
    try testing.expectEqual(heap_mod.taggedObject(root).bits, frame.accumulator.bits);
    try testing.expectEqual(heap_mod.taggedObject(root).bits, environment.slots[0].bits);
}

test "Ohaimark AArch64 environment helper failure restores the pre-operation frame" {
    if (comptime !masm.native_aarch64) return error.SkipZigTest;

    var builder = Builder.init(testing.allocator);
    defer builder.deinit();
    const root_register = try builder.reserveRegister();
    try builder.emitLoadReg(span, root_register);
    try builder.emitOp(.sta_env, span);
    try builder.emitU8(0);
    try builder.emitU8(1);
    try builder.emitLoadReg(span, root_register);
    try builder.emitOp(.return_, span);
    var chunk = try builder.finish();
    defer chunk.deinit(testing.allocator);

    var native = try NativeGraph.build(&chunk);
    defer native.deinit();
    const store_node = try findNode(&native, .store_environment);

    var realm = Realm.init(testing.allocator);
    defer realm.deinit();
    realm.jit_enabled = false;
    const root = try realm.heap.allocateObject();
    const environment = try realm.heap.allocateEnvironment(null, 1);
    const registers = try testing.allocator.alloc(Value, chunk.register_count);
    defer testing.allocator.free(registers);
    var frame = testFrame(&chunk, registers);
    frame.env = environment;
    frame.registers[root_register] = heap_mod.taggedObject(root);

    try testing.expectEqual(
        @intFromEnum(codegen.EntryResult.resume_interp),
        try executeNative(&native, &realm, &frame),
    );
    try testing.expectEqual(native.graph.nodes[store_node].bytecode_offset, frame.ip);
    try testing.expectEqual(heap_mod.taggedObject(root).bits, frame.accumulator.bits);
    try testing.expectEqual(heap_mod.taggedObject(root).bits, frame.registers[root_register].bits);
    try testing.expect(frame.env == environment);
    try testing.expectEqual(Value.hole_.bits, environment.slots[0].bits);
}

test "Ohaimark AArch64 LdaArguments preserves incoming roots across allocation" {
    if (comptime !masm.native_aarch64) return error.SkipZigTest;

    var chunk = try argumentsChunk();
    defer chunk.deinit(testing.allocator);
    var native = try NativeGraph.build(&chunk);
    defer native.deinit();

    var realm = Realm.init(testing.allocator);
    defer realm.deinit();
    realm.jit_enabled = false;
    realm.heap.setGcThreshold(1);

    const first = try realm.heap.allocateObject();
    const second = try realm.heap.allocateObject();
    const registers = try testing.allocator.alloc(Value, chunk.register_count);
    defer testing.allocator.free(registers);
    var frames: std.ArrayListUnmanaged(lantern.CallFrame) = .empty;
    defer frames.deinit(testing.allocator);
    try frames.append(testing.allocator, testFrame(&chunk, registers));
    try realm.frame_stacks.append(realm.allocator, &frames);
    defer _ = realm.frame_stacks.pop();
    const frame = &frames.items[0];
    frame.argc = 2;
    frame.registers[0] = heap_mod.taggedObject(first);
    frame.registers[1] = heap_mod.taggedObject(second);

    try testing.expectEqual(
        @intFromEnum(codegen.EntryResult.done),
        try executeNative(&native, &realm, frame),
    );
    const arguments = heap_mod.valueAsPlainObject(frame.accumulator) orelse
        return error.TestUnexpectedResult;
    try testing.expect(arguments.brand.is_arguments_exotic);
    try testing.expectEqual(heap_mod.taggedObject(first).bits, arguments.lookupOwn("0").?.bits);
    try testing.expectEqual(heap_mod.taggedObject(second).bits, arguments.lookupOwn("1").?.bits);
    try testing.expectEqual(Value.fromInt32(2).bits, arguments.lookupOwn("length").?.bits);

    realm.collectGarbage();
    try testing.expectEqual(heap_mod.taggedObject(first).bits, arguments.lookupOwn("0").?.bits);
    try testing.expectEqual(heap_mod.taggedObject(second).bits, arguments.lookupOwn("1").?.bits);
}

test "Ohaimark AArch64 static object literals survive allocation pressure" {
    if (comptime !masm.native_aarch64) return error.SkipZigTest;

    var realm = Realm.init(testing.allocator);
    defer realm.deinit();
    realm.hardened = false;
    try realm.installBuiltins();
    realm.jit_enabled = false;
    realm.heap.setGcThreshold(1);

    {
        var chunk = try plainObjectChunk();
        defer chunk.deinit(testing.allocator);
        var native = try NativeGraph.build(&chunk);
        defer native.deinit();
        const registers = try testing.allocator.alloc(Value, chunk.register_count);
        defer testing.allocator.free(registers);
        var frames: std.ArrayListUnmanaged(lantern.CallFrame) = .empty;
        defer frames.deinit(testing.allocator);
        try frames.append(testing.allocator, testFrame(&chunk, registers));
        try realm.frame_stacks.append(realm.allocator, &frames);
        defer _ = realm.frame_stacks.pop();
        const frame = &frames.items[0];

        try testing.expectEqual(
            @intFromEnum(codegen.EntryResult.done),
            try executeNative(&native, &realm, frame),
        );
        const object = heap_mod.valueAsPlainObject(frame.accumulator) orelse
            return error.TestUnexpectedResult;
        try testing.expect(object.prototype == realm.intrinsics.object_prototype);
        realm.collectGarbage();
        try testing.expect(heap_mod.valueAsPlainObject(frame.accumulator) == object);
    }

    {
        var chunk = try shapedObjectChunk(&realm);
        defer chunk.deinit(testing.allocator);
        var native = try NativeGraph.build(&chunk);
        defer native.deinit();
        const registers = try testing.allocator.alloc(Value, chunk.register_count);
        defer testing.allocator.free(registers);
        var frames: std.ArrayListUnmanaged(lantern.CallFrame) = .empty;
        defer frames.deinit(testing.allocator);
        try frames.append(testing.allocator, testFrame(&chunk, registers));
        try realm.frame_stacks.append(realm.allocator, &frames);
        defer _ = realm.frame_stacks.pop();
        const frame = &frames.items[0];

        try testing.expectEqual(
            @intFromEnum(codegen.EntryResult.done),
            try executeNative(&native, &realm, frame),
        );
        const object = heap_mod.valueAsPlainObject(frame.accumulator) orelse
            return error.TestUnexpectedResult;
        try testing.expect(object.prototype == realm.intrinsics.object_prototype);
        try testing.expect(object.shape != null);
        try testing.expectEqual(@as(usize, 1), object.slotCount());
        try testing.expectEqual(Value.fromInt32(42).bits, object.get("answer").bits);
        realm.collectGarbage();
        try testing.expectEqual(Value.fromInt32(42).bits, object.get("answer").bits);
    }
}

test "Ohaimark AArch64 ordinary functions retain captured environments" {
    if (comptime !masm.native_aarch64) return error.SkipZigTest;

    var realm = Realm.init(testing.allocator);
    defer realm.deinit();
    realm.hardened = false;
    try realm.installBuiltins();
    realm.jit_enabled = false;
    realm.heap.setGcThreshold(1);

    var chunk = try ordinaryFunctionChunk();
    defer chunk.deinit(testing.allocator);
    try realm.heap.pinChunk(&chunk);
    var native = try NativeGraph.build(&chunk);
    defer native.deinit();
    const registers = try testing.allocator.alloc(Value, chunk.register_count);
    defer testing.allocator.free(registers);
    var frames: std.ArrayListUnmanaged(lantern.CallFrame) = .empty;
    defer frames.deinit(testing.allocator);
    try frames.append(testing.allocator, testFrame(&chunk, registers));
    try realm.frame_stacks.append(realm.allocator, &frames);
    defer _ = realm.frame_stacks.pop();
    const frame = &frames.items[0];
    const environment = try realm.heap.allocateEnvironment(null, 1);
    const captured = heap_mod.taggedObject(try realm.heap.allocateObject());
    realm.heap.storeEnvSlot(environment, 0, captured);
    frame.env = environment;

    try testing.expectEqual(
        @intFromEnum(codegen.EntryResult.done),
        try executeNative(&native, &realm, frame),
    );
    const function = heap_mod.valueAsFunction(frame.accumulator) orelse
        return error.TestUnexpectedResult;
    try testing.expect(function.captured_env == environment);
    try testing.expect(function.proto == realm.intrinsics.function_prototype);
    const prototype = function.prototype orelse return error.TestUnexpectedResult;
    try testing.expect(prototype.prototype == realm.intrinsics.object_prototype);
    try testing.expectEqual(frame.accumulator.bits, prototype.get("constructor").bits);
    try testing.expectEqual(Value.fromInt32(1).bits, function.get("length").bits);

    // The function in the rooted accumulator must keep both its environment
    // and the environment's referent alive after the creator drops its env.
    frame.env = null;
    realm.collectGarbage();
    const after_gc = heap_mod.valueAsFunction(frame.accumulator) orelse
        return error.TestUnexpectedResult;
    const result = switch (try lantern.callJSFunction(
        testing.allocator,
        &realm,
        after_gc,
        Value.undefined_,
        &.{},
    )) {
        .value, .yielded => |value| value,
        .thrown => return error.TestUnexpectedResult,
    };
    try testing.expectEqual(captured.bits, result.bits);
}

test "Ohaimark AArch64 entry zero environment preserves lexical depth" {
    if (comptime !masm.native_aarch64) return error.SkipZigTest;

    var builder = Builder.init(testing.allocator);
    defer builder.deinit();
    try builder.emitOp(.make_environment, span);
    try builder.emitU8(0);
    try builder.emitOp(.lda_env, span);
    try builder.emitU8(1);
    try builder.emitU8(0);
    try builder.emitOp(.return_, span);
    var chunk = try builder.finish();
    defer chunk.deinit(testing.allocator);

    var native = try NativeGraph.build(&chunk);
    defer native.deinit();
    try testing.expectEqual(@as(?u8, 0), native.graph.entry_environment_slots);

    var realm = Realm.init(testing.allocator);
    defer realm.deinit();
    realm.jit_enabled = false;
    const parent = try realm.heap.allocateEnvironment(null, 1);
    parent.slots[0] = Value.fromInt32(73);
    const registers = try testing.allocator.alloc(Value, chunk.register_count);
    defer testing.allocator.free(registers);
    var frame = testFrame(&chunk, registers);
    frame.env = parent;

    try testing.expectEqual(
        @intFromEnum(codegen.EntryResult.done),
        try executeNative(&native, &realm, &frame),
    );
    try testing.expectEqual(Value.fromInt32(73).bits, frame.accumulator.bits);
    const child = frame.env orelse return error.TestUnexpectedResult;
    try testing.expect(child.parent == parent);
    try testing.expectEqual(@as(usize, 0), child.slots.len);
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

test "Ohaimark AArch64 global own-data stores select the running realm and replay generic cases" {
    if (comptime !masm.native_aarch64) return error.SkipZigTest;

    var realm = Realm.init(testing.allocator);
    defer realm.deinit();
    realm.hardened = false;
    try realm.installBuiltins();
    realm.jit_enabled = false;
    try realm.globals.put(realm.allocator, "ohaimarkGlobal", Value.fromInt32(1));

    var chunk = try globalStoreChunk(&realm);
    defer chunk.deinit(testing.allocator);
    var native = try NativeGraph.build(&chunk);
    defer native.deinit();
    const node_id = try findNode(&native, .store_global);
    try testing.expectEqual(
        specialize.Lowering.store_global,
        native.specialization.node_info[node_id].lowering,
    );

    const registers = try testing.allocator.alloc(Value, chunk.register_count);
    defer testing.allocator.free(registers);
    var frame = testFrame(&chunk, registers);
    frame.accumulator = Value.fromInt32(42);
    try testing.expectEqual(
        @intFromEnum(codegen.EntryResult.done),
        try executeNative(&native, &realm, &frame),
    );
    try testing.expectEqual(Value.fromInt32(42).bits, frame.accumulator.bits);
    try testing.expectEqual(Value.fromInt32(42).bits, realm.globals.get("ohaimarkGlobal").?.bits);

    // The target is the executing function's home realm, not the dispatch
    // realm passed to the native entry.
    var other_realm = Realm.init(testing.allocator);
    defer other_realm.deinit();
    other_realm.hardened = false;
    try other_realm.installBuiltins();
    other_realm.jit_enabled = false;
    try other_realm.globals.put(other_realm.allocator, "ohaimarkGlobal", Value.fromInt32(2));
    frame = testFrame(&chunk, registers);
    frame.accumulator = Value.fromInt32(66);
    frame.running_realm = &other_realm;
    try testing.expectEqual(
        @intFromEnum(codegen.EntryResult.done),
        try executeNative(&native, &realm, &frame),
    );
    try testing.expectEqual(Value.fromInt32(42).bits, realm.globals.get("ohaimarkGlobal").?.bits);
    try testing.expectEqual(Value.fromInt32(66).bits, other_realm.globals.get("ohaimarkGlobal").?.bits);

    // A global lexical declaration changes resolution; tier down before the
    // helper writes so Lantern preserves the declarative-record semantics.
    var lexical_realm = Realm.init(testing.allocator);
    defer lexical_realm.deinit();
    lexical_realm.hardened = false;
    try lexical_realm.installBuiltins();
    lexical_realm.jit_enabled = false;
    try lexical_realm.globals.installScriptLexBinding(lexical_realm.allocator, "ohaimarkGlobal", false);
    try lexical_realm.globals.putDecl(lexical_realm.allocator, "ohaimarkGlobal", Value.fromInt32(9));
    frame = testFrame(&chunk, registers);
    frame.accumulator = Value.fromInt32(77);
    frame.running_realm = &lexical_realm;
    try testing.expectEqual(
        @intFromEnum(codegen.EntryResult.resume_interp),
        try executeNative(&native, &realm, &frame),
    );
    try testing.expectEqual(native.graph.nodes[node_id].bytecode_offset, frame.ip);
    try testing.expectEqual(Value.fromInt32(9).bits, lexical_realm.globals.get("ohaimarkGlobal").?.bits);
    try testing.expectEqual(Value.fromInt32(77).bits, (try resumeLantern(&realm, frame)).bits);
    try testing.expectEqual(Value.fromInt32(77).bits, lexical_realm.globals.get("ohaimarkGlobal").?.bits);

    // A non-writable object-record binding must likewise replay Lantern so
    // the canonical strict-mode TypeError is raised without a partial write.
    var frozen_realm = Realm.init(testing.allocator);
    defer frozen_realm.deinit();
    frozen_realm.hardened = false;
    try frozen_realm.installBuiltins();
    frozen_realm.jit_enabled = false;
    const frozen_target = frozen_realm.globals.target orelse return error.TestUnexpectedResult;
    try frozen_target.setWithFlags(frozen_realm.allocator, "ohaimarkGlobal", Value.fromInt32(3), .{
        .writable = false,
        .enumerable = false,
        .configurable = true,
    });
    frame = testFrame(&chunk, registers);
    frame.accumulator = Value.fromInt32(88);
    frame.running_realm = &frozen_realm;
    try testing.expectEqual(
        @intFromEnum(codegen.EntryResult.resume_interp),
        try executeNative(&native, &realm, &frame),
    );
    try testing.expectEqual(native.graph.nodes[node_id].bytecode_offset, frame.ip);
    try testing.expectEqual(Value.fromInt32(3).bits, frozen_realm.globals.get("ohaimarkGlobal").?.bits);
    switch (try resumeLanternResult(&realm, frame)) {
        .thrown => {},
        else => return error.TestUnexpectedResult,
    }
    try testing.expectEqual(Value.fromInt32(3).bits, frozen_realm.globals.get("ohaimarkGlobal").?.bits);

    // Shape-slot stores use the same remembered-set barrier as the Lantern
    // property path. After the temporary handle closes, the global remains
    // the only root for the young object.
    realm.collectGarbage();
    const young = blk: {
        const scope = try realm.heap.openScope();
        defer scope.close();
        const value = heap_mod.taggedObject(try realm.heap.allocateObject());
        try scope.push(value);
        frame = testFrame(&chunk, registers);
        frame.accumulator = value;
        try testing.expectEqual(
            @intFromEnum(codegen.EntryResult.done),
            try executeNative(&native, &realm, &frame),
        );
        break :blk value;
    };
    realm.collectGarbage();
    try testing.expectEqual(young.bits, realm.globals.get("ohaimarkGlobal").?.bits);
    try testing.expect(heap_mod.valueAsPlainObject(young) != null);
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

test "Ohaimark AArch64 global lexical slot stores preserve bindings and replay failures" {
    if (comptime !masm.native_aarch64) return error.SkipZigTest;

    var init_chunk = try globalSlotStoreChunk(.sta_global_slot_init, 0, 42);
    defer init_chunk.deinit(testing.allocator);
    var init_native = try NativeGraph.build(&init_chunk);
    defer init_native.deinit();
    const init_node = try findNode(&init_native, .store_global_slot_init);

    var init_realm = Realm.init(testing.allocator);
    defer init_realm.deinit();
    init_realm.jit_enabled = false;
    try init_realm.globals.installScriptLexBinding(init_realm.allocator, "slot", false);
    const init_registers = try testing.allocator.alloc(Value, init_chunk.register_count);
    defer testing.allocator.free(init_registers);
    var init_frame = testFrame(&init_chunk, init_registers);
    try testing.expectEqual(
        @intFromEnum(codegen.EntryResult.done),
        try executeNative(&init_native, &init_realm, &init_frame),
    );
    try testing.expectEqual(Value.fromInt32(42).bits, init_frame.accumulator.bits);
    try testing.expectEqual(Value.fromInt32(42).bits, init_realm.globals.decl_slots[0].bits);

    var missing_realm = Realm.init(testing.allocator);
    defer missing_realm.deinit();
    init_frame = testFrame(&init_chunk, init_registers);
    init_frame.running_realm = &missing_realm;
    try testing.expectEqual(
        @intFromEnum(codegen.EntryResult.resume_interp),
        try executeNative(&init_native, &init_realm, &init_frame),
    );
    try testing.expectEqual(init_native.graph.nodes[init_node].bytecode_offset, init_frame.ip);
    try testing.expectEqual(Value.fromInt32(42).bits, init_frame.accumulator.bits);

    var store_chunk = try globalSlotStoreChunk(.sta_global_slot, 0, 77);
    defer store_chunk.deinit(testing.allocator);
    var store_native = try NativeGraph.build(&store_chunk);
    defer store_native.deinit();
    const store_node = try findNode(&store_native, .store_global_slot);

    var store_realm = Realm.init(testing.allocator);
    defer store_realm.deinit();
    store_realm.jit_enabled = false;
    try store_realm.globals.installScriptLexBinding(store_realm.allocator, "slot", false);
    try store_realm.globals.putDecl(store_realm.allocator, "slot", Value.fromInt32(9));
    const store_registers = try testing.allocator.alloc(Value, store_chunk.register_count);
    defer testing.allocator.free(store_registers);
    var store_frame = testFrame(&store_chunk, store_registers);
    try testing.expectEqual(
        @intFromEnum(codegen.EntryResult.done),
        try executeNative(&store_native, &store_realm, &store_frame),
    );
    try testing.expectEqual(Value.fromInt32(77).bits, store_frame.accumulator.bits);
    try testing.expectEqual(Value.fromInt32(77).bits, store_realm.globals.decl_slots[0].bits);

    var const_realm = Realm.init(testing.allocator);
    defer const_realm.deinit();
    const_realm.jit_enabled = false;
    try const_realm.globals.installScriptLexBinding(const_realm.allocator, "slot", true);
    try const_realm.globals.putDecl(const_realm.allocator, "slot", Value.fromInt32(9));
    store_frame = testFrame(&store_chunk, store_registers);
    store_frame.running_realm = &const_realm;
    try testing.expectEqual(
        @intFromEnum(codegen.EntryResult.resume_interp),
        try executeNative(&store_native, &store_realm, &store_frame),
    );
    try testing.expectEqual(store_native.graph.nodes[store_node].bytecode_offset, store_frame.ip);
    try testing.expectEqual(Value.fromInt32(77).bits, store_frame.accumulator.bits);
    try testing.expectEqual(Value.fromInt32(9).bits, const_realm.globals.decl_slots[0].bits);
    switch (try resumeLanternResult(&store_realm, store_frame)) {
        .thrown => {},
        else => return error.TestUnexpectedResult,
    }
}

test "Ohaimark AArch64 pops allocated environments and elides paired empty scopes" {
    if (comptime !masm.native_aarch64) return error.SkipZigTest;

    var allocated_chunk = try popEnvironmentChunk(1);
    defer allocated_chunk.deinit(testing.allocator);
    var allocated_native = try NativeGraph.build(&allocated_chunk);
    defer allocated_native.deinit();
    try testing.expect(findNodeInGraph(&allocated_native.graph, .pop_environment) != null);

    var realm = Realm.init(testing.allocator);
    defer realm.deinit();
    realm.jit_enabled = false;
    const outer = try realm.heap.allocateEnvironment(null, 1);
    const allocated_registers = try testing.allocator.alloc(Value, allocated_chunk.register_count);
    defer testing.allocator.free(allocated_registers);
    var allocated_frame = testFrame(&allocated_chunk, allocated_registers);
    allocated_frame.env = outer;
    try testing.expectEqual(
        @intFromEnum(codegen.EntryResult.done),
        try executeNative(&allocated_native, &realm, &allocated_frame),
    );
    try testing.expect(allocated_frame.env == outer);

    var empty_chunk = try popEnvironmentChunk(0);
    defer empty_chunk.deinit(testing.allocator);
    var empty_native = try NativeGraph.build(&empty_chunk);
    defer empty_native.deinit();
    try testing.expect(findNodeInGraph(&empty_native.graph, .pop_environment) == null);

    const empty_registers = try testing.allocator.alloc(Value, empty_chunk.register_count);
    defer testing.allocator.free(empty_registers);
    var empty_frame = testFrame(&empty_chunk, empty_registers);
    empty_frame.env = outer;
    try testing.expectEqual(
        @intFromEnum(codegen.EntryResult.done),
        try executeNative(&empty_native, &realm, &empty_frame),
    );
    try testing.expect(empty_frame.env == outer);
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

test "Ohaimark AArch64 own named store guards live IC state and preserves barriers" {
    if (comptime !masm.native_aarch64) return error.SkipZigTest;
    var realm = Realm.init(testing.allocator);
    defer realm.deinit();
    realm.hardened = false;
    try realm.installBuiltins();
    realm.jit_enabled = false;

    var chunk = try namedStoreChunk(&realm);
    defer chunk.deinit(testing.allocator);
    const receiver = try realm.heap.allocateObject();
    const receiver_value = heap_mod.taggedObject(receiver);
    const receiver_scope = try realm.heap.openScope();
    defer receiver_scope.close();
    try receiver_scope.push(receiver_value);
    try realm.heap.storeProperty(receiver, realm.allocator, "x", Value.fromInt32(1));
    const receiver_shape = receiver.shape orelse return error.TestUnexpectedResult;
    const slot = (receiver_shape.lookup("x") orelse return error.TestUnexpectedResult).slot;
    chunk.inline_store_caches[0] = .{ .shape = receiver_shape, .slot = slot };

    var native = try NativeGraph.build(&chunk);
    defer native.deinit();
    const store_id = try findNode(&native, .store_named);
    try testing.expectEqual(
        specialize.Lowering.store_named_own,
        native.specialization.node_info[store_id].lowering,
    );

    const registers = try testing.allocator.alloc(Value, chunk.register_count);
    defer testing.allocator.free(registers);
    var frame = testFrame(&chunk, registers);
    frame.registers[0] = receiver_value;
    frame.accumulator = Value.fromInt32(42);

    var machine = masm.Masm.init(testing.allocator);
    defer machine.deinit();
    var executable = try code_alloc.CodeAllocator.init(testing.allocator, 64 * 1024);
    defer executable.deinit();
    const entry = try installNative(&native, &frame, &machine, &executable);

    try testing.expectEqual(
        @intFromEnum(codegen.EntryResult.done),
        executeEntry(entry, &realm, &frame),
    );
    try testing.expectEqual(Value.fromInt32(42).bits, receiver.slotAt(slot).bits);
    try testing.expectEqual(Value.fromInt32(42).bits, frame.accumulator.bits);

    // The receiver is mature after this collection. Once the temporary value
    // handle closes, the property slot is its only root, so this proves the
    // generated write invokes the remembered-set barrier.
    realm.collectGarbage();
    const young = blk: {
        const scope = try realm.heap.openScope();
        defer scope.close();
        const value = heap_mod.taggedObject(try realm.heap.allocateObject());
        try scope.push(value);
        frame = testFrame(&chunk, registers);
        frame.registers[0] = receiver_value;
        frame.accumulator = value;
        try testing.expectEqual(
            @intFromEnum(codegen.EntryResult.done),
            executeEntry(entry, &realm, &frame),
        );
        break :blk value;
    };
    realm.collectGarbage();
    try testing.expectEqual(young.bits, receiver.slotAt(slot).bits);
    try testing.expect(heap_mod.valueAsPlainObject(young) != null);

    // A cell refill or invalidation after compilation must force the original
    // bytecode, rather than writing the stale snapshot's slot.
    chunk.inline_store_caches[0] = .{};
    frame = testFrame(&chunk, registers);
    frame.registers[0] = receiver_value;
    frame.accumulator = Value.fromInt32(88);
    try testing.expectEqual(
        @intFromEnum(codegen.EntryResult.resume_interp),
        executeEntry(entry, &realm, &frame),
    );
    try testing.expectEqual(native.graph.nodes[store_id].bytecode_offset, frame.ip);
    try testing.expectEqual(young.bits, receiver.slotAt(slot).bits);
    try testing.expectEqual(Value.fromInt32(88).bits, (try resumeLantern(&realm, frame)).bits);
    try testing.expectEqual(Value.fromInt32(88).bits, receiver.slotAt(slot).bits);

    // Descriptor changes invalidate the receiver shape. Lantern owns the
    // strict-mode TypeError and must observe no partial native write.
    chunk.inline_store_caches[0] = .{ .shape = receiver_shape, .slot = slot };
    try receiver.setWithFlags(realm.allocator, "x", Value.fromInt32(88), .{
        .writable = false,
        .enumerable = true,
        .configurable = true,
    });
    frame = testFrame(&chunk, registers);
    frame.registers[0] = receiver_value;
    frame.accumulator = Value.fromInt32(99);
    try testing.expectEqual(
        @intFromEnum(codegen.EntryResult.resume_interp),
        executeEntry(entry, &realm, &frame),
    );
    try testing.expectEqual(native.graph.nodes[store_id].bytecode_offset, frame.ip);
    try testing.expectEqual(Value.fromInt32(88).bits, receiver.slotAt(slot).bits);
    switch (try resumeLanternResult(&realm, frame)) {
        .thrown => {},
        else => return error.TestUnexpectedResult,
    }
    try testing.expectEqual(Value.fromInt32(88).bits, receiver.slotAt(slot).bits);
}

test "Ohaimark AArch64 computed own load guards key and live IC state" {
    if (comptime !masm.native_aarch64) return error.SkipZigTest;
    var realm = Realm.init(testing.allocator);
    defer realm.deinit();
    realm.jit_enabled = false;

    var chunk = try computedLoadChunk();
    defer chunk.deinit(testing.allocator);
    const receiver = try realm.heap.allocateObject();
    try realm.heap.storeProperty(receiver, realm.allocator, "x", Value.fromInt32(42));
    try realm.heap.storeProperty(receiver, realm.allocator, "y", Value.fromInt32(99));
    const receiver_shape = receiver.shape orelse return error.TestUnexpectedResult;
    const x_slot = (receiver_shape.lookup("x") orelse return error.TestUnexpectedResult).slot;
    const y_slot = (receiver_shape.lookup("y") orelse return error.TestUnexpectedResult).slot;
    const cell = &chunk.inline_computed_caches[0];
    cell.shape = receiver_shape;
    cell.slot = x_slot;
    cell.cached_key_len = 1;
    cell.cached_key_buf[0] = 'x';

    var native = try NativeGraph.build(&chunk);
    defer native.deinit();
    const load_id = try findNode(&native, .load_computed);
    try testing.expectEqual(
        specialize.Lowering.load_computed_own,
        native.specialization.node_info[load_id].lowering,
    );
    const registers = try testing.allocator.alloc(Value, chunk.register_count);
    defer testing.allocator.free(registers);
    const key_x = Value.fromString(try realm.heap.allocateString("x"));
    const key_y = Value.fromString(try realm.heap.allocateString("y"));
    var frame = testFrame(&chunk, registers);
    frame.registers[0] = heap_mod.taggedObject(receiver);
    frame.accumulator = key_x;

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

    // A dynamic key mismatch must resume before ToPropertyKey or the object
    // lookup. Lantern then fills this site for "y" on the same receiver shape.
    frame = testFrame(&chunk, registers);
    frame.registers[0] = heap_mod.taggedObject(receiver);
    frame.accumulator = key_y;
    try testing.expectEqual(
        @intFromEnum(codegen.EntryResult.resume_interp),
        executeEntry(entry, &realm, &frame),
    );
    try testing.expectEqual(native.graph.nodes[load_id].bytecode_offset, frame.ip);
    try testing.expectEqual(key_y.bits, frame.accumulator.bits);
    try testing.expectEqual(Value.fromInt32(99).bits, (try resumeLantern(&realm, frame)).bits);
    try testing.expectEqual(receiver_shape, cell.shape);
    try testing.expectEqual(y_slot, cell.slot);
    try testing.expectEqual(@as(u8, 1), cell.cached_key_len);
    try testing.expectEqual(@as(u8, 'y'), cell.cached_key_buf[0]);

    // The code was compiled for the immutable x snapshot. A post-compile IC
    // refill for y must not reuse x's slot merely because the shape still fits.
    frame = testFrame(&chunk, registers);
    frame.registers[0] = heap_mod.taggedObject(receiver);
    frame.accumulator = key_y;
    try testing.expectEqual(
        @intFromEnum(codegen.EntryResult.resume_interp),
        executeEntry(entry, &realm, &frame),
    );
    try testing.expectEqual(key_y.bits, frame.accumulator.bits);
    try testing.expectEqual(Value.fromInt32(99).bits, (try resumeLantern(&realm, frame)).bits);
}

test "Ohaimark AArch64 computed own store guards value and live IC state" {
    if (comptime !masm.native_aarch64) return error.SkipZigTest;
    var realm = Realm.init(testing.allocator);
    defer realm.deinit();
    realm.jit_enabled = false;

    var chunk = try computedStoreChunk();
    defer chunk.deinit(testing.allocator);
    const receiver = try realm.heap.allocateObject();
    try realm.heap.storeProperty(receiver, realm.allocator, "x", Value.fromInt32(1));
    try realm.heap.storeProperty(receiver, realm.allocator, "y", Value.fromInt32(2));
    const receiver_shape = receiver.shape orelse return error.TestUnexpectedResult;
    const x_slot = (receiver_shape.lookup("x") orelse return error.TestUnexpectedResult).slot;
    const y_slot = (receiver_shape.lookup("y") orelse return error.TestUnexpectedResult).slot;
    const cell = &chunk.inline_computed_caches[0];
    cell.shape = receiver_shape;
    cell.slot = x_slot;
    cell.cached_key_len = 1;
    cell.cached_key_buf[0] = 'x';

    var native = try NativeGraph.build(&chunk);
    defer native.deinit();
    const store_id = try findNode(&native, .store_computed);
    try testing.expectEqual(
        specialize.Lowering.store_computed_own,
        native.specialization.node_info[store_id].lowering,
    );
    const registers = try testing.allocator.alloc(Value, chunk.register_count);
    defer testing.allocator.free(registers);
    const key_x = Value.fromString(try realm.heap.allocateString("x"));
    const key_y = Value.fromString(try realm.heap.allocateString("y"));
    var frame = testFrame(&chunk, registers);
    frame.registers[0] = heap_mod.taggedObject(receiver);
    frame.registers[1] = key_x;
    frame.registers[2] = Value.fromInt32(42);

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
    try testing.expectEqual(Value.fromInt32(42).bits, receiver.slotAt(x_slot).bits);

    // A dynamic key mismatch must replay before the slot write. Lantern owns
    // the y assignment and refills the same-shape computed IC for that key.
    frame = testFrame(&chunk, registers);
    frame.registers[0] = heap_mod.taggedObject(receiver);
    frame.registers[1] = key_y;
    frame.registers[2] = Value.fromInt32(99);
    try testing.expectEqual(
        @intFromEnum(codegen.EntryResult.resume_interp),
        executeEntry(entry, &realm, &frame),
    );
    try testing.expectEqual(native.graph.nodes[store_id].bytecode_offset, frame.ip);
    try testing.expectEqual(Value.fromInt32(99).bits, frame.accumulator.bits);
    try testing.expectEqual(Value.fromInt32(99).bits, (try resumeLantern(&realm, frame)).bits);
    try testing.expectEqual(Value.fromInt32(42).bits, receiver.slotAt(x_slot).bits);
    try testing.expectEqual(Value.fromInt32(99).bits, receiver.slotAt(y_slot).bits);
    try testing.expectEqual(receiver_shape, cell.shape);
    try testing.expectEqual(y_slot, cell.slot);
    try testing.expectEqual(@as(u8, 1), cell.cached_key_len);
    try testing.expectEqual(@as(u8, 'y'), cell.cached_key_buf[0]);

    // The immutable native snapshot is still x. A post-compile refill for y
    // must replay again rather than write x through a stale same-shape cell.
    frame = testFrame(&chunk, registers);
    frame.registers[0] = heap_mod.taggedObject(receiver);
    frame.registers[1] = key_y;
    frame.registers[2] = Value.fromInt32(100);
    try testing.expectEqual(
        @intFromEnum(codegen.EntryResult.resume_interp),
        executeEntry(entry, &realm, &frame),
    );
    try testing.expectEqual(Value.fromInt32(100).bits, frame.accumulator.bits);
    try testing.expectEqual(Value.fromInt32(100).bits, (try resumeLantern(&realm, frame)).bits);
    try testing.expectEqual(Value.fromInt32(42).bits, receiver.slotAt(x_slot).bits);
    try testing.expectEqual(Value.fromInt32(100).bits, receiver.slotAt(y_slot).bits);
}

test "Ohaimark AArch64 computed own store writes an overflow slot" {
    if (comptime !masm.native_aarch64) return error.SkipZigTest;
    var realm = Realm.init(testing.allocator);
    defer realm.deinit();
    realm.jit_enabled = false;

    var chunk = try computedStoreChunk();
    defer chunk.deinit(testing.allocator);
    const receiver = try realm.heap.allocateObject();
    for ([_][]const u8{ "a", "b", "c", "d", "e" }, 0..) |key, index| {
        try realm.heap.storeProperty(receiver, realm.allocator, key, Value.fromInt32(@intCast(index)));
    }
    const receiver_shape = receiver.shape orelse return error.TestUnexpectedResult;
    const slot = (receiver_shape.lookup("e") orelse return error.TestUnexpectedResult).slot;
    try testing.expect(slot >= object_mod.inline_slot_cap);
    const cell = &chunk.inline_computed_caches[0];
    cell.shape = receiver_shape;
    cell.slot = slot;
    cell.cached_key_len = 1;
    cell.cached_key_buf[0] = 'e';

    var native = try NativeGraph.build(&chunk);
    defer native.deinit();
    const registers = try testing.allocator.alloc(Value, chunk.register_count);
    defer testing.allocator.free(registers);
    var frame = testFrame(&chunk, registers);
    frame.registers[0] = heap_mod.taggedObject(receiver);
    frame.registers[1] = Value.fromString(try realm.heap.allocateString("e"));
    frame.registers[2] = Value.fromInt32(77);

    var machine = masm.Masm.init(testing.allocator);
    defer machine.deinit();
    var executable = try code_alloc.CodeAllocator.init(testing.allocator, 64 * 1024);
    defer executable.deinit();
    const entry = try installNative(&native, &frame, &machine, &executable);
    try testing.expectEqual(
        @intFromEnum(codegen.EntryResult.done),
        executeEntry(entry, &realm, &frame),
    );
    try testing.expectEqual(Value.fromInt32(77).bits, frame.accumulator.bits);
    try testing.expectEqual(Value.fromInt32(77).bits, receiver.slotAt(slot).bits);
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

test "Ohaimark AArch64 throw_if_hole preserves values and resumes TDZ throws" {
    if (comptime !masm.native_aarch64) return error.SkipZigTest;
    var chunk = try throwIfHoleChunk();
    defer chunk.deinit(testing.allocator);
    var native = try NativeGraph.build(&chunk);
    defer native.deinit();
    const node_id = try findNode(&native, .throw_if_hole);
    try testing.expectEqual(
        specialize.Lowering.throw_if_hole,
        native.specialization.node_info[node_id].lowering,
    );

    var realm = Realm.init(testing.allocator);
    defer realm.deinit();
    realm.jit_enabled = false;
    const registers = try testing.allocator.alloc(Value, chunk.register_count);
    defer testing.allocator.free(registers);

    var frame = testFrame(&chunk, registers);
    frame.accumulator = Value.fromInt32(42);
    try testing.expectEqual(
        @intFromEnum(codegen.EntryResult.done),
        try executeNative(&native, &realm, &frame),
    );
    try testing.expectEqual(Value.fromInt32(42).bits, frame.accumulator.bits);

    frame = testFrame(&chunk, registers);
    frame.accumulator = Value.hole_;
    try testing.expectEqual(
        @intFromEnum(codegen.EntryResult.resume_interp),
        try executeNative(&native, &realm, &frame),
    );
    try testing.expectEqual(native.graph.nodes[node_id].bytecode_offset, frame.ip);
    try testing.expectEqual(Value.hole_.bits, frame.accumulator.bits);
    switch (try resumeLanternResult(&realm, frame)) {
        .thrown => {},
        else => return error.TestUnexpectedResult,
    }
}

test "Ohaimark AArch64 throw replays the exact Lantern frame" {
    if (comptime !masm.native_aarch64) return error.SkipZigTest;
    var throwing = try throwChunk();
    defer throwing.chunk.deinit(testing.allocator);
    var native = try NativeGraph.build(&throwing.chunk);
    defer native.deinit();

    var realm = Realm.init(testing.allocator);
    defer realm.deinit();
    realm.jit_enabled = false;
    const registers = try testing.allocator.alloc(Value, throwing.chunk.register_count);
    defer testing.allocator.free(registers);

    var frame = testFrame(&throwing.chunk, registers);
    try testing.expectEqual(
        @intFromEnum(codegen.EntryResult.resume_interp),
        try executeNative(&native, &realm, &frame),
    );
    try testing.expectEqual(throwing.throw_pc, frame.ip);
    try testing.expectEqual(Value.fromInt32(42).bits, frame.accumulator.bits);
    switch (try resumeLanternResult(&realm, frame)) {
        .thrown => |value| try testing.expectEqual(Value.fromInt32(42).bits, value.bits),
        else => return error.TestUnexpectedResult,
    }
}

test "Ohaimark AArch64 typeof uses realm-cached strings across value kinds" {
    if (comptime !masm.native_aarch64) return error.SkipZigTest;
    const Noop = struct {
        fn body(realm: *Realm, this_value: Value, args: []const Value) NativeError!Value {
            _ = realm;
            _ = this_value;
            _ = args;
            return Value.undefined_;
        }
    };

    var chunk = try typeOfChunk();
    defer chunk.deinit(testing.allocator);
    var native = try NativeGraph.build(&chunk);
    defer native.deinit();
    const node_id = try findNode(&native, .typeof_);
    try testing.expectEqual(
        specialize.Lowering.typeof_,
        native.specialization.node_info[node_id].lowering,
    );

    var realm = Realm.init(testing.allocator);
    defer realm.deinit();
    realm.jit_enabled = false;
    const plain_object = try realm.heap.allocateObject();
    const callable_object = try realm.heap.allocateObject();
    callable_object.brand.proxy_callable = true;
    const string = try realm.heap.allocateString("string");
    const function = try realm.heap.allocateFunctionNative(&realm, Noop.body, 0, "f");
    const symbol = try realm.heap.allocateSymbol(null);
    const bigint = try realm.heap.allocateBigInt(1);
    const cases = [_]Value{
        Value.undefined_,
        Value.null_,
        Value.true_,
        Value.fromInt32(1),
        Value.fromDouble(1.5),
        Value.fromString(string),
        heap_mod.taggedFunction(function),
        heap_mod.taggedObject(plain_object),
        heap_mod.taggedObject(callable_object),
        heap_mod.taggedSymbol(symbol),
        heap_mod.taggedBigInt(bigint),
    };

    var registers: [0]Value = .{};
    var frame = testFrame(&chunk, &registers);
    frame.accumulator = Value.undefined_;
    var machine = masm.Masm.init(testing.allocator);
    defer machine.deinit();
    var executable = try code_alloc.CodeAllocator.init(testing.allocator, 64 * 1024);
    defer executable.deinit();
    const entry = try installNative(&native, &frame, &machine, &executable);

    // The lazy cache begins empty. Generated code must reconstruct the
    // original operation so Lantern fills it, then execute directly later.
    try testing.expectEqual(
        @intFromEnum(codegen.EntryResult.resume_interp),
        executeEntry(entry, &realm, &frame),
    );
    try testing.expectEqual(native.graph.nodes[node_id].bytecode_offset, frame.ip);
    const cache_miss = try resumeLantern(&realm, frame);
    const cache_miss_string: *JSString = @ptrCast(@alignCast(cache_miss.asString()));
    try testing.expectEqualStrings("undefined", cache_miss_string.flatBytes());

    for (cases) |input| {
        const expected = try arith.typeOf(&realm, input);
        frame = testFrame(&chunk, &registers);
        frame.accumulator = input;
        try testing.expectEqual(
            @intFromEnum(codegen.EntryResult.done),
            executeEntry(entry, &realm, &frame),
        );
        try testing.expectEqual(expected.bits, frame.accumulator.bits);
    }
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
    try testing.expectError(codegen.EmitError.RetryableFeedback, native.emit(&machine, &chunk));
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
    // Both operands open (no int32 evidence) → generic add, still refused by
    // AArch64 emit. (smi + unknown now lowers to checked_int32_add.)
    var builder = Builder.init(testing.allocator);
    defer builder.deinit();
    const unknown_lhs = try builder.reserveRegister();
    const unknown_rhs = try builder.reserveRegister();
    try builder.emitLoadReg(span, unknown_rhs);
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
        @intFromEnum(codegen.EntryResult.safe_point),
        executeEntry(stub, &realm, &frame),
    );
    try testing.expectEqual(loop.header, frame.ip);
    try testing.expectEqual(Value.fromInt32(0).bits, frame.accumulator.bits);
    try testing.expectEqual(heap_mod.taggedObject(root).bits, frame.registers[loop.root].bits);
}

test "Ohaimark AArch64 checked int32 add deopts on overflow" {
    // result_type stays int32 under checked_int32_add; overflow must still
    // resume Lantern (not wrap or finish with a wrong int32).
    if (comptime !masm.native_aarch64) return error.SkipZigTest;
    var chunk = try diamondBinaryChunk(.add, std.math.maxInt(i32), std.math.maxInt(i32) - 1, 1);
    defer chunk.deinit(testing.allocator);
    var native = try NativeGraph.build(&chunk);
    defer native.deinit();
    const add_id = try findNode(&native, .add);
    try testing.expectEqual(
        specialize.Lowering.checked_int32_add,
        native.specialization.node_info[add_id].lowering,
    );
    try testing.expect(native.specialization.node_info[add_id].result_type.eql(specialize.Type.int32));

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
    const resumed = try resumeLantern(&realm, frame);
    try testing.expectEqual(Value.fromDouble(@as(f64, @floatFromInt(std.math.maxInt(i32))) + 1.0).bits, resumed.bits);
}

test "Ohaimark IR models register updates as checked arithmetic with pre-update state" {
    const cases = [_]struct {
        op: Op,
        binary: ir.NodeKind,
    }{
        .{ .op = .inc_reg, .binary = .add },
        .{ .op = .dec_reg, .binary = .sub },
    };
    for (cases) |case| {
        var update = try registerUpdateChunk(case.op);
        defer update.chunk.deinit(testing.allocator);
        var graph = try ir.Graph.build(testing.allocator, &update.chunk);
        defer graph.deinit();

        const node_id = findNodeInGraph(&graph, case.binary) orelse
            return error.TestUnexpectedResult;
        const node = graph.nodes[node_id];
        const inputs = graph.nodeInputs(node_id);
        try testing.expectEqual(@as(usize, 2), inputs.len);
        try testing.expectEqual(ir.NodeKind.block_parameter, graph.nodes[inputs[0]].kind);
        try testing.expectEqual(ir.NodeKind.constant, graph.nodes[inputs[1]].kind);
        try testing.expectEqual(update.update_pc, node.bytecode_offset);

        const frame_state = graph.frame_states[
            node.frame_state orelse
                return error.TestUnexpectedResult
        ];
        try testing.expectEqual(update.update_pc, frame_state.bytecode_offset);
        try testing.expectEqual(@as(u16, 1), frame_state.slot_count);
        const accumulator = graph.nodes[frame_state.accumulator];
        const immediate: ir.Immediate = switch (accumulator.payload) {
            .immediate => |value| value,
            else => return error.TestUnexpectedResult,
        };
        try testing.expectEqual(ir.Immediate{ .int32 = 99 }, immediate);
    }
}

test "Ohaimark AArch64 executes int32 register updates and reuses the binding" {
    if (comptime !masm.native_aarch64) return error.SkipZigTest;
    const cases = [_]struct {
        op: Op,
        binary: ir.NodeKind,
        lowering_kind: specialize.Lowering,
        input: i32,
        expected: i32,
    }{
        .{
            .op = .inc_reg,
            .binary = .add,
            .lowering_kind = .checked_int32_add,
            .input = 7,
            .expected = 8,
        },
        .{
            .op = .dec_reg,
            .binary = .sub,
            .lowering_kind = .checked_int32_sub,
            .input = 7,
            .expected = 6,
        },
    };
    for (cases) |case| {
        var update = try registerUpdateChunk(case.op);
        defer update.chunk.deinit(testing.allocator);
        var native = try NativeGraph.build(&update.chunk);
        defer native.deinit();
        const node_id = try findNode(&native, case.binary);
        try testing.expectEqual(case.lowering_kind, native.specialization.node_info[node_id].lowering);

        var realm = Realm.init(testing.allocator);
        defer realm.deinit();
        realm.jit_enabled = false;
        const registers = try testing.allocator.alloc(Value, update.chunk.register_count);
        defer testing.allocator.free(registers);
        var frame = testFrame(&update.chunk, registers);
        frame.registers[update.register] = Value.fromInt32(case.input);

        try testing.expectEqual(
            @intFromEnum(codegen.EntryResult.done),
            try executeNative(&native, &realm, &frame),
        );
        try testing.expectEqual(Value.fromInt32(case.expected).bits, frame.accumulator.bits);
    }
}

test "Ohaimark AArch64 register updates guard before overwriting a non-int32 result" {
    if (comptime !masm.native_aarch64) return error.SkipZigTest;
    const cases = [_]struct {
        op: Op,
        binary: ir.NodeKind,
        input: i32,
        expected: f64,
    }{
        .{
            .op = .inc_reg,
            .binary = .add,
            .input = std.math.maxInt(i32),
            .expected = @as(f64, @floatFromInt(std.math.maxInt(i32))) + 1.0,
        },
        .{
            .op = .dec_reg,
            .binary = .sub,
            .input = std.math.minInt(i32),
            .expected = @as(f64, @floatFromInt(std.math.minInt(i32))) - 1.0,
        },
    };
    for (cases) |case| {
        var update = try registerUpdateChunk(case.op);
        defer update.chunk.deinit(testing.allocator);
        var native = try NativeGraph.build(&update.chunk);
        defer native.deinit();
        _ = try findNode(&native, case.binary);

        var realm = Realm.init(testing.allocator);
        defer realm.deinit();
        realm.jit_enabled = false;
        const registers = try testing.allocator.alloc(Value, update.chunk.register_count);
        defer testing.allocator.free(registers);
        var frame = testFrame(&update.chunk, registers);
        const original = Value.fromInt32(case.input);
        frame.registers[update.register] = original;

        try testing.expectEqual(
            @intFromEnum(codegen.EntryResult.resume_interp),
            try executeNative(&native, &realm, &frame),
        );
        try testing.expectEqual(update.update_pc, frame.ip);
        try testing.expectEqual(Value.fromInt32(99).bits, frame.accumulator.bits);
        try testing.expectEqual(original.bits, frame.registers[update.register].bits);
        try testing.expectEqual(Value.fromDouble(case.expected).bits, (try resumeLantern(&realm, frame)).bits);
    }
}

test "Ohaimark IR admits Int32 ToNumeric update sequences at both deopt points" {
    inline for (.{ Op.inc, Op.dec }) |op| {
        var update = try toNumericUpdateChunk(op);
        defer update.chunk.deinit(testing.allocator);
        var graph = try ir.Graph.build(testing.allocator, &update.chunk);
        defer graph.deinit();

        var saw_to_numeric = false;
        var saw_update = false;
        for (graph.nodes) |node| {
            if (node.kind == .to_numeric) {
                saw_to_numeric = true;
                try testing.expectEqual(update.to_numeric_pc, node.bytecode_offset);
                try testing.expect(node.frame_state != null);
            }
            if (node.kind == if (op == .inc) ir.NodeKind.add else ir.NodeKind.sub) {
                saw_update = true;
                try testing.expectEqual(update.update_pc, node.bytecode_offset);
                try testing.expect(node.frame_state != null);
            }
        }
        try testing.expect(saw_to_numeric);
        try testing.expect(saw_update);
    }
}

test "Ohaimark AArch64 executes Int32 ToNumeric update sequences" {
    if (comptime !masm.native_aarch64) return error.SkipZigTest;
    const cases = [_]struct {
        op: Op,
        input: i32,
        expected: i32,
    }{
        .{ .op = .inc, .input = 7, .expected = 8 },
        .{ .op = .dec, .input = 7, .expected = 6 },
    };
    for (cases) |case| {
        var update = try toNumericUpdateChunk(case.op);
        defer update.chunk.deinit(testing.allocator);
        var native = try NativeGraph.build(&update.chunk);
        defer native.deinit();

        var realm = Realm.init(testing.allocator);
        defer realm.deinit();
        realm.jit_enabled = false;
        const registers = try testing.allocator.alloc(Value, update.chunk.register_count);
        defer testing.allocator.free(registers);
        var frame = testFrame(&update.chunk, registers);
        frame.registers[update.register] = Value.fromInt32(case.input);

        try testing.expectEqual(
            @intFromEnum(codegen.EntryResult.done),
            try executeNative(&native, &realm, &frame),
        );
        try testing.expectEqual(Value.fromInt32(case.expected).bits, frame.accumulator.bits);
    }
}

test "Ohaimark AArch64 compiles consumed postfix ToNumeric updates" {
    if (comptime !masm.native_aarch64) return error.SkipZigTest;
    inline for (.{ Op.inc, Op.dec }) |op| {
        var chunk = try toNumericPostfixUpdateChunk(op);
        defer chunk.deinit(testing.allocator);
        var native = try NativeGraph.build(&chunk);
        defer native.deinit();

        var realm = Realm.init(testing.allocator);
        defer realm.deinit();
        realm.jit_enabled = false;
        const registers = try testing.allocator.alloc(Value, chunk.register_count);
        defer testing.allocator.free(registers);
        var frame = testFrame(&chunk, registers);
        frame.registers[0] = Value.fromInt32(41);

        try testing.expectEqual(
            @intFromEnum(codegen.EntryResult.done),
            try executeNative(&native, &realm, &frame),
        );
        try testing.expectEqual(Value.fromInt32(41).bits, frame.accumulator.bits);
    }
}

test "Ohaimark AArch64 replays ToNumeric before the bump and overflow at the bump" {
    if (comptime !masm.native_aarch64) return error.SkipZigTest;
    const cases = [_]struct {
        op: Op,
        input: i32,
        double_input: f64,
        double_result: f64,
        overflow_result: f64,
    }{
        .{
            .op = .inc,
            .input = std.math.maxInt(i32),
            .double_input = 1.5,
            .double_result = 2.5,
            .overflow_result = @as(f64, @floatFromInt(std.math.maxInt(i32))) + 1.0,
        },
        .{
            .op = .dec,
            .input = std.math.minInt(i32),
            .double_input = 1.5,
            .double_result = 0.5,
            .overflow_result = @as(f64, @floatFromInt(std.math.minInt(i32))) - 1.0,
        },
    };
    for (cases) |case| {
        var update = try toNumericUpdateChunk(case.op);
        defer update.chunk.deinit(testing.allocator);
        var native = try NativeGraph.build(&update.chunk);
        defer native.deinit();

        var realm = Realm.init(testing.allocator);
        defer realm.deinit();
        realm.jit_enabled = false;
        const registers = try testing.allocator.alloc(Value, update.chunk.register_count);
        defer testing.allocator.free(registers);
        var frame = testFrame(&update.chunk, registers);
        const double = Value.fromDouble(case.double_input);
        frame.registers[update.register] = double;

        try testing.expectEqual(
            @intFromEnum(codegen.EntryResult.resume_interp),
            try executeNative(&native, &realm, &frame),
        );
        try testing.expectEqual(update.to_numeric_pc, frame.ip);
        try testing.expectEqual(double.bits, frame.accumulator.bits);
        try testing.expectEqual(double.bits, frame.registers[update.register].bits);
        try testing.expectEqual(Value.fromDouble(case.double_result).bits, (try resumeLantern(&realm, frame)).bits);

        frame = testFrame(&update.chunk, registers);
        const overflow = Value.fromInt32(case.input);
        frame.registers[update.register] = overflow;
        try testing.expectEqual(
            @intFromEnum(codegen.EntryResult.resume_interp),
            try executeNative(&native, &realm, &frame),
        );
        try testing.expectEqual(update.update_pc, frame.ip);
        try testing.expectEqual(overflow.bits, frame.accumulator.bits);
        try testing.expectEqual(overflow.bits, frame.registers[update.register].bits);
        try testing.expectEqual(Value.fromDouble(case.overflow_result).bits, (try resumeLantern(&realm, frame)).bits);
    }
}

test "Ohaimark IR admits guarded ToString and RequireObjectCoercible" {
    inline for (.{ Op.to_string, Op.require_object_coercible }) |op| {
        var unary = try unaryGuardChunk(op);
        defer unary.chunk.deinit(testing.allocator);
        var graph = try ir.Graph.build(testing.allocator, &unary.chunk);
        defer graph.deinit();
        const expected_kind: ir.NodeKind = if (op == .to_string)
            .to_string
        else
            .require_object_coercible;
        const node_id = findNodeInGraph(&graph, expected_kind) orelse
            return error.TestUnexpectedResult;
        const node = graph.nodes[node_id];
        try testing.expectEqual(unary.operation_pc, node.bytecode_offset);
        try testing.expect(node.frame_state != null);
        try testing.expectEqual(@as(u16, 1), node.input_count);
    }
}

test "Ohaimark AArch64 guards ToString and RequireObjectCoercible before Lantern" {
    if (comptime !masm.native_aarch64) return error.SkipZigTest;
    inline for (.{ Op.to_string, Op.require_object_coercible }) |op| {
        var unary = try unaryGuardChunk(op);
        defer unary.chunk.deinit(testing.allocator);
        var native = try NativeGraph.build(&unary.chunk);
        defer native.deinit();
        var realm = Realm.init(testing.allocator);
        defer realm.deinit();
        realm.jit_enabled = false;
        const registers = try testing.allocator.alloc(Value, unary.chunk.register_count);
        defer testing.allocator.free(registers);

        var frame = testFrame(&unary.chunk, registers);
        const hit = if (op == .to_string)
            Value.fromString(try realm.heap.allocateString("kept"))
        else
            Value.fromInt32(17);
        frame.registers[unary.input] = hit;
        try testing.expectEqual(
            @intFromEnum(codegen.EntryResult.done),
            try executeNative(&native, &realm, &frame),
        );
        try testing.expectEqual(hit.bits, frame.accumulator.bits);

        frame = testFrame(&unary.chunk, registers);
        const miss = if (op == .to_string) Value.fromInt32(17) else Value.null_;
        frame.registers[unary.input] = miss;
        try testing.expectEqual(
            @intFromEnum(codegen.EntryResult.resume_interp),
            try executeNative(&native, &realm, &frame),
        );
        try testing.expectEqual(unary.operation_pc, frame.ip);
        try testing.expectEqual(miss.bits, frame.accumulator.bits);
        if (op == .to_string) {
            const result = try resumeLantern(&realm, frame);
            const result_string: *JSString = @ptrCast(@alignCast(result.asString()));
            try testing.expectEqualStrings("17", result_string.flatBytes());
        } else {
            switch (try resumeLanternResult(&realm, frame)) {
                .thrown => {},
                else => return error.TestUnexpectedResult,
            }
        }
    }
}

test "Ohaimark IR admits terminal tail dispatch with rooted operands" {
    inline for (.{ Op.tail_call, Op.tail_call_method }) |op| {
        var tail = try tailDispatchChunk(op);
        defer tail.chunk.deinit(testing.allocator);
        var graph = try ir.Graph.build(testing.allocator, &tail.chunk);
        defer graph.deinit();

        var saw_tail = false;
        for (graph.nodes) |node| {
            if (node.bytecode_offset != tail.tail_pc or node.frame_state == null) continue;
            saw_tail = true;
            const frame_state = graph.frame_states[node.frame_state.?];
            const expected_slots: u16 = if (tail.receiver == null) 2 else 3;
            try testing.expectEqual(expected_slots, frame_state.slot_count);
        }
        try testing.expect(saw_tail);
    }
}

test "Ohaimark rejects malformed terminal tail dispatch operands" {
    var chunk = try malformedTailDispatchChunk();
    defer chunk.deinit(testing.allocator);
    try testing.expectError(error.MalformedBytecode, ir.Graph.build(testing.allocator, &chunk));
}

test "Ohaimark IR gives computed delete exact rooted frame state" {
    var delete = try computedDeleteChunk();
    defer delete.chunk.deinit(testing.allocator);
    var graph = try ir.Graph.build(testing.allocator, &delete.chunk);
    defer graph.deinit();

    const node_id = findNodeInGraph(&graph, .delete_computed_property) orelse
        return error.TestUnexpectedResult;
    const node = graph.nodes[node_id];
    const site: ir.ComputedDelete = switch (node.payload) {
        .computed_delete => |value| value,
        else => return error.TestUnexpectedResult,
    };
    const state = graph.frame_states[node.frame_state orelse return error.TestUnexpectedResult];
    try testing.expectEqual(delete.delete_pc, node.bytecode_offset);
    try testing.expectEqual(node.bytecode_offset, state.bytecode_offset);
    try testing.expectEqual(delete.object_register, site.object_register);
    try testing.expectEqual(delete.key_register, site.key_register);
    try testing.expectEqual(@as(u16, 2), state.slot_count);
}

test "Ohaimark rejects malformed computed delete operands" {
    var chunk = try malformedComputedDeleteChunk();
    defer chunk.deinit(testing.allocator);
    try testing.expectError(error.MalformedBytecode, ir.Graph.build(testing.allocator, &chunk));
}

test "Ohaimark AArch64 tail dispatch resumes Lantern with the pre-tail frame" {
    if (comptime !masm.native_aarch64) return error.SkipZigTest;
    inline for (.{ Op.tail_call, Op.tail_call_method }) |op| {
        var tail = try tailDispatchChunk(op);
        defer tail.chunk.deinit(testing.allocator);
        var native = try NativeGraph.build(&tail.chunk);
        defer native.deinit();

        var realm = Realm.init(testing.allocator);
        defer realm.deinit();
        realm.jit_enabled = false;
        const registers = try testing.allocator.alloc(Value, tail.chunk.register_count);
        defer testing.allocator.free(registers);
        var frame = testFrame(&tail.chunk, registers);
        const callee = Value.fromInt32(31);
        const argument = Value.fromInt32(17);
        frame.registers[tail.callee] = callee;
        frame.registers[tail.argument] = argument;
        if (tail.receiver) |receiver_register| {
            frame.registers[receiver_register] = Value.fromInt32(23);
        }

        try testing.expectEqual(
            @intFromEnum(codegen.EntryResult.resume_interp),
            try executeNative(&native, &realm, &frame),
        );
        try testing.expectEqual(tail.tail_pc, frame.ip);
        try testing.expectEqual(Value.fromInt32(99).bits, frame.accumulator.bits);
        try testing.expectEqual(callee.bits, frame.registers[tail.callee].bits);
        try testing.expectEqual(argument.bits, frame.registers[tail.argument].bits);
        if (tail.receiver) |receiver_register| {
            try testing.expectEqual(Value.fromInt32(23).bits, frame.registers[receiver_register].bits);
        }
    }
}

test "Ohaimark AArch64 checked_branch deopts non-int32 condition" {
    // Int32-only truthiness: a double formal must deopt, then Lantern ToBoolean.
    if (comptime !masm.native_aarch64) return error.SkipZigTest;
    var builder = Builder.init(testing.allocator);
    defer builder.deinit();
    const x = try builder.reserveRegister();
    try builder.emitLoadReg(span, x);
    const branch_pc = builder.here();
    try builder.emitOp(.jmp_if_false, span);
    const false_patch = builder.here();
    try builder.emitI16(0);
    try builder.emitLoadSmi(span, 11);
    try builder.emitOp(.return_, span);
    const false_target = builder.here();
    try builder.emitLoadSmi(span, 22);
    try builder.emitOp(.return_, span);
    try builder.patchI16(false_patch, false_target);
    var chunk = try builder.finish();
    defer chunk.deinit(testing.allocator);
    var native = try NativeGraph.build(&chunk);
    defer native.deinit();
    const branch_id = try findNode(&native, .branch);
    try testing.expectEqual(
        specialize.Lowering.checked_branch,
        native.specialization.node_info[branch_id].lowering,
    );

    var realm = Realm.init(testing.allocator);
    defer realm.deinit();
    realm.jit_enabled = false;
    const registers = try testing.allocator.alloc(Value, chunk.register_count);
    defer testing.allocator.free(registers);
    var frame = testFrame(&chunk, registers);
    frame.registers[x] = Value.fromDouble(1.5);
    try testing.expectEqual(
        @intFromEnum(codegen.EntryResult.resume_interp),
        try executeNative(&native, &realm, &frame),
    );
    try testing.expectEqual(branch_pc, frame.ip);
    // 1.5 is truthy — fallthrough returns 11.
    try testing.expectEqual(Value.fromInt32(11).bits, (try resumeLantern(&realm, frame)).bits);
}

test "Ohaimark AArch64 checked_branch treats negative int32 as truthy" {
    if (comptime !masm.native_aarch64) return error.SkipZigTest;
    var builder = Builder.init(testing.allocator);
    defer builder.deinit();
    const x = try builder.reserveRegister();
    try builder.emitLoadReg(span, x);
    try builder.emitOp(.jmp_if_false, span);
    const false_patch = builder.here();
    try builder.emitI16(0);
    try builder.emitLoadSmi(span, 11);
    try builder.emitOp(.return_, span);
    const false_target = builder.here();
    try builder.emitLoadSmi(span, 22);
    try builder.emitOp(.return_, span);
    try builder.patchI16(false_patch, false_target);
    var chunk = try builder.finish();
    defer chunk.deinit(testing.allocator);
    var native = try NativeGraph.build(&chunk);
    defer native.deinit();

    var realm = Realm.init(testing.allocator);
    defer realm.deinit();
    realm.jit_enabled = false;
    const registers = try testing.allocator.alloc(Value, chunk.register_count);
    defer testing.allocator.free(registers);
    var frame = testFrame(&chunk, registers);
    frame.registers[x] = Value.fromInt32(-3);
    try testing.expectEqual(
        @intFromEnum(codegen.EntryResult.done),
        try executeNative(&native, &realm, &frame),
    );
    try testing.expectEqual(Value.fromInt32(11).bits, frame.accumulator.bits);
}

test "Ohaimark AArch64 refuses nullish branch on open Type.any" {
    // Defense for specialize's nullish gate: open formal + jmp_if_nullish must
    // not publish always-fallthrough (would miscompile `x ?? 1` when x is null).
    if (comptime !masm.native_aarch64) return error.SkipZigTest;
    var builder = Builder.init(testing.allocator);
    defer builder.deinit();
    const x = try builder.reserveRegister();
    try builder.emitLoadReg(span, x);
    try builder.emitOp(.jmp_if_nullish, span);
    const taken_patch = builder.here();
    try builder.emitI16(0);
    try builder.emitLoadSmi(span, 1);
    try builder.emitOp(.return_, span);
    const taken = builder.here();
    try builder.emitLoadSmi(span, 2);
    try builder.emitOp(.return_, span);
    try builder.patchI16(taken_patch, taken);
    var chunk = try builder.finish();
    defer chunk.deinit(testing.allocator);
    var native = try NativeGraph.build(&chunk);
    defer native.deinit();
    const branch_id = try findNode(&native, .branch);
    try testing.expectEqual(
        specialize.Lowering.none,
        native.specialization.node_info[branch_id].lowering,
    );
    var machine = masm.Masm.init(testing.allocator);
    defer machine.deinit();
    try testing.expectError(error.UnsupportedNode, native.emit(&machine, &chunk));
    try testing.expectEqual(@as(usize, 0), machine.code.items.len);
}

test "Ohaimark AArch64 compiles countdown loop with loop-carried int32" {
    if (comptime !masm.native_aarch64) return error.SkipZigTest;
    const compiler_mod = @import("../../bytecode/compiler.zig");
    const parser_mod = @import("../../parser/parser.zig");
    var realm = Realm.init(testing.allocator);
    defer realm.deinit();
    realm.jit_enabled = false;
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
        \\count(10);
    ;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const program = try parser_mod.parseScript(arena.allocator(), source, null);
    var chunk = try compiler_mod.compileScriptAsChunk(testing.allocator, &realm, &program, source, null);
    defer chunk.deinit(testing.allocator);
    const fn_chunk = blk: {
        for (chunk.function_templates) |*t| {
            if (t.name) |n| if (std.mem.eql(u8, n, "count")) break :blk &t.chunk;
        }
        return error.TestUnexpectedResult;
    };
    var native = try NativeGraph.build(fn_chunk);
    defer native.deinit();
    var machine = masm.Masm.init(testing.allocator);
    defer machine.deinit();
    var osr: std.ArrayListUnmanaged(chunk_mod.Chunk.JitState.OsrEntry) = .empty;
    defer osr.deinit(testing.allocator);
    try codegen.emitGraphCollectingOsr(
        testing.allocator,
        &machine,
        fn_chunk,
        &native.graph,
        &native.specialization,
        &native.representations,
        &native.control_fusion,
        &native.logical,
        &native.homes,
        &native.physical_deopt,
        &native.allocated,
        &native.lowered,
        &osr,
    );
    try testing.expect(machine.code.items.len > 0);
    try testing.expect(osr.items.len >= 1);
}
