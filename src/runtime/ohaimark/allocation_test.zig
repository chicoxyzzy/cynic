const std = @import("std");

const chunk_mod = @import("../../bytecode/chunk.zig");
const Builder = chunk_mod.Builder;
const Chunk = chunk_mod.Chunk;
const Span = @import("../../source.zig").Span;
const allocation = @import("allocation.zig");
const deopt = @import("deopt.zig");
const deopt_physical = @import("deopt_physical.zig");
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

test "Ohaimark allocation bounds registers and partitions spills" {
    var builder = Builder.init(testing.allocator);
    defer builder.deinit();
    const r0 = try builder.reserveRegister();
    const r1 = try builder.reserveRegister();
    const r2 = try builder.reserveRegister();
    const r3 = try builder.reserveRegister();
    try builder.emitLoadReg(span, r0);
    try builder.emitOp(.strict_eq, span);
    try builder.emitU8(r1);
    try builder.emitOp(.strict_eq, span);
    try builder.emitU8(r2);
    try builder.emitOp(.strict_eq, span);
    try builder.emitU8(r3);
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
    try testing.expectEqual(@as(u32, 0), homes.tagged_slot_count);
    try testing.expectEqual(@as(u32, 0), homes.int32_slot_count);

    var plan = try allocation.Plan.build(
        testing.allocator,
        &graph,
        &specialization,
        &representations,
        &homes,
        .{ .register_count = 1 },
    );
    defer plan.deinit();
    try plan.verify(&graph, &specialization, &representations, &homes);
    try testing.expectEqual(@as(u8, 1), plan.register_count);
    try testing.expect(plan.tagged_slot_count >= 2);
    try testing.expectEqual(@as(u32, 0), plan.int32_slot_count);

    var register_values: usize = 0;
    var tagged_spills: usize = 0;
    var register_value: ?ir.ValueId = null;
    var tagged_value: ?ir.ValueId = null;
    for (plan.locations, 0..) |location, value_id| switch (location) {
        .register => |register| {
            try testing.expect(register < plan.register_count);
            register_values += 1;
            register_value = @intCast(value_id);
        },
        .tagged_stack => |slot| {
            try testing.expect(slot < plan.tagged_slot_count);
            tagged_spills += 1;
            tagged_value = @intCast(value_id);
        },
        .int32_stack => return error.TestUnexpectedResult,
        .none, .immediate => {},
    };
    try testing.expect(register_values > 0);
    try testing.expect(tagged_spills >= 2);
    try testing.expect(tagged_spills > plan.tagged_slot_count);

    const value_id = register_value.?;
    const original = plan.locations[value_id];
    plan.locations[value_id] = .{ .register = plan.register_count };
    try testing.expectError(
        error.InvalidAllocation,
        plan.verify(&graph, &specialization, &representations, &homes),
    );
    plan.locations[value_id] = original;

    const spilled_value = tagged_value.?;
    const spilled_original = plan.locations[spilled_value];
    plan.locations[spilled_value] = .{ .tagged_stack = plan.tagged_slot_count };
    try testing.expectError(
        error.InvalidAllocation,
        plan.verify(&graph, &specialization, &representations, &homes),
    );
    plan.locations[spilled_value] = spilled_original;
}

test "Ohaimark allocation rematerializes constants and reuses deopt homes" {
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
    try testing.expectEqual(@as(u32, 1), homes.int32_slot_count);

    var plan = try allocation.Plan.build(
        testing.allocator,
        &graph,
        &specialization,
        &representations,
        &homes,
        .{ .register_count = 0 },
    );
    defer plan.deinit();
    try plan.verify(&graph, &specialization, &representations, &homes);

    var decoded = try logical.decode(testing.allocator, 0);
    defer decoded.deinit();
    const phi_value = switch (decoded.slots[0].recovery) {
        .value => |value| value,
        .immediate => return error.TestUnexpectedResult,
    };
    try testing.expectEqual(
        allocation.Location{ .int32_stack = 0 },
        plan.locations[phi_value],
    );

    const constant_id = findNode(&graph, .constant).?;
    try testing.expect(plan.locations[constant_id] == .immediate);
    const return_id = findNode(&graph, .return_).?;
    const return_input = try plan.nodeInput(&graph, &representations, return_id, 0);
    try testing.expectEqual(representation.Conversion.box_int32, return_input.conversion);
    try testing.expect(return_input.source == .int32_stack);
    try testing.expect(plan.int32_slot_count > homes.int32_slot_count);
}
