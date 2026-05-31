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

/// Membership test over `ranges`. The compiler emits every class with
/// its ranges sorted ascending by `lo` and made disjoint (via
/// `charset.normalize`), so this is a binary search — O(log n) per code
/// point rather than a linear scan. The win is large for property
/// classes: `\p{L}` resolves to hundreds of ranges, and the frequent
/// non-member rejection (a `+` quantifier hitting a delimiter, say)
/// would otherwise walk the entire list before failing.
fn classContains(ranges: []const parser.Node.ClassRange, c: u21) bool {
    var lo: usize = 0;
    var hi: usize = ranges.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        const r = ranges[mid];
        if (c < r.lo) {
            hi = mid;
        } else if (c > r.hi) {
            lo = mid + 1;
        } else {
            return true;
        }
    }
    return false;
}

/// §11.3 LineTerminator: LF, CR, LS, PS. Used by the `m` flag.
fn isLineTerminator(c: anytype) bool {
    return c == 0x0A or c == 0x0D or c == 0x2028 or c == 0x2029;
}

/// Combine a UTF-16 surrogate pair into a supplementary code point.
fn combineSurrogates(hi: u21, lo: u21) u21 {
    return 0x10000 + ((hi - 0xD800) << 10) + (lo - 0xDC00);
}

/// Sentinel for a capture slot that did not participate. Real offsets
/// are bounded by the input length, well below `maxInt`.
pub const none: usize = std.math.maxInt(usize);

/// Backtracking-effort ceiling across one `exec` (all start positions).
/// Unbounded quantifiers can't spin a zero-width loop — the §22.2.2.3
/// progress guard (`prog_mark`/`prog_check`) fails an iteration that
/// consumes nothing — but a pathological nesting of bounded backtracking
/// (`(a*)*b` on a long non-matching run) can still blow up. This is the
/// backstop for that; the real ReDoS answer is the planned linear
/// engine, not this limit.
const step_limit: u64 = 1 << 24;

/// Inline capacity for the per-lookaround capture-snapshot buffer. A
/// zero-width assertion snapshots the live slot array before running
/// its sub-program; slot counts at or below this use a stack buffer,
/// larger ones spill to the heap. This is a small-vector perf hint,
/// not a correctness bound — it's deliberately decoupled from the
/// compiler's group/scratch ceilings so those can grow without
/// resizing a fixed buffer. 32 slots covers ≈every real pattern (16
/// capturing groups, or fewer groups plus progress-guard scratch)
/// with no allocation.
const lookaround_inline_slots: usize = 32;

pub const Match = struct {
    /// `2 * group_count` capture slots: `[2g]` start, `[2g+1]` end (in
    /// code units of the matched `Unit` width), or `none` if group `g`
    /// did not participate. Group 0 is the whole match. Any trailing
    /// `scratch_count` slots are VM-internal §22.2.2.3 progress marks —
    /// the caller reads only the capture slots. Caller-owned.
    slots: []usize,

    pub fn deinit(self: *Match, gpa: std.mem.Allocator) void {
        gpa.free(self.slots);
    }
};

/// §22.2.2.1 AdvanceStringIndex: how far the leftmost scan steps from
/// `s`. One code unit normally; two when `/u`/`/v` and `s` begins a
/// UTF-16 surrogate pair, so a start position is never mid-pair. `u8`
/// inputs are Latin1 (no surrogates), so the stride is always one.
fn scanStride(comptime Unit: type, unicode: bool, input: []const Unit, s: usize) usize {
    if (Unit == u16 and unicode and s + 1 < input.len) {
        const hi = input[s];
        const lo = input[s + 1];
        if (hi >= 0xD800 and hi <= 0xDBFF and lo >= 0xDC00 and lo <= 0xDFFF) return 2;
    }
    return 1;
}

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
    // `2 * group_count` capture slots, then `scratch_count` §22.2.2.3
    // progress-guard slots (`prog_mark` / `prog_check`).
    const slots = try gpa.alloc(usize, 2 * program.group_count + program.scratch_count);
    errdefer gpa.free(slots);

    var m: Matcher(Unit) = .{
        .prog = program,
        .input = input,
        .slots = slots,
        .gpa = gpa,
        // `/v` (UnicodeSets) matches over code points like `/u`.
        .unicode = program.flags.unicode or program.flags.unicode_sets,
        .folder = program.case_folder,
        .nonu_fold = program.nonu_fold,
    };
    defer m.deinit();

    var s = start;
    while (s <= input.len) {
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
        // §22.2.2.1 AdvanceStringIndex: under `/u`/`/v` the leftmost scan
        // steps by whole code points, so a start position never lands
        // between the two halves of a surrogate pair — otherwise a
        // negated class (`[^𝌆]`) could spuriously match the lone low
        // surrogate sitting mid-pair.
        s += scanStride(Unit, m.unicode, input, s);
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
        /// `u` flag — match over code points (decode surrogate pairs).
        /// `u`/`v` aren't modifiable by an inline `(?…)` group, so unlike
        /// the `i`/`m`/`s` flags (now baked per-instruction by the
        /// compiler) this stays matcher-global.
        unicode: bool,
        /// §22.2.2.9 case-folding orbits, injected for `/iu`/`/iv`. Null
        /// for ASCII-`i` (folded inline) and non-folding patterns.
        folder: ?compiler.CaseFoldFn,
        /// §22.2.2.7.3 non-Unicode Canonicalize orbits, injected for a
        /// non-`/u` `i` pattern with a non-ASCII unit. Distinct mapping
        /// from `folder`; null when the pattern is ASCII-only `i` (folded
        /// inline via `asciiUpper`) or non-folding.
        nonu_fold: ?compiler.CaseFoldFn,
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
            return self.runLoop(self.prog.insts, &self.backtrack, &self.undo, start, false);
        }

        /// Run `insts` from `sp_start` against the given backtrack/undo
        /// stacks. The main match uses the matcher's stacks; a lookaround
        /// runs its sub-program with fresh, self-contained stacks so it
        /// can't disturb the outer match. `backward` matches characters
        /// right-to-left (for a lookbehind). Returns whether a `match`
        /// instruction was reached.
        fn runLoop(
            self: *Self,
            insts: []const compiler.Inst,
            backtrack: *std.ArrayListUnmanaged(Frame),
            undo: *std.ArrayListUnmanaged(Undo),
            sp_start: usize,
            backward: bool,
        ) error{ OutOfMemory, StepLimit }!bool {
            var pc: usize = 0;
            var sp: usize = sp_start;
            while (true) {
                self.steps += 1;
                if (self.steps > step_limit) return error.StepLimit;

                switch (insts[pc]) {
                    .char => |ch| {
                        if (self.peek(sp, backward)) |c| {
                            const ok = self.charEq(c.cp, ch.cp, ch.fold);
                            if (ok) {
                                sp = if (backward) sp - c.len else sp + c.len;
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
                    .prog_mark => |slot| {
                        // §22.2.2.3 — stamp the iteration's start position
                        // so the matching `prog_check` can tell whether the
                        // body consumed anything. Logged to `undo`, so a
                        // backtrack restores the prior mark.
                        try self.write(undo, slot, sp);
                        pc += 1;
                        continue;
                    },
                    .prog_check => |slot| {
                        // §22.2.2.3 step 2.b — the iteration advanced: keep
                        // looping. It consumed nothing: fall through to the
                        // backtrack below, which abandons this (empty) path
                        // and so stops the loop, rolling its captures back.
                        if (sp != self.slots[slot]) {
                            pc += 1;
                            continue;
                        }
                    },
                    .counter_init => |ci| {
                        // §22.2.2.3 — seed a counted loop's iteration count.
                        // Logged to `undo`, so a backtrack restores any
                        // prior value (a counted loop nested inside another
                        // quantifier's body is re-seeded each outer pass).
                        try self.write(undo, ci.slot, ci.n);
                        pc += 1;
                        continue;
                    },
                    .counter_loop => |cl| {
                        // §22.2.2.3 — one counted iteration done: decrement
                        // and loop back while passes remain, else fall
                        // through. Only reached by fall-through after a full
                        // body match, so the counter is ≥ 1. The decrement
                        // is logged so a backtrack restores the count.
                        std.debug.assert(self.slots[cl.slot] >= 1);
                        const remaining = self.slots[cl.slot] - 1;
                        try self.write(undo, cl.slot, remaining);
                        pc = if (remaining > 0) cl.target else pc + 1;
                        continue;
                    },
                    .assert_start => |multiline| {
                        // `^`: input start, or (multiline) just after a
                        // line terminator.
                        if (sp == 0 or (multiline and isLineTerminator(self.input[sp - 1]))) {
                            pc += 1;
                            continue;
                        }
                    },
                    .assert_end => |multiline| {
                        // `$`: input end, or (multiline) just before a
                        // line terminator.
                        if (sp == self.input.len or (multiline and isLineTerminator(self.input[sp]))) {
                            pc += 1;
                            continue;
                        }
                    },
                    .class => |cls| {
                        if (self.peek(sp, backward)) |c| {
                            var inside = classContains(cls.ranges, c.cp);
                            // Under `i`, a code point matches the class if
                            // any case-fold partner is in the set. Under
                            // `/iu`/`/iv` that is the full orbit (§22.2.2.9);
                            // otherwise the single ASCII case partner. The
                            // `i` flag is baked per-instruction so an inline
                            // `(?i:…)` / `(?-i:…)` group scopes it.
                            if (cls.fold and !inside) {
                                if (self.unicode) {
                                    if (self.folder) |f| {
                                        for (f(c.cp)) |p| {
                                            if (classContains(cls.ranges, p)) {
                                                inside = true;
                                                break;
                                            }
                                        }
                                    }
                                } else if (c.cp < 128) {
                                    // Non-Unicode `i`: an ASCII unit has
                                    // exactly one case partner (§22.2.2.7.3
                                    // never crosses 0x80, so it can only
                                    // match an ASCII class member).
                                    inside = classContains(cls.ranges, asciiSwapCase(c.cp));
                                } else if (self.nonu_fold) |f| {
                                    // A non-ASCII unit matches if any member
                                    // of its non-Unicode Canonicalize orbit
                                    // (à↔À, σ/ς/Σ, …) is in the set.
                                    for (f(c.cp)) |p| {
                                        if (classContains(cls.ranges, p)) {
                                            inside = true;
                                            break;
                                        }
                                    }
                                }
                            }
                            if (inside != cls.negated) {
                                sp = if (backward) sp - c.len else sp + c.len;
                                pc += 1;
                                continue;
                            }
                        }
                    },
                    .word_boundary => |wb| {
                        const before = sp > 0 and self.wordCharAt(sp - 1, wb.fold);
                        const after = sp < self.input.len and self.wordCharAt(sp, wb.fold);
                        if ((before != after) != wb.negated) {
                            pc += 1;
                            continue;
                        }
                    },
                    .backref => |g| {
                        if (self.matchBackref(g.index, &sp, g.fold, backward)) {
                            pc += 1;
                            continue;
                        }
                    },
                    .backref_dup => |bd| {
                        // Match whichever same-named group participated
                        // (the early error guarantees at most one is
                        // set); if none, the backreference matches the
                        // empty string.
                        var g: ?usize = null;
                        for (bd.indices) |cand| {
                            if (self.slots[2 * cand] != none and self.slots[2 * cand + 1] != none) {
                                g = cand;
                                break;
                            }
                        }
                        if (g) |group| {
                            if (self.matchBackref(group, &sp, bd.fold, backward)) {
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
                        //
                        // Snapshot the live slot array — capture slots plus
                        // the §22.2.2.3 scratch slots a nullable quantifier
                        // in the sub-program may use — so the outcome can be
                        // rolled back. Sized to the actual slot count, not a
                        // compile-time ceiling: small counts (≈all patterns)
                        // use the inline buffer, larger ones spill to the
                        // heap. Each lookaround (including nested ones) gets
                        // its own `saved` on the call stack, so there's no
                        // sharing hazard; the heap slice, when taken, stays
                        // valid across the recursive `runLoop` below.
                        const n = self.slots.len;
                        var inline_buf: [lookaround_inline_slots]usize = undefined;
                        const saved = if (n <= inline_buf.len)
                            inline_buf[0..n]
                        else
                            try self.gpa.alloc(usize, n);
                        defer if (n > inline_buf.len) self.gpa.free(saved);
                        @memcpy(saved, self.slots);
                        var sub_bt: std.ArrayListUnmanaged(Frame) = .empty;
                        defer sub_bt.deinit(self.gpa);
                        var sub_undo: std.ArrayListUnmanaged(Undo) = .empty;
                        defer sub_undo.deinit(self.gpa);
                        const matched = try self.runLoop(la.sub, &sub_bt, &sub_undo, sp, la.behind);
                        if (matched != la.negative) {
                            if (la.negative) {
                                // A negative lookahead contributes no captures.
                                @memcpy(self.slots, saved);
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

        /// §22.2.2.9 Canonicalize equality: does input code point `a`
        /// match pattern code point `b` under the active flags? `fold` is
        /// the effective `i` flag baked at the instruction (an inline
        /// modifier group can flip it). Without `i`, exact equality. With
        /// non-Unicode `i`, ASCII case fold. With `/iu`/`/iv`, `a` matches
        /// `b` if they share a case-folding orbit — `b` is among `a`'s
        /// injected partners. Symmetric, since orbit membership is mutual.
        fn charEq(self: *Self, a: u21, b: u21, fold: bool) bool {
            if (!fold) return a == b;
            if (self.unicode) {
                if (a == b) return true;
                if (self.folder) |f| {
                    for (f(a)) |p| if (p == b) return true;
                }
                return false;
            }
            // Non-Unicode `i` (§22.2.2.7.3 Canonicalize). An ASCII unit
            // canonicalizes by asciiUpper, and the non-Unicode mapping
            // never crosses the 0x80 boundary in either direction (the
            // ASCII-exclusion blocks non-ASCII→ASCII; ASCII→non-ASCII
            // doesn't occur), so a unit on one side of 0x80 can only match
            // one on the same side. With either operand ASCII, the
            // asciiUpper compare decides (and a mixed pair never folds).
            if (a < 128 or b < 128) return asciiUpper(a) == asciiUpper(b);
            // Both non-ASCII: equal, or sharing a non-Unicode Canonicalize
            // orbit (à↔À, σ/ς/Σ, …) via the injected folder. Null folder
            // (ASCII-only `i`) can't reach here — such a pattern has no
            // non-ASCII unit to compare.
            if (a == b) return true;
            if (self.nonu_fold) |f| {
                for (f(a)) |p| if (p == b) return true;
            }
            return false;
        }

        /// Whether the code unit at `idx` is a §22.2.2.9.3 WordCharacters
        /// member. `fold` is the effective `i` flag; under `/iu`/`/iv`
        /// the set extends to every character whose Canonicalize is an
        /// ASCII word char — e.g. ſ (U+017F) and U+212A KELVIN SIGN, which
        /// fold to `s` and `k`. Those partners are all BMP, so one code
        /// unit suffices; non-Unicode `i` never folds a non-ASCII unit to
        /// ASCII (§22.2.2.7.3), so the extension is gated on `unicode`.
        fn wordCharAt(self: *Self, idx: usize, fold: bool) bool {
            const u: u21 = self.input[idx];
            if (isWordChar(u)) return true;
            if (fold and self.unicode) {
                if (self.folder) |f| {
                    for (f(u)) |p| if (isWordChar(p)) return true;
                }
            }
            return false;
        }

        const CodePoint = struct { cp: u21, len: usize };

        /// Read one code point at `sp` (forward) or ending just before
        /// `sp` (backward). Under `/u` a surrogate pair decodes to one
        /// code point of length 2; otherwise each code unit stands
        /// alone. Returns null at the input boundary.
        fn peek(self: *Self, sp: usize, backward: bool) ?CodePoint {
            return if (backward) self.peekBack(sp, 0) else self.peekAt(sp, self.input.len);
        }

        /// Backward-decode one code point *ending* at `idx` (exclusive
        /// upper), bounded below by `lower` so a surrogate pair is never
        /// read across a slice boundary. Under `/u`/`/v` a valid high+low
        /// pair ending at `idx` is one code point of length 2; otherwise
        /// each code unit stands alone. Null when `idx <= lower`.
        fn peekBack(self: *Self, idx: usize, lower: usize) ?CodePoint {
            if (idx <= lower) return null;
            const lo: u21 = self.input[idx - 1];
            if (self.unicode and lo >= 0xDC00 and lo <= 0xDFFF and idx >= lower + 2) {
                const hi: u21 = self.input[idx - 2];
                if (hi >= 0xD800 and hi <= 0xDBFF) {
                    return .{ .cp = combineSurrogates(hi, lo), .len = 2 };
                }
            }
            return .{ .cp = lo, .len = 1 };
        }

        /// Forward-decode one code point at `idx`, bounded by `limit` (so
        /// a surrogate pair is never read across a slice boundary). Under
        /// `/u`/`/v` a valid high+low pair is one code point of length 2;
        /// otherwise each code unit stands alone. Null when `idx >= limit`.
        fn peekAt(self: *Self, idx: usize, limit: usize) ?CodePoint {
            if (idx >= limit) return null;
            const hi: u21 = self.input[idx];
            if (self.unicode and hi >= 0xD800 and hi <= 0xDBFF and idx + 1 < limit) {
                const lo: u21 = self.input[idx + 1];
                if (lo >= 0xDC00 and lo <= 0xDFFF) {
                    return .{ .cp = combineSurrogates(hi, lo), .len = 2 };
                }
            }
            return .{ .cp = hi, .len = 1 };
        }

        /// Match the text captured by group `g` against the input at `sp`,
        /// advancing `sp` on success. Forward (`backward == false`) the
        /// candidate *begins* at `sp`; in a lookbehind (`backward == true`)
        /// it *ends* at `sp`, so `sp` moves left. An unset group matches
        /// the empty string. `fold` is the effective `i` flag baked at the
        /// backreference.
        fn matchBackref(self: *Self, g: usize, sp: *usize, fold: bool, backward: bool) bool {
            const cs = self.slots[2 * g];
            const ce = self.slots[2 * g + 1];
            if (cs == none or ce == none) return true; // unset → empty
            // Under `/iu`/`/iv` fold code point by code point: a fold pair
            // can span a surrogate pair (e.g. Deseret U+10400↔U+10428), so
            // per-code-unit folding would break. Simple case folding never
            // changes the code-point count, but compare against each cursor
            // independently rather than assuming equal unit lengths. The
            // captured text and the candidate are decoded in the same
            // direction, so comparing them pairwise stays in source order.
            if (fold and self.unicode) {
                if (backward) {
                    var ci = ce;
                    var si = sp.*;
                    while (ci > cs) {
                        const cap = self.peekBack(ci, cs).?; // in-bounds: ci > cs
                        const cand = self.peekBack(si, 0) orelse return false;
                        if (!self.charEq(cand.cp, cap.cp, fold)) return false;
                        ci -= cap.len;
                        si -= cand.len;
                    }
                    sp.* = si;
                    return true;
                }
                var ci = cs;
                var si = sp.*;
                while (ci < ce) {
                    const cap = self.peekAt(ci, ce).?; // in-bounds: ci < ce
                    const cand = self.peekAt(si, self.input.len) orelse return false;
                    if (!self.charEq(cand.cp, cap.cp, fold)) return false;
                    ci += cap.len;
                    si += cand.len;
                }
                sp.* = si;
                return true;
            }
            const len = ce - cs;
            // Exact / ASCII-fold matching compares code units directly, so a
            // backreference of `len` units begins at `sp` forward, or ends
            // at `sp` (begins at `sp - len`) in a lookbehind.
            const base = if (backward) blk: {
                if (sp.* < len) return false;
                break :blk sp.* - len;
            } else blk: {
                if (sp.* + len > self.input.len) return false;
                break :blk sp.*;
            };
            if (fold) {
                // Non-Unicode `i` folds per code unit (no surrogate
                // combining — that is the `/iu` path above), so a unit-wise
                // charEq is exact: ASCII via asciiUpper, non-ASCII via the
                // injected §22.2.2.7.3 orbit (à↔À, …).
                var i: usize = 0;
                while (i < len) : (i += 1) {
                    if (!self.charEq(self.input[base + i], self.input[cs + i], true)) return false;
                }
            } else {
                if (!std.mem.eql(Unit, self.input[cs..ce], self.input[base .. base + len])) return false;
            }
            sp.* = if (backward) base else sp.* + len;
            return true;
        }
    };
}
