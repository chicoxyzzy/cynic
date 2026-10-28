const std = @import("std");
const builtin = @import("builtin");
const ir = @import("ir.zig");
const native = @import("native.zig");
const code_alloc = @import("../code_alloc.zig");
const arm = @import("../asm_aarch64.zig");
const arm_masm = @import("../masm.zig");
const x86 = @import("../asm_x86_64.zig");
const a = std.testing.allocator;
const is_x86 = builtin.cpu.arch == .x86_64;
const Machine = if (is_x86) x86.Masm else arm_masm.Masm;
const State = extern struct { control: u64 = 0, status: u64 = 0 };
const ReadState = *const fn (*State) callconv(.c) void;
const WriteState = *const fn (*const State) callconv(.c) void;
const Entry = *const fn ([*]u64, u64) callconv(.c) u32;

fn isRosetta() bool {
    if (comptime builtin.os.tag != .macos or !is_x86) return false;
    var translated: c_int = 0;
    var size: usize = @sizeOf(c_int);
    return std.c.sysctlbyname("sysctl.proc_translated", &translated, &size, null, 0) == 0 and translated == 1;
}

const Probe = struct {
    read_code: code_alloc.InstalledCode,
    write_code: code_alloc.InstalledCode,
    supports_daz: bool = false,

    fn init(owner: *code_alloc.CodeAllocator) !Probe {
        var reader = Machine.init(a);
        defer reader.deinit();
        var writer = Machine.init(a);
        defer writer.deinit();
        if (comptime is_x86) {
            try reader.storeMxcsr(.rdi, 0);
            try reader.ret();
            try writer.loadMxcsr(.rdi, 0);
            try writer.ret();
        } else {
            try reader.emit(arm.readFpcr(.x16));
            try reader.emit(arm.strImm(.x16, .x0, 0));
            try reader.emit(arm.readFpsr(.x16));
            try reader.emit(arm.strImm(.x16, .x0, 8));
            try reader.emit(arm.ret());
            try writer.emit(arm.ldrImm(.x16, .x0, 8));
            try writer.emit(arm.writeFpsr(.x16));
            try writer.emit(arm.ldrImm(.x16, .x0, 0));
            try writer.emit(arm.writeFpcr(.x16));
            try writer.emit(arm.ret());
        }
        var read_code = try owner.installOwned(reader.code.items);
        errdefer read_code.deinit();
        var write_code = try owner.installOwned(writer.code.items);
        errdefer write_code.deinit();
        var supports_daz = false;
        if (comptime is_x86) {
            // FXSAVE [rdi]; RET. MXCSR_MASK is at byte 28. Do not set DAZ
            // on older SSE2 CPUs that do not advertise it as writable.
            var mask_code = try owner.installOwned(&.{ 0x0f, 0xae, 0x07, 0xc3 });
            defer mask_code.deinit();
            var state: [512]u8 align(16) = @splat(0);
            const save: *const fn (*[512]u8) callconv(.c) void = @ptrCast(@alignCast(mask_code.entry().?));
            save(&state);
            supports_daz = std.mem.readInt(u32, state[28..32], .little) & 0x40 != 0;
        }
        return .{ .read_code = read_code, .write_code = write_code, .supports_daz = supports_daz };
    }

    fn deinit(self: *Probe) void {
        self.read_code.deinit();
        self.write_code.deinit();
    }

    fn read(self: *const Probe) State {
        var state: State = .{};
        const entry: ReadState = @ptrCast(@alignCast(self.read_code.entry().?));
        entry(&state);
        return state;
    }

    fn write(self: *const Probe, state: *const State) void {
        const entry: WriteState = @ptrCast(@alignCast(self.write_code.entry().?));
        entry(state);
    }

    fn unusual(self: *const Probe, rounding: u2) State {
        return if (is_x86)
            .{ .control = 0x9f95 | (@as(u64, rounding) << 13) | (if (self.supports_daz) @as(u64, 0x40) else 0) }
        else
            // Include optional AH/FIZ/NEP and unrelated half-precision controls.
            // Assertions compare hardware readback, not unsupported writable bits.
            .{ .control = 7 | (1 << 19) | (@as(u64, rounding) << 22) | (1 << 24) | (1 << 25) | (1 << 26), .status = 0x15 };
    }
};

const Observation = struct { before: State, after: State, status: u32, result: [2]u64, captures: [ir.max_arguments]u64 };

fn observe(probe: *const Probe, code: *const native.Compiled, requested: State, args: []const u64, budget: u32) !Observation {
    return observeWithMemory(probe, code, requested, args, &.{}, budget);
}

fn observeWithMemory(probe: *const Probe, code: *const native.Compiled, requested: State, args: []const u64, views: []const native.MemoryView, budget: u32) !Observation {
    try std.testing.expectEqual(code.memory_count, views.len);
    try std.testing.expectEqual(@as(usize, 1), code.result_types.len);
    const slots = try a.alloc(u64, code.scratchSlotCount());
    defer a.free(slots);
    @memset(slots, 0);
    if (code.memory_count != 0) slots[code.scratchSlotCount() - 1] = @intFromPtr(views.ptr);
    for (args, code.argument_types, 0..) |arg, ty, i| slots[code.spill_slot_count + i] = ir.normalize(ty, arg);
    const entry: Entry = @ptrCast(@alignCast(code.code.entry().?));
    const original = probe.read();
    defer probe.write(&original);
    probe.write(&requested);
    const before = probe.read();
    const status = entry(slots.ptr, budget);
    const after = probe.read();
    // Restore before the allocator, assertions, or test diagnostics can run.
    probe.write(&original);
    const base = code.spill_slot_count + @as(usize, if (status == 0) 0 else ir.max_arguments);
    return .{ .before = before, .after = after, .status = status, .result = if (status == 0) .{ slots[base], 0 } else slots[base..][0..2].*, .captures = slots[code.spill_slot_count..][0..ir.max_arguments].* };
}

test "backend FP environment: direct native entry ignores caller rounding and flush modes" {
    if (!native.supported) return error.SkipZigTest;
    var owner = try code_alloc.CodeAllocator.init(a, 256 * 1024);
    defer owner.deinit();
    var probe = try Probe.init(&owner);
    defer probe.deinit();
    for ([_]ir.Type{ .f32, .f64 }) |ty| for ([_]ir.Op{ .fadd, .fmul }) |op| {
        const graph: ir.Graph = .{ .types = &.{ ty, ty, ty }, .argument_types = &.{ ty, ty }, .result_types = &.{ty}, .blocks = &.{.{ .params = &.{ 0, 1 }, .nodes = &.{.{ .op = op, .out = 2, .lhs = 0, .rhs = 1 }}, .terminator = .{ .return_ = &.{2} } }} };
        var code = try native.compile(a, &owner, graph);
        defer code.deinit();
        const one: u64 = if (ty == .f32) 0x3f80_0000 else 0x3ff0_0000_0000_0000;
        const quarter_ulp: u64 = if (ty == .f32) 0x3300_0000 else 0x3c90_0000_0000_0000;
        const min_normal: u64 = if (ty == .f32) 0x0080_0000 else 0x0010_0000_0000_0000;
        const half: u64 = if (ty == .f32) 0x3f00_0000 else 0x3fe0_0000_0000_0000;
        const sign: u64 = if (ty == .f32) 0x8000_0000 else 0x8000_0000_0000_0000;
        for (0..4) |mode| for ([_]u64{ 0, sign }) |negative| {
            const observed = try observe(&probe, &code, probe.unusual(@intCast(mode)), &.{ (if (op == .fadd) one else min_normal) | negative, if (op == .fadd) quarter_ulp | negative else half }, 1);
            try std.testing.expectEqual(@as(u32, 0), observed.status);
            try std.testing.expectEqual((if (op == .fadd) one else min_normal >> 1) | negative, observed.result[0]);
            try std.testing.expectEqualDeep(observed.before, observed.after);
        };
        if (op == .fadd) {
            const observed = try observe(&probe, &code, probe.unusual(3), &.{ 1, 1 }, 1);
            try std.testing.expectEqual(@as(u64, 2), observed.result[0]);
            try std.testing.expectEqualDeep(observed.before, observed.after);
        }
    };
}

test "backend FP environment: native return preserves incoming sticky exception flags" {
    if (!native.supported) return error.SkipZigTest;
    var owner = try code_alloc.CodeAllocator.init(a, 256 * 1024);
    defer owner.deinit();
    var probe = try Probe.init(&owner);
    defer probe.deinit();
    const graph: ir.Graph = .{ .types = &.{ .f64, .f64, .f64 }, .argument_types = &.{ .f64, .f64 }, .result_types = &.{.f64}, .blocks = &.{.{ .params = &.{ 0, 1 }, .nodes = &.{.{ .op = .fdiv, .out = 2, .lhs = 0, .rhs = 1 }}, .terminator = .{ .return_ = &.{2} } }} };
    var code = try native.compile(a, &owner, graph);
    defer code.deinit();
    const observed = try observe(&probe, &code, probe.unusual(0), &.{ 0x3ff0_0000_0000_0000, 0 }, 1);
    try std.testing.expectEqual(@as(u64, 0x7ff0_0000_0000_0000), observed.result[0]);
    try std.testing.expectEqualDeep(observed.before, observed.after);
}

test "backend FP environment: enabled hardware exceptions cannot escape native arithmetic" {
    if (!native.supported) return error.SkipZigTest;
    var owner = try code_alloc.CodeAllocator.init(a, 256 * 1024);
    defer owner.deinit();
    var probe = try Probe.init(&owner);
    defer probe.deinit();
    const translated = isRosetta();
    var hardware_exceptions_unavailable = false;
    for ([_]ir.Type{ .f32, .f64 }) |ty| {
        const one: u64 = if (ty == .f32) 0x3f80_0000 else 0x3ff0_0000_0000_0000;
        const two: u64 = if (ty == .f32) 0x4000_0000 else 0x4000_0000_0000_0000;
        const three: u64 = if (ty == .f32) 0x4040_0000 else 0x4008_0000_0000_0000;
        const half: u64 = if (ty == .f32) 0x3f00_0000 else 0x3fe0_0000_0000_0000;
        const infinity: u64 = if (ty == .f32) 0x7f80_0000 else 0x7ff0_0000_0000_0000;
        const quiet: u64 = if (ty == .f32) 0x0040_0000 else 0x0008_0000_0000_0000;
        const Case = struct { op: ir.Op, lhs: u64, rhs: u64, expected: ?u64 };
        for ([_]Case{
            .{ .op = .fdiv, .lhs = one, .rhs = 0, .expected = infinity },
            .{ .op = .fdiv, .lhs = 0, .rhs = 0, .expected = null },
            .{ .op = .fadd, .lhs = infinity | 1, .rhs = one, .expected = null },
            .{ .op = .fmul, .lhs = infinity - 1, .rhs = two, .expected = infinity },
            .{ .op = .fmul, .lhs = 1, .rhs = half, .expected = 0 },
            .{ .op = .fdiv, .lhs = one, .rhs = three, .expected = if (ty == .f32) 0x3eaa_aaab else 0x3fd5_5555_5555_5555 },
        }) |case| {
            const graph: ir.Graph = .{ .types = &.{ ty, ty, ty }, .argument_types = &.{ ty, ty }, .result_types = &.{ty}, .blocks = &.{.{ .params = &.{ 0, 1 }, .nodes = &.{.{ .op = case.op, .out = 2, .lhs = 0, .rhs = 1 }}, .terminator = .{ .return_ = &.{2} } }} };
            var code = try native.compile(a, &owner, graph);
            defer code.deinit();
            var requested = probe.unusual(1);
            if (is_x86) requested.control &= ~@as(u64, 0x1f80) else requested.control |= 0x9f00;
            const observed = try observe(&probe, &code, requested, &.{ case.lhs, case.rhs }, 1);
            if (is_x86) {
                if (translated and observed.before.control & 0x1f80 != 0) {
                    hardware_exceptions_unavailable = true;
                } else try std.testing.expectEqual(@as(u64, 0), observed.before.control & 0x1f80);
            } else if (observed.before.control & 0x1f00 != 0x1f00) {
                // Arm exception trapping is optional; unsupported enable bits
                // read as zero. Rosetta can likewise force all MXCSR masks on.
                hardware_exceptions_unavailable = true;
            }
            try std.testing.expectEqual(@as(u32, 0), observed.status);
            if (case.expected) |expected| {
                try std.testing.expectEqual(expected, observed.result[0]);
            } else {
                try std.testing.expectEqual(infinity | quiet, observed.result[0] & (infinity | quiet));
            }
            try std.testing.expectEqualDeep(observed.before, observed.after);
        }
    }
    // Arithmetic and restoration still ran above, but do not count them as
    // proof of protection from hardware exceptions if traps could not be enabled.
    if (hardware_exceptions_unavailable) return error.SkipZigTest;
}

test "backend FP environment: every guard trap and return restores caller state" {
    if (!native.supported) return error.SkipZigTest;
    var owner = try code_alloc.CodeAllocator.init(a, 256 * 1024);
    defer owner.deinit();
    var probe = try Probe.init(&owner);
    defer probe.deinit();
    const one = 0x3ff0_0000_0000_0000;
    const two = 0x4000_0000_0000_0000;
    const infinity = 0x7ff0_0000_0000_0000;
    const Case = struct { args: [5]u64, status: u32, result: [2]u64 };
    for ([_]bool{ false, true }) |terminal_trap| {
        const graph: ir.Graph = .{
            .types = &.{ .i32, .f64, .f64, .i64, .i64, .f64, .i32, .i64 },
            .argument_types = &.{ .i32, .f64, .f64, .i64, .i64 },
            .result_types = &.{.f64},
            .blocks = &.{.{ .params = &.{ 0, 1, 2, 3, 4 }, .nodes = &.{
                .{ .op = .fdiv, .out = 5, .lhs = 1, .rhs = 2 },
                .{ .op = .guard, .lhs = 0, .exit = .{ .id = 10, .values = &.{ 5, 3, 4 } } },
                .{ .op = .trunc_s, .out = 6, .lhs = 5, .trap_site = 77 },
                .{ .op = .div_s, .out = 7, .lhs = 3, .rhs = 4, .trap_site = 88 },
            }, .terminator = if (terminal_trap) .{ .trap = .{ .reason = .unreachable_code, .site = 99 } } else .{ .return_ = &.{5} } }},
        };
        for (0..16) |flags| for ([_]u8{ 0, 1, 4 }) |registers| {
            var code = try native.compileWithOptions(a, &owner, graph, .{ .register_count = registers, .rematerialize_constants = flags & 8 != 0, .optimization = .{ .constant_folding = flags & 1 != 0, .common_subexpression_elimination = flags & 2 != 0, .dead_code_elimination = flags & 4 != 0 } });
            defer code.deinit();
            for ([_]Case{
                .{ .args = .{ 0, one, 0, 12, 13 }, .status = 2, .result = .{ 10, 3 } },
                .{ .args = .{ 1, 0, 0, 1, 1 }, .status = 3, .result = .{ 4, 77 } },
                .{ .args = .{ 1, one, 0, 1, 1 }, .status = 3, .result = .{ 2, 77 } },
                .{ .args = .{ 1, two, one, 1, 0 }, .status = 3, .result = .{ 1, 88 } },
                .{ .args = .{ 1, two, one, 0x8000_0000_0000_0000, 0xffff_ffff_ffff_ffff }, .status = 3, .result = .{ 2, 88 } },
                .{ .args = .{ 1, two, one, 1, 1 }, .status = if (terminal_trap) 3 else 0, .result = if (terminal_trap) .{ 3, 99 } else .{ two, 0 } },
            }) |case| {
                const observed = try observe(&probe, &code, probe.unusual(@intCast(flags % 4)), &case.args, 1);
                try std.testing.expectEqual(case.status, observed.status);
                try std.testing.expectEqualDeep(case.result, observed.result);
                if (case.status == 2) try std.testing.expectEqualSlices(u64, &.{ infinity, 12, 13 }, observed.captures[0..3]);
                try std.testing.expectEqualDeep(observed.before, observed.after);
            }
            const exhausted = try observe(&probe, &code, probe.unusual(2), &.{ 0, one, 0, 0, 0 }, 0);
            try std.testing.expectEqual(@as(u32, 1), exhausted.status);
            try std.testing.expectEqualDeep(exhausted.before, exhausted.after);
        };
    }
}

test "backend FP environment: loop exhaustion restores state after repeated backedges" {
    if (!native.supported) return error.SkipZigTest;
    var owner = try code_alloc.CodeAllocator.init(a, 256 * 1024);
    defer owner.deinit();
    var probe = try Probe.init(&owner);
    defer probe.deinit();
    const graph: ir.Graph = .{ .types = &.{ .f64, .f64, .f64 }, .argument_types = &.{.f64}, .result_types = &.{.f64}, .blocks = &.{
        .{ .params = &.{0}, .nodes = &.{}, .terminator = .{ .jump = .{ .target = 1, .args = &.{0} } } },
        .{ .params = &.{1}, .nodes = &.{.{ .op = .fadd, .out = 2, .lhs = 1, .rhs = 1 }}, .terminator = .{ .jump = .{ .target = 1, .args = &.{2} } } },
    } };
    var code = try native.compile(a, &owner, graph);
    defer code.deinit();
    for ([_]u32{ 1, 2, 5, 100 }) |budget| {
        const observed = try observe(&probe, &code, probe.unusual(1), &.{0x7fef_ffff_ffff_ffff}, budget);
        try std.testing.expectEqual(@as(u32, 1), observed.status);
        try std.testing.expectEqualDeep(observed.before, observed.after);
    }
}

test "backend FP environment: conversions normalize rounding without arithmetic nodes" {
    if (!native.supported) return error.SkipZigTest;
    var owner = try code_alloc.CodeAllocator.init(a, 256 * 1024);
    defer owner.deinit();
    var probe = try Probe.init(&owner);
    defer probe.deinit();
    const Case = struct { input: ir.Type, output: ir.Type, op: ir.Op, bits: u64, expected: u64 };
    for ([_]Case{
        .{ .input = .i32, .output = .f32, .op = .convert_s, .bits = 16_777_217, .expected = 0x4b80_0000 },
        .{ .input = .i64, .output = .f64, .op = .convert_s, .bits = 9_007_199_254_740_993, .expected = 0x4340_0000_0000_0000 },
        .{ .input = .i64, .output = .f64, .op = .convert_u, .bits = 0xffff_ffff_ffff_ffff, .expected = 0x43f0_0000_0000_0000 },
        .{ .input = .f64, .output = .f32, .op = .demote_f64, .bits = 0x3ff0_0000_0800_0000, .expected = 0x3f80_0000 },
        .{ .input = .f32, .output = .f64, .op = .promote_f32, .bits = 1, .expected = 0x36a0_0000_0000_0000 },
    }) |case| {
        const graph: ir.Graph = .{ .types = &.{ case.input, case.output }, .argument_types = &.{case.input}, .result_types = &.{case.output}, .blocks = &.{.{ .params = &.{0}, .nodes = &.{.{ .op = case.op, .out = 1, .lhs = 0 }}, .terminator = .{ .return_ = &.{1} } }} };
        var code = try native.compile(a, &owner, graph);
        defer code.deinit();
        try std.testing.expect(code.uses_fp_environment);
        for (0..4) |mode| {
            const observed = try observe(&probe, &code, probe.unusual(@intCast(mode)), &.{case.bits}, 1);
            try std.testing.expectEqual(@as(u32, 0), observed.status);
            try std.testing.expectEqual(case.expected, observed.result[0]);
            try std.testing.expectEqualDeep(observed.before, observed.after);
        }
    }
}

test "backend FP environment: dead float operations and raw bits need no state storage" {
    if (!native.supported) return error.SkipZigTest;
    var owner = try code_alloc.CodeAllocator.init(a, 256 * 1024);
    defer owner.deinit();
    const graph: ir.Graph = .{ .types = &.{ .f64, .f64, .f64 }, .argument_types = &.{ .f64, .f64 }, .result_types = &.{.f64}, .blocks = &.{.{ .params = &.{ 0, 1 }, .nodes = &.{.{ .op = .fadd, .out = 2, .lhs = 0, .rhs = 1 }}, .terminator = .{ .return_ = &.{0} } }} };
    var optimized = try native.compile(a, &owner, graph);
    defer optimized.deinit();
    try std.testing.expect(!optimized.uses_fp_environment);
    try std.testing.expectEqual(optimized.spill_slot_count + ir.max_arguments + 2, optimized.scratchSlotCount());
    var unoptimized = try native.compileWithOptions(a, &owner, graph, .{ .optimization = .{ .dead_code_elimination = false } });
    defer unoptimized.deinit();
    try std.testing.expect(unoptimized.uses_fp_environment);
    try std.testing.expectEqual(unoptimized.spill_slot_count + ir.max_arguments + 4, unoptimized.scratchSlotCount());
    var probe = try Probe.init(&owner);
    defer probe.deinit();
    const observed = try observe(&probe, &optimized, probe.unusual(3), &.{ 0x7ff0_0000_0000_0001, 0 }, 1);
    try std.testing.expectEqual(@as(u64, 0x7ff0_0000_0000_0001), observed.result[0]);
    try std.testing.expectEqualDeep(observed.before, observed.after);
}

test "backend FP environment: Wasm frontend shares protected native entry" {
    if (!native.supported) return error.SkipZigTest;
    const wasm = @import("../../wasm/backend_prototype.zig");
    const fixtures = @import("../../wasm/backend_prototype_test.zig");
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    var owner = try code_alloc.CodeAllocator.init(a, 256 * 1024);
    defer owner.deinit();
    var probe = try Probe.init(&owner);
    defer probe.deinit();
    for ([_]bool{ false, true }) |single| {
        const ty: u8 = if (single) 0x7d else 0x7c;
        const bytes = try fixtures.moduleBytes(arena.allocator(), &.{ ty, ty }, ty, &.{}, &.{ 0x20, 0, 0x20, 1, if (single) 0x92 else 0xa0, 0x0b });
        var graph = try wasm.lowerModule(a, bytes, 0);
        defer graph.deinit();
        var code = try native.compile(a, &owner, graph.graph);
        defer code.deinit();
        const observed = try observe(&probe, &code, probe.unusual(2), &.{ 1, 1 }, 1);
        try std.testing.expectEqual(@as(u32, 0), observed.status);
        try std.testing.expectEqual(@as(u64, 2), observed.result[0]);
        try std.testing.expectEqualDeep(observed.before, observed.after);
    }
}

test "backend memory: floating arithmetic and memory traps use disjoint saved state" {
    if (!native.supported) return error.SkipZigTest;
    var owner = try code_alloc.CodeAllocator.init(a, 256 * 1024);
    defer owner.deinit();
    var probe = try Probe.init(&owner);
    defer probe.deinit();
    const graph: ir.Graph = .{ .types = &.{ .f64, .f64, .i64, .f64 }, .argument_types = &.{ .f64, .f64, .i64 }, .result_types = &.{.f64}, .memory_count = 1, .blocks = &.{.{ .params = &.{ 0, 1, 2 }, .nodes = &.{
        .{ .op = .fdiv, .out = 3, .lhs = 0, .rhs = 1 },
        .{ .op = .store, .lhs = 2, .rhs = 3, .memory = .{ .width = .double }, .trap_site = 77 },
    }, .terminator = .{ .return_ = &.{3} } }} };
    var code = try native.compile(a, &owner, graph);
    defer code.deinit();
    for ([_]u64{ 0, 1 }) |address| {
        var bytes: [8]u8 = @splat(0);
        const views = [_]native.MemoryView{native.MemoryView.fromSlice(&bytes)};
        const result = try observeWithMemory(&probe, &code, probe.unusual(1), &.{ 0x3ff0_0000_0000_0000, 0, address }, &views, 1);
        try std.testing.expectEqualDeep(result.before, result.after);
        try std.testing.expectEqual(@as(u32, if (address == 0) 0 else 3), result.status);
        if (address == 0) {
            try std.testing.expectEqual(@as(u64, 0x7ff0_0000_0000_0000), std.mem.readInt(u64, &bytes, .little));
        } else {
            try std.testing.expectEqualDeep([2]u64{ 5, 77 }, result.result);
            try std.testing.expectEqual(@as(u64, 0), std.mem.readInt(u64, &bytes, .little));
        }
    }
}

test "backend calls: callbacks see caller FP state and cannot leak control changes" {
    if (!native.supported) return error.SkipZigTest;
    const Host = struct {
        probe: *const Probe,
        seen: State = .{},
        changed: State,
        fail: bool,
        fn invoke(raw: ?*anyopaque, _: native.CallRequest) !void {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            self.seen = self.probe.read();
            self.probe.write(&self.changed);
            if (self.fail) return error.CallbackFailed;
        }
    };
    var owner = try code_alloc.CodeAllocator.init(a, 256 * 1024);
    defer owner.deinit();
    var probe = try Probe.init(&owner);
    defer probe.deinit();
    const graph: ir.Graph = .{ .types = &.{ .f64, .f64, .f64 }, .argument_types = &.{ .f64, .f64 }, .result_types = &.{.f64}, .blocks = &.{.{ .params = &.{ 0, 1 }, .nodes = &.{
        .{ .op = .call, .trap_site = 1, .call = .{ .target = 0, .arguments = &.{}, .parameter_types = &.{}, .results = &.{}, .result_types = &.{}, .safepoint = .{ .id = 0, .values = &.{} } } },
        .{ .op = .fadd, .out = 2, .lhs = 0, .rhs = 1 },
    }, .terminator = .{ .return_ = &.{2} } }} };
    var code = try native.compile(a, &owner, graph);
    defer code.deinit();
    const original = probe.read();
    defer probe.write(&original);
    for ([_]bool{ false, true }) |fail| {
        var host: Host = .{ .probe = &probe, .changed = probe.unusual(2), .fail = fail };
        const requested = probe.unusual(1);
        probe.write(&requested);
        const before = probe.read();
        const result = code.runOutcomeWithRuntime(&.{ 0x3ff0_0000_0000_0000, 0x3ca0_0000_0000_0000 }, &.{}, 1, .{ .context = &host, .call = Host.invoke });
        const after = probe.read();
        probe.write(&original);
        try std.testing.expectEqualDeep(before, host.seen);
        try std.testing.expectEqualDeep(before, after);
        if (fail) {
            try std.testing.expectError(error.CallbackFailed, result);
        } else {
            var outcome = try result;
            defer outcome.deinit();
            try std.testing.expectEqual(@as(u64, 0x3ff0_0000_0000_0000), outcome.returned);
        }
    }
}

test "backend calls: language runtime helpers execute with strict FP controls" {
    if (!native.supported) return error.SkipZigTest;
    const Host = struct {
        fn add(_: ?*anyopaque, request: native.CallRequest) !void {
            const lhs: f64 = @bitCast(request.arguments[0]);
            const rhs: f64 = @bitCast(request.arguments[1]);
            request.results[0] = @bitCast(lhs + rhs);
        }
    };
    const graph: ir.Graph = .{ .types = &.{ .f64, .f64, .f64 }, .argument_types = &.{ .f64, .f64 }, .result_types = &.{.f64}, .blocks = &.{.{ .params = &.{ 0, 1 }, .nodes = &.{
        .{ .op = .call, .trap_site = 0, .call = .{ .target = 0, .arguments = &.{ 0, 1 }, .parameter_types = &.{ .f64, .f64 }, .results = &.{2}, .result_types = &.{.f64}, .fp_mode = .strict, .safepoint = .{ .id = 0, .values = &.{} } } },
    }, .terminator = .{ .return_ = &.{2} } }} };
    var owner = try code_alloc.CodeAllocator.init(a, 256 * 1024);
    defer owner.deinit();
    var probe = try Probe.init(&owner);
    defer probe.deinit();
    var code = try native.compile(a, &owner, graph);
    defer code.deinit();
    const original = probe.read();
    defer probe.write(&original);
    const requested = probe.unusual(if (is_x86) 2 else 1);
    probe.write(&requested);
    const before = probe.read();
    const result = code.runOutcomeWithRuntime(&.{ 0x3ff0_0000_0000_0000, 0x3ca0_0000_0000_0000 }, &.{}, 1, .{ .call = Host.add });
    const after = probe.read();
    probe.write(&original);
    var outcome = try result;
    defer outcome.deinit();
    try std.testing.expectEqual(@as(u64, 0x3ff0_0000_0000_0000), outcome.returned);
    try std.testing.expectEqualDeep(before, after);
}
