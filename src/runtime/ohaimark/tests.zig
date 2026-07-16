const std = @import("std");

const chunk_mod = @import("../../bytecode/chunk.zig");
const Builder = chunk_mod.Builder;
const Chunk = chunk_mod.Chunk;
const Op = @import("../../bytecode/op.zig").Op;
const Span = @import("../../source.zig").Span;
const JSFunction = @import("../function.zig").JSFunction;
const JSObject = @import("../object.zig").JSObject;
const Shape = @import("../shape.zig").Shape;
const Value = @import("../value.zig").Value;
const deopt = @import("deopt.zig");
const feedback = @import("feedback.zig");
const ir = @import("ir.zig");
const representation = @import("representation.zig");
const specialize = @import("specialize.zig");

const testing = std.testing;
const span: Span = .{ .start = 0, .end = 1 };

fn finish(builder: *Builder) !Chunk {
    try builder.emitOp(.return_, span);
    return builder.finish();
}

fn findNode(graph: *const ir.Graph, kind: ir.NodeKind) ?ir.ValueId {
    for (graph.nodes, 0..) |node, index| {
        if (node.kind == kind) return @intCast(index);
    }
    return null;
}

test "Ohaimark feedback snapshot preserves stable guards without GC pointers" {
    var builder = Builder.init(testing.allocator);
    defer builder.deinit();
    const receiver = try builder.reserveRegister();
    try builder.emitLdaProperty(span, 0);
    try builder.emitStaProperty(span, 0, receiver);
    try builder.emitLdaComputed(span, receiver);
    try builder.emitCall(span, receiver, 0);
    try builder.emitForInOpen(span);
    var chunk = try finish(&builder);
    defer chunk.deinit(testing.allocator);

    const receiver_shape: *Shape = @ptrFromInt(0x1000);
    const holder_shape: *Shape = @ptrFromInt(0x2000);
    const result_shape: *Shape = @ptrFromInt(0x3000);
    const proto: *JSObject = @ptrFromInt(0x4000);
    const snapshot_object: *JSObject = @ptrFromInt(0x5000);
    const callee: *JSFunction = @ptrFromInt(0x6000);

    chunk.inline_load_caches[0] = .{
        .shape = receiver_shape,
        .slot = 3,
        .proto = proto,
        .proto_shape = holder_shape,
        .proto_rev = 11,
    };
    chunk.inline_store_caches[0] = .{
        .slot = 4,
        .proto = proto,
        .proto_shape = holder_shape,
        .proto_rev = 12,
        .pre_shape = receiver_shape,
        .post_shape = result_shape,
        .guard_epoch = 13,
    };
    chunk.inline_computed_caches[0].shape = receiver_shape;
    chunk.inline_computed_caches[0].slot = 5;
    chunk.inline_computed_caches[0].cached_key_len = 3;
    @memcpy(chunk.inline_computed_caches[0].cached_key_buf[0..3], "key");
    chunk.inline_call_caches[0] = .{
        .callee = callee,
        .proto = proto,
        .initial_shape = result_shape,
    };
    chunk.inline_forin_caches[0] = .{
        .recv_shape = receiver_shape,
        .proto = proto,
        .snapshot = snapshot_object,
        .guard_epoch = 14,
    };

    var snapshot = try feedback.Snapshot.capture(testing.allocator, &chunk);
    defer snapshot.deinit();

    try testing.expect(!@hasField(feedback.Load, "proto"));
    try testing.expect(!@hasField(feedback.Call, "callee"));
    try testing.expect(!@hasField(feedback.ForIn, "snapshot"));
    try testing.expectEqual(feedback.LoadMode.prototype_data, snapshot.loads[0].mode);
    try testing.expectEqual(receiver_shape, snapshot.loads[0].receiver_shape);
    try testing.expectEqual(holder_shape, snapshot.loads[0].holder_shape);
    try testing.expectEqual(@as(u64, 11), snapshot.loads[0].revision);
    try testing.expectEqual(feedback.StoreMode.transition, snapshot.stores[0].mode);
    try testing.expectEqual(result_shape, snapshot.stores[0].post_shape);
    try testing.expectEqual(@as(u64, 13), snapshot.stores[0].guard_epoch);
    try testing.expectEqual(feedback.ComputedMode.monomorphic, snapshot.computed[0].mode);
    try testing.expectEqualStrings("key", snapshot.computed[0].key());
    try testing.expectEqual(feedback.CallMode.construct, snapshot.calls[0].mode);
    try testing.expectEqual(result_shape, snapshot.calls[0].initial_shape);
    try testing.expectEqual(feedback.ForInMode.monomorphic, snapshot.for_in[0].mode);

    chunk.inline_computed_caches[0].cached_key_buf[0] = 'X';
    chunk.inline_call_caches[0].callee = null;
    try testing.expectEqualStrings("key", snapshot.computed[0].key());
    try testing.expectEqual(feedback.CallMode.construct, snapshot.calls[0].mode);
}

test "Ohaimark feedback distinguishes cold and megamorphic computed sites" {
    var builder = Builder.init(testing.allocator);
    defer builder.deinit();
    const receiver = try builder.reserveRegister();
    try builder.emitLdaComputed(span, receiver);
    try builder.emitLdaComputed(span, receiver);
    var chunk = try finish(&builder);
    defer chunk.deinit(testing.allocator);
    chunk.inline_computed_caches[1].cached_key_len = chunk_mod.computed_key_megamorphic;

    var snapshot = try feedback.Snapshot.capture(testing.allocator, &chunk);
    defer snapshot.deinit();
    try testing.expectEqual(feedback.ComputedMode.cold, snapshot.computed[0].mode);
    try testing.expectEqual(feedback.ComputedMode.megamorphic, snapshot.computed[1].mode);
}

test "Ohaimark builds straight-line value flow" {
    var builder = Builder.init(testing.allocator);
    defer builder.deinit();
    const lhs = try builder.reserveRegister();
    try builder.emitLoadSmi(span, 40);
    try builder.emitStoreReg(span, lhs);
    try builder.emitLoadSmi(span, 2);
    try builder.emitOp(.add, span);
    try builder.emitU8(lhs);
    var chunk = try finish(&builder);
    defer chunk.deinit(testing.allocator);

    var graph = try ir.Graph.build(testing.allocator, &chunk);
    defer graph.deinit();
    const add_id = findNode(&graph, .add).?;
    const return_id = findNode(&graph, .return_).?;
    try testing.expectEqual(@as(usize, 2), graph.nodeInputs(add_id).len);
    try testing.expectEqualSlices(ir.ValueId, &.{add_id}, graph.nodeInputs(return_id));
}

test "Ohaimark block arguments merge accumulator values in a diamond" {
    var builder = Builder.init(testing.allocator);
    defer builder.deinit();
    try builder.emitOp(.lda_true, span);
    try builder.emitOp(.jmp_if_false, span);
    const else_patch = builder.here();
    try builder.emitI16(0);
    try builder.emitOp(.lda_one, span);
    try builder.emitOp(.jmp, span);
    const join_patch = builder.here();
    try builder.emitI16(0);
    const else_target = builder.here();
    try builder.emitLoadSmi(span, 2);
    const join_target = builder.here();
    try builder.emitOp(.return_, span);
    try builder.patchI16(else_patch, else_target);
    try builder.patchI16(join_patch, join_target);
    var chunk = try builder.finish();
    defer chunk.deinit(testing.allocator);

    var graph = try ir.Graph.build(testing.allocator, &chunk);
    defer graph.deinit();
    var join: ?usize = null;
    for (graph.blocks, 0..) |block, index| {
        if (block.predecessor_count == 2) join = index;
    }
    const join_index = join.?;
    const params = graph.blockParams(join_index);
    try testing.expect(params.len >= 1);
    try testing.expectEqual(ir.ParamRole.accumulator, params[0].role);

    var saw_taken = false;
    var saw_fallthrough = false;
    for (graph.edges) |edge| switch (edge.kind) {
        .branch_taken => saw_taken = true,
        .branch_fallthrough => saw_fallthrough = true,
        else => {},
    };
    try testing.expect(saw_taken);
    try testing.expect(saw_fallthrough);

    var incoming: [2]ir.ValueId = undefined;
    var count: usize = 0;
    for (graph.edges) |edge| {
        if (edge.to != join_index) continue;
        incoming[count] = graph.edgeArguments(edge)[0];
        count += 1;
    }
    try testing.expectEqual(@as(usize, 2), count);
    try testing.expect(incoming[0] != incoming[1]);

    var specialization = try specialize.Plan.build(testing.allocator, &graph);
    defer specialization.deinit();
    var representations = try representation.Plan.build(
        testing.allocator,
        &graph,
        &specialization,
    );
    defer representations.deinit();
    try representations.verify(&graph, &specialization);
    try testing.expectEqual(
        representation.Kind.int32,
        representations.outputs[params[0].value],
    );
    for (graph.edges) |edge| {
        if (edge.to != join_index) continue;
        try testing.expectEqual(
            representation.Kind.int32,
            representations.input_requirements[edge.argument_start],
        );
        try testing.expectEqual(
            representation.Conversion.none,
            try representations.conversionAt(&graph, edge.argument_start),
        );
    }
}

test "Ohaimark representation selection keeps mixed block arguments tagged" {
    var builder = Builder.init(testing.allocator);
    defer builder.deinit();
    try builder.emitOp(.lda_true, span);
    try builder.emitOp(.jmp_if_false, span);
    const else_patch = builder.here();
    try builder.emitI16(0);
    try builder.emitOp(.lda_one, span);
    try builder.emitOp(.jmp, span);
    const join_patch = builder.here();
    try builder.emitI16(0);
    const else_target = builder.here();
    try builder.emitOp(.lda_null, span);
    const join_target = builder.here();
    try builder.emitOp(.return_, span);
    try builder.patchI16(else_patch, else_target);
    try builder.patchI16(join_patch, join_target);
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

    var join: ?usize = null;
    for (graph.blocks, 0..) |block, index| {
        if (block.predecessor_count == 2) join = index;
    }
    const join_index = join.?;
    const accumulator = graph.blockParams(join_index)[0].value;
    try testing.expectEqual(representation.Kind.tagged, representations.outputs[accumulator]);

    var boxed_count: usize = 0;
    var unchanged_count: usize = 0;
    for (graph.edges) |edge| {
        if (edge.to != join_index) continue;
        try testing.expectEqual(
            representation.Kind.tagged,
            representations.input_requirements[edge.argument_start],
        );
        switch (try representations.conversionAt(&graph, edge.argument_start)) {
            .box_int32 => boxed_count += 1,
            .none => unchanged_count += 1,
            .check_int32 => return error.TestUnexpectedResult,
        }
    }
    try testing.expectEqual(@as(usize, 1), boxed_count);
    try testing.expectEqual(@as(usize, 1), unchanged_count);
}

test "Ohaimark pre-creates live register parameters for loop back-edges" {
    var builder = Builder.init(testing.allocator);
    defer builder.deinit();
    const counter = try builder.reserveRegister();
    try builder.emitOp(.lda_zero, span);
    try builder.emitStoreReg(span, counter);
    try builder.emitOp(.lda_true, span);
    const header_target = builder.here();
    try builder.emitOp(.jmp_if_false, span);
    const exit_patch = builder.here();
    try builder.emitI16(0);
    try builder.emitAddSmi(span, counter, 1);
    try builder.emitStoreReg(span, counter);
    try builder.emitOp(.lda_true, span);
    try builder.emitOp(.jmp, span);
    const back_patch = builder.here();
    try builder.emitI16(0);
    const exit_target = builder.here();
    try builder.emitLoadReg(span, counter);
    try builder.emitOp(.return_, span);
    try builder.patchI16(exit_patch, exit_target);
    try builder.patchI16(back_patch, header_target);
    var chunk = try builder.finish();
    defer chunk.deinit(testing.allocator);

    var graph = try ir.Graph.build(testing.allocator, &chunk);
    defer graph.deinit();
    var header: ?usize = null;
    for (graph.blocks, 0..) |block, index| {
        if (block.predecessor_count == 2) header = index;
    }
    const header_index = header.?;
    const params = graph.blockParams(header_index);
    var register_argument: ?usize = null;
    for (params, 0..) |param, index| switch (param.role) {
        .register => |register| if (register == counter) {
            register_argument = index;
        },
        else => {},
    };

    var incoming: [2]ir.ValueId = undefined;
    var count: usize = 0;
    var saw_back_edge = false;
    for (graph.edges) |edge| {
        if (edge.to != header_index) continue;
        incoming[count] = graph.edgeArguments(edge)[register_argument.?];
        count += 1;
        saw_back_edge = saw_back_edge or edge.from > edge.to;
    }
    try testing.expectEqual(@as(usize, 2), count);
    try testing.expect(incoming[0] != incoming[1]);
    try testing.expect(saw_back_edge);
}

test "Ohaimark rejects unsupported bytecode without aborting" {
    var builder = Builder.init(testing.allocator);
    defer builder.deinit();
    try builder.emitOp(.make_object, span);
    var chunk = try finish(&builder);
    defer chunk.deinit(testing.allocator);
    try testing.expectError(error.UnsupportedOp, ir.Graph.build(testing.allocator, &chunk));
}

test "Ohaimark defers exception lowering explicitly" {
    var builder = Builder.init(testing.allocator);
    defer builder.deinit();
    try builder.emitOp(.lda_one, span);
    try builder.emitOp(.throw_, span);
    const handler_pc = builder.here();
    try builder.emitOp(.return_, span);
    try builder.addHandler(.{
        .start_pc = 0,
        .end_pc = handler_pc,
        .handler_pc = handler_pc,
        .catch_register = null,
    });
    var chunk = try builder.finish();
    defer chunk.deinit(testing.allocator);
    try testing.expectError(error.UnsupportedExceptionFlow, ir.Graph.build(testing.allocator, &chunk));
}

test "Ohaimark specialization folds semantics-safe int32 constants" {
    var builder = Builder.init(testing.allocator);
    defer builder.deinit();
    const lhs = try builder.reserveRegister();
    try builder.emitLoadSmi(span, 40);
    try builder.emitStoreReg(span, lhs);
    try builder.emitLoadSmi(span, 2);
    try builder.emitOp(.add, span);
    try builder.emitU8(lhs);
    var chunk = try finish(&builder);
    defer chunk.deinit(testing.allocator);

    var graph = try ir.Graph.build(testing.allocator, &chunk);
    defer graph.deinit();
    var plan = try specialize.Plan.build(testing.allocator, &graph);
    defer plan.deinit();
    const info = plan.node_info[findNode(&graph, .add).?];
    try testing.expect(info.result_type.eql(specialize.Type.int32));
    try testing.expectEqual(specialize.Lowering.constant, info.lowering);
    try testing.expectEqual(ir.Immediate{ .int32 = 42 }, info.folded.?);
}

test "Ohaimark specialization keeps overflowing int32 addition guarded" {
    var builder = Builder.init(testing.allocator);
    defer builder.deinit();
    const lhs = try builder.reserveRegister();
    try builder.emitLoadSmi(span, std.math.maxInt(i32));
    try builder.emitStoreReg(span, lhs);
    try builder.emitLoadSmi(span, 1);
    try builder.emitOp(.add, span);
    try builder.emitU8(lhs);
    var chunk = try finish(&builder);
    defer chunk.deinit(testing.allocator);

    var graph = try ir.Graph.build(testing.allocator, &chunk);
    defer graph.deinit();
    var plan = try specialize.Plan.build(testing.allocator, &graph);
    defer plan.deinit();
    const info = plan.node_info[findNode(&graph, .add).?];
    try testing.expect(info.result_type.eql(specialize.Type.number));
    try testing.expectEqual(specialize.Lowering.checked_int32_add, info.lowering);
    try testing.expectEqual(@as(?ir.Immediate, null), info.folded);
}

test "Ohaimark representation selection keeps guarded arithmetic int32" {
    var builder = Builder.init(testing.allocator);
    defer builder.deinit();
    const lhs = try builder.reserveRegister();
    try builder.emitLoadSmi(span, std.math.maxInt(i32));
    try builder.emitStoreReg(span, lhs);
    try builder.emitLoadSmi(span, 1);
    try builder.emitOp(.add, span);
    try builder.emitU8(lhs);
    var chunk = try finish(&builder);
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
    try representations.verify(&graph, &specialization);

    const add_id = findNode(&graph, .add).?;
    try testing.expectEqual(representation.Kind.int32, representations.outputs[add_id]);
    try testing.expectEqual(
        representation.Kind.int32,
        try representations.nodeInputRequirement(&graph, add_id, 0),
    );
    try testing.expectEqual(
        representation.Kind.int32,
        try representations.nodeInputRequirement(&graph, add_id, 1),
    );
    try testing.expectEqual(
        representation.Conversion.none,
        try representations.nodeInputConversion(&graph, add_id, 0),
    );

    const return_id = findNode(&graph, .return_).?;
    try testing.expectEqual(
        representation.Kind.tagged,
        try representations.nodeInputRequirement(&graph, return_id, 0),
    );
    try testing.expectEqual(
        representation.Conversion.box_int32,
        try representations.nodeInputConversion(&graph, return_id, 0),
    );

    const original_start = graph.nodes[add_id].input_start;
    graph.nodes[add_id].input_start = std.math.maxInt(u32);
    try testing.expectError(
        error.MalformedGraph,
        representation.Plan.build(testing.allocator, &graph, &specialization),
    );
    graph.nodes[add_id].input_start = original_start;

    const constant_id = findNode(&graph, .constant).?;
    const original_lowering = specialization.node_info[constant_id].lowering;
    specialization.node_info[constant_id].lowering = .generic;
    try testing.expectError(
        error.MalformedGraph,
        representation.Plan.build(testing.allocator, &graph, &specialization),
    );
    specialization.node_info[constant_id].lowering = original_lowering;
}

test "Ohaimark representation selection keeps generic arithmetic tagged" {
    var builder = Builder.init(testing.allocator);
    defer builder.deinit();
    const lhs = try builder.reserveRegister();
    try builder.emitLoadSmi(span, 1);
    try builder.emitOp(.add, span);
    try builder.emitU8(lhs);
    var chunk = try finish(&builder);
    defer chunk.deinit(testing.allocator);

    var graph = try ir.Graph.build(testing.allocator, &chunk);
    defer graph.deinit();
    var specialization = try specialize.Plan.build(testing.allocator, &graph);
    defer specialization.deinit();
    const add_id = findNode(&graph, .add).?;
    try testing.expectEqual(
        specialize.Lowering.generic,
        specialization.node_info[add_id].lowering,
    );
    var representations = try representation.Plan.build(
        testing.allocator,
        &graph,
        &specialization,
    );
    defer representations.deinit();
    try testing.expectEqual(representation.Kind.tagged, representations.outputs[add_id]);
    try testing.expectEqual(
        representation.Kind.tagged,
        try representations.nodeInputRequirement(&graph, add_id, 1),
    );
    try testing.expectEqual(
        representation.Conversion.box_int32,
        try representations.nodeInputConversion(&graph, add_id, 1),
    );

    const input_index = graph.nodes[add_id].input_start + 1;
    representations.input_requirements[input_index] = .int32;
    try testing.expectError(
        error.InvalidRepresentation,
        representations.verify(&graph, &specialization),
    );
}

test "Ohaimark deopt metadata round-trips pre-guard frame state" {
    var builder = Builder.init(testing.allocator);
    defer builder.deinit();
    const dead = try builder.reserveRegister();
    const lhs = try builder.reserveRegister();
    try builder.emitLoadSmi(span, 99);
    try builder.emitStoreReg(span, dead);
    try builder.emitLoadSmi(span, std.math.maxInt(i32));
    try builder.emitStoreReg(span, lhs);
    try builder.emitLoadSmi(span, 1);
    try builder.emitOp(.add, span);
    try builder.emitU8(lhs);
    var chunk = try finish(&builder);
    defer chunk.deinit(testing.allocator);

    var graph = try ir.Graph.build(testing.allocator, &chunk);
    defer graph.deinit();
    const add_id = findNode(&graph, .add).?;
    const state = graph.frame_states[graph.nodes[add_id].frame_state.?];
    try testing.expectEqual(graph.nodes[add_id].bytecode_offset, state.bytecode_offset);
    const slots = graph.frameSlots(state);
    try testing.expectEqual(@as(usize, 1), slots.len);
    try testing.expectEqual(lhs, slots[0].register);

    var plan = try specialize.Plan.build(testing.allocator, &graph);
    defer plan.deinit();
    try testing.expectEqual(
        specialize.Lowering.checked_int32_add,
        plan.node_info[add_id].lowering,
    );
    var metadata = try deopt.Metadata.build(testing.allocator, &graph, &plan);
    defer metadata.deinit();
    try metadata.verify(&graph, &plan);
    try testing.expectEqual(@as(usize, 1), metadata.points.len);
    try testing.expectEqual(add_id, metadata.points[0].node);

    var decoded = try metadata.decode(testing.allocator, 0);
    defer decoded.deinit();
    try testing.expectEqual(state.bytecode_offset, decoded.bytecode_offset);
    try testing.expectEqual(
        deopt.Recovery{ .immediate = .{ .int32 = 1 } },
        decoded.accumulator,
    );
    try testing.expectEqual(@as(usize, 1), decoded.slots.len);
    try testing.expectEqual(lhs, decoded.slots[0].register);
    try testing.expectEqual(
        deopt.Recovery{ .immediate = .{ .int32 = std.math.maxInt(i32) } },
        decoded.slots[0].recovery,
    );

    const original_offset_byte = metadata.stream[0];
    metadata.stream[0] ^= 0xff;
    try testing.expectError(error.InvalidMetadata, metadata.verify(&graph, &plan));
    metadata.stream[0] = original_offset_byte;

    const original_recovery_tag = metadata.stream[4];
    metadata.stream[4] = 0xff;
    try testing.expectError(error.InvalidMetadata, metadata.verify(&graph, &plan));
    metadata.stream[4] = original_recovery_tag;

    metadata.points[0].stream_len -= 1;
    try testing.expectError(error.InvalidMetadata, metadata.verify(&graph, &plan));
}

test "Ohaimark deopt metadata rejects malformed frame values" {
    var builder = Builder.init(testing.allocator);
    defer builder.deinit();
    const lhs = try builder.reserveRegister();
    try builder.emitLoadSmi(span, std.math.maxInt(i32));
    try builder.emitStoreReg(span, lhs);
    try builder.emitLoadSmi(span, 1);
    try builder.emitOp(.add, span);
    try builder.emitU8(lhs);
    var chunk = try finish(&builder);
    defer chunk.deinit(testing.allocator);

    var graph = try ir.Graph.build(testing.allocator, &chunk);
    defer graph.deinit();
    var plan = try specialize.Plan.build(testing.allocator, &graph);
    defer plan.deinit();
    const add_id = findNode(&graph, .add).?;
    const state_id = graph.nodes[add_id].frame_state.?;
    const state = graph.frame_states[state_id];
    const original_value = graph.frame_slots[state.slot_start].value;
    graph.frame_slots[state.slot_start].value = std.math.maxInt(ir.ValueId);
    try testing.expectError(
        error.MalformedGraph,
        deopt.Metadata.build(testing.allocator, &graph, &plan),
    );
    graph.frame_slots[state.slot_start].value = original_value;
    graph.frame_states[state_id].block = std.math.maxInt(u32);
    try testing.expectError(
        error.MalformedGraph,
        deopt.Metadata.build(testing.allocator, &graph, &plan),
    );
}

test "Ohaimark specialization records pointer-free named-load assumptions" {
    var builder = Builder.init(testing.allocator);
    defer builder.deinit();
    const receiver = try builder.reserveRegister();
    try builder.emitLoadReg(span, receiver);
    try builder.emitLdaProperty(span, 0);
    var chunk = try finish(&builder);
    defer chunk.deinit(testing.allocator);
    const receiver_shape: *Shape = @ptrFromInt(0x7000);
    chunk.inline_load_caches[0].fillOwnData(receiver_shape, 7);

    var graph = try ir.Graph.build(testing.allocator, &chunk);
    defer graph.deinit();
    var plan = try specialize.Plan.build(testing.allocator, &graph);
    defer plan.deinit();
    const load_id = findNode(&graph, .load_named).?;
    const hot = plan.node_info[load_id];
    try testing.expectEqual(specialize.Lowering.load_named_own, hot.lowering);
    const assumption = plan.assumptions[hot.assumption.?];
    try testing.expect(!@hasField(specialize.Assumption, "proto"));
    try testing.expectEqual(@as(u16, 0), assumption.feedback_index);
    try testing.expectEqual(receiver_shape, assumption.receiver_shape);
    try testing.expectEqual(@as(u32, 7), assumption.slot);
    var hot_metadata = try deopt.Metadata.build(testing.allocator, &graph, &plan);
    defer hot_metadata.deinit();
    try hot_metadata.verify(&graph, &plan);
    try testing.expectEqual(@as(usize, 1), hot_metadata.points.len);
    try testing.expectEqual(load_id, hot_metadata.points[0].node);
    var hot_decoded = try hot_metadata.decode(testing.allocator, 0);
    defer hot_decoded.deinit();
    try testing.expectEqual(
        deopt.Recovery{ .value = graph.nodeInputs(load_id)[0] },
        hot_decoded.accumulator,
    );

    // A later compile observes the invalidated live cell and stays generic.
    // Already-produced code must guard through the same cell index above.
    chunk.inline_load_caches[0].invalidate();
    var cold_graph = try ir.Graph.build(testing.allocator, &chunk);
    defer cold_graph.deinit();
    var cold_plan = try specialize.Plan.build(testing.allocator, &cold_graph);
    defer cold_plan.deinit();
    const cold_load = findNode(&cold_graph, .load_named).?;
    try testing.expectEqual(specialize.Lowering.load_named_generic, cold_plan.node_info[cold_load].lowering);
    try testing.expectEqual(@as(?u32, null), cold_plan.node_info[cold_load].assumption);

    const holder_shape: *Shape = @ptrFromInt(0x8000);
    const proto: *JSObject = @ptrFromInt(0x9000);
    chunk.inline_load_caches[0].fillPrototypeData(receiver_shape, 8, proto, holder_shape, 21);
    var prototype_graph = try ir.Graph.build(testing.allocator, &chunk);
    defer prototype_graph.deinit();
    var prototype_plan = try specialize.Plan.build(testing.allocator, &prototype_graph);
    defer prototype_plan.deinit();
    const prototype_load = findNode(&prototype_graph, .load_named).?;
    const prototype_info = prototype_plan.node_info[prototype_load];
    try testing.expectEqual(specialize.Lowering.load_named_prototype, prototype_info.lowering);
    const prototype_assumption = prototype_plan.assumptions[prototype_info.assumption.?];
    try testing.expectEqual(holder_shape, prototype_assumption.holder_shape);
    try testing.expectEqual(@as(u64, 21), prototype_assumption.revision);

    chunk.inline_load_caches[0].fillSyntheticAccessor(
        receiver_shape,
        proto,
        holder_shape,
        22,
        Value.fromInt32(99),
    );
    var synthetic_graph = try ir.Graph.build(testing.allocator, &chunk);
    defer synthetic_graph.deinit();
    var synthetic_plan = try specialize.Plan.build(testing.allocator, &synthetic_graph);
    defer synthetic_plan.deinit();
    const synthetic_load = findNode(&synthetic_graph, .load_named).?;
    try testing.expectEqual(
        specialize.Lowering.load_named_synthetic,
        synthetic_plan.node_info[synthetic_load].lowering,
    );
    try testing.expect(!@hasField(specialize.Assumption, "synthetic_value"));

    const site = switch (synthetic_graph.nodes[synthetic_load].payload) {
        .named_load => |named| named,
        else => return error.TestUnexpectedResult,
    };
    synthetic_graph.nodes[synthetic_load].payload = .{ .named_load = .{
        .key_constant = site.key_constant,
        .feedback_index = std.math.maxInt(u16),
    } };
    try testing.expectError(
        error.MalformedGraph,
        specialize.Plan.build(testing.allocator, &synthetic_graph),
    );
}

test "Ohaimark specialization preserves negative zero multiplication" {
    var builder = Builder.init(testing.allocator);
    defer builder.deinit();
    const lhs = try builder.reserveRegister();
    try builder.emitLoadSmi(span, -1);
    try builder.emitStoreReg(span, lhs);
    try builder.emitLoadSmi(span, 0);
    try builder.emitOp(.mul, span);
    try builder.emitU8(lhs);
    var chunk = try finish(&builder);
    defer chunk.deinit(testing.allocator);

    var graph = try ir.Graph.build(testing.allocator, &chunk);
    defer graph.deinit();
    var plan = try specialize.Plan.build(testing.allocator, &graph);
    defer plan.deinit();
    const info = plan.node_info[findNode(&graph, .mul).?];
    try testing.expect(info.result_type.eql(specialize.Type.number));
    try testing.expectEqual(specialize.Lowering.checked_int32_mul, info.lowering);
    try testing.expectEqual(@as(?ir.Immediate, null), info.folded);
}

test "Ohaimark value facts converge across loop phis" {
    var builder = Builder.init(testing.allocator);
    defer builder.deinit();
    const counter = try builder.reserveRegister();
    try builder.emitOp(.lda_zero, span);
    try builder.emitStoreReg(span, counter);
    try builder.emitOp(.lda_true, span);
    const header_target = builder.here();
    try builder.emitOp(.jmp_if_false, span);
    const exit_patch = builder.here();
    try builder.emitI16(0);
    try builder.emitAddSmi(span, counter, 1);
    try builder.emitStoreReg(span, counter);
    try builder.emitOp(.lda_true, span);
    try builder.emitOp(.jmp, span);
    const back_patch = builder.here();
    try builder.emitI16(0);
    const exit_target = builder.here();
    try builder.emitLoadReg(span, counter);
    try builder.emitOp(.return_, span);
    try builder.patchI16(exit_patch, exit_target);
    try builder.patchI16(back_patch, header_target);
    var chunk = try builder.finish();
    defer chunk.deinit(testing.allocator);

    var graph = try ir.Graph.build(testing.allocator, &chunk);
    defer graph.deinit();
    var plan = try specialize.Plan.build(testing.allocator, &graph);
    defer plan.deinit();
    var header: ?usize = null;
    for (graph.blocks, 0..) |block, index| {
        if (block.predecessor_count == 2) header = index;
    }
    for (graph.blockParams(header.?)) |param| switch (param.role) {
        .register => |register| if (register == counter) {
            try testing.expect(plan.node_info[param.value].result_type.eql(specialize.Type.number));
            try testing.expectEqual(@as(?ir.Immediate, null), plan.node_info[param.value].folded);
            return;
        },
        else => {},
    };
    return error.TestExpectedEqual;
}
