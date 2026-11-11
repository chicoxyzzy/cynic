const std = @import("std");
const ir = @import("ir.zig");
const native = @import("native.zig");
const allocation = @import("allocation.zig");
const CodeAllocator = @import("../code_alloc.zig").CodeAllocator;
const a = std.testing.allocator;

const inputs = [_]u64{ 10, 20, 30, 40, 50, 51, 60, 61, 70, 71, 80, 81 };
const graph: ir.Graph = .{
    .types = &.{
        .i64,  .i64,  .i64,  .i64,  .v128, .v128, .v128, .v128,
        .i64,  .v128, .i64,  .i64,  .i64,  .i64,  .v128, .v128,
        .v128, .v128, .i64,  .v128, .i64,  .i64,  .i64,  .i64,
        .v128, .v128, .v128, .v128, .i64,  .v128, .i64,  .i64,
        .i64,  .i64,
    },
    .argument_types = &.{ .i64, .i64, .i64, .i64, .v128, .v128, .v128, .v128 },
    .result_types = &.{ .i64, .i64, .i64, .i64, .v128, .v128, .v128, .v128, .i64, .v128 },
    .blocks = &.{
        .{ .params = &.{ 0, 1, 2, 3, 4, 5, 6, 7 }, .nodes = &.{
            .{ .op = .constant, .out = 30, .immediate = 17 },
            .{ .op = .constant, .out = 31, .immediate = 17 },
            .{ .op = .add, .out = 32, .lhs = 0, .rhs = 31 },
            .{ .op = .constant, .out = 33, .immediate = 777 },
        }, .terminator = .{ .invoke = .{
            .site = 17,
            .call = .{
                .target = 123,
                .arguments = &.{ 32, 4 },
                .parameter_types = &.{ .i64, .v128 },
                .results = &.{ 8, 9 },
                .result_types = &.{ .i64, .v128 },
                .safepoint = .{ .id = 99, .values = &.{ 0, 4, 1, 5, 2, 6, 3, 7 } },
            },
            .normal = .{ .target = 1, .args = &.{ 32, 1, 2, 3, 4, 5, 6, 7, 8, 9 } },
            .exceptional = .{ .target = 2, .args = &.{ 32, 1, 2, 3, 4, 5, 6, 7 } },
        } } },
        .{ .params = &.{ 10, 11, 12, 13, 14, 15, 16, 17, 18, 19 }, .terminator = .{ .return_ = &.{ 10, 11, 12, 13, 14, 15, 16, 17, 18, 19 } } },
        .{ .params = &.{ 20, 21, 22, 23, 24, 25, 26, 27 }, .nodes = &.{
            .{ .op = .constant, .out = 28, .immediate = 99 },
            .{ .op = .constant, .out = 29, .immediate = 100, .immediate_hi = 101 },
        }, .terminator = .{ .return_ = &.{ 20, 21, 22, 23, 24, 25, 26, 27, 28, 29 } } },
    },
};

const Context = struct {
    failure: ?anyerror = null,
    classifier_failure: bool = false,
    calls: usize = 0,
    classifications: usize = 0,

    fn invoke(raw: ?*anyopaque, request: native.CallRequest) !void {
        const self: *@This() = @ptrCast(@alignCast(raw.?));
        self.calls += 1;
        try std.testing.expectEqual(@as(u64, 123), request.target);
        try std.testing.expectEqual(@as(u32, 17), request.site);
        try std.testing.expectEqual(@as(u32, 99), request.safepoint);
        try std.testing.expectEqualSlices(u64, &.{ 27, 50, 51 }, request.arguments);
        try std.testing.expectEqualSlices(u64, &.{ 10, 50, 51, 20, 60, 61, 30, 70, 71, 40, 80, 81 }, request.captures);
        @memcpy(request.results, &[_]u64{ 55, 66, 77 });
        if (self.failure) |err| return err;
    }

    fn catchException(raw: ?*anyopaque, request: native.CallRequest, err: anyerror) !bool {
        const self: *@This() = @ptrCast(@alignCast(raw.?));
        self.classifications += 1;
        try std.testing.expectEqual(@as(u32, 17), request.site);
        try std.testing.expectEqualSlices(u64, &.{ 10, 50, 51, 20, 60, 61, 30, 70, 71, 40, 80, 81 }, request.captures);
        if (self.classifier_failure) return error.ClassifierFailed;
        return err == error.LanguageException;
    }

    fn runtime(self: *@This()) native.Runtime {
        return .{ .context = self, .call = invoke, .catch_exception = catchException };
    }
};

test "backend invoke: normal and exceptional edges preserve live homes under all optimizations" {
    if (!native.supported) return error.SkipZigTest;
    var owner = try CodeAllocator.init(a, 512 * 1024);
    defer owner.deinit();
    for ([_]allocation.Mode{ .linear_scan, .scratch }) |mode| for ([_]u8{ 0, 1, 4 }) |registers| for (0..16) |flags| {
        var code = try native.compileWithOptions(a, &owner, graph, .{ .allocation = mode, .register_count = registers, .rematerialize_constants = flags & 8 != 0, .optimization = .{ .constant_folding = flags & 1 != 0, .common_subexpression_elimination = flags & 2 != 0, .dead_code_elimination = flags & 4 != 0 } });
        defer code.deinit();
        for ([_]bool{ false, true }) |throws| {
            var context: Context = .{ .failure = if (throws) error.LanguageException else null };
            var values: [15]u64 = @splat(0xdead);
            var result = try code.runInto(&inputs, &.{}, 2, context.runtime(), &values);
            defer result.deinit();
            try std.testing.expect(result == .returned);
            var expected: [15]u64 = undefined;
            @memcpy(expected[0..12], &inputs);
            expected[0] = 27;
            @memcpy(expected[12..], if (throws) &[_]u64{ 99, 100, 101 } else &[_]u64{ 55, 66, 77 });
            try std.testing.expectEqualSlices(u64, &expected, &values);
            try std.testing.expectEqual(@as(usize, 1), context.calls);
            try std.testing.expectEqual(@as(usize, @intFromBool(throws)), context.classifications);
        }
    };
}

test "backend invoke: uncatchable errors classifier errors and absent classifiers propagate once" {
    if (!native.supported) return error.SkipZigTest;
    var owner = try CodeAllocator.init(a, 256 * 1024);
    defer owner.deinit();
    var code = try native.compile(a, &owner, graph);
    defer code.deinit();
    var values: [15]u64 = @splat(0xdead);
    for ([_]anyerror{ error.OutOfMemory, error.ExecutionTerminated, error.IntegerDivideByZero }) |failure| {
        var context: Context = .{ .failure = failure };
        try std.testing.expectError(failure, code.runInto(&inputs, &.{}, 2, context.runtime(), &values));
        try std.testing.expectEqual(@as(usize, 1), context.calls);
        try std.testing.expectEqual(@as(usize, 1), context.classifications);
        try std.testing.expectEqualSlices(u64, &@as([15]u64, @splat(0xdead)), &values);
    }
    var context: Context = .{ .failure = error.LanguageException, .classifier_failure = true };
    try std.testing.expectError(error.ClassifierFailed, code.runInto(&inputs, &.{}, 2, context.runtime(), &values));
    context = .{ .failure = error.LanguageException };
    try std.testing.expectError(error.LanguageException, code.runInto(&inputs, &.{}, 2, .{ .context = &context, .call = Context.invoke }, &values));
    try std.testing.expectEqual(@as(usize, 1), context.calls);
    try std.testing.expectEqual(@as(usize, 0), context.classifications);
}

test "backend invoke: verifier separates result availability and validates both successors" {
    try graph.verify();
    var blocks = graph.blocks[0..3].*;
    var invalid = graph;
    invalid.blocks = &blocks;
    const original = blocks[0].terminator;
    blocks[0].terminator.invoke.exceptional.args = &.{ 8, 1, 2, 3, 4, 5, 6, 7 };
    try std.testing.expectError(error.InvalidGraph, invalid.verify());
    blocks[0].terminator = original;
    blocks[0].terminator.invoke.normal.target = 0;
    try std.testing.expectError(error.InvalidGraph, invalid.verify());
    blocks[0].terminator = original;
    blocks[0].terminator.invoke.exceptional.target = 99;
    try std.testing.expectError(error.InvalidGraph, invalid.verify());
    blocks[0].terminator = original;
    blocks[0].terminator.invoke.call.parameter_types = &.{ .i32, .v128 };
    try std.testing.expectError(error.InvalidGraph, invalid.verify());
    blocks[0].terminator = original;
    blocks[0].terminator.invoke.call.result_types = &.{.i64};
    try std.testing.expectError(error.InvalidGraph, invalid.verify());
    blocks[0].terminator = original;
    blocks[0].terminator.invoke.call.safepoint.values = &.{8};
    try std.testing.expectError(error.InvalidGraph, invalid.verify());
}

test "backend invoke: results cannot be rematerialized and ordinary calls cannot catch" {
    var plan = try allocation.Plan.build(a, graph, .{});
    defer plan.deinit();
    plan.locations[8] = .{ .immediate = 0 };
    try std.testing.expectError(error.InvalidAllocation, plan.verify(graph));
    if (!native.supported) return error.SkipZigTest;
    var blocks = graph.blocks[0..3].*;
    const invocation = blocks[0].terminator.invoke;
    var nodes: [5]ir.Node = undefined;
    @memcpy(nodes[0..4], blocks[0].nodes);
    nodes[4] = .{ .op = .call, .trap_site = invocation.site, .call = invocation.call };
    blocks[0].nodes = &nodes;
    blocks[0].terminator = .{ .jump = invocation.normal };
    var ordinary = graph;
    ordinary.blocks = &blocks;
    var owner = try CodeAllocator.init(a, 256 * 1024);
    defer owner.deinit();
    var code = try native.compile(a, &owner, ordinary);
    defer code.deinit();
    var context: Context = .{ .failure = error.LanguageException };
    var values: [15]u64 = @splat(0xdead);
    try std.testing.expectError(error.LanguageException, code.runInto(&inputs, &.{}, 2, context.runtime(), &values));
    try std.testing.expectEqual(@as(usize, 0), context.classifications);
}

fn allocationFailures(allocator: std.mem.Allocator, owner: *CodeAllocator) !void {
    var code = try native.compile(allocator, owner, graph);
    defer code.deinit();
    var context: Context = .{ .failure = error.LanguageException };
    var values: [15]u64 = undefined;
    var result = try code.runInto(&inputs, &.{}, 2, context.runtime(), &values);
    defer result.deinit();
    try std.testing.expect(result == .returned);
}

test "backend invoke: exceptional backedges obey budgets and uncatchable control polls" {
    if (!native.supported) return error.SkipZigTest;
    const Host = struct {
        calls: usize = 0,
        classifications: usize = 0,
        polls: usize = 0,
        stop: usize = 0,
        fn invoke(raw: ?*anyopaque, request: native.CallRequest) !void {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            self.calls += 1;
            if (self.calls <= 3) return error.LanguageException;
            request.results[0] = request.arguments[0] + 1;
        }
        fn classify(raw: ?*anyopaque, _: native.CallRequest, err: anyerror) !bool {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            self.classifications += 1;
            return err == error.LanguageException;
        }
        fn poll(raw: ?*anyopaque) !void {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            self.polls += 1;
            if (self.polls == self.stop) return error.ExecutionTerminated;
        }
        fn runtime(self: *@This()) native.Runtime {
            return .{ .context = self, .call = invoke, .catch_exception = classify };
        }
    };
    const loop: ir.Graph = .{ .types = &.{ .i64, .i64, .i64, .i64 }, .argument_types = &.{.i64}, .result_types = &.{.i64}, .blocks = &.{
        .{ .params = &.{0}, .terminator = .{ .jump = .{ .target = 1, .args = &.{0} } } },
        .{ .params = &.{1}, .terminator = .{ .invoke = .{
            .site = 0,
            .call = .{ .target = 0, .arguments = &.{1}, .parameter_types = &.{.i64}, .results = &.{2}, .result_types = &.{.i64}, .safepoint = .{ .id = 0, .values = &.{1} } },
            .normal = .{ .target = 2, .args = &.{2} },
            .exceptional = .{ .target = 1, .args = &.{1} },
        } } },
        .{ .params = &.{3}, .terminator = .{ .return_ = &.{3} } },
    } };
    var owner = try CodeAllocator.init(a, 256 * 1024);
    defer owner.deinit();
    for ([_]u8{ 0, 1, 4 }) |registers| {
        var code = try native.compileWithOptions(a, &owner, loop, .{ .register_count = registers });
        defer code.deinit();
        for (0..8) |budget| {
            var host: Host = .{};
            const result = code.runOutcomeWithRuntime(&.{42}, &.{}, @intCast(budget), host.runtime());
            if (budget < 6) {
                try std.testing.expectError(error.BudgetExhausted, result);
            } else {
                var outcome = try result;
                defer outcome.deinit();
                try std.testing.expectEqual(@as(u64, 43), outcome.returned);
            }
            try std.testing.expectEqual(@min(4, budget -| 1), host.calls);
            try std.testing.expectEqual(@min(3, host.calls), host.classifications);
        }
        var controlled = try native.compileWithOptions(a, &owner, loop, .{ .register_count = registers, .execution_policy = .controlled });
        defer controlled.deinit();
        for ([_]usize{ 0, 3 }) |stop| {
            var host: Host = .{ .stop = stop };
            var values = [_]u64{0xdead};
            const result = controlled.runControlledInto(a, &.{42}, &.{}, .{ .runtime = host.runtime(), .control = .{ .context = &host, .poll_fn = Host.poll } }, &values);
            if (stop == 0) {
                var completion = try result;
                defer completion.deinit();
                try std.testing.expect(completion == .returned);
                try std.testing.expectEqual(@as(u64, 43), values[0]);
                try std.testing.expectEqual(@as(usize, 4), host.polls);
            } else {
                try std.testing.expectError(error.ExecutionTerminated, result);
                try std.testing.expectEqual(@as(u64, 0xdead), values[0]);
                try std.testing.expectEqual(@as(usize, 2), host.calls);
                try std.testing.expectEqual(@as(usize, 2), host.classifications);
            }
        }
    }
}

test "backend invoke: handler memory refresh preserves ordered stores and bypasses normal effects" {
    if (!native.supported) return error.SkipZigTest;
    const Host = struct {
        bytes: [8]u8 = @splat(0),
        throws: bool,
        fn invoke(raw: ?*anyopaque, request: native.CallRequest) !void {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            std.mem.writeInt(u64, &self.bytes, 42, .little);
            request.memories[0] = native.MemoryView.fromSlice(&self.bytes);
            if (self.throws) return error.LanguageException;
        }
        fn classify(raw: ?*anyopaque, request: native.CallRequest, err: anyerror) !bool {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            try std.testing.expectEqual(@intFromPtr(self.bytes[0..].ptr), @intFromPtr(request.memories[0].base));
            std.mem.writeInt(u64, &self.bytes, 99, .little);
            return err == error.LanguageException;
        }
    };
    const memory_graph: ir.Graph = .{ .types = &.{ .i64, .i64, .i64, .i64, .i64, .i64, .i64 }, .argument_types = &.{ .i64, .i64 }, .result_types = &.{.i64}, .memory_count = 1, .blocks = &.{
        .{ .params = &.{ 0, 1 }, .nodes = &.{.{ .op = .store, .lhs = 0, .rhs = 1, .memory = .{ .width = .double }, .trap_site = 0 }}, .terminator = .{ .invoke = .{
            .site = 1,
            .call = .{ .target = 0, .arguments = &.{}, .parameter_types = &.{}, .results = &.{}, .result_types = &.{}, .safepoint = .{ .id = 0, .values = &.{} } },
            .normal = .{ .target = 1, .args = &.{ 0, 1 } },
            .exceptional = .{ .target = 2, .args = &.{0} },
        } } },
        .{ .params = &.{ 2, 3 }, .nodes = &.{
            .{ .op = .store, .lhs = 2, .rhs = 3, .memory = .{ .width = .double }, .trap_site = 2 },
            .{ .op = .load, .out = 4, .lhs = 2, .memory = .{ .width = .double }, .trap_site = 3 },
        }, .terminator = .{ .return_ = &.{4} } },
        .{ .params = &.{5}, .nodes = &.{.{ .op = .load, .out = 6, .lhs = 5, .memory = .{ .width = .double }, .trap_site = 4 }}, .terminator = .{ .return_ = &.{6} } },
    } };
    var owner = try CodeAllocator.init(a, 256 * 1024);
    defer owner.deinit();
    for ([_]u8{ 0, 4 }) |registers| {
        var code = try native.compileWithOptions(a, &owner, memory_graph, .{ .register_count = registers });
        defer code.deinit();
        for ([_]bool{ false, true }) |throws| {
            var host: Host = .{ .throws = throws };
            var before: [8]u8 = @splat(0);
            const views = [_]native.MemoryView{native.MemoryView.fromSlice(&before)};
            var result = try code.runOutcomeWithRuntime(&.{ 0, 55 }, &views, 2, .{ .context = &host, .call = Host.invoke, .catch_exception = Host.classify });
            defer result.deinit();
            try std.testing.expectEqual(@as(u64, if (throws) 99 else 55), result.returned);
            try std.testing.expectEqual(@as(u64, 55), std.mem.readInt(u64, &before, .little));
        }
    }
}

test "backend invoke: allocation failures release compiler and invocation state" {
    if (!native.supported) return error.SkipZigTest;
    var owner = try CodeAllocator.init(a, 512 * 1024);
    defer owner.deinit();
    try std.testing.checkAllAllocationFailures(a, allocationFailures, .{&owner});
}
