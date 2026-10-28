const std = @import("std");
const wasm = @import("wasm.zig");
const prototype = @import("backend_prototype.zig");
const native = prototype.native;
const a = std.testing.allocator;

test "backend memory: Wasm scalar accesses match Sarcasm on real instance memories" {
    if (!native.supported) return error.SkipZigTest;
    const Case = struct { ty: wasm.ValType, load: u8, store: u8 };
    const cases = [_]Case{
        .{ .ty = .i32, .load = 0x28, .store = 0x36 }, .{ .ty = .i64, .load = 0x29, .store = 0x37 },
        .{ .ty = .f32, .load = 0x2a, .store = 0x38 }, .{ .ty = .f64, .load = 0x2b, .store = 0x39 },
        .{ .ty = .i32, .load = 0x2c, .store = 0x3a }, .{ .ty = .i32, .load = 0x2d, .store = 0x3a },
        .{ .ty = .i32, .load = 0x2e, .store = 0x3b }, .{ .ty = .i32, .load = 0x2f, .store = 0x3b },
        .{ .ty = .i64, .load = 0x30, .store = 0x3c }, .{ .ty = .i64, .load = 0x31, .store = 0x3c },
        .{ .ty = .i64, .load = 0x32, .store = 0x3d }, .{ .ty = .i64, .load = 0x33, .store = 0x3d },
        .{ .ty = .i64, .load = 0x34, .store = 0x3e }, .{ .ty = .i64, .load = 0x35, .store = 0x3e },
    };
    var owner = try prototype.CodeAllocator.init(a, 1024 * 1024);
    defer owner.deinit();
    for (cases) |case| for ([_]bool{ false, true }) |memory64| {
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        const addr_type: wasm.ValType = if (memory64) .i64 else .i32;
        // Explicit memory index 1; both accesses are deliberately unaligned.
        const body = [_]u8{ 0, 0x20, 0, 0x20, 1, case.store, 0x40, 1, 1, 0x20, 0, case.load, 0x40, 1, 1, 0x0b };
        const module: wasm.Module = .{
            .types = &.{.{ .params = &.{ addr_type, case.ty }, .results = &.{case.ty} }},
            .funcs = &.{0},
            .code = &.{.{ .bytes = &body }},
            .mems = &.{ .{ .limits = .{ .min = 1 } }, .{ .limits = .{ .min = 1, .is_64 = memory64 } } },
        };
        var instance: wasm.Instance = undefined;
        try wasm.instantiate(&instance, arena.allocator(), a, &module, .{});
        defer instance.deinit();
        instance.spasm_enabled = false;
        instance.spasm_diagnostics = true;
        var graph = try prototype.lowerInstance(a, &instance, 0);
        defer graph.deinit();
        var code = try native.compile(a, &owner, graph.graph);
        defer code.deinit();
        for ([_]u64{ 0, 0xffff_ffff_ffff_ffff, 0x7ff0_0000_8000_0001 }) |raw| {
            const bits = if (case.ty == .i32 or case.ty == .f32) raw & 0xffff_ffff else raw;
            @memset(instance.memories[1].data, 0);
            const expected = try wasm.invoke(&instance, a, 0, &.{ 2, bits });
            defer a.free(expected);
            const expected_bytes = instance.memories[1].data[0..16].*;
            @memset(instance.memories[1].data, 0);
            var actual = try prototype.runInInstance(&code, &instance, &.{ 2, bits }, 1);
            defer actual.deinit();
            try std.testing.expectEqual(@as(u64, @truncate(expected[0])), actual.returned);
            try std.testing.expectEqualSlices(u8, &expected_bytes, instance.memories[1].data[0..16]);
            try std.testing.expectEqual(@as(u8, 0), instance.memories[0].data[3]);
            @memset(instance.memories[1].data, 0);
            instance.spasm_enabled = true;
            const baseline = try wasm.invoke(&instance, a, 0, &.{ 2, bits });
            defer a.free(baseline);
            instance.spasm_enabled = false;
            try std.testing.expectEqual(expected[0], baseline[0]);
            try std.testing.expectEqualSlices(u8, &expected_bytes, instance.memories[1].data[0..16]);
        }
        try std.testing.expectEqual(@as(u32, 3), instance.spasm_runs);
        var oob = try prototype.runInInstance(&code, &instance, &.{ if (memory64) 0xffff_ffff_ffff_ffff else 0xffff_ffff, 1 }, 1);
        defer oob.deinit();
        try std.testing.expectEqual(prototype.ir.Trap{ .reason = .memory_out_of_bounds, .site = 4 }, oob.trapped);
    };
}

test "backend memory: imported views may alias and shared memories refuse explicitly" {
    if (!native.supported) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const mem_type: wasm.types.MemType = .{ .limits = .{ .min = 1 } };
    const module: wasm.Module = .{
        .types = &.{.{ .params = &.{ .i32, .i32 }, .results = &.{.i32} }},
        .funcs = &.{0},
        .code = &.{.{ .bytes = &.{ 0, 0x20, 0, 0x20, 1, 0x36, 0x40, 1, 0, 0x20, 0, 0x28, 0, 0, 0x0b } }},
        .imports = &.{ .{ .module = "host", .name = "a", .desc = .{ .mem = mem_type } }, .{ .module = "host", .name = "b", .desc = .{ .mem = mem_type } } },
    };
    const bytes = try a.alloc(u8, wasm.PAGE_SIZE);
    defer a.free(bytes);
    @memset(bytes, 0);
    var memory: wasm.Memory = .{ .data = bytes, .max_pages = null };
    var instance: wasm.Instance = undefined;
    try wasm.instantiate(&instance, arena.allocator(), a, &module, .{ .memories = &.{ &memory, &memory }, .share_memory = true });
    defer instance.deinit();
    try std.testing.expect(instance.memories[0] == &memory and instance.memories[1] == &memory);
    var graph = try prototype.lowerInstance(a, &instance, 0);
    defer graph.deinit();
    var owner = try prototype.CodeAllocator.init(a, 256 * 1024);
    defer owner.deinit();
    var code = try native.compile(a, &owner, graph.graph);
    defer code.deinit();
    var result = try prototype.runInInstance(&code, &instance, &.{ 3, 0xaabb_ccdd }, 1);
    defer result.deinit();
    try std.testing.expectEqual(@as(u64, 0xaabb_ccdd), result.returned);
    try std.testing.expectEqual(@as(u32, 0xaabb_ccdd), std.mem.readInt(u32, bytes[3..7], .little));
    for ([_]bool{ false, true }) |spasm| {
        @memset(bytes, 0);
        instance.spasm_enabled = spasm;
        const expected = try wasm.invoke(&instance, a, 0, &.{ 3, 0xaabb_ccdd });
        defer a.free(expected);
        try std.testing.expectEqual(@as(u128, result.returned), expected[0]);
        try std.testing.expectEqual(@as(u32, 0xaabb_ccdd), std.mem.readInt(u32, bytes[3..7], .little));
    }
    memory.is_shared = true;
    try std.testing.expectError(error.UnsupportedSharedMemory, prototype.runInInstance(&code, &instance, &.{ 3, 1 }, 1));
}

test "backend memory: compiled instance calls observe replacement backing stores" {
    if (!native.supported) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const module: wasm.Module = .{
        .types = &.{.{ .params = &.{.i32}, .results = &.{.i32} }},
        .funcs = &.{0},
        .code = &.{.{ .bytes = &.{ 0, 0x20, 0, 0x28, 0, 0, 0x0b } }},
        .imports = &.{.{ .module = "host", .name = "memory", .desc = .{ .mem = .{ .limits = .{ .min = 0 } } } }},
    };
    const first = try a.alloc(u8, wasm.PAGE_SIZE);
    defer a.free(first);
    const second = try a.alloc(u8, wasm.PAGE_SIZE);
    defer a.free(second);
    @memset(first, 0);
    @memset(second, 0);
    @memcpy(first[0..4], &[_]u8{ 1, 2, 3, 4 });
    @memcpy(second[0..4], &[_]u8{ 5, 6, 7, 8 });
    var memory: wasm.Memory = .{ .data = first, .max_pages = null };
    var instance: wasm.Instance = undefined;
    try wasm.instantiate(&instance, arena.allocator(), a, &module, .{ .memories = &.{&memory}, .share_memory = true });
    defer instance.deinit();
    var graph = try prototype.lowerInstance(a, &instance, 0);
    defer graph.deinit();
    var owner = try prototype.CodeAllocator.init(a, 256 * 1024);
    defer owner.deinit();
    var code = try native.compile(a, &owner, graph.graph);
    defer code.deinit();
    var before = try prototype.runInInstance(&code, &instance, &.{0}, 1);
    defer before.deinit();
    try std.testing.expectEqual(@as(u64, 0x0403_0201), before.returned);
    memory.data = second;
    var after = try prototype.runInInstance(&code, &instance, &.{0}, 1);
    defer after.deinit();
    try std.testing.expectEqual(@as(u64, 0x0807_0605), after.returned);
    memory.data = second[0..0];
    var empty = try prototype.runInInstance(&code, &instance, &.{0}, 1);
    defer empty.deinit();
    try std.testing.expectEqual(prototype.ir.Trap{ .reason = .memory_out_of_bounds, .site = 2 }, empty.trapped);
}

test "backend memory: loop stores and partial progress match both Wasm engines" {
    if (!native.supported) return error.SkipZigTest;
    var owner = try prototype.CodeAllocator.init(a, 256 * 1024);
    defer owner.deinit();
    for ([_]bool{ false, true }) |memory64| {
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        const addr_type: wasm.ValType = if (memory64) .i64 else .i32;
        // Increment count unaligned i32 elements, accumulating their new values.
        const body = [_]u8{
            1,                            1,                            0x7f, // One i32 sum local, after the base/count parameters.
            0x02,                         0x40,                         0x03,
            0x40,                         0x20,                         1,
            0x45,                         0x0d,                         1,
            0x20,                         0,                            0x20,
            0,                            0x28,                         2,
            0,                            0x41,                         1,
            0x6a,                         0x36,                         2,
            0,                            0x20,                         2,
            0x20,                         0,                            0x28,
            2,                            0,                            0x6a,
            0x21,                         2,                            0x20,
            0,                            if (memory64) 0x42 else 0x41, 4,
            if (memory64) 0x7c else 0x6a, 0x21,                         0,
            0x20,                         1,                            0x41,
            1,                            0x6b,                         0x21,
            1,                            0x0c,                         0,
            0x0b,                         0x0b,                         0x20,
            2,                            0x0b,
        };
        const module: wasm.Module = .{
            .types = &.{.{ .params = &.{ addr_type, .i32 }, .results = &.{.i32} }},
            .funcs = &.{0},
            .code = &.{.{ .bytes = &body }},
            .mems = &.{.{ .limits = .{ .min = 1, .is_64 = memory64 } }},
        };
        var instance: wasm.Instance = undefined;
        try wasm.instantiate(&instance, arena.allocator(), a, &module, .{});
        defer instance.deinit();
        instance.spasm_enabled = false;
        instance.spasm_diagnostics = true;
        var graph = try prototype.lowerInstance(a, &instance, 0);
        defer graph.deinit();
        var code = try native.compile(a, &owner, graph.graph);
        defer code.deinit();
        const bytes = instance.memories[0].data;
        @memset(bytes, 0);
        for (0..5) |i| std.mem.writeInt(u32, bytes[1 + i * 4 ..][0..4], @intCast(10 * (i + 1)), .little);
        const initial = bytes[0..32].*;
        for ([_]u64{ 0, 1, 5 }) |count| {
            @memcpy(bytes[0..32], &initial);
            const expected = try wasm.invoke(&instance, a, 0, &.{ 1, count });
            defer a.free(expected);
            try std.testing.expectEqual(@as(u128, 5 * count * (count + 1) + count), expected[0]);
            const expected_bytes = bytes[0..32].*;
            @memcpy(bytes[0..32], &initial);
            var actual = try prototype.runInInstance(&code, &instance, &.{ 1, count }, 64);
            defer actual.deinit();
            try std.testing.expectEqual(@as(u64, @truncate(expected[0])), actual.returned);
            try std.testing.expectEqualSlices(u8, &expected_bytes, bytes[0..32]);
            @memcpy(bytes[0..32], &initial);
            instance.spasm_enabled = true;
            const baseline = try wasm.invoke(&instance, a, 0, &.{ 1, count });
            defer a.free(baseline);
            instance.spasm_enabled = false;
            try std.testing.expectEqual(expected[0], baseline[0]);
            try std.testing.expectEqualSlices(u8, &expected_bytes, bytes[0..32]);
        }
        try std.testing.expectEqual(@as(u32, 3), instance.spasm_runs);
        std.mem.writeInt(u32, bytes[wasm.PAGE_SIZE - 4 ..][0..4], 7, .little);
        try std.testing.expectError(error.OutOfBoundsMemoryAccess, wasm.invoke(&instance, a, 0, &.{ wasm.PAGE_SIZE - 4, 2 }));
        try std.testing.expectEqual(@as(u32, 8), std.mem.readInt(u32, bytes[wasm.PAGE_SIZE - 4 ..][0..4], .little));
        std.mem.writeInt(u32, bytes[wasm.PAGE_SIZE - 4 ..][0..4], 7, .little);
        var trapped = try prototype.runInInstance(&code, &instance, &.{ wasm.PAGE_SIZE - 4, 2 }, 64);
        defer trapped.deinit();
        try std.testing.expectEqual(prototype.ir.Trap{ .reason = .memory_out_of_bounds, .site = 13 }, trapped.trapped);
        try std.testing.expectEqual(@as(u32, 8), std.mem.readInt(u32, bytes[wasm.PAGE_SIZE - 4 ..][0..4], .little));
    }
}

test "backend memory: Wasm memory64 immediate overflow traps at the original instruction" {
    if (!native.supported) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const module: wasm.Module = .{
        .types = &.{.{ .params = &.{.i64}, .results = &.{.i32} }},
        .funcs = &.{0},
        .code = &.{.{ .bytes = &.{ 0, 0x20, 0, 0x28, 0, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0x01, 0x0b } }},
        .mems = &.{.{ .limits = .{ .min = 1, .is_64 = true } }},
    };
    var instance: wasm.Instance = undefined;
    try wasm.instantiate(&instance, arena.allocator(), a, &module, .{});
    defer instance.deinit();
    instance.spasm_enabled = false;
    try std.testing.expectError(error.OutOfBoundsMemoryAccess, wasm.invoke(&instance, a, 0, &.{1}));
    var graph = try prototype.lowerInstance(a, &instance, 0);
    defer graph.deinit();
    var owner = try prototype.CodeAllocator.init(a, 256 * 1024);
    defer owner.deinit();
    var code = try native.compile(a, &owner, graph.graph);
    defer code.deinit();
    var result = try prototype.runInInstance(&code, &instance, &.{1}, 1);
    defer result.deinit();
    try std.testing.expectEqual(prototype.ir.Trap{ .reason = .memory_out_of_bounds, .site = 2 }, result.trapped);
}

test "backend memory: module lowering retains memory metadata and exact float bits" {
    if (!native.supported) return error.SkipZigTest;
    const bytes = [_]u8{
        0,    0x61, 0x73, 0x6d, 1, 0,    0,    0,
        1,    6,    1,    0x60, 1, 0x7f, 1,    0x7c,
        3,    2,    1,    0,    5, 3,    1,    0,
        1,    10,   9,    1,    7, 0,    0x20, 0,
        0x2b, 0,    0,    0x0b,
    };
    var graph = try prototype.lowerModule(a, &bytes, 0);
    defer graph.deinit();
    try std.testing.expectEqual(@as(u32, 1), graph.graph.memory_count);
    var owner = try prototype.CodeAllocator.init(a, 256 * 1024);
    defer owner.deinit();
    var code = try native.compile(a, &owner, graph.graph);
    defer code.deinit();
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const module = try wasm.decode(arena.allocator(), &bytes);
    var instance: wasm.Instance = undefined;
    try wasm.instantiate(&instance, arena.allocator(), a, &module, .{});
    defer instance.deinit();
    std.mem.writeInt(u64, instance.memories[0].data[3..11], 0x7ff0_0000_0000_0001, .little);
    var result = try prototype.runInInstance(&code, &instance, &.{3}, 1);
    defer result.deinit();
    try std.testing.expectEqual(@as(u64, 0x7ff0_0000_0000_0001), result.returned);
}

test "backend memory: instance calls refresh memory views after host growth" {
    if (!native.supported) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const module: wasm.Module = .{
        .types = &.{.{ .params = &.{.i32}, .results = &.{.i32} }},
        .funcs = &.{ 0, 0 },
        .code = &.{ .{ .bytes = &.{ 0, 0x20, 0, 0x28, 0, 0, 0x0b } }, .{ .bytes = &.{ 0, 0x20, 0, 0x40, 0, 0x0b } } },
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
    var before = try prototype.runInInstance(&code, &instance, &.{wasm.PAGE_SIZE}, 1);
    defer before.deinit();
    try std.testing.expectEqual(prototype.ir.TrapReason.memory_out_of_bounds, before.trapped.reason);
    const grown = try wasm.invoke(&instance, a, 1, &.{1});
    defer a.free(grown);
    try std.testing.expectEqual(@as(u128, 1), grown[0]);
    std.mem.writeInt(u32, instance.memories[0].data[wasm.PAGE_SIZE..][0..4], 0xaabb_ccdd, .little);
    var after = try prototype.runInInstance(&code, &instance, &.{wasm.PAGE_SIZE}, 1);
    defer after.deinit();
    try std.testing.expectEqual(@as(u64, 0xaabb_ccdd), after.returned);
}
