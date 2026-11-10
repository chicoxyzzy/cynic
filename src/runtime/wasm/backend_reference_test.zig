const std = @import("std");
const wasm = @import("wasm.zig");
const a = std.testing.allocator;
const prototype = wasm.backend_prototype;

fn expectNative(instance: *wasm.Instance, index: u32, args: []const u128, expected: []const u128) !void {
    const before = instance.shared_backend_stats.entries;
    const result = try wasm.invoke(instance, a, index, args);
    defer a.free(result);
    try std.testing.expectEqualSlices(u128, expected, result);
    try std.testing.expectEqual(before + 1, instance.shared_backend_stats.entries);
}

test "backend references: parameters and multivalue results preserve both words" {
    if (!wasm.backend_prototype.native.supported) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const module: wasm.Module = .{
        .types = &.{.{ .params = &.{ .funcref, .externref, .exnref }, .results = &.{ .exnref, .funcref, .externref } }},
        .funcs = &.{0},
        .code = &.{.{ .bytes = &.{ 0, 0x20, 2, 0x20, 0, 0x20, 1, 0x0b } }},
    };
    var instance: wasm.Instance = undefined;
    try wasm.instantiate(&instance, arena.allocator(), a, &module, .{});
    defer instance.deinit();
    instance.shared_backend_enabled = true;
    const function = wasm.interpreter.makeFuncRef(&instance, 0);
    for ([_]u128{ 0, 0x1234_5678_90ab_cdef, wasm.REF_NULL }) |external|
        try expectNative(&instance, 0, &.{ function, external, wasm.REF_NULL }, &.{ wasm.REF_NULL, function, external });
}

test "backend references: null locals and typed select carry reference pairs across edges" {
    if (!wasm.backend_prototype.native.supported) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const module: wasm.Module = .{
        .types = &.{.{ .params = &.{ .externref, .externref, .i32 }, .results = &.{ .externref, .i32, .i32 } }},
        .funcs = &.{0},
        .code = &.{.{ .bytes = &.{ 1, 1, 0x6f, 0x20, 0, 0x20, 1, 0x20, 2, 0x1c, 1, 0x6f, 0x20, 3, 0xd1, 0xd0, 0x70, 0xd1, 0x0b } }},
    };
    var instance: wasm.Instance = undefined;
    try wasm.instantiate(&instance, arena.allocator(), a, &module, .{});
    defer instance.deinit();
    instance.shared_backend_enabled = true;
    for ([_]u128{ 0, 1 }) |condition|
        try expectNative(&instance, 0, &.{ 17, wasm.REF_NULL, condition }, &.{ if (condition == 0) wasm.REF_NULL else 17, 1, 1 });
}

test "backend references: direct host calls marshal complete reference cells" {
    if (!wasm.backend_prototype.native.supported) return error.SkipZigTest;
    const Host = struct {
        fn call(_: ?*anyopaque, args: []const u128, results: []u128) wasm.TrapError!void {
            results[0] = args[1];
            results[1] = args[0];
        }
    };
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const module: wasm.Module = .{
        .types = &.{.{ .params = &.{ .funcref, .externref }, .results = &.{ .externref, .funcref } }},
        .imports = &.{.{ .module = "h", .name = "f", .desc = .{ .func = 0 } }},
        .funcs = &.{0},
        .code = &.{.{ .bytes = &.{ 0, 0x20, 0, 0x20, 1, 0x10, 0, 0x0b } }},
    };
    var instance: wasm.Instance = undefined;
    try wasm.instantiate(&instance, arena.allocator(), a, &module, .{ .funcs = &.{.{ .host = .{ .fn_ptr = Host.call, .params = 2, .results = 2 } }} });
    defer instance.deinit();
    instance.shared_backend_enabled = true;
    const function = wasm.interpreter.makeFuncRef(&instance, 1);
    try expectNative(&instance, 1, &.{ function, wasm.REF_NULL }, &.{ wasm.REF_NULL, function });
}

test "backend references: imported globals retain reference identity and null high words" {
    if (!wasm.backend_prototype.native.supported) return error.SkipZigTest;
    for ([_]wasm.ValType{ .funcref, .externref, .exnref }) |ty| {
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        const gt: wasm.types.GlobalType = .{ .val = ty, .mut = .mutable };
        const module: wasm.Module = .{
            .types = &.{.{ .params = &.{ty}, .results = &.{ ty, ty } }},
            .imports = &.{ .{ .module = "h", .name = "a", .desc = .{ .global = gt } }, .{ .module = "h", .name = "b", .desc = .{ .global = gt } } },
            .funcs = &.{0},
            .code = &.{.{ .bytes = &.{ 0, 0x23, 0, 0x20, 0, 0x24, 1, 0x23, 0, 0x0b } }},
        };
        var global: wasm.Global = .{ .value = wasm.REF_NULL, .mutable = true };
        var instance: wasm.Instance = undefined;
        try wasm.instantiate(&instance, arena.allocator(), a, &module, .{ .globals = &.{ &global, &global } });
        defer instance.deinit();
        instance.shared_backend_enabled = true;
        const reference: u128 = if (ty == .funcref) wasm.interpreter.makeFuncRef(&instance, 0) else 42;
        try expectNative(&instance, 0, &.{reference}, &.{ wasm.REF_NULL, reference });
        try expectNative(&instance, 0, &.{wasm.REF_NULL}, &.{ reference, wasm.REF_NULL });
        try std.testing.expectEqual(wasm.REF_NULL, global.value);
    }
}

test "backend references: table get set grow size and fill execute natively" {
    if (!wasm.backend_prototype.native.supported) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const module: wasm.Module = .{
        .types = &.{
            .{ .params = &.{ .i32, .externref }, .results = &.{.externref} },
            .{ .params = &.{ .externref, .i32 }, .results = &.{ .i32, .i32 } },
            .{ .params = &.{ .i32, .externref, .i32 }, .results = &.{} },
        },
        .tables = &.{.{ .elem = .externref, .limits = .{ .min = 2, .max = 4 } }},
        .funcs = &.{ 0, 1, 2 },
        .code = &.{
            .{ .bytes = &.{ 0, 0x20, 0, 0x20, 1, 0x26, 0, 0x20, 0, 0x25, 0, 0x0b } },
            .{ .bytes = &.{ 0, 0x20, 0, 0x20, 1, 0xfc, 15, 0, 0xfc, 16, 0, 0x0b } },
            .{ .bytes = &.{ 0, 0x20, 0, 0x20, 1, 0x20, 2, 0xfc, 17, 0, 0x0b } },
        },
    };
    var instance: wasm.Instance = undefined;
    try wasm.instantiate(&instance, arena.allocator(), a, &module, .{});
    defer instance.deinit();
    instance.shared_backend_enabled = true;
    try expectNative(&instance, 0, &.{ 0, 17 }, &.{17});
    try expectNative(&instance, 1, &.{ 42, 2 }, &.{ 2, 4 });
    try std.testing.expectEqualSlices(u128, &.{ 17, wasm.REF_NULL, 42, 42 }, instance.tables[0].elems);
    try expectNative(&instance, 2, &.{ 1, wasm.REF_NULL, 3 }, &.{});
    try expectNative(&instance, 1, &.{ 42, 1 }, &.{ 0xffff_ffff, 4 });
    const before = instance.shared_backend_stats.entries;
    try std.testing.expectError(error.OutOfBoundsTableAccess, wasm.invoke(&instance, a, 2, &.{ 3, 99, 2 }));
    try std.testing.expectEqual(before + 1, instance.shared_backend_stats.entries);
    try std.testing.expectEqualSlices(u128, &.{ 17, wasm.REF_NULL, wasm.REF_NULL, wasm.REF_NULL }, instance.tables[0].elems);
}

test "backend references: ref.func null assertions and nullable branches preserve cells" {
    if (!wasm.backend_prototype.native.supported) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const module: wasm.Module = .{
        .types = &.{
            .{ .params = &.{}, .results = &.{.funcref} },
            .{ .params = &.{.externref}, .results = &.{.externref} },
            .{ .params = &.{.externref}, .results = &.{.i32} },
        },
        .funcs = &.{ 0, 1, 2, 1 },
        .elements_count = 1,
        .elements_raw = &.{ 3, 0, 1, 0 },
        .code = &.{
            .{ .bytes = &.{ 0, 0xd2, 0, 0x0b } },
            .{ .bytes = &.{ 0, 0x20, 0, 0xd4, 0x0b } },
            .{ .bytes = &.{ 0, 0x02, 0x40, 0x20, 0, 0xd5, 0, 0x1a, 0x41, 1, 0x0f, 0x0b, 0x41, 0, 0x0b } },
            .{ .bytes = &.{ 0, 0x02, 0x6f, 0x20, 0, 0xd6, 0, 0xd0, 0x6f, 0x0b, 0x0b } },
        },
    };
    var instance: wasm.Instance = undefined;
    try wasm.instantiate(&instance, arena.allocator(), a, &module, .{});
    defer instance.deinit();
    instance.shared_backend_enabled = true;
    try expectNative(&instance, 0, &.{}, &.{wasm.interpreter.makeFuncRef(&instance, 0)});
    try expectNative(&instance, 1, &.{17}, &.{17});
    const before = instance.shared_backend_stats.entries;
    try std.testing.expectError(error.NullReference, wasm.invoke(&instance, a, 1, &.{wasm.REF_NULL}));
    try std.testing.expectEqual(before + 1, instance.shared_backend_stats.entries);
    for ([_]u128{ 0, 17, wasm.REF_NULL }) |reference| {
        try expectNative(&instance, 2, &.{reference}, &.{@intFromBool(reference != wasm.REF_NULL)});
        try expectNative(&instance, 3, &.{reference}, &.{reference});
    }
}

test "backend references: indirect and typed calls retain the foreign defining instance" {
    if (!wasm.backend_prototype.native.supported) return error.SkipZigTest;
    for (0..3) |tier| {
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        const provider_module: wasm.Module = .{
            .types = &.{ .{ .params = &.{.i32}, .results = &.{.i32} }, .{ .params = &.{.i64}, .results = &.{.i64} } },
            .funcs = &.{ 0, 1 },
            .code = &.{ .{ .bytes = &.{ 0, 0x20, 0, 0x41, 7, 0x6a, 0x0b } }, .{ .bytes = &.{ 0, 0x20, 0, 0x0b } } },
        };
        var provider: wasm.Instance = undefined;
        try wasm.instantiate(&provider, arena.allocator(), a, &provider_module, .{});
        defer provider.deinit();
        provider.spasm_enabled = tier == 1;
        provider.shared_backend_enabled = tier == 2;
        const module: wasm.Module = .{
            .types = &.{
                provider_module.types[0],
                .{ .params = &.{ .i32, .i32 }, .results = &.{.i32} },
                .{ .params = &.{ .i32, wasm.ValType.refType(true, 0) }, .results = &.{.i32} },
            },
            .tables = &.{.{ .elem = .funcref, .limits = .{ .min = 2 } }},
            .funcs = &.{ 1, 2 },
            .code = &.{
                .{ .bytes = &.{ 0, 0x20, 0, 0x20, 1, 0x11, 0, 0, 0x0b } },
                .{ .bytes = &.{ 0, 0x20, 0, 0x20, 1, 0x14, 0, 0x0b } },
            },
        };
        var instance: wasm.Instance = undefined;
        try wasm.instantiate(&instance, arena.allocator(), a, &module, .{});
        defer instance.deinit();
        instance.shared_backend_enabled = true;
        const reference = wasm.interpreter.makeFuncRef(&provider, 0);
        instance.tables[0].elems[0] = reference;
        try expectNative(&instance, 0, &.{ 35, 0 }, &.{42});
        try expectNative(&instance, 1, &.{ 35, reference }, &.{42});
        const before = instance.shared_backend_stats.entries;
        try std.testing.expectError(error.UninitializedElement, wasm.invoke(&instance, a, 0, &.{ 35, 1 }));
        try std.testing.expectError(error.UndefinedElement, wasm.invoke(&instance, a, 0, &.{ 35, 2 }));
        try std.testing.expectError(error.NullReference, wasm.invoke(&instance, a, 1, &.{ 35, wasm.REF_NULL }));
        instance.tables[0].elems[1] = wasm.interpreter.makeFuncRef(&provider, 1);
        try std.testing.expectError(error.IndirectCallTypeMismatch, wasm.invoke(&instance, a, 0, &.{ 35, 1 }));
        try std.testing.expectEqual(before + 4, instance.shared_backend_stats.entries);
        try std.testing.expectEqual(@as(u64, if (tier == 2) 2 else 0), provider.shared_backend_stats.entries);
    }
}

test "backend references: table64 aliases copy overlap and dropped element bounds" {
    if (!wasm.backend_prototype.native.supported) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const table_type: wasm.types.TableType = .{ .elem = .funcref, .limits = .{ .min = 4, .is_64 = true } };
    const module: wasm.Module = .{
        .types = &.{
            .{ .params = &.{ .i64, .i64, .i64 }, .results = &.{} },
            .{ .params = &.{ .i64, .i32, .i32 }, .results = &.{} },
            .{ .params = &.{}, .results = &.{} },
        },
        .imports = &.{ .{ .module = "h", .name = "a", .desc = .{ .table = table_type } }, .{ .module = "h", .name = "b", .desc = .{ .table = table_type } } },
        .funcs = &.{ 0, 1, 2 },
        .elements_count = 1,
        .elements_raw = &.{ 1, 0, 1, 2 },
        .code = &.{
            .{ .bytes = &.{ 0, 0x20, 0, 0x20, 1, 0x20, 2, 0xfc, 14, 0, 1, 0x0b } },
            .{ .bytes = &.{ 0, 0x20, 0, 0x20, 1, 0x20, 2, 0xfc, 12, 0, 0, 0x0b } },
            .{ .bytes = &.{ 0, 0xfc, 13, 0, 0x0b } },
        },
    };
    var cells = [_]u128{ 1, 2, 3, 4 };
    var table: wasm.Table = .{ .elems = &cells, .max = 4, .is_64 = true };
    var instance: wasm.Instance = undefined;
    try wasm.instantiate(&instance, arena.allocator(), a, &module, .{ .tables = &.{ &table, &table } });
    defer instance.deinit();
    instance.shared_backend_enabled = true;
    try expectNative(&instance, 0, &.{ 1, 0, 3 }, &.{});
    try std.testing.expectEqualSlices(u128, &.{ 1, 1, 2, 3 }, &cells);
    try expectNative(&instance, 0, &.{ 0, 1, 3 }, &.{});
    try std.testing.expectEqualSlices(u128, &.{ 1, 2, 3, 3 }, &cells);
    try expectNative(&instance, 1, &.{ 0, 0, 1 }, &.{});
    try std.testing.expectEqual(wasm.interpreter.makeFuncRef(&instance, 2), cells[0]);
    try expectNative(&instance, 2, &.{}, &.{});
    try expectNative(&instance, 1, &.{ 4, 0, 0 }, &.{});
    const before = instance.shared_backend_stats.entries;
    try std.testing.expectError(error.OutOfBoundsTableAccess, wasm.invoke(&instance, a, 1, &.{ 0, 0, 1 }));
    try std.testing.expectError(error.OutOfBoundsTableAccess, wasm.invoke(&instance, a, 0, &.{ std.math.maxInt(u64), 0, 1 }));
    try std.testing.expectEqual(before + 2, instance.shared_backend_stats.entries);
}

const loop_module: wasm.Module = .{
    .types = &.{.{ .params = &.{ .externref, .externref, .i32 }, .results = &.{.externref} }},
    .funcs = &.{0},
    .code = &.{.{ .bytes = &.{
        1,    1,    0x6f, 0x02, 0x40, 0x03, 0x40,
        0x20, 2,    0x45, 0x0d, 1,    0x20, 0,
        0x20, 1,    0x20, 2,    0x41, 1,    0x71,
        0x1c, 1,    0x6f, 0x21, 3,    0x20, 2,
        0x41, 1,    0x6b, 0x21, 2,    0x0c, 0,
        0x0b, 0x0b, 0x20, 3,    0x0b,
    } }},
};

fn runReferenceLoop(code: *const prototype.Compiled, instance: *wasm.Instance) !void {
    for ([_]u64{ 0, 1, 9 }) |count| {
        var result: [2]u64 = undefined;
        var completion = try prototype.runResultsInInstance(code, instance, &.{ 17, 0, 91, 0, count }, 100, &result);
        defer completion.deinit();
        try std.testing.expect(completion == .returned);
        try std.testing.expectEqualSlices(u64, if (count == 0) &.{ std.math.maxInt(u64), std.math.maxInt(u64) } else &.{ 17, 0 }, &result);
    }
}

test "backend references: loop pairs survive all optimization and allocation modes" {
    if (!prototype.native.supported) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    var instance: wasm.Instance = undefined;
    try wasm.instantiate(&instance, arena.allocator(), a, &loop_module, .{});
    defer instance.deinit();
    var owner = try prototype.CodeAllocator.init(a, 256 * 1024);
    defer owner.deinit();
    const Mode = @import("../jit/backend/allocation.zig").Mode;
    for ([_]Mode{ .scratch, .linear_scan }) |mode| for (0..16) |flags| for ([_]u8{ 0, 1, 4 }) |registers| {
        var code = blk: {
            var graph = try prototype.lowerInstance(a, &instance, 0);
            defer graph.deinit();
            break :blk try prototype.compile(a, &owner, &graph, .{
                .allocation = mode,
                .register_count = registers,
                .rematerialize_constants = flags & 8 != 0,
                .optimization = .{ .constant_folding = flags & 1 != 0, .common_subexpression_elimination = flags & 2 != 0, .dead_code_elimination = flags & 4 != 0 },
            });
        };
        defer code.deinit();
        try runReferenceLoop(&code, &instance);
    };
}

fn referenceAllocationFailures(allocator: std.mem.Allocator, owner: *prototype.CodeAllocator, instance: *wasm.Instance) !void {
    var graph = try prototype.lowerInstance(allocator, instance, 0);
    defer graph.deinit();
    var code = try prototype.compile(allocator, owner, &graph, .{});
    defer code.deinit();
    try runReferenceLoop(&code, instance);
}

test "backend references: allocation failures release paired graph and call metadata" {
    if (!prototype.native.supported) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    var instance: wasm.Instance = undefined;
    try wasm.instantiate(&instance, arena.allocator(), a, &loop_module, .{});
    defer instance.deinit();
    var owner = try prototype.CodeAllocator.init(a, 256 * 1024);
    defer owner.deinit();
    // Arena growth must allocate so failure indices do not depend on whether
    // the backing allocator can extend a particular mapping in place.
    var no_resize = std.testing.FailingAllocator.init(a, .{ .resize_fail_index = 0 });
    try std.testing.checkAllAllocationFailures(no_resize.allocator(), referenceAllocationFailures, .{ &owner, &instance });
}

test "backend references: typed snapshots root only externrefs and pin failure never replays stores" {
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
        fn call(raw: ?*anyopaque, _: []const u128, _: []u128) wasm.TrapError!void {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            if (self.pins == 0) return error.HostThrew;
            self.calls += 1;
        }
    };
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const module: wasm.Module = .{
        .types = &.{ .{ .params = &.{}, .results = &.{} }, .{ .params = &.{ .externref, .i64, .funcref }, .results = &.{} } },
        .imports = &.{.{ .module = "h", .name = "f", .desc = .{ .func = 0 } }},
        .globals = &.{.{ .type = .{ .val = .i32, .mut = .mutable }, .init_expr = &.{ 0x41, 0, 0x0b } }},
        .funcs = &.{1},
        .code = &.{.{ .bytes = &.{ 0, 0x23, 0, 0x41, 1, 0x6a, 0x24, 0, 0x10, 0, 0x0b } }},
    };
    var host: Host = .{};
    var instance: wasm.Instance = undefined;
    try wasm.instantiate(&instance, arena.allocator(), a, &module, .{ .funcs = &.{.{ .host = .{ .fn_ptr = Host.call, .ctx = &host, .params = 0, .results = 0 } }} });
    defer instance.deinit();
    instance.externref_rooter = .{ .context = &host, .pin_fn = Host.pin };
    instance.shared_backend_enabled = true;
    instance.spasm_enabled = true;
    const reference = wasm.interpreter.makeFuncRef(&instance, 1);
    try expectNative(&instance, 1, &.{ 17, 91, reference }, &.{});
    try std.testing.expectEqual(@as(usize, 1), host.pins);
    try std.testing.expectEqual(@as(usize, 1), host.calls);
    host.fail = true;
    try std.testing.expectError(error.OutOfMemory, wasm.invoke(&instance, a, 1, &.{ 17, 91, reference }));
    try std.testing.expectEqual(@as(u128, 2), instance.globals[0].value);
    try std.testing.expectEqual(@as(usize, 1), host.calls);
    try std.testing.expectEqual(@as(u64, 2), instance.shared_backend_stats.entries);
    try std.testing.expectEqual(@as(u32, 0), instance.spasm_runs);
}

test "backend references: physical arity limits refuse before native entry" {
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const params: [prototype.ir.max_arguments / 2 + 1]wasm.ValType = @splat(.externref);
    for ([_]usize{ params.len - 1, params.len }) |count| {
        const module: wasm.Module = .{
            .types = &.{.{ .params = params[0..count], .results = &.{} }},
            .funcs = &.{0},
            .code = &.{.{ .bytes = &.{ 0, 0x0b } }},
        };
        var instance: wasm.Instance = undefined;
        try wasm.instantiate(&instance, arena.allocator(), a, &module, .{});
        defer instance.deinit();
        if (count == params.len) {
            try std.testing.expectError(error.UnsupportedSignature, prototype.lowerInstance(a, &instance, 0));
        } else {
            var graph = try prototype.lowerInstance(a, &instance, 0);
            defer graph.deinit();
            try std.testing.expectEqual(@as(usize, prototype.ir.max_arguments), graph.graph.argument_types.len);
        }
    }
}

test "backend references: loaded-reference pin failures unwind all tiers without replay" {
    if (!prototype.native.supported) return error.SkipZigTest;
    const Host = struct {
        fn pin(_: *anyopaque, _: u128) error{OutOfMemory}!void {
            return error.OutOfMemory;
        }
    };
    for (0..3) |tier| for ([_]bool{ false, true }) |global| {
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        const module: wasm.Module = .{
            .types = &.{.{ .params = &.{}, .results = &.{.externref} }},
            .globals = &.{
                .{ .type = .{ .val = .i32, .mut = .mutable }, .init_expr = &.{ 0x41, 0, 0x0b } },
                .{ .type = .{ .val = .externref, .mut = .mutable }, .init_expr = &.{ 0xd0, 0x6f, 0x0b } },
            },
            .tables = &.{.{ .elem = .externref, .limits = .{ .min = 1 } }},
            .funcs = &.{0},
            .code = &.{.{ .bytes = if (global)
                &.{ 0, 0x23, 0, 0x41, 1, 0x6a, 0x24, 0, 0x23, 1, 0x0b }
            else
                &.{ 0, 0x23, 0, 0x41, 1, 0x6a, 0x24, 0, 0x41, 0, 0x25, 0, 0x0b } }},
        };
        var instance: wasm.Instance = undefined;
        try wasm.instantiate(&instance, arena.allocator(), a, &module, .{});
        defer instance.deinit();
        instance.externref_rooter = .{ .context = &instance, .pin_fn = Host.pin };
        instance.spasm_enabled = tier != 0;
        instance.shared_backend_enabled = tier == 2;
        instance.globals[1].value = 17;
        instance.tables[0].elems[0] = 17;
        try std.testing.expectError(error.OutOfMemory, wasm.invoke(&instance, a, 0, &.{}));
        try std.testing.expectEqual(@as(u128, 1), instance.globals[0].value);
        try std.testing.expectEqual(@as(u64, @intFromBool(tier == 2)), instance.shared_backend_stats.entries);
        try std.testing.expectEqual(@as(u32, @intFromBool(tier == 1)), instance.spasm_runs);
    };
}
