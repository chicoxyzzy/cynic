const std = @import("std");
const ir = @import("ir.zig");
const native = @import("native.zig");
const CodeAllocator = @import("../code_alloc.zig").CodeAllocator;
const a = std.testing.allocator;

const loop: ir.Graph = .{ .types = &.{ .i32, .i32, .i32, .i32, .i32 }, .argument_types = &.{.i32}, .result_types = &.{.i32}, .blocks = &.{
    .{ .params = &.{0}, .terminator = .{ .jump = .{ .target = 1, .args = &.{0} } } },
    .{ .params = &.{1}, .nodes = &.{ .{ .op = .constant, .out = 2, .immediate = 1 }, .{ .op = .sub, .out = 3, .lhs = 1, .rhs = 2 } }, .terminator = .{ .branch = .{ .condition = 3, .taken = .{ .target = 1, .args = &.{3} }, .fallthrough = .{ .target = 2, .args = &.{3} } } } },
    .{ .params = &.{4}, .terminator = .{ .return_ = &.{4} } },
} };
const Control = struct {
    calls: usize = 0,
    stop: usize = std.math.maxInt(usize),
    fn poll(raw: ?*anyopaque) !void {
        const self: *@This() = @ptrCast(@alignCast(raw.?));
        self.calls += 1;
        if (self.calls == self.stop) return error.HostStopped;
    }
};

test "backend control: entry and taken backward edges preserve live transfers" {
    if (!native.supported) return error.SkipZigTest;
    var owner = try CodeAllocator.init(a, 128 * 1024);
    defer owner.deinit();
    for ([_]u8{ 0, 1, 4 }) |registers| {
        var code = try native.compileWithOptions(a, &owner, loop, .{ .execution_policy = .controlled, .register_count = registers });
        defer code.deinit();
        var control: Control = .{};
        var values = [_]u64{99};
        var result = try code.runControlledInto(a, &.{5}, &.{}, .{ .control = .{ .context = &control, .poll_fn = Control.poll } }, &values);
        defer result.deinit();
        try std.testing.expect(result == .returned);
        try std.testing.expectEqual(@as(u64, 0), values[0]);
        try std.testing.expectEqual(@as(usize, 5), control.calls);
        control = .{ .stop = 3 };
        values[0] = 99;
        try std.testing.expectError(error.HostStopped, code.runControlledInto(a, &.{5}, &.{}, .{ .control = .{ .context = &control, .poll_fn = Control.poll } }, &values));
        try std.testing.expectEqual(@as(u64, 99), values[0]);
        try std.testing.expectError(error.ExecutionPolicyMismatch, code.run(&.{5}, 100));
    }
}

test "backend control: unarmed wake probes skip callbacks and controlled execution has no demo cap" {
    if (!native.supported) return error.SkipZigTest;
    var owner = try CodeAllocator.init(a, 64 * 1024);
    defer owner.deinit();
    var code = try native.compileWithOptions(a, &owner, loop, .{ .execution_policy = .controlled });
    defer code.deinit();
    var control: Control = .{ .stop = 1 };
    var wake = std.atomic.Value(bool).init(false);
    var values = [_]u64{99};
    var result = try code.runControlledInto(a, &.{native.max_budget + 5}, &.{}, .{ .control = .{ .context = &control, .poll_fn = Control.poll, .wake_flag = &wake } }, &values);
    defer result.deinit();
    try std.testing.expect(result == .returned);
    try std.testing.expectEqual(@as(usize, 0), control.calls);
    wake.store(true, .release);
    try std.testing.expectError(error.HostStopped, code.runControlledInto(a, &.{5}, &.{}, .{ .control = .{ .context = &control, .poll_fn = Control.poll, .wake_flag = &wake } }, &values));
}

test "backend control: static traffic includes wake probes helper calls and FP transitions" {
    if (!native.supported) return error.SkipZigTest;
    var owner = try CodeAllocator.init(a, 64 * 1024);
    defer owner.deinit();
    const graph: ir.Graph = .{ .types = &.{}, .argument_types = &.{}, .result_types = &.{}, .blocks = &.{.{ .params = &.{}, .terminator = .{ .return_ = &.{} } }} };
    var code = try native.compileWithOptions(a, &owner, graph, .{ .execution_policy = .controlled });
    defer code.deinit();
    const x86 = @import("builtin").cpu.arch == .x86_64;
    // One probe, both FP transitions around the helper, and both terminal
    // returns are emitted, even though only one return executes per entry.
    try std.testing.expectEqual(@as(usize, if (x86) 11 else 16), code.stats.loads);
    try std.testing.expectEqual(@as(usize, if (x86) 4 else 6), code.stats.stores);
}
