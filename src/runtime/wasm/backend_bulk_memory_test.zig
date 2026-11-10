const std = @import("std");
const wasm = @import("wasm.zig");
const a = std.testing.allocator;

fn invoke(instance: *wasm.Instance, tier: usize, index: u32, args: []const u128, failure: ?anyerror) !void {
    const entries = instance.shared_backend_stats.entries;
    const spasm_entries = instance.spasm_runs;
    if (failure) |err| {
        try std.testing.expectError(err, wasm.invoke(instance, a, index, args));
    } else {
        const result = try wasm.invoke(instance, a, index, args);
        defer a.free(result);
        try std.testing.expectEqual(@as(usize, 0), result.len);
    }
    if (tier == 1) try std.testing.expectEqual(spasm_entries + 1, instance.spasm_runs);
    if (tier == 2) try std.testing.expectEqual(entries + 1, instance.shared_backend_stats.entries);
}

test "backend bulk memory: copy preserves mixed widths, aliasing and all-or-nothing bounds" {
    if (!wasm.backend_prototype.native.supported) return error.SkipZigTest;
    for ([_]bool{ false, true }) |dst64| for ([_]bool{ false, true }) |src64| for ([_]bool{ false, true }) |alias| {
        if (alias and dst64 != src64) continue;
        for (0..3) |tier| {
            var arena = std.heap.ArenaAllocator.init(a);
            defer arena.deinit();
            const dst_type: wasm.types.MemType = .{ .limits = .{ .min = 1, .is_64 = dst64 } };
            const src_type: wasm.types.MemType = .{ .limits = .{ .min = 1, .is_64 = src64 } };
            const module: wasm.Module = .{
                .types = &.{.{ .params = &.{ if (dst64) .i64 else .i32, if (src64) .i64 else .i32, if (dst64 and src64) .i64 else .i32 }, .results = &.{} }},
                .funcs = &.{0},
                .imports = &.{ .{ .module = "host", .name = "dst", .desc = .{ .mem = dst_type } }, .{ .module = "host", .name = "src", .desc = .{ .mem = src_type } } },
                .code = &.{.{ .bytes = &.{ 0, 0x20, 0, 0x20, 1, 0x20, 2, 0xfc, 10, 0, 1, 0x0b } }},
            };
            var dst: wasm.Memory = .{ .data = try a.alloc(u8, wasm.PAGE_SIZE), .max_pages = null, .is_64 = dst64 };
            defer a.free(dst.data);
            var src: wasm.Memory = .{ .data = try a.alloc(u8, wasm.PAGE_SIZE), .max_pages = null, .is_64 = src64 };
            defer a.free(src.data);
            var instance: wasm.Instance = undefined;
            try wasm.instantiate(&instance, arena.allocator(), a, &module, .{ .memories = &.{ &dst, if (alias) &dst else &src }, .share_memory = true });
            defer instance.deinit();
            instance.spasm_enabled = tier == 1;
            instance.shared_backend_enabled = tier == 2;
            const Case = struct { dst: u64, src: u64, len: u64, fails: bool = false };
            const cases = [_]Case{
                .{ .dst = 2, .src = 0, .len = 6 },
                .{ .dst = 0, .src = 2, .len = 6 },
                .{ .dst = wasm.PAGE_SIZE, .src = wasm.PAGE_SIZE, .len = 0 },
                .{ .dst = wasm.PAGE_SIZE, .src = 0, .len = 1, .fails = true },
                .{ .dst = 0, .src = wasm.PAGE_SIZE, .len = 1, .fails = true },
                .{ .dst = wasm.PAGE_SIZE + 1, .src = 0, .len = 0, .fails = true },
                .{ .dst = 0, .src = 0, .len = if (dst64 and src64) std.math.maxInt(u64) else std.math.maxInt(u32), .fails = true },
                .{ .dst = if (dst64) std.math.maxInt(u64) else std.math.maxInt(u32), .src = 0, .len = 1, .fails = true },
            };
            for (cases) |case| {
                @memset(dst.data, 0x5a);
                @memset(src.data, 0xa5);
                @memcpy(dst.data[0..8], "abcdefgh");
                @memcpy(src.data[0..8], "01234567");
                const expected = try a.dupe(u8, dst.data);
                defer a.free(expected);
                if (!case.fails) @memcpy(expected[@intCast(case.dst)..][0..@intCast(case.len)], (if (alias) dst.data else src.data)[@intCast(case.src)..][0..@intCast(case.len)]);
                try invoke(&instance, tier, 0, &.{ case.dst, case.src, case.len }, if (case.fails) error.OutOfBoundsMemoryAccess else null);
                try std.testing.expectEqualSlices(u8, expected, dst.data);
            }
        }
    };
}

test "backend bulk memory: fill, init and drop preserve memory64 and passive segment state" {
    if (!wasm.backend_prototype.native.supported) return error.SkipZigTest;
    for ([_]bool{ false, true }) |memory64| for (0..3) |tier| {
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        const addr: wasm.ValType = if (memory64) .i64 else .i32;
        const module: wasm.Module = .{
            .types = &.{ .{ .params = &.{ addr, .i32, addr }, .results = &.{} }, .{ .params = &.{ addr, .i32, .i32 }, .results = &.{} }, .{ .params = &.{}, .results = &.{} } },
            .funcs = &.{ 0, 1, 2 },
            .mems = &.{ .{ .limits = .{ .min = 1 } }, .{ .limits = .{ .min = 1, .is_64 = memory64 } } },
            .code = &.{
                .{ .bytes = &.{ 0, 0x20, 0, 0x20, 1, 0x20, 2, 0xfc, 11, 1, 0x0b } },
                .{ .bytes = &.{ 0, 0x20, 0, 0x20, 1, 0x20, 2, 0xfc, 8, 1, 1, 0x0b } },
                .{ .bytes = &.{ 0, 0xfc, 9, 1, 0x0b } },
            },
            .data_raw = &.{ 1, 6, 'a', 'b', 'c', 'd', 'e', 'f', 1, 6, '0', '1', '2', '3', '4', '5' },
            .data_count_in_section = 2,
            .data_count = 2,
        };
        var instance: wasm.Instance = undefined;
        try wasm.instantiate(&instance, arena.allocator(), a, &module, .{});
        defer instance.deinit();
        instance.spasm_enabled = tier == 1;
        instance.shared_backend_enabled = tier == 2;
        const data = instance.memories[1].data;
        try invoke(&instance, tier, 0, &.{ 0, 0x1234, 4 }, null);
        try std.testing.expectEqualSlices(u8, &.{ 0x34, 0x34, 0x34, 0x34, 0 }, data[0..5]);
        try invoke(&instance, tier, 0, &.{ wasm.PAGE_SIZE, 255, 0 }, null);
        try invoke(&instance, tier, 0, &.{ wasm.PAGE_SIZE - 1, 255, 2 }, error.OutOfBoundsMemoryAccess);
        try std.testing.expectEqual(@as(u8, 0), data[wasm.PAGE_SIZE - 1]);
        try invoke(&instance, tier, 0, &.{ wasm.PAGE_SIZE + 1, 255, 0 }, error.OutOfBoundsMemoryAccess);
        try invoke(&instance, tier, 0, &.{ 0, 255, if (memory64) std.math.maxInt(u64) else std.math.maxInt(u32) }, error.OutOfBoundsMemoryAccess);
        try std.testing.expectEqual(@as(u8, 0x34), data[0]);
        try invoke(&instance, tier, 1, &.{ 8, 1, 4 }, null);
        try std.testing.expectEqualSlices(u8, "1234", data[8..12]);
        try invoke(&instance, tier, 1, &.{ 8, 5, 2 }, error.OutOfBoundsMemoryAccess);
        try std.testing.expectEqualSlices(u8, "1234", data[8..12]);
        try invoke(&instance, tier, 1, &.{ wasm.PAGE_SIZE, 6, 0 }, null);
        try invoke(&instance, tier, 1, &.{ if (memory64) std.math.maxInt(u64) else std.math.maxInt(u32), 0, 1 }, error.OutOfBoundsMemoryAccess);
        try invoke(&instance, tier, 1, &.{ 0, std.math.maxInt(u32), 1 }, error.OutOfBoundsMemoryAccess);
        try invoke(&instance, tier, 2, &.{}, null);
        try invoke(&instance, tier, 2, &.{}, null);
        try std.testing.expect(instance.data_segments[1].dropped);
        try std.testing.expectEqual(@as(usize, 0), instance.data_segments[1].bytes.len);
        try std.testing.expectEqualSlices(u8, "abcdef", instance.data_segments[0].bytes);
        try invoke(&instance, tier, 1, &.{ 0, 0, 0 }, null);
        try invoke(&instance, tier, 1, &.{ 0, 0, 1 }, error.OutOfBoundsMemoryAccess);
        try invoke(&instance, tier, 1, &.{ 0, 1, 0 }, error.OutOfBoundsMemoryAccess);
        try std.testing.expect(std.mem.allEqual(u8, instance.memories[0].data, 0));
    };
}

test "backend bulk memory: void effects survive every optimization and allocation mode" {
    const prototype = wasm.backend_prototype;
    if (!prototype.native.supported) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const module: wasm.Module = .{
        .types = &.{.{ .params = &.{}, .results = &.{} }},
        .funcs = &.{ 0, 0 },
        .mems = &.{.{ .limits = .{ .min = 1 } }},
        .code = &.{
            .{ .bytes = &.{ 0, 0x41, 0, 0x41, 42, 0x41, 1, 0xfc, 11, 0, 0xfc, 9, 0, 0x0b } },
            .{ .bytes = &.{ 0, 0xfc, 9, 0, 0x0b } },
        },
        .data_raw = &.{ 1, 1, 7 },
        .data_count_in_section = 1,
        .data_count = 1,
    };
    var instance: wasm.Instance = undefined;
    try wasm.instantiate(&instance, arena.allocator(), a, &module, .{});
    defer instance.deinit();
    var graph = try prototype.lowerInstance(a, &instance, 0);
    defer graph.deinit();
    var owner = try prototype.CodeAllocator.init(a, 256 * 1024);
    defer owner.deinit();
    const AllocationMode = @import("../jit/backend/allocation.zig").Mode;
    for ([_]AllocationMode{ .scratch, .linear_scan }) |mode| for (0..16) |flags| for ([_]u8{ 0, 1, 4 }) |registers| {
        var code = try prototype.compile(a, &owner, &graph, .{
            .allocation = mode,
            .register_count = registers,
            .rematerialize_constants = flags & 8 != 0,
            .optimization = .{ .constant_folding = flags & 1 != 0, .common_subexpression_elimination = flags & 2 != 0, .dead_code_elimination = flags & 4 != 0 },
        });
        defer code.deinit();
        instance.memories[0].data[0] = 0;
        instance.data_segments[0] = .{ .bytes = &.{7}, .dropped = false };
        var result = try prototype.runResultsInInstance(&code, &instance, &.{}, 1, &.{});
        defer result.deinit();
        try std.testing.expect(result == .returned);
        try std.testing.expectEqual(@as(u8, 42), instance.memories[0].data[0]);
        try std.testing.expect(instance.data_segments[0].dropped);
    };
    var no_memory = module;
    no_memory.mems = &.{};
    no_memory.funcs = &.{0};
    no_memory.code = module.code[1..];
    var data_only: wasm.Instance = undefined;
    try wasm.instantiate(&data_only, arena.allocator(), a, &no_memory, .{});
    defer data_only.deinit();
    data_only.shared_backend_enabled = true;
    try invoke(&data_only, 2, 0, &.{}, null);
    try std.testing.expect(data_only.data_segments[0].dropped);
}

test "backend bulk memory: growth, writes and data drop survive a later trap without replay" {
    if (!wasm.backend_prototype.native.supported) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const module: wasm.Module = .{
        .types = &.{.{ .params = &.{}, .results = &.{} }},
        .funcs = &.{0},
        .mems = &.{.{ .limits = .{ .min = 1, .max = 3 } }},
        .code = &.{.{ .bytes = &.{ 0, 0x41, 1, 0x40, 0, 0x1a, 0x41, 0x80, 0x80, 4, 0x41, 42, 0x41, 1, 0xfc, 11, 0, 0xfc, 9, 0, 0, 0x0b } }},
        .data_raw = &.{ 1, 1, 7 },
        .data_count_in_section = 1,
        .data_count = 1,
    };
    var instance: wasm.Instance = undefined;
    try wasm.instantiate(&instance, arena.allocator(), a, &module, .{});
    defer instance.deinit();
    instance.shared_backend_enabled = true;
    instance.spasm_enabled = true;
    try invoke(&instance, 2, 0, &.{}, error.Unreachable);
    try std.testing.expectEqual(@as(usize, 2 * wasm.PAGE_SIZE), instance.memories[0].data.len);
    try std.testing.expectEqual(@as(u8, 42), instance.memories[0].data[wasm.PAGE_SIZE]);
    try std.testing.expect(instance.data_segments[0].dropped);
    try std.testing.expectEqual(@as(u32, 0), instance.spasm_runs);
}
