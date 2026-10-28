//! Bounded Wasm frontend for the isolated shared-backend experiment.
//! Production instantiation and tier selection never call this module.
const std = @import("std");
const decoder = @import("decoder.zig");
const validator = @import("validator.zig");
const wasm_types = @import("types.zig");
const CompiledFunc = @import("code.zig").CompiledFunc;
const Reader = @import("reader.zig").Reader;
const Op = @import("opcodes.zig").Op;
pub const ir = @import("../jit/backend/ir.zig");
pub const native = @import("../jit/backend/native.zig");
pub const CodeAllocator = @import("../jit/code_alloc.zig").CodeAllocator;

pub const OwnedGraph = struct {
    arena: std.heap.ArenaAllocator,
    graph: ir.Graph,

    pub fn deinit(self: *OwnedGraph) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

/// Developer-only module entry point, not a Wasm execution tier. The temporary
/// decoder/validator workspace is capped independently of the emitted graph.
pub fn lowerModule(allocator: std.mem.Allocator, bytes: []const u8, function_index: u32) !OwnedGraph {
    if (bytes.len > 64 * 1024) return error.PrototypeLimit;
    const workspace = try allocator.alloc(u8, 8 * 1024 * 1024);
    defer allocator.free(workspace);
    var fixed = std.heap.FixedBufferAllocator.init(workspace);
    const module = try decoder.decode(fixed.allocator(), bytes);
    if (module.imports.len != 0) return error.UnsupportedImports;
    if (function_index >= module.funcs.len) return error.FunctionIndex;
    const functions = try validator.validateModule(fixed.allocator(), &module);
    const function = &functions[function_index];
    return lower(allocator, function, module.types[function.type_index]);
}

pub fn evaluate(allocator: std.mem.Allocator, bytes: []const u8, function_index: u32, args: []const u64, budget: u32) !u64 {
    var graph = try lowerModule(allocator, bytes, function_index);
    defer graph.deinit();
    if (args.len != graph.graph.argument_types.len) return error.ArgumentCount;
    if (comptime !native.supported) return error.UnsupportedTarget;
    var owner = try CodeAllocator.init(allocator, 256 * 1024);
    defer owner.deinit();
    var compiled = try native.compile(allocator, &owner, graph.graph);
    defer compiled.deinit();
    return compiled.run(args, budget);
}

fn valueType(ty: wasm_types.ValType) !ir.Type {
    return switch (ty) {
        .i32 => .i32,
        .i64 => .i64,
        .f32 => .f32,
        .f64 => .f64,
        else => error.UnsupportedType,
    };
}

const missing = std.math.maxInt(u32);
const Instruction = struct {
    op: Op,
    offset: u32,
    immediate: u64 = 0,
    target: u32 = missing,
    pop_count: u32 = 0,
};
const Range = struct { start: usize, end: usize };

fn lower(allocator: std.mem.Allocator, function: *const CompiledFunc, signature: wasm_types.FuncType) !OwnedGraph {
    if (signature.results.len != 1) return error.UnsupportedSignature;
    const result_type = try valueType(signature.results[0]);
    if (function.body.len > 16 * 1024 or function.local_types.len > ir.max_arguments or
        function.max_stack > ir.max_arguments - function.local_types.len) return error.PrototypeLimit;
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const a = arena.allocator();
    const argument_types = try a.alloc(ir.Type, signature.params.len);
    for (signature.params, argument_types) |ty, *out| out.* = try valueType(ty);
    const local_types = try a.alloc(ir.Type, function.local_types.len);
    for (function.local_types, local_types) |ty, *out| out.* = try valueType(ty);

    var instructions: std.ArrayList(Instruction) = .empty;
    const offsets = try a.alloc(u32, function.body.len + 1);
    @memset(offsets, missing);
    // Mirror validator reachability: dead branches have no side-table entry.
    // Leaving an inner control restores its parent's reachability state.
    var reachable: std.ArrayList(bool) = .empty;
    try reachable.append(a, true);
    var reader = Reader.init(function.body);
    var side_index: usize = 0;
    while (!reader.atEnd()) {
        const offset = reader.pos;
        offsets[offset] = @intCast(instructions.items.len);
        var inst: Instruction = .{ .op = @fromBackingInt(@intCast(try reader.byte())), .offset = @intCast(offset) };
        switch (inst.op) {
            .nop, .drop => {},
            .block, .loop => {
                if (try reader.byte() != 0x40) return error.UnsupportedBlockType;
                const parent = reachable.items[reachable.items.len - 1];
                try reachable.append(a, parent);
            },
            .end => {
                _ = reachable.pop() orelse return error.InvalidControlFlow;
                if (reachable.items.len == 0) {
                    if (!reader.atEnd()) return error.InvalidControlFlow;
                    inst.op = .@"return";
                }
            },
            .br, .br_if => {
                _ = try reader.uleb(u32);
                if (reachable.items[reachable.items.len - 1]) {
                    if (side_index >= function.side_table.len) return error.InvalidControlFlow;
                    const branch = function.side_table[side_index];
                    side_index += 1;
                    if (branch.val_count != 0) return error.UnsupportedBlockType;
                    const target = @as(i64, @intCast(offset)) + branch.delta_ip;
                    if (target < 0 or target >= function.body.len) return error.InvalidControlFlow;
                    inst.target = @intCast(target);
                    inst.pop_count = branch.pop_count;
                }
                if (inst.op == .br) reachable.items[reachable.items.len - 1] = false;
            },
            .@"return", .@"unreachable" => reachable.items[reachable.items.len - 1] = false,
            .local_get, .local_set, .local_tee => inst.immediate = try reader.uleb(u32),
            .i32_const => inst.immediate = @as(u32, @bitCast(try reader.sleb(i32))),
            .i64_const => inst.immediate = @bitCast(try reader.sleb(i64)),
            .f32_const => inst.immediate = try reader.u32le(),
            .f64_const => inst.immediate = std.mem.readInt(u64, (try reader.bytesN(8))[0..8], .little),
            else => if (scalarOperation(inst.op) == null) return error.UnsupportedOpcode,
        }
        try instructions.append(a, inst);
    }
    if (reachable.items.len != 0 or side_index != function.side_table.len) return error.InvalidControlFlow;
    if (instructions.items.len == 0) return error.InvalidControlFlow;

    // Split only at branch destinations and terminators, then lower reachable
    // blocks in queue order. Every edge carries locals plus the operand stack.
    const leaders = try a.alloc(bool, instructions.items.len);
    @memset(leaders, false);
    leaders[0] = true;
    for (instructions.items, 0..) |*inst, i| {
        if (inst.target != missing) {
            inst.target = offsets[inst.target];
            if (inst.target == missing) return error.InvalidControlFlow;
            leaders[inst.target] = true;
        }
        if ((inst.op == .br or inst.op == .br_if or inst.op == .@"return" or inst.op == .@"unreachable") and i + 1 < leaders.len)
            leaders[i + 1] = true;
    }
    var ranges: std.ArrayList(Range) = .empty;
    const instruction_blocks = try a.alloc(u32, instructions.items.len);
    for (leaders, 0..) |leader, i| {
        if (leader) {
            if (ranges.items.len == ir.max_blocks) return error.PrototypeLimit;
            if (ranges.items.len != 0) ranges.items[ranges.items.len - 1].end = i;
            try ranges.append(a, .{ .start = i, .end = instructions.items.len });
        }
        instruction_blocks[i] = @intCast(ranges.items.len - 1);
    }
    for (instructions.items) |*inst| if (inst.target != missing) {
        inst.target = instruction_blocks[inst.target];
    };
    var builder: Builder = .{ .a = a };
    builder.mapping = try a.alloc(u32, ranges.items.len);
    @memset(builder.mapping, missing);
    builder.mapping[0] = 0;
    try builder.queue.append(a, 0);
    const params = try a.alloc(ir.Value, argument_types.len);
    for (params, argument_types) |*param, ty| param.* = try builder.value(ty);
    try builder.blocks.append(a, .{ .params = params });
    var index: usize = 0;
    while (index < builder.queue.items.len) : (index += 1) {
        const byte_block = builder.queue.items[index];
        const range = ranges.items[byte_block];
        var nodes: std.ArrayList(ir.Node) = .empty;
        var locals: [ir.max_arguments]ir.Value = undefined;
        var stack: std.ArrayList(ir.Value) = .empty;
        const block_params = builder.blocks.items[index].params;
        if (index == 0) {
            @memcpy(locals[0..params.len], params);
            for (local_types[params.len..], params.len..) |ty, i|
                locals[i] = try builder.constant(&nodes, ty, 0);
        } else {
            @memcpy(locals[0..local_types.len], block_params[0..local_types.len]);
            try stack.appendSlice(a, block_params[local_types.len..]);
        }
        var terminator: ?ir.Terminator = null;
        for (instructions.items[range.start..range.end]) |inst| {
            switch (inst.op) {
                .nop, .block, .loop, .end => {},
                .local_get, .local_set, .local_tee => {
                    if (inst.immediate >= local_types.len) return error.InvalidControlFlow;
                    const local: usize = @intCast(inst.immediate);
                    if (inst.op == .local_get) {
                        try stack.append(a, locals[local]);
                    } else {
                        locals[local] = stack.pop() orelse return error.InvalidControlFlow;
                        if (inst.op == .local_tee) try stack.append(a, locals[local]);
                    }
                },
                .drop => {
                    _ = stack.pop() orelse return error.InvalidControlFlow;
                },
                .i32_const, .i64_const, .f32_const, .f64_const => {
                    const ty: ir.Type = switch (inst.op) {
                        .i32_const => .i32,
                        .i64_const => .i64,
                        .f32_const => .f32,
                        else => .f64,
                    };
                    try stack.append(a, try builder.constant(&nodes, ty, inst.immediate));
                },
                .@"return" => terminator = .{ .return_ = stack.pop() orelse return error.InvalidControlFlow },
                .@"unreachable" => terminator = .{ .trap = .{ .reason = .unreachable_code, .site = inst.offset } },
                .br, .br_if => {
                    const condition = if (inst.op == .br_if) stack.pop() orelse return error.InvalidControlFlow else null;
                    if (inst.pop_count > stack.items.len) return error.InvalidControlFlow;
                    const edge = try builder.edge(inst.target, locals[0..local_types.len], stack.items[0 .. stack.items.len - inst.pop_count]);
                    terminator = if (condition) |cond| .{ .branch = .{
                        .condition = cond,
                        .taken = edge,
                        .fallthrough = try builder.edge(byte_block + 1, locals[0..local_types.len], stack.items),
                    } } else .{ .jump = edge };
                },
                else => {
                    const op = scalarOperation(inst.op) orelse return error.UnsupportedOpcode;
                    const rhs = if (inst.op == .i32_eqz or inst.op == .i64_eqz)
                        try builder.constant(&nodes, if (inst.op == .i32_eqz) .i32 else .i64, 0)
                    else if (ir.inputCount(op) == 2)
                        stack.pop() orelse return error.InvalidControlFlow
                    else
                        0;
                    const lhs = stack.pop() orelse return error.InvalidControlFlow;
                    const ty: ir.Type = if (ir.isComparison(op)) .i32 else if (ir.conversionTypes(op)) |conversion| conversion.output else switch (inst.op) {
                        .i32_reinterpret_f32 => .i32,
                        .i64_reinterpret_f64 => .i64,
                        .f32_reinterpret_i32 => .f32,
                        .f64_reinterpret_i64 => .f64,
                        else => builder.types.items[lhs],
                    };
                    const out = try builder.value(ty);
                    try nodes.append(a, .{ .op = op, .out = out, .lhs = lhs, .rhs = rhs, .trap_site = if (ir.mayTrap(op)) inst.offset else null });
                    try stack.append(a, out);
                },
            }
        }
        const final_terminator = terminator orelse ir.Terminator{
            .jump = try builder.edge(byte_block + 1, locals[0..local_types.len], stack.items),
        };
        builder.blocks.items[index].nodes = nodes.items;
        builder.blocks.items[index].terminator = final_terminator;
    }
    const graph: ir.Graph = .{
        .types = builder.types.items,
        .blocks = builder.blocks.items,
        .argument_types = argument_types,
        .result_type = result_type,
    };
    try graph.verify();
    return .{ .arena = arena, .graph = graph };
}

fn scalarOperation(op: Op) ?ir.Op {
    return switch (op) {
        .i32_eqz, .i32_eq, .i64_eqz, .i64_eq => .eq,
        .i32_ne, .i64_ne => .ne,
        .i32_lt_s, .i64_lt_s => .lt_s,
        .i32_lt_u, .i64_lt_u => .lt_u,
        .i32_gt_s, .i64_gt_s => .gt_s,
        .i32_gt_u, .i64_gt_u => .gt_u,
        .i32_le_s, .i64_le_s => .le_s,
        .i32_le_u, .i64_le_u => .le_u,
        .i32_ge_s, .i64_ge_s => .ge_s,
        .i32_ge_u, .i64_ge_u => .ge_u,
        .i32_add, .i64_add => .add,
        .i32_sub, .i64_sub => .sub,
        .i32_mul, .i64_mul => .mul,
        .i32_div_s, .i64_div_s => .div_s,
        .i32_div_u, .i64_div_u => .div_u,
        .i32_rem_s, .i64_rem_s => .rem_s,
        .i32_rem_u, .i64_rem_u => .rem_u,
        .i32_and, .i64_and => .bit_and,
        .i32_or, .i64_or => .bit_or,
        .i32_xor, .i64_xor => .bit_xor,
        .i32_shl, .i64_shl => .shl,
        .i32_shr_s, .i64_shr_s => .shr_s,
        .i32_shr_u, .i64_shr_u => .shr_u,
        .i32_rotl, .i64_rotl => .rotl,
        .i32_rotr, .i64_rotr => .rotr,
        .i32_clz, .i64_clz => .clz,
        .i32_ctz, .i64_ctz => .ctz,
        .i32_popcnt, .i64_popcnt => .popcnt,
        .i32_extend8_s, .i64_extend8_s => .sext8,
        .i32_extend16_s, .i64_extend16_s => .sext16,
        .i64_extend32_s => .sext32,
        .i32_wrap_i64 => .trunc_i64,
        .i64_extend_i32_s => .sext_i32,
        .i64_extend_i32_u => .zext_i32,
        .f32_add, .f64_add => .fadd,
        .f32_sub, .f64_sub => .fsub,
        .f32_mul, .f64_mul => .fmul,
        .f32_div, .f64_div => .fdiv,
        .f32_min, .f64_min => .fmin,
        .f32_max, .f64_max => .fmax,
        .f32_copysign, .f64_copysign => .fcopysign,
        .f32_abs, .f64_abs => .fabs,
        .f32_neg, .f64_neg => .fneg,
        .f32_sqrt, .f64_sqrt => .fsqrt,
        .f32_eq, .f64_eq => .feq,
        .f32_ne, .f64_ne => .fne,
        .f32_lt, .f64_lt => .flt,
        .f32_gt, .f64_gt => .fgt,
        .f32_le, .f64_le => .fle,
        .f32_ge, .f64_ge => .fge,
        .f32_demote_f64 => .demote_f64,
        .f64_promote_f32 => .promote_f32,
        .i32_reinterpret_f32, .i64_reinterpret_f64, .f32_reinterpret_i32, .f64_reinterpret_i64 => .reinterpret,
        else => null,
    };
}

const Builder = struct {
    a: std.mem.Allocator,
    types: std.ArrayList(ir.Type) = .empty,
    blocks: std.ArrayList(ir.Block) = .empty,
    mapping: []u32 = &.{},
    queue: std.ArrayList(u32) = .empty,

    fn value(self: *Builder, ty: ir.Type) !ir.Value {
        if (self.types.items.len == ir.max_values) return error.PrototypeLimit;
        const id: ir.Value = @intCast(self.types.items.len);
        try self.types.append(self.a, ty);
        return id;
    }

    fn constant(self: *Builder, nodes: *std.ArrayList(ir.Node), ty: ir.Type, immediate: u64) !ir.Value {
        const out = try self.value(ty);
        try nodes.append(self.a, .{ .op = .constant, .out = out, .immediate = immediate });
        return out;
    }

    fn edge(self: *Builder, target: u32, locals: []const ir.Value, stack: []const ir.Value) !ir.Edge {
        if (target == 0 or target >= self.mapping.len) return error.InvalidControlFlow;
        if (locals.len + stack.len > ir.max_arguments) return error.PrototypeLimit;
        const args = try self.a.alloc(ir.Value, locals.len + stack.len);
        @memcpy(args[0..locals.len], locals);
        @memcpy(args[locals.len..], stack);
        if (self.mapping[target] == missing) {
            const params = try self.a.alloc(ir.Value, args.len);
            for (params, args) |*param, arg| param.* = try self.value(self.types.items[arg]);
            self.mapping[target] = @intCast(self.blocks.items.len);
            try self.blocks.append(self.a, .{ .params = params });
            try self.queue.append(self.a, target);
        }
        return .{ .target = self.mapping[target], .args = args };
    }
};
