const std = @import("std");
const wasm = @import("wasm.zig");
const prototype = @import("backend_prototype.zig");
const moduleBytes = @import("backend_prototype_test.zig").moduleBytes;
const floats = @import("backend_float_test.zig");
const a = std.testing.allocator;

fn floatValues(ty: u8) [192]u64 {
    var values: [192]u64 = undefined;
    const edges = [_]f64{ 0, -0.0, 0.5, -0.5, 1.5, -1.5, 2.5, -2.5, 1, -1, -2147483649.0, -2147483648.0, 2147483648.0, 4294967296.0, -9223372036854775808.0, 9223372036854775808.0, 18446744073709551616.0, 8388608.0, 4503599627370496.0 };
    var n: usize = 0;
    for (edges) |edge| {
        const bits: u64 = if (ty == 0x7d) @as(u32, @bitCast(@as(f32, @floatCast(edge)))) else @bitCast(edge);
        for ([_]u64{ bits -% 1, bits, bits +% 1 }) |near| {
            values[n] = if (ty == 0x7d) @as(u32, @truncate(near)) else near;
            n += 1;
        }
    }
    const special: []const u64 = if (ty == 0x7d) &.{ 0x7f80_0000, 0xff80_0000, 0x7fc0_0000, 0x7f80_0001, 0xffc0_0011, 0x7f7f_ffff } else &.{ 0x7ff0_0000_0000_0000, 0xfff0_0000_0000_0000, 0x7ff8_0000_0000_0000, 0x7ff0_0000_0000_0001, 0xfff8_0000_0000_0011, 0x7fef_ffff_ffff_ffff };
    for (special) |bits| {
        values[n] = bits;
        n += 1;
    }
    var random = std.Random.DefaultPrng.init(0x639aad);
    while (n < values.len) : (n += 1) values[n] = if (ty == 0x7d) random.random().int(u32) else random.random().int(u64);
    return values;
}

fn compare(opcode: []const u8, input: u8, output: u8, values: []const u64) !void {
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    var body: std.ArrayList(u8) = .empty;
    try body.appendSlice(arena.allocator(), &.{ 0x20, 0 });
    try body.appendSlice(arena.allocator(), opcode);
    try body.append(arena.allocator(), 0x0b);
    const bytes = try moduleBytes(arena.allocator(), &.{input}, output, &.{}, body.items);
    var graph = try prototype.lowerModule(a, bytes, 0);
    defer graph.deinit();
    const module = try wasm.decode(arena.allocator(), bytes);
    var instance: wasm.Instance = undefined;
    try wasm.instantiate(&instance, arena.allocator(), a, &module, .{});
    defer instance.deinit();
    instance.spasm_enabled = false;
    var owner = try prototype.CodeAllocator.init(a, 256 * 1024);
    defer owner.deinit();
    for ([_]u8{ 0, 1, 4 }) |registers| for ([_]bool{ false, true }) |optimized| {
        var code = try prototype.native.compileWithOptions(a, &owner, graph.graph, .{
            .register_count = registers,
            .rematerialize_constants = optimized,
            .optimization = .{ .constant_folding = optimized, .common_subexpression_elimination = optimized, .dead_code_elimination = optimized },
        });
        defer code.deinit();
        for (values) |bits| {
            const expected = wasm.invoke(&instance, a, 0, &.{bits}) catch |err| {
                try std.testing.expectError(err, code.run(&.{bits}, 1));
                continue;
            };
            defer a.free(expected);
            try floats.expectBits(output, false, if (input == 0x7d or input == 0x7c) floats.canonicalNaNOrNumber(input, bits) else true, @intCast(expected[0]), try code.run(&.{bits}, 1));
        }
        try std.testing.expectError(error.BudgetExhausted, code.run(&.{0}, 0));
    };
}

test "backend conversion: rounding matches Sarcasm at ties zeros NaNs and exponent boundaries" {
    if (!prototype.native.supported) return error.SkipZigTest;
    for ([_]u8{ 0x7d, 0x7c }) |ty| {
        const values = floatValues(ty);
        for (0..4) |operation| try compare(&.{(if (ty == 0x7d) @as(u8, 0x8d) else 0x9b) + @as(u8, @intCast(operation))}, ty, ty, &values);
    }
}

test "backend conversion: trapping and saturating truncations match Sarcasm" {
    if (!prototype.native.supported) return error.SkipZigTest;
    for (0..8) |operation| {
        const input: u8 = if (operation % 4 < 2) 0x7d else 0x7c;
        const output: u8 = if (operation < 4) 0x7f else 0x7e;
        const values = floatValues(input);
        const opcode = @as(u8, @intCast(operation)) + (if (operation < 4) @as(u8, 0xa8) else 0xaa);
        try compare(&.{opcode}, input, output, &values);
        try compare(&.{ 0xfc, @intCast(operation) }, input, output, &values);
    }
}

test "backend conversion: signed and unsigned integer to float match Sarcasm" {
    if (!prototype.native.supported) return error.SkipZigTest;
    for (0..8) |operation| {
        const input: u8 = if (operation % 4 < 2) 0x7f else 0x7e;
        const output: u8 = if (operation < 4) 0x7d else 0x7c;
        var values: [384]u64 = undefined;
        var n: usize = 0;
        // Adjacent values around exact powers catch rounding and sticky-bit loss.
        for (0..64) |shift| {
            const power = @as(u64, 1) << @as(u6, @intCast(shift));
            for ([_]u64{ power - 1, power, power +% 1 }) |value| {
                values[n] = if (input == 0x7f) @as(u32, @truncate(value)) else value;
                n += 1;
            }
        }
        values[0] = if (input == 0x7f) 0xffff_ffff else 0xffff_ffff_ffff_ffff;
        var random = std.Random.DefaultPrng.init(0xfedacc);
        while (n < values.len) : (n += 1) values[n] = if (input == 0x7f) random.random().int(u32) else random.random().int(u64);
        try compare(&.{@as(u8, @intCast(operation)) + (if (operation < 4) @as(u8, 0xb2) else 0xb3)}, input, output, &values);
    }
}

test "backend conversion: Wasm source locations survive discarded results" {
    if (!prototype.native.supported) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const bytes = try moduleBytes(arena.allocator(), &.{0x7c}, 0x7f, &.{}, &.{ 0x20, 0, 0x9b, 0xaa, 0x1a, 0x41, 7, 0x0b });
    var graph = try prototype.lowerModule(a, bytes, 0);
    defer graph.deinit();
    var owner = try prototype.CodeAllocator.init(a, 256 * 1024);
    defer owner.deinit();
    var code = try prototype.native.compile(a, &owner, graph.graph);
    defer code.deinit();
    var outcome = try code.runOutcome(&.{0x7ff8_0000_0000_0000}, 1);
    defer outcome.deinit();
    try std.testing.expectEqual(prototype.ir.Trap{ .reason = .invalid_conversion, .site = 3 }, outcome.trapped);
    try std.testing.expectEqual(@as(u64, 7), try code.run(&.{0}, 1));
    // Sub-opcodes are LEBs, not necessarily single bytes.
    const sat = try moduleBytes(arena.allocator(), &.{0x7d}, 0x7f, &.{}, &.{ 0x20, 0, 0xfc, 0x80, 0, 0x0b });
    try std.testing.expectEqual(@as(u64, 0), try prototype.evaluate(a, sat, 0, &.{0x7fc0_0000}, 1));
}
