const std = @import("std");
const ir = @import("ir.zig");
const native = @import("native.zig");
const allocation = @import("allocation.zig");
const CodeAllocator = @import("../code_alloc.zig").CodeAllocator;
const a = std.testing.allocator;

const graph: ir.Graph = .{
    .types = &.{ .i64, .i64, .i64, .i64, .i64, .i64, .i64, .i64, .i64 },
    .argument_types = &.{ .i64, .i64, .i64, .i64 },
    .result_type = .i64,
    .blocks = &.{.{ .params = &.{ 0, 1, 2, 3 }, .nodes = &.{
        .{ .op = .call, .out = 4, .trap_site = 17, .call = .{
            .target = 42,
            .arguments = &.{ 3, 1, 3 },
            .parameter_types = &.{ .i64, .i64, .i64 },
            .result_type = .i64,
            .safepoint = .{ .id = 99, .values = &.{ 2, 0, 2 } },
        } },
        .{ .op = .add, .out = 5, .lhs = 0, .rhs = 1 },
        .{ .op = .add, .out = 6, .lhs = 2, .rhs = 3 },
        .{ .op = .add, .out = 7, .lhs = 5, .rhs = 6 },
        .{ .op = .add, .out = 8, .lhs = 7, .rhs = 4 },
    }, .terminator = .{ .return_ = 8 } }},
};

const Context = struct {
    calls: usize = 0,
    fail: bool = false,
    nested: ?*const native.Compiled = null,

    fn invoke(raw: ?*anyopaque, request: native.CallRequest) !u64 {
        const self: *Context = @ptrCast(@alignCast(raw.?));
        self.calls += 1;
        try std.testing.expectEqual(@as(u32, 42), request.target);
        try std.testing.expectEqual(@as(u32, 17), request.site);
        try std.testing.expectEqual(@as(u32, 99), request.safepoint);
        try std.testing.expectEqualSlices(u64, &.{ 40, 20, 40 }, request.arguments);
        try std.testing.expectEqualSlices(u64, &.{ 30, 10, 30 }, request.captures);
        if (self.fail) return error.CallbackFailed;
        if (self.nested) |code| return code.run(&.{7}, 1);
        return request.arguments[0] + request.arguments[1];
    }
};

test "backend calls: live registers captures and argument permutations survive native calls" {
    if (!native.supported) return error.SkipZigTest;
    var owner = try CodeAllocator.init(a, 256 * 1024);
    defer owner.deinit();
    for ([_]allocation.Mode{ .linear_scan, .scratch }) |mode| for ([_]u8{ 0, 1, 4 }) |registers| for (0..16) |flags| {
        var code = try native.compileWithOptions(a, &owner, graph, .{ .allocation = mode, .register_count = registers, .rematerialize_constants = flags & 8 != 0, .optimization = .{ .constant_folding = flags & 1 != 0, .common_subexpression_elimination = flags & 2 != 0, .dead_code_elimination = flags & 4 != 0 } });
        defer code.deinit();
        var context: Context = .{};
        var result = try code.runOutcomeWithRuntime(&.{ 10, 20, 30, 40 }, &.{}, 1, .{ .context = &context, .call = Context.invoke });
        defer result.deinit();
        try std.testing.expectEqual(@as(u64, 160), result.returned);
        try std.testing.expectEqual(@as(usize, 1), context.calls);
        try std.testing.expectError(error.MissingRuntime, code.run(&.{ 10, 20, 30, 40 }, 1));
        context.fail = true;
        try std.testing.expectError(error.CallbackFailed, code.runOutcomeWithRuntime(&.{ 10, 20, 30, 40 }, &.{}, 1, .{ .context = &context, .call = Context.invoke }));
    };
}

test "backend calls: nested native entry has independent scratch and budget" {
    if (!native.supported) return error.SkipZigTest;
    var owner = try CodeAllocator.init(a, 256 * 1024);
    defer owner.deinit();
    const inner: ir.Graph = .{ .types = &.{.i64}, .argument_types = &.{.i64}, .result_type = .i64, .blocks = &.{.{ .params = &.{0}, .terminator = .{ .return_ = 0 } }} };
    var nested = try native.compile(a, &owner, inner);
    defer nested.deinit();
    var outer = try native.compile(a, &owner, graph);
    defer outer.deinit();
    var context: Context = .{ .nested = &nested };
    var result = try outer.runOutcomeWithRuntime(&.{ 10, 20, 30, 40 }, &.{}, 1, .{ .context = &context, .call = Context.invoke });
    defer result.deinit();
    try std.testing.expectEqual(@as(u64, 107), result.returned);
    try std.testing.expectError(error.BudgetExhausted, outer.runOutcomeWithRuntime(&.{ 10, 20, 30, 40 }, &.{}, 0, .{ .context = &context, .call = Context.invoke }));
    try std.testing.expectEqual(@as(usize, 1), context.calls);
}

test "backend calls: verifier checks signatures captures and ordered effects" {
    try graph.verify();
    const effects = ir.effects(.call);
    try std.testing.expect(effects.reads_memory and effects.writes_memory and effects.may_trap and effects.safepoint);
    var nodes = graph.blocks[0].nodes[0..1].*;
    var blocks = graph.blocks[0..1].*;
    blocks[0].nodes = &nodes;
    blocks[0].terminator = .{ .return_ = 4 };
    var invalid = graph;
    invalid.types = graph.types[0..5];
    invalid.blocks = &blocks;
    try invalid.verify();
    const original = nodes[0];
    nodes[0].call.?.parameter_types = &.{ .i32, .i64, .i64 };
    try std.testing.expectError(error.InvalidGraph, invalid.verify());
    nodes[0] = original;
    nodes[0].call.?.safepoint.values = &.{4};
    try std.testing.expectError(error.InvalidGraph, invalid.verify());
    nodes[0] = original;
    nodes[0].call.?.result_type = null;
    try std.testing.expectError(error.InvalidGraph, invalid.verify());
    nodes[0] = original;
    nodes[0].call = null;
    try std.testing.expectError(error.InvalidGraph, invalid.verify());
    nodes[0] = original;
    nodes[0].trap_site = null;
    try std.testing.expectError(error.InvalidGraph, invalid.verify());
    nodes[0] = original;
    nodes[0].call.?.parameter_types = &.{};
    try std.testing.expectError(error.InvalidGraph, invalid.verify());
    nodes[0] = original;
    nodes[0].call.?.safepoint.values = &@as([ir.max_arguments + 1]ir.Value, @splat(0));
    try std.testing.expectError(error.PrototypeLimit, invalid.verify());
    nodes[0] = original;
    nodes[0].out = null;
    try std.testing.expectError(error.InvalidGraph, invalid.verify());
}

fn allocationFailures(allocator: std.mem.Allocator, owner: *CodeAllocator) !void {
    var code = try native.compile(allocator, owner, graph);
    defer code.deinit();
    var context: Context = .{};
    var result = try code.runOutcomeWithRuntime(&.{ 10, 20, 30, 40 }, &.{}, 1, .{ .context = &context, .call = Context.invoke });
    defer result.deinit();
    try std.testing.expectEqual(@as(u64, 160), result.returned);
}

test "backend calls: allocation failures release metadata and invocation scratch" {
    if (!native.supported) return error.SkipZigTest;
    var owner = try CodeAllocator.init(a, 256 * 1024);
    defer owner.deinit();
    try std.testing.checkAllAllocationFailures(a, allocationFailures, .{&owner});
}

test "backend calls: void effects refresh memory and errors prevent subsequent stores" {
    if (!native.supported) return error.SkipZigTest;
    const Host = struct {
        bytes: [8]u8 = @splat(0),
        fail: bool = false,
        calls: usize = 0,
        fn invoke(raw: ?*anyopaque, request: native.CallRequest) !u64 {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            self.calls += 1;
            request.memories[0] = native.MemoryView.fromSlice(&self.bytes);
            if (self.fail) return error.HostThrew;
            return 0;
        }
    };
    const memory_graph: ir.Graph = .{ .types = &.{ .i32, .i64, .i64 }, .argument_types = &.{ .i32, .i64 }, .result_type = .i64, .memory_count = 1, .blocks = &.{.{ .params = &.{ 0, 1 }, .nodes = &.{
        .{ .op = .call, .trap_site = 1, .call = .{ .target = 0, .arguments = &.{}, .parameter_types = &.{}, .result_type = null, .safepoint = .{ .id = 0, .values = &.{} } } },
        .{ .op = .store, .lhs = 0, .rhs = 1, .memory = .{ .width = .double }, .trap_site = 2 },
        .{ .op = .load, .out = 2, .lhs = 0, .memory = .{ .width = .double }, .trap_site = 3 },
    }, .terminator = .{ .return_ = 2 } }} };
    var owner = try CodeAllocator.init(a, 256 * 1024);
    defer owner.deinit();
    var code = try native.compile(a, &owner, memory_graph);
    defer code.deinit();
    var empty: [0]u8 = .{};
    const views = [_]native.MemoryView{native.MemoryView.fromSlice(&empty)};
    var host: Host = .{};
    var result = try code.runOutcomeWithRuntime(&.{ 0, 0x1234 }, &views, 1, .{ .context = &host, .call = Host.invoke });
    defer result.deinit();
    try std.testing.expectEqual(@as(u64, 0x1234), result.returned);
    try std.testing.expectEqual(@as(u64, 0x1234), std.mem.readInt(u64, &host.bytes, .little));
    host.bytes = @splat(0);
    host.fail = true;
    try std.testing.expectError(error.HostThrew, code.runOutcomeWithRuntime(&.{ 0, 0x1234 }, &views, 1, .{ .context = &host, .call = Host.invoke }));
    try std.testing.expectEqual(@as(u64, 0), std.mem.readInt(u64, &host.bytes, .little));
    try std.testing.expectEqual(@as(usize, 2), host.calls);
}

test "backend calls: callback scalar results preserve raw bits and narrow upper lanes" {
    if (!native.supported) return error.SkipZigTest;
    const Host = struct {
        fn invoke(_: ?*anyopaque, request: native.CallRequest) !u64 {
            return request.arguments[0] | 0xffff_ffff_0000_0000;
        }
    };
    var owner = try CodeAllocator.init(a, 256 * 1024);
    defer owner.deinit();
    for ([_]ir.Type{ .i32, .i64, .f32, .f64 }) |ty| {
        const call_graph: ir.Graph = .{ .types = &.{ ty, ty }, .argument_types = &.{ty}, .result_type = ty, .blocks = &.{.{ .params = &.{0}, .nodes = &.{
            .{ .op = .call, .out = 1, .trap_site = 0, .call = .{ .target = 0, .arguments = &.{0}, .parameter_types = &.{ty}, .result_type = ty, .safepoint = .{ .id = 0, .values = &.{} } } },
        }, .terminator = .{ .return_ = 1 } }} };
        var code = try native.compile(a, &owner, call_graph);
        defer code.deinit();
        for ([_]u64{ 0, 0x8000_0000, 0x7f80_0001, 0x7ff0_0000_0000_0001 }) |bits| {
            var result = try code.runOutcomeWithRuntime(&.{bits}, &.{}, 1, .{ .call = Host.invoke });
            defer result.deinit();
            try std.testing.expectEqual(ir.normalize(ty, bits | 0xffff_ffff_0000_0000), result.returned);
        }
    }
}

test "backend calls: recursive host re-entry returns stack exhaustion without aborting" {
    if (!native.supported) return error.SkipZigTest;
    const Host = struct {
        code: *const native.Compiled,
        calls: usize = 0,
        fn invoke(raw: ?*anyopaque, _: native.CallRequest) anyerror!u64 {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            self.calls += 1;
            var result = try self.code.runOutcomeWithRuntime(&.{}, &.{}, 1, .{ .context = self, .call = invoke });
            defer result.deinit();
            return result.returned;
        }
    };
    const recursive: ir.Graph = .{ .types = &.{.i64}, .argument_types = &.{}, .result_type = .i64, .blocks = &.{.{ .params = &.{}, .nodes = &.{
        .{ .op = .call, .out = 0, .trap_site = 0, .call = .{ .target = 0, .arguments = &.{}, .parameter_types = &.{}, .result_type = .i64, .safepoint = .{ .id = 0, .values = &.{} } } },
    }, .terminator = .{ .return_ = 0 } }} };
    var owner = try CodeAllocator.init(a, 256 * 1024);
    defer owner.deinit();
    var code = try native.compile(a, &owner, recursive);
    defer code.deinit();
    var host: Host = .{ .code = &code };
    try std.testing.expectError(error.CallStackExhausted, code.runOutcomeWithRuntime(&.{}, &.{}, 1, .{ .context = &host, .call = Host.invoke }));
    try std.testing.expect(host.calls > 1);
}

test "backend calls: repeated native continuations retain the caller block budget" {
    if (!native.supported) return error.SkipZigTest;
    const Host = struct {
        calls: usize = 0,
        fn invoke(raw: ?*anyopaque, request: native.CallRequest) !u64 {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            self.calls += 1;
            return request.arguments[0] - 1;
        }
    };
    const loop: ir.Graph = .{ .types = &.{ .i32, .i32, .i32, .i32 }, .argument_types = &.{.i32}, .result_type = .i32, .blocks = &.{
        .{ .params = &.{0}, .terminator = .{ .jump = .{ .target = 1, .args = &.{0} } } },
        .{ .params = &.{1}, .nodes = &.{.{ .op = .call, .out = 2, .trap_site = 0, .call = .{ .target = 0, .arguments = &.{1}, .parameter_types = &.{.i32}, .result_type = .i32, .safepoint = .{ .id = 0, .values = &.{} } } }}, .terminator = .{ .branch = .{ .condition = 2, .taken = .{ .target = 1, .args = &.{2} }, .fallthrough = .{ .target = 2, .args = &.{2} } } } },
        .{ .params = &.{3}, .terminator = .{ .return_ = 3 } },
    } };
    var owner = try CodeAllocator.init(a, 256 * 1024);
    defer owner.deinit();
    for ([_]u8{ 0, 1, 4 }) |registers| {
        var code = try native.compileWithOptions(a, &owner, loop, .{ .register_count = registers });
        defer code.deinit();
        for (0..6) |budget| {
            var host: Host = .{};
            const result = code.runOutcomeWithRuntime(&.{3}, &.{}, @intCast(budget), .{ .context = &host, .call = Host.invoke });
            if (budget < 5) {
                try std.testing.expectError(error.BudgetExhausted, result);
            } else {
                var outcome = try result;
                defer outcome.deinit();
                try std.testing.expectEqual(@as(u64, 0), outcome.returned);
            }
            try std.testing.expectEqual(@min(3, budget -| 1), host.calls);
        }
    }
}
