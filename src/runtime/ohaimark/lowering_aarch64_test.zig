const std = @import("std");

const chunk_mod = @import("../../bytecode/chunk.zig");
const Builder = chunk_mod.Builder;
const Chunk = chunk_mod.Chunk;
const Span = @import("../../source.zig").Span;
const allocation = @import("allocation.zig");
const deopt = @import("deopt.zig");
const deopt_physical = @import("deopt_physical.zig");
const ir = @import("ir.zig");
const lowering = @import("lowering_aarch64.zig");
const parallel_moves = @import("parallel_moves.zig");
const representation = @import("representation.zig");
const specialize = @import("specialize.zig");

const testing = std.testing;
const span: Span = .{ .start = 0, .end = 1 };

fn finish(builder: *Builder) !Chunk {
    try builder.emitOp(.return_, span);
    return builder.finish();
}

test "Ohaimark AArch64 lowering lays out aligned representation regions" {
    const frame = try lowering.FrameLayout.build(3, 2);
    try testing.expectEqual(@as(u32, 0), try frame.taggedByteOffset(0));
    try testing.expectEqual(@as(u32, 16), try frame.taggedByteOffset(2));
    try testing.expectEqual(@as(u32, 24), try frame.int32ByteOffset(0));
    try testing.expectEqual(@as(u32, 28), try frame.int32ByteOffset(1));
    try testing.expectEqual(@as(u32, 32), frame.spill_bytes);
    try testing.expectEqual(@as(u32, 128), frame.native_frame_bytes);
    try testing.expectEqual(@as(u32, 0), frame.tagged_start);
    try testing.expectEqual(@as(u32, 24), frame.int32_start);
    try testing.expectEqual(@as(u32, 0), frame.spill_bytes % 16);

    try testing.expectEqual(lowering.value_registers[0], try lowering.valueRegister(0));
    try testing.expectEqual(lowering.value_registers[5], try lowering.valueRegister(5));
    try testing.expectError(error.UnsupportedRegisterCount, lowering.valueRegister(6));
    try testing.expectError(error.FrameTooLarge, lowering.FrameLayout.build(0, 4097));
}

test "Ohaimark parallel moves preserve cycles and fanout" {
    const a: parallel_moves.Location = .{ .register = .x23 };
    const b: parallel_moves.Location = .{ .register = .x24 };
    const spill: parallel_moves.Location = .{ .tagged_stack = 0 };
    const assignments = [_]parallel_moves.Assignment{
        .{
            .source = a,
            .destination = b,
            .source_kind = .tagged,
            .destination_kind = .tagged,
            .conversion = .none,
        },
        .{
            .source = b,
            .destination = a,
            .source_kind = .tagged,
            .destination_kind = .tagged,
            .conversion = .none,
        },
        .{
            .source = a,
            .destination = spill,
            .source_kind = .tagged,
            .destination_kind = .tagged,
            .conversion = .none,
        },
    };
    var resolved: std.ArrayListUnmanaged(parallel_moves.Move) = .empty;
    defer resolved.deinit(testing.allocator);
    try parallel_moves.resolve(
        testing.allocator,
        &assignments,
        lowering.cycle_scratch,
        &resolved,
    );
    try testing.expectEqual(@as(usize, 4), resolved.items.len);
    try testing.expectEqual(parallel_moves.Move{
        .source = a,
        .destination = spill,
        .source_kind = .tagged,
        .destination_kind = .tagged,
        .conversion = .none,
    }, resolved.items[0]);
    try testing.expectEqual(parallel_moves.Move{
        .source = a,
        .destination = .{ .register = lowering.cycle_scratch },
        .source_kind = .tagged,
        .destination_kind = .tagged,
        .conversion = .none,
    }, resolved.items[1]);
    try testing.expectEqual(parallel_moves.Move{
        .source = b,
        .destination = a,
        .source_kind = .tagged,
        .destination_kind = .tagged,
        .conversion = .none,
    }, resolved.items[2]);
    try testing.expectEqual(parallel_moves.Move{
        .source = .{ .register = lowering.cycle_scratch },
        .destination = b,
        .source_kind = .tagged,
        .destination_kind = .tagged,
        .conversion = .none,
    }, resolved.items[3]);

    resolved.clearRetainingCapacity();
    const in_place_box = [_]parallel_moves.Assignment{.{
        .source = a,
        .destination = a,
        .source_kind = .int32,
        .destination_kind = .tagged,
        .conversion = .box_int32,
    }};
    try parallel_moves.resolve(
        testing.allocator,
        &in_place_box,
        lowering.cycle_scratch,
        &resolved,
    );
    try testing.expectEqual(@as(usize, 2), resolved.items.len);
    try testing.expectEqual(representation.Conversion.none, resolved.items[0].conversion);
    try testing.expectEqual(
        parallel_moves.Location{ .register = lowering.cycle_scratch },
        resolved.items[0].destination,
    );
    try testing.expectEqual(representation.Conversion.box_int32, resolved.items[1].conversion);
    try testing.expectEqual(a, resolved.items[1].destination);

    const duplicate_destinations = [_]parallel_moves.Assignment{
        .{
            .source = a,
            .destination = spill,
            .source_kind = .tagged,
            .destination_kind = .tagged,
            .conversion = .none,
        },
        .{
            .source = b,
            .destination = spill,
            .source_kind = .tagged,
            .destination_kind = .tagged,
            .conversion = .none,
        },
    };
    try testing.expectError(
        error.InvalidParallelMove,
        parallel_moves.resolve(
            testing.allocator,
            &duplicate_destinations,
            lowering.cycle_scratch,
            &resolved,
        ),
    );
}

test "Ohaimark AArch64 lowering boxes edge values and verifies the plan" {
    var builder = Builder.init(testing.allocator);
    defer builder.deinit();
    try builder.emitOp(.lda_true, span);
    try builder.emitOp(.jmp_if_false, span);
    const else_patch = builder.here();
    try builder.emitI16(0);
    try builder.emitLoadSmi(span, 7);
    try builder.emitOp(.jmp, span);
    const join_patch = builder.here();
    try builder.emitI16(0);
    const else_target = builder.here();
    try builder.emitOp(.lda_null, span);
    const join_target = builder.here();
    try builder.patchI16(else_patch, else_target);
    try builder.patchI16(join_patch, join_target);
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
    var plan = try lowering.Plan.build(
        testing.allocator,
        &graph,
        &specialization,
        &representations,
        &homes,
        &allocated,
    );
    defer plan.deinit();
    try plan.verify(
        &graph,
        &specialization,
        &representations,
        &homes,
        &allocated,
    );
    try testing.expectEqual(graph.edges.len, plan.edges.len);
    try testing.expectEqual(allocated.tagged_slot_count, plan.frame.tagged_slot_count);
    try testing.expectEqual(allocated.int32_slot_count, plan.frame.int32_slot_count);
    try testing.expectEqual(@as(u32, 0), plan.frame.native_frame_bytes % 16);

    var saw_box = false;
    var corrupt_move: ?usize = null;
    for (plan.moves, 0..) |move, move_index| {
        try testing.expect(move.source != .none);
        try testing.expect(move.destination != .none and move.destination != .immediate);
        try testing.expect(move.conversion != .check_int32);
        if (move.conversion == .box_int32) saw_box = true;
        if (move.destination == .tagged_stack) corrupt_move = move_index;
    }
    try testing.expect(saw_box);

    const move_index = corrupt_move.?;
    const original = plan.moves[move_index];
    plan.moves[move_index].destination = .{ .register = lowering.cycle_scratch };
    try testing.expectError(
        error.InvalidLowering,
        plan.verify(
            &graph,
            &specialization,
            &representations,
            &homes,
            &allocated,
        ),
    );
    plan.moves[move_index] = original;
}
