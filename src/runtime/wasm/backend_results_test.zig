const std = @import("std");
const wasm = @import("wasm.zig");
const prototype = @import("backend_prototype.zig");
const a = std.testing.allocator;

fn compare(module: *const wasm.Module, args: []const u64, expected: []const u64) !void {
    if (!prototype.native.supported) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    var instance: wasm.Instance = undefined;
    try wasm.instantiate(&instance, arena.allocator(), a, module, .{});
    defer instance.deinit();
    var cells: [64]u128 = undefined;
    for (args, 0..) |value, i| cells[i] = value;
    for ([_]bool{ false, true }) |spasm| {
        instance.spasm_enabled = spasm;
        const result = try wasm.invoke(&instance, a, 0, cells[0..args.len]);
        defer a.free(result);
        try std.testing.expectEqual(expected.len, result.len);
        for (result, expected) |actual, value| try std.testing.expectEqual(@as(u128, value), actual);
    }
    try std.testing.expect(instance.spasm_runs != 0);
    var graph = try prototype.lowerInstance(a, &instance, 0);
    defer graph.deinit();
    var owner = try prototype.CodeAllocator.init(a, 256 * 1024);
    defer owner.deinit();
    for ([_]u8{ 0, 1, 4 }) |registers| for ([_]bool{ false, true }) |optimize| {
        var code = try prototype.native.compileWithOptions(a, &owner, graph.graph, .{ .register_count = registers, .optimization = .{ .constant_folding = optimize, .common_subexpression_elimination = optimize, .dead_code_elimination = optimize } });
        defer code.deinit();
        var values: [64]u64 = undefined;
        var completion = try prototype.runResultsInInstance(&code, &instance, args, 100, values[0..expected.len]);
        defer completion.deinit();
        try std.testing.expect(completion == .returned);
        try std.testing.expectEqualSlices(u64, expected, values[0..expected.len]);
    };
}

test "backend results: Wasm function returns mixed results through its implicit label" {
    const module: wasm.Module = .{
        .types = &.{.{ .params = &.{ .i32, .i64, .f32, .f64 }, .results = &.{ .f64, .i32, .f32, .i64, .i32 } }},
        .funcs = &.{0},
        .code = &.{.{ .bytes = &.{ 0, 0x20, 3, 0x20, 0, 0x20, 2, 0x20, 1, 0x20, 0, 0x0c, 0, 0x00, 0x0b } }},
    };
    try compare(&module, &.{ 0x8000_0000, 13, 0xffc0_0042, 0xfff8_0000_0000_0042 }, &.{ 0xfff8_0000_0000_0042, 0x8000_0000, 0xffc0_0042, 13, 0x8000_0000 });
}

test "backend results: Wasm void calls and function returns execute natively" {
    const module: wasm.Module = .{
        .types = &.{.{ .params = &.{.i32}, .results = &.{} }},
        .funcs = &.{ 0, 0 },
        .code = &.{
            .{ .bytes = &.{ 0, 0x20, 0, 0x10, 1, 0x0c, 0, 0x00, 0x0b } },
            .{ .bytes = &.{ 0, 0x20, 0, 0x04, 0x40, 0x0f, 0x0b, 0x0b } },
        },
    };
    try compare(&module, &.{0}, &.{});
    try compare(&module, &.{1}, &.{});
}

test "backend results: Wasm direct multi-result calls return into native arithmetic" {
    const module: wasm.Module = .{
        .types = &.{.{ .params = &.{.i32}, .results = &.{ .i32, .i64 } }},
        .funcs = &.{ 0, 0 },
        .code = &.{
            .{ .bytes = &.{ 0, 0x20, 0, 0x10, 1, 0x42, 7, 0x7c, 0x0b } },
            .{ .bytes = &.{ 0, 0x20, 0, 0x20, 0, 0xad, 0x0b } },
        },
    };
    try compare(&module, &.{42}, &.{ 42, 49 });
    try compare(&module, &.{0xffff_ffff}, &.{ 0xffff_ffff, 0x1_0000_0006 });
}

test "backend results: imported result lists retain types and exact callback errors" {
    if (!prototype.native.supported) return error.SkipZigTest;
    const Host = struct {
        calls: usize = 0,
        fail: bool = false,
        fn invoke(raw: ?*anyopaque, args: []const u128, results: []u128) wasm.TrapError!void {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            self.calls += 1;
            results[0] = args[0] | (@as(u128, 1) << 100);
            results[1] = 0xfff8_0000_0000_0042;
            if (self.fail) return error.HostThrew;
        }
    };
    var host: Host = .{};
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const module: wasm.Module = .{
        .types = &.{.{ .params = &.{.i32}, .results = &.{ .i32, .f64 } }},
        .imports = &.{.{ .module = "host", .name = "pair", .desc = .{ .func = 0 } }},
        .funcs = &.{0},
        .code = &.{.{ .bytes = &.{ 0, 0x20, 0, 0x10, 0, 0x0b } }},
    };
    var instance: wasm.Instance = undefined;
    try wasm.instantiate(&instance, arena.allocator(), a, &module, .{ .funcs = &.{.{ .host = .{ .fn_ptr = Host.invoke, .ctx = &host, .params = 1, .results = 2 } }} });
    defer instance.deinit();
    var graph = try prototype.lowerInstance(a, &instance, 1);
    defer graph.deinit();
    var owner = try prototype.CodeAllocator.init(a, 64 * 1024);
    defer owner.deinit();
    var code = try prototype.native.compile(a, &owner, graph.graph);
    defer code.deinit();
    try std.testing.expectError(error.ResultCount, prototype.runInInstance(&code, &instance, &.{42}, 10));
    try std.testing.expectEqual(@as(usize, 0), host.calls);
    var values: [2]u64 = undefined;
    var result = try prototype.runResultsInInstance(&code, &instance, &.{42}, 10, &values);
    defer result.deinit();
    try std.testing.expect(result == .returned);
    try std.testing.expectEqualSlices(u64, &.{ 42, 0xfff8_0000_0000_0042 }, &values);
    host.fail = true;
    @memset(&values, 99);
    try std.testing.expectError(error.HostThrew, prototype.runResultsInInstance(&code, &instance, &.{42}, 10, &values));
    try std.testing.expectEqualSlices(u64, &.{ 99, 99 }, &values);
}

test "backend results: cross-instance multi-result calls preserve defining instance execution" {
    if (!prototype.native.supported) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const provider_module: wasm.Module = .{
        .types = &.{.{ .params = &.{.i32}, .results = &.{ .i32, .i64 } }},
        .funcs = &.{0},
        .code = &.{.{ .bytes = &.{ 0, 0x20, 0, 0x42, 7, 0x0b } }},
    };
    var provider: wasm.Instance = undefined;
    try wasm.instantiate(&provider, arena.allocator(), a, &provider_module, .{});
    defer provider.deinit();
    const module: wasm.Module = .{
        .types = provider_module.types,
        .imports = &.{.{ .module = "provider", .name = "pair", .desc = .{ .func = 0 } }},
        .funcs = &.{0},
        .code = &.{.{ .bytes = &.{ 0, 0x20, 0, 0x10, 0, 0x0b } }},
    };
    var instance: wasm.Instance = undefined;
    try wasm.instantiate(&instance, arena.allocator(), a, &module, .{ .funcs = &.{provider.funcRefAt(0).?} });
    defer instance.deinit();
    var graph = try prototype.lowerInstance(a, &instance, 1);
    defer graph.deinit();
    var owner = try prototype.CodeAllocator.init(a, 64 * 1024);
    defer owner.deinit();
    var code = try prototype.native.compile(a, &owner, graph.graph);
    defer code.deinit();
    for ([_]bool{ false, true }) |spasm| {
        provider.spasm_enabled = spasm;
        var values: [2]u64 = undefined;
        var result = try prototype.runResultsInInstance(&code, &instance, &.{42}, 10, &values);
        defer result.deinit();
        try std.testing.expect(result == .returned);
        try std.testing.expectEqualSlices(u64, &.{ 42, 7 }, &values);
    }
    try std.testing.expectEqual(@as(u32, 1), provider.spasm_runs);
}

test "backend results: module byte decoding accepts void and multi-result entry signatures" {
    if (!prototype.native.supported) return error.SkipZigTest;
    const modules = [_][]const u8{
        &.{ 0, 0x61, 0x73, 0x6d, 1, 0, 0, 0, 1, 4, 1, 0x60, 0, 0, 3, 2, 1, 0, 10, 4, 1, 2, 0, 0x0b },
        &.{ 0, 0x61, 0x73, 0x6d, 1, 0, 0, 0, 1, 6, 1, 0x60, 0, 2, 0x7f, 0x7e, 3, 2, 1, 0, 10, 8, 1, 6, 0, 0x41, 42, 0x42, 7, 0x0b },
    };
    var owner = try prototype.CodeAllocator.init(a, 64 * 1024);
    defer owner.deinit();
    for (modules, 0..) |bytes, i| {
        var graph = try prototype.lowerModule(a, bytes, 0);
        defer graph.deinit();
        var code = try prototype.native.compile(a, &owner, graph.graph);
        defer code.deinit();
        var values: [2]u64 = undefined;
        var result = try code.runInto(&.{}, &.{}, 1, null, values[0 .. i * 2]);
        defer result.deinit();
        try std.testing.expect(result == .returned);
        if (i == 1) try std.testing.expectEqualSlices(u64, &.{ 42, 7 }, &values);
    }
}
