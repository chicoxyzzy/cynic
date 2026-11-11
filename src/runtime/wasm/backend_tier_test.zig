const std = @import("std");
const wasm = @import("wasm.zig");
const a = std.testing.allocator;

const identity_module: wasm.Module = .{
    .types = &.{.{ .params = &.{.i32}, .results = &.{.i32} }},
    .funcs = &.{0},
    .code = &.{.{ .bytes = &.{ 0, 0x20, 0, 0x0b } }},
};

test "backend tier: instance dispatch caches generated callers and callees" {
    if (!wasm.backend_prototype.native.supported) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const module: wasm.Module = .{
        .types = &.{.{ .params = &.{.i32}, .results = &.{.i32} }},
        .funcs = &.{ 0, 0 },
        .code = &.{ .{ .bytes = &.{ 0, 0x20, 0, 0x10, 1, 0x41, 1, 0x6a, 0x0b } }, .{ .bytes = &.{ 0, 0x20, 0, 0x41, 2, 0x6a, 0x0b } } },
    };
    var instance: wasm.Instance = undefined;
    try wasm.instantiate(&instance, arena.allocator(), a, &module, .{});
    defer instance.deinit();
    try std.testing.expect(!instance.shared_backend_enabled);
    instance.shared_backend_enabled = true;
    for (0..3) |_| {
        const result = try wasm.invoke(&instance, a, 0, &.{42});
        defer a.free(result);
        try std.testing.expectEqualSlices(u128, &.{45}, result);
    }
    try std.testing.expectEqual(@as(u64, 6), instance.shared_backend_stats.entries);
    try std.testing.expectEqual(@as(u64, 2), instance.shared_backend_stats.compiles);
    try std.testing.expectEqual(@as(u64, 0), instance.shared_backend_stats.refusals);
    instance.releaseExecutableCode();
    instance.releaseExecutableCode();
    try std.testing.expect(instance.shared_backend_cache == null);
}

test "backend tier: unsupported functions fall back once without disguising native coverage" {
    if (!wasm.backend_prototype.native.supported) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const module: wasm.Module = .{
        .types = &.{.{ .params = &.{}, .results = &.{.i32} }},
        .funcs = &.{0},
        .mems = &.{.{ .limits = .{ .min = 1 } }},
        // Exception regions remain unsupported, even with an empty catch table.
        .code = &.{.{ .bytes = &.{ 0, 0x1f, 0x40, 0, 0x0b, 0x41, 1, 0x0b } }},
    };
    var instance: wasm.Instance = undefined;
    try wasm.instantiate(&instance, arena.allocator(), a, &module, .{});
    defer instance.deinit();
    instance.shared_backend_enabled = true;
    for (0..2) |_| {
        const result = try wasm.invoke(&instance, a, 0, &.{});
        defer a.free(result);
        try std.testing.expectEqualSlices(u128, &.{1}, result);
    }
    try std.testing.expectEqual(@as(u64, 0), instance.shared_backend_stats.entries);
    try std.testing.expectEqual(@as(u64, 1), instance.shared_backend_stats.refusals);
}

test "backend tier: fuel termination is propagated and the cached function remains reusable" {
    if (!wasm.backend_prototype.native.supported) return error.SkipZigTest;
    const Fuel = struct {
        remaining: usize,
        fn armed(_: *anyopaque) bool {
            return true;
        }
        fn poll(raw: *anyopaque) wasm.ExecutionPoll {
            const self: *@This() = @ptrCast(@alignCast(raw));
            if (self.remaining == 0) return .terminated;
            self.remaining -= 1;
            return .proceed;
        }
    };
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const module: wasm.Module = .{
        .types = &.{.{ .params = &.{.i32}, .results = &.{.i32} }},
        .funcs = &.{0},
        .code = &.{.{ .bytes = &.{ 0, 0x03, 0x40, 0x20, 0, 0x41, 1, 0x6b, 0x22, 0, 0x0d, 0, 0x0b, 0x20, 0, 0x0b } }},
    };
    var instance: wasm.Instance = undefined;
    try wasm.instantiate(&instance, arena.allocator(), a, &module, .{});
    defer instance.deinit();
    instance.shared_backend_enabled = true;
    var fuel: Fuel = .{ .remaining = 3 };
    instance.execution_control = .{ .ctx = &fuel, .poll_fn = Fuel.poll, .armed_fn = Fuel.armed };
    try std.testing.expectError(error.ExecutionTerminated, wasm.invoke(&instance, a, 0, &.{100}));
    fuel.remaining = 100;
    const result = try wasm.invoke(&instance, a, 0, &.{5});
    defer a.free(result);
    try std.testing.expectEqualSlices(u128, &.{0}, result);
    try std.testing.expectEqual(@as(u64, 2), instance.shared_backend_stats.entries);
    try std.testing.expectEqual(@as(u64, 1), instance.shared_backend_stats.compiles);
}

test "backend tier: callback errors and arithmetic traps never replay side effects" {
    if (!wasm.backend_prototype.native.supported) return error.SkipZigTest;
    const Host = struct {
        calls: usize = 0,
        fail: bool = true,
        fn invoke(raw: ?*anyopaque, _: []const u128, _: []u128) wasm.TrapError!void {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            self.calls += 1;
            if (self.fail) return error.HostThrew;
        }
    };
    var host: Host = .{};
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const module: wasm.Module = .{
        .types = &.{ .{ .params = &.{}, .results = &.{} }, .{ .params = &.{.i32}, .results = &.{.i32} } },
        .imports = &.{.{ .module = "host", .name = "effect", .desc = .{ .func = 0 } }},
        .funcs = &.{1},
        .code = &.{.{ .bytes = &.{ 0, 0x10, 0, 0x41, 10, 0x20, 0, 0x6d, 0x0b } }},
    };
    var instance: wasm.Instance = undefined;
    try wasm.instantiate(&instance, arena.allocator(), a, &module, .{ .funcs = &.{.{ .host = .{ .fn_ptr = Host.invoke, .ctx = &host, .params = 0, .results = 0 } }} });
    defer instance.deinit();
    instance.shared_backend_enabled = true;
    instance.spasm_enabled = true;
    try std.testing.expectError(error.HostThrew, wasm.invoke(&instance, a, 1, &.{2}));
    host.fail = false;
    try std.testing.expectError(error.IntegerDivideByZero, wasm.invoke(&instance, a, 1, &.{0}));
    const result = try wasm.invoke(&instance, a, 1, &.{2});
    defer a.free(result);
    try std.testing.expectEqualSlices(u128, &.{5}, result);
    try std.testing.expectEqual(@as(usize, 3), host.calls);
    try std.testing.expectEqual(@as(u64, 3), instance.shared_backend_stats.entries);
    try std.testing.expectEqual(@as(u64, 1), instance.shared_backend_stats.compiles);
    try std.testing.expectEqual(@as(u32, 0), instance.spasm_runs);
}

test "backend tier: foreign calls preserve instance state and controller precedence" {
    if (!wasm.backend_prototype.native.supported) return error.SkipZigTest;
    const Control = struct {
        stop: bool = true,
        polls: usize = 0,
        fn armed(_: *anyopaque) bool {
            return true;
        }
        fn poll(raw: *anyopaque) wasm.ExecutionPoll {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.polls += 1;
            return if (self.stop) .terminated else .proceed;
        }
        fn handle(self: *@This()) wasm.ExecutionControl {
            return .{ .ctx = self, .poll_fn = poll, .armed_fn = armed };
        }
    };
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const provider_module: wasm.Module = .{
        .types = identity_module.types,
        .funcs = &.{0},
        .mems = &.{.{ .limits = .{ .min = 1 } }},
        .code = &.{.{ .bytes = &.{ 0, 0x41, 0, 0x28, 0, 0, 0x20, 0, 0x6a, 0x0b } }},
    };
    var provider: wasm.Instance = undefined;
    try wasm.instantiate(&provider, arena.allocator(), a, &provider_module, .{});
    defer provider.deinit();
    provider.shared_backend_enabled = true;
    provider.memories[0].data[0] = 11;
    const consumer_module: wasm.Module = .{
        .types = identity_module.types,
        .imports = &.{.{ .module = "provider", .name = "load", .desc = .{ .func = 0 } }},
        .funcs = &.{0},
        .mems = provider_module.mems,
        .code = &.{.{ .bytes = &.{ 0, 0x20, 0, 0x10, 0, 0x0b } }},
    };
    var consumer: wasm.Instance = undefined;
    try wasm.instantiate(&consumer, arena.allocator(), a, &consumer_module, .{ .funcs = &.{provider.funcRefAt(0).?} });
    defer consumer.deinit();
    consumer.shared_backend_enabled = true;
    consumer.memories[0].data[0] = 99;
    var provider_control: Control = .{};
    provider.execution_control = provider_control.handle();
    try std.testing.expectError(error.ExecutionTerminated, wasm.invoke(&consumer, a, 1, &.{3}));
    var caller_control: Control = .{ .stop = false };
    consumer.execution_control = caller_control.handle();
    const result = try wasm.invoke(&consumer, a, 1, &.{3});
    defer a.free(result);
    try std.testing.expectEqualSlices(u128, &.{14}, result);
    try std.testing.expectEqual(@as(usize, 1), provider_control.polls);
    try std.testing.expectEqual(@as(usize, 2), caller_control.polls);
    var inherited: Control = .{};
    try std.testing.expectError(error.ExecutionTerminated, @import("interpreter.zig").invokeWithControl(&consumer, a, 1, &.{3}, inherited.handle()));
    try std.testing.expectEqual(@as(usize, 1), inherited.polls);
    try std.testing.expectEqual(@as(u64, 2), provider.shared_backend_stats.entries);
    try std.testing.expectEqual(@as(u64, 3), consumer.shared_backend_stats.entries);
}

test "backend tier: recursive native dispatch exhausts the host stack safely" {
    if (!wasm.backend_prototype.native.supported) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const module: wasm.Module = .{
        .types = &.{.{ .params = &.{}, .results = &.{} }},
        .funcs = &.{0},
        .code = &.{.{ .bytes = &.{ 0, 0x10, 0, 0x0b } }},
    };
    var instance: wasm.Instance = undefined;
    try wasm.instantiate(&instance, arena.allocator(), a, &module, .{});
    defer instance.deinit();
    instance.shared_backend_enabled = true;
    try std.testing.expectError(error.CallStackExhausted, wasm.invoke(&instance, a, 0, &.{}));
    try std.testing.expect(instance.shared_backend_stats.entries > 1);
    try std.testing.expectEqual(@as(u64, 1), instance.shared_backend_stats.compiles);
}

test "backend tier: exhausted host stack refuses before compilation" {
    if (!wasm.backend_prototype.native.supported) return error.SkipZigTest;
    const Stack = struct {
        noinline fn invokeNearLimit(instance: *wasm.Instance, depth: usize) anyerror![]u128 {
            var padding: [16 * 1024]u8 = undefined;
            std.mem.doNotOptimizeAway(&padding);
            defer std.mem.doNotOptimizeAway(&padding);
            if (@import("../../stack_guard.zig").nearLimit()) return wasm.invoke(instance, a, 0, &.{42});
            if (depth == 4096) return error.StackLimitNotReached;
            return invokeNearLimit(instance, depth + 1);
        }
    };
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    var instance: wasm.Instance = undefined;
    try wasm.instantiate(&instance, arena.allocator(), a, &identity_module, .{});
    defer instance.deinit();
    instance.shared_backend_enabled = true;
    try std.testing.expectError(error.CallStackExhausted, Stack.invokeNearLimit(&instance, 0));
    try std.testing.expect(instance.shared_backend_cache == null);
    try std.testing.expectEqual(@as(u64, 0), instance.shared_backend_stats.compiles);
    try std.testing.expectEqual(@as(u64, 0), instance.shared_backend_stats.entries);
}

test "backend tier: cached recursion does not retain compiler workspace on each frame" {
    if (!wasm.backend_prototype.native.supported) return error.SkipZigTest;
    const Worker = struct {
        failure: ?anyerror = null,
        fn run(self: *@This()) void {
            execute() catch |err| {
                self.failure = err;
            };
        }
        fn execute() !void {
            var arena = std.heap.ArenaAllocator.init(a);
            defer arena.deinit();
            const module: wasm.Module = .{
                .types = identity_module.types,
                .funcs = &.{0},
                .code = &.{.{ .bytes = &.{ 0, 0x20, 0, 0x45, 0x04, 0x7f, 0x41, 42, 0x05, 0x20, 0, 0x41, 1, 0x6b, 0x10, 0, 0x0b, 0x0b } }},
            };
            var instance: wasm.Instance = undefined;
            try wasm.instantiate(&instance, arena.allocator(), a, &module, .{});
            defer instance.deinit();
            instance.shared_backend_enabled = true;
            const result = wasm.invoke(&instance, a, 0, &.{256}) catch |err| {
                std.debug.print("cached recursion failed with {s} after {d} native entries\n", .{ @errorName(err), instance.shared_backend_stats.entries });
                return err;
            };
            defer a.free(result);
            try std.testing.expectEqualSlices(u128, &.{42}, result);
            try std.testing.expectEqual(@as(u64, 257), instance.shared_backend_stats.entries);
            try std.testing.expectEqual(@as(u64, 1), instance.shared_backend_stats.compiles);
        }
    };
    var worker: Worker = .{};
    const stack_size: usize = if (@import("builtin").optimize == .debug) 16 * 1024 * 1024 else 2 * 1024 * 1024;
    const thread = try std.Thread.spawn(.{ .stack_size = stack_size }, Worker.run, .{&worker});
    thread.join();
    if (worker.failure) |err| return err;
}

test "backend tier: a fallback callee can grow memory before the native caller loads it" {
    if (!wasm.backend_prototype.native.supported) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const module: wasm.Module = .{
        .types = &.{ .{ .params = &.{ .i32, .i32 }, .results = &.{.i32} }, .{ .params = &.{.i32}, .results = &.{.i32} } },
        .funcs = &.{ 0, 1 },
        // The callee grows, then enters an exception region to keep
        // this specifically a fallback-callee descriptor-refresh test.
        .code = &.{ .{ .bytes = &.{ 0, 0x20, 0, 0x10, 1, 0x1a, 0x20, 1, 0x28, 0, 0, 0x0b } }, .{ .bytes = &.{ 0, 0x20, 0, 0x40, 0, 0x1f, 0x40, 0, 0x0b, 0x0b } } },
        .mems = &.{.{ .limits = .{ .min = 1, .max = 2 } }},
    };
    var instance: wasm.Instance = undefined;
    try wasm.instantiate(&instance, arena.allocator(), a, &module, .{});
    defer instance.deinit();
    instance.shared_backend_enabled = true;
    const result = try wasm.invoke(&instance, a, 0, &.{ 1, wasm.PAGE_SIZE });
    defer a.free(result);
    try std.testing.expectEqualSlices(u128, &.{0}, result);
    try std.testing.expectEqual(@as(usize, 2 * wasm.PAGE_SIZE), instance.memories[0].data.len);
    try std.testing.expectEqual(@as(u64, 1), instance.shared_backend_stats.entries);
    try std.testing.expectEqual(@as(u64, 1), instance.shared_backend_stats.refusals);
}

test "backend tier: foreign fallback exceptions preserve their tag and payload" {
    if (!wasm.backend_prototype.native.supported) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const provider_module: wasm.Module = .{
        .types = &.{ .{ .params = &.{}, .results = &.{} }, .{ .params = &.{.i32}, .results = &.{} } },
        .funcs = &.{0},
        .tags = &.{.{ .attribute = 0, .type_index = 1 }},
        .code = &.{.{ .bytes = &.{ 0, 0x41, 37, 0x08, 0, 0x0b } }},
    };
    var provider: wasm.Instance = undefined;
    try wasm.instantiate(&provider, arena.allocator(), a, &provider_module, .{});
    defer provider.deinit();
    provider.shared_backend_enabled = true;
    const consumer_module: wasm.Module = .{
        .types = provider_module.types[0..1],
        .imports = &.{.{ .module = "provider", .name = "throw", .desc = .{ .func = 0 } }},
        .funcs = &.{0},
        .code = &.{.{ .bytes = &.{ 0, 0x10, 0, 0x0b } }},
    };
    var consumer: wasm.Instance = undefined;
    try wasm.instantiate(&consumer, arena.allocator(), a, &consumer_module, .{ .funcs = &.{provider.funcRefAt(0).?} });
    defer consumer.deinit();
    consumer.shared_backend_enabled = true;
    try std.testing.expectError(error.UncaughtException, wasm.invoke(&consumer, a, 1, &.{}));
    const exception = consumer.pending_exn orelse return error.MissingException;
    try std.testing.expectEqual(provider.tag_identities[0], exception.tag);
    try std.testing.expectEqualSlices(u128, &.{37}, exception.payload);
    try std.testing.expectEqual(@as(u64, 1), consumer.shared_backend_stats.entries);
    try std.testing.expectEqual(@as(u64, 1), provider.shared_backend_stats.refusals);
}

test "backend tier: allocation failures release cache metadata and invocation scratch" {
    if (!wasm.backend_prototype.native.supported) return error.SkipZigTest;
    var baseline = std.testing.FailingAllocator.init(a, .{});
    try allocationFailure(baseline.allocator());
    try std.testing.expectEqual(baseline.allocated_bytes, baseline.freed_bytes);
    for (0..baseline.alloc_index) |index| {
        var failing = std.testing.FailingAllocator.init(a, .{ .fail_index = index });
        allocationFailure(failing.allocator()) catch |err| if (err != error.OutOfMemory) return err;
        try std.testing.expect(failing.has_induced_failure);
        // Compilation can refuse before entry, and code-slot reclamation is
        // best-effort. Neither may retain metadata or an executable mapping.
        try std.testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
    }
}

test "backend tier: an invocation allocator never owns persistent cache metadata" {
    if (!wasm.backend_prototype.native.supported) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    var instance: wasm.Instance = undefined;
    try wasm.instantiate(&instance, arena.allocator(), a, &identity_module, .{});
    defer instance.deinit();
    instance.shared_backend_enabled = true;
    var scratch = std.testing.FailingAllocator.init(a, .{});
    instance.invocation_allocator = scratch.allocator();
    const result = try wasm.invoke(&instance, a, 0, &.{42});
    defer a.free(result);
    try std.testing.expectEqualSlices(u128, &.{42}, result);
    try std.testing.expect(scratch.allocated_bytes > 0);
    try std.testing.expectEqual(scratch.allocated_bytes, scratch.freed_bytes);
    try std.testing.expect(instance.shared_backend_cache != null);
}

fn allocationFailure(allocator: std.mem.Allocator) !void {
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    var instance: wasm.Instance = undefined;
    try wasm.instantiate(&instance, arena.allocator(), a, &identity_module, .{});
    defer instance.deinit();
    instance.shared_backend_enabled = true;
    instance.invocation_allocator = allocator;
    instance.shared_backend_allocator = allocator;
    const result = try wasm.invoke(&instance, a, 0, &.{42});
    defer a.free(result);
    try std.testing.expectEqualSlices(u128, &.{42}, result);
    // A compile-time OOM is deliberately a fallback. Expose it to the failure
    // injector so every allocation site is still exercised and leak-checked.
    if (instance.shared_backend_stats.last_refusal) |err| if (err == error.OutOfMemory) return error.OutOfMemory;
    try std.testing.expectEqual(@as(u64, 1), instance.shared_backend_stats.entries);
}

test "backend tier: Realm quota covers code metadata and transient scratch" {
    if (!wasm.backend_prototype.native.supported) return error.SkipZigTest;
    const Realm = @import("../realm.zig").Realm;
    var realm = Realm.init(a);
    defer realm.deinit();
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    var instance: wasm.Instance = undefined;
    try wasm.instantiate(&instance, arena.allocator(), a, &identity_module, .{});
    defer instance.deinit();
    instance.shared_backend_enabled = true;
    instance.invocation_allocator = realm.wasmInvocationAllocator();
    instance.shared_backend_allocator = realm.wasmStoreAllocator();
    instance.spasm_memory_ledger = realm.wasmCodeMemoryLedger();
    const baseline = realm.heap.bytes_live;
    realm.setMemoryLimit(baseline + 32 * 1024);
    const fallback = try wasm.invoke(&instance, a, 0, &.{42});
    defer a.free(fallback);
    try std.testing.expectEqualSlices(u128, &.{42}, fallback);
    try std.testing.expect(instance.shared_backend_cache_failed);
    try std.testing.expectEqual(@as(u64, 0), instance.shared_backend_stats.entries);
    try std.testing.expectEqual(baseline, realm.heap.bytes_live);
    try std.testing.expectEqual(@as(usize, 0), realm.wasm_code_bytes_live);
    realm.setMemoryLimit(std.math.maxInt(usize));
    instance.releaseExecutableCode();
    const first = try wasm.invoke(&instance, a, 0, &.{42});
    defer a.free(first);
    try std.testing.expectEqual(@as(u64, 1), instance.shared_backend_stats.entries);
    const retained = realm.heap.bytes_live;
    try std.testing.expect(retained > baseline + 64 * 1024);
    try std.testing.expectEqual(@as(usize, 64 * 1024), realm.wasm_code_bytes_live);
    for (0..8) |_| {
        const result = try wasm.invoke(&instance, a, 0, &.{42});
        a.free(result);
        try std.testing.expectEqual(retained, realm.heap.bytes_live);
    }
    realm.setMemoryLimit(retained);
    const entries = instance.shared_backend_stats.entries;
    try std.testing.expectError(error.OutOfMemory, wasm.invoke(&instance, a, 0, &.{42}));
    try std.testing.expectEqual(entries, instance.shared_backend_stats.entries);
    try std.testing.expectEqual(retained, realm.heap.bytes_live);
    instance.releaseExecutableCode();
    try std.testing.expectEqual(baseline, realm.heap.bytes_live);
    try std.testing.expectEqual(@as(usize, 0), realm.wasm_code_bytes_live);
}
