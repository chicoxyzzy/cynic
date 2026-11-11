const std = @import("std");
const ir = @import("ir.zig");
const native = @import("native.zig");
const allocation = @import("allocation.zig");
const CodeAllocator = @import("../code_alloc.zig").CodeAllocator;
const a = std.testing.allocator;

test "backend SIMD lanes: scalar transfers and lane immediates survive every optimization" {
    const input: u128 = 0xffeeddccbbaa9988_7766554433221180;
    for ([_]ir.VectorLane{ .i8x16, .i16x8, .i32x4, .i64x2, .f32x4, .f64x2 }) |lane| {
        const scalar: u64 = if (lane.bytes() == 8) 0xfff0000000000042 else 0xff800042;
        const mask = (@as(u128, 1) << @as(u7, @intCast(lane.bytes() * 8))) - 1;
        const shift: u7 = @intCast(128 - lane.bytes() * 8);
        var splat: u128 = 0;
        for (0..lane.count()) |i| splat |= (@as(u128, scalar) & mask) << @as(u7, @intCast(i * lane.bytes() * 8));
        const replaced = (input & ~(mask << shift)) | ((@as(u128, scalar) & mask) << shift);
        const graph: ir.Graph = .{
            .types = &.{ .v128, lane.scalarType(), .v128, .v128, lane.scalarType(), lane.scalarType() },
            .argument_types = &.{ .v128, lane.scalarType() },
            .result_types = &.{ .v128, .v128, lane.scalarType(), lane.scalarType(), .v128, lane.scalarType() },
            .blocks = &.{.{ .params = &.{ 0, 1 }, .nodes = &.{
                .{ .op = .vector_splat, .out = 2, .lhs = 1, .vector_lane = lane },
                .{ .op = .vector_replace, .out = 3, .lhs = 0, .rhs = 1, .vector_lane = lane, .immediate = lane.count() - 1 },
                .{ .op = .vector_extract, .out = 4, .lhs = 0, .vector_lane = lane, .immediate = 0 },
                .{ .op = .vector_extract, .out = 5, .lhs = 0, .vector_lane = lane, .immediate = lane.count() - 1 },
            }, .terminator = .{ .return_ = &.{ 2, 3, 4, 5, 0, 1 } } }},
        };
        try check(graph, &.{ @truncate(input), @truncate(input >> 64), scalar }, &.{ @truncate(splat), @truncate(splat >> 64), @truncate(replaced), @truncate(replaced >> 64), @truncate(input & mask), @truncate(input >> shift), @truncate(input), @truncate(input >> 64), scalar }, null);
    }
}

test "backend SIMD lanes: permutations preserve live homes and CSE keeps both mask words" {
    const graph: ir.Graph = .{
        .types = &.{ .v128, .v128, .v128, .v128, .i64, .i64, .i64, .i64, .v128, .v128, .v128, .v128 },
        .argument_types = &.{ .v128, .v128, .v128, .v128, .i64, .i64, .i64, .i64 },
        .result_types = &.{ .v128, .v128, .v128, .v128, .v128, .v128, .i64, .i64, .i64, .i64 },
        .blocks = &.{.{ .params = &.{ 0, 1, 2, 3, 4, 5, 6, 7 }, .nodes = &.{
            .{ .op = .vector_shuffle, .out = 8, .lhs = 0, .rhs = 1, .immediate = 0x0706050403020100, .immediate_hi = 0x1f1e1d1c1b1a1918 },
            .{ .op = .vector_shuffle, .out = 9, .lhs = 0, .rhs = 1, .immediate = 0x1716151413121110, .immediate_hi = 0x1f1e1d1c1b1a1918 },
            .{ .op = .vector_shuffle, .out = 10, .lhs = 0, .rhs = 1, .immediate = 0x0706050403020100, .immediate_hi = 0x0f0e0d0c0b0a0908 },
            .{ .op = .vector_swizzle, .out = 11, .lhs = 0, .rhs = 2 },
        }, .terminator = .{ .return_ = &.{ 8, 9, 10, 11, 0, 3, 4, 5, 6, 7 } } }},
    };
    try check(graph, &.{ 0x0706050403020100, 0x0f0e0d0c0b0a0908, 0x1716151413121110, 0x1f1e1d1c1b1a1918, 0x0807060504030201, 0xffff807f20100f00, 42, 43, 11, 22, 33, 44 }, &.{
        0x0706050403020100, 0x1f1e1d1c1b1a1918, 0x1716151413121110, 0x1f1e1d1c1b1a1918,
        0x0706050403020100, 0x0f0e0d0c0b0a0908, 0x0807060504030201, 0x0000000000000f00,
        0x0706050403020100, 0x0f0e0d0c0b0a0908, 42,                 43,
        11,                 22,                 33,                 44,
    }, null);
}

test "backend SIMD lanes: verifier rejects invalid lane types indices and shuffle selectors" {
    var nodes = [_]ir.Node{.{ .op = .vector_extract, .out = 1, .lhs = 0, .vector_lane = .i8x16, .immediate = 15 }};
    const blocks = [_]ir.Block{.{ .params = &.{0}, .nodes = &nodes, .terminator = .{ .return_ = &.{1} } }};
    var graph: ir.Graph = .{ .types = &.{ .v128, .i32 }, .argument_types = &.{.v128}, .result_types = &.{.i32}, .blocks = &blocks };
    try graph.verify();
    nodes[0].immediate = 16;
    try std.testing.expectError(error.InvalidGraph, graph.verify());
    nodes[0].immediate = 0;
    nodes[0].vector_lane = .f32x4;
    try std.testing.expectError(error.InvalidGraph, graph.verify());
    nodes[0].vector_lane = null;
    try std.testing.expectError(error.InvalidGraph, graph.verify());
    nodes[0] = .{ .op = .vector_shuffle, .lhs = 0, .rhs = 0, .out = 1, .immediate = 0x20 };
    graph.types = &.{ .v128, .v128 };
    graph.result_types = &.{.v128};
    try std.testing.expectError(error.InvalidGraph, graph.verify());
    nodes[0].immediate = 0;
    nodes[0].immediate_hi = 0x8000000000000000;
    try std.testing.expectError(error.InvalidGraph, graph.verify());
    nodes[0].immediate_hi = 0;
    try graph.verify();
    nodes[0].vector_lane = .i8x16;
    try std.testing.expectError(error.InvalidGraph, graph.verify());
}

pub fn check(graph: ir.Graph, args: []const u64, expected: []const u64, runtime: ?native.Runtime) !void {
    if (!native.supported) return error.SkipZigTest;
    var owner = try CodeAllocator.init(a, 256 * 1024);
    defer owner.deinit();
    for ([_]allocation.Mode{ .scratch, .linear_scan }) |mode| for ([_]u8{ 0, 1, 4 }) |registers| for (0..16) |flags| {
        var code = try native.compileWithOptions(a, &owner, graph, .{
            .allocation = mode,
            .register_count = registers,
            .rematerialize_constants = flags & 8 != 0,
            .optimization = .{ .constant_folding = flags & 1 != 0, .common_subexpression_elimination = flags & 2 != 0, .dead_code_elimination = flags & 4 != 0 },
        });
        defer code.deinit();
        var results: [64]u64 = @splat(0);
        var completion = try code.runInto(args, &.{}, 100, runtime, results[0..expected.len]);
        defer completion.deinit();
        try std.testing.expect(completion == .returned);
        try std.testing.expectEqualSlices(u64, expected, results[0..expected.len]);
    };
}

test "backend vectors: constants retain both words through CSE and mixed returns" {
    const graph: ir.Graph = .{
        .types = &.{ .i32, .v128, .v128, .v128 },
        .argument_types = &.{.i32},
        .result_types = &.{ .v128, .i32, .v128, .v128 },
        .blocks = &.{.{ .params = &.{0}, .nodes = &.{
            .{ .op = .constant, .out = 1, .immediate = 7, .immediate_hi = 0xfff8_0000_0000_0042 },
            .{ .op = .constant, .out = 2, .immediate = 7, .immediate_hi = 0x8000_0000_0000_0000 },
            .{ .op = .bit_xor, .out = 3, .lhs = 1, .rhs = 2 },
        }, .terminator = .{ .return_ = &.{ 1, 0, 2, 3 } } }},
    };
    try check(graph, &.{0xffff_ffff_0000_0009}, &.{ 7, 0xfff8_0000_0000_0042, 9, 7, 0x8000_0000_0000_0000, 0, 0x7ff8_0000_0000_0042 }, null);
}

test "backend vectors: bitwise operations use every bit independently of lanes" {
    for ([_]ir.Op{ .bit_and, .bit_or, .bit_xor }) |op| {
        const graph: ir.Graph = .{ .types = &.{ .v128, .v128, .v128 }, .argument_types = &.{ .v128, .v128 }, .result_types = &.{.v128}, .blocks = &.{.{ .params = &.{ 0, 1 }, .nodes = &.{
            .{ .op = op, .out = 2, .lhs = 0, .rhs = 1 },
        }, .terminator = .{ .return_ = &.{2} } }} };
        const left = [_]u64{ 0x0123_4567_89ab_cdef, 0xffff_0000_ffff_0000 };
        const right = [_]u64{ 0xfedc_ba98_7654_3210, 0x0f0f_f0f0_0f0f_f0f0 };
        var expected: [2]u64 = undefined;
        for (&expected, left, right) |*out, lhs, rhs| out.* = switch (op) {
            .bit_and => lhs & rhs,
            .bit_or => lhs | rhs,
            .bit_xor => lhs ^ rhs,
            else => return error.TestUnexpectedResult,
        };
        try check(graph, &(left ++ right), &expected, null);
    }
}

test "backend vectors: lane addition wraps independently and uses strict floating arithmetic" {
    inline for (.{ .{ ir.VectorLane.i8x16, u8, 16 }, .{ ir.VectorLane.i16x8, u16, 8 }, .{ ir.VectorLane.i32x4, u32, 4 }, .{ ir.VectorLane.i64x2, u64, 2 }, .{ ir.VectorLane.f32x4, f32, 4 }, .{ ir.VectorLane.f64x2, f64, 2 } }) |case| {
        const T = case[1];
        const N = case[2];
        const floating = @typeInfo(T) == .float;
        var lhs: [N]T = undefined;
        var rhs: [N]T = undefined;
        var expected: [N]T = undefined;
        for (0..N) |i| {
            lhs[i] = if (floating) @as(T, @floatFromInt(i)) + 0.25 else std.math.maxInt(T) - @as(T, @intCast(i));
            rhs[i] = if (floating) 0.5 else @intCast(2 * i + 1);
            expected[i] = if (floating) lhs[i] + rhs[i] else lhs[i] +% rhs[i];
        }
        const lo: [2]u64 = @bitCast(lhs);
        const ro: [2]u64 = @bitCast(rhs);
        const result: [2]u64 = @bitCast(expected);
        const graph: ir.Graph = .{ .types = &.{ .v128, .v128, .v128 }, .argument_types = &.{ .v128, .v128 }, .result_types = &.{.v128}, .blocks = &.{.{ .params = &.{ 0, 1 }, .nodes = &.{
            .{ .op = .vector_add, .out = 2, .lhs = 0, .rhs = 1, .vector_lane = case[0] },
        }, .terminator = .{ .return_ = &.{2} } }} };
        try check(graph, &(lo ++ ro), &result, null);
    }
}

test "backend vectors: cyclic block transfers preserve mixed widths" {
    const graph: ir.Graph = .{
        .types = &.{ .v128, .i32, .v128, .v128, .i32, .v128, .i32, .i32, .v128, .v128 },
        .argument_types = &.{ .v128, .i32, .v128 },
        .result_types = &.{ .v128, .v128 },
        .blocks = &.{
            .{ .params = &.{ 0, 1, 2 }, .terminator = .{ .jump = .{ .target = 1, .args = &.{ 0, 1, 2 } } } },
            .{ .params = &.{ 3, 4, 5 }, .nodes = &.{
                .{ .op = .constant, .out = 6, .immediate = 1 },
                .{ .op = .sub, .out = 7, .lhs = 4, .rhs = 6 },
            }, .terminator = .{ .branch = .{ .condition = 7, .taken = .{ .target = 1, .args = &.{ 5, 7, 3 } }, .fallthrough = .{ .target = 2, .args = &.{ 3, 5 } } } } },
            .{ .params = &.{ 8, 9 }, .terminator = .{ .return_ = &.{ 8, 9 } } },
        },
    };
    try check(graph, &.{ 1, 2, 4, 3, 4 }, &.{ 3, 4, 1, 2 }, null);
}

test "backend vectors: calls separate logical types from physical words and preserve live vectors" {
    const Host = struct {
        fn invoke(_: ?*anyopaque, request: native.CallRequest) !void {
            try std.testing.expectEqualSlices(ir.Type, &.{ .v128, .i32, .v128 }, request.parameter_types);
            try std.testing.expectEqualSlices(ir.Type, &.{ .i32, .v128 }, request.result_types);
            try std.testing.expectEqualSlices(u64, &.{ 3, 4, 5, 1, 2 }, request.arguments);
            try std.testing.expectEqualSlices(u64, &.{ 1, 2, 5, 3, 4 }, request.captures);
            @memcpy(request.results, &[_]u64{ 0xffff_ffff_0000_0006, 7, 8 });
        }
    };
    const graph: ir.Graph = .{
        .types = &.{ .v128, .v128, .i32, .i32, .v128, .v128 },
        .argument_types = &.{ .v128, .v128, .i32 },
        .result_types = &.{ .v128, .i32, .v128, .v128 },
        .blocks = &.{.{ .params = &.{ 0, 1, 2 }, .nodes = &.{
            .{ .op = .call, .trap_site = 1, .call = .{ .target = 0, .arguments = &.{ 1, 2, 0 }, .parameter_types = &.{ .v128, .i32, .v128 }, .results = &.{ 3, 4 }, .result_types = &.{ .i32, .v128 }, .safepoint = .{ .id = 0, .values = &.{ 0, 2, 1 } } } },
            .{ .op = .vector_add, .out = 5, .lhs = 0, .rhs = 1, .vector_lane = .i64x2 },
        }, .terminator = .{ .return_ = &.{ 5, 3, 4, 0 } } }},
    };
    try check(graph, &.{ 1, 2, 3, 4, 5 }, &.{ 4, 6, 6, 7, 8, 1, 2 }, .{ .call = Host.invoke });
}

test "backend vectors: verifier enforces physical transfer bounds and scalar operations" {
    var nodes = [_]ir.Node{.{ .op = .vector_add, .out = 2, .lhs = 0, .rhs = 1, .vector_lane = .i32x4 }};
    var blocks = [_]ir.Block{.{ .params = &.{ 0, 1 }, .nodes = &nodes, .terminator = .{ .return_ = &.{2} } }};
    var graph: ir.Graph = .{ .types = &.{ .v128, .v128, .v128 }, .argument_types = &.{ .v128, .v128 }, .result_types = &.{.v128}, .blocks = &blocks };
    try graph.verify();
    nodes[0].vector_lane = null;
    try std.testing.expectError(error.InvalidGraph, graph.verify());
    nodes[0].op = .add;
    try std.testing.expectError(error.InvalidGraph, graph.verify());
    nodes[0] = .{ .op = .constant, .out = 2, .immediate_hi = 1 };
    graph.types = &.{ .v128, .v128, .i64 };
    graph.result_types = &.{.i64};
    try std.testing.expectError(error.InvalidGraph, graph.verify());
    nodes[0] = .{ .op = .bit_or, .out = 2, .lhs = 0, .rhs = 1 };
    graph.types = &.{ .v128, .v128, .v128 };
    graph.result_types = &@as([33]ir.Type, @splat(.v128));
    blocks[0].terminator = .{ .return_ = &@as([33]ir.Value, @splat(2)) };
    try std.testing.expectError(error.PrototypeLimit, graph.verify());
    graph.result_types = &.{};
    blocks[0].terminator = .{ .exit = .{ .id = 0, .values = &@as([33]ir.Value, @splat(2)) } };
    try std.testing.expectError(error.PrototypeLimit, graph.verify());
}

test "backend vectors: allocator detects partial overlap and separates register classes" {
    const graph: ir.Graph = .{ .types = &.{ .v128, .i64, .v128 }, .argument_types = &.{ .v128, .i64, .v128 }, .result_types = &.{ .v128, .i64, .v128 }, .blocks = &.{.{ .params = &.{ 0, 1, 2 }, .terminator = .{ .return_ = &.{ 0, 1, 2 } } }} };
    var scratch = try allocation.Plan.build(a, graph, .{ .mode = .scratch });
    defer scratch.deinit();
    try std.testing.expectEqual(@as(u32, 5), scratch.spill_slot_count);
    scratch.locations[1] = .{ .spill = 1 };
    try std.testing.expectError(error.InvalidAllocation, scratch.verify(graph));
    var registers = try allocation.Plan.build(a, graph, .{});
    defer registers.deinit();
    try std.testing.expect(registers.locations[0] == .vector_register);
    try std.testing.expect(registers.locations[1] == .register);
    registers.locations[0] = .{ .register = 0 };
    try std.testing.expectError(error.InvalidAllocation, registers.verify(graph));
}

test "backend vectors: full-width memory is unaligned bounded and ordered" {
    if (!native.supported) return error.SkipZigTest;
    const graph: ir.Graph = .{
        .types = &.{ .i64, .v128, .v128 },
        .argument_types = &.{ .i64, .v128 },
        .result_types = &.{.v128},
        .memory_count = 1,
        .blocks = &.{.{ .params = &.{ 0, 1 }, .nodes = &.{
            .{ .op = .store, .lhs = 0, .rhs = 1, .trap_site = 3, .memory = .{ .width = .quad } },
            .{ .op = .load, .out = 2, .lhs = 0, .trap_site = 4, .memory = .{ .width = .quad } },
        }, .terminator = .{ .return_ = &.{2} } }},
    };
    var owner = try CodeAllocator.init(a, 64 * 1024);
    defer owner.deinit();
    for ([_]allocation.Mode{ .scratch, .linear_scan }) |mode| {
        var code = try native.compileWithOptions(a, &owner, graph, .{ .allocation = mode });
        defer code.deinit();
        var bytes: [33]u8 = @splat(0xa5);
        var result: [2]u64 = undefined;
        var ok = try code.runInto(&.{ 17, 0x0123_4567_89ab_cdef, 0xfedc_ba98_7654_3210 }, &.{native.MemoryView.fromSlice(&bytes)}, 1, null, &result);
        defer ok.deinit();
        try std.testing.expect(ok == .returned);
        try std.testing.expectEqualSlices(u64, &.{ 0x0123_4567_89ab_cdef, 0xfedc_ba98_7654_3210 }, &result);
        try std.testing.expectEqual(@as(u8, 0xa5), bytes[16]);
        const previous = bytes;
        for ([_]u64{ 18, std.math.maxInt(u64) }) |address| {
            result = .{ 55, 66 };
            var failed = try code.runInto(&.{ address, 0, 0 }, &.{native.MemoryView.fromSlice(&bytes)}, 1, null, &result);
            defer failed.deinit();
            try std.testing.expectEqual(ir.Trap{ .reason = .memory_out_of_bounds, .site = 3 }, failed.trapped);
            try std.testing.expectEqualSlices(u8, &previous, &bytes);
            try std.testing.expectEqualSlices(u64, &.{ 55, 66 }, &result);
        }
    }
}

test "backend vectors: guards and terminal exits capture all words without publishing results" {
    if (!native.supported) return error.SkipZigTest;
    const graph: ir.Graph = .{ .types = &.{ .v128, .i32, .v128 }, .argument_types = &.{ .v128, .i32, .v128 }, .result_types = &.{.v128}, .blocks = &.{.{ .params = &.{ 0, 1, 2 }, .nodes = &.{
        .{ .op = .guard, .lhs = 1, .exit = .{ .id = 9, .values = &.{ 2, 1, 0 } } },
    }, .terminator = .{ .exit = .{ .id = 10, .values = &.{ 0, 1, 2 } } } }} };
    var owner = try CodeAllocator.init(a, 64 * 1024);
    defer owner.deinit();
    for ([_]u8{ 0, 1, 4 }) |registers| {
        var code = try native.compileWithOptions(a, &owner, graph, .{ .register_count = registers });
        defer code.deinit();
        for (0..2) |condition| {
            var result: [2]u64 = .{ 77, 88 };
            var completion = try code.runInto(&.{ 1, 2, condition, 3, 4 }, &.{}, 1, null, &result);
            defer completion.deinit();
            try std.testing.expectEqual(@as(u32, if (condition == 0) 9 else 10), completion.exited.id);
            try std.testing.expectEqualSlices(u64, if (condition == 0) &.{ 3, 4, 0, 1, 2 } else &.{ 1, 2, 1, 3, 4 }, completion.exited.values);
            try std.testing.expectEqualSlices(u64, &.{ 77, 88 }, &result);
        }
        try std.testing.expectError(error.ResultCount, code.run(&.{ 1, 2, 0, 3, 4 }, 1));
    }
}

test "backend vectors: nested native call clobbers every allocated vector register" {
    if (!native.supported) return error.SkipZigTest;
    const Host = struct {
        fn invoke(raw: ?*anyopaque, _: native.CallRequest) !void {
            const nested: *const native.Compiled = @ptrCast(@alignCast(raw.?));
            var result: [8]u64 = undefined;
            var completion = try nested.runInto(&.{ 10, 20, 30, 40, 50, 60, 70, 80 }, &.{}, 1, null, &result);
            defer completion.deinit();
            try std.testing.expect(completion == .returned);
        }
    };
    var graph: ir.Graph = .{ .types = &.{ .v128, .v128, .v128, .v128 }, .argument_types = &.{ .v128, .v128, .v128, .v128 }, .result_types = &.{ .v128, .v128, .v128, .v128 }, .blocks = &.{.{ .params = &.{ 0, 1, 2, 3 }, .terminator = .{ .return_ = &.{ 3, 2, 1, 0 } } }} };
    var owner = try CodeAllocator.init(a, 64 * 1024);
    defer owner.deinit();
    var nested = try native.compile(a, &owner, graph);
    defer nested.deinit();
    graph.blocks = &.{.{ .params = &.{ 0, 1, 2, 3 }, .nodes = &.{
        .{ .op = .call, .trap_site = 0, .call = .{ .target = 0, .arguments = &.{}, .parameter_types = &.{}, .results = &.{}, .result_types = &.{}, .safepoint = .{ .id = 0, .values = &.{} } } },
    }, .terminator = .{ .return_ = &.{ 3, 2, 1, 0 } } }};
    try check(graph, &.{ 1, 2, 3, 4, 5, 6, 7, 8 }, &.{ 7, 8, 5, 6, 3, 4, 1, 2 }, .{ .context = &nested, .call = Host.invoke });
}

test "backend vectors: maximum scratch reaches FP control memory and call metadata beyond 32 KiB" {
    if (!native.supported) return error.SkipZigTest;
    var types: [ir.max_values]ir.Type = @splat(.v128);
    types[ir.max_values - 2] = .i64;
    var nodes: [ir.max_values - 1]ir.Node = undefined;
    for (nodes[0 .. nodes.len - 2], 1..) |*node, i| node.* = .{ .op = .constant, .out = @intCast(i), .immediate = i, .immediate_hi = ~@as(u64, i) };
    nodes[nodes.len - 2] = .{ .op = .memory_length, .out = ir.max_values - 2 };
    nodes[nodes.len - 1] = .{ .op = .call, .trap_site = 0, .call = .{ .target = 0, .arguments = &.{ir.max_values - 3}, .parameter_types = &.{.v128}, .results = &.{ir.max_values - 1}, .result_types = &.{.v128}, .safepoint = .{ .id = 0, .values = &.{0} } } };
    const graph: ir.Graph = .{ .types = &types, .argument_types = &.{.v128}, .result_types = &.{ .v128, .i64, .v128 }, .memory_count = 1, .blocks = &.{.{ .params = &.{0}, .nodes = &nodes, .terminator = .{ .return_ = &.{ ir.max_values - 1, ir.max_values - 2, 0 } } }} };
    const Host = struct {
        fn invoke(_: ?*anyopaque, request: native.CallRequest) !void {
            @memcpy(request.results, request.arguments);
            try std.testing.expectEqualSlices(u64, &.{ 9, 10 }, request.captures);
        }
        fn poll(raw: ?*anyopaque) !void {
            const count: *usize = @ptrCast(@alignCast(raw.?));
            count.* += 1;
        }
    };
    var owner = try CodeAllocator.init(a, 1024 * 1024);
    defer owner.deinit();
    var code = try native.compileWithOptions(a, &owner, graph, .{ .execution_policy = .controlled, .allocation = .scratch, .optimization = .{ .constant_folding = false, .common_subexpression_elimination = false, .dead_code_elimination = false } });
    defer code.deinit();
    try std.testing.expect(code.scratchSlotCount() > 4096);
    var bytes: [13]u8 = undefined;
    var result: [5]u64 = undefined;
    var polls: usize = 0;
    var entries: u64 = 0;
    var completion = try code.runControlledInto(a, &.{ 9, 10 }, &.{native.MemoryView.fromSlice(&bytes)}, .{ .runtime = .{ .call = Host.invoke }, .control = .{ .context = &polls, .poll_fn = Host.poll }, .entry_counter = &entries }, &result);
    defer completion.deinit();
    try std.testing.expect(completion == .returned);
    try std.testing.expectEqualSlices(u64, &.{ ir.max_values - 3, ~@as(u64, ir.max_values - 3), 13, 9, 10 }, &result);
    try std.testing.expectEqual(@as(usize, 1), polls);
    try std.testing.expectEqual(@as(u64, 1), entries);
}

test "backend vectors: maximum physical arity keeps callback results and captures disjoint" {
    const Host = struct {
        fn invoke(_: ?*anyopaque, request: native.CallRequest) !void {
            try std.testing.expectEqual(@as(usize, 32), request.parameter_types.len);
            try std.testing.expectEqual(@as(usize, 32), request.result_types.len);
            try std.testing.expectEqual(@as(usize, 64), request.arguments.len);
            try std.testing.expectEqual(@as(usize, 64), request.captures.len);
            for (0..32) |i| {
                request.results[2 * i] = request.arguments[2 * (31 - i)];
                request.results[2 * i + 1] = request.arguments[2 * (31 - i) + 1];
            }
            try std.testing.expectEqualSlices(u64, request.arguments, request.captures);
        }
    };
    var params: [32]ir.Value = undefined;
    var outputs: [32]ir.Value = undefined;
    var args: [64]u64 = undefined;
    var expected: [64]u64 = undefined;
    for (0..32) |i| {
        params[i] = @intCast(i);
        outputs[i] = @intCast(i + 32);
        args[2 * i] = i;
        args[2 * i + 1] = ~@as(u64, i);
        expected[2 * (31 - i)] = i;
        expected[2 * (31 - i) + 1] = ~@as(u64, i);
    }
    const types: [32]ir.Type = @splat(.v128);
    const graph: ir.Graph = .{ .types = &@as([64]ir.Type, @splat(.v128)), .argument_types = &types, .result_types = &types, .blocks = &.{.{ .params = &params, .nodes = &.{
        .{ .op = .call, .trap_site = 0, .call = .{ .target = 0, .arguments = &params, .parameter_types = &types, .results = &outputs, .result_types = &types, .safepoint = .{ .id = 0, .values = &params } } },
    }, .terminator = .{ .return_ = &outputs } }} };
    try check(graph, &args, &expected, .{ .call = Host.invoke });
}

test "backend vectors: CSE distinguishes lane interpretations of identical operands" {
    const graph: ir.Graph = .{ .types = &.{ .v128, .v128, .v128, .v128 }, .argument_types = &.{ .v128, .v128 }, .result_types = &.{ .v128, .v128 }, .blocks = &.{.{ .params = &.{ 0, 1 }, .nodes = &.{
        .{ .op = .vector_add, .out = 2, .lhs = 0, .rhs = 1, .vector_lane = .i8x16 },
        .{ .op = .vector_add, .out = 3, .lhs = 0, .rhs = 1, .vector_lane = .i64x2 },
    }, .terminator = .{ .return_ = &.{ 2, 3 } } }} };
    try check(graph, &.{ 255, 255, 1, 1 }, &.{ 0, 0, 256, 256 }, null);
}

fn allocationFailures(allocator: std.mem.Allocator, owner: *CodeAllocator) !void {
    const graph: ir.Graph = .{ .types = &.{.v128}, .argument_types = &.{.v128}, .result_types = &.{.v128}, .blocks = &.{.{ .params = &.{0}, .terminator = .{ .exit = .{ .id = 3, .values = &.{0} } } }} };
    var code = try native.compile(allocator, owner, graph);
    defer code.deinit();
    var result: [2]u64 = .{ 9, 10 };
    var completion = try code.runInto(&.{ 7, 8 }, &.{}, 1, null, &result);
    defer completion.deinit();
    try std.testing.expectEqualSlices(u64, &.{ 7, 8 }, completion.exited.values);
    try std.testing.expectEqualSlices(u64, &.{ 9, 10 }, &result);
}

test "backend vectors: allocation failures release compilation invocation and exit storage" {
    if (!native.supported) return error.SkipZigTest;
    var owner = try CodeAllocator.init(a, 256 * 1024);
    defer owner.deinit();
    var no_resize = std.testing.FailingAllocator.init(a, .{ .resize_fail_index = 0 });
    try std.testing.checkAllAllocationFailures(no_resize.allocator(), allocationFailures, .{&owner});
}
