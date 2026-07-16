const std = @import("std");

const chunk_mod = @import("../../bytecode/chunk.zig");
const Builder = chunk_mod.Builder;
const Chunk = chunk_mod.Chunk;
const Op = @import("../../bytecode/op.zig").Op;
const Span = @import("../../source.zig").Span;
const JSFunction = @import("../function.zig").JSFunction;
const JSObject = @import("../object.zig").JSObject;
const Shape = @import("../shape.zig").Shape;
const feedback = @import("feedback.zig");
const ir = @import("ir.zig");

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
