const std = @import("std");
const wasm = @import("wasm.zig");
const a = std.testing.allocator;
const prototype = wasm.backend_prototype;

fn expectResult(instance: *wasm.Instance, index: u32, args: []const u128, expected: []const u128) !void {
    const result = try wasm.invoke(instance, a, index, args);
    defer a.free(result);
    try std.testing.expectEqualSlices(u128, expected, result);
    try std.testing.expect(instance.native_tail_call == null);
}

test "backend tail calls: direct indirect and typed recursion discard native frames" {
    if (!wasm.backend_prototype.native.supported) return error.SkipZigTest;
    for ([_][]const u8{ &.{ 0x12, 0 }, &.{ 0x41, 0, 0x13, 0, 0 }, &.{ 0xd2, 0, 0x15, 0 } }) |tail| {
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        var body: std.ArrayList(u8) = .empty;
        defer body.deinit(a);
        try body.appendSlice(a, &.{ 0, 0x20, 0, 0x45, 0x04, 0x7e, 0x20, 1, 0x05, 0x20, 0, 0x41, 1, 0x6b, 0x20, 1, 0x42, 1, 0x7c });
        try body.appendSlice(a, tail);
        try body.appendSlice(a, &.{ 0x0b, 0x0b });
        const module: wasm.Module = .{
            .types = &.{.{ .params = &.{ .i32, .i64 }, .results = &.{.i64} }},
            .funcs = &.{0},
            .code = &.{.{ .bytes = body.items }},
            .tables = &.{.{ .elem = .funcref, .limits = .{ .min = 1 } }},
            .elements_count = 1,
            .elements_raw = &.{ 3, 0, 1, 0 },
        };
        var instance: wasm.Instance = undefined;
        try wasm.instantiate(&instance, arena.allocator(), a, &module, .{});
        defer instance.deinit();
        instance.shared_backend_enabled = true;
        instance.tables[0].elems[0] = wasm.interpreter.makeFuncRef(&instance, 0);
        var control: Control = .{ .remaining = 10002 };
        instance.execution_control = control.handle();
        const result = try wasm.invoke(&instance, a, 0, &.{ 10000, 17 });
        defer a.free(result);
        try std.testing.expectEqualSlices(u128, &.{10017}, result);
        try std.testing.expectEqual(@as(u64, 10001), instance.shared_backend_stats.entries);
        try std.testing.expectEqual(@as(u64, 0), instance.shared_backend_stats.refusals);
        try std.testing.expect(control.max_sp - control.min_sp < 32 * 1024);
    }
}

test "backend tail calls: alternating shared and Spasm entries use one trampoline" {
    if (!wasm.backend_prototype.native.supported) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const module: wasm.Module = .{
        .types = &.{.{ .params = &.{.i32}, .results = &.{.i32} }},
        .funcs = &.{ 0, 0 },
        .code = &.{
            .{ .bytes = &.{ 0, 0x20, 0, 0x45, 0x04, 0x7f, 0x41, 42, 0x05, 0x20, 0, 0x41, 1, 0x6b, 0x12, 1, 0x0b, 0x0b } },
            .{ .bytes = &.{ 0, 0xfd, 12, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xfd, 103, 0x1a, 0x20, 0, 0x12, 0, 0x0b } },
        },
    };
    var instance: wasm.Instance = undefined;
    try wasm.instantiate(&instance, arena.allocator(), a, &module, .{});
    defer instance.deinit();
    instance.shared_backend_enabled = true;
    instance.spasm_enabled = true;
    var control: Control = .{ .remaining = 20002 };
    instance.execution_control = control.handle();
    const result = try wasm.invoke(&instance, a, 0, &.{10000});
    defer a.free(result);
    try std.testing.expectEqualSlices(u128, &.{42}, result);
    try std.testing.expectEqual(@as(u64, 10001), instance.shared_backend_stats.entries);
    try std.testing.expectEqual(@as(u32, 10000), instance.spasm_runs);
    try std.testing.expectEqual(@as(u64, 1), instance.shared_backend_stats.refusals);
    try std.testing.expect(control.max_sp - control.min_sp < 32 * 1024);
}

test "backend tail calls: foreign direct indirect and typed targets preserve defining state and traps" {
    if (!prototype.native.supported) return error.SkipZigTest;
    for (0..3) |tier| for ([_]bool{ false, true }) |table64| {
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        const provider_module: wasm.Module = .{
            .types = &.{ .{ .params = &.{.i32}, .results = &.{.i32} }, .{ .params = &.{.i64}, .results = &.{.i64} } },
            .funcs = &.{ 0, 1 },
            .mems = &.{.{ .limits = .{ .min = 1 } }},
            .code = &.{ .{ .bytes = &.{ 0, 0x41, 0, 0x28, 0, 0, 0x20, 0, 0x6a, 0x0b } }, .{ .bytes = &.{ 0, 0x20, 0, 0x0b } } },
        };
        var provider: wasm.Instance = undefined;
        try wasm.instantiate(&provider, arena.allocator(), a, &provider_module, .{});
        defer provider.deinit();
        provider.spasm_enabled = tier == 1;
        provider.shared_backend_enabled = tier == 2;
        provider.memories[0].data[0] = 11;
        const module: wasm.Module = .{
            .types = &.{
                provider_module.types[0],
                .{ .params = &.{ .i32, if (table64) .i64 else .i32 }, .results = &.{.i32} },
                .{ .params = &.{ .i32, wasm.ValType.refType(true, 0) }, .results = &.{.i32} },
            },
            .imports = &.{.{ .module = "p", .name = "f", .desc = .{ .func = 0 } }},
            .mems = provider_module.mems,
            .tables = &.{.{ .elem = .funcref, .limits = .{ .min = 2, .is_64 = table64 } }},
            .funcs = &.{ 0, 1, 2 },
            .code = &.{
                .{ .bytes = &.{ 0, 0x20, 0, 0x12, 0, 0x0b } },
                .{ .bytes = &.{ 0, 0x20, 0, 0x20, 1, 0x13, 0, 0, 0x0b } },
                .{ .bytes = &.{ 0, 0x20, 0, 0x20, 1, 0x15, 0, 0x0b } },
            },
        };
        var instance: wasm.Instance = undefined;
        try wasm.instantiate(&instance, arena.allocator(), a, &module, .{ .funcs = &.{provider.funcRefAt(0).?} });
        defer instance.deinit();
        instance.shared_backend_enabled = true;
        instance.memories[0].data[0] = 99;
        const reference = wasm.interpreter.makeFuncRef(&provider, 0);
        instance.tables[0].elems[0] = reference;
        try expectResult(&instance, 1, &.{3}, &.{14});
        try expectResult(&instance, 2, &.{ 3, 0 }, &.{14});
        try expectResult(&instance, 3, &.{ 3, reference }, &.{14});
        try std.testing.expectEqual(@as(u64, 3), instance.shared_backend_stats.entries);
        try std.testing.expectEqual(@as(u64, if (tier == 2) 3 else 0), provider.shared_backend_stats.entries);
        try std.testing.expectEqual(@as(u32, if (tier == 1) 3 else 0), provider.spasm_runs);
        try std.testing.expectError(error.UninitializedElement, wasm.invoke(&instance, a, 2, &.{ 3, 1 }));
        try std.testing.expectError(error.UndefinedElement, wasm.invoke(&instance, a, 2, &.{ 3, 2 }));
        try std.testing.expectError(error.NullReference, wasm.invoke(&instance, a, 3, &.{ 3, wasm.REF_NULL }));
        instance.tables[0].elems[1] = wasm.interpreter.makeFuncRef(&provider, 1);
        try std.testing.expectError(error.IndirectCallTypeMismatch, wasm.invoke(&instance, a, 2, &.{ 3, 1 }));
        try std.testing.expect(instance.native_tail_call == null);
        try std.testing.expectEqual(@as(u64, 7), instance.shared_backend_stats.entries);
        try std.testing.expectEqual(@as(u64, 0), instance.shared_backend_stats.refusals);
    };
}

const Control = struct {
    remaining: usize,
    polls: usize = 0,
    min_sp: usize = std.math.maxInt(usize),
    max_sp: usize = 0,
    fn armed(_: *anyopaque) bool {
        return true;
    }
    fn poll(raw: *anyopaque) wasm.ExecutionPoll {
        const self: *@This() = @ptrCast(@alignCast(raw));
        var probe: u8 = 0;
        self.min_sp = @min(self.min_sp, @intFromPtr(&probe));
        self.max_sp = @max(self.max_sp, @intFromPtr(&probe));
        self.polls += 1;
        if (self.remaining == 0) return .terminated;
        self.remaining -= 1;
        return .proceed;
    }
    fn handle(self: *@This()) wasm.ExecutionControl {
        return .{ .ctx = self, .poll_fn = poll, .armed_fn = armed };
    }
};

test "backend tail calls: bounded entry preserves a foreign execution controller" {
    if (!prototype.native.supported) return error.SkipZigTest;
    for (0..3) |tier| {
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        const provider_module: wasm.Module = .{
            .types = &.{.{ .params = &.{.i32}, .results = &.{.i32} }},
            .funcs = &.{0},
            .code = &.{.{ .bytes = &.{ 0, 0x20, 0, 0x0b } }},
        };
        var provider: wasm.Instance = undefined;
        try wasm.instantiate(&provider, arena.allocator(), a, &provider_module, .{});
        defer provider.deinit();
        provider.spasm_enabled = tier == 1;
        provider.shared_backend_enabled = tier == 2;
        const module: wasm.Module = .{
            .types = provider_module.types,
            .imports = &.{.{ .module = "p", .name = "f", .desc = .{ .func = 0 } }},
            .funcs = &.{0},
            .code = &.{.{ .bytes = &.{ 0, 0x20, 0, 0x12, 0, 0x0b } }},
        };
        var instance: wasm.Instance = undefined;
        try wasm.instantiate(&instance, arena.allocator(), a, &module, .{ .funcs = &.{provider.funcRefAt(0).?} });
        defer instance.deinit();
        instance.shared_backend_enabled = true;
        var owner = try prototype.CodeAllocator.init(a, 256 * 1024);
        defer owner.deinit();
        var code = blk: {
            var graph = try prototype.lowerInstance(a, &instance, 1);
            defer graph.deinit();
            break :blk try prototype.compile(a, &owner, &graph, .{});
        };
        defer code.deinit();
        var control: Control = .{ .remaining = 0 };
        provider.execution_control = control.handle();
        try std.testing.expectError(error.ExecutionTerminated, prototype.runInInstance(&code, &instance, &.{42}, 8));
        try std.testing.expectEqual(@as(usize, 1), control.polls);
        try std.testing.expect(instance.native_tail_call == null);
        var inherited: Control = .{ .remaining = 8 };
        instance.execution_control = inherited.handle();
        var result = try prototype.runInInstance(&code, &instance, &.{42}, 8);
        defer result.deinit();
        try std.testing.expectEqual(@as(u64, 42), result.returned);
        try std.testing.expectEqual(@as(usize, 1), control.polls);
        try std.testing.expect(inherited.polls > 0);
        try std.testing.expect(instance.native_tail_call == null);
    }
}

test "backend tail calls: host entry polls cancellation before observable effects" {
    if (!prototype.native.supported) return error.SkipZigTest;
    const Host = struct {
        calls: usize = 0,
        fn invoke(raw: ?*anyopaque, args: []const u128, results: []u128) wasm.TrapError!void {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            self.calls += 1;
            results[0] = args[0];
        }
    };
    var host: Host = .{};
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const module: wasm.Module = .{
        .types = &.{.{ .params = &.{.i32}, .results = &.{.i32} }},
        .imports = &.{.{ .module = "h", .name = "f", .desc = .{ .func = 0 } }},
        .funcs = &.{0},
        .code = &.{.{ .bytes = &.{ 0, 0x20, 0, 0x12, 0, 0x0b } }},
    };
    var instance: wasm.Instance = undefined;
    try wasm.instantiate(&instance, arena.allocator(), a, &module, .{ .funcs = &.{.{ .host = .{ .fn_ptr = Host.invoke, .ctx = &host, .params = 1, .results = 1 } }} });
    defer instance.deinit();
    instance.shared_backend_enabled = true;
    var control: Control = .{ .remaining = 1 };
    instance.execution_control = control.handle();
    try std.testing.expectError(error.ExecutionTerminated, wasm.invoke(&instance, a, 1, &.{42}));
    try std.testing.expectEqual(@as(usize, 0), host.calls);
    try std.testing.expectEqual(@as(usize, 2), control.polls);
    try std.testing.expect(instance.native_tail_call == null);
    control.remaining = 2;
    try expectResult(&instance, 1, &.{42}, &.{42});
    try std.testing.expectEqual(@as(usize, 1), host.calls);
}

test "backend tail calls: outgoing references and mixed results survive host calls and failures" {
    if (!prototype.native.supported) return error.SkipZigTest;
    const Host = struct {
        calls: usize = 0,
        pins: usize = 0,
        pinned: u128 = 0,
        fail_pin: bool = false,
        fail_host: bool = false,
        fn pin(raw: *anyopaque, value: u128) error{OutOfMemory}!void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.pins += 1;
            self.pinned = value;
            if (self.fail_pin) return error.OutOfMemory;
        }
        fn invoke(raw: ?*anyopaque, args: []const u128, results: []u128) wasm.TrapError!void {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            self.calls += 1;
            if (self.fail_host) return error.HostThrew;
            results[0] = args[2];
            results[1] = args[0];
            results[2] = args[1];
        }
    };
    var host: Host = .{};
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const module: wasm.Module = .{
        .types = &.{
            .{ .params = &.{ .externref, .f64, .i64 }, .results = &.{ .i64, .externref, .f64 } },
            .{ .params = &.{ .externref, .f64, .i64, .externref }, .results = &.{ .i64, .externref, .f64 } },
        },
        .imports = &.{.{ .module = "h", .name = "f", .desc = .{ .func = 0 } }},
        .globals = &.{.{ .type = .{ .val = .i32, .mut = .mutable }, .init_expr = &.{ 0x41, 0, 0x0b } }},
        .funcs = &.{1},
        .code = &.{.{ .bytes = &.{ 0, 0x23, 0, 0x41, 1, 0x6a, 0x24, 0, 0x20, 0, 0x20, 1, 0x20, 2, 0x12, 0, 0x0b } }},
    };
    var instance: wasm.Instance = undefined;
    try wasm.instantiate(&instance, arena.allocator(), a, &module, .{ .funcs = &.{.{ .host = .{ .fn_ptr = Host.invoke, .ctx = &host, .params = 3, .results = 3 } }} });
    defer instance.deinit();
    instance.shared_backend_enabled = true;
    instance.spasm_enabled = true;
    instance.externref_rooter = .{ .context = &host, .pin_fn = Host.pin };
    const reference: u128 = (@as(u128, 0x1234) << 64) | 17;
    const args = [_]u128{ reference, 0x8000_0000_0000_0000, std.math.maxInt(u64), 91 };
    const expected = [_]u128{ args[2], reference, args[1] };
    try expectResult(&instance, 1, &args, &expected);
    try std.testing.expectEqual(reference, host.pinned);
    try std.testing.expectEqual(@as(usize, 1), host.pins);
    host.fail_pin = true;
    try std.testing.expectError(error.OutOfMemory, wasm.invoke(&instance, a, 1, &args));
    try std.testing.expectEqual(@as(usize, 1), host.calls);
    try std.testing.expect(instance.native_tail_call == null);
    host.fail_pin = false;
    host.fail_host = true;
    try std.testing.expectError(error.HostThrew, wasm.invoke(&instance, a, 1, &args));
    try std.testing.expectEqual(@as(usize, 2), host.calls);
    try std.testing.expect(instance.native_tail_call == null);
    host.fail_host = false;
    try expectResult(&instance, 1, &args, &expected);
    try std.testing.expectEqual(@as(u128, 4), instance.globals[0].value);
    try std.testing.expectEqual(@as(u64, 4), instance.shared_backend_stats.entries);
    try std.testing.expectEqual(@as(u32, 0), instance.spasm_runs);

    var owner = try prototype.CodeAllocator.init(a, 256 * 1024);
    defer owner.deinit();
    const Mode = @import("../jit/backend/allocation.zig").Mode;
    for ([_]Mode{ .scratch, .linear_scan }) |mode| for (0..16) |flags| for ([_]u8{ 0, 1, 4 }) |registers| {
        var code = blk: {
            var graph = try prototype.lowerInstance(a, &instance, 1);
            defer graph.deinit();
            break :blk try prototype.compile(a, &owner, &graph, .{
                .allocation = mode,
                .register_count = registers,
                .rematerialize_constants = flags & 8 != 0,
                .optimization = .{ .constant_folding = flags & 1 != 0, .common_subexpression_elimination = flags & 2 != 0, .dead_code_elimination = flags & 4 != 0 },
            });
        };
        defer code.deinit();
        var arguments: [6]u64 = undefined;
        var results: [4]u64 = undefined;
        var logical: [3]u128 = undefined;
        const words = try prototype.abi.pack(module.types[1].params, &args, &arguments);
        host.pins = 0;
        var completion = try prototype.runResultsInInstance(&code, &instance, words, 4, &results);
        defer completion.deinit();
        try std.testing.expect(completion == .returned);
        try prototype.abi.unpack(module.types[1].results, &results, &logical);
        try std.testing.expectEqualSlices(u128, &expected, &logical);
        try std.testing.expectEqual(reference, host.pinned);
        try std.testing.expectEqual(@as(usize, 1), host.pins);
        try std.testing.expect(instance.native_tail_call == null);
    };
}

fn invokeTailWithAllocator(instance: *wasm.Instance, allocator: std.mem.Allocator) !void {
    instance.invocation_allocator = allocator;
    defer instance.invocation_allocator = null;
    const result = try wasm.invoke(instance, allocator, 0, &.{42});
    defer allocator.free(result);
    try std.testing.expectEqualSlices(u128, &.{42}, result);
}

test "backend tail calls: allocation failures release captures and staged requests without replay" {
    if (!prototype.native.supported) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const module: wasm.Module = .{
        .types = &.{.{ .params = &.{.i32}, .results = &.{.i32} }},
        .globals = &.{.{ .type = .{ .val = .i32, .mut = .mutable }, .init_expr = &.{ 0x41, 0, 0x0b } }},
        .funcs = &.{ 0, 0 },
        .code = &.{
            .{ .bytes = &.{ 0, 0x23, 0, 0x41, 1, 0x6a, 0x24, 0, 0x20, 0, 0x12, 1, 0x0b } },
            .{ .bytes = &.{ 0, 0x20, 0, 0x0b } },
        },
    };
    var instance: wasm.Instance = undefined;
    try wasm.instantiate(&instance, arena.allocator(), a, &module, .{});
    defer instance.deinit();
    instance.shared_backend_enabled = true;
    instance.spasm_enabled = true;
    try expectResult(&instance, 0, &.{42}, &.{42});
    try std.testing.expectEqual(@as(u64, 2), instance.shared_backend_stats.compiles);
    var baseline = std.testing.FailingAllocator.init(a, .{});
    try invokeTailWithAllocator(&instance, baseline.allocator());
    try std.testing.expectEqual(baseline.allocated_bytes, baseline.freed_bytes);
    for (0..baseline.alloc_index) |index| {
        var failing = std.testing.FailingAllocator.init(a, .{ .fail_index = index });
        instance.globals[0].value = 0;
        try std.testing.expectError(error.OutOfMemory, invokeTailWithAllocator(&instance, failing.allocator()));
        try std.testing.expect(failing.has_induced_failure);
        try std.testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
        try std.testing.expect(instance.globals[0].value <= 1);
        try std.testing.expect(instance.native_tail_call == null);
        try std.testing.expectEqual(@as(u32, 0), instance.spasm_runs);
        try expectResult(&instance, 0, &.{42}, &.{42});
    }
}

test "backend tail calls: foreign fallback exceptions preserve payloads without replay" {
    if (!prototype.native.supported) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const provider_module: wasm.Module = .{
        .types = &.{ .{ .params = &.{}, .results = &.{.i32} }, .{ .params = &.{.i32}, .results = &.{} } },
        .globals = &.{.{ .type = .{ .val = .i32, .mut = .mutable }, .init_expr = &.{ 0x41, 0, 0x0b } }},
        .tags = &.{.{ .attribute = 0, .type_index = 1 }},
        .funcs = &.{0},
        .code = &.{.{ .bytes = &.{ 0, 0x23, 0, 0x41, 1, 0x6a, 0x24, 0, 0x41, 37, 0x08, 0, 0x0b } }},
    };
    var provider: wasm.Instance = undefined;
    try wasm.instantiate(&provider, arena.allocator(), a, &provider_module, .{});
    defer provider.deinit();
    provider.shared_backend_enabled = true;
    provider.spasm_enabled = true;
    const module: wasm.Module = .{
        .types = provider_module.types[0..1],
        .imports = &.{.{ .module = "p", .name = "f", .desc = .{ .func = 0 } }},
        .funcs = &.{0},
        .code = &.{.{ .bytes = &.{ 0, 0x12, 0, 0x0b } }},
    };
    var instance: wasm.Instance = undefined;
    try wasm.instantiate(&instance, arena.allocator(), a, &module, .{ .funcs = &.{provider.funcRefAt(0).?} });
    defer instance.deinit();
    instance.shared_backend_enabled = true;
    try std.testing.expectError(error.UncaughtException, wasm.invoke(&instance, a, 1, &.{}));
    const exception = instance.pending_exn orelse return error.MissingException;
    try std.testing.expectEqual(provider.tag_identities[0], exception.tag);
    try std.testing.expectEqualSlices(u128, &.{37}, exception.payload);
    try std.testing.expectEqual(@as(u128, 1), provider.globals[0].value);
    try std.testing.expect(instance.native_tail_call == null and provider.native_tail_call == null);
    try std.testing.expectEqual(@as(u64, 1), instance.shared_backend_stats.entries);
    try std.testing.expectEqual(@as(u64, 1), provider.shared_backend_stats.refusals);
}

test "backend tail calls: full physical arity preserves reordered arguments and multiple results" {
    if (!prototype.native.supported) return error.SkipZigTest;
    for ([_]bool{ false, true }) |fallback| {
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        const params: [prototype.ir.max_arguments]wasm.ValType = @splat(.i64);
        var caller: std.ArrayList(u8) = .empty;
        var callee: std.ArrayList(u8) = .empty;
        try caller.append(arena.allocator(), 0);
        try callee.append(arena.allocator(), 0);
        if (fallback) {
            try callee.appendSlice(arena.allocator(), &.{ 0xfd, 12 });
            try callee.appendNTimes(arena.allocator(), 0, 16);
            try callee.appendSlice(arena.allocator(), &.{ 0xfd, 103, 0x1a });
        }
        var args: [params.len]u128 = undefined;
        var expected: [params.len]u128 = undefined;
        for (0..params.len) |i| {
            try caller.appendSlice(arena.allocator(), &.{ 0x20, @intCast(params.len - 1 - i) });
            try callee.appendSlice(arena.allocator(), &.{ 0x20, @intCast(i) });
            args[i] = 0x1234_0000_0000_0000 + i;
            expected[params.len - 1 - i] = args[i];
        }
        try caller.appendSlice(arena.allocator(), &.{ 0x12, 1, 0x0b });
        try callee.append(arena.allocator(), 0x0b);
        const module: wasm.Module = .{
            .types = &.{.{ .params = &params, .results = &params }},
            .funcs = &.{ 0, 0 },
            .code = &.{ .{ .bytes = caller.items }, .{ .bytes = callee.items } },
        };
        var instance: wasm.Instance = undefined;
        try wasm.instantiate(&instance, arena.allocator(), a, &module, .{});
        defer instance.deinit();
        instance.shared_backend_enabled = true;
        instance.spasm_enabled = true;
        try expectResult(&instance, 0, &args, &expected);
        try std.testing.expectEqual(@as(u64, if (fallback) 1 else 2), instance.shared_backend_stats.entries);
        try std.testing.expectEqual(@as(u64, @intFromBool(fallback)), instance.shared_backend_stats.refusals);
    }
}

test "backend tail calls: infinite chains honor production and developer budgets" {
    if (!prototype.native.supported) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const module: wasm.Module = .{
        .types = &.{.{ .params = &.{}, .results = &.{.i32} }},
        .funcs = &.{0},
        .code = &.{.{ .bytes = &.{ 0, 0x12, 0, 0x0b } }},
    };
    var instance: wasm.Instance = undefined;
    try wasm.instantiate(&instance, arena.allocator(), a, &module, .{});
    defer instance.deinit();
    instance.shared_backend_enabled = true;
    var control: Control = .{ .remaining = 8 };
    instance.execution_control = control.handle();
    try std.testing.expectError(error.ExecutionTerminated, wasm.invoke(&instance, a, 0, &.{}));
    try std.testing.expectEqual(@as(usize, 9), control.polls);
    try std.testing.expectEqual(@as(u64, 9), instance.shared_backend_stats.entries);
    try std.testing.expect(instance.native_tail_call == null);
    instance.execution_control = null;
    var owner = try prototype.CodeAllocator.init(a, 256 * 1024);
    defer owner.deinit();
    var code = blk: {
        var graph = try prototype.lowerInstance(a, &instance, 0);
        defer graph.deinit();
        break :blk try prototype.compile(a, &owner, &graph, .{});
    };
    defer code.deinit();
    try std.testing.expectError(error.BudgetExhausted, prototype.runInInstance(&code, &instance, &.{}, 0));
    try std.testing.expectError(error.StepBudgetExhausted, prototype.runInInstance(&code, &instance, &.{}, 3));
    try std.testing.expect(instance.native_tail_call == null);
}

test "backend tail calls: dormant controllers wake between shared and mixed-tier hops" {
    if (!prototype.native.supported) return error.SkipZigTest;
    const Wake = struct {
        flag: std.atomic.Value(bool) = .init(false),
        pins: usize = 0,
        polls: usize = 0,
        fn armed(_: *anyopaque) bool {
            return false;
        }
        fn poll(raw: *anyopaque) wasm.ExecutionPoll {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.polls += 1;
            return .terminated;
        }
        fn pin(raw: *anyopaque, _: u128) error{OutOfMemory}!void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.pins += 1;
            // A deterministic host-boundary wake; bound a broken probe path.
            if (self.pins == 5) self.flag.store(true, .release);
            if (self.pins > 16) return error.OutOfMemory;
        }
    };
    for ([_]bool{ false, true }) |mixed| {
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        const module: wasm.Module = .{
            .types = &.{.{ .params = &.{.externref}, .results = &.{.i32} }},
            .funcs = if (mixed) &.{ 0, 0 } else &.{0},
            .code = if (mixed) &.{
                .{ .bytes = &.{ 0, 0x20, 0, 0x12, 1, 0x0b } },
                .{ .bytes = &.{ 0, 0xfd, 12, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xfd, 103, 0x1a, 0x20, 0, 0x12, 0, 0x0b } },
            } else &.{.{ .bytes = &.{ 0, 0x20, 0, 0x12, 0, 0x0b } }},
        };
        var instance: wasm.Instance = undefined;
        try wasm.instantiate(&instance, arena.allocator(), a, &module, .{});
        defer instance.deinit();
        instance.shared_backend_enabled = true;
        instance.spasm_enabled = mixed;
        var wake: Wake = .{};
        instance.execution_control = .{ .ctx = &wake, .poll_fn = Wake.poll, .armed_fn = Wake.armed, .wake_flag = &wake.flag };
        instance.externref_rooter = .{ .context = &wake, .pin_fn = Wake.pin };
        try std.testing.expectError(error.ExecutionTerminated, wasm.invoke(&instance, a, 0, &.{17}));
        try std.testing.expectEqual(@as(usize, 5), wake.pins);
        try std.testing.expectEqual(@as(usize, 1), wake.polls);
        try std.testing.expectEqual(@as(u64, if (mixed) 5 else 6), instance.shared_backend_stats.entries);
        try std.testing.expectEqual(@as(u32, if (mixed) 5 else 0), instance.spasm_runs);
        try std.testing.expect(instance.native_tail_call == null);
    }
}

fn compileTailAllocation(allocator: std.mem.Allocator, owner: *prototype.CodeAllocator, instance: *wasm.Instance) !void {
    var code = blk: {
        var graph = try prototype.lowerInstance(allocator, instance, 1);
        defer graph.deinit();
        break :blk try prototype.compile(allocator, owner, &graph, .{});
    };
    defer code.deinit();
    try std.testing.expectEqual(@as(usize, 1), code.tail_calls.len);
    var completion = try prototype.runResultsInInstance(&code, instance, &.{}, 4, &.{});
    defer completion.deinit();
    try std.testing.expect(completion == .returned);
    try std.testing.expect(instance.native_tail_call == null);
}

test "backend tail calls: allocation failures release owned continuation metadata" {
    if (!prototype.native.supported) return error.SkipZigTest;
    const Host = struct {
        fn invoke(_: ?*anyopaque, _: []const u128, _: []u128) wasm.TrapError!void {}
    };
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const module: wasm.Module = .{
        .types = &.{.{ .params = &.{}, .results = &.{} }},
        .imports = &.{.{ .module = "h", .name = "f", .desc = .{ .func = 0 } }},
        .funcs = &.{0},
        .code = &.{.{ .bytes = &.{ 0, 0x12, 0, 0x0b } }},
    };
    var instance: wasm.Instance = undefined;
    try wasm.instantiate(&instance, arena.allocator(), a, &module, .{ .funcs = &.{.{ .host = .{ .fn_ptr = Host.invoke, .ctx = null, .params = 0, .results = 0 } }} });
    defer instance.deinit();
    var owner = try prototype.CodeAllocator.init(a, 256 * 1024);
    defer owner.deinit();
    var no_resize = std.testing.FailingAllocator.init(a, .{ .resize_fail_index = 0 });
    try std.testing.checkAllAllocationFailures(no_resize.allocator(), compileTailAllocation, .{ &owner, &instance });
    try std.testing.expect(instance.native_tail_call == null);
}

test "backend tail calls: indirect host targets require types rather than arity alone" {
    if (!prototype.native.supported) return error.SkipZigTest;
    const Host = struct {
        calls: usize = 0,
        fn invoke(raw: ?*anyopaque, args: []const u128, results: []u128) wasm.TrapError!void {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            self.calls += 1;
            results[0] = args[0];
        }
    };
    for ([_]u8{ 0x11, 0x13 }) |opcode| {
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        const module: wasm.Module = .{
            .types = &.{ .{ .params = &.{.i64}, .results = &.{.i64} }, .{ .params = &.{.i32}, .results = &.{.i32} } },
            .imports = &.{.{ .module = "h", .name = "f", .desc = .{ .func = 0 } }},
            .tables = &.{.{ .elem = .funcref, .limits = .{ .min = 1 } }},
            .funcs = &.{1},
            .code = &.{.{ .bytes = &.{ 0, 0x20, 0, 0x41, 0, opcode, 1, 0, 0x0b } }},
        };
        var host: Host = .{};
        var instance: wasm.Instance = undefined;
        try wasm.instantiate(&instance, arena.allocator(), a, &module, .{ .funcs = &.{.{ .host = .{ .fn_ptr = Host.invoke, .ctx = &host, .params = 1, .results = 1 } }} });
        defer instance.deinit();
        instance.shared_backend_enabled = true;
        instance.tables[0].elems[0] = wasm.interpreter.makeFuncRef(&instance, 0);
        const outcome = wasm.invoke(&instance, a, 1, &.{42});
        defer if (outcome) |result| a.free(result) else |_| {};
        try std.testing.expectError(error.IndirectCallTypeMismatch, outcome);
        try std.testing.expectEqual(@as(usize, 0), host.calls);
        try std.testing.expectEqual(@as(u64, 1), instance.shared_backend_stats.entries);
        try std.testing.expect(instance.native_tail_call == null);
    }
}
