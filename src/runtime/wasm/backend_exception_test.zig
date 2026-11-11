const std = @import("std");
const wasm = @import("wasm.zig");
const frontend = @import("backend_prototype.zig");
const a = std.testing.allocator;

const types: []const wasm.FuncType = &.{
    .{ .params = &.{}, .results = &.{.i32} },
    .{ .params = &.{.i32}, .results = &.{} },
    .{ .params = &.{.i32}, .results = &.{.i32} },
    .{ .params = &.{}, .results = &.{} },
    .{ .params = &.{}, .results = &.{ .i32, .exnref } },
};

fn expectNative(module: *const wasm.Module, index: u32, expected: anyerror!u128, compiled: u64) !void {
    if (!frontend.native.supported) return error.SkipZigTest;
    for ([_]bool{ false, true }) |shared| {
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        var instance: wasm.Instance = undefined;
        try wasm.instantiate(&instance, arena.allocator(), a, module, .{});
        defer instance.deinit();
        instance.spasm_enabled = false;
        instance.shared_backend_enabled = shared;
        instance.shared_backend_diagnostics = true;
        if (expected) |value| {
            const result = try wasm.invoke(&instance, a, index, &.{});
            defer a.free(result);
            try std.testing.expectEqualSlices(u128, &.{value}, result);
        } else |err| {
            try std.testing.expectError(err, wasm.invoke(&instance, a, index, &.{}));
            if (err == error.UncaughtException) {
                const record = instance.pending_exn orelse return error.MissingException;
                try std.testing.expectEqual(instance.tag_identities[0], record.tag);
                try std.testing.expectEqualSlices(u128, &.{9}, record.payload);
            }
        }
        if (shared) {
            try std.testing.expectEqual(@as(u64, 0), instance.shared_backend_stats.refusals);
            try std.testing.expectEqual(compiled, instance.shared_backend_stats.compiles);
            try std.testing.expectEqual(compiled, instance.shared_backend_stats.entries);
        }
    }
}

test "backend exceptions: catches, references, scope, and block parameters stay native" {
    const Case = struct { body: []const u8, expected: anyerror!u128 };
    const cases: []const Case = &.{
        // Catch the direct throw's i32 payload.
        .{ .body = &.{ 0, 0x02, 0x7f, 0x1f, 0x7f, 1, 0, 0, 0, 0x41, 9, 0x08, 0, 0x0b, 0x0b, 0x0b }, .expected = 9 },
        // Preserve a stack prefix and the current, mutated local on the catch edge.
        .{ .body = &.{ 1, 1, 0x7f, 0x41, 3, 0x02, 0x7f, 0x41, 9, 0x1f, 2, 1, 0, 0, 0, 0x41, 7, 0x21, 0, 0x08, 0, 0x0b, 0x0b, 0x6a, 0x20, 0, 0x6a, 0x0b }, .expected = 19 },
        // catch_ref carries both payload and exnref.
        .{ .body = &.{ 0, 0x02, 4, 0x1f, 4, 1, 1, 0, 0, 0x41, 9, 0x08, 0, 0x0b, 0x0b, 0x1a, 0x0b }, .expected = 9 },
        // catch_all_ref followed by throw_ref reaches the enclosing typed catch.
        .{ .body = &.{ 0, 0x02, 0x7f, 0x1f, 0x7f, 1, 0, 0, 0, 0x02, 0x69, 0x1f, 0x69, 1, 3, 0, 0x41, 9, 0x08, 0, 0x0b, 0x0b, 0x0a, 0x0b, 0x0b, 0x0b }, .expected = 9 },
        // Equal signatures do not make distinct tags match; catch_all runs second.
        .{ .body = &.{ 0, 0x02, 0x40, 0x1f, 0x40, 2, 0, 1, 0, 2, 0, 0x08, 2, 0x0b, 0x0b, 0x41, 42, 0x0b }, .expected = 42 },
        // A completed handler cannot catch a subsequent throw.
        .{ .body = &.{ 0, 0x02, 0x40, 0x1f, 0x40, 1, 2, 0, 0x01, 0x0b, 0x0b, 0x41, 9, 0x08, 0, 0x0b }, .expected = error.UncaughtException },
        // Non-matching handlers preserve the uncaught tag and payload.
        .{ .body = &.{ 0, 0x02, 0x40, 0x1f, 0x40, 1, 0, 1, 0, 0x41, 9, 0x08, 0, 0x0b, 0x0b, 0x41, 0, 0x0b }, .expected = error.UncaughtException },
        // A null exnref and a numeric trap are not exceptions catch_all can catch.
        .{ .body = &.{ 0, 0x02, 0x40, 0x1f, 0x40, 1, 2, 0, 0xd0, 0x69, 0x0a, 0x0b, 0x0b, 0x41, 0, 0x0b }, .expected = error.NullExnRef },
        .{ .body = &.{ 0, 0x02, 0x40, 0x1f, 0x40, 1, 2, 0, 0x41, 1, 0x41, 0, 0x6d, 0x1a, 0x0b, 0x0b, 0x41, 0, 0x0b }, .expected = error.IntegerDivideByZero },
    };
    for (cases) |case| {
        const module: wasm.Module = .{
            .types = types,
            .tags = &.{ .{ .attribute = 0, .type_index = 1 }, .{ .attribute = 0, .type_index = 3 }, .{ .attribute = 0, .type_index = 3 } },
            .funcs = &.{0},
            .code = &.{.{ .bytes = case.body }},
        };
        try expectNative(&module, 0, case.expected, 1);
    }
}

test "backend exceptions: native callees propagate through native caller handlers" {
    const module: wasm.Module = .{
        .types = types,
        .tags = &.{.{ .attribute = 0, .type_index = 1 }},
        .funcs = &.{ 0, 0 },
        .code = &.{
            .{ .bytes = &.{ 0, 0x41, 9, 0x08, 0, 0x0b } },
            .{ .bytes = &.{ 0, 0x02, 0x7f, 0x1f, 0x7f, 1, 0, 0, 0, 0x10, 0, 0x0b, 0x0b, 0x41, 1, 0x6a, 0x0b } },
        },
    };
    try expectNative(&module, 1, 10, 2);
}

test "backend exceptions: proper tail calls remove the current handler" {
    const module: wasm.Module = .{
        .types = types,
        .tags = &.{.{ .attribute = 0, .type_index = 1 }},
        .funcs = &.{ 0, 0 },
        .code = &.{
            .{ .bytes = &.{ 0, 0x41, 9, 0x08, 0, 0x0b } },
            .{ .bytes = &.{ 0, 0x02, 0x7f, 0x1f, 0x7f, 1, 0, 0, 0, 0x12, 0, 0x0b, 0x0b, 0x0b } },
        },
    };
    try expectNative(&module, 1, error.UncaughtException, 2);
}

test "backend exceptions: a local catch without exnref does not retain records" {
    if (!frontend.native.supported) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const module: wasm.Module = .{
        .types = types,
        .tags = &.{.{ .attribute = 0, .type_index = 1 }},
        .funcs = &.{0},
        .code = &.{.{ .bytes = &.{ 0, 0x02, 0x7f, 0x1f, 0x7f, 1, 0, 0, 0, 0x41, 9, 0x08, 0, 0x0b, 0x0b, 0x0b } }},
    };
    var instance: wasm.Instance = undefined;
    try wasm.instantiate(&instance, arena.allocator(), a, &module, .{});
    defer instance.deinit();
    instance.spasm_enabled = false;
    instance.shared_backend_enabled = true;
    instance.shared_backend_diagnostics = true;
    for (0..100) |_| {
        const result = try wasm.invoke(&instance, a, 0, &.{});
        defer a.free(result);
        try std.testing.expectEqualSlices(u128, &.{9}, result);
    }
    try std.testing.expectEqual(@as(u64, 100), instance.shared_backend_stats.entries);
    try std.testing.expectEqual(@as(u64, 0), instance.shared_backend_stats.refusals);
    try std.testing.expectEqual(@as(usize, 0), instance.exn_pool.items.len);
}

test "backend exceptions: retained exception records root payloads and original JS values" {
    const Realm = @import("../realm.zig").Realm;
    const heap = @import("../heap.zig");
    var realm = Realm.init(a);
    defer realm.deinit();
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const module: wasm.Module = .{};
    var instance: wasm.Instance = undefined;
    try wasm.instantiate(&instance, arena.allocator(), a, &module, .{});
    defer instance.deinit();
    try realm.registerWasmInstance(&instance);
    defer realm.unregisterWasmInstance(&instance);
    const payload = try realm.heap.allocateObject();
    const original = try realm.heap.allocateObject();
    const tag: wasm.TagType = .{ .params = &.{.externref} };
    _ = instance.internExnRecord(&tag, &.{heap.taggedObject(payload).bits}, heap.taggedObject(original).bits) orelse return error.OutOfMemory;
    for (0..2) |_| {
        realm.collectGarbageYoung();
        realm.collectGarbage();
        // Check allocation counts before dereferencing a potentially freed value.
        try std.testing.expectEqual(@as(usize, 2), realm.heap.objectCount());
    }
}

test "backend exceptions: caught host throws refresh memory and retain error distinctions" {
    if (!frontend.native.supported) return error.SkipZigTest;
    const Host = struct {
        instance: *wasm.Instance,
        failure: wasm.TrapError = error.HostThrew,
        conversions: usize = 0,
        fn invoke(raw: ?*anyopaque, _: []const u128, _: []u128) wasm.TrapError!void {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            _ = wasm.interpreter.growMemory(a, self.instance.memories[0], 1);
            return self.failure;
        }
        fn convert(raw: *anyopaque, owner: *wasm.Instance) ?*wasm.ExnRecord {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.conversions += 1;
            return owner.internExnRecord(owner.tag_identities[0], &.{9}, wasm.REF_NULL);
        }
    };
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const module: wasm.Module = .{
        .types = types,
        .tags = &.{.{ .attribute = 0, .type_index = 1 }},
        .imports = &.{.{ .module = "host", .name = "throw", .desc = .{ .func = 3 } }},
        .funcs = &.{0},
        .mems = &.{.{ .limits = .{ .min = 1, .max = 2 } }},
        // Catch, discard the payload, and load from the newly grown page.
        .code = &.{.{ .bytes = &.{ 0, 0x02, 0x7f, 0x1f, 0x7f, 1, 0, 0, 0, 0x10, 0, 0x41, 0, 0x0b, 0x0b, 0x1a, 0x41, 0x80, 0x80, 4, 0x28, 0, 0, 0x0b } }},
    };
    var instance: wasm.Instance = undefined;
    var host: Host = .{ .instance = &instance };
    try wasm.instantiate(&instance, arena.allocator(), a, &module, .{ .funcs = &.{.{ .host = .{ .fn_ptr = Host.invoke, .ctx = &host, .params = 0, .results = 0 } }} });
    defer instance.deinit();
    instance.host_exn_ctx = &host;
    instance.host_exn_hook = Host.convert;
    instance.spasm_enabled = false;
    instance.shared_backend_enabled = true;
    instance.shared_backend_diagnostics = true;
    const result = try wasm.invoke(&instance, a, 1, &.{});
    defer a.free(result);
    try std.testing.expectEqualSlices(u128, &.{0}, result);
    try std.testing.expectEqual(@as(usize, 1), host.conversions);
    for ([_]wasm.TrapError{ error.OutOfMemory, error.ExecutionTerminated, error.IntegerDivideByZero }) |failure| {
        host.failure = failure;
        try std.testing.expectError(failure, wasm.invoke(&instance, a, 1, &.{}));
        try std.testing.expectEqual(@as(usize, 1), host.conversions);
    }
    try std.testing.expectEqual(@as(u64, 4), instance.shared_backend_stats.entries);
    try std.testing.expectEqual(@as(u64, 0), instance.shared_backend_stats.refusals);
}

test "backend exceptions: all payload types survive native catch transfers bit for bit" {
    if (!frontend.native.supported) return error.SkipZigTest;
    const payload_types: []const wasm.ValType = &.{ .i32, .i64, .f32, .f64, .v128, .externref, .funcref, .exnref };
    const module: wasm.Module = .{
        .types = &.{
            .{ .params = payload_types, .results = payload_types },
            .{ .params = payload_types, .results = &.{} },
            .{ .params = &.{}, .results = payload_types },
        },
        .tags = &.{.{ .attribute = 0, .type_index = 1 }},
        .funcs = &.{0},
        .code = &.{.{ .bytes = &.{ 0, 0x02, 2, 0x1f, 2, 1, 0, 0, 0, 0x20, 0, 0x20, 1, 0x20, 2, 0x20, 3, 0x20, 4, 0x20, 5, 0x20, 6, 0x20, 7, 0x08, 0, 0x0b, 0x0b, 0x0b } }},
    };
    const values: []const u128 = &.{ 0xffff_ffff, 0xfedc_ba98_7654_3210, 0x7fc1_2345, 0x8000_0000_0000_0000, 0x0123456789abcdef_fedcba9876543210, 0x1234567800000000_7654321087654321, wasm.REF_NULL, wasm.REF_NULL };
    for ([_]bool{ false, true }) |shared| {
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        var instance: wasm.Instance = undefined;
        try wasm.instantiate(&instance, arena.allocator(), a, &module, .{});
        defer instance.deinit();
        instance.spasm_enabled = false;
        instance.shared_backend_enabled = shared;
        instance.shared_backend_diagnostics = true;
        const result = try wasm.invoke(&instance, a, 0, values);
        defer a.free(result);
        try std.testing.expectEqualSlices(u128, values, result);
        if (shared) {
            try std.testing.expectEqual(@as(u64, 1), instance.shared_backend_stats.entries);
            try std.testing.expectEqual(@as(u64, 0), instance.shared_backend_stats.refusals);
        }
    }
}

test "backend exceptions: imported tag identity wins over equal local signatures" {
    if (!frontend.native.supported) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const provider_module: wasm.Module = .{
        .types = types,
        .tags = &.{.{ .attribute = 0, .type_index = 1 }},
        .funcs = &.{0},
        .code = &.{.{ .bytes = &.{ 0, 0x41, 9, 0x08, 0, 0x0b } }},
    };
    var provider: wasm.Instance = undefined;
    try wasm.instantiate(&provider, arena.allocator(), a, &provider_module, .{});
    defer provider.deinit();
    provider.shared_backend_enabled = true;
    provider.shared_backend_diagnostics = true;
    provider.spasm_enabled = false;
    const module: wasm.Module = .{
        .types = types,
        .imports = &.{ .{ .module = "p", .name = "throw", .desc = .{ .func = 0 } }, .{ .module = "p", .name = "tag", .desc = .{ .tag = 1 } } },
        .tags = &.{.{ .attribute = 0, .type_index = 1 }},
        .funcs = &.{0},
        .code = &.{.{ .bytes = &.{ 0, 0x02, 0x7f, 0x02, 0x7f, 0x1f, 0x7f, 2, 0, 1, 0, 0, 0, 1, 0x10, 0, 0x0b, 0x0b, 0x41, 1, 0x6a, 0x0b, 0x0b } }},
    };
    var consumer: wasm.Instance = undefined;
    try wasm.instantiate(&consumer, arena.allocator(), a, &module, .{ .funcs = &.{provider.funcRefAt(0).?}, .tags = &.{provider.tag_identities[0]} });
    defer consumer.deinit();
    consumer.shared_backend_enabled = true;
    consumer.shared_backend_diagnostics = true;
    consumer.spasm_enabled = false;
    const result = try wasm.invoke(&consumer, a, 1, &.{});
    defer a.free(result);
    try std.testing.expectEqualSlices(u128, &.{9}, result);
    for ([_]*wasm.Instance{ &provider, &consumer }) |instance| {
        try std.testing.expectEqual(@as(u64, 1), instance.shared_backend_stats.entries);
        try std.testing.expectEqual(@as(u64, 0), instance.shared_backend_stats.refusals);
    }
}

test "backend exceptions: record creation, capture, and propagation are allocation-safe" {
    const Exercise = struct {
        fn run(allocator: std.mem.Allocator, mode: u32) !void {
            const exceptions = @import("backend_exceptions.zig");
            var arena = std.heap.ArenaAllocator.init(a);
            defer arena.deinit();
            const module: wasm.Module = .{ .types = types, .tags = &.{.{ .attribute = 0, .type_index = 1 }} };
            var instance: wasm.Instance = undefined;
            try wasm.instantiate(&instance, arena.allocator(), allocator, &module, .{});
            defer instance.deinit();
            var state: exceptions.State = .{};
            defer state.deinit(allocator);
            const request: frontend.native.CallRequest = .{
                .target = 0,
                .site = 0,
                .safepoint = 0,
                .arguments = &.{9},
                .parameter_types = &.{.i32},
                .results = &.{},
                .result_types = &.{},
                .captures = &.{},
                .memories = &.{},
            };
            exceptions.raise(&state, &instance, 0, request, true) catch |err| switch (err) {
                error.UncaughtException => {},
                else => return err,
            };
            try std.testing.expect(state.classify(&instance, error.UncaughtException));
            if (mode == 4) {
                state.propagate(&instance) catch |err| switch (err) {
                    error.UncaughtException => {},
                    else => return err,
                };
                try std.testing.expectEqualSlices(u128, &.{9}, instance.pending_exn.?.payload);
            } else {
                var results: [3]u64 = undefined;
                var output = request;
                output.arguments = &.{};
                output.parameter_types = &.{};
                output.results = results[0..if (mode == 3) @as(usize, 3) else 1];
                output.result_types = if (mode == 3) &.{ .i32, .i64, .i64 } else &.{.i32};
                try state.payload(&instance, mode, output);
                try std.testing.expectEqual(@as(u64, 9), results[0]);
                try std.testing.expectEqual(@as(usize, if (mode == 3) 1 else 0), instance.exn_pool.items.len);
            }
        }
    };
    for ([_]u32{ 1, 3, 4 }) |mode| try std.testing.checkAllAllocationFailures(a, Exercise.run, .{mode});
}

test "backend exceptions: JS host throws survive collecting reentry and stored exnrefs" {
    if (!frontend.native.supported) return error.SkipZigTest;
    const Realm = @import("../realm.zig").Realm;
    const lantern = @import("../lantern/interpreter.zig");
    var realm = Realm.init(a);
    defer realm.deinit();
    realm.allow_wasm_compile = true;
    realm.jit_enabled = true;
    realm.wasm_shared_backend_enabled = true;
    try realm.installBuiltins();
    try realm.installTestGlobals();
    const setup = try lantern.evaluateScript(a, &realm,
        \\let exceptionWeak;
        \\const exceptionInstance = new WebAssembly.Instance(new WebAssembly.Module(new Uint8Array([
        \\  0,97,115,109,1,0,0,0,1,4,1,96,0,0,2,7,1,1,104,1,102,0,0,
        \\  3,3,2,0,0,6,6,1,105,1,208,105,11,
        \\  7,16,2,4,115,97,118,101,0,1,5,97,103,97,105,110,0,2,
        \\  10,25,2,17,0,2,105,31,105,1,3,0,16,0,208,105,11,11,36,0,11,
        \\  5,0,35,0,10,11
        \\])), {h: {f() {
        \\  const value = {answer: 42}; exceptionWeak = new WeakRef(value);
        \\  __clearKeptObjects(); __collectGarbage(); throw value;
        \\}}});
        \\42;
    );
    try std.testing.expect(setup == .value and setup.value.asInt32() == 42);
    realm.heap.setGcThreshold(1);
    const result = try lantern.evaluateScript(a, &realm,
        \\exceptionInstance.exports.save();
        \\__clearKeptObjects(); __collectGarbage();
        \\let caught = false;
        \\try { exceptionInstance.exports.again(); }
        \\catch (value) { caught = value === exceptionWeak.deref() && value.answer === 42; }
        \\caught;
    );
    try std.testing.expect(result == .value and result.value.isBool() and result.value.asBool());
    try std.testing.expectEqual(@as(usize, 1), realm.wasm_instances.items.len);
    const instance = realm.wasm_instances.items[0];
    try std.testing.expectEqual(@as(u64, 2), instance.shared_backend_stats.entries);
    try std.testing.expectEqual(@as(u64, 2), instance.shared_backend_stats.compiles);
    try std.testing.expectEqual(@as(u64, 0), instance.shared_backend_stats.refusals);
    try std.testing.expectEqual(@as(usize, 0), realm.wasm_extern_roots.count());
}
