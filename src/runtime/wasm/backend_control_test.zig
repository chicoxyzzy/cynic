const std = @import("std");
const wasm = @import("wasm.zig");
const prototype = @import("backend_prototype.zig");
const a = std.testing.allocator;
const Case = struct { args: []const u64, expected: u64 };

fn expectControl(module: *const wasm.Module, cases: []const Case) !void {
    if (!prototype.native.supported) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    var instance: wasm.Instance = undefined;
    try wasm.instantiate(&instance, arena.allocator(), a, module, .{});
    defer instance.deinit();
    var graph = try prototype.lowerInstance(a, &instance, 0);
    defer graph.deinit();
    var owner = try prototype.CodeAllocator.init(a, 256 * 1024);
    defer owner.deinit();
    for (cases) |case| {
        var cells: [prototype.ir.max_arguments]u128 = undefined;
        for (case.args, 0..) |value, i| cells[i] = value;
        for ([_]bool{ false, true }) |spasm| {
            instance.spasm_enabled = spasm;
            const result = try wasm.invoke(&instance, a, 0, cells[0..case.args.len]);
            defer a.free(result);
            try std.testing.expectEqualSlices(u128, &.{case.expected}, result);
        }
    }
    try std.testing.expectEqual(cases.len, instance.spasm_runs);
    for (0..16) |flags| {
        for ([_]u8{ 0, 1, 4 }) |registers| {
            var code = try prototype.native.compileWithOptions(a, &owner, graph.graph, .{
                .register_count = registers,
                .rematerialize_constants = flags & 8 != 0,
                .optimization = .{
                    .constant_folding = flags & 1 != 0,
                    .common_subexpression_elimination = flags & 2 != 0,
                    .dead_code_elimination = flags & 4 != 0,
                },
            });
            defer code.deinit();
            for (cases) |case| try std.testing.expectEqual(case.expected, try code.run(case.args, 10_000));
        }
    }
}

test "backend control: result branches discard beneath carried values" {
    const module: wasm.Module = .{
        .types = &.{.{ .params = &.{.i32}, .results = &.{.i64} }},
        .funcs = &.{0},
        .code = &.{.{
            .bytes = &.{
                0,    0x42, 7,    0x02, 0x7e, // prefix 7; block (result i64)
                0x41, 0x63, 0x42, 11,   0x20,
                0,    0x0d, 0,    0x1a, 0x1a,
                0x42, 13,   0x0b, 0x7c, 0x0b,
            },
        }},
    };
    try expectControl(&module, &.{ .{ .args = &.{0}, .expected = 20 }, .{ .args = &.{1}, .expected = 18 } });
}

test "backend control: typed if arms merge multiple results and mutated locals" {
    const module: wasm.Module = .{
        .types = &.{
            .{ .params = &.{.i32}, .results = &.{.i64} },
            .{ .params = &.{ .i32, .i64 }, .results = &.{ .i64, .i32 } },
        },
        .funcs = &.{0},
        .code = &.{.{
            .bytes = &.{
                2,    1,    0x7f, 1,    0x7e, // locals i32, i64
                0x41, 4,    0x42, 9,    0x20,
                0,    0x04, 1,    0x21, 2,
                0x21, 1,    0x20, 2,    0x20,
                1,    0x05, 0x1a, 0x1a, 0x42,
                20,   0x41, 3,    0x0b, 0xad,
                0x7c, 0x0b,
            },
        }},
    };
    try expectControl(&module, &.{ .{ .args = &.{0}, .expected = 23 }, .{ .args = &.{1}, .expected = 13 } });
}

test "backend control: loop parameters carry simultaneous values on backedges" {
    const module: wasm.Module = .{
        .types = &.{
            .{ .params = &.{.i32}, .results = &.{.i32} },
            .{ .params = &.{ .i32, .i32 }, .results = &.{.i32} },
        },
        .funcs = &.{0},
        .code = &.{.{ .bytes = &.{
            1,    2,    0x7f, 0x02, 0x7f, 0x20, 0,    0x41, 0,    0x03, 1,
            0x21, 2,    0x21, 1,    0x20, 2,    0x20, 1,    0x45, 0x0d, 1,
            0x1a, 0x20, 1,    0x41, 1,    0x6b, 0x20, 2,    0x20, 1,    0x6a,
            0x0c, 0,    0x0b, 0x0b, 0x0b,
        } }},
    };
    try expectControl(&module, &.{ .{ .args = &.{0}, .expected = 0 }, .{ .args = &.{1}, .expected = 1 }, .{ .args = &.{100}, .expected = 5050 } });
}

test "backend control: branch tables carry values across distinct stack heights" {
    const module: wasm.Module = .{
        .types = &.{
            .{ .params = &.{.i32}, .results = &.{.i64} },
            .{ .params = &.{}, .results = &.{ .i32, .i64 } },
        },
        .funcs = &.{0},
        .code = &.{.{ .bytes = &.{
            2,    1,    0x7f, 1,    0x7e,
            0x02, 1,    0x41, 55,   0x02,
            1,    0x41, 0x63, 0x41, 7,
            0x42, 11,   0x20, 0,    0x0e,
            2,    0,    1,    1,    0x0b,
            0x42, 1,    0x7c, 0x21, 2,
            0x21, 1,    0x1a, 0x20, 1,
            0x20, 2,    0x0b, 0x21, 2,
            0xad, 0x20, 2,    0x7c, 0x0b,
        } }},
    };
    try expectControl(&module, &.{ .{ .args = &.{0}, .expected = 19 }, .{ .args = &.{1}, .expected = 18 }, .{ .args = &.{2}, .expected = 18 }, .{ .args = &.{0xffff_ffff}, .expected = 18 } });
}

test "backend control: branch to implicit function label returns carried result" {
    const module: wasm.Module = .{
        .types = &.{.{ .params = &.{}, .results = &.{.i32} }},
        .funcs = &.{0},
        .code = &.{.{ .bytes = &.{ 0, 0x41, 42, 0x41, 0, 0x0e, 0, 0, 0x00, 0x0b } }},
    };
    // The table index is also a discarded operand; the result is beneath it.
    var amended = module;
    try expectControl(&amended, &.{.{ .args = &.{}, .expected = 42 }});
    amended.code = &.{.{ .bytes = &.{ 0, 0x41, 42, 0x0c, 0, 0x00, 0x0b } }};
    try expectControl(&amended, &.{.{ .args = &.{}, .expected = 42 }});
    amended.types = &.{.{ .params = &.{.i32}, .results = &.{.i32} }};
    amended.code = &.{.{ .bytes = &.{ 0, 0x41, 42, 0x20, 0, 0x0d, 0, 0x1a, 0x41, 7, 0x0b } }};
    try expectControl(&amended, &.{ .{ .args = &.{0}, .expected = 7 }, .{ .args = &.{1}, .expected = 42 } });
}

test "backend control: else metadata survives a terminated then arm" {
    const module: wasm.Module = .{
        .types = &.{.{ .params = &.{.i32}, .results = &.{.i32} }},
        .funcs = &.{0},
        .code = &.{.{ .bytes = &.{
            0,    0x20, 0,    0x04, 0x7f, 0x41, 11, 0x0f,
            0x05, 0x02, 0x7f, 0x41, 7,    0x0c, 0,  0x00,
            0x0b, 0x0b, 0x0b,
        } }},
    };
    try expectControl(&module, &.{ .{ .args = &.{0}, .expected = 7 }, .{ .args = &.{1}, .expected = 11 } });
}

test "backend control: typed if without else retains its input on the false edge" {
    const module: wasm.Module = .{
        .types = &.{ .{ .params = &.{.i32}, .results = &.{.i64} }, .{ .params = &.{.i64}, .results = &.{.i64} } },
        .funcs = &.{0},
        .code = &.{.{ .bytes = &.{ 0, 0x42, 9, 0x20, 0, 0x04, 1, 0x42, 1, 0x7c, 0x0b, 0x0b } }},
    };
    try expectControl(&module, &.{ .{ .args = &.{0}, .expected = 9 }, .{ .args = &.{1}, .expected = 10 } });
}

test "backend control: typed and untyped select preserve every scalar bit pattern" {
    for ([_]wasm.ValType{ .i32, .i64, .f32, .f64 }) |ty| {
        for ([_]bool{ false, true }) |typed| {
            const params = [_]wasm.ValType{ ty, ty, .i32 };
            const results = [_]wasm.ValType{ty};
            const body = [_]u8{ 0, 0x20, 0, 0x20, 1, 0x20, 2, 0x1c, 1, @intCast(@backingInt(ty)), 0x0b };
            const module: wasm.Module = .{
                .types = &.{.{ .params = &params, .results = &results }},
                .funcs = &.{0},
                .code = &.{.{ .bytes = if (typed) &body else &.{ 0, 0x20, 0, 0x20, 1, 0x20, 2, 0x1b, 0x0b } }},
            };
            const lhs: u64 = if (ty == .i32 or ty == .f32) 0xffc0_0042 else 0xfff8_0000_0000_0042;
            const rhs: u64 = if (ty == .i32 or ty == .f32) 0x8000_0000 else 0x8000_0000_0000_0000;
            try expectControl(&module, &.{ .{ .args = &.{ lhs, rhs, 0 }, .expected = rhs }, .{ .args = &.{ lhs, rhs, 1 }, .expected = lhs }, .{ .args = &.{ lhs, rhs, 0x8000_0000 }, .expected = lhs } });
        }
    }
}

test "backend control: select evaluates both operands before choosing" {
    if (!prototype.native.supported) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const bytes = try @import("backend_prototype_test.zig").moduleBytes(arena.allocator(), &.{0x7f}, 0x7f, &.{}, &.{
        0x41, 7, 0x41, 1, 0x41, 0, 0x6d, 0x20, 0, 0x1b, 0x0b,
    });
    var graph = try prototype.lowerModule(a, bytes, 0);
    defer graph.deinit();
    var owner = try prototype.CodeAllocator.init(a, 64 * 1024);
    defer owner.deinit();
    for ([_]bool{ false, true }) |optimize| {
        var code = try prototype.native.compileWithOptions(a, &owner, graph.graph, .{ .optimization = .{
            .constant_folding = optimize,
            .common_subexpression_elimination = optimize,
            .dead_code_elimination = optimize,
        } });
        defer code.deinit();
        for ([_]u64{ 0, 1 }) |condition| {
            var outcome = try code.runOutcome(&.{condition}, 20);
            defer outcome.deinit();
            try std.testing.expectEqual(prototype.ir.TrapReason.division_by_zero, outcome.trapped.reason);
            try std.testing.expectEqual(@as(u32, 6), outcome.trapped.site);
        }
    }
}

test "backend control: nested dead control consumes no branch metadata" {
    const module: wasm.Module = .{
        .types = &.{.{ .params = &.{}, .results = &.{.i32} }},
        .funcs = &.{0},
        .code = &.{.{ .bytes = &.{
            0,    0x41, 5,    0x0f, 0x04, 0x7f, 0x41, 7, 0x0c, 0,
            0x05, 0x41, 9,    0x41, 0,    0x0e, 0,    0, 0x0b, 0x1a,
            0x41, 8,    0x0b,
        } }},
    };
    try expectControl(&module, &.{.{ .args = &.{}, .expected = 5 }});
}

fn lowerWithFailures(allocator: std.mem.Allocator, instance: *wasm.Instance) !void {
    var graph = try prototype.lowerInstance(allocator, instance, 0);
    defer graph.deinit();
    try graph.graph.verify();
}

test "backend control: typed edges and table lowering clean up every allocation failure" {
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const module: wasm.Module = .{
        .types = &.{.{ .params = &.{.i32}, .results = &.{.i32} }},
        .funcs = &.{0},
        .code = &.{.{ .bytes = &.{
            0,    0x02, 0x7f, 0x20, 0, 0x04, 0x7f, 0x41, 7, 0x0c, 1,
            0x05, 0x41, 9,    0x41, 0, 0x0e, 1,    1,    1, 0x0b, 0x0b,
            0x0b,
        } }},
    };
    var instance: wasm.Instance = undefined;
    try wasm.instantiate(&instance, arena.allocator(), a, &module, .{});
    defer instance.deinit();
    try std.testing.checkAllAllocationFailures(a, lowerWithFailures, .{&instance});
}

test "backend control: oversized tables and unsupported dead signatures refuse" {
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const helper = @import("backend_prototype_test.zig");
    var body: std.ArrayList(u8) = .empty;
    try body.appendSlice(arena.allocator(), &.{ 0x41, 42, 0x41, 0, 0x0e, 0x80, 0x02 });
    try body.appendNTimes(arena.allocator(), 0, 257);
    try body.append(arena.allocator(), 0x0b);
    const oversized = try helper.moduleBytes(arena.allocator(), &.{}, 0x7f, &.{}, body.items);
    try std.testing.expectError(error.PrototypeLimit, prototype.lowerModule(a, oversized, 0));
    for ([_][]const u8{
        &.{ 0x41, 5, 0x0f, 0x02, 0x7b, 0x00, 0x0b, 0x1a, 0x41, 8, 0x0b },
        &.{ 0x41, 5, 0x0f, 0x1c, 1, 0x6f, 0x1a, 0x41, 8, 0x0b },
    }) |dead_body| {
        const bytes = try helper.moduleBytes(arena.allocator(), &.{}, 0x7f, &.{}, dead_body);
        try std.testing.expectError(error.UnsupportedType, prototype.lowerModule(a, bytes, 0));
    }
}

test "backend control: typed loop backedges remain budget bounded" {
    if (!prototype.native.supported) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const module: wasm.Module = .{
        .types = &.{.{ .params = &.{.i32}, .results = &.{.i32} }},
        .funcs = &.{0},
        .code = &.{.{ .bytes = &.{ 0, 0x20, 0, 0x03, 0, 0x41, 1, 0x6a, 0x0c, 0, 0x0b, 0x0b } }},
    };
    var instance: wasm.Instance = undefined;
    try wasm.instantiate(&instance, arena.allocator(), a, &module, .{});
    defer instance.deinit();
    var graph = try prototype.lowerInstance(a, &instance, 0);
    defer graph.deinit();
    var owner = try prototype.CodeAllocator.init(a, 64 * 1024);
    defer owner.deinit();
    var code = try prototype.native.compile(a, &owner, graph.graph);
    defer code.deinit();
    for ([_]u32{ 0, 1, 1000 }) |budget| try std.testing.expectError(error.BudgetExhausted, code.run(&.{42}, budget));
}

test "backend control: indexed block signatures decode signed multibyte LEBs" {
    const signatures: [129]wasm.FuncType = @splat(.{ .params = &.{.i32}, .results = &.{.i32} });
    for ([_][2]u8{ .{ 0xc0, 0 }, .{ 0x80, 1 } }) |index| {
        const body = [_]u8{ 0, 0x20, 0, 0x02, index[0], index[1], 0x41, 1, 0x6a, 0x0b, 0x0b };
        const module: wasm.Module = .{ .types = &signatures, .funcs = &.{0}, .code = &.{.{ .bytes = &body }} };
        try expectControl(&module, &.{ .{ .args = &.{41}, .expected = 42 }, .{ .args = &.{0xffff_ffff}, .expected = 0 } });
    }
}

test "backend control: generated branch tables match nested-label arithmetic" {
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const alloc = arena.allocator();
    for ([_]u8{ 1, 2, 5, 8, 13 }) |count| {
        var body: std.ArrayList(u8) = .empty;
        try body.append(alloc, 0);
        for (0..count) |_| try body.appendSlice(alloc, &.{ 0x02, 0x7f });
        try body.appendSlice(alloc, &.{ 0x41, 10, 0x20, 0, 0x0e, count });
        for (0..count) |i| try body.append(alloc, @intCast((i * 5) % count));
        const default = (count - 1) / 2;
        try body.appendSlice(alloc, &.{ default, 0x00 });
        for (0..count) |i| {
            try body.append(alloc, 0x0b);
            if (i + 1 < count) try body.appendSlice(alloc, &.{ 0x41, 1, 0x6a });
        }
        try body.append(alloc, 0x0b);
        const module: wasm.Module = .{
            .types = &.{.{ .params = &.{.i32}, .results = &.{.i32} }},
            .funcs = &.{0},
            .code = &.{.{ .bytes = body.items }},
        };
        const inputs = try alloc.alloc([1]u64, @as(usize, count) + 3);
        const cases = try alloc.alloc(Case, inputs.len);
        for (inputs, cases, 0..) |*input, *case, i| {
            input[0] = if (i + 1 == inputs.len) 0xffff_ffff else i;
            const depth = if (i < count) (i * 5) % count else default;
            case.* = .{ .args = input, .expected = 10 + count - 1 - depth };
        }
        try expectControl(&module, cases);
    }
}
