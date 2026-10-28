const std = @import("std");
const ir = @import("ir.zig");
const native = @import("native.zig");
const CodeAllocator = @import("../code_alloc.zig").CodeAllocator;
const a = std.testing.allocator;

fn options(flags: usize, registers: u8) native.Options {
    return .{ .register_count = registers, .rematerialize_constants = flags & 8 != 0, .optimization = .{ .constant_folding = flags & 1 != 0, .common_subexpression_elimination = flags & 2 != 0, .dead_code_elimination = flags & 4 != 0 } };
}

test "backend conversion: verifier checks numeric domains and trapping metadata" {
    for ([_]ir.Op{ .convert_s, .convert_u, .trunc_s, .trunc_u, .trunc_sat_s, .trunc_sat_u }) |op| {
        for ([_]ir.Type{ .i32, .i64, .f32, .f64 }) |input| for ([_]ir.Type{ .i32, .i64, .f32, .f64 }) |output| {
            var nodes = [_]ir.Node{.{ .op = op, .out = 1, .lhs = 0, .rhs = 999, .trap_site = if (ir.mayTrap(op)) 7 else null }};
            const graph: ir.Graph = .{ .types = &.{ input, output }, .argument_types = &.{input}, .result_type = output, .blocks = &.{.{ .params = &.{0}, .nodes = &nodes, .terminator = .{ .return_ = 1 } }} };
            const to_float = op == .convert_s or op == .convert_u;
            if (ir.isFloat(input) == to_float or ir.isFloat(output) != to_float) {
                try std.testing.expectError(error.InvalidGraph, graph.verify());
            } else {
                try graph.verify();
                nodes[0].trap_site = if (nodes[0].trap_site == null) 7 else null;
                try std.testing.expectError(error.InvalidGraph, graph.verify());
            }
        };
    }
}

const ordered: ir.Graph = .{
    .types = &.{ .i32, .f64, .i32, .i32 },
    .argument_types = &.{ .i32, .f64 },
    .result_type = .i32,
    .blocks = &.{.{ .params = &.{ 0, 1 }, .nodes = &.{
        .{ .op = .guard, .lhs = 0, .exit = .{ .id = 1, .values = &.{1} } },
        .{ .op = .trunc_s, .out = 2, .lhs = 1, .trap_site = 77 },
        .{ .op = .trunc_s, .out = 3, .lhs = 1, .trap_site = 88 },
    }, .terminator = .{ .return_ = 0 } }},
};

test "backend conversion: unused checked conversions preserve first trap and guard order" {
    if (!native.supported) return error.SkipZigTest;
    var owner = try CodeAllocator.init(a, 256 * 1024);
    defer owner.deinit();
    for (0..16) |flags| for ([_]u8{ 0, 1, 4 }) |registers| {
        var code = try native.compileWithOptions(a, &owner, ordered, options(flags, registers));
        defer code.deinit();
        for ([_]u64{ 0x7ff0_0000_0000_0001, 0x7ff0_0000_0000_0000, 0xfff0_0000_0000_0000 }) |bits| {
            var before = try code.runOutcome(&.{ 0, bits }, 1);
            defer before.deinit();
            try std.testing.expectEqualSlices(u64, &.{bits}, before.exited.values);
            var trapped = try code.runOutcome(&.{ 1, bits }, 1);
            defer trapped.deinit();
            try std.testing.expectEqual(ir.Trap{ .reason = if (bits == 0x7ff0_0000_0000_0001) .invalid_conversion else .integer_overflow, .site = 77 }, trapped.trapped);
        }
        try std.testing.expectEqual(@as(u64, 1), try code.run(&.{ 1, 0xbfe0_0000_0000_0000 }, 1));
    };
}

test "backend conversion: all operations preserve live integer and float homes" {
    if (!native.supported) return error.SkipZigTest;
    var owner = try CodeAllocator.init(a, 1024 * 1024);
    defer owner.deinit();
    for ([_]ir.Op{ .convert_s, .convert_u, .trunc_s, .trunc_u, .trunc_sat_s, .trunc_sat_u, .fceil, .ffloor, .ftrunc, .fnearest }) |op| {
        const from_int = op == .convert_s or op == .convert_u;
        for ([_]bool{ false, true }) |single| for ([_]bool{ false, true }) |narrow| {
            const integer_type: ir.Type = if (narrow) .i32 else .i64;
            const float_type: ir.Type = if (single) .f32 else .f64;
            const input = if (from_int) integer_type else float_type;
            const output = if (from_int or ir.isFloatOp(op)) float_type else integer_type;
            const graph: ir.Graph = .{
                .types = &.{ .i32, input, .i64, .f64, .i64, output },
                .argument_types = &.{ .i32, input, .i64, .f64, .i64 },
                .result_type = output,
                .blocks = &.{.{ .params = &.{ 0, 1, 2, 3, 4 }, .nodes = &.{
                    .{ .op = op, .out = 5, .lhs = 1, .rhs = 999, .trap_site = if (ir.mayTrap(op)) 9 else null },
                    .{ .op = .guard, .lhs = 0, .exit = .{ .id = 4, .values = &.{ 0, 1, 2, 3, 4, 5 } } },
                }, .terminator = .{ .return_ = 5 } }},
            };
            const bits: u64 = if (from_int) ir.normalize(input, 0xffff_ffff_ffff_ffff) else if (single) 0x4060_0000 else 0x400c_0000_0000_0000;
            const args = [_]u64{ 0, bits, 0xaabb_ccdd_eeff_0011, 0xfff0_0000_0000_0011, 0x1234_5678_ffff_0000 };
            var oracle = try native.compileWithOptions(a, &owner, graph, .{ .allocation = .scratch, .optimization = .{ .constant_folding = false, .common_subexpression_elimination = false, .dead_code_elimination = false } });
            defer oracle.deinit();
            var expected = try oracle.runOutcome(&args, 1);
            defer expected.deinit();
            try std.testing.expectEqualSlices(u64, &args, expected.exited.values[0..5]);
            for (0..16) |flags| for ([_]u8{ 0, 1, 4 }) |registers| {
                var code = try native.compileWithOptions(a, &owner, graph, options(flags, registers));
                defer code.deinit();
                var actual = try code.runOutcome(&args, 1);
                defer actual.deinit();
                try std.testing.expectEqualSlices(u64, expected.exited.values, actual.exited.values);
            };
        };
    }
}

fn allocationFailures(allocator: std.mem.Allocator, owner: *CodeAllocator) !void {
    var code = try native.compile(allocator, owner, ordered);
    defer code.deinit();
    var outcome = try code.runOutcome(&.{ 1, 0x7ff8_0000_0000_0000 }, 1);
    defer outcome.deinit();
    try std.testing.expectEqual(ir.Trap{ .reason = .invalid_conversion, .site = 77 }, outcome.trapped);
}

test "backend conversion: constant operands retain checked operations and common pure operations" {
    if (!native.supported) return error.SkipZigTest;
    const graph: ir.Graph = .{
        .types = &.{ .i32, .f64, .i64, .i64, .f64, .f64, .f32, .f32 },
        .argument_types = &.{.i32},
        .result_type = .i64,
        .blocks = &.{.{ .params = &.{0}, .nodes = &.{
            .{ .op = .constant, .out = 1, .immediate = 0x3ff8_0000_0000_0000 },
            .{ .op = .trunc_s, .out = 2, .lhs = 1, .rhs = 999, .trap_site = 10 },
            .{ .op = .trunc_s, .out = 3, .lhs = 1, .rhs = 999, .trap_site = 11 },
            .{ .op = .fnearest, .out = 4, .lhs = 1, .rhs = 999 },
            .{ .op = .fnearest, .out = 5, .lhs = 1, .rhs = 999 },
            .{ .op = .convert_u, .out = 6, .lhs = 2, .rhs = 999 },
            .{ .op = .convert_u, .out = 7, .lhs = 2, .rhs = 999 },
            .{ .op = .guard, .lhs = 0, .exit = .{ .id = 5, .values = &.{ 2, 3, 4, 5, 6, 7 } } },
        }, .terminator = .{ .return_ = 2 } }},
    };
    var owner = try CodeAllocator.init(a, 256 * 1024);
    defer owner.deinit();
    for (0..16) |flags| for ([_]u8{ 0, 1, 4 }) |registers| {
        var code = try native.compileWithOptions(a, &owner, graph, options(flags, registers));
        defer code.deinit();
        try std.testing.expectEqual(@as(u32, 0), code.optimization.folded_nodes);
        try std.testing.expectEqual(@as(u32, if (flags & 2 != 0) 2 else 0), code.optimization.commoned_nodes);
        var outcome = try code.runOutcome(&.{0}, 1);
        defer outcome.deinit();
        try std.testing.expectEqualSlices(u64, &.{ 1, 1, 0x4000_0000_0000_0000, 0x4000_0000_0000_0000, 0x3f80_0000, 0x3f80_0000 }, outcome.exited.values);
    };
}

test "backend conversion: compilation and trap execution clean up on allocation failure" {
    if (!native.supported) return error.SkipZigTest;
    var owner = try CodeAllocator.init(a, 256 * 1024);
    defer owner.deinit();
    try std.testing.checkAllAllocationFailures(a, allocationFailures, .{&owner});
}
