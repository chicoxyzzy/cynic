const std = @import("std");
const wasm = @import("wasm.zig");
const prototype = @import("backend_prototype.zig");
const moduleBytes = @import("backend_prototype_test.zig").moduleBytes;
const a = std.testing.allocator;

const values32 = [_]u64{ 0, 0x8000_0000, 0x3f80_0000, 0xbf80_0000, 0x3fc0_0000, 0xc010_0000, 0x7f80_0000, 0xff80_0000, 0x7fc0_0000, 0x7fc0_0011, 0x7f80_0011, 1, 0x7f7f_ffff };
const values64 = [_]u64{ 0, 0x8000_0000_0000_0000, 0x3ff0_0000_0000_0000, 0xbff0_0000_0000_0000, 0x3ff8_0000_0000_0000, 0xc002_0000_0000_0000, 0x7ff0_0000_0000_0000, 0xfff0_0000_0000_0000, 0x7ff8_0000_0000_0000, 0x7ff8_0000_0000_0011, 0x7ff0_0000_0000_0011, 1, 0x7fef_ffff_ffff_ffff };

fn canonicalNaNOrNumber(ty: u8, bits: u64) bool {
    const exponent: u64 = if (ty == 0x7d) 0x7f80_0000 else 0x7ff0_0000_0000_0000;
    const fraction: u64 = if (ty == 0x7d) 0x007f_ffff else 0x000f_ffff_ffff_ffff;
    const quiet: u64 = if (ty == 0x7d) 0x0040_0000 else 0x0008_0000_0000_0000;
    return bits & exponent != exponent or bits & fraction == 0 or bits & fraction == quiet;
}

fn expectBits(ty: u8, exact_nan: bool, canonical_nan: bool, expected: u64, actual: u64) !void {
    if (exact_nan or ty == 0x7f or ty == 0x7e) return std.testing.expectEqual(expected, actual);
    const exponent: u64 = if (ty == 0x7d) 0x7f80_0000 else 0x7ff0_0000_0000_0000;
    const fraction: u64 = if (ty == 0x7d) 0x007f_ffff else 0x000f_ffff_ffff_ffff;
    const quiet: u64 = if (ty == 0x7d) 0x0040_0000 else 0x0008_0000_0000_0000;
    if (expected & exponent == exponent and expected & fraction != 0) {
        try std.testing.expectEqual(exponent, actual & exponent);
        try std.testing.expect(actual & quiet != 0);
        if (canonical_nan) try std.testing.expectEqual(quiet, actual & fraction);
    } else try std.testing.expectEqual(expected, actual);
    if (ty == 0x7d) try std.testing.expect(actual <= std.math.maxInt(u32));
}

test "backend float: scalar arithmetic comparisons and sign operations match Sarcasm" {
    if (!prototype.native.supported) return error.SkipZigTest;
    var owner = try prototype.CodeAllocator.init(a, 256 * 1024);
    defer owner.deinit();
    for ([_]u8{ 0x7d, 0x7c }) |ty| {
        const values = if (ty == 0x7d) &values32 else &values64;
        const base: u8 = if (ty == 0x7d) 0x92 else 0xa0;
        const compare_base: u8 = if (ty == 0x7d) 0x5b else 0x61;
        for (0..16) |operation| {
            const unary = operation >= 13;
            const comparison = operation >= 7 and operation < 13;
            const opcode: u8 = if (operation < 7) base + @as(u8, @intCast(operation)) else if (comparison) compare_base + @as(u8, @intCast(operation - 7)) else switch (operation) {
                13 => base - 7,
                14 => base - 6,
                else => base - 1,
            };
            const result_type: u8 = if (comparison) 0x7f else ty;
            const exact_nan = operation == 6 or operation == 13 or operation == 14;
            var arena = std.heap.ArenaAllocator.init(a);
            defer arena.deinit();
            const unary_body = [_]u8{ 0x20, 0, opcode, 0x0b };
            const binary_body = [_]u8{ 0x20, 0, 0x20, 1, opcode, 0x0b };
            const params = [_]u8{ ty, ty };
            const bytes = try moduleBytes(arena.allocator(), params[0..if (unary) @as(usize, 1) else 2], result_type, &.{}, if (unary) &unary_body else &binary_body);
            var graph = try prototype.lowerModule(a, bytes, 0);
            defer graph.deinit();
            const module = try wasm.decode(arena.allocator(), bytes);
            var instance: wasm.Instance = undefined;
            try wasm.instantiate(&instance, arena.allocator(), a, &module, .{});
            defer instance.deinit();
            instance.spasm_enabled = false;
            for ([_]u8{ 0, 1, 4 }) |registers| {
                for ([_]bool{ false, true }) |optimized| {
                    var code = try prototype.native.compileWithOptions(a, &owner, graph.graph, .{
                        .register_count = registers,
                        .rematerialize_constants = optimized,
                        .optimization = .{ .constant_folding = optimized, .common_subexpression_elimination = optimized, .dead_code_elimination = optimized },
                    });
                    defer code.deinit();
                    for (values) |left| {
                        for (values[0..if (unary) @as(usize, 1) else values.len]) |right| {
                            const args = [_]u64{ left, right };
                            const cells = [_]u128{ left, right };
                            const count: usize = if (unary) 1 else 2;
                            const expected = try wasm.invoke(&instance, a, 0, cells[0..count]);
                            defer a.free(expected);
                            const canonical_nan = canonicalNaNOrNumber(ty, left) and (unary or canonicalNaNOrNumber(ty, right));
                            try expectBits(result_type, exact_nan, canonical_nan, @intCast(expected[0]), try code.run(args[0..count], 1));
                        }
                    }
                    const args = [_]u64{ 0, 0 };
                    try std.testing.expectError(error.BudgetExhausted, code.run(args[0..if (unary) @as(usize, 1) else 2], 0));
                }
            }
        }
    }
}

test "backend float: promotion demotion and runtime reinterpretation" {
    if (!prototype.native.supported) return error.SkipZigTest;
    var owner = try prototype.CodeAllocator.init(a, 256 * 1024);
    defer owner.deinit();
    for ([_]u8{ 0x7d, 0x7c }) |ty| {
        const values = if (ty == 0x7d) &values32 else &values64;
        for ([_]bool{ false, true }) |reinterpret| {
            var arena = std.heap.ArenaAllocator.init(a);
            defer arena.deinit();
            const result_type: u8 = if (reinterpret) (if (ty == 0x7d) @as(u8, 0x7f) else 0x7e) else (if (ty == 0x7d) @as(u8, 0x7c) else 0x7d);
            // For reinterpretation, exercise both directions in one body.
            const body = [_]u8{ 0x20, 0, if (ty == 0x7d) @as(u8, 0xbe) else 0xbf, if (ty == 0x7d) @as(u8, 0xbc) else 0xbd, 0x0b };
            const convert_body = [_]u8{ 0x20, 0, if (ty == 0x7d) @as(u8, 0xbb) else 0xb6, 0x0b };
            const bytes = try moduleBytes(arena.allocator(), &.{if (reinterpret) result_type else ty}, result_type, &.{}, if (reinterpret) &body else &convert_body);
            var graph = try prototype.lowerModule(a, bytes, 0);
            defer graph.deinit();
            const module = try wasm.decode(arena.allocator(), bytes);
            var instance: wasm.Instance = undefined;
            try wasm.instantiate(&instance, arena.allocator(), a, &module, .{});
            defer instance.deinit();
            instance.spasm_enabled = false;
            for ([_]u8{ 0, 1, 4 }) |registers| {
                var code = try prototype.native.compileWithOptions(a, &owner, graph.graph, .{ .register_count = registers });
                defer code.deinit();
                for (values) |bits| {
                    const expected = try wasm.invoke(&instance, a, 0, &.{bits});
                    defer a.free(expected);
                    try expectBits(result_type, reinterpret, canonicalNaNOrNumber(ty, bits), @intCast(expected[0]), try code.run(&.{bits}, 1));
                }
            }
        }
    }
}

test "backend float: constants locals and reinterpretation preserve NaN payloads and signed zero" {
    if (!prototype.native.supported) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    for ([_]u8{ 0x7d, 0x7c }) |ty| {
        const values = if (ty == 0x7d) &values32 else &values64;
        const width: usize = if (ty == 0x7d) 4 else 8;
        for (values) |bits| {
            var body: std.ArrayList(u8) = .empty;
            try body.append(arena.allocator(), if (ty == 0x7d) 0x43 else 0x44);
            var literal: [8]u8 = undefined;
            std.mem.writeInt(u64, &literal, bits, .little);
            try body.appendSlice(arena.allocator(), literal[0..width]);
            try body.appendSlice(arena.allocator(), &.{ 0x21, 0, 0x20, 0, if (ty == 0x7d) @as(u8, 0xbc) else 0xbd, 0x0b });
            const bytes = try moduleBytes(arena.allocator(), &.{}, if (ty == 0x7d) 0x7f else 0x7e, &.{ty}, body.items);
            try std.testing.expectEqual(bits, try prototype.evaluate(a, bytes, 0, &.{}, 1));
        }
    }
}

test "backend float: mixed integer and float loop values survive backedges" {
    if (!prototype.native.supported) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    // while (n != 0) { sum += x; n -= 1; }
    const bytes = try moduleBytes(arena.allocator(), &.{ 0x7f, 0x7c }, 0x7c, &.{0x7c}, &.{
        0x02, 0x40, 0x03, 0x40, 0x20, 0,    0x45, 0x0d, 1,
        0x20, 2,    0x20, 1,    0xa0, 0x21, 2,    0x20, 0,
        0x41, 1,    0x6b, 0x21, 0,    0x0c, 0,    0x0b, 0x0b,
        0x20, 2,    0x0b,
    });
    try std.testing.expectEqual(@as(u64, @bitCast(@as(f64, 25))), try prototype.evaluate(a, bytes, 0, &.{ 10, @as(u64, @bitCast(@as(f64, 2.5))) }, 100));
    try std.testing.expectError(error.BudgetExhausted, prototype.evaluate(a, bytes, 0, &.{ 10, @as(u64, @bitCast(@as(f64, 2.5))) }, 2));
}
