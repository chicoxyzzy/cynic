const std = @import("std");
const wasm = @import("wasm.zig");
const prototype = @import("backend_prototype.zig");
const moduleBytes = @import("backend_prototype_test.zig").moduleBytes;
const a = std.testing.allocator;

test "backend integer: division traps are normal outcomes even when the value is discarded" {
    if (!prototype.native.supported) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const bytes = try moduleBytes(arena.allocator(), &.{ 0x7f, 0x7f }, 0x7f, &.{}, &.{ 0x20, 0, 0x20, 1, 0x6d, 0x1a, 0x41, 7, 0x0b });
    try std.testing.expectEqual(@as(u64, 7), try prototype.evaluate(a, bytes, 0, &.{ 8, 2 }, 1));
    try std.testing.expectError(error.IntegerDivideByZero, prototype.evaluate(a, bytes, 0, &.{ 8, 0 }, 1));
    try std.testing.expectError(error.IntegerOverflow, prototype.evaluate(a, bytes, 0, &.{ 0x8000_0000, 0xffff_ffff }, 1));
}

test "backend integer: unreachable executes as a bounded native trap" {
    if (!prototype.native.supported) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const bytes = try moduleBytes(arena.allocator(), &.{}, 0x7f, &.{}, &.{ 0x00, 0x0b });
    try std.testing.expectError(error.Unreachable, prototype.evaluate(a, bytes, 0, &.{}, 1));
    try std.testing.expectError(error.BudgetExhausted, prototype.evaluate(a, bytes, 0, &.{}, 0));
}

test "backend integer: source offsets and untaken traps remain precise" {
    if (!prototype.native.supported) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    var owner = try prototype.CodeAllocator.init(a, 64 * 1024);
    defer owner.deinit();
    const bytes = try moduleBytes(arena.allocator(), &.{0x7f}, 0x7f, &.{}, &.{ 0x02, 0x40, 0x20, 0, 0x0d, 0, 0x00, 0x0b, 0x41, 7, 0x0b });
    var graph = try prototype.lowerModule(a, bytes, 0);
    defer graph.deinit();
    var compiled = try prototype.native.compile(a, &owner, graph.graph);
    defer compiled.deinit();
    try std.testing.expectEqual(@as(u64, 7), try compiled.run(&.{1}, 3));
    var outcome = try compiled.runOutcome(&.{0}, 3);
    defer outcome.deinit();
    try std.testing.expectEqual(prototype.ir.Trap{ .reason = .unreachable_code, .site = 6 }, outcome.trapped);
    const dead = try moduleBytes(arena.allocator(), &.{}, 0x7f, &.{}, &.{ 0x41, 1, 0x0f, 0x00, 0x0b });
    try std.testing.expectEqual(@as(u64, 1), try prototype.evaluate(a, dead, 0, &.{}, 1));
}

const inputs = [_]u64{ 0, 1, 2, 31, 32, 63, 64, 65, 0xffff_ffff, 0x8000_0000, 0x7fff_ffff, 0x1234_5678_9abc_def0, 0x8000_0000_0000_0000, 0x7fff_ffff_ffff_ffff, 0xffff_ffff_ffff_ffff };

test "backend integer: complete scalar integer operations match Sarcasm" {
    if (!prototype.native.supported) return error.SkipZigTest;
    var owner = try prototype.CodeAllocator.init(a, 256 * 1024);
    defer owner.deinit();
    for ([_]u8{ 0x7f, 0x7e }) |ty| {
        for (0..29) |operation| {
            const compare = operation >= 18;
            const unary = operation < 3 or operation == 18;
            const opcode: u8 = if (compare)
                (if (ty == 0x7f) @as(u8, 0x45) else 0x50) + @as(u8, @intCast(operation - 18))
            else
                (if (ty == 0x7f) @as(u8, 0x67) else 0x79) + @as(u8, @intCast(operation));
            const unary_body = [_]u8{ 0x20, 0, opcode, 0x0b };
            const binary_body = [_]u8{ 0x20, 0, 0x20, 1, opcode, 0x0b };
            var arena = std.heap.ArenaAllocator.init(a);
            defer arena.deinit();
            const params = [_]u8{ ty, ty };
            const count: usize = if (unary) 1 else 2;
            const bytes = try moduleBytes(arena.allocator(), params[0..count], if (compare) 0x7f else ty, &.{}, if (unary) &unary_body else &binary_body);
            var graph = try prototype.lowerModule(a, bytes, 0);
            defer graph.deinit();
            const module = try wasm.decode(arena.allocator(), bytes);
            var instance: wasm.Instance = undefined;
            try wasm.instantiate(&instance, arena.allocator(), a, &module, .{});
            defer instance.deinit();
            instance.spasm_enabled = false;
            for ([_]u8{ 0, 1, 4 }) |registers| for ([_]bool{ false, true }) |optimized| {
                var compiled = try prototype.native.compileWithOptions(a, &owner, graph.graph, .{
                    .register_count = registers,
                    .rematerialize_constants = optimized,
                    .optimization = .{ .constant_folding = optimized, .common_subexpression_elimination = optimized, .dead_code_elimination = optimized },
                });
                defer compiled.deinit();
                for (inputs) |left| for (inputs[0..if (unary) 1 else inputs.len]) |right| {
                    const args = [_]u64{ left, right };
                    const cells = [_]u128{ left, right };
                    if (wasm.invoke(&instance, a, 0, cells[0..count])) |expected| {
                        defer a.free(expected);
                        try std.testing.expectEqual(@as(u64, @intCast(expected[0])), try compiled.run(args[0..count], 1));
                    } else |err| try std.testing.expectError(err, compiled.run(args[0..count], 1));
                };
            };
        }
    }
}

test "backend integer: width and sign extensions match Sarcasm" {
    if (!prototype.native.supported) return error.SkipZigTest;
    const cases = [_]struct { input: u8, output: u8, opcode: u8 }{
        .{ .input = 0x7e, .output = 0x7f, .opcode = 0xa7 },
        .{ .input = 0x7f, .output = 0x7e, .opcode = 0xac },
        .{ .input = 0x7f, .output = 0x7e, .opcode = 0xad },
        .{ .input = 0x7f, .output = 0x7f, .opcode = 0xc0 },
        .{ .input = 0x7f, .output = 0x7f, .opcode = 0xc1 },
        .{ .input = 0x7e, .output = 0x7e, .opcode = 0xc2 },
        .{ .input = 0x7e, .output = 0x7e, .opcode = 0xc3 },
        .{ .input = 0x7e, .output = 0x7e, .opcode = 0xc4 },
    };
    for (cases) |case| {
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        const bytes = try moduleBytes(arena.allocator(), &.{case.input}, case.output, &.{}, &.{ 0x20, 0, case.opcode, 0x0b });
        const module = try wasm.decode(arena.allocator(), bytes);
        var instance: wasm.Instance = undefined;
        try wasm.instantiate(&instance, arena.allocator(), a, &module, .{});
        defer instance.deinit();
        instance.spasm_enabled = false;
        for (inputs ++ [_]u64{ 0x80, 0x7f, 0x8000, 0x7fff }) |bits| {
            const expected = try wasm.invoke(&instance, a, 0, &.{bits});
            defer a.free(expected);
            try std.testing.expectEqual(@as(u64, @intCast(expected[0])), try prototype.evaluate(a, bytes, 0, &.{bits}, 1));
        }
    }
}
