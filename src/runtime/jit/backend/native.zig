//! Experimental backend. Values use caller-saved registers, bounded spills,
//! or rematerialized literals. Runtime calls use explicit snapshots. Opaque
//! frontend words may contain tagged references; the backend never dereferences them.
const std = @import("std");
const builtin = @import("builtin");
const ir = @import("ir.zig");
const allocation = @import("allocation.zig");
const optimize = @import("optimize.zig");
const float = @import("float.zig");
const integer = @import("integer.zig");
const conversion = @import("conversion.zig");
const fp_environment = @import("fp_environment.zig");
const memory = @import("memory.zig");
const call = @import("call.zig");
const stack_guard = @import("../../../stack_guard.zig");
const code_alloc = @import("../code_alloc.zig");
const a64 = @import("../asm_aarch64.zig");
const arm_masm = @import("../masm.zig");
const x86 = @import("../asm_x86_64.zig");

pub const supported = code_alloc.supported;
pub const max_budget = 1_000_000;
pub const MemoryView = memory.View;
pub const CallRequest = call.Request;
pub const Runtime = call.Runtime;
const is_x86 = builtin.cpu.arch == .x86_64;
const Machine = if (is_x86) x86.Masm else arm_masm.Masm;
const Reg = if (is_x86) x86.Reg else a64.Reg;
const Entry = *const fn ([*]u64, u64) callconv(.c) u32;

pub const Options = struct {
    allocation: allocation.Mode = .linear_scan,
    register_count: u8 = allocation.max_registers,
    rematerialize_constants: bool = true,
    optimization: optimize.Options = .{},
};
pub const Stats = struct { loads: u32 = 0, stores: u32 = 0, register_moves: u32 = 0, rematerializations: u32 = 0 };

const SideExit = struct { allocator: std.mem.Allocator, id: u32, values: []u64 };
pub const Completion = union(enum) {
    returned,
    trapped: ir.Trap,
    exited: SideExit,

    pub fn deinit(self: *Completion) void {
        if (self.* == .exited) self.exited.allocator.free(self.exited.values);
        self.* = undefined;
    }
};
pub const Outcome = union(enum) {
    returned: u64,
    trapped: ir.Trap,
    exited: SideExit,

    /// Transfers ownership of any side-exit capture buffer.
    pub fn fromCompletion(completion: Completion, value: u64) Outcome {
        return switch (completion) {
            .returned => .{ .returned = value },
            .trapped => |trap| .{ .trapped = trap },
            .exited => |exit| .{ .exited = exit },
        };
    }

    pub fn deinit(self: *Outcome) void {
        switch (self.*) {
            .returned, .trapped => {},
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
    result_types: []ir.Type,
    spill_slot_count: usize,
    uses_fp_environment: bool = false,
    memory_count: u32 = 0,
    call_sites: []const call.Site,
    stats: Stats = .{},
    optimization: optimize.Stats = .{},

    pub fn scratchSlotCount(self: *const Compiled) usize {
        return self.callBase() + @as(usize, if (self.call_sites.len != 0) call.slot_count else 0);
    }

    fn callBase(self: *const Compiled) usize {
        return self.memoryViewsSlot() + @as(usize, @intFromBool(self.memory_count != 0));
    }

    fn memoryViewsSlot(self: *const Compiled) usize {
        return self.spill_slot_count + ir.max_arguments + 2 +
            @as(usize, if (self.uses_fp_environment) fp_environment.slot_count else 0);
    }

    pub fn deinit(self: *Compiled) void {
        self.code.deinit();
        self.allocator.free(self.params);
        self.allocator.free(self.argument_types);
        self.allocator.free(self.result_types);
        self.allocator.free(self.call_sites);
        self.* = undefined;
    }

    pub fn run(self: *const Compiled, args: []const u64, budget: u32) !u64 {
        return self.runWithMemory(args, &.{}, budget);
    }

    pub fn runWithMemory(self: *const Compiled, args: []const u64, views: []const MemoryView, budget: u32) !u64 {
        var outcome = try self.runOutcomeWithMemory(args, views, budget);
        defer outcome.deinit();
        return switch (outcome) {
            .returned => |value| value,
            .trapped => |trap| trap.reason.toError(),
            .exited => error.UnexpectedSideExit,
        };
    }

    pub fn runOutcome(self: *const Compiled, args: []const u64, budget: u32) !Outcome {
        return self.runOutcomeWithMemory(args, &.{}, budget);
    }

    pub fn runOutcomeWithMemory(self: *const Compiled, args: []const u64, views: []const MemoryView, budget: u32) !Outcome {
        return self.runOutcomeWithRuntime(args, views, budget, null);
    }

    pub fn runOutcomeWithRuntime(self: *const Compiled, args: []const u64, views: []const MemoryView, budget: u32, runtime: ?Runtime) !Outcome {
        if (self.result_types.len != 1) return error.ResultCount;
        var result: [1]u64 = .{0};
        const completion = try self.runInto(args, views, budget, runtime, &result);
        return Outcome.fromCompletion(completion, result[0]);
    }

    /// Writes caller-owned results only after a normal return. Stores and callbacks
    /// retain their ordinary side effects, including through aliases of this buffer.
    pub fn runInto(self: *const Compiled, args: []const u64, views: []const MemoryView, budget: u32, runtime: ?Runtime, results: []u64) !Completion {
        if (args.len != self.params.len) return error.ArgumentCount;
        if (results.len != self.result_types.len) return error.ResultCount;
        if (views.len != self.memory_count) return error.MemoryCount;
        if (self.call_sites.len != 0 and runtime == null) return error.MissingRuntime;
        if (budget > max_budget) return error.PrototypeLimit;
        if (stack_guard.nearLimit()) return error.CallStackExhausted;
        const slots = try self.allocator.alloc(u64, self.scratchSlotCount());
        defer self.allocator.free(slots);
        @memset(slots, 0);
        var current_views: [ir.max_memories]MemoryView = undefined;
        @memcpy(current_views[0..views.len], views);
        if (self.memory_count != 0) slots[self.memoryViewsSlot()] = @intFromPtr(&current_views);
        var invocation: ?call.Invocation = if (runtime) |host| .{
            .runtime = host,
            .sites = self.call_sites,
            .memories = current_views[0..views.len],
            .transfer_base = self.spill_slot_count,
            .call_base = self.callBase(),
        } else null;
        if (self.call_sites.len != 0) slots[self.callBase()] = @intFromPtr(&invocation.?);
        for (args, self.argument_types, 0..) |arg, ty, i| slots[self.spill_slot_count + i] = ir.normalize(ty, arg);
        const entry: Entry = @ptrCast(@alignCast(self.code.entry() orelse return error.MissingCode));
        const result_slot = self.spill_slot_count + ir.max_arguments;
        return switch (entry(slots.ptr, budget)) {
            0 => blk: {
                for (results, self.result_types, 0..) |*out, ty, i| out.* = ir.normalize(ty, slots[self.spill_slot_count + i]);
                break :blk .returned;
            },
            1 => error.BudgetExhausted,
            2 => blk: {
                const id = slots[result_slot];
                const count = slots[result_slot + 1];
                if (id > std.math.maxInt(u32) or count > ir.max_arguments) return error.InvalidNativeResult;
                break :blk .{ .exited = .{
                    .allocator = self.allocator,
                    .id = @intCast(id),
                    .values = try self.allocator.dupe(u64, slots[self.spill_slot_count .. self.spill_slot_count + @as(usize, @intCast(count))]),
                } };
            },
            3 => blk: {
                const reason: ir.TrapReason = switch (slots[result_slot]) {
                    1 => .division_by_zero,
                    2 => .integer_overflow,
                    3 => .unreachable_code,
                    4 => .invalid_conversion,
                    5 => .memory_out_of_bounds,
                    else => return error.InvalidNativeResult,
                };
                if (slots[result_slot + 1] > std.math.maxInt(u32)) return error.InvalidNativeResult;
                break :blk .{ .trapped = .{ .reason = reason, .site = @intCast(slots[result_slot + 1]) } };
            },
            4 => if (invocation) |host| host.failure orelse error.InvalidNativeResult else error.InvalidNativeResult,
            else => error.InvalidNativeResult,
        };
    }
};

pub fn compile(a: std.mem.Allocator, owner: *code_alloc.CodeAllocator, graph: ir.Graph) !Compiled {
    return compileWithOptions(a, owner, graph, .{});
}

pub fn compileWithOptions(a: std.mem.Allocator, owner: *code_alloc.CodeAllocator, graph: ir.Graph, options: Options) !Compiled {
    try graph.verify();
    if (comptime !supported) return error.UnsupportedTarget;
    var optimized: ?optimize.Result = if (options.optimization.constant_folding or options.optimization.common_subexpression_elimination or options.optimization.dead_code_elimination)
        try optimize.run(a, graph, options.optimization)
    else
        null;
    defer if (optimized) |*result| result.deinit();
    var compiled = try emitGraph(a, owner, if (optimized) |result| result.graph else graph, options);
    if (optimized) |result| {
        compiled.optimization = result.stats;
    } else {
        for (graph.blocks) |block| compiled.optimization.input_nodes += @intCast(block.nodes.len);
        compiled.optimization.output_nodes = compiled.optimization.input_nodes;
    }
    return compiled;
}

fn emitGraph(a: std.mem.Allocator, owner: *code_alloc.CodeAllocator, graph: ir.Graph, options: Options) !Compiled {
    var plan = try allocation.Plan.build(a, graph, .{
        .mode = options.allocation,
        .register_count = options.register_count,
        .rematerialize_constants = options.rematerialize_constants,
    });
    defer plan.deinit();
    var m = Machine.init(a);
    defer m.deinit();
    var emission: Emission = .{ .m = &m, .plan = &plan, .transfer_base = plan.spill_slot_count };
    var call_count: usize = 0;
    for (graph.blocks) |block| for (block.nodes) |node| {
        if (node.op == .call) call_count += 1;
    };
    const call_sites = try a.alloc(call.Site, call_count);
    errdefer a.free(call_sites);
    if (fp_environment.required(graph)) {
        emission.fp_state_slot = emission.transfer_base + ir.max_arguments + 2;
        try fp_environment.enter(&m, emission.fp_state_slot.?);
        emission.stats.loads += fp_environment.enter_loads;
        emission.stats.stores += fp_environment.enter_stores;
    }
    if (graph.memory_count != 0) emission.memory_views_slot = emission.transfer_base + ir.max_arguments + 2 +
        @as(usize, if (emission.fp_state_slot != null) fp_environment.slot_count else 0);
    if (call_count != 0) emission.call_base = emission.transfer_base + ir.max_arguments + 2 + fp_environment.slot_count +
        @as(usize, @intFromBool(graph.memory_count != 0));
    var call_index: u32 = 0;
    const labels = try a.alloc(Machine.Label, graph.blocks.len);
    defer a.free(labels);
    @memset(labels, .{});
    defer for (labels) |*label| label.deinit(a);
    var exhausted: Machine.Label = .{};
    defer exhausted.deinit(a);
    for (graph.blocks[0].params, 0..) |param, i| {
        if (plan.locations[param] == .none) continue;
        try emission.loadSlot(false, emission.transfer_base + i);
        try emission.write(param);
    }
    for (graph.blocks, 0..) |block, index| {
        try m.bind(&labels[index]);
        try poll(&m, &exhausted);
        for (block.nodes, 0..) |node, node_index| {
            if (node.op == .guard) {
                var success: Machine.Label = .{};
                defer success.deinit(a);
                try emission.read(false, node.lhs);
                if (comptime is_x86) {
                    try m.testReg64(.rax, .rax);
                    try m.jumpCond(.not_equal, &success);
                } else try m.jumpCbnz(.x2, &success);
                try emission.emitExit(node.exit.?);
                try m.bind(&success);
                continue;
            } else if (node.call) |runtime_call| {
                call_sites[call_index] = .{ .target = runtime_call.target, .site = node.trap_site.?, .safepoint = runtime_call.safepoint.id, .argument_count = runtime_call.arguments.len, .capture_count = runtime_call.safepoint.values.len, .result_count = runtime_call.results.len };
                @memcpy(call_sites[call_index].parameter_types[0..runtime_call.parameter_types.len], runtime_call.parameter_types);
                @memcpy(call_sites[call_index].result_types[0..runtime_call.result_types.len], runtime_call.result_types);
                try emission.invoke(node, @intCast(index), @intCast(2 * node_index + 1), call_index);
                call_index += 1;
                continue;
            } else if (ir.isMemoryOp(node.op)) {
                try emission.read(false, node.lhs);
                if (node.op == .store) try emission.read(true, node.rhs);
                try emission.accessMemory(node, graph.types[if (node.op == .store) node.rhs else node.out.?]);
                if (node.out) |out| try emission.write(out);
                continue;
            } else if (node.op == .constant) {
                if (plan.locations[node.out.?] == .immediate) continue;
                try constant(&m, node.immediate);
            } else {
                try emission.read(false, node.lhs);
                if (ir.inputCount(node.op) == 2) try emission.read(true, node.rhs);
                if (ir.isNumericConversion(node.op)) {
                    try emission.convert(node, graph.types[node.lhs], graph.types[node.out.?]);
                } else if (ir.isFloatOp(node.op)) {
                    try float.emit(&m, node.op, graph.types[node.lhs]);
                } else if (ir.mayTrap(node.op)) {
                    try emission.divide(node, graph.types[node.lhs]);
                } else if (node.op == .reinterpret) {
                    // Every home contains raw bits; no numeric conversion.
                } else if (ir.conversionTypes(node.op) != null) {
                    if (comptime is_x86) {
                        if (node.op == .sext_i32) try m.signExtendReg32To64(.rax, .rax) else try m.movReg32(.rax, .rax);
                    } else try m.emit(if (node.op == .sext_i32) a64.sxtw(.x2, .x2) else a64.movRegW(.x2, .x2));
                } else try integer.emit(&m, node.op, graph.types[node.lhs]);
            }
            try emission.write(node.out.?);
        }
        switch (block.terminator) {
            .trap => |trap| try emission.emitTrap(trap),
            .return_ => |values| {
                for (values, 0..) |value, i| {
                    try emission.read(false, value);
                    try emission.storeSlot(emission.transfer_base + i);
                }
                try emission.finish(0);
            },
            .jump => |edge| try emission.transfer(graph, edge, labels),
            .branch => |branch| {
                var otherwise: Machine.Label = .{};
                defer otherwise.deinit(a);
                try emission.read(false, branch.condition);
                if (comptime is_x86) {
                    try m.testReg64(.rax, .rax);
                    try m.jumpCond(.equal, &otherwise);
                } else try m.jumpCbz(.x2, &otherwise);
                try emission.transfer(graph, branch.taken, labels);
                try m.bind(&otherwise);
                try emission.transfer(graph, branch.fallthrough, labels);
            },
        }
    }
    try m.bind(&exhausted);
    try emission.finish(1);
    const params = try a.dupe(ir.Value, graph.blocks[0].params);
    errdefer a.free(params);
    const argument_types = try a.dupe(ir.Type, graph.argument_types);
    errdefer a.free(argument_types);
    const result_types = try a.dupe(ir.Type, graph.result_types);
    errdefer a.free(result_types);
    return .{
        .allocator = a,
        .code = try owner.installOwned(m.code.items),
        .params = params,
        .argument_types = argument_types,
        .result_types = result_types,
        .spill_slot_count = plan.spill_slot_count,
        .uses_fp_environment = emission.fp_state_slot != null,
        .memory_count = graph.memory_count,
        .call_sites = call_sites,
        .stats = emission.stats,
    };
}

const Emission = struct {
    m: *Machine,
    plan: *const allocation.Plan,
    transfer_base: usize,
    fp_state_slot: ?usize = null,
    memory_views_slot: ?usize = null,
    call_base: ?usize = null,
    stats: Stats = .{},

    fn read(self: *Emission, rhs: bool, value: ir.Value) !void {
        switch (self.plan.locations[value]) {
            .none => return error.InvalidAllocation,
            .spill => |slot| try self.loadSlot(rhs, slot),
            .register => |register| try self.move(scratchRegister(rhs), allocatedRegister(register)),
            .immediate => |bits| {
                try self.m.movImm64(scratchRegister(rhs), bits);
                self.stats.rematerializations += 1;
            },
        }
    }

    fn write(self: *Emission, value: ir.Value) !void {
        switch (self.plan.locations[value]) {
            .none => {},
            .spill => |slot| try self.storeSlot(slot),
            .register => |register| try self.move(allocatedRegister(register), scratchRegister(false)),
            .immediate => return error.InvalidAllocation,
        }
    }

    fn loadSlot(self: *Emission, rhs: bool, slot: usize) !void {
        try load(self.m, rhs, slot);
        self.stats.loads += 1;
    }

    fn storeSlot(self: *Emission, slot: usize) !void {
        try store(self.m, slot);
        self.stats.stores += 1;
    }

    fn move(self: *Emission, destination: Reg, source: Reg) !void {
        if (comptime is_x86) try self.m.movReg64(destination, source) else try self.m.emit(a64.movReg(destination, source));
        self.stats.register_moves += 1;
    }

    fn emitExit(self: *Emission, side_exit: ir.SideExit) !void {
        for (side_exit.values, 0..) |value, i| {
            try self.read(false, value);
            try self.storeSlot(self.transfer_base + i);
        }
        try constant(self.m, side_exit.id);
        try self.storeSlot(self.transfer_base + ir.max_arguments);
        try constant(self.m, side_exit.values.len);
        try self.storeSlot(self.transfer_base + ir.max_arguments + 1);
        try self.finish(2);
    }

    fn transfer(self: *Emission, graph: ir.Graph, edge: ir.Edge, labels: []Machine.Label) !void {
        // Capture all sources before changing any destination home, including
        // registers. Both register and spill permutations may contain cycles.
        for (edge.args, 0..) |arg, i| {
            try self.read(false, arg);
            try self.storeSlot(self.transfer_base + i);
        }
        for (graph.blocks[edge.target].params, 0..) |param, i| {
            if (self.plan.locations[param] == .none) continue;
            try self.loadSlot(false, self.transfer_base + i);
            try self.write(param);
        }
        try self.m.jump(&labels[edge.target]);
    }

    fn emitTrap(self: *Emission, trap: ir.Trap) !void {
        try constant(self.m, @backingInt(trap.reason));
        try self.storeSlot(self.transfer_base + ir.max_arguments);
        try constant(self.m, trap.site);
        try self.storeSlot(self.transfer_base + ir.max_arguments + 1);
        try self.finish(3);
    }

    fn divide(self: *Emission, node: ir.Node, ty: ir.Type) !void {
        var zero: Machine.Label = .{};
        defer zero.deinit(self.m.gpa);
        var overflow: Machine.Label = .{};
        defer overflow.deinit(self.m.gpa);
        var done: Machine.Label = .{};
        defer done.deinit(self.m.gpa);
        try integer.divide(self.m, node.op, ty, &zero, &overflow);
        try self.m.jump(&done);
        try self.m.bind(&zero);
        try self.emitTrap(.{ .reason = .division_by_zero, .site = node.trap_site.? });
        try self.m.bind(&overflow);
        try self.emitTrap(.{ .reason = .integer_overflow, .site = node.trap_site.? });
        try self.m.bind(&done);
    }

    fn convert(self: *Emission, node: ir.Node, input: ir.Type, output: ir.Type) !void {
        var invalid: Machine.Label = .{};
        defer invalid.deinit(self.m.gpa);
        var overflow: Machine.Label = .{};
        defer overflow.deinit(self.m.gpa);
        var done: Machine.Label = .{};
        defer done.deinit(self.m.gpa);
        try conversion.emit(self.m, node.op, input, output, &invalid, &overflow);
        if (node.trap_site) |site| {
            try self.m.jump(&done);
            try self.m.bind(&invalid);
            try self.emitTrap(.{ .reason = .invalid_conversion, .site = site });
            try self.m.bind(&overflow);
            try self.emitTrap(.{ .reason = .integer_overflow, .site = site });
            try self.m.bind(&done);
        }
    }

    fn accessMemory(self: *Emission, node: ir.Node, ty: ir.Type) !void {
        var oob: Machine.Label = .{};
        defer oob.deinit(self.m.gpa);
        var done: Machine.Label = .{};
        defer done.deinit(self.m.gpa);
        try memory.emit(self.m, node.op, ty, node.memory.?, self.memory_views_slot.?, &oob);
        self.stats.loads += 4 + @as(u32, @intFromBool(node.op == .load));
        self.stats.stores += @intFromBool(node.op == .store);
        try self.m.jump(&done);
        try self.m.bind(&oob);
        try self.emitTrap(.{ .reason = .memory_out_of_bounds, .site = node.trap_site.? });
        try self.m.bind(&done);
    }

    fn invoke(self: *Emission, node: ir.Node, block: u32, position: u32, index: u32) !void {
        const runtime_call = node.call.?;
        const base = self.call_base.?;
        var live: [allocation.max_registers]bool = @splat(false);
        for (self.plan.locations, self.plan.ranges) |location, range| {
            if (range.block == block and range.start < position and range.end > position and location == .register)
                live[location.register] = true;
        }
        for (runtime_call.arguments, 0..) |value, i| {
            try self.read(false, value);
            try self.storeSlot(self.transfer_base + i);
        }
        for (runtime_call.safepoint.values, 0..) |value, i| {
            try self.read(false, value);
            try self.storeSlot(base + call.captures_offset + i);
        }
        for (live, 0..) |used, register| if (used) {
            try self.move(scratchRegister(false), allocatedRegister(@intCast(register)));
            try self.storeSlot(base + call.saved_registers_offset + register);
        };
        if (runtime_call.fp_mode == .host) {
            try fp_environment.leave(self.m, self.fp_state_slot.?);
            self.stats.loads += fp_environment.leave_loads;
        }
        try call.emit(self.m, base, index);
        var success: Machine.Label = .{};
        defer success.deinit(self.m.gpa);
        if (comptime is_x86) {
            try self.m.testReg64(.rax, .rax);
            try self.m.jumpCond(.equal, &success);
        } else try self.m.jumpCbz(.x2, &success);
        try self.finish(4);
        try self.m.bind(&success);
        try fp_environment.reenter(self.m, self.fp_state_slot.?);
        self.stats.loads += fp_environment.leave_loads;
        // call.emit also saves and restores the context and budget on the stack.
        self.stats.loads += call.emit_loads;
        self.stats.stores += call.emit_stores;
        for (live, 0..) |used, register| if (used) {
            try self.loadSlot(false, base + call.saved_registers_offset + register);
            try self.move(allocatedRegister(@intCast(register)), scratchRegister(false));
        };
        for (runtime_call.results, runtime_call.result_types, 0..) |out, ty, i| {
            try self.loadSlot(false, self.transfer_base + i);
            if (ir.is32(ty)) {
                if (comptime is_x86) try self.m.movReg32(.rax, .rax) else try self.m.emit(a64.movRegW(.x2, .x2));
            }
            try self.write(out);
        }
    }

    fn finish(self: *Emission, status: u32) !void {
        if (self.fp_state_slot) |slot| {
            try fp_environment.leave(self.m, slot);
            self.stats.loads += fp_environment.leave_loads;
        }
        if (comptime is_x86) {
            try self.m.movImm32(.rax, status);
            try self.m.ret();
        } else {
            try self.m.movImm64(.x0, status);
            try self.m.emit(a64.ret());
        }
    }
};

fn scratchRegister(rhs: bool) Reg {
    return if (comptime is_x86) (if (rhs) .r10 else .rax) else (if (rhs) .x3 else .x2);
}

fn allocatedRegister(register: u8) Reg {
    // Caller-saved on both supported ABIs. Excludes the scratch pointer,
    // budget, arithmetic scratch, and all platform/callee-saved registers.
    return if (comptime is_x86)
        ([_]Reg{ .rcx, .rdx, .r8, .r9 })[register]
    else
        ([_]Reg{ .x4, .x5, .x6, .x7 })[register];
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
