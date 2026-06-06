//! WebAssembly validation (§3) fused with O(1) side-table emission.
//!
//! A single forward pass over each function body type-checks it against
//! the abstract value/control stacks of the spec's validation
//! algorithm (Appendix), and — as a side effect — emits the branch
//! side-table the in-place interpreter consults (see
//! docs/wasm-engine.md and code.zig).
//!
//! Side-table contract. One entry per reachable branch-consulting
//! instruction (`if` / `else` / `br` / `br_if`), in bytecode order, so
//! an entry's index equals the count of reachable branches before it.
//! The interpreter keeps a side-table pointer in lockstep: falling
//! through a not-taken `if` / `br_if` advances it by one; a taken
//! branch adds `delta_stp`, set here so the pointer lands on the entry
//! of the first reachable branch at or after the target. Forward
//! targets (`block` / `if` ends) are backpatched at `end` / `else`;
//! `loop` targets are backward and resolved immediately. Branches in
//! unreachable code are type-checked but emit no entry, keeping the
//! lockstep exact.

const std = @import("std");
const types = @import("types.zig");
const module_mod = @import("module.zig");
const reader_mod = @import("reader.zig");
const code_mod = @import("code.zig");
const opcodes = @import("opcodes.zig");

const ValType = types.ValType;
const Module = module_mod.Module;
const Reader = reader_mod.Reader;
const BranchEntry = code_mod.BranchEntry;
const CompiledFunc = code_mod.CompiledFunc;
const Op = opcodes.Op;

pub const ValidateError = error{
    Truncated,
    IntTooLarge,
    LebTooLong,
    BadUtf8,
    BadValType,
    BadBlockType,
    UnknownOpcode,
    TypeMismatch,
    StackUnderflow,
    UnknownLocal,
    UnknownGlobal,
    UnknownFunc,
    UnknownType,
    UnknownLabel,
    ImmutableGlobal,
    UnexpectedElse,
    UnbalancedEnd,
    InvalidLocalCount,
    NoMemory,
    OutOfMemory,
};

/// `null` models the spec's "Unknown" (bottom) type that polymorphic
/// stack slots take in unreachable code.
const AbsVal = ?ValType;

/// A block signature: the params it consumes and the results it
/// produces (§5.3.2 blocktype). Slices live in the arena.
const BlockType = struct {
    params: []const ValType,
    results: []const ValType,
};

/// A forward branch awaiting its target. Patched when the construct's
/// `end` (or, for `if`'s false edge, its `else`) is reached.
const Pending = struct {
    entry: u32, // index into the side-table
    ip: u32, // bytecode offset of the branch opcode
};

const Ctrl = struct {
    op: Op, // block / loop / if / else
    start_types: []const ValType,
    end_types: []const ValType,
    height: u32, // operand-stack height at entry
    unreachable_: bool = false,
    entered_reachable: bool, // was the construct itself reachable?
    start_ip: u32, // first body instruction (loop branch target)
    start_stp: u32, // side-table length at body start (loop target entry)
    pending: std.ArrayListUnmanaged(Pending) = .empty,
    if_entry: ?u32 = null, // `if`'s own entry, patched at else/end
    if_ip: u32 = 0,

    fn labelTypes(self: *const Ctrl) []const ValType {
        return if (self.op == .loop) self.start_types else self.end_types;
    }
};

/// Validate every function in `module`, returning one `CompiledFunc`
/// each (positionally matching `module.code`). Allocations come from
/// `arena`, which the caller owns for the module's lifetime.
pub fn validateModule(arena: std.mem.Allocator, module: *const Module) ValidateError![]const CompiledFunc {
    const out = try arena.alloc(CompiledFunc, module.code.len);
    for (module.code, 0..) |body, i| {
        const type_index = module.funcs[i];
        if (type_index >= module.types.len) return error.UnknownType;
        out[i] = try validateFunc(arena, module, type_index, body.bytes);
    }
    return out;
}

const Validator = struct {
    arena: std.mem.Allocator,
    module: *const Module,
    local_types: []const ValType,
    results: []const ValType,
    has_memory: bool,
    r: Reader, // over the body's expression bytes
    vals: std.ArrayListUnmanaged(AbsVal) = .empty,
    ctrls: std.ArrayListUnmanaged(Ctrl) = .empty,
    side_table: std.ArrayListUnmanaged(BranchEntry) = .empty,
    max_stack: u32 = 0,

    fn reachable(self: *Validator) bool {
        const c = &self.ctrls.items[self.ctrls.items.len - 1];
        return c.entered_reachable and !c.unreachable_;
    }

    fn pushVal(self: *Validator, t: AbsVal) !void {
        try self.vals.append(self.arena, t);
        self.max_stack = @max(self.max_stack, @as(u32, @intCast(self.vals.items.len)));
    }

    fn popVal(self: *Validator) !AbsVal {
        const c = &self.ctrls.items[self.ctrls.items.len - 1];
        if (self.vals.items.len == c.height) {
            if (c.unreachable_) return null; // polymorphic: yields Unknown
            return error.StackUnderflow;
        }
        return self.vals.pop().?;
    }

    fn popExpect(self: *Validator, expect: ValType) !void {
        const actual = try self.popVal();
        if (actual) |a| {
            if (a != expect) return error.TypeMismatch;
        }
    }

    fn popVals(self: *Validator, ts: []const ValType) !void {
        var i: usize = ts.len;
        while (i > 0) {
            i -= 1;
            try self.popExpect(ts[i]);
        }
    }

    fn pushVals(self: *Validator, ts: []const ValType) !void {
        for (ts) |t| try self.pushVal(t);
    }

    fn pushCtrl(self: *Validator, op: Op, in: []const ValType, out: []const ValType, start_ip: u32) !void {
        const parent_reachable = self.reachable();
        const c: Ctrl = .{
            .op = op,
            .start_types = in,
            .end_types = out,
            .height = @intCast(self.vals.items.len),
            .entered_reachable = parent_reachable,
            .start_ip = start_ip,
            .start_stp = @intCast(self.side_table.items.len),
        };
        try self.ctrls.append(self.arena, c);
        try self.pushVals(in);
    }

    fn popCtrl(self: *Validator) !Ctrl {
        if (self.ctrls.items.len == 0) return error.UnbalancedEnd;
        const c = self.ctrls.items[self.ctrls.items.len - 1];
        try self.popVals(c.end_types);
        if (self.vals.items.len != c.height) return error.TypeMismatch;
        _ = self.ctrls.pop();
        return c;
    }

    fn setUnreachable(self: *Validator) void {
        const c = &self.ctrls.items[self.ctrls.items.len - 1];
        self.vals.shrinkRetainingCapacity(c.height);
        c.unreachable_ = true;
    }

    /// Resolve the `n`-th enclosing label (0 = innermost).
    fn label(self: *Validator, n: u32) !*Ctrl {
        if (n >= self.ctrls.items.len) return error.UnknownLabel;
        return &self.ctrls.items[self.ctrls.items.len - 1 - n];
    }

    /// Emit a side-table entry for a reachable branch to `target`,
    /// returning its index (or null when the branch is in dead code).
    fn emitBranch(self: *Validator, branch_ip: u32, target: *Ctrl) !?u32 {
        const arity: u32 = @intCast(target.labelTypes().len);
        // popcnt: operands above the target label's height, minus the
        // carried arity. In reachable code the height is concrete.
        const height: u32 = @intCast(self.vals.items.len);
        const popcnt = height - target.height - arity;
        if (!self.reachable()) return null;
        const idx: u32 = @intCast(self.side_table.items.len);
        try self.side_table.append(self.arena, .{
            .delta_ip = 0,
            .delta_stp = 0,
            .val_count = arity,
            .pop_count = popcnt,
        });
        if (target.op == .loop) {
            // Backward target: resolve now.
            const e = &self.side_table.items[idx];
            e.delta_ip = @as(i32, @intCast(target.start_ip)) - @as(i32, @intCast(branch_ip));
            e.delta_stp = @as(i32, @intCast(target.start_stp)) - @as(i32, @intCast(idx));
        } else {
            // Forward target: patch at the construct's `end`.
            try target.pending.append(self.arena, .{ .entry = idx, .ip = branch_ip });
        }
        return idx;
    }

    /// Patch every forward branch that targeted a just-closed
    /// construct, given the position past its `end`.
    fn patchPending(self: *Validator, c: *Ctrl, after_end_ip: u32) void {
        const end_stp: u32 = @intCast(self.side_table.items.len);
        for (c.pending.items) |p| {
            const e = &self.side_table.items[p.entry];
            e.delta_ip = @as(i32, @intCast(after_end_ip)) - @as(i32, @intCast(p.ip));
            e.delta_stp = @as(i32, @intCast(end_stp)) - @as(i32, @intCast(p.entry));
        }
    }
};

fn validateFunc(
    arena: std.mem.Allocator,
    module: *const Module,
    type_index: u32,
    body_bytes: []const u8,
) ValidateError!CompiledFunc {
    const ft = module.types[type_index];

    // Parse the locals header (§5.5.13): vec((count, valtype)).
    var br = Reader.init(body_bytes);
    const group_count = try br.uleb(u32);
    var locals: std.ArrayListUnmanaged(ValType) = .empty;
    try locals.appendSlice(arena, ft.params);
    var g: u32 = 0;
    while (g < group_count) : (g += 1) {
        const n = try br.uleb(u32);
        const vt = ValType.fromByte(try br.byte()) orelse return error.BadValType;
        // Guard against a pathological local count blowing up memory.
        if (n > 1_000_000) return error.InvalidLocalCount;
        var k: u32 = 0;
        while (k < n) : (k += 1) try locals.append(arena, vt);
    }
    const local_types = try locals.toOwnedSlice(arena);
    const expr = body_bytes[br.pos..];

    var has_memory = module.mems.len > 0;
    for (module.imports) |imp| {
        if (imp.desc == .mem) has_memory = true;
    }

    var v: Validator = .{
        .arena = arena,
        .module = module,
        .local_types = local_types,
        .results = ft.results,
        .has_memory = has_memory,
        .r = Reader.init(expr),
    };

    // The implicit function-level block: its results are the function
    // results, and its `end` is the body's terminating `end`.
    try v.ctrls.append(arena, .{
        .op = .block,
        .start_types = &.{},
        .end_types = ft.results,
        .height = 0,
        .entered_reachable = true,
        .start_ip = 0,
        .start_stp = 0,
    });

    try validateExpr(&v);

    return .{
        .type_index = type_index,
        .local_types = local_types,
        .body = expr,
        .side_table = try v.side_table.toOwnedSlice(arena),
        .max_stack = v.max_stack,
    };
}

fn readBlockType(v: *Validator) !BlockType {
    // §5.3.2 — an s33: negative encodes empty (0x40) or a single
    // valtype; non-negative is a type index.
    const peek = try v.r.peek();
    if (peek == 0x40) {
        _ = try v.r.byte();
        return .{ .params = &.{}, .results = &.{} };
    }
    if (ValType.fromByte(peek)) |vt| {
        _ = try v.r.byte();
        const one = try v.arena.alloc(ValType, 1);
        one[0] = vt;
        return .{ .params = &.{}, .results = one };
    }
    const idx = try v.r.sleb(i33);
    if (idx < 0 or @as(u64, @intCast(idx)) >= v.module.types.len) return error.BadBlockType;
    const ft = v.module.types[@intCast(idx)];
    return .{ .params = ft.params, .results = ft.results };
}

/// Map an index in the function index space to its type signature,
/// accounting for imported functions preceding the defined ones.
fn funcType(module: *const Module, func_index: u32) !types.FuncType {
    var imported: u32 = 0;
    for (module.imports) |imp| {
        if (imp.desc == .func) {
            if (func_index == imported) {
                if (imp.desc.func >= module.types.len) return error.UnknownType;
                return module.types[imp.desc.func];
            }
            imported += 1;
        }
    }
    const local_index = func_index - imported;
    if (local_index >= module.funcs.len) return error.UnknownFunc;
    const ti = module.funcs[local_index];
    if (ti >= module.types.len) return error.UnknownType;
    return module.types[ti];
}

fn validateExpr(v: *Validator) ValidateError!void {
    while (true) {
        const op_ip: u32 = @intCast(v.r.pos);
        const op: Op = @enumFromInt(try v.r.byte());
        switch (op) {
            .nop => {},
            .@"unreachable" => v.setUnreachable(),

            .block, .loop => {
                const bt = try readBlockType(v);
                try v.popVals(bt.params);
                const body_ip: u32 = @intCast(v.r.pos);
                try v.pushCtrl(op, bt.params, bt.results, body_ip);
            },
            .@"if" => {
                const bt = try readBlockType(v);
                try v.popExpect(.i32); // condition
                try v.popVals(bt.params);
                const reachable_here = v.reachable();
                const body_ip: u32 = @intCast(v.r.pos);
                try v.pushCtrl(.@"if", bt.params, bt.results, body_ip);
                // The `if`'s false edge is a forward branch (to else or
                // end) carrying nothing: the params are already on the
                // stack as the block's operands.
                if (reachable_here) {
                    const idx: u32 = @intCast(v.side_table.items.len);
                    try v.side_table.append(v.arena, .{ .delta_ip = 0, .delta_stp = 0, .val_count = 0, .pop_count = 0 });
                    const c = &v.ctrls.items[v.ctrls.items.len - 1];
                    c.if_entry = idx;
                    c.if_ip = op_ip;
                }
            },
            .@"else" => {
                var c = v.ctrls.items[v.ctrls.items.len - 1];
                if (c.op != .@"if") return error.UnexpectedElse;
                // Close the then-arm: it must have produced end_types.
                try v.popVals(c.end_types);
                if (v.vals.items.len != c.height) return error.TypeMismatch;
                // `else` is an unconditional forward branch to `end`,
                // carrying the block results.
                var else_entry: ?u32 = null;
                if (c.entered_reachable) {
                    else_entry = @intCast(v.side_table.items.len);
                    try v.side_table.append(v.arena, .{
                        .delta_ip = 0,
                        .delta_stp = 0,
                        .val_count = @intCast(c.end_types.len),
                        .pop_count = 0,
                    });
                    try c.pending.append(v.arena, .{ .entry = else_entry.?, .ip = op_ip });
                    // Resolve the `if`'s false edge to the else body.
                    if (c.if_entry) |ie| {
                        const else_body_ip: u32 = @intCast(v.r.pos);
                        const e = &v.side_table.items[ie];
                        e.delta_ip = @as(i32, @intCast(else_body_ip)) - @as(i32, @intCast(c.if_ip));
                        e.delta_stp = @as(i32, @intCast(else_entry.? + 1)) - @as(i32, @intCast(ie));
                    }
                }
                // Re-open as the else-arm: same label types, reachable
                // afresh, params back on the stack.
                c.op = .@"else";
                c.unreachable_ = false;
                c.if_entry = null;
                v.ctrls.items[v.ctrls.items.len - 1] = c;
                v.vals.shrinkRetainingCapacity(c.height);
                try v.pushVals(c.start_types);
            },
            .end => {
                var c = try v.popCtrl();
                const after_end_ip: u32 = @intCast(v.r.pos);
                // An `if` with no `else`: the empty else must map params
                // to results, so they must match.
                if (c.op == .@"if") {
                    if (!sameTypes(c.start_types, c.end_types)) return error.TypeMismatch;
                    // Resolve the `if`'s false edge straight to `end`.
                    if (c.if_entry) |ie| {
                        const e = &v.side_table.items[ie];
                        e.delta_ip = @as(i32, @intCast(after_end_ip)) - @as(i32, @intCast(c.if_ip));
                        e.delta_stp = @as(i32, @intCast(v.side_table.items.len)) - @as(i32, @intCast(ie));
                    }
                }
                v.patchPending(&c, after_end_ip);
                try v.pushVals(c.end_types);
                if (v.ctrls.items.len == 0) return; // function `end`
            },

            .br => {
                const n = try v.r.uleb(u32);
                const target = try v.label(n);
                _ = try v.emitBranch(op_ip, target);
                try v.popVals(target.labelTypes());
                v.setUnreachable();
            },
            .br_if => {
                const n = try v.r.uleb(u32);
                const target = try v.label(n);
                try v.popExpect(.i32); // condition
                _ = try v.emitBranch(op_ip, target);
                try v.popVals(target.labelTypes());
                try v.pushVals(target.labelTypes());
            },
            .@"return" => {
                try v.popVals(v.results);
                v.setUnreachable();
            },
            .call => {
                const fidx = try v.r.uleb(u32);
                const ft = try funcType(v.module, fidx);
                try v.popVals(ft.params);
                try v.pushVals(ft.results);
            },

            .drop => {
                _ = try v.popVal();
            },
            .select => {
                try v.popExpect(.i32);
                const a = try v.popVal();
                const b = try v.popVal();
                // Untyped select: operands must be a matching number
                // type (refs require the typed form, added later).
                const t = a orelse b;
                if (a != null and b != null and a.? != b.?) return error.TypeMismatch;
                if (t) |tt| {
                    if (!tt.isNum() and !tt.isVec()) return error.TypeMismatch;
                }
                try v.pushVal(t);
            },

            .local_get => {
                const x = try v.r.uleb(u32);
                if (x >= v.local_types.len) return error.UnknownLocal;
                try v.pushVal(v.local_types[x]);
            },
            .local_set => {
                const x = try v.r.uleb(u32);
                if (x >= v.local_types.len) return error.UnknownLocal;
                try v.popExpect(v.local_types[x]);
            },
            .local_tee => {
                const x = try v.r.uleb(u32);
                if (x >= v.local_types.len) return error.UnknownLocal;
                try v.popExpect(v.local_types[x]);
                try v.pushVal(v.local_types[x]);
            },
            .global_get => {
                const x = try v.r.uleb(u32);
                const gt = try globalType(v.module, x);
                try v.pushVal(gt.val);
            },
            .global_set => {
                const x = try v.r.uleb(u32);
                const gt = try globalType(v.module, x);
                if (gt.mut != .mutable) return error.ImmutableGlobal;
                try v.popExpect(gt.val);
            },

            .i32_const => {
                _ = try v.r.sleb(i32);
                try v.pushVal(.i32);
            },
            .i64_const => {
                _ = try v.r.sleb(i64);
                try v.pushVal(.i64);
            },

            .i32_eqz => try unop(v, .i32, .i32),
            .i64_eqz => try unop(v, .i64, .i32),

            .i32_eq, .i32_ne, .i32_lt_s, .i32_lt_u, .i32_gt_s, .i32_gt_u, .i32_le_s, .i32_le_u, .i32_ge_s, .i32_ge_u => try binop(v, .i32, .i32),
            .i64_eq, .i64_ne, .i64_lt_s, .i64_lt_u, .i64_gt_s, .i64_gt_u, .i64_le_s, .i64_le_u, .i64_ge_s, .i64_ge_u => try binop(v, .i64, .i32),

            .i32_add, .i32_sub, .i32_mul, .i32_div_s, .i32_div_u, .i32_rem_s, .i32_rem_u, .i32_and, .i32_or, .i32_xor, .i32_shl, .i32_shr_s, .i32_shr_u, .i32_rotl, .i32_rotr => try binop(v, .i32, .i32),
            .i64_add, .i64_sub, .i64_mul, .i64_div_s, .i64_div_u, .i64_rem_s, .i64_rem_u, .i64_and, .i64_or, .i64_xor, .i64_shl, .i64_shr_s, .i64_shr_u, .i64_rotl, .i64_rotr => try binop(v, .i64, .i64),

            // Integer unary (count bits) and sign extension.
            .i32_clz, .i32_ctz, .i32_popcnt, .i32_extend8_s, .i32_extend16_s => try unop(v, .i32, .i32),
            .i64_clz, .i64_ctz, .i64_popcnt, .i64_extend8_s, .i64_extend16_s, .i64_extend32_s => try unop(v, .i64, .i64),

            // Float constants.
            .f32_const => {
                _ = try v.r.bytesN(4);
                try v.pushVal(.f32);
            },
            .f64_const => {
                _ = try v.r.bytesN(8);
                try v.pushVal(.f64);
            },

            // Float comparisons → i32.
            .f32_eq, .f32_ne, .f32_lt, .f32_gt, .f32_le, .f32_ge => try binop(v, .f32, .i32),
            .f64_eq, .f64_ne, .f64_lt, .f64_gt, .f64_le, .f64_ge => try binop(v, .f64, .i32),

            // Float unary / binary arithmetic.
            .f32_abs, .f32_neg, .f32_ceil, .f32_floor, .f32_trunc, .f32_nearest, .f32_sqrt => try unop(v, .f32, .f32),
            .f32_add, .f32_sub, .f32_mul, .f32_div, .f32_min, .f32_max, .f32_copysign => try binop(v, .f32, .f32),
            .f64_abs, .f64_neg, .f64_ceil, .f64_floor, .f64_trunc, .f64_nearest, .f64_sqrt => try unop(v, .f64, .f64),
            .f64_add, .f64_sub, .f64_mul, .f64_div, .f64_min, .f64_max, .f64_copysign => try binop(v, .f64, .f64),

            // Memory loads: pop the i32 address, push the result.
            .i32_load, .i32_load8_s, .i32_load8_u, .i32_load16_s, .i32_load16_u => try load(v, .i32),
            .i64_load, .i64_load8_s, .i64_load8_u, .i64_load16_s, .i64_load16_u, .i64_load32_s, .i64_load32_u => try load(v, .i64),
            .f32_load => try load(v, .f32),
            .f64_load => try load(v, .f64),
            // Memory stores: pop the value, then the i32 address.
            .i32_store, .i32_store8, .i32_store16 => try store(v, .i32),
            .i64_store, .i64_store8, .i64_store16, .i64_store32 => try store(v, .i64),
            .f32_store => try store(v, .f32),
            .f64_store => try store(v, .f64),

            .memory_size => {
                try requireMemory(v);
                _ = try v.r.byte(); // reserved memory index
                try v.pushVal(.i32);
            },
            .memory_grow => {
                try requireMemory(v);
                _ = try v.r.byte();
                try v.popExpect(.i32);
                try v.pushVal(.i32);
            },

            .prefix_fc => {
                const sub = try v.r.uleb(u32);
                switch (sub) {
                    10 => { // memory.copy
                        try requireMemory(v);
                        _ = try v.r.byte(); // dst memidx
                        _ = try v.r.byte(); // src memidx
                        try v.popExpect(.i32);
                        try v.popExpect(.i32);
                        try v.popExpect(.i32);
                    },
                    11 => { // memory.fill
                        try requireMemory(v);
                        _ = try v.r.byte(); // memidx
                        try v.popExpect(.i32);
                        try v.popExpect(.i32);
                        try v.popExpect(.i32);
                    },
                    else => return error.UnknownOpcode,
                }
            },

            _ => return error.UnknownOpcode,
        }
    }
}

fn requireMemory(v: *Validator) !void {
    if (!v.has_memory) return error.NoMemory;
}

fn load(v: *Validator, result: ValType) !void {
    try requireMemory(v);
    try skipMemarg(v);
    try v.popExpect(.i32); // address
    try v.pushVal(result);
}

fn store(v: *Validator, value: ValType) !void {
    try requireMemory(v);
    try skipMemarg(v);
    try v.popExpect(value); // value
    try v.popExpect(.i32); // address
}

fn skipMemarg(v: *Validator) !void {
    _ = try v.r.uleb(u32); // align (log2)
    _ = try v.r.uleb(u32); // offset
}

fn unop(v: *Validator, in: ValType, out: ValType) !void {
    try v.popExpect(in);
    try v.pushVal(out);
}

fn binop(v: *Validator, in: ValType, out: ValType) !void {
    try v.popExpect(in);
    try v.popExpect(in);
    try v.pushVal(out);
}

fn globalType(module: *const Module, global_index: u32) !types.GlobalType {
    var imported: u32 = 0;
    for (module.imports) |imp| {
        if (imp.desc == .global) {
            if (global_index == imported) return imp.desc.global;
            imported += 1;
        }
    }
    const local_index = global_index - imported;
    if (local_index >= module.globals.len) return error.UnknownGlobal;
    return module.globals[local_index].type;
}

fn sameTypes(a: []const ValType, b: []const ValType) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| if (x != y) return false;
    return true;
}
