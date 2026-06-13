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

    // ── old offset → new offset map (every instruction start + a code.len
    // sentinel). A removed store maps to the next surviving instruction. ──
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
            if (di < dead.items.len and dead.items[di] == old) {
                di += 1; // removed: don't advance `new`
            } else {
                new += sz;
            }
            old += sz;
        }
        new_off[code.len] = new;
    }

    // ── Pass 2: re-emit surviving instructions, re-patching i16 jumps ──
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
            const is_dead = di < dead.items.len and dead.items[di] == old;
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
        @intFromEnum(Op.lda_one),  @intFromEnum(Op.star),    0, // dead store
        @intFromEnum(Op.lda_zero), @intFromEnum(Op.star),    0,
        @intFromEnum(Op.ldar),     0, @intFromEnum(Op.return_),
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
        @intFromEnum(Op.lda_one),  @intFromEnum(Op.star),    0, // dead store
        @intFromEnum(Op.lda_zero), @intFromEnum(Op.star),    0,
        @intFromEnum(Op.ldar),     0, @intFromEnum(Op.return_),
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
        @intFromEnum(Op.star),         1, // 4: dead, between branch and target
        @intFromEnum(Op.lda_one), // 6: target
        @intFromEnum(Op.star),         0, // 7
        @intFromEnum(Op.ldar),         0, // 9
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
