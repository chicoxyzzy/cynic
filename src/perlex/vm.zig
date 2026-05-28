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
const parser = @import("parser.zig");
const Program = compiler.Program;

/// §22.2.1 word character: `[A-Za-z0-9_]`. Accepts either code-unit
/// width; non-ASCII units are never word characters in this set.
fn isWordChar(c: anytype) bool {
    return (c >= 'a' and c <= 'z') or
        (c >= 'A' and c <= 'Z') or
        (c >= '0' and c <= '9') or
        c == '_';
}

/// §22.2.2.7.1 Canonicalize, ASCII case: fold a lowercase letter to
/// upper. Exact for non-Unicode `i` on all-ASCII patterns (the spec
/// never folds a non-ASCII unit to ASCII).
fn asciiUpper(c: u21) u21 {
    return if (c >= 'a' and c <= 'z') c - ('a' - 'A') else c;
}

/// The ASCII case partner of `c` (the other case of a letter, else
/// `c`). Used to test class membership case-insensitively.
fn asciiSwapCase(c: u21) u21 {
    if (c >= 'a' and c <= 'z') return c - ('a' - 'A');
    if (c >= 'A' and c <= 'Z') return c + ('a' - 'A');
    return c;
}

fn classContains(ranges: []const parser.Node.ClassRange, c: u21) bool {
    for (ranges) |r| {
        if (c >= r.lo and c <= r.hi) return true;
    }
    return false;
}

/// §11.3 LineTerminator: LF, CR, LS, PS. Used by the `m` flag.
fn isLineTerminator(c: anytype) bool {
    return c == 0x0A or c == 0x0D or c == 0x2028 or c == 0x2029;
}

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
        .fold = program.flags.ignore_case,
        .multiline = program.flags.multiline,
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
        /// `i` flag — fold ASCII case in char/class/backref matching.
        fold: bool,
        /// `m` flag — `^`/`$` also match at line-terminator boundaries.
        multiline: bool,
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
            return self.runLoop(self.prog.insts, &self.backtrack, &self.undo, start);
        }

        /// Run `insts` from `sp_start` against the given backtrack/undo
        /// stacks. The main match uses the matcher's stacks; a lookahead
        /// runs its sub-program with fresh, self-contained stacks so it
        /// can't disturb the outer match. Returns whether a `match`
        /// instruction was reached.
        fn runLoop(
            self: *Self,
            insts: []const compiler.Inst,
            backtrack: *std.ArrayListUnmanaged(Frame),
            undo: *std.ArrayListUnmanaged(Undo),
            sp_start: usize,
        ) error{ OutOfMemory, StepLimit }!bool {
            var pc: usize = 0;
            var sp: usize = sp_start;
            while (true) {
                self.steps += 1;
                if (self.steps > step_limit) return error.StepLimit;

                switch (insts[pc]) {
                    .char => |ch| {
                        if (sp < self.input.len) {
                            const ic: u21 = self.input[sp];
                            const pat: u21 = ch;
                            const ok = if (self.fold) asciiUpper(ic) == asciiUpper(pat) else ic == pat;
                            if (ok) {
                                sp += 1;
                                pc += 1;
                                continue;
                            }
                        }
                    },
                    .match => return true,
                    .jmp => |t| {
                        pc = t;
                        continue;
                    },
                    .split => |s| {
                        // Try `a` now; `b` is the backtrack target.
                        try backtrack.append(self.gpa, .{
                            .pc = s.b,
                            .sp = sp,
                            .undo_mark = undo.items.len,
                        });
                        pc = s.a;
                        continue;
                    },
                    .save => |slot| {
                        try self.write(undo, slot, sp);
                        pc += 1;
                        continue;
                    },
                    .clear => |r| {
                        var i = r.from;
                        while (i < r.to) : (i += 1) try self.write(undo, i, none);
                        pc += 1;
                        continue;
                    },
                    .assert_start => {
                        // `^`: input start, or (multiline) just after a
                        // line terminator.
                        if (sp == 0 or (self.multiline and isLineTerminator(self.input[sp - 1]))) {
                            pc += 1;
                            continue;
                        }
                    },
                    .assert_end => {
                        // `$`: input end, or (multiline) just before a
                        // line terminator.
                        if (sp == self.input.len or (self.multiline and isLineTerminator(self.input[sp]))) {
                            pc += 1;
                            continue;
                        }
                    },
                    .class => |cls| {
                        if (sp < self.input.len) {
                            const cu: u21 = self.input[sp];
                            var inside = classContains(cls.ranges, cu);
                            // Under `i`, a letter matches the class if
                            // its other-case partner is in the set.
                            if (self.fold and !inside) inside = classContains(cls.ranges, asciiSwapCase(cu));
                            if (inside != cls.negated) {
                                sp += 1;
                                pc += 1;
                                continue;
                            }
                        }
                    },
                    .word_boundary => |negated| {
                        const before = sp > 0 and isWordChar(self.input[sp - 1]);
                        const after = sp < self.input.len and isWordChar(self.input[sp]);
                        if ((before != after) != negated) {
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
                    .lookahead => |la| {
                        // §22.2.2.4 — run the sub-program at `sp` with
                        // fresh stacks, sharing the capture array. The
                        // assertion is zero-width: `sp` is unchanged
                        // whatever the outcome.
                        var saved: [2 * compiler.max_groups]usize = undefined;
                        const n = self.slots.len;
                        @memcpy(saved[0..n], self.slots);
                        var sub_bt: std.ArrayListUnmanaged(Frame) = .empty;
                        defer sub_bt.deinit(self.gpa);
                        var sub_undo: std.ArrayListUnmanaged(Undo) = .empty;
                        defer sub_undo.deinit(self.gpa);
                        const matched = try self.runLoop(la.sub, &sub_bt, &sub_undo, sp);
                        if (matched != la.negative) {
                            if (la.negative) {
                                // A negative lookahead contributes no captures.
                                @memcpy(self.slots, saved[0..n]);
                            } else {
                                // A positive lookahead keeps its captures;
                                // log them so an outer backtrack restores
                                // the pre-lookahead state.
                                var i: usize = 0;
                                while (i < n) : (i += 1) {
                                    if (self.slots[i] != saved[i]) {
                                        try undo.append(self.gpa, .{ .slot = i, .old = saved[i] });
                                    }
                                }
                            }
                            pc += 1;
                            continue;
                        }
                        // Assertion failed — restore captures and backtrack.
                        @memcpy(self.slots, saved[0..n]);
                    },
                }

                // Falling out of the switch means this instruction
                // failed: pop the most recent choice point, undo the
                // captures it accumulated, and resume there.
                if (backtrack.items.len == 0) return false;
                const f = backtrack.items[backtrack.items.len - 1];
                backtrack.items.len -= 1;
                self.undoTo(undo, f.undo_mark);
                pc = f.pc;
                sp = f.sp;
            }
        }

        /// Set capture slot `slot`, logging the prior value to `undo`
        /// so a later backtrack can restore it.
        fn write(self: *Self, undo: *std.ArrayListUnmanaged(Undo), slot: usize, value: usize) error{OutOfMemory}!void {
            try undo.append(self.gpa, .{ .slot = slot, .old = self.slots[slot] });
            self.slots[slot] = value;
        }

        fn undoTo(self: *Self, undo: *std.ArrayListUnmanaged(Undo), mark: usize) void {
            while (undo.items.len > mark) {
                const u = undo.items[undo.items.len - 1];
                undo.items.len -= 1;
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
            if (self.fold) {
                var i: usize = 0;
                while (i < len) : (i += 1) {
                    if (asciiUpper(self.input[cs + i]) != asciiUpper(self.input[sp.* + i])) return false;
                }
            } else {
                if (!std.mem.eql(Unit, self.input[cs..ce], self.input[sp.* .. sp.* + len])) return false;
            }
            sp.* += len;
            return true;
        }
    };
}
