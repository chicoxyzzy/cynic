//! Lightweight block + register-liveness analysis over a finalized,
//! linear bytecode chunk. This is the substrate the front-end
//! optimization campaign sits on: P1 (liveness-driven register
//! allocation) and P2 (DCE / jump threading) consume it. It is
//! deliberately NOT a full SSA/CFG IR — just block boundaries,
//! reachability, and per-register liveness, computed once per function.
//!
//! Analysis-only: nothing here mutates bytecode. A consumer that
//! rewrites (P1) re-emits and re-patches jumps itself.
//!
//! ## Safety model (load-bearing)
//!
//! Liveness drives register *reuse*. The only way a reuse can miscompile
//! is to believe a register is dead when a later instruction still reads
//! it — i.e. to MISS a register read. Two invariants prevent that:
//!
//!  1. Every register-operand byte of every modelled opcode is recorded
//!     as at least a READ (`Effect.read*`). Recording an actual *write*
//!     as a read only over-extends a live range (pins a slot) — safe,
//!     merely suboptimal. So when read/write direction is uncertain we
//!     mark READ.
//!  2. `effectOf` returns `.opaque_bail` for any opcode whose operand
//!     layout we have not explicitly modelled (the `else` arm). A
//!     function containing an opaque op has `fully_understood == false`,
//!     and P1 must refuse to reallocate it. New opcodes therefore fail
//!     safe (no optimization) until classified here.

const std = @import("std");
const Op = @import("op.zig").Op;
const Handler = @import("chunk.zig").Handler;

fn readI16(code: []const u8, at: usize) i16 {
    return std.mem.bytesToValue(i16, code[at..][0..2]);
}

/// The register-level effect of one instruction. `reads` / `write` are
/// discrete register indices; `win_*` is the inclusive arg/operand
/// window `[win_base, win_base + win_len)` that call-family ops read.
/// `opaque_bail` means the op's layout isn't modelled (fail safe).
pub const Effect = struct {
    reads: [2]u8 = .{ 0, 0 },
    n_reads: u8 = 0,
    write: ?u8 = null,
    win_base: u8 = 0,
    win_len: u16 = 0,
    opaque_bail: bool = false,

    fn read1(r: u8) Effect {
        return .{ .reads = .{ r, 0 }, .n_reads = 1 };
    }
    fn read2(a: u8, b: u8) Effect {
        return .{ .reads = .{ a, b }, .n_reads = 2 };
    }
    fn writeReg(r: u8) Effect {
        return .{ .write = r };
    }
};

/// Register effect of the instruction at `code[i]`. The operand byte
/// positions mirror the emit helpers / disasm layout exactly; see the
/// safety model above for why uncertain cases fall to READ or bail.
pub fn effectOf(op: Op, code: []const u8, i: usize) Effect {
    return switch (op) {
        // ── Pure accumulator / immediate / constant / env / global —
        // no register operands. Listed explicitly so a function built
        // only from these stays `fully_understood`.
        .lda_undefined,
        .lda_null,
        .lda_true,
        .lda_false,
        .lda_hole,
        .lda_zero,
        .lda_one,
        .lda_smi,
        .lda_constant,
        .lda_this,
        .lda_new_target,
        .lda_arguments,
        .import_meta,
        .lda_property,
        .lda_global,
        .lda_global_or_undef,
        .lda_global_slot,
        .sta_global_slot,
        .sta_global_slot_init,
        .lda_env,
        .sta_env,
        .make_environment,
        .pop_env,
        .negate,
        .bit_not,
        .logical_not,
        .to_number,
        .to_numeric,
        .to_string,
        .to_int32,
        .inc,
        .dec,
        .typeof_,
        .to_property_key,
        .throw_,
        .throw_if_hole,
        .throw_assign_const,
        .throw_if_not_object,
        .require_object_coercible,
        .return_,
        .make_object,
        .make_array,
        // `make_function` is `[op][k:u16]` — builds a closure from a template
        // + the current environment, reading no register (captured variables
        // live in the environment, not registers; capture forces env
        // promotion, so a register-resident local is never captured). Modelled
        // as no-effect so a chunk that merely declares a closure stays
        // fully-understood and the register passes still fire on it.
        .make_function,
        => .{},

        // ── Register reads (one source register; acc is implicit) ──
        .ldar => Effect.read1(code[i + 1]),
        .add,
        .sub,
        .mul,
        .div,
        .mod,
        .pow,
        .bit_and,
        .bit_or,
        .bit_xor,
        .shl,
        .shr,
        .shr_u,
        .eq,
        .strict_eq,
        .neq,
        .strict_neq,
        .lt,
        .gt,
        .le,
        .ge,
        .instanceof_,
        .in_op,
        .array_spread,
        => Effect.read1(code[i + 1]),
        // Fused compare-and-branch `[op][r:u8][off:i16]` — reads the
        // register operand (the compared lhs); the branch edge is handled
        // by the leader/CFG scan via `branchTarget` / `isBranch`.
        .jmp_if_strict_eq,
        .jmp_if_strict_neq,
        .jmp_if_not_lt,
        .jmp_if_not_le,
        .jmp_if_not_gt,
        .jmp_if_not_ge,
        => Effect.read1(code[i + 1]),
        .add_smi => Effect.read1(code[i + 1]),
        .lda_computed => Effect.read1(code[i + 1]),
        // `[op][k:u16][r_obj:u8]…` — receiver register at i+3.
        .lda_property_reg, .sta_property, .def_property => Effect.read1(code[i + 3]),
        .sta_computed, .def_computed => Effect.read2(code[i + 1], code[i + 2]),

        // Compact register loads/stores — index baked in the opcode.
        .ldar_0, .ldar_1, .ldar_2, .ldar_3 => Effect.read1(@intFromEnum(op) - @intFromEnum(Op.ldar_0)),

        // ── Register writes ──
        .star => Effect.writeReg(code[i + 1]),
        .star_0, .star_1, .star_2, .star_3 => Effect.writeReg(@intFromEnum(op) - @intFromEnum(Op.star_0)),
        .mov => .{ .reads = .{ code[i + 1], 0 }, .n_reads = 1, .write = code[i + 2] },

        // ── Read + write the same register (loop counter) ──
        // `[op][r_counter:u8][r_bound:u8][off:i16]` — counter is read
        // (test + increment) and written (the bumped value).
        .loop_inc_lt => .{ .reads = .{ code[i + 1], code[i + 2] }, .n_reads = 2, .write = code[i + 1] },

        // ── Control flow (no register operands; edges handled by the
        // leader/CFG scan, not the register model) ──
        .jmp, .jmp_if_true, .jmp_if_false, .jmp_if_nullish => .{},

        // ── Call family — read the callee/receiver and the contiguous
        // argument window `[base+1 .. base+1+argc)`. Modelled as one
        // read window `[base .. base+argc]` (base + args). ──
        // `[op][r_callee:u8][argc:u8][ic:u16]`
        .call, .new_call => .{ .win_base = code[i + 1], .win_len = @as(u16, code[i + 2]) + 1 },
        // `[op][r_callee:u8][ic:u16]` — argc folded into the opcode.
        .call0, .call1, .call2, .call3 => .{
            .win_base = code[i + 1],
            .win_len = (@intFromEnum(op) - @intFromEnum(Op.call0)) + 1,
        },
        // `[op][r_recv:u8][r_callee:u8][argc:u8][ic:u16]` — receiver
        // plus the callee+args window.
        .call_method => .{
            .reads = .{ code[i + 1], 0 },
            .n_reads = 1,
            .win_base = code[i + 2],
            .win_len = @as(u16, code[i + 3]) + 1,
        },
        // `[op][k:u16][r_recv:u8][argc:u8][ic:u16][callic:u16]` —
        // receiver plus the arg window placed after it (conservative).
        .call_property => .{ .win_base = code[i + 3], .win_len = @as(u16, code[i + 4]) + 1 },

        // ── Everything else: not modelled → fail safe. A function
        // containing one of these is not `fully_understood`, so P1
        // leaves it alone. (super_call, make_class, def_template_property,
        // sta_private, generator/iterator/module/dispose ops, …) ──
        else => .{ .opaque_bail = true },
    };
}

/// Returns the branch target offset for a control-transfer op, or null
/// if the op doesn't branch. Offsets are i16 relative to the byte after
/// the operand (matching `Builder.patchI16`).
pub fn branchTarget(op: Op, code: []const u8, i: usize) ?u32 {
    return switch (op) {
        .jmp, .jmp_if_true, .jmp_if_false, .jmp_if_nullish => blk: {
            const after: i64 = @intCast(i + 1 + 2);
            break :blk @intCast(after + readI16(code, i + 1));
        },
        .loop_inc_lt => blk: {
            const after: i64 = @intCast(i + 1 + 4);
            break :blk @intCast(after + readI16(code, i + 3));
        },
        // Fused compare-and-branch `[op][r:u8][off:i16]` — i16 at i+2,
        // relative to the byte after the operand (i + 1 + 3).
        .jmp_if_strict_eq,
        .jmp_if_strict_neq,
        .jmp_if_not_lt,
        .jmp_if_not_le,
        .jmp_if_not_gt,
        .jmp_if_not_ge,
        => blk: {
            const after: i64 = @intCast(i + 1 + 3);
            break :blk @intCast(after + readI16(code, i + 2));
        },
        else => null,
    };
}

fn isUnconditionalTransfer(op: Op) bool {
    return switch (op) {
        .jmp, .return_, .throw_ => true,
        else => false,
    };
}

fn isBranch(op: Op) bool {
    return switch (op) {
        .jmp,
        .jmp_if_true,
        .jmp_if_false,
        .jmp_if_nullish,
        .loop_inc_lt,
        .jmp_if_strict_eq,
        .jmp_if_strict_neq,
        .jmp_if_not_lt,
        .jmp_if_not_le,
        .jmp_if_not_gt,
        .jmp_if_not_ge,
        => true,
        else => false,
    };
}

pub const Analysis = struct {
    allocator: std.mem.Allocator,
    /// Sorted block-leader offsets; block `b` spans `[leaders[b], leaders[b+1])`.
    leaders: []u32,
    /// Per-block forward control-flow successors (block indices; up to two —
    /// branch target + fall-through). `null` slots are unused. Handler edges
    /// are NOT included here (consumers that care bail on handlers). Exposed
    /// for forward dataflow passes (e.g. TDZ-check elimination).
    succs: [][2]?usize,
    /// `reachable.isSet(b)` — block `b` is reachable from entry.
    reachable: std.DynamicBitSet,
    /// Per-block register live-in / live-out sets (size `register_count`).
    live_in: []std.DynamicBitSet,
    live_out: []std.DynamicBitSet,
    register_count: u16,
    /// True iff every opcode's register effect was modelled exactly.
    /// P1 must check this before reallocating registers.
    fully_understood: bool,

    pub fn blockCount(self: *const Analysis) usize {
        return self.leaders.len;
    }

    /// Index of the block containing offset `off`.
    pub fn blockOf(self: *const Analysis, off: u32) usize {
        // leaders is sorted; find the last leader <= off.
        var lo: usize = 0;
        var hi: usize = self.leaders.len;
        while (lo + 1 < hi) {
            const mid = (lo + hi) / 2;
            if (self.leaders[mid] <= off) lo = mid else hi = mid;
        }
        return lo;
    }

    /// Registers live at the program point immediately AFTER the
    /// instruction at `off` (i.e. live-in of the next instruction).
    /// Caller owns the returned set. Used to detect dead stores
    /// (`Star rX` is dead iff `rX` ∉ liveAfter(off)) and interference.
    pub fn liveAfter(self: *const Analysis, code: []const u8, off: u32) !std.DynamicBitSet {
        const blk = self.blockOf(off);
        var live = try std.DynamicBitSet.initEmpty(self.allocator, self.register_count);
        live.setUnion(self.live_out[blk]);
        const end: u32 = if (blk + 1 < self.leaders.len) self.leaders[blk + 1] else @intCast(code.len);
        // Collect instruction offsets strictly after `off`, then apply the
        // reverse transfer in reverse program order: starting from the
        // block's live_out, `live = (live − writes) ∪ reads` per insn
        // yields the live set just after `off`.
        var insn: std.ArrayListUnmanaged(u32) = .empty;
        defer insn.deinit(self.allocator);
        var p: u32 = self.leaders[blk];
        while (p < end) {
            if (p > off) try insn.append(self.allocator, p);
            const op: Op = @enumFromInt(code[p]);
            p += 1 + Op.operandSize(op);
        }
        var idx: usize = insn.items.len;
        while (idx > 0) {
            idx -= 1;
            const at = insn.items[idx];
            const op: Op = @enumFromInt(code[at]);
            const e = effectOf(op, code, at);
            if (e.write) |w| {
                if (w < self.register_count) live.unset(w);
            }
            var ri: u8 = 0;
            while (ri < e.n_reads) : (ri += 1) {
                if (e.reads[ri] < self.register_count) live.set(e.reads[ri]);
            }
            if (e.win_len > 0) {
                var w: u32 = e.win_base;
                const wend = @as(u32, e.win_base) + e.win_len;
                while (w < wend) : (w += 1) if (w < self.register_count) live.set(@intCast(w));
            }
        }
        return live;
    }

    pub fn deinit(self: *Analysis) void {
        self.allocator.free(self.leaders);
        self.allocator.free(self.succs);
        self.reachable.deinit();
        for (self.live_in) |*s| s.deinit();
        for (self.live_out) |*s| s.deinit();
        self.allocator.free(self.live_in);
        self.allocator.free(self.live_out);
    }
};

/// Compute the block/liveness analysis for `code`. `handlers` supplies
/// try/catch/finally entry offsets (each is a block leader and an
/// implicit successor of every block in its protected range). Caller
/// owns the returned `Analysis` (`deinit`).
pub fn analyze(
    allocator: std.mem.Allocator,
    code: []const u8,
    register_count: u16,
    handlers: []const Handler,
) !Analysis {
    var fully_understood = true;

    // ── Pass 1: instruction offsets + leader set ──
    var leader_set: std.AutoHashMapUnmanaged(u32, void) = .empty;
    defer leader_set.deinit(allocator);
    try leader_set.put(allocator, 0, {});
    for (handlers) |h| try leader_set.put(allocator, h.handler_pc, {});

    var offsets: std.ArrayListUnmanaged(u32) = .empty;
    defer offsets.deinit(allocator);

    var i: usize = 0;
    while (i < code.len) {
        const op: Op = @enumFromInt(code[i]);
        try offsets.append(allocator, @intCast(i));
        if (effectOf(op, code, i).opaque_bail) fully_understood = false;
        if (branchTarget(op, code, i)) |t| try leader_set.put(allocator, t, {});
        const next = i + 1 + Op.operandSize(op);
        // The instruction after any branch / terminator starts a block.
        if (isBranch(op) or isUnconditionalTransfer(op)) {
            if (next < code.len) try leader_set.put(allocator, @intCast(next), {});
        }
        i = next;
    }

    // ── Sort leaders → blocks ──
    var leaders = try allocator.alloc(u32, leader_set.count());
    errdefer allocator.free(leaders);
    {
        var it = leader_set.keyIterator();
        var n: usize = 0;
        while (it.next()) |k| : (n += 1) leaders[n] = k.*;
        std.mem.sort(u32, leaders, {}, std.sort.asc(u32));
    }
    const nblocks = leaders.len;

    // block end offset (exclusive)
    const blockEnd = struct {
        fn f(lds: []const u32, code_len: usize, b: usize) u32 {
            return if (b + 1 < lds.len) lds[b + 1] else @intCast(code_len);
        }
    }.f;

    // ── Successors + per-block use/def ──
    var succs = try allocator.alloc([2]?usize, nblocks);
    errdefer allocator.free(succs);
    var use = try allocator.alloc(std.DynamicBitSet, nblocks);
    var def = try allocator.alloc(std.DynamicBitSet, nblocks);
    defer {
        for (use) |*s| s.deinit();
        for (def) |*s| s.deinit();
        allocator.free(use);
        allocator.free(def);
    }
    // protected-range handler edges: a block whose range is covered by a
    // handler gets an extra successor to that handler's entry block.
    for (0..nblocks) |b| {
        succs[b] = .{ null, null };
        use[b] = try std.DynamicBitSet.initEmpty(allocator, register_count);
        def[b] = try std.DynamicBitSet.initEmpty(allocator, register_count);

        const start = leaders[b];
        const end = blockEnd(leaders, code.len, b);

        // Walk the block forward to compute use/def and find its terminator.
        var defined = try std.DynamicBitSet.initEmpty(allocator, register_count);
        defer defined.deinit();
        var p: usize = start;
        var last_op: Op = .lda_undefined;
        var last_off: usize = start;
        while (p < end) {
            const op: Op = @enumFromInt(code[p]);
            last_op = op;
            last_off = p;
            const e = effectOf(op, code, p);
            // reads before any in-block def → uses
            var ri: u8 = 0;
            while (ri < e.n_reads) : (ri += 1) {
                const r = e.reads[ri];
                if (r < register_count and !defined.isSet(r)) use[b].set(r);
            }
            if (e.win_len > 0) {
                var w: u32 = e.win_base;
                const wend = @as(u32, e.win_base) + e.win_len;
                while (w < wend) : (w += 1) {
                    if (w < register_count and !defined.isSet(@intCast(w))) use[b].set(@intCast(w));
                }
            }
            if (e.write) |wr| {
                if (wr < register_count) {
                    def[b].set(wr);
                    defined.set(wr);
                }
            }
            p += 1 + Op.operandSize(op);
        }

        // Successor edges from the terminator.
        if (branchTarget(last_op, code, last_off)) |t| {
            succs[b][0] = blockOfLeader(leaders, t);
            if (!isUnconditionalTransfer(last_op)) {
                // conditional branch / loop also falls through
                if (end < code.len) succs[b][1] = blockOfLeader(leaders, end);
            }
        } else if (!isUnconditionalTransfer(last_op)) {
            // plain fall-through
            if (end < code.len) succs[b][0] = blockOfLeader(leaders, end);
        }
    }

    // handler edges: for each handler, every block whose start is within
    // [protected_start, protected_end) gains an edge to the handler entry.
    // We don't store a third successor slot; instead we union the handler's
    // live-in during the fixpoint via an explicit extra-successor list.
    var handler_edges: std.ArrayListUnmanaged([2]usize) = .empty; // (from_block, to_block)
    defer handler_edges.deinit(allocator);
    // NOTE: `catch_register` is written by the unwinder at handler entry,
    // not by an opcode, so liveness sees no def for it — it stays
    // conservatively live across the protected range (pinned, never
    // reused). Safe (over-live), merely suboptimal; P1 may refine later.
    for (handlers) |h| {
        const hb = blockOfLeader(leaders, h.handler_pc);
        for (0..nblocks) |b| {
            const s = leaders[b];
            if (s >= h.start_pc and s < h.end_pc) {
                try handler_edges.append(allocator, .{ b, hb });
            }
        }
    }

    // ── Reachability ──
    var reachable = try std.DynamicBitSet.initEmpty(allocator, nblocks);
    errdefer reachable.deinit();
    {
        var stack: std.ArrayListUnmanaged(usize) = .empty;
        defer stack.deinit(allocator);
        try stack.append(allocator, 0);
        reachable.set(0);
        // handler entries are reachable via throw edges
        for (handler_edges.items) |e| {
            if (!reachable.isSet(e[1])) {
                reachable.set(e[1]);
                try stack.append(allocator, e[1]);
            }
        }
        while (stack.pop()) |b| {
            for (succs[b]) |maybe| {
                if (maybe) |s| if (!reachable.isSet(s)) {
                    reachable.set(s);
                    try stack.append(allocator, s);
                };
            }
        }
    }

    // ── Liveness fixpoint (backward dataflow) ──
    var live_in = try allocator.alloc(std.DynamicBitSet, nblocks);
    errdefer {
        for (live_in) |*s| s.deinit();
        allocator.free(live_in);
    }
    var live_out = try allocator.alloc(std.DynamicBitSet, nblocks);
    errdefer {
        for (live_out) |*s| s.deinit();
        allocator.free(live_out);
    }
    for (0..nblocks) |b| {
        live_in[b] = try std.DynamicBitSet.initEmpty(allocator, register_count);
        live_out[b] = try std.DynamicBitSet.initEmpty(allocator, register_count);
    }
    var changed = true;
    while (changed) {
        changed = false;
        // iterate blocks in reverse for faster convergence
        var bi: usize = nblocks;
        while (bi > 0) {
            bi -= 1;
            // live_out[b] = ∪ live_in[succ]  (+ handler entries)
            var new_out = try std.DynamicBitSet.initEmpty(allocator, register_count);
            defer new_out.deinit();
            for (succs[bi]) |maybe| {
                if (maybe) |s| new_out.setUnion(live_in[s]);
            }
            for (handler_edges.items) |e| {
                if (e[0] == bi) new_out.setUnion(live_in[e[1]]);
            }
            // live_in[b] = use[b] ∪ (live_out[b] − def[b])
            var new_in = try std.DynamicBitSet.initEmpty(allocator, register_count);
            defer new_in.deinit();
            new_in.setUnion(new_out); // = live_out
            var dit = def[bi].iterator(.{});
            while (dit.next()) |r| new_in.unset(r); // − def
            new_in.setUnion(use[bi]); // ∪ use

            if (!bitsetEql(new_out, live_out[bi])) changed = true;
            if (!bitsetEql(new_in, live_in[bi])) changed = true;
            live_out[bi].setRangeValue(.{ .start = 0, .end = register_count }, false);
            live_out[bi].setUnion(new_out);
            live_in[bi].setRangeValue(.{ .start = 0, .end = register_count }, false);
            live_in[bi].setUnion(new_in);
        }
    }

    return .{
        .allocator = allocator,
        .leaders = leaders,
        .succs = succs,
        .reachable = reachable,
        .live_in = live_in,
        .live_out = live_out,
        .register_count = register_count,
        .fully_understood = fully_understood,
    };
}

fn blockOfLeader(leaders: []const u32, off: u32) usize {
    var lo: usize = 0;
    var hi: usize = leaders.len;
    while (lo + 1 < hi) {
        const mid = (lo + hi) / 2;
        if (leaders[mid] <= off) lo = mid else hi = mid;
    }
    return lo;
}

fn bitsetEql(a: std.DynamicBitSet, b: std.DynamicBitSet) bool {
    var it = a.iterator(.{});
    var count_a: usize = 0;
    while (it.next()) |idx| {
        count_a += 1;
        if (!b.isSet(idx)) return false;
    }
    return count_a == b.count();
}

// ─────────────────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────────────────

const testing = std.testing;
fn byteOf(o: Op) u8 {
    return @intFromEnum(o);
}

test "liveness: effectOf classifies register operands" {
    var ldar = [_]u8{ byteOf(.ldar), 3 };
    const e_ldar = effectOf(.ldar, &ldar, 0);
    try testing.expectEqual(@as(u8, 1), e_ldar.n_reads);
    try testing.expectEqual(@as(u8, 3), e_ldar.reads[0]);
    try testing.expectEqual(@as(?u8, null), e_ldar.write);

    var star = [_]u8{ byteOf(.star), 5 };
    try testing.expectEqual(@as(?u8, 5), effectOf(.star, &star, 0).write);

    // compact Ldar2 reads r2 (index from the opcode, no operand byte).
    var l2 = [_]u8{byteOf(.ldar_2)};
    try testing.expectEqual(@as(u8, 2), effectOf(.ldar_2, &l2, 0).reads[0]);

    // mov reads src, writes dst.
    var mov = [_]u8{ byteOf(.mov), 1, 2 };
    const e_mov = effectOf(.mov, &mov, 0);
    try testing.expectEqual(@as(u8, 1), e_mov.reads[0]);
    try testing.expectEqual(@as(?u8, 2), e_mov.write);

    // loop_inc_lt reads counter+bound, writes counter.
    var lil = [_]u8{ byteOf(.loop_inc_lt), 1, 2, 0, 0 };
    const e_lil = effectOf(.loop_inc_lt, &lil, 0);
    try testing.expectEqual(@as(u8, 2), e_lil.n_reads);
    try testing.expectEqual(@as(?u8, 1), e_lil.write);

    // call reads the [callee .. callee+argc] window.
    var call = [_]u8{ byteOf(.call), 4, 2, 0, 0 }; // r_callee=4, argc=2
    const e_call = effectOf(.call, &call, 0);
    try testing.expectEqual(@as(u8, 4), e_call.win_base);
    try testing.expectEqual(@as(u16, 3), e_call.win_len); // r4,r5,r6

    // an unmodelled op fails safe.
    var mc = [_]u8{ byteOf(.make_class), 0, 0, 0, 0 };
    try testing.expect(effectOf(.make_class, &mc, 0).opaque_bail);
}

test "liveness: straight-line block, def-then-use register is not live-in" {
    // lda_one; star r0; ldar r0; star r1; return
    var code = [_]u8{ byteOf(.lda_one), byteOf(.star), 0, byteOf(.ldar), 0, byteOf(.star), 1, byteOf(.return_) };
    var a = try analyze(testing.allocator, &code, 4, &.{});
    defer a.deinit();
    try testing.expectEqual(@as(usize, 1), a.blockCount());
    try testing.expect(a.reachable.isSet(0));
    try testing.expect(a.fully_understood);
    try testing.expect(!a.live_in[0].isSet(0)); // r0 defined before use
    try testing.expect(!a.live_in[0].isSet(1));
}

test "liveness: a register defined before a branch is live across both arms" {
    // star r0; jmp_if_false +2 -> 7; ldar r0; ldar r0; return
    var code = [_]u8{
        byteOf(.star), 0, // 0: def r0
        byteOf(.jmp_if_false), 2, 0, // 2: -> (2+3)+2 = 7
        byteOf(.ldar), 0, // 5: then reads r0
        byteOf(.ldar), 0, // 7: join reads r0
        byteOf(.return_), // 9
    };
    var a = try analyze(testing.allocator, &code, 4, &.{});
    defer a.deinit();
    try testing.expectEqual(@as(usize, 3), a.blockCount()); // leaders 0,5,7
    for (0..3) |i| try testing.expect(a.reachable.isSet(i));
    try testing.expect(a.live_out[0].isSet(0)); // r0 live out of the test block
    try testing.expect(a.live_in[a.blockOf(5)].isSet(0)); // then-arm
    try testing.expect(a.live_in[a.blockOf(7)].isSet(0)); // join
}

test "liveness: code after an unconditional return is unreachable" {
    // lda_zero; return; star r0; return   (the star/return are dead)
    var code = [_]u8{ byteOf(.lda_zero), byteOf(.return_), byteOf(.star), 0, byteOf(.return_) };
    var a = try analyze(testing.allocator, &code, 4, &.{});
    defer a.deinit();
    try testing.expectEqual(@as(usize, 2), a.blockCount()); // leaders 0, 2
    try testing.expect(a.reachable.isSet(0));
    try testing.expect(!a.reachable.isSet(1)); // dead tail
}

test "liveness: a backward loop keeps the counter live across the back-edge" {
    var code = [_]u8{
        byteOf(.jmp_if_false), 5, 0, // 0: exit -> (0+3)+5 = 8
        byteOf(.ldar), 0, // 3: read r0 (loop body)
        byteOf(.jmp), 0xf8, 0xff, // 5: back-edge -8 -> (5+3)-8 = 0
        byteOf(.return_), // 8: exit
    };
    var a = try analyze(testing.allocator, &code, 4, &.{});
    defer a.deinit();
    try testing.expect(a.fully_understood);
    // r0 is read in the loop body and the back-edge re-enters, so r0 is
    // live at the loop header (live_in of block 0).
    try testing.expect(a.live_in[0].isSet(0));
}

test "liveness: a fused compare-and-branch is modelled (register read + branch edge)" {
    // jmp_if_not_lt r1 +2 -> 6 ; ldar r0 ; return — `[op][r:u8][off:i16]`.
    // Must be recognized as a branch (so blocks/successors are correct) and
    // as reading r1 (so a re-emit re-patches its i16 — the corruption this
    // guards against), and must NOT mark the function opaque.
    var code = [_]u8{
        byteOf(.jmp_if_not_lt), 1, 2, 0, // 0: r1, off=2, after=4 -> 6
        byteOf(.ldar), 0, // 4
        byteOf(.return_), // 6
    };
    var a = try analyze(testing.allocator, &code, 4, &.{});
    defer a.deinit();
    try testing.expect(a.fully_understood);
    try testing.expectEqual(@as(?u32, 6), branchTarget(.jmp_if_not_lt, &code, 0));
    try testing.expectEqual(@as(usize, 3), a.blockCount()); // leaders 0,4,6
    try testing.expect(a.live_in[0].isSet(1)); // r1 is read by the fused op
}

test "liveness: make_function is modelled (no register operand → no effect)" {
    // `make_function k0` is `[op][k:u16]` — it builds a closure from a
    // template + the current env, reading no register (captures live in the
    // environment, not registers). Modelling it as no-effect lets a chunk
    // that merely declares a closure stay fully-understood, so the register
    // passes still fire on the common "closure + loop" shape.
    var code = [_]u8{ byteOf(.make_function), 0, 0, byteOf(.return_) };
    var a = try analyze(testing.allocator, &code, 4, &.{});
    defer a.deinit();
    try testing.expect(a.fully_understood);
}

test "liveness: an opaque opcode marks the function not-fully-understood" {
    // make_class is not modelled → P1 must not reallocate this function.
    var code = [_]u8{ byteOf(.make_class), 0, 0, 0, 0, byteOf(.return_) };
    var a = try analyze(testing.allocator, &code, 4, &.{});
    defer a.deinit();
    try testing.expect(!a.fully_understood);
}
