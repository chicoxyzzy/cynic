const std = @import("std");
const ir = @import("ir.zig");
const native = @import("native.zig");
const CodeAllocator = @import("../code_alloc.zig").CodeAllocator;
const a = std.testing.allocator;

test "backend results: mixed return lists preserve order duplicates and scalar bits" {
    if (!native.supported) return error.SkipZigTest;
    const graph: ir.Graph = .{
        .types = &.{ .i32, .i64, .f32, .f64 },
        .argument_types = &.{ .i32, .i64, .f32, .f64 },
        .result_types = &.{ .f64, .i64, .f32, .i32, .f64 },
        .blocks = &.{.{ .params = &.{ 0, 1, 2, 3 }, .terminator = .{ .return_ = &.{ 3, 1, 2, 0, 3 } } }},
    };
    var owner = try CodeAllocator.init(a, 64 * 1024);
    defer owner.deinit();
    const args = [_]u64{ 0xffff_ffff_8000_0000, 0xffff_ffff_ffff_ffff, 0xffc0_0042, 0xfff8_0000_0000_0042 };
    for ([_]u8{ 0, 1, 4 }) |registers| {
        var code = try native.compileWithOptions(a, &owner, graph, .{ .register_count = registers });
        defer code.deinit();
        var values: [5]u64 = undefined;
        var completion = try code.runInto(&args, &.{}, 1, null, &values);
        defer completion.deinit();
        try std.testing.expect(completion == .returned);
        try std.testing.expectEqualSlices(u64, &.{ args[3], args[1], args[2], 0x8000_0000, args[3] }, &values);
        try std.testing.expectError(error.ResultCount, code.run(&args, 1));
        try std.testing.expectError(error.ResultCount, code.runInto(&args, &.{}, 1, null, values[0..4]));
    }
}

const call_graph: ir.Graph = .{
    .types = &.{ .i32, .i64, .f32, .f64, .i32, .i64, .f32, .f64, .i64 },
    .argument_types = &.{ .i32, .i64, .f32, .f64 },
    .result_types = &.{ .f64, .i64, .f32, .i32, .i64, .i64 },
    .blocks = &.{.{ .params = &.{ 0, 1, 2, 3 }, .nodes = &.{
        .{ .op = .call, .trap_site = 9, .call = .{
            .target = 7,
            .arguments = &.{ 0, 1, 2, 3 },
            .parameter_types = &.{ .i32, .i64, .f32, .f64 },
            .results = &.{ 4, 5, 6, 7 },
            .result_types = &.{ .i32, .i64, .f32, .f64 },
            .safepoint = .{ .id = 3, .values = &.{ 1, 3 } },
        } },
        .{ .op = .add, .out = 8, .lhs = 1, .rhs = 5 },
    }, .terminator = .{ .return_ = &.{ 7, 5, 6, 4, 8, 1 } } }},
};
const Host = struct {
    fail: bool = false,
    calls: usize = 0,
    fn invoke(raw: ?*anyopaque, request: native.CallRequest) !void {
        const self: *Host = @ptrCast(@alignCast(raw.?));
        self.calls += 1;
        try std.testing.expectEqualSlices(ir.Type, &.{ .i32, .i64, .f32, .f64 }, request.result_types);
        for (request.results, request.arguments) |*out, value| out.* = value;
        request.results[0] |= 0xffff_ffff_0000_0000;
        request.results[2] |= 0xffff_ffff_0000_0000;
        // Result writes must not alias borrowed inputs or snapshots.
        try std.testing.expectEqual(@as(u64, 0x8000_0000), request.arguments[0]);
        try std.testing.expectEqualSlices(u64, &.{ 13, 0xfff8_0000_0000_0042 }, request.captures);
        if (self.fail) return error.HostThrew;
    }
};

test "backend results: call outputs and live values survive every allocation mode" {
    if (!native.supported) return error.SkipZigTest;
    var owner = try CodeAllocator.init(a, 256 * 1024);
    defer owner.deinit();
    for ([_]@import("allocation.zig").Mode{ .scratch, .linear_scan }) |mode| for ([_]u8{ 0, 1, 4 }) |registers| for (0..16) |flags| {
        var code = try native.compileWithOptions(a, &owner, call_graph, .{ .allocation = mode, .register_count = registers, .rematerialize_constants = flags & 8 != 0, .optimization = .{ .constant_folding = flags & 1 != 0, .common_subexpression_elimination = flags & 2 != 0, .dead_code_elimination = flags & 4 != 0 } });
        defer code.deinit();
        var host: Host = .{};
        var values: [6]u64 = @splat(99);
        const runtime: native.Runtime = .{ .context = &host, .call = Host.invoke };
        const args = [_]u64{ 0x8000_0000, 13, 0xffc0_0042, 0xfff8_0000_0000_0042 };
        try std.testing.expectError(error.ResultCount, code.runInto(&args, &.{}, 1, runtime, values[0..5]));
        try std.testing.expectEqual(@as(usize, 0), host.calls);
        var result = try code.runInto(&args, &.{}, 1, runtime, &values);
        defer result.deinit();
        try std.testing.expect(result == .returned);
        try std.testing.expectEqualSlices(u64, &.{ args[3], 13, args[2], args[0], 26, 13 }, &values);
        host.fail = true;
        @memset(&values, 99);
        try std.testing.expectError(error.HostThrew, code.runInto(&args, &.{}, 1, runtime, &values));
        try std.testing.expectEqualSlices(u64, &.{ 99, 99, 99, 99, 99, 99 }, &values);
    };
}

test "backend results: void functions preserve calls and require an empty result buffer" {
    if (!native.supported) return error.SkipZigTest;
    const VoidHost = struct {
        fn invoke(raw: ?*anyopaque, request: native.CallRequest) !void {
            const calls: *usize = @ptrCast(@alignCast(raw.?));
            calls.* += 1;
            try std.testing.expectEqual(@as(usize, 0), request.results.len);
        }
    };
    const graph: ir.Graph = .{ .types = &.{}, .argument_types = &.{}, .result_types = &.{}, .blocks = &.{.{ .params = &.{}, .nodes = &.{
        .{ .op = .call, .trap_site = 0, .call = .{ .target = 0, .arguments = &.{}, .parameter_types = &.{}, .results = &.{}, .result_types = &.{}, .safepoint = .{ .id = 0, .values = &.{} } } },
    }, .terminator = .{ .return_ = &.{} } }} };
    var owner = try CodeAllocator.init(a, 64 * 1024);
    defer owner.deinit();
    var code = try native.compile(a, &owner, graph);
    defer code.deinit();
    var calls: usize = 0;
    try std.testing.expectError(error.ResultCount, code.runOutcomeWithRuntime(&.{}, &.{}, 1, .{ .context = &calls, .call = VoidHost.invoke }));
    var result = try code.runInto(&.{}, &.{}, 1, .{ .context = &calls, .call = VoidHost.invoke }, &.{});
    defer result.deinit();
    try std.testing.expect(result == .returned);
    try std.testing.expectEqual(@as(usize, 1), calls);
}

test "backend results: verifier rejects result arity types duplicate definitions and premature capture" {
    var graph = call_graph;
    var nodes = graph.blocks[0].nodes[0..2].*;
    var block = graph.blocks[0];
    block.nodes = &nodes;
    graph.blocks = @as(*const [1]ir.Block, &block);
    nodes[0].call.?.results = &.{ 4, 5, 6, 6 };
    try std.testing.expectError(error.InvalidGraph, graph.verify());
    nodes[0] = call_graph.blocks[0].nodes[0];
    nodes[0].out = 4;
    try std.testing.expectError(error.InvalidGraph, graph.verify());
    nodes[0] = call_graph.blocks[0].nodes[0];
    nodes[0].call.?.result_types = &.{.i32};
    try std.testing.expectError(error.InvalidGraph, graph.verify());
    nodes[0] = call_graph.blocks[0].nodes[0];
    nodes[0].call.?.safepoint.values = &.{4};
    try std.testing.expectError(error.InvalidGraph, graph.verify());
    nodes[0] = call_graph.blocks[0].nodes[0];
    graph.result_types = &.{.i32};
    try std.testing.expectError(error.InvalidGraph, graph.verify());
    graph.result_types = &.{ .f64, .i64, .f32, .f64, .i64, .i64 };
    try std.testing.expectError(error.InvalidGraph, graph.verify());
}

test "backend results: maximum arity keeps callback buffers and snapshots disjoint" {
    if (!native.supported) return error.SkipZigTest;
    const FullHost = struct {
        fn invoke(_: ?*anyopaque, request: native.CallRequest) !void {
            for (request.results, 0..) |*out, i| out.* = request.arguments[63 - i];
            try std.testing.expectEqualSlices(u64, request.captures, request.arguments);
        }
    };
    var types: [128]ir.Type = undefined;
    var params: [64]ir.Value = undefined;
    var outputs: [64]ir.Value = undefined;
    var returns: [64]ir.Value = undefined;
    var values: [64]u64 = undefined;
    for (0..64) |i| {
        types[i] = ([_]ir.Type{ .i32, .i64, .f32, .f64 })[i % 4];
        params[i] = @intCast(i);
        outputs[i] = @intCast(64 + i);
        returns[i] = @intCast(127 - i);
        values[i] = ir.normalize(types[i], 0xfff8_0000_0000_0000 + i);
    }
    for (0..64) |i| types[64 + i] = types[63 - i];
    const expected = values;
    const graph: ir.Graph = .{ .types = &types, .argument_types = types[0..64], .result_types = types[0..64], .blocks = &.{.{ .params = &params, .nodes = &.{
        .{ .op = .call, .trap_site = 1, .call = .{ .target = 0, .arguments = &params, .parameter_types = types[0..64], .results = &outputs, .result_types = types[64..], .safepoint = .{ .id = 99, .values = &params } } },
    }, .terminator = .{ .return_ = &returns } }} };
    var owner = try CodeAllocator.init(a, 256 * 1024);
    defer owner.deinit();
    for ([_]u8{ 0, 1, 4 }) |registers| {
        var code = try native.compileWithOptions(a, &owner, graph, .{ .register_count = registers });
        defer code.deinit();
        // Caller results may alias caller inputs, unlike the callback buffers.
        var result = try code.runInto(&values, &.{}, 1, .{ .call = FullHost.invoke }, &values);
        defer result.deinit();
        try std.testing.expect(result == .returned);
        try std.testing.expectEqualSlices(u64, &expected, &values);
    }
    var invalid = graph;
    invalid.result_types = &@as([65]ir.Type, @splat(.i64));
    try std.testing.expectError(error.PrototypeLimit, invalid.verify());
}

test "backend results: traps side exits and exhaustion do not publish partial results" {
    if (!native.supported) return error.SkipZigTest;
    const graph: ir.Graph = .{ .types = &.{ .i32, .i64, .i64 }, .argument_types = &.{ .i32, .i64, .i64 }, .result_types = &.{ .i64, .i64 }, .blocks = &.{.{ .params = &.{ 0, 1, 2 }, .nodes = &.{
        .{ .op = .guard, .lhs = 0, .exit = .{ .id = 7, .values = &.{ 1, 2 } } },
    }, .terminator = .{ .trap = .{ .reason = .unreachable_code, .site = 42 } } }} };
    var owner = try CodeAllocator.init(a, 64 * 1024);
    defer owner.deinit();
    var code = try native.compile(a, &owner, graph);
    defer code.deinit();
    var values = [_]u64{ 99, 99 };
    var exit = try code.runInto(&.{ 0, 11, 13 }, &.{}, 1, null, &values);
    defer exit.deinit();
    try std.testing.expectEqual(@as(u32, 7), exit.exited.id);
    try std.testing.expectEqualSlices(u64, &.{ 11, 13 }, exit.exited.values);
    var trap = try code.runInto(&.{ 1, 11, 13 }, &.{}, 1, null, &values);
    defer trap.deinit();
    try std.testing.expectEqual(@as(u32, 42), trap.trapped.site);
    try std.testing.expectError(error.BudgetExhausted, code.runInto(&.{ 1, 11, 13 }, &.{}, 0, null, &values));
    try std.testing.expectEqualSlices(u64, &.{ 99, 99 }, &values);
}

fn allocationFailures(allocator: std.mem.Allocator, owner: *CodeAllocator) !void {
    var code = try native.compile(allocator, owner, call_graph);
    defer code.deinit();
    var host: Host = .{};
    var values: [6]u64 = undefined;
    var result = try code.runInto(&.{ 0x8000_0000, 13, 0xffc0_0042, 0xfff8_0000_0000_0042 }, &.{}, 1, .{ .context = &host, .call = Host.invoke }, &values);
    defer result.deinit();
    try std.testing.expect(result == .returned);
    try std.testing.expectEqual(@as(u64, 26), values[4]);
}

test "backend results: allocation failures release result types lists and scratch" {
    if (!native.supported) return error.SkipZigTest;
    var owner = try CodeAllocator.init(a, 256 * 1024);
    defer owner.deinit();
    try std.testing.checkAllAllocationFailures(a, allocationFailures, .{&owner});
}

test "backend results: discarded call results do not eliminate the call" {
    if (!native.supported) return error.SkipZigTest;
    var graph = call_graph;
    var block = graph.blocks[0];
    block.nodes = block.nodes[0..1];
    block.terminator = .{ .return_ = &.{} };
    graph.blocks = @as(*const [1]ir.Block, &block);
    graph.types = graph.types[0..8];
    graph.result_types = &.{};
    var owner = try CodeAllocator.init(a, 64 * 1024);
    defer owner.deinit();
    var code = try native.compile(a, &owner, graph);
    defer code.deinit();
    var host: Host = .{};
    var result = try code.runInto(&.{ 0x8000_0000, 13, 0xffc0_0042, 0xfff8_0000_0000_0042 }, &.{}, 1, .{ .context = &host, .call = Host.invoke }, &.{});
    defer result.deinit();
    try std.testing.expect(result == .returned);
    try std.testing.expectEqual(@as(usize, 1), host.calls);
}

test "backend results: optimized graph owns result signatures definitions and return lists" {
    if (!native.supported) return error.SkipZigTest;
    const Echo = struct {
        fn invoke(_: ?*anyopaque, request: native.CallRequest) !void {
            request.results[0] = request.arguments[0] + 7;
        }
    };
    var types = [_]ir.Type{.i64};
    var call_types = types;
    var outputs = [_]ir.Value{1};
    var returns = outputs;
    const graph: ir.Graph = .{ .types = &.{ .i64, .i64 }, .argument_types = &.{.i64}, .result_types = &types, .blocks = &.{.{ .params = &.{0}, .nodes = &.{
        .{ .op = .call, .trap_site = 0, .call = .{ .target = 0, .arguments = &.{0}, .parameter_types = &.{.i64}, .results = &outputs, .result_types = &call_types, .safepoint = .{ .id = 0, .values = &.{} } } },
    }, .terminator = .{ .return_ = &returns } }} };
    var optimized = try @import("optimize.zig").run(a, graph, .{});
    defer optimized.deinit();
    types[0] = .f64;
    call_types[0] = .i32;
    outputs[0] = 0;
    returns[0] = 0;
    var owner = try CodeAllocator.init(a, 64 * 1024);
    defer owner.deinit();
    var code = try native.compile(a, &owner, optimized.graph);
    defer code.deinit();
    var result = try code.runOutcomeWithRuntime(&.{3}, &.{}, 1, .{ .call = Echo.invoke });
    defer result.deinit();
    try std.testing.expectEqual(@as(u64, 10), result.returned);
}
