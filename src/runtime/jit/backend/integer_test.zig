const std = @import("std");
const ir = @import("ir.zig");
const native = @import("native.zig");
const optimize = @import("optimize.zig");
const CodeAllocator = @import("../code_alloc.zig").CodeAllocator;
const a = std.testing.allocator;

test "backend integer: trap sites are verified and trapping dead results survive all passes" {
    var nodes = [_]ir.Node{
        .{ .op = .constant, .out = 0, .immediate = 8 },
        .{ .op = .constant, .out = 1, .immediate = 0 },
        .{ .op = .div_s, .out = 2, .lhs = 0, .rhs = 1, .trap_site = 0xffff_ffff },
        .{ .op = .div_s, .out = 3, .lhs = 0, .rhs = 1, .trap_site = 4 },
        .{ .op = .constant, .out = 4, .immediate = 7 },
    };
    const graph: ir.Graph = .{ .types = &@as([5]ir.Type, @splat(.i32)), .argument_types = &.{}, .result_type = .i32, .blocks = &.{.{ .params = &.{}, .nodes = &nodes, .terminator = .{ .return_ = 4 } }} };
    try graph.verify();
    nodes[2].trap_site = null;
    try std.testing.expectError(error.InvalidGraph, graph.verify());
    nodes[2].trap_site = 0xffff_ffff;
    nodes[2].op = .add;
    try std.testing.expectError(error.InvalidGraph, graph.verify());
    nodes[2].op = .div_s;
    var result = try optimize.run(a, graph, .{});
    defer result.deinit();
    try std.testing.expectEqual(@as(u32, 0), result.stats.folded_nodes);
    try std.testing.expectEqual(@as(u32, 0), result.stats.commoned_nodes);
    try std.testing.expectEqual(@as(u32, 0), result.stats.removed_nodes);
    if (!native.supported) return error.SkipZigTest;
    var owner = try CodeAllocator.init(a, 256 * 1024);
    defer owner.deinit();
    for (0..16) |flags| {
        var compiled = try native.compileWithOptions(a, &owner, graph, options(flags, 4));
        defer compiled.deinit();
        var outcome = try compiled.runOutcome(&.{}, 1);
        defer outcome.deinit();
        try std.testing.expectEqual(ir.Trap{ .reason = .division_by_zero, .site = 0xffff_ffff }, outcome.trapped);
    }
}

fn options(flags: usize, registers: u8) native.Options {
    return .{ .register_count = registers, .rematerialize_constants = flags & 8 != 0, .optimization = .{ .constant_folding = flags & 1 != 0, .common_subexpression_elimination = flags & 2 != 0, .dead_code_elimination = flags & 4 != 0 } };
}

const ordered: ir.Graph = .{
    .types = &.{ .i32, .i32, .i64, .i64, .i64 },
    .argument_types = &.{ .i32, .i32, .i64, .i64 },
    .result_type = .i64,
    .blocks = &.{.{ .params = &.{ 0, 1, 2, 3 }, .nodes = &.{
        .{ .op = .guard, .lhs = 0, .exit = .{ .id = 1, .values = &.{2} } },
        .{ .op = .div_s, .out = 4, .lhs = 2, .rhs = 3, .trap_site = 11 },
        .{ .op = .guard, .lhs = 1, .exit = .{ .id = 2, .values = &.{ 0, 1, 2, 3, 4 } } },
    }, .terminator = .{ .trap = .{ .reason = .unreachable_code, .site = 33 } } }},
};

test "backend integer: guards division and terminal traps retain execution order" {
    if (!native.supported) return error.SkipZigTest;
    var owner = try CodeAllocator.init(a, 256 * 1024);
    defer owner.deinit();
    for (0..16) |flags| for ([_]u8{ 0, 1, 4 }) |registers| {
        var compiled = try native.compileWithOptions(a, &owner, ordered, options(flags, registers));
        defer compiled.deinit();
        var before = try compiled.runOutcome(&.{ 0, 0, 8, 0 }, 1);
        defer before.deinit();
        try std.testing.expectEqual(@as(u32, 1), before.exited.id);
        var zero = try compiled.runOutcome(&.{ 1, 0, 8, 0 }, 1);
        defer zero.deinit();
        try std.testing.expectEqual(ir.Trap{ .reason = .division_by_zero, .site = 11 }, zero.trapped);
        var overflow = try compiled.runOutcome(&.{ 1, 0, 0x8000_0000_0000_0000, 0xffff_ffff_ffff_ffff }, 1);
        defer overflow.deinit();
        try std.testing.expectEqual(ir.Trap{ .reason = .integer_overflow, .site = 11 }, overflow.trapped);
        var after = try compiled.runOutcome(&.{ 1, 0, 21, 3 }, 1);
        defer after.deinit();
        try std.testing.expectEqual(@as(u32, 2), after.exited.id);
        try std.testing.expectEqualSlices(u64, &.{ 1, 0, 21, 3, 7 }, after.exited.values);
        var terminal = try compiled.runOutcome(&.{ 1, 1, 21, 3 }, 1);
        defer terminal.deinit();
        try std.testing.expectEqual(ir.Trap{ .reason = .unreachable_code, .site = 33 }, terminal.trapped);
        try std.testing.expectError(error.BudgetExhausted, compiled.run(&.{ 1, 0, 8, 0 }, 0));
    };
}

test "backend integer: fixed-register operations preserve live register homes" {
    if (!native.supported) return error.SkipZigTest;
    var owner = try CodeAllocator.init(a, 256 * 1024);
    defer owner.deinit();
    for ([_]ir.Type{ .i32, .i64 }) |ty| for ([_]ir.Op{ .div_s, .div_u, .rem_s, .rem_u, .shl, .shr_s, .shr_u, .rotl, .rotr, .clz, .ctz, .popcnt, .sext8, .sext16 }) |op| {
        const graph: ir.Graph = .{
            .types = &.{ .i32, ty, ty, ty, ty, ty },
            .argument_types = &.{ .i32, ty, ty, ty, ty },
            .result_type = ty,
            .blocks = &.{.{ .params = &.{ 0, 1, 2, 3, 4 }, .nodes = &.{
                .{ .op = op, .out = 5, .lhs = 1, .rhs = if (ir.inputCount(op) == 2) 2 else 999, .trap_site = if (ir.mayTrap(op)) 7 else null },
                .{ .op = .guard, .lhs = 0, .exit = .{ .id = 99, .values = &.{ 0, 1, 2, 3, 4, 5 } } },
            }, .terminator = .{ .return_ = 5 } }},
        };
        const args = [_]u64{ 0, ir.normalize(ty, 0xfedc_ba98_7654_3210), 7, ir.normalize(ty, 0x1234_5678_0123_4567), ir.normalize(ty, 0xaabb_ccdd_eeff_7788) };
        var oracle = try native.compileWithOptions(a, &owner, graph, .{ .allocation = .scratch, .optimization = .{ .constant_folding = false, .common_subexpression_elimination = false, .dead_code_elimination = false } });
        defer oracle.deinit();
        var expected = try oracle.runOutcome(&args, 1);
        defer expected.deinit();
        for (0..16) |flags| for ([_]u8{ 0, 1, 4 }) |registers| {
            var compiled = try native.compileWithOptions(a, &owner, graph, options(flags, registers));
            defer compiled.deinit();
            var actual = try compiled.runOutcome(&args, 1);
            defer actual.deinit();
            try std.testing.expectEqualSlices(u64, expected.exited.values, actual.exited.values);
        };
    };
}

fn allocationFailures(allocator: std.mem.Allocator, owner: *CodeAllocator) !void {
    var compiled = try native.compile(allocator, owner, ordered);
    defer compiled.deinit();
    var outcome = try compiled.runOutcome(&.{ 1, 1, 8, 0 }, 1);
    defer outcome.deinit();
    try std.testing.expectEqual(ir.Trap{ .reason = .division_by_zero, .site = 11 }, outcome.trapped);
}

test "backend integer: trap compilation and execution clean up on allocation failure" {
    if (!native.supported) return error.SkipZigTest;
    var owner = try CodeAllocator.init(a, 256 * 1024);
    defer owner.deinit();
    try std.testing.checkAllAllocationFailures(a, allocationFailures, .{&owner});
}
