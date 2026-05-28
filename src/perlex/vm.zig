//! Perlex VM — an explicit-stack backtracking executor.
//!
//! ECMA-262 §22.2.2 matching is ordered backtracking (backreferences
//! make the language non-regular, so a Thompson NFA / lazy-DFA can't
//! model the whole grammar — those will be an additive fast path for
//! the regular subset, behind the `Program.is_regular` classifier).
//!
//! Design choices, following V8 Irregexp / JSC YARR / QuickJS-NG
//! libregexp rather than the textbook recursive matcher:
//!
//!   * **Explicit backtrack stack**, not native recursion — bounded
//!     and stack-safe on large inputs, and the shape a future JIT
//!     tier (Bistromath/Ohaimark) can lower directly.
//!   * **Undo log for captures.** A choice point records only the
//!     undo-log mark, and `save`/`clear` push (slot, old value); a
//!     backtrack replays the log back to the mark. That is O(writes
//!     since the choice point), versus copying the whole capture
//!     array at every `split`.
//!   * **Width-generic** via `comptime Unit` — instantiated for `u8`
//!     (Latin1/ASCII subjects, matched directly on Cynic's WTF-8
//!     bytes with no transcode) and `u16` (everything else).

const std = @import("std");
const compiler = @import("compiler.zig");
const Program = compiler.Program;

/// Sentinel for a capture slot that did not participate. Real offsets
/// are bounded by the input length, well below `maxInt`.
pub const none: usize = std.math.maxInt(usize);

/// Backtracking-effort ceiling across one `exec` (all start
/// positions). The v1 grammar has no unbounded quantifiers, so step
/// counts are tiny and this never trips; it is a backstop for when
/// `*`/`+`/`{n,}` land — at which point the real ReDoS answer is the
/// linear engine, not this limit.
const step_limit: u64 = 1 << 24;

pub const Match = struct {
    /// `2 * group_count` slots: `[2g]` start, `[2g+1]` end (in code
    /// units of the matched `Unit` width), or `none` if group `g` did
    /// not participate. Group 0 is the whole match. Caller-owned.
    slots: []usize,

    pub fn deinit(self: *Match, gpa: std.mem.Allocator) void {
        gpa.free(self.slots);
    }
};

/// Find the leftmost match at or after `start`, scanning forward
/// (sticky patterns match only at `start`). `Unit` is `u8` or `u16`;
/// capture offsets are in those units. Returns `null` for no match.
pub fn exec(
    comptime Unit: type,
    gpa: std.mem.Allocator,
    program: *const Program,
    input: []const Unit,
    start: usize,
) error{OutOfMemory}!?Match {
    const slots = try gpa.alloc(usize, 2 * program.group_count);
    errdefer gpa.free(slots);

    var m: Matcher(Unit) = .{
        .prog = program,
        .input = input,
        .slots = slots,
        .gpa = gpa,
    };
    defer m.deinit();

    var s = start;
    while (s <= input.len) : (s += 1) {
        const matched = m.runFrom(s) catch |e| switch (e) {
            // Backstop tripped — report no match rather than spin. v1
            // patterns never reach it (see `step_limit`).
            error.StepLimit => {
                gpa.free(slots);
                return null;
            },
            error.OutOfMemory => return error.OutOfMemory,
        };
        if (matched) return Match{ .slots = slots };
        if (program.flags.sticky) break;
    }
    gpa.free(slots);
    return null;
}

fn Matcher(comptime Unit: type) type {
    return struct {
        const Self = @This();

        prog: *const Program,
        input: []const Unit,
        slots: []usize,
        gpa: std.mem.Allocator,
        undo: std.ArrayListUnmanaged(Undo) = .empty,
        backtrack: std.ArrayListUnmanaged(Frame) = .empty,
        steps: u64 = 0,

        const Undo = struct { slot: usize, old: usize };
        const Frame = struct { pc: usize, sp: usize, undo_mark: usize };

        fn deinit(self: *Self) void {
            self.undo.deinit(self.gpa);
            self.backtrack.deinit(self.gpa);
        }

        /// Attempt a match anchored at `start`. The step counter is
        /// shared across attempts so total work per `exec` is bounded.
        fn runFrom(self: *Self, start: usize) error{ OutOfMemory, StepLimit }!bool {
            self.undo.clearRetainingCapacity();
            self.backtrack.clearRetainingCapacity();
            @memset(self.slots, none);

            var pc: usize = 0;
            var sp: usize = start;
            while (true) {
                self.steps += 1;
                if (self.steps > step_limit) return error.StepLimit;

                switch (self.prog.insts[pc]) {
                    .char => |ch| {
                        if (sp < self.input.len and @as(u16, self.input[sp]) == ch) {
                            sp += 1;
                            pc += 1;
                            continue;
                        }
                    },
                    .match => return true,
                    .jmp => |t| {
                        pc = t;
                        continue;
                    },
                    .split => |s| {
                        // Try `a` now; `b` is the backtrack target.
                        try self.backtrack.append(self.gpa, .{
                            .pc = s.b,
                            .sp = sp,
                            .undo_mark = self.undo.items.len,
                        });
                        pc = s.a;
                        continue;
                    },
                    .save => |slot| {
                        try self.write(slot, sp);
                        pc += 1;
                        continue;
                    },
                    .clear => |r| {
                        var i = r.from;
                        while (i < r.to) : (i += 1) try self.write(i, none);
                        pc += 1;
                        continue;
                    },
                    .assert_start => {
                        // Non-multiline `^`: input start only.
                        if (sp == 0) {
                            pc += 1;
                            continue;
                        }
                    },
                    .assert_end => {
                        // Non-multiline `$`: input end only.
                        if (sp == self.input.len) {
                            pc += 1;
                            continue;
                        }
                    },
                    .backref => |g| {
                        if (self.matchBackref(g, &sp)) {
                            pc += 1;
                            continue;
                        }
                    },
                    .backref_dup => |idxs| {
                        // Match whichever same-named group participated
                        // (the early error guarantees at most one is
                        // set); if none, the backreference matches the
                        // empty string.
                        var g: ?usize = null;
                        for (idxs) |cand| {
                            if (self.slots[2 * cand] != none and self.slots[2 * cand + 1] != none) {
                                g = cand;
                                break;
                            }
                        }
                        if (g) |group| {
                            if (self.matchBackref(group, &sp)) {
                                pc += 1;
                                continue;
                            }
                        } else {
                            pc += 1;
                            continue;
                        }
                    },
                }

                // Falling out of the switch means this instruction
                // failed: pop the most recent choice point, undo the
                // captures it accumulated, and resume there.
                if (self.backtrack.items.len == 0) return false;
                const f = self.backtrack.items[self.backtrack.items.len - 1];
                self.backtrack.items.len -= 1;
                self.undoTo(f.undo_mark);
                pc = f.pc;
                sp = f.sp;
            }
        }

        /// Set capture slot `slot`, logging the prior value so a later
        /// backtrack can restore it.
        fn write(self: *Self, slot: usize, value: usize) error{OutOfMemory}!void {
            try self.undo.append(self.gpa, .{ .slot = slot, .old = self.slots[slot] });
            self.slots[slot] = value;
        }

        fn undoTo(self: *Self, mark: usize) void {
            while (self.undo.items.len > mark) {
                const u = self.undo.items[self.undo.items.len - 1];
                self.undo.items.len -= 1;
                self.slots[u.slot] = u.old;
            }
        }

        /// Match the text captured by group `g` at `sp`, advancing
        /// `sp` on success. An unset group matches the empty string.
        fn matchBackref(self: *Self, g: usize, sp: *usize) bool {
            const cs = self.slots[2 * g];
            const ce = self.slots[2 * g + 1];
            if (cs == none or ce == none) return true; // unset → empty
            const len = ce - cs;
            if (sp.* + len > self.input.len) return false;
            if (!std.mem.eql(Unit, self.input[cs..ce], self.input[sp.* .. sp.* + len])) return false;
            sp.* += len;
            return true;
        }
    };
}
