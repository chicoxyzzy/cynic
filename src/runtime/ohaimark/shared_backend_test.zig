const std = @import("std");
const shared = @import("shared_backend.zig");
const chunk_mod = @import("../../bytecode/chunk.zig");
const Op = @import("../../bytecode/op.zig").Op;
const Span = @import("../../source.zig").Span;
const Value = @import("../value.zig").Value;
const Realm = @import("../realm.zig").Realm;
const a = std.testing.allocator;
const span: Span = .{ .start = 0, .end = 1 };

fn binaryChunk(op: Op) !chunk_mod.Chunk {
    var builder = chunk_mod.Builder.init(a);
    defer builder.deinit();
    const lhs = try builder.reserveRegister();
    const rhs = try builder.reserveRegister();
    try builder.emitLoadReg(span, rhs);
    try builder.emitBinary(op, span, lhs);
    try builder.emitOp(.return_, span);
    return builder.finish();
}

test "shared Ohaimark backend: checked integer arithmetic executes natively" {
    if (!shared.supported) return error.SkipZigTest;
    var owner = try shared.CodeAllocator.init(a, 256 * 1024);
    defer owner.deinit();
    for ([_]struct { op: Op, expected: i32 }{
        .{ .op = .add, .expected = 9 }, .{ .op = .sub, .expected = 5 }, .{ .op = .mul, .expected = 14 },
    }) |case| {
        var chunk = try binaryChunk(case.op);
        defer chunk.deinit(a);
        var program = try shared.Program.build(a, &owner, &chunk);
        defer program.deinit();
        var outcome = try program.run(.{ .accumulator = Value.undefined_, .registers = &.{ Value.fromInt32(7), Value.fromInt32(2) }, .block_budget = 100 });
        defer outcome.deinit();
        try std.testing.expect(outcome == .returned);
        try std.testing.expectEqual(Value.fromInt32(case.expected).bits, outcome.returned.bits);
    }
}

test "shared Ohaimark backend: overflow reconstructs the exact intermediate frame" {
    if (!shared.supported) return error.SkipZigTest;
    var builder = chunk_mod.Builder.init(a);
    defer builder.deinit();
    const lhs = try builder.reserveRegister();
    const rhs = try builder.reserveRegister();
    const saved = try builder.reserveRegister();
    try builder.emitLoadReg(span, lhs);
    try builder.emitBinary(.sub, span, rhs);
    try builder.emitStoreReg(span, saved);
    try builder.emitLoadReg(span, rhs);
    const failed_offset = builder.here();
    try builder.emitBinary(.add, span, lhs);
    try builder.emitBinary(.add, span, saved);
    try builder.emitOp(.return_, span);
    var chunk = try builder.finish();
    defer chunk.deinit(a);
    var owner = try shared.CodeAllocator.init(a, 256 * 1024);
    defer owner.deinit();
    var program = try shared.Program.build(a, &owner, &chunk);
    defer program.deinit();
    var outcome = try program.run(.{
        .accumulator = Value.undefined_,
        .registers = &.{ Value.fromInt32(std.math.maxInt(i32)), Value.fromInt32(1), Value.undefined_ },
        .this_value = Value.fromInt32(77),
        .block_budget = 100,
    });
    defer outcome.deinit();
    try std.testing.expect(outcome == .deopt);
    const state = &outcome.deopt;
    try std.testing.expectEqual(failed_offset, state.bytecode_offset);
    try std.testing.expectEqual(Value.fromInt32(1).bits, state.accumulator.bits);
    try std.testing.expectEqual(Value.fromInt32(-2147483646).bits, state.registers[saved].bits);
    try std.testing.expectEqual(Value.fromInt32(77).bits, state.this_value.bits);
    var realm = Realm.init(a);
    defer realm.deinit();
    realm.jit_enabled = false;
    const result = try state.resumeLantern(a, &realm, &chunk);
    try std.testing.expect(result == .value);
    try std.testing.expectEqual(@as(f64, 2), if (result.value.isInt32()) @as(f64, @floatFromInt(result.value.asInt32())) else result.value.asDouble());
}

test "shared Ohaimark backend: negative zero and unexpected operands deopt before arithmetic" {
    if (!shared.supported) return error.SkipZigTest;
    var chunk = try binaryChunk(.mul);
    defer chunk.deinit(a);
    var owner = try shared.CodeAllocator.init(a, 256 * 1024);
    defer owner.deinit();
    var program = try shared.Program.build(a, &owner, &chunk);
    defer program.deinit();
    var realm = Realm.init(a);
    defer realm.deinit();
    realm.jit_enabled = false;
    for ([_]struct { lhs: Value, rhs: Value, expected: Value }{
        .{ .lhs = Value.fromInt32(-1), .rhs = Value.fromInt32(0), .expected = Value.fromDouble(-0.0) },
        .{ .lhs = Value.fromInt32(0), .rhs = Value.fromInt32(-1), .expected = Value.fromDouble(-0.0) },
        .{ .lhs = Value.fromDouble(-0.0), .rhs = Value.fromInt32(3), .expected = Value.fromDouble(-0.0) },
        .{ .lhs = Value.fromDouble(1.5), .rhs = Value.fromInt32(3), .expected = Value.fromDouble(4.5) },
    }) |case| {
        var outcome = try program.run(.{ .accumulator = Value.undefined_, .registers = &.{ case.lhs, case.rhs }, .block_budget = 100 });
        defer outcome.deinit();
        try std.testing.expect(outcome == .deopt);
        try std.testing.expectEqual(case.rhs.bits, outcome.deopt.accumulator.bits);
        try std.testing.expectEqual(case.lhs.bits, outcome.deopt.registers[0].bits);
        const result = try outcome.deopt.resumeLantern(a, &realm, &chunk);
        try std.testing.expect(result == .value);
        try std.testing.expectEqual(case.expected.bits, result.value.bits);
    }
}

test "shared Ohaimark backend: integer boundaries match Lantern without wrapping" {
    if (!shared.supported) return error.SkipZigTest;
    var owner = try shared.CodeAllocator.init(a, 256 * 1024);
    defer owner.deinit();
    var realm = Realm.init(a);
    defer realm.deinit();
    const min = std.math.minInt(i32);
    const max = std.math.maxInt(i32);
    for ([_]Op{ .add, .sub, .mul }) |op| {
        var chunk = try binaryChunk(op);
        defer chunk.deinit(a);
        var program = try shared.Program.build(a, &owner, &chunk);
        defer program.deinit();
        for ([_][2]i32{ .{ min, -1 }, .{ min, 1 }, .{ max, max }, .{ max, 1 }, .{ -46341, 46341 }, .{ -3, -7 } }) |pair| {
            const registers = [_]Value{ Value.fromInt32(pair[0]), Value.fromInt32(pair[1]) };
            var reference: @import("evaluator.zig").DeoptState = .{
                .allocator = a,
                .node = 0,
                .bytecode_offset = 0,
                .accumulator = Value.undefined_,
                .registers = try a.dupe(Value, &registers),
                .this_value = Value.undefined_,
            };
            defer reference.deinit();
            const expected = try reference.resumeLantern(a, &realm, &chunk);
            var outcome = try program.run(.{ .accumulator = Value.undefined_, .registers = &registers, .block_budget = 100 });
            defer outcome.deinit();
            try std.testing.expectEqual(expected.value.isInt32(), outcome == .returned);
            const actual = switch (outcome) {
                .returned => |value| value,
                .deopt => |*state| (try state.resumeLantern(a, &realm, &chunk)).value,
            };
            try std.testing.expectEqual(expected.value.bits, actual.bits);
        }
    }
}

test "shared Ohaimark backend: branch selection and truthiness fallback" {
    if (!shared.supported) return error.SkipZigTest;
    var builder = chunk_mod.Builder.init(a);
    defer builder.deinit();
    const condition = try builder.reserveRegister();
    try builder.emitLoadReg(span, condition);
    try builder.emitOp(.jmp_if_false, span);
    const patch = builder.here();
    try builder.emitI16(0);
    try builder.emitLoadSmi(span, 11);
    try builder.emitOp(.return_, span);
    try builder.patchI16(patch, builder.here());
    try builder.emitLoadSmi(span, 22);
    try builder.emitOp(.return_, span);
    var chunk = try builder.finish();
    defer chunk.deinit(a);
    var owner = try shared.CodeAllocator.init(a, 256 * 1024);
    defer owner.deinit();
    var program = try shared.Program.build(a, &owner, &chunk);
    defer program.deinit();
    for ([_]Value{ Value.true_, Value.fromInt32(1), Value.false_, Value.fromInt32(0) }, 0..) |condition_value, i| {
        var outcome = try program.run(.{ .accumulator = Value.undefined_, .registers = &.{condition_value}, .block_budget = 100 });
        defer outcome.deinit();
        try std.testing.expect(outcome == .returned);
        try std.testing.expectEqual(Value.fromInt32(if (i < 2) 11 else 22).bits, outcome.returned.bits);
    }
    var outcome = try program.run(.{ .accumulator = Value.undefined_, .registers = &.{Value.null_}, .block_budget = 100 });
    defer outcome.deinit();
    try std.testing.expect(outcome == .deopt);
    var realm = Realm.init(a);
    defer realm.deinit();
    realm.jit_enabled = false;
    const result = try outcome.deopt.resumeLantern(a, &realm, &chunk);
    try std.testing.expectEqual(Value.fromInt32(22).bits, result.value.bits);
    try std.testing.expectError(error.BudgetExhausted, program.run(.{ .accumulator = Value.undefined_, .registers = &.{Value.true_}, .block_budget = 0 }));
}

test "shared Ohaimark backend: unsupported operations refuse explicitly" {
    var chunk = try binaryChunk(.div);
    defer chunk.deinit(a);
    if (!shared.supported) return error.SkipZigTest;
    var owner = try shared.CodeAllocator.init(a, 64 * 1024);
    defer owner.deinit();
    try std.testing.expectError(error.UnsupportedNode, shared.Program.build(a, &owner, &chunk));
}

test "shared Ohaimark backend: comparison inversion and non-number recovery" {
    if (!shared.supported) return error.SkipZigTest;
    var realm = Realm.init(a);
    defer realm.deinit();
    var owner = try shared.CodeAllocator.init(a, 256 * 1024);
    defer owner.deinit();
    for ([_]Op{ .lt, .gt, .ge, .strict_eq, .strict_neq }) |op| {
        var chunk = try binaryChunk(op);
        defer chunk.deinit(a);
        var program = try shared.Program.build(a, &owner, &chunk);
        defer program.deinit();
        for ([_]Value{ Value.fromInt32(-7), Value.fromInt32(2), Value.fromInt32(9), Value.null_, Value.fromDouble(std.math.nan(f64)) }) |lhs| {
            const registers = [_]Value{ lhs, Value.fromInt32(2) };
            var reference: @import("evaluator.zig").DeoptState = .{
                .allocator = a,
                .node = 0,
                .bytecode_offset = 0,
                .accumulator = Value.undefined_,
                .registers = try a.dupe(Value, &registers),
                .this_value = Value.undefined_,
            };
            defer reference.deinit();
            const expected = try reference.resumeLantern(a, &realm, &chunk);
            var outcome = try program.run(.{ .accumulator = Value.undefined_, .registers = &registers, .block_budget = 100 });
            defer outcome.deinit();
            try std.testing.expectEqual(lhs.isInt32(), outcome == .returned);
            const actual = switch (outcome) {
                .returned => |value| value,
                .deopt => |*state| (try state.resumeLantern(a, &realm, &chunk)).value,
            };
            try std.testing.expectEqual(expected.value.bits, actual.bits);
        }
    }
}

test "shared Ohaimark backend: primitive constants run but heap constants refuse" {
    if (!shared.supported) return error.SkipZigTest;
    var realm = Realm.init(a);
    defer realm.deinit();
    const object = try realm.heap.allocateObject();
    var owner = try shared.CodeAllocator.init(a, 64 * 1024);
    defer owner.deinit();
    for ([_]Value{ Value.fromDouble(-0.0), @import("../heap.zig").taggedObject(object) }) |constant| {
        var builder = chunk_mod.Builder.init(a);
        defer builder.deinit();
        const index = try builder.addConstant(constant);
        try builder.emitOp(.lda_constant, span);
        try builder.emitU16(index);
        try builder.emitOp(.return_, span);
        var chunk = try builder.finish();
        defer chunk.deinit(a);
        if (constant.isHeapValue()) {
            try std.testing.expectError(error.UnsupportedNode, shared.Program.build(a, &owner, &chunk));
            continue;
        }
        var program = try shared.Program.build(a, &owner, &chunk);
        defer program.deinit();
        var outcome = try program.run(.{ .accumulator = Value.undefined_, .registers = &.{}, .block_budget = 1 });
        defer outcome.deinit();
        try std.testing.expectEqual(Value.fromDouble(-0.0).bits, outcome.returned.bits);
        try std.testing.expectError(error.ArgumentCount, program.run(.{ .accumulator = Value.undefined_, .registers = &.{Value.null_}, .block_budget = 1 }));
        try std.testing.expectError(error.PrototypeLimit, program.run(.{ .accumulator = Value.undefined_, .registers = &.{}, .block_budget = 1_000_001 }));
    }
}

test "shared Ohaimark backend: parsed JS loop matches Lantern and resumes loop overflow" {
    if (!shared.supported) return error.SkipZigTest;
    const parser = @import("../../parser/parser.zig");
    const compiler = @import("../../bytecode/compiler.zig");
    const evaluator = @import("evaluator.zig");
    var realm = Realm.init(a);
    defer realm.deinit();
    realm.jit_enabled = false;
    const source = "function sum(n) { var i = 0, s = 0; while (i < n) { s = s + i * i; i = i + 1; } return s; }";
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const parsed = try parser.parseScript(arena.allocator(), source, null);
    var outer = try compiler.compileScriptAsChunk(a, &realm, &parsed, source, null);
    defer outer.deinit(a);
    const chunk = &outer.function_templates[0].chunk;
    var owner = try shared.CodeAllocator.init(a, 256 * 1024);
    defer owner.deinit();
    var program = try shared.Program.build(a, &owner, chunk);
    defer program.deinit();
    const registers = try a.alloc(Value, chunk.register_count);
    defer a.free(registers);
    for ([_]i32{ 0, 1, 10, 1000, 2000 }) |n| {
        @memset(registers, Value.undefined_);
        registers[0] = Value.fromInt32(n);
        var reference: evaluator.DeoptState = .{ .allocator = a, .node = 0, .bytecode_offset = 0, .accumulator = Value.undefined_, .registers = try a.dupe(Value, registers), .this_value = Value.undefined_ };
        defer reference.deinit();
        const expected = try reference.resumeLantern(a, &realm, chunk);
        var outcome = try program.run(.{ .accumulator = Value.undefined_, .registers = registers, .block_budget = 10000 });
        defer outcome.deinit();
        const actual = switch (outcome) {
            .returned => |value| blk: {
                try std.testing.expect(n < 2000);
                break :blk value;
            },
            .deopt => |*state| blk: {
                try std.testing.expectEqual(@as(i32, 2000), n);
                try std.testing.expect(state.bytecode_offset > 0);
                break :blk (try state.resumeLantern(a, &realm, chunk)).value;
            },
        };
        try std.testing.expectEqual(expected.value.bits, actual.bits);
    }
}

fn buildAndRunWithFailures(allocator: std.mem.Allocator, owner: *shared.CodeAllocator, chunk: *const chunk_mod.Chunk) !void {
    var program = try shared.Program.build(allocator, owner, chunk);
    defer program.deinit();
    var outcome = try program.run(.{ .accumulator = Value.undefined_, .registers = &.{ Value.fromInt32(-1), Value.fromInt32(0) }, .block_budget = 100 });
    defer outcome.deinit();
    try std.testing.expect(outcome == .deopt);
}

test "shared Ohaimark backend: compilation and recovery clean up allocation failures" {
    if (!shared.supported) return error.SkipZigTest;
    var chunk = try binaryChunk(.mul);
    defer chunk.deinit(a);
    var owner = try shared.CodeAllocator.init(a, 256 * 1024);
    defer owner.deinit();
    try std.testing.checkAllAllocationFailures(a, buildAndRunWithFailures, .{ &owner, &chunk });
}

test "shared Ohaimark backend: object coercion only runs after recovery and survives GC" {
    if (!shared.supported) return error.SkipZigTest;
    const heap = @import("../heap.zig");
    const Callback = struct {
        fn valueOf(realm: *Realm, this_value: Value, _: []const Value) @import("../function.zig").NativeError!Value {
            realm.collectGarbage();
            const object = @import("../intrinsics.zig").objectFromThis(this_value) orelse return Value.undefined_;
            try object.set(realm.allocator, "calls", Value.fromInt32(1));
            return object.get("marker");
        }
    };
    var realm = Realm.init(a);
    defer realm.deinit();
    try realm.installBuiltins();
    realm.jit_enabled = false;
    var chunk = try binaryChunk(.add);
    defer chunk.deinit(a);
    var owner = try shared.CodeAllocator.init(a, 256 * 1024);
    defer owner.deinit();
    var program = try shared.Program.build(a, &owner, &chunk);
    defer program.deinit();
    const object = try realm.heap.allocateObject();
    const callback = try realm.heap.allocateFunctionNative(&realm, Callback.valueOf, 0, "valueOf");
    try object.set(a, "valueOf", heap.taggedFunction(callback));
    try object.set(a, "marker", Value.fromInt32(7));
    try object.set(a, "calls", Value.fromInt32(0));
    var outcome = try program.run(.{ .accumulator = Value.undefined_, .registers = &.{ heap.taggedObject(object), Value.fromInt32(2) }, .block_budget = 100 });
    defer outcome.deinit();
    try std.testing.expect(outcome == .deopt);
    try std.testing.expectEqual(Value.fromInt32(0).bits, object.get("calls").bits);
    const result = try outcome.deopt.resumeLantern(a, &realm, &chunk);
    try std.testing.expect(result == .value);
    try std.testing.expectEqual(Value.fromInt32(9).bits, result.value.bits);
    try std.testing.expectEqual(Value.fromInt32(1).bits, object.get("calls").bits);
}
