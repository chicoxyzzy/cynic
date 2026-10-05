//! Experimental leaf backend. Values live in caller-owned bounded scratch
//! slots. No stack frame, host calls, GC, or executable-page patching. Opaque
//! frontend words may contain tagged references; the backend never dereferences them.
const std = @import("std");
const builtin = @import("builtin");
const ir = @import("ir.zig");
const code_alloc = @import("../code_alloc.zig");
const a64 = @import("../asm_aarch64.zig");
const arm_masm = @import("../masm.zig");
const x86 = @import("../asm_x86_64.zig");

pub const supported = code_alloc.supported;
pub const max_budget = 1_000_000;
const is_x86 = builtin.cpu.arch == .x86_64;
const Machine = if (is_x86) x86.Masm else arm_masm.Masm;
const Entry = *const fn ([*]u64, u64) callconv(.c) u32;

pub const Outcome = union(enum) {
    returned: u64,
    exited: struct { allocator: std.mem.Allocator, id: u32, values: []u64 },

    pub fn deinit(self: *Outcome) void {
        switch (self.*) {
            .returned => {},
            .exited => |exit| exit.allocator.free(exit.values),
        }
        self.* = undefined;
    }
};

pub const Compiled = struct {
    allocator: std.mem.Allocator,
    code: code_alloc.InstalledCode,
    params: []ir.Value,
    argument_types: []ir.Type,
    value_count: usize,

    pub fn deinit(self: *Compiled) void {
        self.code.deinit();
        self.allocator.free(self.params);
        self.allocator.free(self.argument_types);
        self.* = undefined;
    }

    pub fn run(self: *const Compiled, args: []const u64, budget: u32) !u64 {
        var outcome = try self.runOutcome(args, budget);
        defer outcome.deinit();
        return switch (outcome) {
            .returned => |value| value,
            .exited => error.UnexpectedSideExit,
        };
    }

    pub fn runOutcome(self: *const Compiled, args: []const u64, budget: u32) !Outcome {
        if (args.len != self.params.len) return error.ArgumentCount;
        if (budget > max_budget) return error.PrototypeLimit;
        const slots = try self.allocator.alloc(u64, self.value_count + ir.max_arguments + 2);
        defer self.allocator.free(slots);
        @memset(slots, 0);
        for (args, self.params, self.argument_types) |arg, param, ty| slots[param] = ir.normalize(ty, arg);
        const entry: Entry = @ptrCast(@alignCast(self.code.entry() orelse return error.MissingCode));
        const result_slot = self.value_count + ir.max_arguments;
        return switch (entry(slots.ptr, budget)) {
            0 => .{ .returned = slots[result_slot] },
            1 => error.BudgetExhausted,
            2 => blk: {
                const id = slots[result_slot];
                const count = slots[result_slot + 1];
                if (id > std.math.maxInt(u32) or count > ir.max_arguments) return error.InvalidNativeResult;
                break :blk .{ .exited = .{
                    .allocator = self.allocator,
                    .id = @intCast(id),
                    .values = try self.allocator.dupe(u64, slots[self.value_count .. self.value_count + @as(usize, @intCast(count))]),
                } };
            },
            else => error.InvalidNativeResult,
        };
    }
};

pub fn compile(a: std.mem.Allocator, owner: *code_alloc.CodeAllocator, graph: ir.Graph) !Compiled {
    try graph.verify();
    if (comptime !supported) return error.UnsupportedTarget;
    var m = Machine.init(a);
    defer m.deinit();
    const labels = try a.alloc(Machine.Label, graph.blocks.len);
    defer a.free(labels);
    @memset(labels, .{});
    defer for (labels) |*label| label.deinit(a);
    var exhausted: Machine.Label = .{};
    defer exhausted.deinit(a);
    for (graph.blocks, 0..) |block, index| {
        try m.bind(&labels[index]);
        try poll(&m, &exhausted);
        for (block.nodes) |node| {
            if (node.op == .guard) {
                var success: Machine.Label = .{};
                defer success.deinit(a);
                try load(&m, false, node.lhs);
                if (comptime is_x86) {
                    try m.testReg64(.rax, .rax);
                    try m.jumpCond(.not_equal, &success);
                } else try m.jumpCbnz(.x2, &success);
                try emitExit(&m, graph.types.len, node.exit.?);
                try m.bind(&success);
                continue;
            } else if (node.op == .constant) {
                try constant(&m, node.immediate);
            } else if (ir.isConversion(node.op)) {
                try load(&m, false, node.lhs);
                if (comptime is_x86) {
                    if (node.op == .sext_i32) try m.signExtendReg32To64(.rax, .rax) else try m.movReg32(.rax, .rax);
                } else try m.emit(if (node.op == .sext_i32) a64.sxtw(.x2, .x2) else a64.movRegW(.x2, .x2));
            } else {
                try load(&m, false, node.lhs);
                try load(&m, true, node.rhs);
                try binary(&m, node.op, graph.types[node.lhs]);
            }
            try store(&m, node.out.?);
        }
        switch (block.terminator) {
            .return_ => |value| {
                try load(&m, false, value);
                try store(&m, graph.types.len + ir.max_arguments);
                try finish(&m, 0);
            },
            .jump => |edge| try transfer(&m, graph, edge, labels),
            .branch => |branch| {
                var otherwise: Machine.Label = .{};
                defer otherwise.deinit(a);
                try load(&m, false, branch.condition);
                if (comptime is_x86) {
                    try m.testReg64(.rax, .rax);
                    try m.jumpCond(.equal, &otherwise);
                } else try m.jumpCbz(.x2, &otherwise);
                try transfer(&m, graph, branch.taken, labels);
                try m.bind(&otherwise);
                try transfer(&m, graph, branch.fallthrough, labels);
            },
        }
    }
    try m.bind(&exhausted);
    try finish(&m, 1);
    const params = try a.dupe(ir.Value, graph.blocks[0].params);
    errdefer a.free(params);
    const argument_types = try a.dupe(ir.Type, graph.argument_types);
    errdefer a.free(argument_types);
    return .{
        .allocator = a,
        .code = try owner.installOwned(m.code.items),
        .params = params,
        .argument_types = argument_types,
        .value_count = graph.types.len,
    };
}

fn emitExit(m: *Machine, value_count: usize, side_exit: ir.SideExit) !void {
    for (side_exit.values, 0..) |value, i| {
        try load(m, false, value);
        try store(m, value_count + i);
    }
    try constant(m, side_exit.id);
    try store(m, value_count + ir.max_arguments);
    try constant(m, side_exit.values.len);
    try store(m, value_count + ir.max_arguments + 1);
    try finish(m, 2);
}

fn transfer(m: *Machine, graph: ir.Graph, edge: ir.Edge, labels: []Machine.Label) !void {
    // Capture every source before assigning a destination: loop edges may
    // exchange parameters, including cycles longer than two values.
    for (edge.args, 0..) |arg, i| {
        try load(m, false, arg);
        try store(m, graph.types.len + i);
    }
    for (graph.blocks[edge.target].params, 0..) |param, i| {
        try load(m, false, graph.types.len + i);
        try store(m, param);
    }
    try m.jump(&labels[edge.target]);
}

fn load(m: *Machine, rhs: bool, slot: usize) !void {
    if (comptime is_x86) {
        try m.load64Disp32(if (rhs) .r10 else .rax, .rdi, @intCast(slot * 8));
    } else try m.emit(a64.ldrImm(if (rhs) .x3 else .x2, .x0, @intCast(slot * 8)));
}

fn store(m: *Machine, slot: usize) !void {
    if (comptime is_x86) {
        try m.store64Disp32(.rdi, @intCast(slot * 8), .rax);
    } else try m.emit(a64.strImm(.x2, .x0, @intCast(slot * 8)));
}

fn constant(m: *Machine, value: u64) !void {
    try m.movImm64(if (is_x86) .rax else .x2, value);
}

fn poll(m: *Machine, exhausted: *Machine.Label) !void {
    if (comptime is_x86) {
        try m.testReg64(.rsi, .rsi);
        try m.jumpCond(.equal, exhausted);
        try m.subRegImm32(.rsi, 1);
    } else {
        try m.jumpCbz(.x1, exhausted);
        try m.emit(a64.subImm(.x1, .x1, 1, false));
    }
}

fn finish(m: *Machine, status: u32) !void {
    if (comptime is_x86) {
        try m.movImm32(.rax, status);
        try m.ret();
    } else {
        try m.movImm64(.x0, status);
        try m.emit(a64.ret());
    }
}

fn binary(m: *Machine, op: ir.Op, ty: ir.Type) !void {
    if (comptime is_x86) {
        switch (op) {
            .add => if (ty == .i32) try m.addReg32(.rax, .r10) else try m.addReg64(.rax, .r10),
            .sub => if (ty == .i32) try m.subReg32(.rax, .r10) else try m.subReg64(.rax, .r10),
            .mul => if (ty == .i32) try m.imulReg32(.rax, .r10) else try m.imulReg64(.rax, .r10),
            .bit_and => if (ty == .i32) try m.andReg32(.rax, .r10) else try m.andReg64(.rax, .r10),
            .bit_or => if (ty == .i32) try m.orReg32(.rax, .r10) else try m.orReg64(.rax, .r10),
            .constant => return error.InvalidGraph,
            else => {
                if (ty == .i32) try m.cmpReg32(.rax, .r10) else try m.cmpReg64(.rax, .r10);
                const condition: x86.Cond = switch (op) {
                    .eq => .equal,
                    .lt_s => .less,
                    .lt_u => .below,
                    .ge_s => .greater_or_equal,
                    .ge_u => .above_or_equal,
                    else => return error.InvalidGraph,
                };
                try m.setCond32(.rax, condition);
            },
        }
    } else {
        switch (op) {
            .add => try m.emit(a64.addReg(.x2, .x2, .x3)),
            .sub => try m.emit(a64.subReg(.x2, .x2, .x3)),
            .mul => try m.emit(a64.mul(.x2, .x2, .x3)),
            .bit_and => try m.emit(a64.andReg(.x2, .x2, .x3)),
            .bit_or => try m.emit(a64.orrReg(.x2, .x2, .x3)),
            .constant => return error.InvalidGraph,
            else => {
                try m.emit(if (ty == .i32) a64.cmpRegW(.x2, .x3) else a64.cmpReg(.x2, .x3));
                const condition: a64.Cond = switch (op) {
                    .eq => .eq,
                    .lt_s => .lt,
                    .lt_u => .cc,
                    .ge_s => .ge,
                    .ge_u => .cs,
                    else => return error.InvalidGraph,
                };
                try m.emit(a64.csetW(.x2, condition));
            },
        }
        if (ty == .i32) try m.emit(a64.movRegW(.x2, .x2));
    }
}
