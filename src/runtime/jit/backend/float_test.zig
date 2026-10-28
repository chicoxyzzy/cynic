const std = @import("std");
const ir = @import("ir.zig");
const optimize = @import("optimize.zig");
const native = @import("native.zig");
const CodeAllocator = @import("../code_alloc.zig").CodeAllocator;
const a = std.testing.allocator;

test "backend float: verifier enforces numeric domains widths and predicates" {
    const cases = [_]struct { op: ir.Op, input: ir.Type, output: ir.Type, valid: bool }{
        .{ .op = .fadd, .input = .f64, .output = .f64, .valid = true },
        .{ .op = .fadd, .input = .f32, .output = .f32, .valid = true },
        .{ .op = .fadd, .input = .f64, .output = .f32, .valid = false },
        .{ .op = .fadd, .input = .i64, .output = .i64, .valid = false },
        .{ .op = .add, .input = .f64, .output = .f64, .valid = false },
        .{ .op = .eq, .input = .f64, .output = .i32, .valid = false },
        .{ .op = .feq, .input = .f64, .output = .i32, .valid = true },
        .{ .op = .feq, .input = .f64, .output = .f64, .valid = false },
        .{ .op = .fabs, .input = .f32, .output = .f32, .valid = true },
        .{ .op = .fabs, .input = .i32, .output = .i32, .valid = false },
        .{ .op = .reinterpret, .input = .i32, .output = .f32, .valid = true },
        .{ .op = .reinterpret, .input = .f64, .output = .i64, .valid = true },
        .{ .op = .reinterpret, .input = .f64, .output = .i32, .valid = false },
        .{ .op = .reinterpret, .input = .f64, .output = .f64, .valid = false },
        .{ .op = .reinterpret, .input = .i64, .output = .i64, .valid = false },
        .{ .op = .promote_f32, .input = .f32, .output = .f64, .valid = true },
        .{ .op = .promote_f32, .input = .i32, .output = .f64, .valid = false },
        .{ .op = .demote_f64, .input = .f64, .output = .f32, .valid = true },
        .{ .op = .demote_f64, .input = .f32, .output = .f64, .valid = false },
        .{ .op = .sext_i32, .input = .f32, .output = .i64, .valid = false },
    };
    for (cases) |case| {
        const graph: ir.Graph = .{
            .types = &.{ case.input, case.output },
            .argument_types = &.{case.input},
            .result_type = case.output,
            .blocks = &.{.{ .params = &.{0}, .nodes = &.{.{ .op = case.op, .out = 1, .lhs = 0, .rhs = if (ir.inputCount(case.op) == 2) 0 else 999 }}, .terminator = .{ .return_ = 1 } }},
        };
        if (case.valid) try graph.verify() else try std.testing.expectError(error.InvalidGraph, graph.verify());
    }
    var nodes = [_]ir.Node{.{ .op = .constant, .out = 0, .immediate = 0x1_0000_0000 }};
    const graph: ir.Graph = .{ .types = &.{.f32}, .argument_types = &.{}, .result_type = .f32, .blocks = &.{.{ .params = &.{}, .nodes = &nodes, .terminator = .{ .return_ = 0 } }} };
    try std.testing.expectError(error.InvalidGraph, graph.verify());
    nodes[0].immediate = 0x8000_0000;
    try graph.verify();
}

test "backend float: optimization and guard recovery preserve typed literal bits" {
    const graph: ir.Graph = .{
        .types = &.{ .i32, .f64, .f64, .f64, .f64, .f64, .f64, .f64, .f64, .f64, .i64 },
        .argument_types = &.{.i32},
        .result_type = .f64,
        .blocks = &.{.{ .params = &.{0}, .nodes = &.{
            .{ .op = .constant, .out = 1, .immediate = 0 },
            .{ .op = .constant, .out = 2, .immediate = 0x8000_0000_0000_0000 },
            .{ .op = .constant, .out = 3, .immediate = 0x7ff0_0000_0000_0011 },
            .{ .op = .constant, .out = 4, .immediate = 0x7ff0_0000_0000_0022 },
            .{ .op = .constant, .out = 5, .immediate = 0x7ff0_0000_0000_0011 },
            .{ .op = .fadd, .out = 6, .lhs = 1, .rhs = 2 },
            .{ .op = .fadd, .out = 7, .lhs = 2, .rhs = 1 },
            .{ .op = .fadd, .out = 8, .lhs = 1, .rhs = 2 },
            .{ .op = .fneg, .out = 9, .lhs = 3, .rhs = 999 },
            .{ .op = .reinterpret, .out = 10, .lhs = 3, .rhs = 999 },
            .{ .op = .guard, .lhs = 0, .exit = .{ .id = 23, .values = &.{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 2 } } },
        }, .terminator = .{ .return_ = 9 } }},
    };
    var optimized = try optimize.run(a, graph, .{});
    defer optimized.deinit();
    try std.testing.expectEqual(@as(u32, 2), optimized.stats.commoned_nodes);
    try std.testing.expectEqual(@as(u32, 1), optimized.stats.folded_nodes);
    var additions: usize = 0;
    for (optimized.graph.blocks[0].nodes) |node| if (node.op == .fadd) {
        additions += 1;
    };
    try std.testing.expectEqual(@as(usize, 2), additions);
    if (!native.supported) return error.SkipZigTest;
    var owner = try CodeAllocator.init(a, 256 * 1024);
    defer owner.deinit();
    const expected = [_]u64{ 0, 0x8000_0000_0000_0000, 0x7ff0_0000_0000_0011, 0x7ff0_0000_0000_0022, 0x7ff0_0000_0000_0011, 0, 0, 0, 0xfff0_0000_0000_0011, 0x7ff0_0000_0000_0011, 0x8000_0000_0000_0000 };
    for (0..16) |flags| {
        for ([_]u8{ 0, 1, 4 }) |registers| {
            var code = try native.compileWithOptions(a, &owner, graph, .{
                .register_count = registers,
                .rematerialize_constants = flags & 8 != 0,
                .optimization = .{ .constant_folding = flags & 1 != 0, .common_subexpression_elimination = flags & 2 != 0, .dead_code_elimination = flags & 4 != 0 },
            });
            defer code.deinit();
            var outcome = try code.runOutcome(&.{0}, 1);
            defer outcome.deinit();
            try std.testing.expect(outcome == .exited);
            try std.testing.expectEqual(@as(u32, 23), outcome.exited.id);
            try std.testing.expectEqualSlices(u64, &expected, outcome.exited.values);
            try std.testing.expectEqual(@as(u64, 0xfff0_0000_0000_0011), try code.run(&.{1}, 1));
        }
    }
}

fn compileWithFailures(allocator: std.mem.Allocator, owner: *CodeAllocator) !void {
    const graph: ir.Graph = .{
        .types = &.{ .f64, .f64, .f64, .i32 },
        .argument_types = &.{ .f64, .f64 },
        .result_type = .i32,
        .blocks = &.{.{ .params = &.{ 0, 1 }, .nodes = &.{
            .{ .op = .fmin, .out = 2, .lhs = 0, .rhs = 1 },
            .{ .op = .fne, .out = 3, .lhs = 0, .rhs = 2 },
        }, .terminator = .{ .return_ = 3 } }},
    };
    var compiled = try native.compile(allocator, owner, graph);
    defer compiled.deinit();
    try std.testing.expectEqual(@as(u64, 1), try compiled.run(&.{ 0x7ff8_0000_0000_0000, 0 }, 1));
}

test "backend float: native emission cleans up on allocation failure" {
    if (!native.supported) return error.SkipZigTest;
    var owner = try CodeAllocator.init(a, 64 * 1024);
    defer owner.deinit();
    try std.testing.checkAllAllocationFailures(a, compileWithFailures, .{&owner});
}
