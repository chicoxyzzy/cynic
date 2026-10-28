const std = @import("std");
const ir = @import("ir.zig");
const allocation = @import("allocation.zig");
const native = @import("native.zig");
const CodeAllocator = @import("../code_alloc.zig").CodeAllocator;
const a = std.testing.allocator;
const unoptimized = @import("optimize.zig").Options{
    .constant_folding = false,
    .common_subexpression_elimination = false,
    .dead_code_elimination = false,
};

const guarded: ir.Graph = .{
    .types = &(.{ ir.Type.i32, ir.Type.i32 } ++ @as([9]ir.Type, @splat(.i64)) ++ .{ir.Type.i32}),
    .argument_types = &.{ .i32, .i32, .i64 },
    .result_type = .i64,
    .blocks = &.{
        .{ .params = &.{ 0, 1, 2 }, .nodes = &.{
            .{ .op = .constant, .out = 3, .immediate = 7 },
            .{ .op = .constant, .out = 4, .immediate = 0xffff_0000_0000_0000 },
            .{ .op = .constant, .out = 5, .immediate = 0x1234_5678_9abc_def0 },
            .{ .op = .add, .out = 6, .lhs = 2, .rhs = 3 },
            .{ .op = .sub, .out = 7, .lhs = 3, .rhs = 2 },
            .{ .op = .guard, .lhs = 0, .exit = .{ .id = 19, .values = &.{ 3, 4, 5, 3, 6, 7 } } },
        }, .terminator = .{ .branch = .{
            .condition = 1,
            .taken = .{ .target = 1, .args = &.{ 3, 4, 5 } },
            .fallthrough = .{ .target = 1, .args = &.{ 4, 3, 5 } },
        } } },
        .{ .params = &.{ 8, 9, 10 }, .nodes = &.{
            .{ .op = .constant, .out = 11, .immediate = 0 },
            .{ .op = .guard, .lhs = 11, .exit = .{ .id = 20, .values = &.{ 8, 9, 10, 8 } } },
        }, .terminator = .{ .return_ = 8 } },
    },
};

test "backend rematerialization: only single-lane literals are cheap and dead constants stay homeless" {
    const Case = struct { bits: u64, cheap: bool };
    for ([_]Case{
        .{ .bits = 0, .cheap = true },
        .{ .bits = 0xffff, .cheap = true },
        .{ .bits = 0xffff_0000, .cheap = true },
        .{ .bits = 0xffff_0000_0000, .cheap = true },
        .{ .bits = 0xffff_0000_0000_0000, .cheap = true },
        .{ .bits = 0x0001_0001, .cheap = false },
        .{ .bits = 0xffff_ffff, .cheap = false },
        .{ .bits = 0x1234_5678_9abc_def0, .cheap = false },
        .{ .bits = 0xffff_ffff_ffff_ffff, .cheap = false },
    }) |case| {
        const nodes = [_]ir.Node{
            .{ .op = .constant, .out = 0, .immediate = case.bits },
            .{ .op = .constant, .out = 1, .immediate = case.bits },
        };
        const blocks = [_]ir.Block{.{ .params = &.{}, .nodes = &nodes, .terminator = .{ .return_ = 0 } }};
        const graph: ir.Graph = .{ .types = &.{ .i64, .i64 }, .argument_types = &.{}, .result_type = .i64, .blocks = &blocks };
        var plan = try allocation.Plan.build(a, graph, .{ .register_count = 0 });
        defer plan.deinit();
        try std.testing.expectEqual(case.cheap, plan.locations[0] == .immediate);
        if (case.cheap) try std.testing.expectEqual(case.bits, plan.locations[0].immediate);
        try std.testing.expectEqual(@as(u32, if (case.cheap) 0 else 1), plan.spill_slot_count);
        try std.testing.expect(plan.locations[1] == .none);
    }
}

test "backend rematerialization: switches preserve both branch transfers and ordered captures" {
    if (!native.supported) return error.SkipZigTest;
    var owner = try CodeAllocator.init(a, 256 * 1024);
    defer owner.deinit();
    var oracle = try native.compileWithOptions(a, &owner, guarded, .{ .allocation = .scratch, .optimization = unoptimized });
    defer oracle.deinit();
    for ([_]bool{ false, true }) |fold| {
        for ([_]bool{ false, true }) |cse| {
            for ([_]bool{ false, true }) |dce| {
                for ([_]bool{ false, true }) |enabled| {
                    for ([_]u8{ 0, 1, 4 }) |registers| {
                        var code = try native.compileWithOptions(a, &owner, guarded, .{
                            .register_count = registers,
                            .rematerialize_constants = enabled,
                            .optimization = .{ .constant_folding = fold, .common_subexpression_elimination = cse, .dead_code_elimination = dce },
                        });
                        defer code.deinit();
                        for ([_][3]u64{ .{ 0, 0, 10 }, .{ 0, 1, 0xffff_ffff_ffff_ffff }, .{ 1, 0, 10 }, .{ 1, 1, 10 } }) |args| {
                            var expected = try oracle.runOutcome(&args, 2);
                            defer expected.deinit();
                            var actual = try code.runOutcome(&args, 2);
                            defer actual.deinit();
                            try std.testing.expect(actual == .exited);
                            try std.testing.expectEqual(expected.exited.id, actual.exited.id);
                            try std.testing.expectEqualSlices(u64, expected.exited.values, actual.exited.values);
                        }
                        try std.testing.expectError(error.BudgetExhausted, code.run(&.{ 1, 1, 10 }, 0));
                        try std.testing.expectError(error.BudgetExhausted, code.run(&.{ 1, 1, 10 }, 1));
                    }
                }
            }
        }
    }
}

test "backend rematerialization: verifier checks constant definitions and exact bits" {
    const graph: ir.Graph = .{
        .types = &.{ .i64, .i64, .i64, .i64, .i64 },
        .argument_types = &.{.i64},
        .result_type = .i64,
        .blocks = &.{.{ .params = &.{0}, .nodes = &.{
            .{ .op = .constant, .out = 1, .immediate = 7 },
            .{ .op = .constant, .out = 2, .immediate = 7 },
            .{ .op = .add, .out = 3, .lhs = 0, .rhs = 1 },
            .{ .op = .add, .out = 4, .lhs = 3, .rhs = 2 },
        }, .terminator = .{ .return_ = 4 } }},
    };
    var plan = try allocation.Plan.build(a, graph, .{});
    defer plan.deinit();
    try std.testing.expectEqual(@as(u64, 7), plan.locations[1].immediate);
    try std.testing.expectEqual(@as(u64, 7), plan.locations[2].immediate);
    try plan.verify(graph);
    plan.locations[1] = .{ .immediate = 8 };
    try std.testing.expectError(error.InvalidAllocation, plan.verify(graph));
    plan.locations[1] = .{ .immediate = 7 };
    for ([_]usize{ 0, 3 }) |index| {
        const saved = plan.locations[index];
        plan.locations[index] = .{ .immediate = 7 };
        try std.testing.expectError(error.InvalidAllocation, plan.verify(graph));
        plan.locations[index] = saved;
    }
    var disabled = try allocation.Plan.build(a, graph, .{ .rematerialize_constants = false, .register_count = 0 });
    defer disabled.deinit();
    try std.testing.expect(disabled.locations[1] == .spill);
    var scratch = try allocation.Plan.build(a, graph, .{ .mode = .scratch });
    defer scratch.deinit();
    for (scratch.locations) |location| try std.testing.expect(location == .spill);
}

test "backend rematerialization: typed constants use either scratch operand without clobbering" {
    if (!native.supported) return error.SkipZigTest;
    var owner = try CodeAllocator.init(a, 256 * 1024);
    defer owner.deinit();
    for ([_]ir.Type{ .i32, .i64 }) |ty| {
        for ([_]u64{ 0, 1, 0xffff, 0x8000_0000, 0xffff_0000, 0xffff_0000_0000_0000, 0x1234_5678_9abc_def0, 0xffff_ffff_ffff_ffff }) |bits| {
            const value = ir.normalize(ty, bits);
            const types = [_]ir.Type{ ty, ty, ty, ty, ty };
            const nodes = [_]ir.Node{
                .{ .op = .constant, .out = 1, .immediate = value },
                .{ .op = .sub, .out = 2, .lhs = 0, .rhs = 1 },
                .{ .op = .sub, .out = 3, .lhs = 1, .rhs = 2 },
                .{ .op = .add, .out = 4, .lhs = 3, .rhs = 1 },
            };
            const blocks = [_]ir.Block{.{ .params = &.{0}, .nodes = &nodes, .terminator = .{ .return_ = 4 } }};
            const graph: ir.Graph = .{ .types = &types, .argument_types = types[0..1], .result_type = ty, .blocks = &blocks };
            var oracle = try native.compileWithOptions(a, &owner, graph, .{ .allocation = .scratch, .optimization = unoptimized });
            defer oracle.deinit();
            for ([_]u8{ 0, 1, 4 }) |registers| {
                for ([_]bool{ false, true }) |enabled| {
                    var code = try native.compileWithOptions(a, &owner, graph, .{ .register_count = registers, .rematerialize_constants = enabled, .optimization = unoptimized });
                    defer code.deinit();
                    for ([_]u64{ 0, 19, 0xffff_ffff, 0x8000_0000_0000_0000 }) |input| {
                        const expected = ir.normalize(ty, value *% 3 -% input);
                        try std.testing.expectEqual(expected, try oracle.run(&.{input}, 1));
                        try std.testing.expectEqual(expected, try code.run(&.{input}, 1));
                    }
                    try std.testing.expectError(error.BudgetExhausted, code.run(&.{0}, 0));
                }
            }
        }
    }
}
