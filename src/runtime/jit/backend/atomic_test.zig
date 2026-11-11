const std = @import("std");
const ir = @import("ir.zig");
const native = @import("native.zig");
const optimize = @import("optimize.zig");
const Mode = @import("allocation.zig").Mode;
const CodeAllocator = @import("../code_alloc.zig").CodeAllocator;
const a = std.testing.allocator;

test "backend atomics: instruction encodings match the platform assembler" {
    const arm = @import("../asm_aarch64.zig");
    const x86 = @import("../asm_x86_64.zig");
    for ([_]arm.AtomicWidth{ .byte, .half, .word, .double }, 0..) |width, i| {
        const size = @as(u32, @intCast(i)) << 30;
        try std.testing.expectEqual(@as(u32, 0x08dffe02) | size, arm.atomicLoad(.x2, .x16, width, false));
        try std.testing.expectEqual(@as(u32, 0x085ffe02) | size, arm.atomicLoad(.x2, .x16, width, true));
        try std.testing.expectEqual(@as(u32, 0x089ffe03) | size, arm.atomicStore(.x3, .x16, width));
        try std.testing.expectEqual(@as(u32, 0x0808fe11) | size, arm.storeReleaseExclusive(.x8, .x17, .x16, width));
    }
    try std.testing.expectEqual(@as(u32, 0xd5033bbf), arm.dmbIsh());
    try std.testing.expectEqual(@as(u32, 0xd5033f5f), arm.clrex());
    var m = x86.Masm.init(a);
    defer m.deinit();
    try m.atomicCompareExchange(.r11, .r10, .byte);
    try m.atomicCompareExchange(.r11, .rcx, .half);
    try m.atomicCompareExchange(.r11, .rcx, .word);
    try m.atomicCompareExchange(.r11, .rcx, .double);
    try m.atomicExchange(.r11, .r10, .double);
    try m.memoryFence();
    try std.testing.expectEqualSlices(u8, &.{
        0xf0, 0x45, 0x0f, 0xb0, 0x93, 0,    0, 0, 0,
        0xf0, 0x66, 0x41, 0x0f, 0xb1, 0x8b, 0, 0, 0,
        0,    0xf0, 0x41, 0x0f, 0xb1, 0x8b, 0, 0, 0,
        0,    0xf0, 0x49, 0x0f, 0xb1, 0x8b, 0, 0, 0,
        0,    0x4d, 0x87, 0x93, 0,    0,    0, 0, 0x0f,
        0xae, 0xf0,
    }, m.code.items);
}

const operations = [_]ir.Op{ .atomic_load, .atomic_store, .atomic_add, .atomic_sub, .atomic_and, .atomic_or, .atomic_xor, .atomic_exchange, .atomic_compare_exchange };

const Fixture = struct {
    types: [5]ir.Type = @splat(.i64),
    node: [1]ir.Node,
    block: [1]ir.Block = .{.{ .params = &.{ 0, 1, 2, 3 } }},

    fn init(op: ir.Op, ty: ir.Type, width: ir.MemoryWidth) Fixture {
        return .{
            .types = .{ .i64, ty, ty, .i64, ty },
            .node = .{.{ .op = op, .lhs = 0, .rhs = 1, .expected = if (op == .atomic_compare_exchange) 2 else null, .out = if (op == .atomic_store) null else 4, .memory = .{ .width = width }, .trap_site = 73 }},
        };
    }

    fn graph(self: *Fixture) ir.Graph {
        self.block[0].nodes = &self.node;
        self.block[0].terminator = .{ .return_ = if (self.node[0].op == .atomic_store) &.{ 0, 1, 2, 3 } else &.{ 0, 1, 2, 3, 4 } };
        return .{ .types = if (self.node[0].op == .atomic_store) self.types[0..4] else &self.types, .argument_types = self.types[0..4], .result_types = if (self.node[0].op == .atomic_store) self.types[0..4] else &self.types, .memory_count = 1, .blocks = &self.block };
    }
};

fn mask(width: ir.MemoryWidth) u64 {
    return @as(u64, std.math.maxInt(u64)) >> @as(u6, @intCast(64 - width.bytes() * 8));
}

test "backend atomics: verifier rejects malformed widths operands and effects" {
    for (operations) |op| {
        const effects = ir.effects(op);
        try std.testing.expect(effects.ordered and effects.may_trap and !effects.isPure());
        var fixture = Fixture.init(op, .i64, .double);
        try fixture.graph().verify();
        fixture.node[0].memory.?.signed = true;
        try std.testing.expectError(error.InvalidGraph, fixture.graph().verify());
        fixture.node[0].memory.?.signed = false;
        fixture.node[0].memory.?.width = .quad;
        try std.testing.expectError(error.InvalidGraph, fixture.graph().verify());
        fixture.node[0].memory.?.width = .double;
        fixture.node[0].trap_site = null;
        try std.testing.expectError(error.InvalidGraph, fixture.graph().verify());
        fixture.node[0].trap_site = 73;
        fixture.node[0].expected = if (op == .atomic_compare_exchange) null else 2;
        try std.testing.expectError(error.InvalidGraph, fixture.graph().verify());
    }
    for ([_]ir.Type{ .i32, .f32, .f64, .v128 }) |ty| {
        var fixture = Fixture.init(.atomic_add, ty, .double);
        try std.testing.expectError(error.InvalidGraph, fixture.graph().verify());
    }
    var fixture = Fixture.init(.atomic_compare_exchange, .i64, .word);
    fixture.node[0].expected = 4;
    try std.testing.expectError(error.InvalidGraph, fixture.graph().verify());
    fixture.node[0].expected = 3;
    fixture.types[3] = .i32;
    try std.testing.expectError(error.InvalidGraph, fixture.graph().verify());
}

test "backend atomics: native widths operations and live homes match integer reference" {
    if (!native.supported) return error.SkipZigTest;
    var owner = try CodeAllocator.init(a, 256 * 1024);
    defer owner.deinit();
    for ([_]ir.Type{ .i32, .i64 }) |ty| for ([_]ir.MemoryWidth{ .byte, .half, .word, .double }) |width| {
        if (ty == .i32 and width == .double) continue;
        const initial = 0xfedc_ba98_7654_32ff & mask(width);
        const operand = ir.normalize(ty, 0x1234_5678_9abc_de03);
        for (operations) |op| for ([_]Mode{ .scratch, .linear_scan }) |mode| for ([_]u8{ 0, 1, 4 }) |registers| for ([_]bool{ false, true }) |optimized| {
            var fixture = Fixture.init(op, ty, width);
            fixture.node[0].memory.?.offset = 8;
            var code = try native.compileWithOptions(a, &owner, fixture.graph(), .{ .allocation = mode, .register_count = registers, .optimization = .{ .constant_folding = optimized, .common_subexpression_elimination = optimized, .dead_code_elimination = optimized } });
            defer code.deinit();
            try std.testing.expectEqual(@as(usize, 0), code.call_sites.len);
            for ([_]bool{ false, true }) |match| {
                var bytes: [32]u8 align(16) = @splat(0xa5);
                std.mem.writeInt(u64, bytes[16..24], initial, .little);
                const views = [_]native.MemoryView{native.MemoryView.fromSlice(&bytes)};
                const expected = ir.normalize(ty, (initial ^ @as(u64, @intFromBool(!match))) | (~mask(width) & 0x7654_3210_ffff_ffff));
                const args = [_]u64{ 8, operand, expected, 0x9876_5432_1234_5678 };
                var results: [5]u64 = undefined;
                var outcome = try code.runInto(&args, &views, 1, null, results[0..ir.wordCount(code.result_types)]);
                defer outcome.deinit();
                try std.testing.expect(outcome == .returned);
                try std.testing.expectEqualSlices(u64, &args, results[0..4]);
                if (op != .atomic_store) try std.testing.expectEqual(initial, results[4]);
                const changed = (switch (op) {
                    .atomic_load => initial,
                    .atomic_store, .atomic_exchange => operand,
                    .atomic_add => initial +% operand,
                    .atomic_sub => initial -% operand,
                    .atomic_and => initial & operand,
                    .atomic_or => initial | operand,
                    .atomic_xor => initial ^ operand,
                    .atomic_compare_exchange => if (match) operand else initial,
                    else => unreachable,
                }) & mask(width);
                var actual: u64 = 0;
                for (bytes[16..][0..width.bytes()], 0..) |byte, i| actual |= @as(u64, byte) << @as(u6, @intCast(8 * i));
                try std.testing.expectEqual(changed, actual);
                for (bytes[0..16]) |byte| try std.testing.expectEqual(@as(u8, 0xa5), byte);
                for (bytes[16 + width.bytes() .. 24]) |byte| try std.testing.expectEqual(@as(u8, 0), byte);
                for (bytes[24..]) |byte| try std.testing.expectEqual(@as(u8, 0xa5), byte);
            }
        };
    };
}

test "backend atomics: alignment bounds overflow and trap sites are explicit" {
    if (!native.supported) return error.SkipZigTest;
    var owner = try CodeAllocator.init(a, 64 * 1024);
    defer owner.deinit();
    for (operations) |op| for ([_]u64{ 0, 1, std.math.maxInt(u64) }) |offset| {
        var fixture = Fixture.init(op, .i64, .double);
        fixture.node[0].memory.?.offset = offset;
        var code = try native.compile(a, &owner, fixture.graph());
        defer code.deinit();
        var bytes: [24]u8 align(16) = @splat(0);
        for ([_]usize{ 0, 7, 16 }) |len| for ([_]u64{ 0, 1, 8, 16, std.math.maxInt(u64) }) |address| {
            const views = [_]native.MemoryView{native.MemoryView.fromSlice(bytes[0..len])};
            var results: [5]u64 = undefined;
            var result = try code.runInto(&.{ address, 0, 0, 0 }, &views, 1, null, results[0..ir.wordCount(code.result_types)]);
            defer result.deinit();
            const sum = @addWithOverflow(address, offset);
            if (sum[1] != 0 or len < 8 or sum[0] > len - 8) {
                try std.testing.expectEqual(ir.Trap{ .reason = .memory_out_of_bounds, .site = 73 }, result.trapped);
            } else if (sum[0] % 8 != 0) {
                try std.testing.expectEqual(ir.Trap{ .reason = .unaligned_atomic, .site = 73 }, result.trapped);
            } else try std.testing.expect(result == .returned);
        };
        if (offset == 0) {
            const views = [_]native.MemoryView{native.MemoryView.fromSlice(bytes[1..])};
            var results: [5]u64 = undefined;
            var result = try code.runInto(&.{ 0, 0, 0, 0 }, &views, 1, null, results[0..ir.wordCount(code.result_types)]);
            defer result.deinit();
            try std.testing.expectEqual(ir.Trap{ .reason = .unaligned_atomic, .site = 73 }, result.trapped);
        }
    };
}

test "backend atomics: fences survive optimization without a memory region" {
    const graph: ir.Graph = .{ .types = &.{}, .argument_types = &.{}, .result_types = &.{}, .blocks = &.{.{ .params = &.{}, .nodes = &.{.{ .op = .atomic_fence }} }} };
    try graph.verify();
    try std.testing.expect(ir.effects(.atomic_fence).ordered);
    var optimized = try optimize.run(a, graph, .{});
    defer optimized.deinit();
    try std.testing.expectEqual(@as(usize, 1), optimized.graph.blocks[0].nodes.len);
    if (!native.supported) return error.SkipZigTest;
    var owner = try CodeAllocator.init(a, 64 * 1024);
    defer owner.deinit();
    var code = try native.compile(a, &owner, graph);
    defer code.deinit();
    var result = try code.runInto(&.{}, &.{}, 1, null, &.{});
    defer result.deinit();
    try std.testing.expect(result == .returned);
}

test "backend atomics: concurrent native and host increments are indivisible" {
    if (!native.supported) return error.SkipZigTest;
    const graph: ir.Graph = .{ .types = &.{ .i64, .i64, .i64 }, .argument_types = &.{ .i64, .i64 }, .result_types = &.{.i64}, .memory_count = 1, .blocks = &.{.{ .params = &.{ 0, 1 }, .nodes = &.{.{ .op = .atomic_add, .out = 2, .lhs = 0, .rhs = 1, .memory = .{ .width = .double }, .trap_site = 0 }}, .terminator = .{ .return_ = &.{2} } }} };
    var owner = try CodeAllocator.init(a, 64 * 1024);
    defer owner.deinit();
    var code = try native.compile(a, &owner, graph);
    defer code.deinit();
    const Worker = struct {
        code: *const native.Compiled,
        counter: *u64,
        host: bool,
        sum: u64 = 0,
        failure: ?anyerror = null,

        fn run(self: *@This()) void {
            const views = [_]native.MemoryView{native.MemoryView.fromSlice(std.mem.asBytes(self.counter))};
            for (0..1000) |_| {
                self.sum += if (self.host) @atomicRmw(u64, self.counter, .Add, 1, .seq_cst) else self.code.runWithMemory(&.{ 0, 1 }, &views, 1) catch |err| {
                    self.failure = err;
                    return;
                };
            }
        }
    };
    var counter: u64 = 0;
    var workers: [4]Worker = undefined;
    var threads: [4]std.Thread = undefined;
    var started: usize = 0;
    errdefer for (threads[0..started]) |thread| thread.join();
    for (&workers, &threads, 0..) |*worker, *thread, i| {
        worker.* = .{ .code = &code, .counter = &counter, .host = i == 0 };
        thread.* = try std.Thread.spawn(.{}, Worker.run, .{worker});
        started += 1;
    }
    for (threads) |thread| thread.join();
    started = 0;
    var sum: u64 = 0;
    for (workers) |worker| {
        if (worker.failure) |err| return err;
        sum += worker.sum;
    }
    try std.testing.expectEqual(@as(u64, 4000), counter);
    try std.testing.expectEqual(@as(u64, 4000 * 3999 / 2), sum);
}

test "backend atomics: expected operands remap and unused results retain effects" {
    if (!native.supported) return error.SkipZigTest;
    const graph: ir.Graph = .{ .types = &@as([6]ir.Type, @splat(.i64)), .argument_types = &.{}, .result_types = &.{.i64}, .memory_count = 1, .blocks = &.{.{ .params = &.{}, .nodes = &.{
        .{ .op = .constant, .out = 0 },
        .{ .op = .constant, .out = 1, .immediate = 42 },
        .{ .op = .constant, .out = 2, .immediate = 13 },
        .{ .op = .constant, .out = 3 },
        .{ .op = .atomic_compare_exchange, .out = 4, .lhs = 0, .rhs = 1, .expected = 3, .memory = .{ .width = .double }, .trap_site = 10 },
        .{ .op = .atomic_fence },
        .{ .op = .atomic_load, .out = 5, .lhs = 0, .memory = .{ .width = .double }, .trap_site = 11 },
    }, .terminator = .{ .return_ = &.{5} } }} };
    var owner = try CodeAllocator.init(a, 64 * 1024);
    defer owner.deinit();
    var code = try native.compile(a, &owner, graph);
    defer code.deinit();
    try std.testing.expect(code.optimization.commoned_nodes > 0);
    try std.testing.expect(code.optimization.removed_nodes > 0);
    var cell: u64 = 0;
    const views = [_]native.MemoryView{native.MemoryView.fromSlice(std.mem.asBytes(&cell))};
    try std.testing.expectEqual(@as(u64, 42), try code.runWithMemory(&.{}, &views, 1));
    try std.testing.expectEqual(@as(u64, 42), cell);
    cell = 0;
    try std.testing.expectError(error.BudgetExhausted, code.runWithMemory(&.{}, &views, 0));
    try std.testing.expectEqual(@as(u64, 0), cell);
}

test "backend atomics: sequential consistency forbids store buffering" {
    if (!native.supported) return error.SkipZigTest;
    const rounds = 1000;
    const Worker = struct {
        code: *const native.Compiled,
        cells: *[2]u64,
        phase: *std.atomic.Value(usize),
        done: *std.atomic.Value(usize),
        result: u64 = 0,
        failure: ?anyerror = null,

        fn run(self: *@This()) void {
            const views = [_]native.MemoryView{native.MemoryView.fromSlice(std.mem.asBytes(self.cells))};
            for (1..rounds + 1) |round| {
                while (self.phase.load(.acquire) < round) std.atomic.spinLoopHint();
                self.result = self.code.runWithMemory(&.{ 0, 1 }, &views, 1) catch |err| result: {
                    self.failure = err;
                    break :result 0;
                };
                _ = self.done.fetchAdd(1, .acq_rel);
            }
        }
    };
    var nodes = [_]ir.Node{
        .{ .op = .atomic_store, .lhs = 0, .rhs = 1, .memory = .{ .width = .double }, .trap_site = 1 },
        .{ .op = .atomic_load, .out = 2, .lhs = 0, .memory = .{ .width = .double, .offset = 8 }, .trap_site = 2 },
    };
    const blocks = [_]ir.Block{.{ .params = &.{ 0, 1 }, .nodes = &nodes, .terminator = .{ .return_ = &.{2} } }};
    const graph: ir.Graph = .{ .types = &.{ .i64, .i64, .i64 }, .argument_types = &.{ .i64, .i64 }, .result_types = &.{.i64}, .memory_count = 1, .blocks = &blocks };
    var owner = try CodeAllocator.init(a, 64 * 1024);
    defer owner.deinit();
    var first = try native.compile(a, &owner, graph);
    defer first.deinit();
    nodes[0].memory.?.offset = 8;
    nodes[1].memory.?.offset = 0;
    var second = try native.compile(a, &owner, graph);
    defer second.deinit();
    var cells: [2]u64 = @splat(0);
    var phase = std.atomic.Value(usize).init(0);
    var done = std.atomic.Value(usize).init(0);
    var workers = [_]Worker{
        .{ .code = &first, .cells = &cells, .phase = &phase, .done = &done },
        .{ .code = &second, .cells = &cells, .phase = &phase, .done = &done },
    };
    const one = try std.Thread.spawn(.{}, Worker.run, .{&workers[0]});
    var joined = false;
    errdefer if (!joined) {
        phase.store(rounds, .release);
        one.join();
    };
    const two = try std.Thread.spawn(.{}, Worker.run, .{&workers[1]});
    var forbidden: usize = 0;
    for (1..rounds + 1) |round| {
        @atomicStore(u64, &cells[0], 0, .seq_cst);
        @atomicStore(u64, &cells[1], 0, .seq_cst);
        phase.store(round, .release);
        while (done.load(.acquire) < 2 * round) std.atomic.spinLoopHint();
        if (workers[0].result == 0 and workers[1].result == 0) forbidden += 1;
    }
    one.join();
    two.join();
    joined = true;
    // The threads are joined before assertions so failures cannot strand them.
    for (workers) |worker| if (worker.failure) |err| return err;
    try std.testing.expectEqual(@as(usize, 0), forbidden);
}

test "backend atomics: guards and unused trapping loads precede writes" {
    if (!native.supported) return error.SkipZigTest;
    const graph: ir.Graph = .{ .types = &.{ .i32, .i64, .i64, .i64 }, .argument_types = &.{ .i32, .i64, .i64 }, .result_types = &.{.i64}, .memory_count = 1, .blocks = &.{.{ .params = &.{ 0, 1, 2 }, .nodes = &.{
        .{ .op = .guard, .lhs = 0, .exit = .{ .id = 9, .values = &.{} } },
        .{ .op = .atomic_load, .out = 3, .lhs = 1, .memory = .{ .width = .double }, .trap_site = 10 },
        .{ .op = .atomic_store, .lhs = 2, .rhs = 1, .memory = .{ .width = .double }, .trap_site = 11 },
    }, .terminator = .{ .return_ = &.{1} } }} };
    var owner = try CodeAllocator.init(a, 64 * 1024);
    defer owner.deinit();
    var code = try native.compile(a, &owner, graph);
    defer code.deinit();
    var cell: u64 = 42;
    const views = [_]native.MemoryView{native.MemoryView.fromSlice(std.mem.asBytes(&cell))};
    var guard = try code.runOutcomeWithMemory(&.{ 0, 1, 0 }, &views, 1);
    defer guard.deinit();
    try std.testing.expectEqual(@as(u32, 9), guard.exited.id);
    var trap = try code.runOutcomeWithMemory(&.{ 1, 8, 0 }, &views, 1);
    defer trap.deinit();
    try std.testing.expectEqual(ir.Trap{ .reason = .memory_out_of_bounds, .site = 10 }, trap.trapped);
    try std.testing.expectEqual(@as(u64, 42), cell);
}

fn compileWithFailures(allocator: std.mem.Allocator, owner: *CodeAllocator) !void {
    var fixture = Fixture.init(.atomic_compare_exchange, .i64, .double);
    var code = try native.compile(allocator, owner, fixture.graph());
    defer code.deinit();
    var cell: u64 = 0;
    const views = [_]native.MemoryView{native.MemoryView.fromSlice(std.mem.asBytes(&cell))};
    var values: [5]u64 = undefined;
    var result = try code.runInto(&.{ 0, 42, 0, 13 }, &views, 1, null, &values);
    defer result.deinit();
    try std.testing.expect(result == .returned);
    try std.testing.expectEqual(@as(u64, 42), cell);
}

test "backend atomics: compilation and execution clean up allocation failures" {
    if (!native.supported) return error.SkipZigTest;
    var owner = try CodeAllocator.init(a, 64 * 1024);
    defer owner.deinit();
    try std.testing.checkAllAllocationFailures(a, compileWithFailures, .{&owner});
}
