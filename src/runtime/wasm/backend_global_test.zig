const std = @import("std");
const wasm = @import("wasm.zig");
const prototype = wasm.backend_prototype;
const a = std.testing.allocator;

fn expectInvoke(instance: *wasm.Instance, tier: usize, index: u32, args: []const u128, expected: []const u128) !void {
    const entries = instance.shared_backend_stats.entries;
    const spasm_entries = instance.spasm_runs;
    const result = try wasm.invoke(instance, a, index, args);
    defer a.free(result);
    try std.testing.expectEqualSlices(u128, expected, result);
    if (tier == 1) try std.testing.expectEqual(spasm_entries + 1, instance.spasm_runs);
    if (tier == 2) try std.testing.expectEqual(entries + 1, instance.shared_backend_stats.entries);
}

test "backend globals: scalar bits, imported aliases and defined cells agree across tiers" {
    if (!prototype.native.supported) return error.SkipZigTest;
    for ([_]wasm.ValType{ .i32, .i64, .f32, .f64 }) |ty| for (0..3) |tier| {
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        const init: []const u8 = switch (ty) {
            .i32 => &.{ 0x41, 0, 0x0b },
            .i64 => &.{ 0x42, 0, 0x0b },
            .f32 => &.{ 0x43, 0, 0, 0, 0, 0x0b },
            else => &.{ 0x44, 0, 0, 0, 0, 0, 0, 0, 0, 0x0b },
        };
        const gt: wasm.types.GlobalType = .{ .val = ty, .mut = .mutable };
        const module: wasm.Module = .{
            .types = &.{.{ .params = &.{ty}, .results = &.{ ty, ty, ty, ty } }},
            .imports = &.{ .{ .module = "h", .name = "a", .desc = .{ .global = gt } }, .{ .module = "h", .name = "b", .desc = .{ .global = gt } } },
            .globals = &.{ .{ .type = .{ .val = ty, .mut = .immutable }, .init_expr = init }, .{ .type = gt, .init_expr = init } },
            .funcs = &.{0},
            .code = &.{.{ .bytes = &.{ 0, 0x23, 0, 0x20, 0, 0x24, 1, 0x23, 0, 0x23, 2, 0x20, 0, 0x24, 3, 0x23, 3, 0x0b } }},
        };
        var global: wasm.Global = .{ .value = 17, .mutable = true };
        var instance: wasm.Instance = undefined;
        try wasm.instantiate(&instance, arena.allocator(), a, &module, .{ .globals = &.{ &global, &global } });
        defer instance.deinit();
        instance.spasm_enabled = tier == 1;
        instance.shared_backend_enabled = tier == 2;
        const bits = [_]u64{ 0, 0x8000_0000, 0xffff_ffff, 0x7f80_0001, 0x7fc0_1234, 0x8000_0000_0000_0000, 0x7ff0_0000_0000_0001, 0xfff8_1234_5678_9abc, 0xffff_ffff_ffff_ffff };
        for (bits) |raw| {
            const value: u128 = if (ty == .i32 or ty == .f32) @as(u32, @truncate(raw)) else raw;
            const old = global.value;
            try expectInvoke(&instance, tier, 0, &.{value}, &.{ old, value, 0, value });
            try std.testing.expectEqual(value, global.value);
            try std.testing.expectEqual(value, instance.globals[3].value);
        }
    };
}

test "backend globals: callees update aliased cells and refresh linear memory views" {
    if (!prototype.native.supported) return error.SkipZigTest;
    const Host = struct {
        global: *wasm.Global,
        memory: ?*wasm.Memory = null,
        fn invoke(raw: ?*anyopaque, _: []const u128, _: []u128) wasm.TrapError!void {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            self.global.value = 42;
            _ = wasm.interpreter.growMemory(a, self.memory.?, 1) orelse return error.OutOfMemory;
        }
    };
    for (0..3) |tier| {
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        const gt: wasm.types.GlobalType = .{ .val = .i32, .mut = .mutable };
        const module: wasm.Module = .{
            .types = &.{ .{ .params = &.{}, .results = &.{} }, .{ .params = &.{}, .results = &.{ .i32, .i32, .i32 } } },
            .imports = &.{ .{ .module = "h", .name = "f", .desc = .{ .func = 0 } }, .{ .module = "h", .name = "a", .desc = .{ .global = gt } }, .{ .module = "h", .name = "b", .desc = .{ .global = gt } } },
            .funcs = &.{1},
            .mems = &.{.{ .limits = .{ .min = 1, .max = 3 } }},
            .code = &.{.{ .bytes = &.{ 0, 0x23, 0, 0x10, 0, 0x23, 1, 0x41, 1, 0x40, 0, 0x1a, 0x3f, 0, 0x0b } }},
        };
        var global: wasm.Global = .{ .value = 7, .mutable = true };
        var host: Host = .{ .global = &global };
        var instance: wasm.Instance = undefined;
        try wasm.instantiate(&instance, arena.allocator(), a, &module, .{ .globals = &.{ &global, &global }, .funcs = &.{.{ .host = .{ .fn_ptr = Host.invoke, .ctx = &host, .params = 0, .results = 0 } }} });
        defer instance.deinit();
        host.memory = instance.memories[0];
        instance.spasm_enabled = tier == 1;
        instance.shared_backend_enabled = tier == 2;
        try expectInvoke(&instance, tier, 1, &.{}, &.{ 7, 42, 3 });
    }
}

test "backend globals: cross-instance callees keep shared cell identity in every tier" {
    if (!prototype.native.supported) return error.SkipZigTest;
    for (0..3) |tier| {
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        const provider_module: wasm.Module = .{
            .types = &.{.{ .params = &.{}, .results = &.{} }},
            .globals = &.{.{ .type = .{ .val = .i32, .mut = .mutable }, .init_expr = &.{ 0x41, 7, 0x0b } }},
            .funcs = &.{0},
            .code = &.{.{ .bytes = &.{ 0, 0x41, 42, 0x24, 0, 0x0b } }},
        };
        var provider: wasm.Instance = undefined;
        try wasm.instantiate(&provider, arena.allocator(), a, &provider_module, .{});
        defer provider.deinit();
        provider.spasm_enabled = tier == 1;
        provider.shared_backend_enabled = tier == 2;
        const consumer_module: wasm.Module = .{
            .types = &.{ provider_module.types[0], .{ .params = &.{}, .results = &.{ .i32, .i32 } } },
            .imports = &.{ .{ .module = "p", .name = "f", .desc = .{ .func = 0 } }, .{ .module = "p", .name = "g", .desc = .{ .global = provider_module.globals[0].type } } },
            .funcs = &.{1},
            .code = &.{.{ .bytes = &.{ 0, 0x23, 0, 0x10, 0, 0x23, 0, 0x0b } }},
        };
        var consumer: wasm.Instance = undefined;
        try wasm.instantiate(&consumer, arena.allocator(), a, &consumer_module, .{ .funcs = &.{provider.funcRefAt(0).?}, .globals = &.{provider.globals[0]} });
        defer consumer.deinit();
        consumer.shared_backend_enabled = true;
        try expectInvoke(&consumer, 2, 1, &.{}, &.{ 7, 42 });
        try std.testing.expectEqual(@as(u64, @intFromBool(tier == 2)), provider.shared_backend_stats.entries);
        try std.testing.expectEqual(@as(u32, @intFromBool(tier == 1)), provider.spasm_runs);
        try std.testing.expectEqual(@as(u128, 42), provider.globals[0].value);
    }
}

test "backend globals: completed writes survive a later trap without replay" {
    if (!prototype.native.supported) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const module: wasm.Module = .{
        .types = &.{.{ .params = &.{}, .results = &.{} }},
        .globals = &.{.{ .type = .{ .val = .i32, .mut = .mutable }, .init_expr = &.{ 0x41, 5, 0x0b } }},
        .funcs = &.{0},
        .code = &.{.{ .bytes = &.{ 0, 0x23, 0, 0x41, 1, 0x6a, 0x24, 0, 0, 0x0b } }},
    };
    var instance: wasm.Instance = undefined;
    try wasm.instantiate(&instance, arena.allocator(), a, &module, .{});
    defer instance.deinit();
    instance.shared_backend_enabled = true;
    instance.spasm_enabled = true;
    try std.testing.expectError(error.Unreachable, wasm.invoke(&instance, a, 0, &.{}));
    try std.testing.expectEqual(@as(u128, 6), instance.globals[0].value);
    try std.testing.expectEqual(@as(u64, 1), instance.shared_backend_stats.entries);
    try std.testing.expectEqual(@as(u32, 0), instance.spasm_runs);
}

test "backend globals: unused globals do not consume the native view budget" {
    if (!prototype.native.supported) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    var globals: [prototype.ir.max_memories + 2]wasm.module.Global = undefined;
    @memset(&globals, .{ .type = .{ .val = .i32, .mut = .mutable }, .init_expr = &.{ 0x41, 0, 0x0b } });
    const index = globals.len - 1;
    const module: wasm.Module = .{
        .types = &.{.{ .params = &.{.i32}, .results = &.{.i32} }},
        .globals = &globals,
        .funcs = &.{0},
        .code = &.{.{ .bytes = &.{ 0, 0x20, 0, 0x24, index, 0x23, index, 0x0b } }},
    };
    var instance: wasm.Instance = undefined;
    try wasm.instantiate(&instance, arena.allocator(), a, &module, .{});
    defer instance.deinit();
    instance.shared_backend_enabled = true;
    try expectInvoke(&instance, 2, 0, &.{123}, &.{123});
    try std.testing.expectEqual(@as(u128, 0), instance.globals[0].value);
}

const alias_module: wasm.Module = .{
    .types = &.{.{ .params = &.{.i32}, .results = &.{ .i32, .i32 } }},
    .imports = &.{
        .{ .module = "h", .name = "a", .desc = .{ .global = .{ .val = .i32, .mut = .mutable } } },
        .{ .module = "h", .name = "b", .desc = .{ .global = .{ .val = .i32, .mut = .mutable } } },
    },
    .funcs = &.{0},
    .code = &.{.{ .bytes = &.{ 0, 0x23, 0, 0x20, 0, 0x24, 1, 0x23, 0, 0x0b } }},
};

test "backend globals: bindings outlive graphs and remain instance-relative in every mode" {
    if (!prototype.native.supported) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    var first_global: wasm.Global = .{ .value = 0, .mutable = true };
    var second_global: wasm.Global = .{ .value = 0, .mutable = true };
    var first: wasm.Instance = undefined;
    try wasm.instantiate(&first, arena.allocator(), a, &alias_module, .{ .globals = &.{ &first_global, &first_global } });
    defer first.deinit();
    var second: wasm.Instance = undefined;
    try wasm.instantiate(&second, arena.allocator(), a, &alias_module, .{ .globals = &.{ &second_global, &second_global } });
    defer second.deinit();
    var owner = try prototype.CodeAllocator.init(a, 256 * 1024);
    defer owner.deinit();
    const Mode = @import("../jit/backend/allocation.zig").Mode;
    for ([_]Mode{ .scratch, .linear_scan }) |mode| for (0..16) |flags| for ([_]u8{ 0, 1, 4 }) |registers| {
        var code = blk: {
            var graph = try prototype.lowerInstance(a, &first, 0);
            defer graph.deinit();
            try std.testing.expectEqualSlices(u32, &.{ 0, 1 }, graph.global_indices);
            break :blk try prototype.compile(a, &owner, &graph, .{
                .allocation = mode,
                .register_count = registers,
                .rematerialize_constants = flags & 8 != 0,
                .optimization = .{ .constant_folding = flags & 1 != 0, .common_subexpression_elimination = flags & 2 != 0, .dead_code_elimination = flags & 4 != 0 },
            });
        };
        defer code.deinit();
        try std.testing.expectEqual(@as(usize, 0), code.code.call_sites.len);
        try std.testing.expectEqual(@as(u32, 2), code.code.memory_count);
        first_global.value = 17;
        second_global.value = 91;
        for ([_]*wasm.Instance{ &first, &second }, [_]u64{ 17, 91 }) |instance, old| {
            var values: [2]u64 = undefined;
            var result = try prototype.runResultsInInstance(&code, instance, &.{0xffff_ffff}, 1, &values);
            defer result.deinit();
            try std.testing.expect(result == .returned);
            try std.testing.expectEqualSlices(u64, &.{ old, 0xffff_ffff }, &values);
        }
        try std.testing.expectEqual(@as(u128, 0xffff_ffff), first_global.value);
        try std.testing.expectEqual(first_global.value, second_global.value);
    };
}

fn globalAllocationFailures(allocator: std.mem.Allocator, owner: *prototype.CodeAllocator, instance: *wasm.Instance) !void {
    var graph = try prototype.lowerInstance(allocator, instance, 0);
    defer graph.deinit();
    var code = try prototype.compile(allocator, owner, &graph, .{});
    defer code.deinit();
    instance.globals[0].value = 17;
    var values: [2]u64 = undefined;
    var result = try prototype.runResultsInInstance(&code, instance, &.{42}, 1, &values);
    defer result.deinit();
    try std.testing.expect(result == .returned);
    try std.testing.expectEqualSlices(u64, &.{ 17, 42 }, &values);
}

test "backend globals: allocation failures release bindings and compiler workspace" {
    if (!prototype.native.supported) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    var global: wasm.Global = .{ .value = 0, .mutable = true };
    var instance: wasm.Instance = undefined;
    try wasm.instantiate(&instance, arena.allocator(), a, &alias_module, .{ .globals = &.{ &global, &global } });
    defer instance.deinit();
    var owner = try prototype.CodeAllocator.init(a, 256 * 1024);
    defer owner.deinit();
    // Arena growth must allocate so failure indices do not depend on whether
    // the backing allocator can extend a particular mapping in place.
    var no_resize = std.testing.FailingAllocator.init(a, .{ .resize_fail_index = 0 });
    try std.testing.checkAllAllocationFailures(no_resize.allocator(), globalAllocationFailures, .{ &owner, &instance });
}

test "backend globals: vector cells lower in live and dead code but unused imports stay unbound" {
    for ([_]wasm.ValType{.v128}) |ty| {
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        const module: wasm.Module = .{
            .types = &.{.{ .params = &.{}, .results = &.{.i32} }},
            .imports = &.{.{ .module = "h", .name = "g", .desc = .{ .global = .{ .val = ty, .mut = .immutable } } }},
            .funcs = &.{ 0, 0, 0 },
            .code = &.{
                .{ .bytes = &.{ 0, 0x41, 42, 0x0b } },
                .{ .bytes = &.{ 0, 0x23, 0, 0x1a, 0x41, 42, 0x0b } },
                .{ .bytes = &.{ 0, 0, 0x23, 0, 0x1a, 0x0b } },
            },
        };
        var global: wasm.Global = .{ .value = 0, .mutable = false };
        var instance: wasm.Instance = undefined;
        try wasm.instantiate(&instance, arena.allocator(), a, &module, .{ .globals = &.{&global} });
        defer instance.deinit();
        var graph = try prototype.lowerInstance(a, &instance, 0);
        defer graph.deinit();
        try std.testing.expectEqual(@as(usize, 0), graph.global_indices.len);
        for ([_]u32{ 1, 2 }) |index| {
            var used = try prototype.lowerInstance(a, &instance, index);
            defer used.deinit();
            try used.graph.verify();
            try std.testing.expectEqualSlices(u32, &.{0}, used.global_indices);
        }
    }
    var invalid = alias_module;
    invalid.imports = &.{
        alias_module.imports[0],
        .{ .module = "h", .name = "b", .desc = .{ .global = .{ .val = .i32, .mut = .immutable } } },
    };
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    try std.testing.expectError(error.ImmutableGlobal, wasm.validateModule(arena.allocator(), &invalid));
}

test "backend globals: linear memories and used globals share the bounded view budget" {
    for ([_]usize{ prototype.ir.max_memories - 1, prototype.ir.max_memories }) |count| {
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        var globals: [prototype.ir.max_memories]wasm.module.Global = undefined;
        @memset(&globals, .{ .type = .{ .val = .i32, .mut = .immutable }, .init_expr = &.{ 0x41, 0, 0x0b } });
        var body: std.ArrayList(u8) = .empty;
        try body.append(arena.allocator(), 0);
        for (0..count) |index| try body.appendSlice(arena.allocator(), &.{ 0x23, @intCast(index), 0x1a });
        try body.append(arena.allocator(), 0x0b);
        const module: wasm.Module = .{
            .types = &.{.{ .params = &.{}, .results = &.{} }},
            .globals = &globals,
            .mems = &.{.{ .limits = .{ .min = 0 } }},
            .funcs = &.{0},
            .code = &.{.{ .bytes = body.items }},
        };
        var instance: wasm.Instance = undefined;
        try wasm.instantiate(&instance, arena.allocator(), a, &module, .{});
        defer instance.deinit();
        if (count == prototype.ir.max_memories) {
            try std.testing.expectError(error.PrototypeLimit, prototype.lowerInstance(a, &instance, 0));
        } else {
            var graph = try prototype.lowerInstance(a, &instance, 0);
            defer graph.deinit();
            try std.testing.expectEqual(@as(u32, prototype.ir.max_memories), graph.graph.memory_count);
            if (!prototype.native.supported) continue;
            var owner = try prototype.CodeAllocator.init(a, 256 * 1024);
            defer owner.deinit();
            var bounded = try prototype.compile(a, &owner, &graph, .{});
            defer bounded.deinit();
            var result = try prototype.runResultsInInstance(&bounded, &instance, &.{}, 1, &.{});
            defer result.deinit();
            try std.testing.expect(result == .returned);
            var controlled = try prototype.compile(a, &owner, &graph, .{ .execution_policy = .controlled });
            defer controlled.deinit();
            // The adapter's overflow buffer and native scratch both precede entry.
            for (0..3) |fail_index| {
                var failing = std.testing.FailingAllocator.init(a, .{ .fail_index = fail_index });
                var entries: u64 = 0;
                if (fail_index < 2) {
                    try std.testing.expectError(error.OutOfMemory, prototype.runControlledInInstance(&controlled, failing.allocator(), &instance, &.{}, null, &entries, &.{}));
                    try std.testing.expectEqual(@as(u64, 0), entries);
                    try std.testing.expect(failing.has_induced_failure);
                } else {
                    var completion = try prototype.runControlledInInstance(&controlled, failing.allocator(), &instance, &.{}, null, &entries, &.{});
                    defer completion.deinit();
                    try std.testing.expect(completion == .returned);
                    try std.testing.expectEqual(@as(u64, 1), entries);
                }
                try std.testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
            }
        }
    }
}
