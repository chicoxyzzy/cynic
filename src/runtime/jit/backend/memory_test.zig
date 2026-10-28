const std = @import("std");
const ir = @import("ir.zig");
const native = @import("native.zig");
const optimize = @import("optimize.zig");
const AllocationMode = @import("allocation.zig").Mode;
const CodeAllocator = @import("../code_alloc.zig").CodeAllocator;
const a = std.testing.allocator;

const LoadFixture = struct {
    types: [2]ir.Type,
    nodes: [1]ir.Node,
    blocks: [1]ir.Block = .{.{ .params = &.{0}, .terminator = .{ .return_ = 1 } }},

    fn init(ty: ir.Type, access: ir.MemoryAccess) LoadFixture {
        return .{ .types = .{ .i64, ty }, .nodes = .{.{ .op = .load, .out = 1, .lhs = 0, .memory = access, .trap_site = 9 }} };
    }

    fn graph(self: *LoadFixture) ir.Graph {
        self.blocks[0].nodes = &self.nodes;
        return .{ .types = &self.types, .argument_types = &.{.i64}, .result_type = self.types[1], .memory_count = 1, .blocks = &self.blocks };
    }
};

test "backend memory: verifier checks access widths regions and effects" {
    const effects = ir.effects(.load);
    try std.testing.expect(effects.reads_memory and effects.may_trap and !effects.writes_memory);
    try std.testing.expect(ir.effects(.store).writes_memory and ir.effects(.store).may_trap);
    try std.testing.expect(!effects.isPure());
    try std.testing.expect(ir.effects(.add).isPure());
    for ([_]ir.Type{ .i32, .i64, .f32, .f64 }) |ty| for ([_]ir.MemoryWidth{ .byte, .half, .word, .double }) |width| for ([_]bool{ false, true }) |signed| {
        var fixture = LoadFixture.init(ty, .{ .width = width, .signed = signed });
        const graph = fixture.graph();
        const bytes = width.bytes();
        const value_bytes: usize = if (ir.is32(ty)) 4 else 8;
        const valid = bytes <= value_bytes and
            (!ir.isFloat(ty) or bytes == value_bytes) and
            (!signed or (!ir.isFloat(ty) and bytes < value_bytes));
        if (valid) try graph.verify() else try std.testing.expectError(error.InvalidGraph, graph.verify());
    };
    var invalid = LoadFixture.init(.i32, .{ .width = .word, .region = 1 });
    try std.testing.expectError(error.InvalidGraph, invalid.graph().verify());
    var fixture = LoadFixture.init(.i32, .{ .width = .word });
    var graph = fixture.graph();
    graph.memory_count = 0;
    try std.testing.expectError(error.InvalidGraph, graph.verify());
    graph.memory_count = ir.max_memories + 1;
    try std.testing.expectError(error.PrototypeLimit, graph.verify());
    fixture.types[0] = .f64;
    graph = fixture.graph();
    graph.argument_types = &.{.f64};
    try std.testing.expectError(error.InvalidGraph, graph.verify());
}

test "backend memory: scalar loads preserve bits and extend narrow integers" {
    if (!native.supported) return error.SkipZigTest;
    var owner = try CodeAllocator.init(a, 256 * 1024);
    defer owner.deinit();
    var bytes = [_]u8{ 0x11, 0x80, 0xff, 0xff, 0xff, 0xff, 0xff, 0xf0, 0xff, 0x22 };
    const views = [_]native.MemoryView{native.MemoryView.fromSlice(&bytes)};
    for ([_]ir.Type{ .i32, .i64, .f32, .f64 }) |ty| for ([_]ir.MemoryWidth{ .byte, .half, .word, .double }) |width| for ([_]bool{ false, true }) |signed| {
        var fixture = LoadFixture.init(ty, .{ .width = width, .signed = signed, .offset = 1 });
        const graph = fixture.graph();
        graph.verify() catch continue;
        var code = try native.compile(a, &owner, graph);
        defer code.deinit();
        var expected: u64 = 0;
        for (bytes[1..][0..width.bytes()], 0..) |byte, i| expected |= @as(u64, byte) << @as(u6, @intCast(8 * i));
        if (signed and bytes[width.bytes()] & 0x80 != 0) expected |= ~@as(u64, 0) << @as(u6, @intCast(width.bytes() * 8));
        try std.testing.expectEqual(ir.normalize(ty, expected), try code.runWithMemory(&.{0}, &views, 1));
        try std.testing.expectError(error.MemoryCount, code.run(&.{0}, 1));
    };
}

test "backend memory: bounds checks reject overflow and retain unused trapping loads" {
    if (!native.supported) return error.SkipZigTest;
    var owner = try CodeAllocator.init(a, 256 * 1024);
    defer owner.deinit();
    var bytes: [8]u8 = @splat(0x55);
    for ([_]u64{ 0, 1, 0xffff_ffff_ffff_ffff }) |offset| {
        const graph: ir.Graph = .{ .types = &.{ .i64, .i64 }, .argument_types = &.{.i64}, .result_type = .i64, .memory_count = 1, .blocks = &.{.{ .params = &.{0}, .nodes = &.{.{ .op = .load, .out = 1, .lhs = 0, .memory = .{ .width = .double, .offset = offset }, .trap_site = 77 }}, .terminator = .{ .return_ = 0 } }} };
        var optimized = try optimize.run(a, graph, .{});
        defer optimized.deinit();
        try std.testing.expectEqual(@as(usize, 1), optimized.graph.blocks[0].nodes.len);
        var code = try native.compile(a, &owner, graph);
        defer code.deinit();
        for ([_]usize{ 0, 7, 8 }) |len| for ([_]u64{ 0, 1, 8, 0xffff_ffff_ffff_ffff }) |address| {
            const views = [_]native.MemoryView{native.MemoryView.fromSlice(bytes[0..len])};
            var outcome = try code.runOutcomeWithMemory(&.{address}, &views, 1);
            defer outcome.deinit();
            if (len == 8 and offset == 0 and address == 0) {
                try std.testing.expectEqual(@as(u64, 0), outcome.returned);
            } else try std.testing.expectEqual(ir.Trap{ .reason = .memory_out_of_bounds, .site = 77 }, outcome.trapped);
        };
    }
}

test "backend memory: aliased writes stay ordered across loads and guard exits" {
    if (!native.supported) return error.SkipZigTest;
    var owner = try CodeAllocator.init(a, 256 * 1024);
    defer owner.deinit();
    const graph: ir.Graph = .{
        .types = &.{ .i32, .i64, .i64, .i64, .i64 },
        .argument_types = &.{ .i32, .i64, .i64 },
        .result_type = .i64,
        .memory_count = 2,
        .blocks = &.{.{ .params = &.{ 0, 1, 2 }, .nodes = &.{
            .{ .op = .load, .out = 3, .lhs = 1, .memory = .{ .width = .double }, .trap_site = 1 },
            .{ .op = .store, .lhs = 1, .rhs = 2, .memory = .{ .width = .double, .region = 1 }, .trap_site = 2 },
            .{ .op = .load, .out = 4, .lhs = 1, .memory = .{ .width = .double }, .trap_site = 3 },
            .{ .op = .guard, .lhs = 0, .exit = .{ .id = 4, .values = &.{ 3, 4 } } },
        }, .terminator = .{ .return_ = 4 } }},
    };
    for ([_]AllocationMode{ .linear_scan, .scratch }) |mode| for (0..16) |flags| for ([_]u8{ 0, 1, 4 }) |registers| {
        var code = try native.compileWithOptions(a, &owner, graph, .{ .allocation = mode, .register_count = registers, .rematerialize_constants = flags & 8 != 0, .optimization = .{ .constant_folding = flags & 1 != 0, .common_subexpression_elimination = flags & 2 != 0, .dead_code_elimination = flags & 4 != 0 } });
        defer code.deinit();
        var bytes: [16]u8 = @splat(0);
        const views = [_]native.MemoryView{ native.MemoryView.fromSlice(&bytes), native.MemoryView.fromSlice(&bytes) };
        var outcome = try code.runOutcomeWithMemory(&.{ 0, 1, 0x1234_5678_9abc_def0 }, &views, 1);
        defer outcome.deinit();
        try std.testing.expectEqualSlices(u64, &.{ 0, 0x1234_5678_9abc_def0 }, outcome.exited.values);
        try std.testing.expectEqual(@as(u64, 0x1234_5678_9abc_def0), std.mem.readInt(u64, bytes[1..9], .little));
        try std.testing.expectEqual(@as(u8, 0), bytes[0]);
        try std.testing.expectEqual(@as(u8, 0), bytes[9]);
    };
}

test "backend memory: stores cannot cross traps guards or budget polls" {
    if (!native.supported) return error.SkipZigTest;
    var owner = try CodeAllocator.init(a, 256 * 1024);
    defer owner.deinit();
    const graph: ir.Graph = .{
        .types = &.{ .i32, .i64, .i64, .i64 },
        .argument_types = &.{ .i32, .i64, .i64 },
        .result_type = .i64,
        .memory_count = 1,
        .blocks = &.{.{ .params = &.{ 0, 1, 2 }, .nodes = &.{
            .{ .op = .guard, .lhs = 0, .exit = .{ .id = 1, .values = &.{} } },
            .{ .op = .store, .lhs = 1, .rhs = 2, .memory = .{ .width = .double }, .trap_site = 2 },
            .{ .op = .load, .out = 3, .lhs = 1, .memory = .{ .width = .double, .offset = 8 }, .trap_site = 3 },
            .{ .op = .store, .lhs = 1, .rhs = 1, .memory = .{ .width = .double }, .trap_site = 4 },
        }, .terminator = .{ .return_ = 1 } }},
    };
    var code = try native.compile(a, &owner, graph);
    defer code.deinit();
    for ([_][3]u64{ .{ 0, 0, 1 }, .{ 1, 1, 1 }, .{ 1, 0, 0 } }) |args| {
        var bytes: [8]u8 = @splat(0xa5);
        const views = [_]native.MemoryView{native.MemoryView.fromSlice(&bytes)};
        if (args[2] == 0) {
            try std.testing.expectError(error.BudgetExhausted, code.runWithMemory(&args, &views, 0));
        } else {
            var result = try code.runOutcomeWithMemory(&args, &views, 1);
            defer result.deinit();
            if (args[0] == 0) try std.testing.expectEqual(@as(u32, 1), result.exited.id) else try std.testing.expectEqual(ir.Trap{ .reason = .memory_out_of_bounds, .site = 2 }, result.trapped);
        }
        try std.testing.expectEqualSlices(u8, &@as([8]u8, @splat(0xa5)), &bytes);
    }
    var bytes: [8]u8 = @splat(0);
    const views = [_]native.MemoryView{native.MemoryView.fromSlice(&bytes)};
    var result = try code.runOutcomeWithMemory(&.{ 1, 0, 0x1234 }, &views, 1);
    defer result.deinit();
    try std.testing.expectEqual(ir.Trap{ .reason = .memory_out_of_bounds, .site = 3 }, result.trapped);
    try std.testing.expectEqual(@as(u64, 0x1234), std.mem.readInt(u64, &bytes, .little));
}

test "backend memory: verifier rejects malformed store and stray memory metadata" {
    var nodes = [_]ir.Node{.{ .op = .store, .lhs = 0, .rhs = 1, .memory = .{ .width = .double }, .trap_site = 2 }};
    const graph: ir.Graph = .{ .types = &.{ .i64, .i64 }, .argument_types = &.{ .i64, .i64 }, .result_type = .i64, .memory_count = 1, .blocks = &.{.{ .params = &.{ 0, 1 }, .nodes = &nodes, .terminator = .{ .return_ = 0 } }} };
    try graph.verify();
    const original = nodes[0];
    nodes[0].out = 0;
    try std.testing.expectError(error.InvalidGraph, graph.verify());
    nodes[0] = original;
    nodes[0].trap_site = null;
    try std.testing.expectError(error.InvalidGraph, graph.verify());
    nodes[0] = original;
    nodes[0].memory = null;
    try std.testing.expectError(error.InvalidGraph, graph.verify());
    nodes[0] = original;
    nodes[0].memory.?.signed = true;
    try std.testing.expectError(error.InvalidGraph, graph.verify());
    const stray: ir.Graph = .{ .types = &.{.i64}, .argument_types = &.{}, .result_type = .i64, .blocks = &.{.{ .params = &.{}, .nodes = &.{.{ .op = .constant, .out = 0, .immediate = 1, .memory = .{ .width = .byte } }}, .terminator = .{ .return_ = 0 } }} };
    try std.testing.expectError(error.InvalidGraph, stray.verify());
}

fn allocationFailures(allocator: std.mem.Allocator, owner: *CodeAllocator) !void {
    var fixture = LoadFixture.init(.i32, .{ .width = .byte });
    var code = try native.compile(allocator, owner, fixture.graph());
    defer code.deinit();
    var bytes = [_]u8{42};
    const views = [_]native.MemoryView{native.MemoryView.fromSlice(&bytes)};
    try std.testing.expectEqual(@as(u64, 42), try code.runWithMemory(&.{0}, &views, 1));
}

test "backend memory: compilation and invocation clean up on allocation failure" {
    if (!native.supported) return error.SkipZigTest;
    var owner = try CodeAllocator.init(a, 256 * 1024);
    defer owner.deinit();
    try std.testing.checkAllAllocationFailures(a, allocationFailures, .{&owner});
}
