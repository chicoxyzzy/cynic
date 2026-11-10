const std = @import("std");
const wasm = @import("wasm.zig");
const prototype = wasm.backend_prototype;
const abi = prototype.abi;
const ir = prototype.ir;
const a = std.testing.allocator;
const first: u128 = 0x0123456789abcdef_fedcba9876543210;
const second: u128 = 0xfedcba9876543210_0123456789abcdef;

fn expectNative(instance: *wasm.Instance, index: u32, args: []const u128, expected: []const u128) !void {
    const before = instance.shared_backend_stats.entries;
    const result = try wasm.invoke(instance, a, index, args);
    defer a.free(result);
    try std.testing.expectEqualSlices(u128, expected, result);
    try std.testing.expectEqual(before + 1, instance.shared_backend_stats.entries);
    try std.testing.expectEqual(@as(u64, 0), instance.shared_backend_stats.refusals);
}

test "backend Wasm vectors: ABI distinguishes SSA types from physical words" {
    const types: []const wasm.ValType = &.{ .v128, .i32, .externref, .f32, .v128 };
    const expected_types: []const ir.Type = &.{ .v128, .i32, .i64, .i64, .f32, .v128 };
    var storage: [6]ir.Type = undefined;
    try std.testing.expectEqual(@as(usize, 8), try abi.wordCount(types));
    try std.testing.expectEqualSlices(ir.Type, expected_types, try abi.writeTypes(types, &storage));
    const owned = try abi.loweredTypes(a, types);
    defer a.free(owned);
    try std.testing.expectEqualSlices(ir.Type, expected_types, owned);
    var words: [8]u64 = undefined;
    const payload = try abi.pack(types, &.{ first, 0xffff_ffff_8000_0001, wasm.REF_NULL, 0xffff_ffff_ffc0_0042, second }, &words);
    try std.testing.expectEqualSlices(u64, &.{ @truncate(first), @truncate(first >> 64), 0x8000_0001, 0xffff_ffff_ffff_ffff, 0xffff_ffff_ffff_ffff, 0xffc0_0042, @truncate(second), @truncate(second >> 64) }, payload);
    var cells: [5]u128 = undefined;
    try abi.unpack(types, payload, &cells);
    try std.testing.expectEqualSlices(u128, &.{ first, 0x8000_0001, wasm.REF_NULL, 0xffc0_0042, second }, &cells);
    const too_many: [33]wasm.ValType = @splat(.v128);
    try std.testing.expectEqual(@as(usize, 64), try abi.wordCount(too_many[0..32]));
    try std.testing.expectError(error.UnsupportedSignature, abi.wordCount(&too_many));
    try std.testing.expectError(error.CallSignatureMismatch, abi.pack(types, &cells, words[0..7]));
    try std.testing.expectError(error.CallSignatureMismatch, abi.unpack(types, words[0..7], &cells));
    try std.testing.expectError(error.CallSignatureMismatch, abi.writeTypes(types, storage[0..5]));
}

test "backend Wasm vectors: mixed results preserve bits in every allocation and optimization mode" {
    if (!prototype.native.supported) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const module: wasm.Module = .{
        .types = &.{.{ .params = &.{ .v128, .i32, .externref, .f64 }, .results = &.{ .externref, .v128, .f64, .i32, .v128 } }},
        .funcs = &.{0},
        .code = &.{.{ .bytes = &.{ 0, 0x20, 2, 0x20, 0, 0x20, 3, 0x20, 1, 0x20, 0, 0x0b } }},
    };
    var instance: wasm.Instance = undefined;
    try wasm.instantiate(&instance, arena.allocator(), a, &module, .{});
    defer instance.deinit();
    instance.shared_backend_enabled = true;
    const args = [_]u128{ first, 0x8000_0001, wasm.REF_NULL, 0xfff8_0000_0000_0042 };
    const expected = [_]u128{ wasm.REF_NULL, first, 0xfff8_0000_0000_0042, 0x8000_0001, first };
    try expectNative(&instance, 0, &args, &expected);
    var graph = try prototype.lowerInstance(a, &instance, 0);
    defer graph.deinit();
    var owner = try prototype.CodeAllocator.init(a, 256 * 1024);
    defer owner.deinit();
    var words: [64]u64 = undefined;
    const payload = try abi.pack(module.types[0].params, &args, &words);
    for ([_]@import("../jit/backend/allocation.zig").Mode{ .scratch, .linear_scan }) |mode| for ([_]u8{ 0, 1, 4 }) |registers| for (0..16) |switches| {
        var code = try prototype.compile(a, &owner, &graph, .{
            .allocation = mode,
            .register_count = registers,
            .rematerialize_constants = switches & 1 != 0,
            .optimization = .{ .constant_folding = switches & 2 != 0, .common_subexpression_elimination = switches & 4 != 0, .dead_code_elimination = switches & 8 != 0 },
        });
        defer code.deinit();
        var results: [8]u64 = undefined;
        var completion = try prototype.runResultsInInstance(&code, &instance, payload, 100, &results);
        defer completion.deinit();
        try std.testing.expect(completion == .returned);
        var cells: [5]u128 = undefined;
        try abi.unpack(module.types[0].results, &results, &cells);
        try std.testing.expectEqualSlices(u128, &expected, &cells);
    };
}

test "backend Wasm vectors: zero locals selection and cyclic branches retain full vectors" {
    if (!prototype.native.supported) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const module: wasm.Module = .{
        .types = &.{.{ .params = &.{ .v128, .v128, .i32 }, .results = &.{ .v128, .v128, .v128 } }},
        .funcs = &.{0},
        // Preserve a zero local, swap two vector locals each loop, then select.
        .code = &.{.{ .bytes = &.{
            1,    1,    0x7b, 0x20, 3,    0x02, 0x40, 0x03, 0x40,
            0x20, 2,    0x45, 0x0d, 1,    0x20, 0,    0x20, 1,
            0x21, 0,    0x21, 1,    0x20, 2,    0x41, 1,    0x6b,
            0x21, 2,    0x0c, 0,    0x0b, 0x0b, 0x20, 0,    0x20,
            1,    0x20, 2,    0x1c, 1,    0x7b, 0x20, 0,    0x0b,
        } }},
    };
    var instance: wasm.Instance = undefined;
    try wasm.instantiate(&instance, arena.allocator(), a, &module, .{});
    defer instance.deinit();
    instance.shared_backend_enabled = true;
    for ([_]u128{ 0, 1, 2, 101 }) |count|
        try expectNative(&instance, 0, &.{ first, second, count }, &.{ 0, if (count % 2 == 0) second else first, if (count % 2 == 0) first else second });
}

test "backend Wasm vectors: direct indirect typed and tail host calls marshal mixed cells" {
    if (!prototype.native.supported) return error.SkipZigTest;
    const Host = struct {
        calls: usize = 0,
        fail: bool = false,
        fn invoke(raw: ?*anyopaque, args: []const u128, results: []u128) wasm.TrapError!void {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            self.calls += 1;
            results[0] = args[1];
            results[1] = args[0];
            results[2] = args[2];
            if (self.fail) return error.HostThrew;
        }
    };
    for ([_][]const u8{ &.{ 0x10, 0 }, &.{ 0x41, 0, 0x11, 0, 0 }, &.{ 0xd2, 0, 0x14, 0 }, &.{ 0x12, 0 }, &.{ 0x41, 0, 0x13, 0, 0 }, &.{ 0xd2, 0, 0x15, 0 } }) |call| {
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        var body: std.ArrayList(u8) = .empty;
        defer body.deinit(a);
        try body.appendSlice(a, &.{ 0, 0x20, 0, 0x20, 1, 0x20, 2 });
        try body.appendSlice(a, call);
        try body.append(a, 0x0b);
        const module: wasm.Module = .{
            .types = &.{.{ .params = &.{ .v128, .externref, .f32 }, .results = &.{ .externref, .v128, .f32 } }},
            .imports = &.{.{ .module = "h", .name = "f", .desc = .{ .func = 0 } }},
            .tables = &.{.{ .elem = .funcref, .limits = .{ .min = 1 } }},
            .elements_count = 1,
            .elements_raw = &.{ 3, 0, 1, 0 },
            .funcs = &.{0},
            .code = &.{.{ .bytes = body.items }},
        };
        var host: Host = .{};
        var instance: wasm.Instance = undefined;
        try wasm.instantiate(&instance, arena.allocator(), a, &module, .{ .funcs = &.{.{ .host = .{ .fn_ptr = Host.invoke, .ctx = &host, .params = 3, .results = 3 } }} });
        defer instance.deinit();
        instance.shared_backend_enabled = true;
        instance.tables[0].elems[0] = wasm.makeFuncRef(&instance, 0);
        try expectNative(&instance, 1, &.{ first, wasm.REF_NULL, 0xffc0_0042 }, &.{ wasm.REF_NULL, first, 0xffc0_0042 });
        host.fail = true;
        try std.testing.expectError(error.HostThrew, wasm.invoke(&instance, a, 1, &.{ second, 17, 0x8000_0000 }));
        try std.testing.expectEqual(@as(usize, 2), host.calls);
        try std.testing.expectEqual(@as(u64, 2), instance.shared_backend_stats.entries);
        try std.testing.expect(instance.native_tail_call == null);
    }
}

test "backend Wasm vectors: aliased globals load and store all sixteen bytes" {
    if (!prototype.native.supported) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const module: wasm.Module = .{
        .types = &.{.{ .params = &.{.v128}, .results = &.{ .v128, .v128 } }},
        .imports = &.{
            .{ .module = "h", .name = "a", .desc = .{ .global = .{ .val = .v128, .mut = .mutable } } },
            .{ .module = "h", .name = "b", .desc = .{ .global = .{ .val = .v128, .mut = .mutable } } },
        },
        .funcs = &.{0},
        .code = &.{.{ .bytes = &.{ 0, 0x23, 0, 0x20, 0, 0x24, 1, 0x23, 0, 0x0b } }},
    };
    var global: wasm.Global = .{ .value = first, .mutable = true };
    var instance: wasm.Instance = undefined;
    try wasm.instantiate(&instance, arena.allocator(), a, &module, .{ .globals = &.{ &global, &global } });
    defer instance.deinit();
    instance.shared_backend_enabled = true;
    try expectNative(&instance, 0, &.{second}, &.{ first, second });
    try std.testing.expectEqual(second, global.value);
}

test "backend Wasm vectors: full width signatures are bounded by words" {
    if (!prototype.native.supported) return error.SkipZigTest;
    for ([_]usize{ 32, 33 }) |count| {
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        const types: [33]wasm.ValType = @splat(.v128);
        var body: std.ArrayList(u8) = .empty;
        defer body.deinit(a);
        try body.append(a, 0);
        for (0..count) |i| try body.appendSlice(a, &.{ 0x20, @intCast(i) });
        try body.append(a, 0x0b);
        const callee = try arena.allocator().dupe(u8, body.items);
        const signature: wasm.FuncType = .{ .params = types[0..count], .results = types[0..count] };
        const provider_module: wasm.Module = .{ .types = &.{signature}, .funcs = &.{0}, .code = &.{.{ .bytes = callee }} };
        var provider: wasm.Instance = undefined;
        try wasm.instantiate(&provider, arena.allocator(), a, &provider_module, .{});
        defer provider.deinit();
        _ = body.pop();
        try body.appendSlice(a, &.{ 0x10, 0, 0x0b });
        const module: wasm.Module = .{
            .types = &.{signature},
            .imports = &.{.{ .module = "h", .name = "f", .desc = .{ .func = 0 } }},
            .funcs = &.{0},
            .code = &.{.{ .bytes = body.items }},
        };
        var instance: wasm.Instance = undefined;
        try wasm.instantiate(&instance, arena.allocator(), a, &module, .{ .funcs = &.{provider.funcRefAt(0).?} });
        defer instance.deinit();
        if (count == 33) {
            try std.testing.expectError(error.UnsupportedSignature, prototype.lowerInstance(a, &instance, 1));
        } else {
            instance.shared_backend_enabled = true;
            var args: [32]u128 = undefined;
            for (&args, 0..) |*arg, i| arg.* = first + i;
            try expectNative(&instance, 1, &args, &args);
        }
    }
}

test "backend Wasm vectors: indirect selectors count against the physical call limit" {
    if (!prototype.native.supported) return error.SkipZigTest;
    for ([_]usize{ 31, 32 }) |count| {
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        const types: [32]wasm.ValType = @splat(.v128);
        var body: std.ArrayList(u8) = .empty;
        defer body.deinit(a);
        try body.append(a, 0);
        for (0..count) |i| try body.appendSlice(a, &.{ 0x20, @intCast(i) });
        try body.appendSlice(a, &.{ 0x41, 0, 0x11, 0, 0, 0x0b });
        const signature: wasm.FuncType = .{ .params = types[0..count], .results = &.{} };
        const provider_module: wasm.Module = .{ .types = &.{signature}, .funcs = &.{0}, .code = &.{.{ .bytes = &.{ 0, 0x0b } }} };
        var provider: wasm.Instance = undefined;
        try wasm.instantiate(&provider, arena.allocator(), a, &provider_module, .{});
        defer provider.deinit();
        const module: wasm.Module = .{
            .types = &.{signature},
            .imports = &.{.{ .module = "h", .name = "f", .desc = .{ .func = 0 } }},
            .tables = &.{.{ .elem = .funcref, .limits = .{ .min = 1 } }},
            .funcs = &.{0},
            .code = &.{.{ .bytes = body.items }},
        };
        var instance: wasm.Instance = undefined;
        try wasm.instantiate(&instance, arena.allocator(), a, &module, .{ .funcs = &.{provider.funcRefAt(0).?} });
        defer instance.deinit();
        if (count == 32) {
            try std.testing.expectError(error.PrototypeLimit, prototype.lowerInstance(a, &instance, 1));
        } else {
            instance.shared_backend_enabled = true;
            instance.tables[0].elems[0] = wasm.makeFuncRef(&instance, 0);
            const args: [31]u128 = @splat(first);
            try expectNative(&instance, 1, &args, &.{});
        }
    }
}

test "backend Wasm vectors: constants retain high words and scalar entry refuses truncation" {
    if (!prototype.native.supported) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    var literal: [16]u8 = undefined;
    std.mem.writeInt(u128, &literal, first, .little);
    const bytes = try @import("backend_prototype_test.zig").moduleBytes(arena.allocator(), &.{}, 0x7b, &.{}, &(@as([2]u8, .{ 0xfd, 12 }) ++ literal ++ .{0x0b}));
    var graph = try prototype.lowerModule(a, bytes, 0);
    defer graph.deinit();
    try std.testing.expectEqualSlices(ir.Type, &.{.v128}, graph.graph.result_types);
    var owner = try prototype.CodeAllocator.init(a, 64 * 1024);
    defer owner.deinit();
    var code = try prototype.native.compile(a, &owner, graph.graph);
    defer code.deinit();
    var result: [2]u64 = undefined;
    var completion = try code.runInto(&.{}, &.{}, 10, null, &result);
    defer completion.deinit();
    try std.testing.expect(completion == .returned);
    try std.testing.expectEqualSlices(u64, &.{ @truncate(first), @truncate(first >> 64) }, &result);
    try std.testing.expectError(error.ResultCount, prototype.evaluate(a, bytes, 0, &.{}, 10));
}

test "backend Wasm vectors: lane additions and bitwise operations agree with Sarcasm" {
    if (!prototype.native.supported) return error.SkipZigTest;
    for ([_]u32{ 78, 80, 81, 110, 142, 174, 206, 228, 240 }) |sub| {
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        var body: std.ArrayList(u8) = .empty;
        defer body.deinit(a);
        try body.appendSlice(a, &.{ 0, 0x20, 0, 0x20, 1, 0xfd });
        if (sub < 128) try body.append(a, @intCast(sub)) else try body.appendSlice(a, &.{ @as(u8, @intCast(sub & 0x7f)) | 0x80, @intCast(sub >> 7) });
        try body.append(a, 0x0b);
        const module: wasm.Module = .{ .types = &.{.{ .params = &.{ .v128, .v128 }, .results = &.{.v128} }}, .funcs = &.{0}, .code = &.{.{ .bytes = body.items }} };
        var instance: wasm.Instance = undefined;
        try wasm.instantiate(&instance, arena.allocator(), a, &module, .{});
        defer instance.deinit();
        // Finite FP lanes, subnormals, signed zero, and wrapping integer lanes.
        for ([_][2]u128{
            .{ first, second },
            .{ 0xffffffffffffffff_ffffffffffffffff, 1 },
            .{ 0x3f80000040000000_8000000000000001, 0x408000003f000000_0000000000000001 },
            .{ 0x3ff0000000000000_0000000000000001, 0x4000000000000000_8000000000000000 },
        }) |args| {
            instance.shared_backend_enabled = false;
            const expected = try wasm.invoke(&instance, a, 0, &args);
            defer a.free(expected);
            // NaN payload selection is target-defined; literal identity is
            // tested separately, and arithmetic compares NaN lanes by class.
            instance.shared_backend_enabled = true;
            const before = instance.shared_backend_stats.entries;
            const result = try wasm.invoke(&instance, a, 0, &args);
            defer a.free(result);
            if (sub == 228 or sub == 240) {
                const width: u8 = if (sub == 228) 32 else 64;
                var shift: u8 = 0;
                while (shift < 128) : (shift += width) {
                    if (sub == 228) {
                        const actual: f32 = @bitCast(@as(u32, @truncate(result[0] >> @as(u7, @intCast(shift)))));
                        const want: f32 = @bitCast(@as(u32, @truncate(expected[0] >> @as(u7, @intCast(shift)))));
                        if (std.math.isNan(want)) try std.testing.expect(std.math.isNan(actual)) else try std.testing.expectEqual(@as(u32, @bitCast(want)), @as(u32, @bitCast(actual)));
                    } else {
                        const actual: f64 = @bitCast(@as(u64, @truncate(result[0] >> @as(u7, @intCast(shift)))));
                        const want: f64 = @bitCast(@as(u64, @truncate(expected[0] >> @as(u7, @intCast(shift)))));
                        if (std.math.isNan(want)) try std.testing.expect(std.math.isNan(actual)) else try std.testing.expectEqual(@as(u64, @bitCast(want)), @as(u64, @bitCast(actual)));
                    }
                }
            } else try std.testing.expectEqualSlices(u128, expected, result);
            try std.testing.expectEqual(before + 1, instance.shared_backend_stats.entries);
            try std.testing.expectEqual(@as(u64, 0), instance.shared_backend_stats.refusals);
        }
    }
}

test "backend Wasm vectors: unaligned multi-memory accesses preserve bounds and trap order" {
    if (!prototype.native.supported) return error.SkipZigTest;
    for ([_]bool{ false, true }) |memory64| {
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        const module: wasm.Module = .{
            .types = &.{ .{ .params = &.{ if (memory64) .i64 else .i32, .v128 }, .results = &.{.v128} }, .{ .params = &.{if (memory64) .i64 else .i32}, .results = &.{.v128} } },
            .mems = &.{ .{ .limits = .{ .min = 0 } }, .{ .limits = .{ .min = 1, .is_64 = memory64 } } },
            .funcs = &.{ 0, 1 },
            .code = &.{
                .{ .bytes = &.{ 0, 0x20, 0, 0x20, 1, 0xfd, 11, 0x40, 1, 3, 0x20, 0, 0xfd, 0, 0x40, 1, 3, 0x0b } },
                .{ .bytes = &.{ 0, 0x20, 0, 0xfd, 0, 0x40, 1, 3, 0x0b } },
            },
        };
        var instance: wasm.Instance = undefined;
        try wasm.instantiate(&instance, arena.allocator(), a, &module, .{});
        defer instance.deinit();
        instance.shared_backend_enabled = true;
        for ([_]u128{ 0, 2, wasm.PAGE_SIZE - 19 }) |address| {
            try expectNative(&instance, 0, &.{ address, first }, &.{first});
            try expectNative(&instance, 1, &.{address}, &.{first});
            try std.testing.expectEqual(first, std.mem.readInt(u128, instance.memories[1].data[@as(usize, @intCast(address)) + 3 ..][0..16], .little));
        }
        for ([_]u128{ wasm.PAGE_SIZE - 18, 0xffff_ffff, 0xffff_ffff_ffff_ffff }) |address| {
            @memset(instance.memories[1].data, 0x5a);
            const before = instance.shared_backend_stats.entries;
            try std.testing.expectError(error.OutOfBoundsMemoryAccess, wasm.invoke(&instance, a, 0, &.{ address, second }));
            try std.testing.expectError(error.OutOfBoundsMemoryAccess, wasm.invoke(&instance, a, 1, &.{address}));
            try std.testing.expectEqual(before + 2, instance.shared_backend_stats.entries);
            try std.testing.expect(std.mem.allEqual(u8, instance.memories[1].data, 0x5a));
        }
    }
}

test "backend Wasm vectors: foreign direct indirect typed and tail calls cross all tiers" {
    if (!prototype.native.supported) return error.SkipZigTest;
    for (0..3) |tier| for ([_][]const u8{ &.{ 0x10, 0 }, &.{ 0x41, 0, 0x11, 0, 0 }, &.{ 0xd2, 0, 0x14, 0 }, &.{ 0x12, 0 }, &.{ 0x41, 0, 0x13, 0, 0 }, &.{ 0xd2, 0, 0x15, 0 } }) |call| {
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        const signature: wasm.FuncType = .{ .params = &.{ .v128, .externref }, .results = &.{ .v128, .externref, .v128 } };
        var global: wasm.Global = .{ .value = second, .mutable = false };
        const provider_module: wasm.Module = .{
            .types = &.{signature},
            .imports = &.{.{ .module = "h", .name = "g", .desc = .{ .global = .{ .val = .v128, .mut = .immutable } } }},
            .funcs = &.{0},
            .code = &.{.{ .bytes = &.{ 0, 0x20, 0, 0x20, 1, 0x23, 0, 0x0b } }},
        };
        var provider: wasm.Instance = undefined;
        try wasm.instantiate(&provider, arena.allocator(), a, &provider_module, .{ .globals = &.{&global} });
        defer provider.deinit();
        provider.spasm_enabled = tier == 1;
        provider.shared_backend_enabled = tier == 2;
        var body: std.ArrayList(u8) = .empty;
        defer body.deinit(a);
        try body.appendSlice(a, &.{ 0, 0x20, 0, 0x20, 1 });
        try body.appendSlice(a, call);
        try body.append(a, 0x0b);
        const module: wasm.Module = .{
            .types = &.{signature},
            .imports = &.{.{ .module = "p", .name = "f", .desc = .{ .func = 0 } }},
            .tables = &.{.{ .elem = .funcref, .limits = .{ .min = 1 } }},
            .elements_count = 1,
            .elements_raw = &.{ 3, 0, 1, 0 },
            .funcs = &.{0},
            .code = &.{.{ .bytes = body.items }},
        };
        var instance: wasm.Instance = undefined;
        try wasm.instantiate(&instance, arena.allocator(), a, &module, .{ .funcs = &.{provider.funcRefAt(0).?} });
        defer instance.deinit();
        instance.shared_backend_enabled = true;
        instance.tables[0].elems[0] = wasm.makeFuncRef(&provider, 0);
        try expectNative(&instance, 1, &.{ first, wasm.REF_NULL }, &.{ first, wasm.REF_NULL, second });
        try std.testing.expectEqual(@as(u32, @intFromBool(tier == 1)), provider.spasm_runs);
        try std.testing.expectEqual(@as(u64, @intFromBool(tier == 2)), provider.shared_backend_stats.entries);
        try std.testing.expectEqual(@as(u64, 0), provider.shared_backend_stats.refusals);
    };
}

test "backend Wasm vectors: snapshots exclude vector bits and root failures never replay effects" {
    if (!prototype.native.supported) return error.SkipZigTest;
    const Host = struct {
        pins: usize = 0,
        calls: usize = 0,
        fail: bool = false,
        fn pin(raw: *anyopaque, reference: u128) error{OutOfMemory}!void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            if (reference != 17 or self.fail) return error.OutOfMemory;
            self.pins += 1;
        }
        fn invoke(raw: ?*anyopaque, _: []const u128, _: []u128) wasm.TrapError!void {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            if (self.pins == 0) return error.HostThrew;
            self.calls += 1;
        }
    };
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const module: wasm.Module = .{
        .types = &.{ .{ .params = &.{}, .results = &.{} }, .{ .params = &.{ .v128, .externref }, .results = &.{ .v128, .externref } } },
        .imports = &.{.{ .module = "h", .name = "f", .desc = .{ .func = 0 } }},
        .globals = &.{.{ .type = .{ .val = .i32, .mut = .mutable }, .init_expr = &.{ 0x41, 0, 0x0b } }},
        .funcs = &.{1},
        .code = &.{.{ .bytes = &.{ 0, 0x23, 0, 0x41, 1, 0x6a, 0x24, 0, 0x20, 0, 0x10, 0, 0x20, 1, 0x0b } }},
    };
    var host: Host = .{};
    var instance: wasm.Instance = undefined;
    try wasm.instantiate(&instance, arena.allocator(), a, &module, .{ .funcs = &.{.{ .host = .{ .fn_ptr = Host.invoke, .ctx = &host, .params = 0, .results = 0 } }} });
    defer instance.deinit();
    instance.externref_rooter = .{ .context = &host, .pin_fn = Host.pin };
    instance.shared_backend_enabled = true;
    instance.spasm_enabled = true;
    try expectNative(&instance, 1, &.{ first, 17 }, &.{ first, 17 });
    host.fail = true;
    try std.testing.expectError(error.OutOfMemory, wasm.invoke(&instance, a, 1, &.{ second, 17 }));
    try std.testing.expectEqual(@as(u128, 2), instance.globals[0].value);
    try std.testing.expectEqual(@as(usize, 1), host.calls);
    try std.testing.expectEqual(@as(u64, 2), instance.shared_backend_stats.entries);
    try std.testing.expectEqual(@as(u32, 0), instance.spasm_runs);
}

fn allocationFailures(allocator: std.mem.Allocator, owner: *prototype.CodeAllocator, instance: *wasm.Instance) !void {
    var graph = try prototype.lowerInstance(allocator, instance, 0);
    defer graph.deinit();
    var code = try prototype.compile(allocator, owner, &graph, .{});
    defer code.deinit();
    var results: [2]u64 = undefined;
    var completion = try prototype.runResultsInInstance(&code, instance, &.{ @truncate(first), @truncate(first >> 64) }, 100, &results);
    defer completion.deinit();
    try std.testing.expect(completion == .returned);
    try std.testing.expectEqualSlices(u64, &.{ @truncate(first), @truncate(first >> 64) }, &results);
}

test "backend Wasm vectors: OOM releases mixed width lowering and code metadata" {
    if (!prototype.native.supported) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const module: wasm.Module = .{
        .types = &.{.{ .params = &.{.v128}, .results = &.{.v128} }},
        .funcs = &.{ 0, 0 },
        .code = &.{ .{ .bytes = &.{ 0, 0x20, 0, 0x10, 1, 0x0b } }, .{ .bytes = &.{ 0, 0x20, 0, 0x0b } } },
    };
    var instance: wasm.Instance = undefined;
    try wasm.instantiate(&instance, arena.allocator(), a, &module, .{});
    defer instance.deinit();
    var owner = try prototype.CodeAllocator.init(a, 256 * 1024);
    defer owner.deinit();
    var no_resize = std.testing.FailingAllocator.init(a, .{ .resize_fail_index = 0 });
    try std.testing.checkAllAllocationFailures(no_resize.allocator(), allocationFailures, .{ &owner, &instance });
}
