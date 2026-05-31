//! Perlex compiler — lowers the §22.2.1 AST to a flat instruction
//! program for the backtracking VM. The instruction set follows the
//! NFA-program style (Thompson/Pike, as adapted for backtracking by
//! Cox, "Regular Expression Matching: the Virtual Machine Approach"),
//! extended with capture, capture-clear, anchor, and backreference
//! ops so it can express the backtracking semantics ECMA-262 §22.2.2
//! requires (which a pure NFA can't, because of backreferences).

const std = @import("std");
const parser = @import("parser.zig");
const charset = @import("charset.zig");
const Node = parser.Node;

/// Upper bound on capturing groups (including the whole match) Perlex
/// handles; patterns with more fall back to the vendored matcher. Set to
/// match libregexp's CAPTURE_COUNT_MAX (255 groups counting the implicit
/// group 0 — i.e. ≤ 254 explicit), so every pattern the fallback would
/// accept Perlex also owns, and a pattern past the ceiling is rejected by
/// both. This is a deferral threshold, not a buffer bound: the slot array
/// is heap-sized per program and the lookaround snapshot spills to the
/// heap past a small inline size, so nothing here is forced by a fixed
/// buffer.
pub const max_groups = 255;

/// Inline-vs-counted threshold for a bounded quantifier. At or below
/// this, each mandatory / optional iteration inlines one body copy — no
/// per-iteration counter overhead, fastest for the common small bounds.
/// Above it the lowering switches to a counted loop (`counter_init` /
/// `counter_loop`), so a huge bound (`a{0,1000000}`) compiles to a
/// constant-size program instead of a million inlined copies. The
/// mandatory `min` and optional `max − min` spans are decided
/// independently — `a{2,100000}` inlines the two mandatory copies and
/// counts the optional tail.
pub const max_repeat_expand = 1024;

/// Upper bound on §22.2.2.3 progress-guard scratch slots — one per
/// quantifier over a nullable body; patterns with more defer to the
/// vendored matcher. Like `max_groups`, a conservative deferral
/// threshold rather than a structural limit: the slot array and the
/// per-lookaround snapshot are both sized at runtime, so the bound
/// isn't forced by a fixed buffer.
pub const max_scratch = 64;

pub const Flags = packed struct {
    global: bool = false,
    ignore_case: bool = false,
    multiline: bool = false,
    dot_all: bool = false,
    unicode: bool = false,
    sticky: bool = false,
    has_indices: bool = false,
    unicode_sets: bool = false,
};

/// A resolved `\p{…}` property: its code-point ranges plus, for the
/// `/v`-mode *properties of strings* (§22.2.1.1, e.g. `RGI_Emoji`), the
/// multi-code-point sequence members. `strings` is empty for every
/// ordinary property; each entry has length ≥ 2 (single-code-point
/// members fold into `ranges`). Both halves are allocated by the resolver
/// from the allocator it is handed.
pub const ResolvedProperty = struct {
    ranges: []const parser.Node.ClassRange,
    strings: []const []const u21 = &.{},
};

/// Resolves a `\p{…}` property escape to ranges (and, for properties of
/// strings, sequence members). Returns a `ResolvedProperty` allocated
/// from the handed allocator, or null to decline the whole pattern to the
/// fallback matcher. `key` is the `Name` of `\p{Name=Value}`, or null for
/// the lone `\p{NameOrValue}` form. Injected so Perlex itself carries no
/// Unicode data — the bridge backs it with Cynic's generated tables.
pub const PropertyResolver = *const fn (
    gpa: std.mem.Allocator,
    key: ?[]const u8,
    value: []const u8,
) std.mem.Allocator.Error!?ResolvedProperty;

/// Resolves a code point to the other members of its §22.2.2.9
/// Canonicalize equivalence class under Unicode case folding — the
/// simple/common case-folding orbit (CaseFolding.txt statuses C and S)
/// *excluding* `cp` itself. Returns an empty slice when `cp` folds only
/// to itself. The returned slice points at static table data the VM
/// never frees. Injected so Perlex carries no Unicode data — the bridge
/// backs it with Cynic's generated CaseFolding tables; a null folder
/// defers every `/iu`/`/iv` pattern to the fallback matcher.
pub const CaseFoldFn = *const fn (cp: u21) []const u21;

pub const Inst = union(enum) {
    /// Match one literal — a UTF-16 code unit, or a code point up to
    /// U+10FFFF under `/u` — then advance. `fold` is the effective `i`
    /// flag baked at this position (§22.2.1 inline modifiers let it
    /// differ from the program flag inside a `(?i:…)` / `(?-i:…)` group).
    char: Char,
    /// Accept — the whole-match end slot has already been saved.
    match,
    /// Unconditional jump to an instruction index.
    jmp: usize,
    /// Try `a` first; on backtrack, resume at `b`.
    split: Split,
    /// Record the current position into capture slot `n`.
    save: usize,
    /// Reset capture slots `[from, to)` to "unset" (§22.2.2.3 step 4).
    clear: Range,
    /// `^` — succeed only at input start; the bool is the effective `m`
    /// flag, baked per-position so an inline modifier group can override
    /// it (true → also match just after a line terminator).
    assert_start: bool,
    /// `$` — succeed only at input end; the bool is the effective `m`
    /// flag (true → also match just before a line terminator).
    assert_end: bool,
    /// Match the text previously captured by group `n` (or the empty
    /// string if that group did not participate).
    backref: Backref,
    /// `\k<name>` where the name is duplicated: match the text of
    /// whichever listed group participated (§22.2.2 with duplicate
    /// group names). At most one can be set, per the early error.
    backref_dup: BackrefDup,
    /// Match one code unit against a class (`.`, `[…]`, `\d`/`\w`/`\s`
    /// and negated forms), advancing on success. `ranges` is owned by
    /// the program; `fold` is the effective `i` flag baked at this
    /// position.
    class: ClassInst,
    /// `\b` / `\B` word-boundary assertion. `negated` is true for `\B`;
    /// `fold` is the effective `i` flag baked at this position (an inline
    /// `(?i:…)` group scopes it). Under `/iu`/`/iv` the word set extends to
    /// every character whose Canonicalize is an ASCII word char (§22.2.2.9.3
    /// WordCharacters), so the assertion needs the flag at match time.
    word_boundary: WordBoundary,
    /// `(?=…)` / `(?!…)` — run `sub` (a self-contained program ending
    /// in `match`) at the current position without consuming input;
    /// `negative` inverts success.
    lookahead: LookInst,
    /// §22.2.2.3 zero-width progress guard, top of a guarded iteration:
    /// record the current input position into scratch slot `n` (a slot
    /// past the capture slots in the same array). Logged to the undo
    /// stack, so a backtrack rolls it back like any capture write.
    prog_mark: usize,
    /// §22.2.2.3 step 2.b, bottom of a guarded iteration: succeed only
    /// when the position advanced since the matching `prog_mark`. An
    /// iteration that consumed nothing fails here, which (falling
    /// through to backtrack) stops the loop and rolls the empty
    /// iteration's captures back to "unset".
    prog_check: usize,
    /// Counted-loop initializer: set counter slot `slot` to its bound `n`
    /// (the mandatory `min`, or the optional `max − min`). The slot lives
    /// past the captures like a progress mark, so the undo log rolls it
    /// back on backtrack. Emitted by the counted-loop lowering of a large
    /// bounded quantifier so the body need not be inlined per iteration —
    /// the program stays a constant size regardless of the bound.
    /// §22.2.2.3 RepeatMatcher.
    counter_init: CounterInit,
    /// Counted-loop step: decrement counter slot `slot`; jump to `target`
    /// while it is still greater than zero, else fall through (iterations
    /// exhausted). The decrement is undo-logged so a backtrack restores
    /// the prior count. Reached only by fall-through after a body match,
    /// so the counter is ≥ 1 here. §22.2.2.3 RepeatMatcher.
    counter_loop: CounterLoop,

    pub const Char = struct { cp: u21, fold: bool };
    pub const WordBoundary = struct { negated: bool, fold: bool };
    pub const Backref = struct { index: usize, fold: bool };
    pub const BackrefDup = struct { indices: []const usize, fold: bool };
    pub const ClassInst = struct { negated: bool, ranges: []const parser.Node.ClassRange, fold: bool };
    pub const Split = struct { a: usize, b: usize };
    pub const Range = struct { from: usize, to: usize };
    pub const LookInst = struct { negative: bool, behind: bool, sub: []const Inst };
    pub const CounterInit = struct { slot: usize, n: usize };
    pub const CounterLoop = struct { slot: usize, target: usize };
};

/// Free the owned allocations inside each instruction (class ranges,
/// dup-backref index lists, nested lookahead sub-programs).
fn freeInstContents(gpa: std.mem.Allocator, insts: []const Inst) void {
    for (insts) |inst| switch (inst) {
        .backref_dup => |bd| gpa.free(bd.indices),
        .class => |cls| gpa.free(cls.ranges),
        .lookahead => |la| freeInsts(gpa, la.sub),
        else => {},
    };
}

/// `freeInstContents` plus the instruction slice itself.
fn freeInsts(gpa: std.mem.Allocator, insts: []const Inst) void {
    freeInstContents(gpa, insts);
    gpa.free(insts);
}

pub const Program = struct {
    insts: []Inst,
    /// Capturing groups including the whole match (group 0). The VM's
    /// slot array holds `2 * group_count` capture slots followed by
    /// `scratch_count` progress-guard slots, so its length is
    /// `2 * group_count + scratch_count`.
    group_count: usize,
    /// §22.2.2.3 progress-guard scratch slots appended after the
    /// capture slots (see `group_count`). Zero for a pattern with no
    /// quantifier over a nullable body.
    scratch_count: usize = 0,
    /// Group name per group index; length `group_count`, index 0 null.
    names: []const ?[]const u8,
    flags: Flags,
    /// True when the pattern is "regular" — no backreferences (and, in
    /// future, no lookaround). Such patterns admit a linear-time
    /// Thompson/PikeVM strategy; the backtracking VM is only required
    /// when this is false. Unused until that engine lands, but the
    /// classification is the seam it plugs into.
    is_regular: bool,
    /// Unicode case-folding orbit resolver, applied at match time for
    /// `/iu`/`/iv` (§22.2.2.9 Canonicalize). Null for non-folding
    /// patterns and for ASCII-`i`, which the VM folds inline. Set by the
    /// caller after `compile`; it is injected data, not derived here.
    case_folder: ?CaseFoldFn = null,
    /// Non-Unicode Canonicalize orbit resolver, applied at match time for
    /// a non-`/u`/`/v` `i` pattern that contains a non-ASCII unit
    /// (§22.2.2.7.3 step 3 — toUppercase with the ASCII-exclusion). Same
    /// orbit signature as `case_folder` but a *different* mapping (e.g.
    /// U+212A KELVIN folds to `k` under `/iu` but to itself here). Null
    /// for ASCII-only `i` (the VM folds those inline via asciiUpper);
    /// injected by the caller, not derived here.
    nonu_fold: ?CaseFoldFn = null,
    gpa: std.mem.Allocator,

    pub fn deinit(self: *Program) void {
        freeInsts(self.gpa, self.insts);
        for (self.names) |maybe| {
            if (maybe) |name| self.gpa.free(name);
        }
        self.gpa.free(self.names);
    }
};

pub const CompileError = error{ Unsupported, SyntaxError, OutOfMemory };

pub fn compile(gpa: std.mem.Allocator, result: parser.ParseResult, flags: Flags, resolver: ?PropertyResolver) CompileError!Program {
    if (result.capture_count + 1 > max_groups) return error.Unsupported;
    var c: Compiler = .{
        .gpa = gpa,
        .names = result.names,
        .insts = .empty,
        .fold = flags.ignore_case,
        .multiline = flags.multiline,
        .dot_all = flags.dot_all,
        .resolver = resolver,
    };
    errdefer c.deinitPartial();

    // Wrap the pattern so group 0 spans the whole match.
    try c.emit(.{ .save = 0 });
    try c.compileNode(result.root);
    try c.emit(.{ .save = 1 });
    try c.emit(.match);

    const names = try copyNames(gpa, result.names);
    errdefer freeNames(gpa, names);

    return .{
        .insts = try c.insts.toOwnedSlice(gpa),
        .group_count = result.capture_count + 1,
        .scratch_count = c.scratch_count,
        .names = names,
        .flags = flags,
        .is_regular = c.regular,
        .gpa = gpa,
    };
}

fn copyNames(gpa: std.mem.Allocator, src: []const ?[]const u8) CompileError![]const ?[]const u8 {
    const out = try gpa.alloc(?[]const u8, src.len);
    var filled: usize = 0;
    errdefer {
        for (out[0..filled]) |maybe| if (maybe) |n| gpa.free(n);
        gpa.free(out);
    }
    for (src, 0..) |maybe, i| {
        out[i] = if (maybe) |name| try gpa.dupe(u8, name) else null;
        filled = i + 1;
    }
    return out;
}

fn freeNames(gpa: std.mem.Allocator, names: []const ?[]const u8) void {
    for (names) |maybe| if (maybe) |n| gpa.free(n);
    gpa.free(names);
}

const Compiler = struct {
    gpa: std.mem.Allocator,
    names: []const ?[]const u8,
    insts: std.ArrayListUnmanaged(Inst),
    /// Effective `i`/`m`/`s` flags at the current compile position.
    /// Seeded from the program flags; an inline modifier group
    /// (`(?i-m:…)`, §22.2.1 UpdateModifiers) saves, overrides, compiles
    /// its body, and restores these — so each char/class/anchor
    /// instruction bakes the flag in force where it sits.
    fold: bool,
    multiline: bool,
    /// The `s` (dotall) flag — `.` matches line terminators too.
    dot_all: bool,
    /// True while compiling a lookbehind body — concatenations are
    /// emitted in reverse so the VM matches them right-to-left.
    backward: bool = false,
    /// Cleared to false the moment a backreference is emitted — the
    /// pattern is then no longer in the regular subset.
    regular: bool = true,
    /// Resolver for `\p{…}` escapes, or null when the caller offers none
    /// (then property escapes defer the whole pattern to the fallback).
    resolver: ?PropertyResolver = null,
    /// Count of §22.2.2.3 progress-guard scratch slots handed out so far
    /// (see `allocScratch`); becomes `Program.scratch_count`.
    scratch_count: usize = 0,

    /// Hand out a fresh VM slot just past the `2 * group_count` capture
    /// slots in the shared slot array (`names.len` is the group count,
    /// including group 0), for a §22.2.2.3 progress guard
    /// (`prog_mark`/`prog_check`) or a counted-loop counter
    /// (`counter_init`/`counter_loop`). Living in that array means the
    /// undo log rolls the slot back on backtrack like any capture, and the
    /// bridge — which reads only the capture slots — never sees it.
    /// Declines to the fallback once the fixed slot budget (`max_scratch`)
    /// is spent: the VM snapshots the whole array into a stack buffer per
    /// lookaround, so the count must be bounded.
    fn allocScratch(self: *Compiler) CompileError!usize {
        if (self.scratch_count >= max_scratch) return error.Unsupported;
        const idx = 2 * self.names.len + self.scratch_count;
        self.scratch_count += 1;
        return idx;
    }

    fn deinitPartial(self: *Compiler) void {
        freeInstContents(self.gpa, self.insts.items);
        self.insts.deinit(self.gpa);
    }

    fn emit(self: *Compiler, inst: Inst) CompileError!void {
        try self.insts.append(self.gpa, inst);
    }

    /// Emit a `.class` instruction with program-owned ranges that are
    /// sorted ascending and disjoint. `charset.normalize` does the
    /// sort+merge and allocates the kept copy, so callers may pass raw,
    /// unsorted, or overlapping ranges (a user class like `[c-ea-c]`)
    /// or already-sorted ones (a resolved `\p{…}` set) interchangeably.
    /// This is the single choke point that establishes the sorted-and-
    /// disjoint invariant the VM's binary `classContains` relies on.
    fn emitClass(self: *Compiler, negated: bool, ranges: []const Node.ClassRange, fold: bool) CompileError!void {
        const owned = try charset.normalize(self.gpa, ranges);
        self.emit(.{ .class = .{ .negated = negated, .ranges = owned, .fold = fold } }) catch |e| {
            self.gpa.free(owned);
            return e;
        };
    }

    fn here(self: *Compiler) usize {
        return self.insts.items.len;
    }

    fn compileNode(self: *Compiler, node: *const Node) CompileError!void {
        switch (node.*) {
            .empty => {},
            .char => |ch| try self.emit(.{ .char = .{ .cp = ch, .fold = self.fold } }),
            .anchor_start => try self.emit(.{ .assert_start = self.multiline }),
            .anchor_end => try self.emit(.{ .assert_end = self.multiline }),
            .word_boundary => |neg| try self.emit(.{ .word_boundary = .{ .negated = neg, .fold = self.fold } }),
            .dot => {
                // `.` excludes line terminators unless dotall (`s`), in
                // which case it matches any code unit (negated empty
                // class).
                // The line-terminator set has no case partners, so the
                // effective `i` flag never changes a `.` match: bake false.
                const src_ranges: []const parser.Node.ClassRange =
                    if (self.dot_all) &[_]parser.Node.ClassRange{} else &parser.line_terminator_ranges;
                try self.emitClass(true, src_ranges, false);
            },
            .class => |cls| {
                // Copy the ranges into program-owned memory (the AST is
                // arena/const and freed after compilation); emitClass
                // sorts + merges them for the VM's binary search.
                try self.emitClass(cls.negated, cls.ranges, self.fold);
            },
            .prop => |p| {
                // §22.2.1.1 — resolve the property via the injected
                // resolver; declined properties (unknown, or valid but
                // unsupported here, e.g. Script) defer the whole pattern to
                // the fallback. The resolver allocates into a scratch arena;
                // the emitted instructions copy what they keep into program
                // memory.
                var scratch = std.heap.ArenaAllocator.init(self.gpa);
                defer scratch.deinit();
                const a = scratch.allocator();
                const resolve = self.resolver orelse return error.Unsupported;
                const rp = (try resolve(a, p.key, p.value)) orelse return error.Unsupported;
                if (rp.strings.len == 0) {
                    // §22.2.2.7.1 — `\P{…}` builds the COMPLEMENT CharSet
                    // matched with invert = false, not the base set matched
                    // with invert = true (that is what `[^…]` does). The two
                    // coincide without case folding, but diverge under /iu
                    // when the property isn't closed under §22.2.2.9.3
                    // Canonicalize (e.g. Lu holds 'A' whose fold 'a' ∉ Lu):
                    // only the complemented set, tested via the VM's orbit
                    // membership, yields the spec's `∃ d ∈ orbit(ch): d ∉ Lu`.
                    // Mirror the /v operand path (evalOperand), which already
                    // complements `\P{…}`.
                    const base: []const Node.ClassRange = if (p.negated)
                        try charset.complement(a, rp.ranges)
                    else
                        rp.ranges;
                    try self.emitClass(false, base, self.fold);
                } else {
                    // A property of strings (§22.2.1.1). The parser rejects
                    // `\P{…}` of one and the non-`/v` forms as early errors,
                    // so a resolved string set here is positive and `/v`;
                    // lower it like a `/v` ClassSetExpression. The negation
                    // guard is defensive — it cannot fire post-parse.
                    if (p.negated) return error.SyntaxError;
                    try self.emitResolvedSet(a, rp.ranges, rp.strings);
                }
            },
            .class_set => |cs| try self.compileClassSet(cs),
            .concat => |parts| {
                if (self.backward) {
                    // Reverse the sequence so right-to-left execution in
                    // a lookbehind matches the body in source order.
                    var i = parts.len;
                    while (i > 0) {
                        i -= 1;
                        try self.compileNode(parts[i]);
                    }
                } else {
                    for (parts) |part| try self.compileNode(part);
                }
            },
            .noncapture => |body| try self.compileNode(body),
            .capture => |g| {
                // In a lookbehind the body runs right-to-left, entering at
                // the group's right boundary and exiting at the left, so
                // save the end slot (2g+1) first and the start slot (2g)
                // last — keeping the recorded [start, end) left-to-right.
                if (self.backward) {
                    try self.emit(.{ .save = 2 * g.index + 1 });
                    try self.compileNode(g.body);
                    try self.emit(.{ .save = 2 * g.index });
                } else {
                    try self.emit(.{ .save = 2 * g.index });
                    try self.compileNode(g.body);
                    try self.emit(.{ .save = 2 * g.index + 1 });
                }
            },
            .alternate => |alts| try self.compileAlternation(alts),
            .repeat => |r| try self.compileRepeat(r),
            .lookahead => |la| {
                // §22.2.2.4 — a lookbehind compiles its body backward
                // (`compileSubProgram` reverses concatenations, swaps
                // capture saves, and matches backreferences ending at the
                // cursor); a nested assertion re-anchors with its own
                // direction. No body construct is excluded.
                const sub = try self.compileSubProgram(la.body, la.behind);
                self.emit(.{ .lookahead = .{ .negative = la.negative, .behind = la.behind, .sub = sub } }) catch |e| {
                    freeInsts(self.gpa, sub);
                    return e;
                };
            },
            .backref_name => |name| try self.compileBackref(name),
            .backref_index => |n| {
                // §22.2.1.1: a DecimalEscape whose CapturingGroupNumber
                // exceeds the number of capturing groups is a Syntax Error.
                // Annex B §B.1.2 would reinterpret `\N` as a legacy
                // octal/identity escape, but Cynic drops Annex B regex
                // leniency in every mode, so the early error stands.
                const total = self.names.len - 1; // capturing groups, excl group 0
                if (n == 0 or n > total) return error.SyntaxError;
                self.regular = false;
                try self.emit(.{ .backref = .{ .index = n, .fold = self.fold } });
            },
            .modifier_group => |mg| {
                // §22.2.1 inline modifiers — UpdateModifiers: an added flag
                // is set true and a removed flag false, scoped to this
                // group's body only. `u`/`v` aren't modifiable (the parser
                // rejects them), so the matcher-global unicode decode and
                // case-folder are untouched; only the per-position `i`/`m`/
                // `s` baking changes. Save/restore so the scope ends with
                // the group.
                const saved_fold = self.fold;
                const saved_multiline = self.multiline;
                const saved_dot_all = self.dot_all;
                defer {
                    self.fold = saved_fold;
                    self.multiline = saved_multiline;
                    self.dot_all = saved_dot_all;
                }
                if (mg.add.ignore_case) self.fold = true;
                if (mg.add.multiline) self.multiline = true;
                if (mg.add.dot_all) self.dot_all = true;
                if (mg.remove.ignore_case) self.fold = false;
                if (mg.remove.multiline) self.multiline = false;
                if (mg.remove.dot_all) self.dot_all = false;
                try self.compileNode(mg.body);
            },
        }
    }

    fn compileAlternation(self: *Compiler, alts: []const *Node) CompileError!void {
        var end_jumps: std.ArrayListUnmanaged(usize) = .empty;
        defer end_jumps.deinit(self.gpa);
        for (alts, 0..) |alt, i| {
            if (i + 1 < alts.len) {
                const split_idx = self.here();
                try self.emit(.{ .split = .{ .a = 0, .b = 0 } });
                const a_start = self.here();
                try self.compileNode(alt);
                try end_jumps.append(self.gpa, self.here());
                try self.emit(.{ .jmp = 0 });
                self.insts.items[split_idx].split = .{ .a = a_start, .b = self.here() };
            } else {
                try self.compileNode(alt);
            }
        }
        const end = self.here();
        for (end_jumps.items) |j| self.insts.items[j].jmp = end;
    }

    fn compileRepeat(self: *Compiler, r: Node.Repeat) CompileError!void {
        // A body that can match the empty string would spin a zero-width
        // loop without the §22.2.2.3 progress guard emitted below; every
        // such body is guarded here. The one nullable body with no
        // spec-legal lowering — a *directly*-quantified assertion (`^*`,
        // `\b?`, `(?=a)*`), a §22.2.1 QuantifiableAssertion accepted only
        // under Annex B, which Cynic drops — is a SyntaxError the parser
        // (`applyQuantifier`) already rejects, so it never reaches here.
        // With a non-nullable body every iteration consumes at least one
        // code unit, so the loops below terminate without a guard.
        const body_nullable = nullable(r.body);

        // §22.2.2.3 step 2.b guards only the *optional* iterations (the
        // unbounded tail, or the `max - min` skippable ones); its `min = 0`
        // precondition exempts the mandatory `min` iterations, which run
        // unconditionally and so participate even when they match empty.
        // One scratch slot serves all of a quantifier's optional
        // iterations, since each `prog_mark` re-stamps it.
        const has_optional = r.max == parser.unbounded_max or r.max > r.min;
        const guard = body_nullable and has_optional;
        const scratch: usize = if (guard) try self.allocScratch() else undefined;

        // `min` mandatory iterations — unguarded. A small count inlines one
        // body copy each (no per-iteration counter overhead); a large count
        // lowers to a counted loop so the program size stays constant.
        if (r.min <= max_repeat_expand) {
            var i: usize = 0;
            while (i < r.min) : (i += 1) try self.compileIteration(r.body);
        } else {
            const counter = try self.allocScratch();
            try self.emit(.{ .counter_init = .{ .slot = counter, .n = r.min } });
            const loop = self.here();
            try self.compileIteration(r.body);
            try self.emit(.{ .counter_loop = .{ .slot = counter, .target = loop } });
        }

        if (r.max == parser.unbounded_max) {
            // Greedy/lazy star over the body.
            const loop = self.here();
            const split_idx = self.here();
            try self.emit(.{ .split = .{ .a = 0, .b = 0 } });
            const body_start = self.here();
            if (guard) try self.emit(.{ .prog_mark = scratch });
            try self.compileIteration(r.body);
            if (guard) try self.emit(.{ .prog_check = scratch });
            try self.emit(.{ .jmp = loop });
            const exit = self.here();
            self.insts.items[split_idx].split = if (r.greedy)
                .{ .a = body_start, .b = exit }
            else
                .{ .a = exit, .b = body_start };
        } else if (r.max - r.min <= max_repeat_expand) {
            // `max - min` optional, each-skippable iterations, inlined.
            var splits: std.ArrayListUnmanaged(usize) = .empty;
            defer splits.deinit(self.gpa);
            var k = r.min;
            while (k < r.max) : (k += 1) {
                try splits.append(self.gpa, self.here());
                try self.emit(.{ .split = .{ .a = 0, .b = 0 } });
                if (guard) try self.emit(.{ .prog_mark = scratch });
                try self.compileIteration(r.body);
                if (guard) try self.emit(.{ .prog_check = scratch });
            }
            const exit = self.here();
            for (splits.items) |s| {
                // `s` is the split; its body begins at the next instruction
                // (the `prog_mark` when guarded, else the iteration body).
                const body_start = s + 1;
                self.insts.items[s].split = if (r.greedy)
                    .{ .a = body_start, .b = exit }
                else
                    .{ .a = exit, .b = body_start };
            }
        } else {
            // A large optional span — a counted loop wrapping one body
            // copy. The `split` at the loop top is the skip choice point
            // (greedy: try the body; on backtrack, exit), and the trailing
            // `counter_loop` bounds it to `max - min` passes. Together they
            // give bounded, backtrackable iteration without inlining.
            const counter = try self.allocScratch();
            try self.emit(.{ .counter_init = .{ .slot = counter, .n = r.max - r.min } });
            const loop = self.here();
            const split_idx = self.here();
            try self.emit(.{ .split = .{ .a = 0, .b = 0 } });
            const body_start = self.here();
            if (guard) try self.emit(.{ .prog_mark = scratch });
            try self.compileIteration(r.body);
            if (guard) try self.emit(.{ .prog_check = scratch });
            try self.emit(.{ .counter_loop = .{ .slot = counter, .target = loop } });
            const exit = self.here();
            self.insts.items[split_idx].split = if (r.greedy)
                .{ .a = body_start, .b = exit }
            else
                .{ .a = exit, .b = body_start };
        }
    }

    /// One quantifier iteration: clear the body's captures (§22.2.2.3
    /// step 4, so a later iteration that doesn't re-capture a group
    /// leaves it undefined) then match the body.
    fn compileIteration(self: *Compiler, body: *const Node) CompileError!void {
        if (groupSlotRange(body)) |rng| try self.emit(.{ .clear = rng });
        try self.compileNode(body);
    }

    /// Compile `body` into a fresh, self-contained sub-program ending
    /// in `match`, for a lookaround. `backward` reverses concatenations
    /// (for lookbehind). Returns an owned instruction slice.
    fn compileSubProgram(self: *Compiler, body: *const Node, backward: bool) CompileError![]Inst {
        const saved = self.insts;
        const saved_dir = self.backward;
        self.insts = .empty;
        self.backward = backward;
        errdefer {
            freeInstContents(self.gpa, self.insts.items);
            self.insts.deinit(self.gpa);
            self.insts = saved;
            self.backward = saved_dir;
        }
        try self.compileNode(body);
        try self.emit(.match);
        const sub = try self.insts.toOwnedSlice(self.gpa);
        self.insts = saved;
        self.backward = saved_dir;
        return sub;
    }

    fn compileBackref(self: *Compiler, name: []const u8) CompileError!void {
        var indices: std.ArrayListUnmanaged(usize) = .empty;
        defer indices.deinit(self.gpa);
        for (self.names, 0..) |maybe, idx| {
            if (maybe) |n| {
                if (std.mem.eql(u8, n, name)) try indices.append(self.gpa, idx);
            }
        }
        self.regular = false;
        switch (indices.items.len) {
            // §22.2.1.1 — a `\k GroupName` that references no existing group
            // is an early error. Only Annex B §B.1.4 (a pattern containing no
            // GroupName at all) rereads `\k` as a literal 'k'; Cynic drops
            // that leniency in every mode, so the SyntaxError stands. The
            // parser already committed to `\k GroupName` on seeing `\k<`.
            0 => return error.SyntaxError,
            1 => try self.emit(.{ .backref = .{ .index = indices.items[0], .fold = self.fold } }),
            else => try self.emit(.{ .backref_dup = .{ .indices = try indices.toOwnedSlice(self.gpa), .fold = self.fold } }),
        }
    }

    /// §22.2.2.7 Atom :: CharacterClass — lower a `/v` ClassSetExpression.
    /// The set algebra runs in a scratch arena (including the resolver's
    /// allocations). A char-only result becomes one ordinary class
    /// instruction; a result that may contain strings becomes an ordered
    /// alternation: each multi-character string (longest first), then the
    /// single-character class, then the empty string if the set has it.
    fn compileClassSet(self: *Compiler, cs: *const Node.ClassSet) CompileError!void {
        var scratch = std.heap.ArenaAllocator.init(self.gpa);
        defer scratch.deinit();
        const a = scratch.allocator();
        const set = try self.evalSet(a, cs);
        try self.emitResolvedSet(a, set.ranges, set.strings);
    }

    /// Lower a resolved set — code-point `ranges` plus multi-code-point
    /// `strings` members — to instructions. A char-only result becomes one
    /// ordinary class instruction; a result that may contain strings
    /// becomes an ordered alternation: each multi-character string (longest
    /// first), then the single-character class, then the empty string if
    /// present (§22.2.2.7). Shared by `/v` ClassSetExpressions
    /// (`compileClassSet`) and atom-position properties of strings
    /// (`\p{RGI_Emoji}`). `a` is a scratch arena owning `ranges`/`strings`;
    /// `compileNode` copies the char values and class ranges it needs into
    /// program (gpa) memory.
    fn emitResolvedSet(
        self: *Compiler,
        a: std.mem.Allocator,
        ranges: []const Node.ClassRange,
        strings: []const []const u21,
    ) CompileError!void {
        // Common case: a flat code-point class (no string members).
        if (strings.len == 0) {
            try self.emitClass(false, ranges, self.fold);
            return;
        }

        // Build a synthetic alternation AST and compile it: this reuses
        // the existing split/jmp lowering, and a concatenation reverses
        // correctly inside a lookbehind via compileNode's `backward`
        // handling. The nodes live in the scratch arena; compileNode
        // copies the char values and class ranges it needs.
        var alts: std.ArrayListUnmanaged(*Node) = .empty;

        // Multi-character strings, longest first (§22.2.2.7).
        const multi = try collectMultiStringsDesc(a, strings);
        for (multi) |s| {
            const seq = try a.alloc(*Node, s.len);
            for (s, 0..) |cp, i| {
                const cn = try a.create(Node);
                cn.* = .{ .char = cp };
                seq[i] = cn;
            }
            const concat = try a.create(Node);
            concat.* = .{ .concat = seq };
            try alts.append(a, concat);
        }

        // The collapsed single-character class, if any.
        if (ranges.len != 0) {
            const cn = try a.create(Node);
            cn.* = .{ .class = .{ .negated = false, .ranges = ranges } };
            try alts.append(a, cn);
        }

        // The empty string, last, if the set contains it (§22.2.2.7).
        if (containsEmptySeq(strings)) {
            const en = try a.create(Node);
            en.* = .empty;
            try alts.append(a, en);
        }

        // `strings` is non-empty, so `alts` has at least one element.
        const root = try a.create(Node);
        root.* = .{ .alternate = alts.items };
        try self.compileNode(root);
    }

    /// Fold the operands of one ClassSetExpression together under its
    /// operator, then apply `^` negation. Recurses into nested classes.
    /// Returns a ResolvedSet (ranges + string members); all allocations
    /// come from the scratch arena `a`.
    fn evalSet(self: *Compiler, a: std.mem.Allocator, cs: *const Node.ClassSet) CompileError!ResolvedSet {
        if (cs.operands.len == 0) {
            // `[]` matches nothing; `[^]` matches every code point.
            if (cs.negated) return .{ .ranges = try charset.complement(a, &.{}), .strings = &.{} };
            return .{ .ranges = &.{}, .strings = &.{} };
        }
        var acc = try self.evalOperand(a, cs.operands[0]);
        for (cs.operands[1..]) |op| {
            const r = try self.evalOperand(a, op);
            acc = switch (cs.op) {
                .union_ => .{
                    .ranges = try charset.unionRanges(a, acc.ranges, r.ranges),
                    .strings = try unionStrings(a, acc.strings, r.strings),
                },
                .intersection => .{
                    .ranges = try charset.intersect(a, acc.ranges, r.ranges),
                    .strings = try intersectStrings(a, acc.strings, r.strings),
                },
                .difference => .{
                    .ranges = try charset.subtract(a, acc.ranges, r.ranges),
                    .strings = try subtractStrings(a, acc.strings, r.strings),
                },
            };
        }
        if (cs.negated) {
            // §22.2.1.1's early error guarantees a negated set's contents
            // cannot contain strings, so `acc.strings` is empty here.
            return .{ .ranges = try charset.complement(a, acc.ranges), .strings = &.{} };
        }
        return acc;
    }

    fn evalOperand(self: *Compiler, a: std.mem.Allocator, op: Node.ClassSet.Operand) CompileError!ResolvedSet {
        return switch (op) {
            .ranges => |r| .{ .ranges = r, .strings = &.{} },
            .nested => |n| try self.evalSet(a, n),
            .prop => |p| blk: {
                // §22.2.1.1 — resolve `\p{}` via the injected resolver;
                // a declined property defers the whole pattern.
                const resolve = self.resolver orelse return error.Unsupported;
                const rp = (try resolve(a, p.key, p.value)) orelse return error.Unsupported;
                if (p.negated) {
                    // `\P{…}` operand. A property of strings can't be
                    // negated (§22.2.1.1, the parser rejects it), so a
                    // negated property contributes only its complemented
                    // ranges — no string members.
                    break :blk .{ .ranges = try charset.complement(a, rp.ranges), .strings = &.{} };
                }
                break :blk .{ .ranges = rp.ranges, .strings = rp.strings };
            },
            // §22.2.1.8 — fold `\q{…}`: single-character strings join the
            // char set; the rest (empty or length ≥ 2) stay as string
            // members. Sequences are deduplicated (set semantics).
            .strings => |ss| try foldStrings(a, ss),
        };
    }
};

/// A resolved `/v` ClassSetExpression: a normalized code-point range set
/// plus its multi-code-point string members. A string member has length
/// 0 (the empty string) or ≥ 2; single-character strings fold into
/// `ranges`. Members of different lengths never coincide, so the union /
/// intersection / difference algebra runs independently on the two
/// halves (§22.2.1.8 / §22.2.2.7).
const ResolvedSet = struct {
    ranges: []const Node.ClassRange,
    strings: []const []const u21,
};

/// Equality of two code-point sequences (string members).
fn seqEql(x: []const u21, y: []const u21) bool {
    if (x.len != y.len) return false;
    for (x, y) |xc, yc| {
        if (xc != yc) return false;
    }
    return true;
}

/// Whether `list` already holds a sequence equal to `s`.
fn containsSeq(list: []const []const u21, s: []const u21) bool {
    for (list) |e| {
        if (seqEql(e, s)) return true;
    }
    return false;
}

fn containsEmptySeq(list: []const []const u21) bool {
    for (list) |s| {
        if (s.len == 0) return true;
    }
    return false;
}

/// Fold a `\q{…}` disjunction into a ResolvedSet: length-1 strings become
/// single-point ranges; the rest stay as deduplicated string members.
fn foldStrings(a: std.mem.Allocator, ss: []const []const u21) std.mem.Allocator.Error!ResolvedSet {
    var ranges: std.ArrayListUnmanaged(Node.ClassRange) = .empty;
    var strs: std.ArrayListUnmanaged([]const u21) = .empty;
    for (ss) |s| {
        if (s.len == 1) {
            try ranges.append(a, .{ .lo = s[0], .hi = s[0] });
        } else if (!containsSeq(strs.items, s)) {
            try strs.append(a, s);
        }
    }
    return .{ .ranges = try charset.normalize(a, ranges.items), .strings = strs.items };
}

/// x ∪ y over string members, deduplicated.
fn unionStrings(a: std.mem.Allocator, x: []const []const u21, y: []const []const u21) std.mem.Allocator.Error![]const []const u21 {
    var out: std.ArrayListUnmanaged([]const u21) = .empty;
    for (x) |s| if (!containsSeq(out.items, s)) try out.append(a, s);
    for (y) |s| if (!containsSeq(out.items, s)) try out.append(a, s);
    return out.items;
}

/// x ∩ y over string members.
fn intersectStrings(a: std.mem.Allocator, x: []const []const u21, y: []const []const u21) std.mem.Allocator.Error![]const []const u21 {
    var out: std.ArrayListUnmanaged([]const u21) = .empty;
    for (x) |s| {
        if (containsSeq(y, s) and !containsSeq(out.items, s)) try out.append(a, s);
    }
    return out.items;
}

/// x ∖ y over string members.
fn subtractStrings(a: std.mem.Allocator, x: []const []const u21, y: []const []const u21) std.mem.Allocator.Error![]const []const u21 {
    var out: std.ArrayListUnmanaged([]const u21) = .empty;
    for (x) |s| {
        if (!containsSeq(y, s) and !containsSeq(out.items, s)) try out.append(a, s);
    }
    return out.items;
}

fn longerFirst(_: void, x: []const u21, y: []const u21) bool {
    return x.len > y.len;
}

/// The length-≥ 2 members of `strings`, sorted longest first (§22.2.2.7
/// matches longer alternatives before shorter ones).
fn collectMultiStringsDesc(a: std.mem.Allocator, strings: []const []const u21) std.mem.Allocator.Error![]const []const u21 {
    var multi: std.ArrayListUnmanaged([]const u21) = .empty;
    for (strings) |s| {
        if (s.len >= 2) try multi.append(a, s);
    }
    std.mem.sort([]const u21, multi.items, {}, longerFirst);
    return multi.items;
}

/// Whether a subtree can match the empty string. A quantifier over a
/// nullable body needs the §22.2.2.3 zero-width progress guard
/// (`compileRepeat` emits `prog_mark`/`prog_check`); a non-nullable body
/// makes every iteration consume input, so no guard is needed.
fn nullable(node: *const Node) bool {
    return switch (node.*) {
        .empty, .anchor_start, .anchor_end, .word_boundary, .backref_name, .backref_index, .lookahead => true,
        .char, .class, .dot, .prop => false,
        // A `/v` class is nullable only when its membership includes the
        // empty string (a `\q{}` empty alternative); a quantifier over
        // such a body would otherwise spin a zero-width loop.
        .class_set => |cs| classSetMayMatchEmpty(cs),
        .noncapture => |b| nullable(b),
        .modifier_group => |mg| nullable(mg.body),
        .capture => |g| nullable(g.body),
        .repeat => |r| r.min == 0 or nullable(r.body),
        .concat => |parts| {
            for (parts) |p| {
                if (!nullable(p)) return false;
            }
            return true;
        },
        .alternate => |alts| {
            for (alts) |a| {
                if (nullable(a)) return true;
            }
            return false;
        },
    };
}

/// Whether a `/v` ClassSetExpression's resolved membership can include
/// the empty string. Computed structurally as a conservative
/// over-approximation (subtraction's right operand — which could remove
/// the empty string — is ignored), so it never reports false for a set
/// that truly matches empty. A negated set is char-only (the §22.2.1.1
/// early error forbids strings under `^`), so it never matches empty.
fn classSetMayMatchEmpty(cs: *const Node.ClassSet) bool {
    if (cs.negated) return false;
    switch (cs.op) {
        .union_ => {
            for (cs.operands) |op| if (operandMayMatchEmpty(op)) return true;
            return false;
        },
        .intersection => {
            if (cs.operands.len == 0) return false;
            for (cs.operands) |op| if (!operandMayMatchEmpty(op)) return false;
            return true;
        },
        .difference => {
            if (cs.operands.len == 0) return false;
            return operandMayMatchEmpty(cs.operands[0]);
        },
    }
}

fn operandMayMatchEmpty(op: Node.ClassSet.Operand) bool {
    return switch (op) {
        .ranges, .prop => false,
        .nested => |n| classSetMayMatchEmpty(n),
        .strings => |ss| blk: {
            for (ss) |s| if (s.len == 0) break :blk true;
            break :blk false;
        },
    };
}

/// Inclusive capture-slot range covered by a subtree, or null if it
/// contains no capturing groups. Used to clear a quantified body's
/// captures between iterations.
fn groupSlotRange(node: *const Node) ?Inst.Range {
    return switch (node.*) {
        .empty, .char, .anchor_start, .anchor_end, .word_boundary, .dot, .class, .prop, .class_set, .backref_name, .backref_index => null,
        .noncapture => |body| groupSlotRange(body),
        .modifier_group => |mg| groupSlotRange(mg.body),
        .lookahead => |la| groupSlotRange(la.body),
        .repeat => |r| groupSlotRange(r.body),
        .capture => |g| blk: {
            var lo = g.index;
            var hi = g.index;
            if (groupSlotRange(g.body)) |inner| {
                // inner is a slot range; convert back to group bounds.
                const inner_lo = inner.from / 2;
                const inner_hi = (inner.to / 2) - 1;
                lo = @min(lo, inner_lo);
                hi = @max(hi, inner_hi);
            }
            break :blk .{ .from = 2 * lo, .to = 2 * hi + 2 };
        },
        .concat => |parts| foldRange(parts),
        .alternate => |alts| foldRange(alts),
    };
}

fn foldRange(children: []const *Node) ?Inst.Range {
    var acc: ?Inst.Range = null;
    for (children) |child| {
        if (groupSlotRange(child)) |r| {
            acc = if (acc) |a|
                .{ .from = @min(a.from, r.from), .to = @max(a.to, r.to) }
            else
                r;
        }
    }
    return acc;
}
