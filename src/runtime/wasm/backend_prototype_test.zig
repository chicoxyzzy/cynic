const std = @import("std");
const prototype = @import("backend_prototype.zig");
const code_alloc = @import("../jit/code_alloc.zig");
const wasm = @import("wasm.zig");

pub fn moduleBytes(a: std.mem.Allocator, params: []const u8, result: u8, locals: []const u8, body: []const u8) ![]const u8 {
    var bytes: std.ArrayList(u8) = .empty;
    try bytes.appendSlice(a, &.{ 0, 0x61, 0x73, 0x6d, 1, 0, 0, 0 });
    var types: std.ArrayList(u8) = .empty;
    try types.appendSlice(a, &.{ 1, 0x60 });
    try uleb(a, &types, params.len);
    try types.appendSlice(a, params);
    try types.appendSlice(a, &.{ 1, result });
    try section(a, &bytes, 1, types.items);
    try section(a, &bytes, 3, &.{ 1, 0 });
    var function: std.ArrayList(u8) = .empty;
    try uleb(a, &function, locals.len);
    for (locals) |ty| try function.appendSlice(a, &.{ 1, ty });
    try function.appendSlice(a, body);
    var code: std.ArrayList(u8) = .empty;
    try code.append(a, 1);
    try uleb(a, &code, function.items.len);
    try code.appendSlice(a, function.items);
    try section(a, &bytes, 10, code.items);
    return bytes.items;
}

fn uleb(a: std.mem.Allocator, out: *std.ArrayList(u8), value: usize) !void {
    var n = value;
    while (true) {
        const byte: u8 = @intCast(n & 0x7f);
        n >>= 7;
        try out.append(a, byte | @as(u8, if (n != 0) 0x80 else 0));
        if (n == 0) return;
    }
}

fn section(a: std.mem.Allocator, out: *std.ArrayList(u8), id: u8, bytes: []const u8) !void {
    try out.append(a, id);
    try uleb(a, out, bytes.len);
    try out.appendSlice(a, bytes);
}

pub const sum_body = [_]u8{
    0x02, 0x40, 0x03, 0x40, // block; loop
    0x20, 1,    0x20, 0,    0x4e, 0x0d, 1, // i >= n: break
    0x20, 2,    0x20, 1,    0x20, 1,    0x6c,
    0x6a, 0x21, 2,    0x20, 1,    0x41, 1,
    0x6a, 0x21, 1,    0x0c, 0,    0x0b, 0x0b,
    0x20, 2,    0x0b,
};

test "backend prototype: native i32 and i64 wraparound" {
    if (!code_alloc.supported) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const i32_module = try moduleBytes(a, &.{ 0x7f, 0x7f }, 0x7f, &.{}, &.{ 0x20, 0, 0x20, 1, 0x6a, 0x41, 3, 0x6c, 0x0b });
    try std.testing.expectEqual(@as(u64, 3), try prototype.evaluate(std.testing.allocator, i32_module, 0, &.{ 0xffff_ffff, 2 }, 10));
    const i64_module = try moduleBytes(a, &.{ 0x7e, 0x7e }, 0x7e, &.{}, &.{ 0x20, 0, 0x20, 1, 0x7c, 0x42, 3, 0x7e, 0x0b });
    try std.testing.expectEqual(@as(u64, 3), try prototype.evaluate(std.testing.allocator, i64_module, 0, &.{ std.math.maxInt(u64), 2 }, 10));
}

test "backend prototype: native loop carries locals and agrees with arithmetic oracle" {
    if (!code_alloc.supported) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const bytes = try moduleBytes(arena.allocator(), &.{0x7f}, 0x7f, &.{ 0x7f, 0x7f }, &sum_body);
    for ([_]u32{ 0, 1, 2, 10, 100, 1000 }) |n| {
        var expected: u32 = 0;
        for (0..n) |i| expected +%= @as(u32, @intCast(i)) *% @as(u32, @intCast(i));
        try std.testing.expectEqual(@as(u64, expected), try prototype.evaluate(std.testing.allocator, bytes, 0, &.{n}, 10_000));
    }
}

test "backend prototype: infinite loop and zero budget return normally" {
    if (!code_alloc.supported) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const bytes = try moduleBytes(arena.allocator(), &.{}, 0x7f, &.{}, &.{ 0x03, 0x40, 0x0c, 0, 0x0b, 0x41, 0, 0x0b });
    try std.testing.expectError(error.BudgetExhausted, prototype.evaluate(std.testing.allocator, bytes, 0, &.{}, 0));
    try std.testing.expectError(error.BudgetExhausted, prototype.evaluate(std.testing.allocator, bytes, 0, &.{}, 100));
}

test "backend prototype: unsupported operations refuse rather than falling back silently" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const bytes = try moduleBytes(arena.allocator(), &.{ 0x7f, 0x7f }, 0x7f, &.{}, &.{ 0x20, 0, 0x20, 1, 0x6d, 0x0b });
    try std.testing.expectError(error.UnsupportedOpcode, prototype.evaluate(std.testing.allocator, bytes, 0, &.{ 1, 0 }, 100));
    const floats = try moduleBytes(arena.allocator(), &.{0x7d}, 0x7d, &.{}, &.{ 0x20, 0, 0x0b });
    try std.testing.expectError(error.UnsupportedType, prototype.evaluate(std.testing.allocator, floats, 0, &.{0}, 100));
}

test "backend prototype: argument count is checked before native entry" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const bytes = try moduleBytes(arena.allocator(), &.{0x7f}, 0x7f, &.{}, &.{ 0x20, 0, 0x0b });
    try std.testing.expectError(error.ArgumentCount, prototype.evaluate(std.testing.allocator, bytes, 0, &.{}, 100));
    try std.testing.expectError(error.FunctionIndex, prototype.evaluate(std.testing.allocator, bytes, 1, &.{0}, 100));
}

test "backend prototype: branch discard and dead branch metadata" {
    if (!code_alloc.supported) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // Keep 7 below the block's height, discard 9 on a taken branch. The
    // second unconditional branch has no validator side-table entry.
    const bytes = try moduleBytes(arena.allocator(), &.{0x7f}, 0x7f, &.{}, &.{
        0x41, 7,    0x02, 0x40, 0x41, 9,    0x20, 0, 0x0d, 0,
        0x1a, 0x0c, 0,    0x0c, 0,    0x0b, 0x0b,
    });
    for ([_]u64{ 0, 1 }) |condition|
        try std.testing.expectEqual(@as(u64, 7), try prototype.evaluate(std.testing.allocator, bytes, 0, &.{condition}, 10));
}

test "backend prototype: unsupported dead operations and resource limits refuse" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const bytes = try moduleBytes(arena.allocator(), &.{}, 0x7f, &.{}, &.{ 0x41, 1, 0x0f, 0x00, 0x0b });
    try std.testing.expectError(error.UnsupportedOpcode, prototype.lowerModule(std.testing.allocator, bytes, 0));
    const oversized = try arena.allocator().alloc(u8, 64 * 1024 + 1);
    try std.testing.expectError(error.PrototypeLimit, prototype.lowerModule(std.testing.allocator, oversized, 0));
}

fn lowerWithFailures(a: std.mem.Allocator, bytes: []const u8) !void {
    var graph = try prototype.lowerModule(a, bytes, 0);
    defer graph.deinit();
    try graph.graph.verify();
}

test "backend prototype: lowering cleans up on allocation failure" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const bytes = try moduleBytes(arena.allocator(), &.{0x7f}, 0x7f, &.{ 0x7f, 0x7f }, &sum_body);
    try std.testing.checkAllAllocationFailures(std.testing.allocator, lowerWithFailures, .{bytes});
}

test "backend prototype: signed and unsigned native comparisons match integer semantics" {
    if (!code_alloc.supported) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const cases = [_]struct { ty: u8, op: u8, input: u64, result: u64 }{
        .{ .ty = 0x7f, .op = 0x48, .input = 0x8000_0000, .result = 1 },
        .{ .ty = 0x7f, .op = 0x49, .input = 0x8000_0000, .result = 0 },
        .{ .ty = 0x7f, .op = 0x4e, .input = 0xffff_ffff, .result = 0 },
        .{ .ty = 0x7f, .op = 0x4f, .input = 0xffff_ffff, .result = 1 },
        .{ .ty = 0x7e, .op = 0x53, .input = 0x8000_0000_0000_0000, .result = 1 },
        .{ .ty = 0x7e, .op = 0x54, .input = 0x8000_0000_0000_0000, .result = 0 },
        .{ .ty = 0x7e, .op = 0x59, .input = 0xffff_ffff_ffff_ffff, .result = 0 },
        .{ .ty = 0x7e, .op = 0x5a, .input = 0xffff_ffff_ffff_ffff, .result = 1 },
        .{ .ty = 0x7f, .op = 0x46, .input = 0xffff_ffff_0000_0001, .result = 1 },
    };
    for (cases) |case| {
        const bytes = try moduleBytes(arena.allocator(), &.{ case.ty, case.ty }, 0x7f, &.{}, &.{ 0x20, 0, 0x20, 1, case.op, 0x0b });
        try std.testing.expectEqual(case.result, try prototype.evaluate(std.testing.allocator, bytes, 0, &.{ case.input, 1 }, 10));
    }
}

test "backend prototype: arithmetic agrees with Sarcasm and native Spasm" {
    if (!code_alloc.supported) return error.SkipZigTest;
    const a = std.testing.allocator;
    for ([_]u8{ 0x7f, 0x7e }) |ty| {
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        const bytes = try moduleBytes(arena.allocator(), &.{ ty, ty }, ty, &.{}, &.{
            0x20, 0, 0x20,                           1,    if (ty == 0x7f) 0x6a else 0x7c,
            0x20, 1, if (ty == 0x7f) 0x6c else 0x7e, 0x0b,
        });
        const module = try wasm.decode(arena.allocator(), bytes);
        var instance: wasm.Instance = undefined;
        try wasm.instantiate(&instance, arena.allocator(), a, &module, .{});
        defer instance.deinit();
        instance.spasm_diagnostics = true;
        var graph = try prototype.lowerModule(a, bytes, 0);
        defer graph.deinit();
        var owner = try code_alloc.CodeAllocator.init(a, 64 * 1024);
        defer owner.deinit();
        var compiled = try prototype.native.compile(a, &owner, graph.graph);
        defer compiled.deinit();
        var seed: u64 = 0x1234_5678_9abc_def0;
        for (0..64) |_| {
            seed = seed *% 6364136223846793005 +% 1;
            const lhs = prototype.ir.normalize(graph.graph.result_type, seed);
            seed = seed *% 6364136223846793005 +% 1;
            const rhs = prototype.ir.normalize(graph.graph.result_type, seed);
            const expected = prototype.ir.normalize(graph.graph.result_type, (lhs +% rhs) *% rhs);
            try std.testing.expectEqual(expected, try compiled.run(&.{ lhs, rhs }, 10));
            for ([_]bool{ false, true }) |spasm| {
                instance.spasm_enabled = spasm;
                const result = try wasm.invoke(&instance, a, 0, &.{ lhs, rhs });
                defer a.free(result);
                try std.testing.expectEqual(@as(usize, 1), result.len);
                try std.testing.expectEqual(@as(u128, expected), result[0]);
            }
        }
        try std.testing.expectEqual(@as(u32, 64), instance.spasm_runs);
    }
}
