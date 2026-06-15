//! P1 — liveness-driven register passes that re-emit a finalized chunk.
//!
//! First landed slice: dead-store elimination. A `Star rX` whose target
//! register is not live afterward has no observable effect (the value is
//! never read), so it is dropped — one fewer interpreter dispatch. The
//! canonical case is a script/eval completion store inside a loop body
//! (`for (…) { s = s + i; }` stores the completion every iteration, but
//! the trailing statement overwrites it), so this directly shrinks hot
//! loops.
//!
//! Re-emitting (vs in-place patching) is what lets an instruction be
//! removed: the new code buffer is rebuilt and every code-offset
//! reference is fixed up — i16-relative jumps, `source_positions`, and
//! exception `handlers`. (`jit_state` is null at compile time; constants
//! / inline caches / templates are index-based and untouched.)
//!
//! Only runs on `fully_understood` functions (every opcode's register
//! effect modelled — see liveness.zig); on any other it is a no-op, so a
//! gap in the effect model can never miscompile, only forgo the pass.
//!
//! Register-renumbering passes (copy coalescing, frame packing) layer on
//! this re-emit foundation next; they additionally must pin the ABI
//! registers (params `r0..nparams-1`, contiguous call arg windows, the
//! completion register), so they are kept separate from this safe slice.

const std = @import("std");
const Op = @import("op.zig").Op;
const chunk_mod = @import("chunk.zig");
const Chunk = chunk_mod.Chunk;
const SourcePos = chunk_mod.SourcePos;
const Handler = chunk_mod.Handler;
const liveness = @import("liveness.zig");

fn isPureStore(op: Op) bool {
    return switch (op) {
        .star, .star_0, .star_1, .star_2, .star_3 => true,
        else => false,
    };
}

fn storeTarget(op: Op, code: []const u8, i: u32) u8 {
    return switch (op) {
        .star => code[i + 1],
        .star_0, .star_1, .star_2, .star_3 => @intFromEnum(op) - @intFromEnum(Op.star_0),
        else => unreachable,
    };
}

/// Drop dead `Star` instructions in `chunk` (and recurse into nested
/// function / class templates). Returns the total number removed. The
/// chunk's `code`, `source_positions`, and `handlers` are reallocated;
/// the old buffers are freed. A no-op on not-fully-understood functions.
pub fn eliminateDeadStores(allocator: std.mem.Allocator, chunk: *Chunk) !usize {
    var removed = try eliminateDeadStoresOne(allocator, chunk);
    // Recurse into nested functions (class method bodies that are emitted
    // as function templates are reached this way too); any chunk we don't
    // reach simply forgoes the pass.
    for (chunk.function_templates) |*t| removed += try eliminateDeadStores(allocator, &t.chunk);
    return removed;
}

fn eliminateDeadStoresOne(allocator: std.mem.Allocator, chunk: *Chunk) !usize {
    const code = chunk.code;
    if (code.len == 0) return 0;

    // The block/CFG model captures jump and fall-through edges but NOT the
    // full try/catch/finally control flow — a `finally` re-dispatches on
    // normal / throw / break / continue / return completion, and those
    // edges (plus the completion-register plumbing through them) aren't
    // modelled. Liveness across a protected region can therefore be wrong,
    // which would let a live completion store look dead. Bail on any
    // function with handlers — the stores we target (loop-body completion
    // stores) live in handler-free code, so the win is unaffected.
    if (chunk.handlers.len > 0) return 0;

    var a = try liveness.analyze(allocator, code, chunk.register_count, chunk.handlers);
    defer a.deinit();
    if (!a.fully_understood) return 0;

    // ── Pass 1: collect offsets of dead stores (sorted, since we walk
    // forward). A store is dead iff its target reg isn't live after it. ──
    var dead: std.ArrayListUnmanaged(u32) = .empty;
    defer dead.deinit(allocator);
    {
        var i: u32 = 0;
        while (i < code.len) {
            const op: Op = @enumFromInt(code[i]);
            if (isPureStore(op)) {
                var live = try a.liveAfter(code, i);
                defer live.deinit();
                const t = storeTarget(op, code, i);
                if (t >= chunk.register_count or !live.isSet(t)) try dead.append(allocator, i);
            }
            i += 1 + Op.operandSize(op);
        }
    }
    if (dead.items.len == 0) return 0;
    try reEmitDropping(allocator, chunk, dead.items);
    return dead.items.len;
}

/// Rebuild `chunk.code` / `source_positions` / `handlers` with the
/// instructions at the given `dead` offsets removed (sorted ascending, each
/// an instruction start), re-patching i16-relative jumps, remapping source
/// positions, and fixing handler pc ranges. The old buffers are freed.
/// Shared re-emit foundation for the dead-store and TDZ-check passes — a
/// removed instruction's offset maps to the next surviving instruction, so a
/// jump that targeted it still resolves.
fn reEmitDropping(allocator: std.mem.Allocator, chunk: *Chunk, dead: []const u32) !void {
    const code = chunk.code;

    // ── old offset → new offset map (every instruction start + a code.len
    // sentinel). A removed instruction maps to the next surviving one. ──
    const new_off = try allocator.alloc(u32, code.len + 1);
    defer allocator.free(new_off);
    {
        var di: usize = 0;
        var old: u32 = 0;
        var new: u32 = 0;
        while (old < code.len) {
            new_off[old] = new;
            const op: Op = @enumFromInt(code[old]);
            const sz: u32 = 1 + Op.operandSize(op);
            if (di < dead.len and dead[di] == old) {
                di += 1; // removed: don't advance `new`
            } else {
                new += sz;
            }
            old += sz;
        }
        new_off[code.len] = new;
    }

    // ── Re-emit surviving instructions, re-patching i16 jumps ──
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    var new_sp: std.ArrayListUnmanaged(SourcePos) = .empty;
    errdefer new_sp.deinit(allocator);
    {
        var di: usize = 0;
        var sp_i: usize = 0;
        var old: u32 = 0;
        while (old < code.len) {
            const op: Op = @enumFromInt(code[old]);
            const sz: u32 = 1 + Op.operandSize(op);
            const is_dead = di < dead.len and dead[di] == old;
            if (is_dead) {
                di += 1;
                // skip this instruction's source position(s)
                while (sp_i < chunk.source_positions.len and chunk.source_positions[sp_i].offset == old) sp_i += 1;
                old += sz;
                continue;
            }
            const new_self: u32 = new_off[old];
            // carry over source positions for this instruction, remapped.
            while (sp_i < chunk.source_positions.len and chunk.source_positions[sp_i].offset == old) : (sp_i += 1) {
                try new_sp.append(allocator, .{ .offset = new_self, .span = chunk.source_positions[sp_i].span });
            }
            if (liveness.branchTarget(op, code, old)) |tgt| {
                // copy bytes, then overwrite the i16 with the recomputed
                // relative offset from the new layout.
                try out.appendSlice(allocator, code[old .. old + sz]);
                const i16_pos: u32 = switch (op) {
                    .loop_inc_lt => new_self + 3, // [op][rc][rb][off]
                    .jmp_if_strict_eq, .jmp_if_strict_neq, .jmp_if_not_lt, .jmp_if_not_le, .jmp_if_not_gt, .jmp_if_not_ge => new_self + 2, // [op][r][off]
                    else => new_self + 1, // [op][off]
                };
                const new_after: i64 = @as(i64, i16_pos) + 2;
                const new_target: i64 = new_off[tgt];
                const rel: i64 = new_target - new_after;
                std.debug.assert(rel >= std.math.minInt(i16) and rel <= std.math.maxInt(i16));
                std.mem.writeInt(i16, out.items[i16_pos..][0..2], @intCast(rel), .little);
            } else {
                try out.appendSlice(allocator, code[old .. old + sz]);
            }
            old += sz;
        }
    }

    // ── Remap handler pc ranges ──
    const new_handlers = try allocator.alloc(Handler, chunk.handlers.len);
    errdefer allocator.free(new_handlers);
    for (chunk.handlers, 0..) |h, idx| {
        new_handlers[idx] = .{
            .start_pc = new_off[h.start_pc],
            .end_pc = new_off[h.end_pc],
            .handler_pc = new_off[h.handler_pc],
            .catch_register = h.catch_register,
            .is_finally = h.is_finally,
        };
    }

    // ── Commit: swap in the rebuilt buffers, free the originals ──
    const owned_code = try out.toOwnedSlice(allocator);
    const owned_sp = try new_sp.toOwnedSlice(allocator);
    allocator.free(chunk.code);
    allocator.free(chunk.source_positions);
    allocator.free(chunk.handlers);
    chunk.code = owned_code;
    chunk.source_positions = owned_sp;
    chunk.handlers = new_handlers;
}

// ─────────────────────────────────────────────────────────────────────
// Redundant TDZ-check elimination
// ─────────────────────────────────────────────────────────────────────

/// The global lexical slot index of a global-slot op, else null. Each is
/// `[op][slot:u32-le]`.
fn globalSlotOf(op: Op, code: []const u8, i: u32) ?u32 {
    return switch (op) {
        .lda_global_slot, .sta_global_slot, .sta_global_slot_init => std.mem.readInt(u32, code[i + 1 ..][0..4], .little),
        else => null,
    };
}

fn writesGlobalSlot(op: Op) bool {
    return op == .sta_global_slot or op == .sta_global_slot_init;
}

fn isLeaderOff(leaders: []const u32, off: u32) bool {
    var lo: usize = 0;
    var hi: usize = leaders.len;
    while (lo < hi) {
        const mid = (lo + hi) / 2;
        if (leaders[mid] == off) return true;
        if (leaders[mid] < off) lo = mid + 1 else hi = mid;
    }
    return false;
}

fn bitsetEqlN(a: std.DynamicBitSet, b: std.DynamicBitSet, n: u32) bool {
    var i: u32 = 0;
    while (i < n) : (i += 1) if (a.isSet(i) != b.isSet(i)) return false;
    return true;
}

/// Drop provably-redundant TDZ checks. A `let` / `const` global lexical
/// binding, once initialized, can never return to the TDZ hole sentinel
/// (§9.1.1.4 — InitializeBinding runs once and is irreversible), so a
/// `throw_if_hole` that guards a `lda_global_slot sN` for a slot already
/// initialized on every path to that read always passes — dead. A forward
/// must-dataflow ("definitely-initialized slots", meet = intersection)
/// finds them; each such check is removed via the shared re-emit. Recurses
/// into nested function / class templates. Returns the count removed.
///
/// Sound across opaque ops and calls: global lexical slots are written only
/// by `sta_global_slot{,_init}`, and nothing can un-initialize one, so an
/// unmodelled op can only fail to *add* init-ness (kept check, conservative)
/// — never wrongly assert it. Restricted to the exact adjacent
/// `lda_global_slot; throw_if_hole` pair (so the accumulator definitely
/// holds the slot) with the check not itself a jump target.
pub fn eliminateRedundantTdzChecks(allocator: std.mem.Allocator, chunk: *Chunk) !usize {
    var removed = try eliminateRedundantTdzChecksOne(allocator, chunk);
    for (chunk.function_templates) |*t| removed += try eliminateRedundantTdzChecks(allocator, &t.chunk);
    return removed;
}

fn eliminateRedundantTdzChecksOne(allocator: std.mem.Allocator, chunk: *Chunk) !usize {
    const code = chunk.code;
    if (code.len == 0) return 0;

    // Handlers ARE supported here (unlike the dead-store pass): Cynic inlines
    // every `finally` body at each break/continue/return exit, so all
    // completion control flow is via static jumps already in `succs`. The
    // only non-static edge is `throw → handler_pc`, and a throw can occur at
    // any protected instruction — including before any in-try init. So a
    // handler-entry block's must-init set is pinned to ∅ below (never trusted
    // from its normal predecessors), which makes the forward must-analysis
    // sound across try/catch/finally. (Backward dead-store liveness needs
    // instruction-granular throw edges for a mid-block throw, which we don't
    // model — hence it still bails on handlers; this forward pass doesn't.)

    // Slot universe = highest referenced global slot + 1.
    var nslots: u32 = 0;
    {
        var i: u32 = 0;
        while (i < code.len) {
            const op: Op = @enumFromInt(code[i]);
            if (globalSlotOf(op, code, i)) |s| nslots = @max(nslots, s + 1);
            i += 1 + Op.operandSize(op);
        }
    }
    if (nslots == 0) return 0; // no global-slot traffic

    var a = try liveness.analyze(allocator, code, chunk.register_count, chunk.handlers);
    defer a.deinit();
    const nblocks = a.blockCount();

    // Blocks pinned to must-in = ∅: the entry block (program start), and every
    // handler entry (reachable via a throw at any protected point, so nothing
    // can be assumed initialized there). These never take the meet over their
    // normal predecessors — that is what keeps the analysis sound across
    // exception edges the `succs` CFG does not carry.
    var is_pinned = try allocator.alloc(bool, nblocks);
    defer allocator.free(is_pinned);
    for (0..nblocks) |b| is_pinned[b] = (b == 0);
    for (chunk.handlers) |h| is_pinned[a.blockOf(h.handler_pc)] = true;

    // gen[b] = slots written (→ definitely initialized) within block b.
    var gen = try allocator.alloc(std.DynamicBitSet, nblocks);
    defer {
        for (gen) |*g| g.deinit();
        allocator.free(gen);
    }
    for (0..nblocks) |b| {
        gen[b] = try std.DynamicBitSet.initEmpty(allocator, nslots);
        const start = a.leaders[b];
        const end: u32 = if (b + 1 < nblocks) a.leaders[b + 1] else @intCast(code.len);
        var p: u32 = start;
        while (p < end) {
            const op: Op = @enumFromInt(code[p]);
            if (writesGlobalSlot(op)) {
                if (globalSlotOf(op, code, p)) |s| gen[b].set(s);
            }
            p += 1 + Op.operandSize(op);
        }
    }

    // Predecessor lists from normal (succs) edges only — reachable blocks.
    // Throw→handler edges are deliberately excluded; handler entries are
    // pinned to ∅ instead (see `is_pinned`), which is the conservative truth.
    var preds = try allocator.alloc(std.ArrayListUnmanaged(usize), nblocks);
    defer {
        for (preds) |*pl| pl.deinit(allocator);
        allocator.free(preds);
    }
    for (0..nblocks) |b| preds[b] = .empty;
    for (0..nblocks) |b| {
        if (!a.reachable.isSet(b)) continue;
        for (a.succs[b]) |maybe| if (maybe) |s| try preds[s].append(allocator, b);
    }

    // Forward must-dataflow:
    //   in[pinned] = ∅ ; in[b] = ⋂ out[pred] ; out[b] = in[b] ∪ gen[b]
    // Pinned blocks (entry + handler entries) start at in=∅, out=gen and are
    // never recomputed — correct even when a back-edge re-enters them, since
    // the program-start / throw path contributes ∅. Other blocks start at ⊤
    // (all slots) so the meet narrows down monotonically.
    var in_set = try allocator.alloc(std.DynamicBitSet, nblocks);
    var out_set = try allocator.alloc(std.DynamicBitSet, nblocks);
    defer {
        for (in_set) |*s| s.deinit();
        for (out_set) |*s| s.deinit();
        allocator.free(in_set);
        allocator.free(out_set);
    }
    for (0..nblocks) |b| {
        in_set[b] = try std.DynamicBitSet.initEmpty(allocator, nslots);
        out_set[b] = try std.DynamicBitSet.initEmpty(allocator, nslots);
        if (is_pinned[b]) {
            out_set[b].setUnion(gen[b]); // in=∅ → out=gen
        } else {
            out_set[b].setRangeValue(.{ .start = 0, .end = nslots }, true);
        }
    }
    var changed = true;
    while (changed) {
        changed = false;
        for (0..nblocks) |b| {
            if (is_pinned[b] or !a.reachable.isSet(b)) continue;
            var new_in = try std.DynamicBitSet.initEmpty(allocator, nslots);
            defer new_in.deinit();
            var first = true;
            for (preds[b].items) |p| {
                if (first) {
                    new_in.setUnion(out_set[p]);
                    first = false;
                } else {
                    new_in.setIntersection(out_set[p]);
                }
            }
            var new_out = try new_in.clone(allocator);
            defer new_out.deinit();
            new_out.setUnion(gen[b]);
            if (!bitsetEqlN(new_out, out_set[b], nslots)) {
                changed = true;
                out_set[b].setRangeValue(.{ .start = 0, .end = nslots }, false);
                out_set[b].setUnion(new_out);
            }
            in_set[b].setRangeValue(.{ .start = 0, .end = nslots }, false);
            in_set[b].setUnion(new_in);
        }
    }

    // Replay the transfer per reachable block, marking every
    // `lda_global_slot sN; throw_if_hole` with sN already initialized — and
    // the check not itself a jump target — for removal.
    var dead: std.ArrayListUnmanaged(u32) = .empty;
    defer dead.deinit(allocator);
    for (0..nblocks) |b| {
        if (!a.reachable.isSet(b)) continue;
        var cur = try in_set[b].clone(allocator);
        defer cur.deinit();
        const start = a.leaders[b];
        const end: u32 = if (b + 1 < nblocks) a.leaders[b + 1] else @intCast(code.len);
        var p: u32 = start;
        while (p < end) {
            const op: Op = @enumFromInt(code[p]);
            const sz: u32 = 1 + Op.operandSize(op);
            if (op == .lda_global_slot) {
                const slot = globalSlotOf(op, code, p).?;
                const next = p + sz;
                if (next < end and @as(Op, @enumFromInt(code[next])) == .throw_if_hole and
                    cur.isSet(slot) and !isLeaderOff(a.leaders, next))
                {
                    try dead.append(allocator, next);
                }
            }
            if (writesGlobalSlot(op)) {
                if (globalSlotOf(op, code, p)) |s| cur.set(s);
            }
            p += sz;
        }
    }
    if (dead.items.len == 0) return 0;
    std.mem.sort(u32, dead.items, {}, std.sort.asc(u32));
    try reEmitDropping(allocator, chunk, dead.items);
    return dead.items.len;
}

// ─────────────────────────────────────────────────────────────────────
// Tests
// ─────────────────────────────────────────────────────────────────────

const testing = std.testing;

test "regalloc: a dead store is dropped and the value is unchanged" {
    // Build: lda_one; star r0; lda_zero; star r0; ldar r0; return
    // The first `star r0` is dead (r0 overwritten before any read).
    var code = [_]u8{
        @intFromEnum(Op.lda_one),  @intFromEnum(Op.star), 0, // dead store
        @intFromEnum(Op.lda_zero), @intFromEnum(Op.star), 0,
        @intFromEnum(Op.ldar),     0,                     @intFromEnum(Op.return_),
    };
    var chunk: Chunk = .{
        .code = try testing.allocator.dupe(u8, &code),
        .constants = &.{},
        .source_positions = &.{},
        .handlers = &.{},
        .function_templates = &.{},
        .class_templates = &.{},
        .register_count = 4,
    };
    defer testing.allocator.free(chunk.code);
    const removed = try eliminateDeadStoresOne(testing.allocator, &chunk);
    try testing.expectEqual(@as(usize, 1), removed);
    // The surviving program: lda_one; lda_zero; star r0; ldar r0; return
    // (one `star r0` gone) — 6 fewer? no, 2 bytes fewer.
    try testing.expectEqual(@as(usize, code.len - 2), chunk.code.len);
}

test "regalloc: a function with an exception handler is left untouched" {
    // Same dead-store shape as above, but with a handler present — the
    // unmodelled try/catch/finally control flow means we must not rewrite.
    var code = [_]u8{
        @intFromEnum(Op.lda_one),  @intFromEnum(Op.star), 0, // dead store
        @intFromEnum(Op.lda_zero), @intFromEnum(Op.star), 0,
        @intFromEnum(Op.ldar),     0,                     @intFromEnum(Op.return_),
    };
    var handlers = [_]Handler{.{ .start_pc = 0, .end_pc = 3, .handler_pc = 3, .catch_register = 1 }};
    var chunk: Chunk = .{
        .code = try testing.allocator.dupe(u8, &code),
        .constants = &.{},
        .source_positions = &.{},
        .handlers = &handlers,
        .function_templates = &.{},
        .class_templates = &.{},
        .register_count = 4,
    };
    defer testing.allocator.free(chunk.code);
    try testing.expectEqual(@as(usize, 0), try eliminateDeadStoresOne(testing.allocator, &chunk));
    try testing.expectEqual(@as(usize, code.len), chunk.code.len); // unchanged
}

test "regalloc: a jump offset is recomputed when a store between it and its target is removed" {
    // 0: lda_zero
    // 1: jmp_if_false +2 -> 6   (false skips the store; true falls through)
    // 4: star r1                 <- dead (r1 never read), between branch & target
    // 6: lda_one; star r0; ldar r0; return
    var code = [_]u8{
        @intFromEnum(Op.lda_zero), // 0
        @intFromEnum(Op.jmp_if_false), 2, 0, // 1: -> (1+3)+2 = 6
        @intFromEnum(Op.star), 1, // 4: dead, between branch and target
        @intFromEnum(Op.lda_one), // 6: target
        @intFromEnum(Op.star), 0, // 7
        @intFromEnum(Op.ldar), 0, // 9
        @intFromEnum(Op.return_), // 11
    };
    var chunk: Chunk = .{
        .code = try testing.allocator.dupe(u8, &code),
        .constants = &.{},
        .source_positions = &.{},
        .handlers = &.{},
        .function_templates = &.{},
        .class_templates = &.{},
        .register_count = 4,
    };
    defer testing.allocator.free(chunk.code);
    const removed = try eliminateDeadStoresOne(testing.allocator, &chunk);
    try testing.expectEqual(@as(usize, 1), removed); // the dead `star r1`
    // The target `lda_one` is now 2 bytes earlier, so the i16 offset must
    // be recomputed (here 2 → 0) to still resolve to it.
    var i: u32 = 0;
    var checked = false;
    while (i < chunk.code.len) {
        const op: Op = @enumFromInt(chunk.code[i]);
        if (op == .jmp_if_false) {
            const t = liveness.branchTarget(.jmp_if_false, chunk.code, i).?;
            try testing.expectEqual(@intFromEnum(Op.lda_one), chunk.code[t]);
            checked = true;
        }
        i += 1 + Op.operandSize(op);
    }
    try testing.expect(checked);
}

fn mkChunk(code: []const u8) !Chunk {
    return .{
        .code = try testing.allocator.dupe(u8, code),
        .constants = &.{},
        .source_positions = &.{},
        .handlers = &.{},
        .function_templates = &.{},
        .class_templates = &.{},
        .register_count = 4,
    };
}

// `sta_global_slot_init s0` / `lda_global_slot s0` are `[op][slot:u32-le]`.
const gs_init_s0 = [_]u8{ @intFromEnum(Op.sta_global_slot_init), 0, 0, 0, 0 };
const gl_s0 = [_]u8{ @intFromEnum(Op.lda_global_slot), 0, 0, 0, 0 };

test "regalloc: dead-store runs on a chunk that declares a closure (make_function modelled)" {
    // make_function k0; lda_one; star r0 (dead); lda_zero; star r0; ldar r0; return
    // `make_function` has no register effect, so the chunk stays
    // fully-understood and the dead store is removed — previously the opaque
    // make_function bailed the whole pass (the common closure + loop shape).
    var code = [_]u8{ @intFromEnum(Op.make_function), 0, 0 } // make_function k0
        ++ [_]u8{ @intFromEnum(Op.lda_one), @intFromEnum(Op.star), 0 } // dead store r0
        ++ [_]u8{ @intFromEnum(Op.lda_zero), @intFromEnum(Op.star), 0, @intFromEnum(Op.ldar), 0, @intFromEnum(Op.return_) };
    var chunk = try mkChunk(&code);
    defer testing.allocator.free(chunk.code);
    try testing.expectEqual(@as(usize, 1), try eliminateDeadStoresOne(testing.allocator, &chunk));
}

test "regalloc(tdz): a check dominated by the slot's init is dropped" {
    // lda_zero; sta_global_slot_init s0; lda_global_slot s0; throw_if_hole; return
    var code = [_]u8{@intFromEnum(Op.lda_zero)} ++ gs_init_s0 ++ gl_s0 ++
        [_]u8{ @intFromEnum(Op.throw_if_hole), @intFromEnum(Op.return_) };
    var chunk = try mkChunk(&code);
    defer testing.allocator.free(chunk.code);
    const removed = try eliminateRedundantTdzChecksOne(testing.allocator, &chunk);
    try testing.expectEqual(@as(usize, 1), removed);
    try testing.expectEqual(@as(usize, code.len - 1), chunk.code.len); // throw_if_hole (1 byte) gone
    // No throw_if_hole survives.
    var i: u32 = 0;
    while (i < chunk.code.len) : (i += 1 + Op.operandSize(@enumFromInt(chunk.code[i]))) {
        try testing.expect(@as(Op, @enumFromInt(chunk.code[i])) != .throw_if_hole);
    }
}

test "regalloc(tdz): a check before the slot's init is kept" {
    // lda_global_slot s0; throw_if_hole; lda_zero; sta_global_slot_init s0; return
    var code = gl_s0 ++ [_]u8{ @intFromEnum(Op.throw_if_hole), @intFromEnum(Op.lda_zero) } ++
        gs_init_s0 ++ [_]u8{@intFromEnum(Op.return_)};
    var chunk = try mkChunk(&code);
    defer testing.allocator.free(chunk.code);
    try testing.expectEqual(@as(usize, 0), try eliminateRedundantTdzChecksOne(testing.allocator, &chunk));
    try testing.expectEqual(@as(usize, code.len), chunk.code.len);
}

test "regalloc(tdz): a check after a one-armed init is kept (must, not may)" {
    // lda_zero; jmp_if_false +6 -> join; lda_zero; sta_global_slot_init s0;
    // join: lda_global_slot s0; throw_if_hole; return
    // The init runs only on the fall-through arm, so at the join s0 is not
    // initialized on ALL paths — the check must stay.
    var code = [_]u8{
        @intFromEnum(Op.lda_zero), // 0
        @intFromEnum(Op.jmp_if_false), 6, 0, // 1: after=4, +6 -> 10 (join)
        @intFromEnum(Op.lda_zero), // 4
    } ++ gs_init_s0 // 5: sta_global_slot_init s0 -> 10
    ++ gl_s0 // 10: lda_global_slot s0 -> 15
    ++ [_]u8{ @intFromEnum(Op.throw_if_hole), @intFromEnum(Op.return_) }; // 15, 16
    var chunk = try mkChunk(&code);
    defer testing.allocator.free(chunk.code);
    try testing.expectEqual(@as(usize, 0), try eliminateRedundantTdzChecksOne(testing.allocator, &chunk));
}

test "regalloc(tdz): a check on a branch dominated by an earlier init is dropped" {
    // lda_zero; sta_global_slot_init s0; jmp_if_false +6 -> end;
    // lda_global_slot s0; throw_if_hole; end: return
    // The init precedes (dominates) the branch, so the in-branch read is
    // provably initialized.
    var code = [_]u8{@intFromEnum(Op.lda_zero)} // 0
        ++ gs_init_s0 // 1: init -> 6
        ++ [_]u8{ @intFromEnum(Op.jmp_if_false), 6, 0 } // 6: after=9, +6 -> 15 (end)
        ++ gl_s0 // 9: lda_global_slot s0 -> 14
        ++ [_]u8{ @intFromEnum(Op.throw_if_hole), @intFromEnum(Op.return_) }; // 14, 15
    var chunk = try mkChunk(&code);
    defer testing.allocator.free(chunk.code);
    try testing.expectEqual(@as(usize, 1), try eliminateRedundantTdzChecksOne(testing.allocator, &chunk));
}

test "regalloc(tdz): a check in a handler (catch) body is kept — handler entry pinned to ∅" {
    // The `lda_global_slot s0; throw_if_hole` sits in the catch body
    // (handler_pc = 6). A throw can reach the catch before the init runs, so
    // the handler-entry block's must-init is ∅ and the check must stay — even
    // though a normal fall-through from the init block exists in the bytecode.
    var code = [_]u8{@intFromEnum(Op.lda_zero)} ++ gs_init_s0 ++ gl_s0 ++
        [_]u8{ @intFromEnum(Op.throw_if_hole), @intFromEnum(Op.return_) };
    var handlers = [_]Handler{.{ .start_pc = 0, .end_pc = 6, .handler_pc = 6, .catch_register = 1 }};
    var chunk = try mkChunk(&code);
    chunk.handlers = &handlers;
    defer testing.allocator.free(chunk.code);
    try testing.expectEqual(@as(usize, 0), try eliminateRedundantTdzChecksOne(testing.allocator, &chunk));
    try testing.expectEqual(@as(usize, code.len), chunk.code.len);
}

test "regalloc(tdz): a check inside a try body dominated by a pre-try init is dropped" {
    // init s0 before the try; the read is inside the protected range and the
    // try normally jumps past the catch. The check is removable despite the
    // handler — the pass no longer bails on handler-bearing chunks.
    // @0 lda_zero; @1 sta_global_slot_init s0; [try @6) @6 lda_global_slot s0;
    // @11 throw_if_hole; @12 jmp +1 -> @16; [catch @15] @15 lda_undefined;
    // @16 return.  handler: try [6,12), catch @15.
    var code = [_]u8{@intFromEnum(Op.lda_zero)} // 0
        ++ gs_init_s0 // 1: init -> 6
        ++ gl_s0 // 6: read -> 11
        ++ [_]u8{ @intFromEnum(Op.throw_if_hole), @intFromEnum(Op.jmp), 1, 0, @intFromEnum(Op.lda_undefined), @intFromEnum(Op.return_) };
    // 11: throw_if_hole; 12: jmp after=15 +1 -> 16; 15: lda_undefined; 16: return
    var chunk = try mkChunk(&code);
    // Owned handlers slice — the re-emit frees and rebuilds it (a removal
    // happens here, so it runs), so it must not be a stack array.
    const handlers = try testing.allocator.alloc(Handler, 1);
    handlers[0] = .{ .start_pc = 6, .end_pc = 12, .handler_pc = 15, .catch_register = 1 };
    chunk.handlers = handlers;
    defer testing.allocator.free(chunk.code);
    defer testing.allocator.free(chunk.handlers); // the rebuilt slice
    try testing.expectEqual(@as(usize, 1), try eliminateRedundantTdzChecksOne(testing.allocator, &chunk));
}
