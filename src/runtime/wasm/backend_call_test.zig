const std = @import("std");
const wasm = @import("wasm.zig");
const prototype = @import("backend_prototype.zig");
const native = prototype.native;
const a = std.testing.allocator;

test "backend calls: Wasm direct callees return into native arithmetic" {
    if (!native.supported) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const module: wasm.Module = .{
        .types = &.{.{ .params = &.{.i32}, .results = &.{.i32} }},
        .funcs = &.{ 0, 0 },
        .code = &.{ .{ .bytes = &.{ 0, 0x20, 0, 0x10, 1, 0x20, 0, 0x6a, 0x0b } }, .{ .bytes = &.{ 0, 0x20, 0, 0x41, 2, 0x6c, 0x0b } } },
    };
    var instance: wasm.Instance = undefined;
    try wasm.instantiate(&instance, arena.allocator(), a, &module, .{});
    defer instance.deinit();
    var graph = try prototype.lowerInstance(a, &instance, 0);
    defer graph.deinit();
    var owner = try prototype.CodeAllocator.init(a, 256 * 1024);
    defer owner.deinit();
    var code = try native.compile(a, &owner, graph.graph);
    defer code.deinit();
    try std.testing.expectEqual(@as(usize, 1), code.call_sites.len);
    for ([_]bool{ false, true }) |spasm| {
        instance.spasm_enabled = spasm;
        for ([_]u64{ 0, 7, 0x7fff_ffff, 0xffff_ffff }) |arg| {
            const expected = try wasm.invoke(&instance, a, 0, &.{arg});
            defer a.free(expected);
            var result = try prototype.runInInstance(&code, &instance, &.{arg}, 8);
            defer result.deinit();
            try std.testing.expectEqual(@as(u64, @truncate(expected[0])), result.returned);
        }
    }
}

test "backend calls: Wasm imports retain function indices and exact callback errors" {
    if (!native.supported) return error.SkipZigTest;
    const Host = struct {
        fail: bool = false,
        fn invoke(raw: ?*anyopaque, args: []const u128, results: []u128) wasm.TrapError!void {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            if (self.fail) return error.HostThrew;
            results[0] = args[0] +% 7;
        }
    };
    var host: Host = .{};
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const module: wasm.Module = .{
        .types = &.{.{ .params = &.{.i32}, .results = &.{.i32} }},
        .imports = &.{.{ .module = "host", .name = "add", .desc = .{ .func = 0 } }},
        .funcs = &.{0},
        .code = &.{.{ .bytes = &.{ 0, 0x20, 0, 0x10, 0, 0x0b } }},
    };
    var instance: wasm.Instance = undefined;
    try wasm.instantiate(&instance, arena.allocator(), a, &module, .{ .funcs = &.{.{ .host = .{ .fn_ptr = Host.invoke, .ctx = &host, .params = 1, .results = 1 } }} });
    defer instance.deinit();
    var graph = try prototype.lowerInstance(a, &instance, 1);
    defer graph.deinit();
    var owner = try prototype.CodeAllocator.init(a, 256 * 1024);
    defer owner.deinit();
    var code = try native.compile(a, &owner, graph.graph);
    defer code.deinit();
    var result = try prototype.runInInstance(&code, &instance, &.{0xffff_ffff}, 8);
    defer result.deinit();
    try std.testing.expectEqual(@as(u64, 6), result.returned);
    host.fail = true;
    try std.testing.expectError(error.HostThrew, prototype.runInInstance(&code, &instance, &.{0}, 8));
}

test "backend calls: Wasm callee growth refreshes native memory views" {
    if (!native.supported) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const module: wasm.Module = .{
        .types = &.{ .{ .params = &.{ .i32, .i32 }, .results = &.{.i32} }, .{ .params = &.{.i32}, .results = &.{.i32} } },
        .funcs = &.{ 0, 1 },
        .code = &.{ .{ .bytes = &.{ 0, 0x20, 0, 0x10, 1, 0x1a, 0x20, 1, 0x28, 0, 0, 0x0b } }, .{ .bytes = &.{ 0, 0x20, 0, 0x40, 0, 0x0b } } },
        .mems = &.{.{ .limits = .{ .min = 1, .max = 2 } }},
    };
    var instance: wasm.Instance = undefined;
    try wasm.instantiate(&instance, arena.allocator(), a, &module, .{});
    defer instance.deinit();
    instance.spasm_enabled = false;
    var graph = try prototype.lowerInstance(a, &instance, 0);
    defer graph.deinit();
    var owner = try prototype.CodeAllocator.init(a, 256 * 1024);
    defer owner.deinit();
    var code = try native.compile(a, &owner, graph.graph);
    defer code.deinit();
    var result = try prototype.runInInstance(&code, &instance, &.{ 1, wasm.PAGE_SIZE }, 8);
    defer result.deinit();
    try std.testing.expectEqual(@as(u64, 0), result.returned);
    try std.testing.expectEqual(@as(usize, 2 * wasm.PAGE_SIZE), instance.memories[0].data.len);
}

test "backend calls: Wasm callee loops remain bounded in either existing tier" {
    if (!native.supported) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const module: wasm.Module = .{
        .types = &.{.{ .params = &.{}, .results = &.{.i32} }},
        .funcs = &.{ 0, 0 },
        .code = &.{ .{ .bytes = &.{ 0, 0x10, 1, 0x0b } }, .{ .bytes = &.{ 0, 0x03, 0x40, 0x0c, 0, 0x0b, 0x00, 0x0b } } },
    };
    var instance: wasm.Instance = undefined;
    try wasm.instantiate(&instance, arena.allocator(), a, &module, .{});
    defer instance.deinit();
    var graph = try prototype.lowerInstance(a, &instance, 0);
    defer graph.deinit();
    var owner = try prototype.CodeAllocator.init(a, 256 * 1024);
    defer owner.deinit();
    var code = try native.compile(a, &owner, graph.graph);
    defer code.deinit();
    for ([_]bool{ false, true }) |spasm| {
        instance.spasm_enabled = spasm;
        try std.testing.expectError(error.StepBudgetExhausted, prototype.runInInstance(&code, &instance, &.{}, 4));
    }
}

test "backend calls: cross-instance callees retain their execution controller" {
    if (!native.supported) return error.SkipZigTest;
    const Control = struct {
        polls: usize = 0,
        fn armed(_: *anyopaque) bool {
            return true;
        }
        fn poll(raw: *anyopaque) wasm.ExecutionPoll {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.polls += 1;
            return .terminated;
        }
    };
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const provider_module: wasm.Module = .{
        .types = &.{.{ .params = &.{.i32}, .results = &.{.i32} }},
        .funcs = &.{0},
        .code = &.{.{ .bytes = &.{ 0, 0x20, 0, 0x41, 2, 0x6c, 0x0b } }},
    };
    var provider: wasm.Instance = undefined;
    try wasm.instantiate(&provider, arena.allocator(), a, &provider_module, .{});
    defer provider.deinit();
    const module: wasm.Module = .{
        .types = provider_module.types,
        .imports = &.{.{ .module = "provider", .name = "double", .desc = .{ .func = 0 } }},
        .funcs = &.{0},
        .code = &.{.{ .bytes = &.{ 0, 0x20, 0, 0x10, 0, 0x0b } }},
    };
    var instance: wasm.Instance = undefined;
    try wasm.instantiate(&instance, arena.allocator(), a, &module, .{ .funcs = &.{provider.funcRefAt(0).?} });
    defer instance.deinit();
    var graph = try prototype.lowerInstance(a, &instance, 1);
    defer graph.deinit();
    var owner = try prototype.CodeAllocator.init(a, 256 * 1024);
    defer owner.deinit();
    var code = try native.compile(a, &owner, graph.graph);
    defer code.deinit();
    for ([_]bool{ false, true }) |spasm| {
        provider.spasm_enabled = spasm;
        var result = try prototype.runInInstance(&code, &instance, &.{9}, 8);
        defer result.deinit();
        try std.testing.expectEqual(@as(u64, 18), result.returned);
        var control: Control = .{};
        provider.execution_control = .{ .ctx = &control, .poll_fn = Control.poll, .armed_fn = Control.armed };
        try std.testing.expectError(error.ExecutionTerminated, prototype.runInInstance(&code, &instance, &.{9}, 8));
        try std.testing.expectEqual(@as(usize, 1), control.polls);
        provider.execution_control = null;
    }
}
