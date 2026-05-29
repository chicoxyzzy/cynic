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

/// Upper bound on capturing groups (including the whole match) the v1
/// VM handles, set by the fixed per-`split` snapshot buffer. Patterns
/// with more groups fall back to the vendored matcher.
pub const max_groups = 64;

/// Bounded quantifiers are lowered by inlining the body, so a huge
/// bound (`a{0,4294967295}`) would emit billions of instructions.
/// Patterns whose mandatory or optional iteration count exceeds this
/// fall back to the vendored matcher's counted-loop lowering.
pub const max_repeat_expand = 1024;

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

/// Resolves a `\p{…}` property escape to code-point ranges. Returns
/// gpa-owned ranges (the Program takes ownership and frees them like any
/// class) or null to decline the whole pattern to the fallback matcher.
/// `key` is the `Name` of `\p{Name=Value}`, or null for the lone
/// `\p{NameOrValue}` form. Injected so Perlex itself carries no Unicode
/// data — the bridge backs it with Cynic's generated tables.
pub const PropertyResolver = *const fn (
    gpa: std.mem.Allocator,
    key: ?[]const u8,
    value: []const u8,
) std.mem.Allocator.Error!?[]const parser.Node.ClassRange;

pub const Inst = union(enum) {
    /// Match one literal — a UTF-16 code unit, or a code point up to
    /// U+10FFFF under `/u` — then advance.
    char: u21,
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
    /// `^` — succeed only at input start (non-multiline mode).
    assert_start,
    /// `$` — succeed only at input end (non-multiline mode).
    assert_end,
    /// Match the text previously captured by group `n` (or the empty
    /// string if that group did not participate).
    backref: usize,
    /// `\k<name>` where the name is duplicated: match the text of
    /// whichever listed group participated (§22.2.2 with duplicate
    /// group names). At most one can be set, per the early error.
    backref_dup: []const usize,
    /// Match one code unit against a class (`.`, `[…]`, `\d`/`\w`/`\s`
    /// and negated forms), advancing on success. `ranges` is owned by
    /// the program.
    class: parser.Node.Class,
    /// `\b` (false) / `\B` (true) word-boundary assertion.
    word_boundary: bool,
    /// `(?=…)` / `(?!…)` — run `sub` (a self-contained program ending
    /// in `match`) at the current position without consuming input;
    /// `negative` inverts success.
    lookahead: LookInst,

    pub const Split = struct { a: usize, b: usize };
    pub const Range = struct { from: usize, to: usize };
    pub const LookInst = struct { negative: bool, behind: bool, sub: []const Inst };
};

/// Free the owned allocations inside each instruction (class ranges,
/// dup-backref index lists, nested lookahead sub-programs).
fn freeInstContents(gpa: std.mem.Allocator, insts: []const Inst) void {
    for (insts) |inst| switch (inst) {
        .backref_dup => |idxs| gpa.free(idxs),
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
    /// Capturing groups including the whole match (group 0); capture
    /// slot array length is `2 * group_count`.
    group_count: usize,
    /// Group name per group index; length `group_count`, index 0 null.
    names: []const ?[]const u8,
    flags: Flags,
    /// True when the pattern is "regular" — no backreferences (and, in
    /// future, no lookaround). Such patterns admit a linear-time
    /// Thompson/PikeVM strategy; the backtracking VM is only required
    /// when this is false. Unused until that engine lands, but the
    /// classification is the seam it plugs into.
    is_regular: bool,
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

    fn deinitPartial(self: *Compiler) void {
        freeInstContents(self.gpa, self.insts.items);
        self.insts.deinit(self.gpa);
    }

    fn emit(self: *Compiler, inst: Inst) CompileError!void {
        try self.insts.append(self.gpa, inst);
    }

    fn here(self: *Compiler) usize {
        return self.insts.items.len;
    }

    fn compileNode(self: *Compiler, node: *const Node) CompileError!void {
        switch (node.*) {
            .empty => {},
            .char => |ch| try self.emit(.{ .char = ch }),
            .anchor_start => try self.emit(.assert_start),
            .anchor_end => try self.emit(.assert_end),
            .word_boundary => |neg| try self.emit(.{ .word_boundary = neg }),
            .dot => {
                // `.` excludes line terminators unless dotall (`s`), in
                // which case it matches any code unit (negated empty
                // class).
                const src_ranges: []const parser.Node.ClassRange =
                    if (self.dot_all) &[_]parser.Node.ClassRange{} else &parser.line_terminator_ranges;
                const ranges = try self.gpa.dupe(parser.Node.ClassRange, src_ranges);
                self.emit(.{ .class = .{ .negated = true, .ranges = ranges } }) catch |e| {
                    self.gpa.free(ranges);
                    return e;
                };
            },
            .class => |cls| {
                // Copy the ranges into program-owned memory (the AST is
                // arena/const and freed after compilation).
                const ranges = try self.gpa.dupe(parser.Node.ClassRange, cls.ranges);
                self.emit(.{ .class = .{ .negated = cls.negated, .ranges = ranges } }) catch |e| {
                    self.gpa.free(ranges);
                    return e;
                };
            },
            .prop => |p| {
                // §22.2.1.1 — resolve the property to ranges via the
                // injected resolver; declined properties (unknown, or valid
                // but unsupported here, e.g. Script) defer the whole pattern
                // to the fallback. Lowers to an ordinary class instruction.
                const resolve = self.resolver orelse return error.Unsupported;
                const ranges = (try resolve(self.gpa, p.key, p.value)) orelse return error.Unsupported;
                // `ranges` is gpa-owned; transfer ownership to the class
                // instruction (freed by Program.deinit like any class).
                self.emit(.{ .class = .{ .negated = p.negated, .ranges = ranges } }) catch |e| {
                    self.gpa.free(ranges);
                    return e;
                };
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
                try self.emit(.{ .save = 2 * g.index });
                try self.compileNode(g.body);
                try self.emit(.{ .save = 2 * g.index + 1 });
            },
            .alternate => |alts| try self.compileAlternation(alts),
            .repeat => |r| try self.compileRepeat(r),
            .lookahead => |la| {
                // Lookbehind matches backward and (v1) only supports
                // capture-free, assertion-free bodies; richer bodies
                // defer to the fallback. Lookahead has no restriction.
                if (la.behind and !lookbehindBodyOk(la.body)) return error.Unsupported;
                const sub = try self.compileSubProgram(la.body, la.behind);
                self.emit(.{ .lookahead = .{ .negative = la.negative, .behind = la.behind, .sub = sub } }) catch |e| {
                    freeInsts(self.gpa, sub);
                    return e;
                };
            },
            .backref_name => |name| try self.compileBackref(name),
            .backref_index => |n| {
                // In range → a backreference; out of range is an Annex B
                // octal/identity escape the v1 grammar doesn't model.
                const total = self.names.len - 1; // capturing groups, excl group 0
                if (n == 0 or n > total) return error.Unsupported;
                self.regular = false;
                try self.emit(.{ .backref = n });
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
        // A quantified body that can match the empty string risks a
        // zero-width infinite loop; the §22.2.2.3 progress guard for
        // that case isn't built yet, so defer such patterns to the
        // fallback. With a non-nullable body every iteration consumes
        // at least one code unit, so the loops below terminate.
        if (nullable(r.body)) return error.Unsupported;

        // Inline expansion would blow up for huge bounds; defer those.
        if (r.min > max_repeat_expand) return error.Unsupported;
        if (r.max != parser.unbounded_max and r.max - r.min > max_repeat_expand) return error.Unsupported;

        // `min` mandatory iterations.
        var i: usize = 0;
        while (i < r.min) : (i += 1) try self.compileIteration(r.body);

        if (r.max == parser.unbounded_max) {
            // Greedy/lazy star over the body.
            const loop = self.here();
            const split_idx = self.here();
            try self.emit(.{ .split = .{ .a = 0, .b = 0 } });
            const body_start = self.here();
            try self.compileIteration(r.body);
            try self.emit(.{ .jmp = loop });
            const exit = self.here();
            self.insts.items[split_idx].split = if (r.greedy)
                .{ .a = body_start, .b = exit }
            else
                .{ .a = exit, .b = body_start };
        } else {
            // `max - min` optional, each-skippable iterations.
            var splits: std.ArrayListUnmanaged(usize) = .empty;
            defer splits.deinit(self.gpa);
            var k = r.min;
            while (k < r.max) : (k += 1) {
                try splits.append(self.gpa, self.here());
                try self.emit(.{ .split = .{ .a = 0, .b = 0 } });
                try self.compileIteration(r.body);
            }
            const exit = self.here();
            for (splits.items) |s| {
                const body_start = s + 1;
                self.insts.items[s].split = if (r.greedy)
                    .{ .a = body_start, .b = exit }
                else
                    .{ .a = exit, .b = body_start };
            }
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
            // An unresolved `\k<name>` carries Annex-B-tolerant
            // semantics the v1 grammar doesn't model — defer.
            0 => return error.Unsupported,
            1 => try self.emit(.{ .backref = indices.items[0] }),
            else => try self.emit(.{ .backref_dup = try indices.toOwnedSlice(self.gpa) }),
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

        // Common case: a flat code-point class (no string members).
        if (set.strings.len == 0) {
            const ranges = try self.gpa.dupe(Node.ClassRange, set.ranges);
            self.emit(.{ .class = .{ .negated = false, .ranges = ranges } }) catch |e| {
                self.gpa.free(ranges);
                return e;
            };
            return;
        }

        // Build a synthetic alternation AST and compile it: this reuses
        // the existing split/jmp lowering, and a concatenation reverses
        // correctly inside a lookbehind via compileNode's `backward`
        // handling. The nodes live in the scratch arena; compileNode
        // copies the char values and class ranges it needs.
        var alts: std.ArrayListUnmanaged(*Node) = .empty;

        // Multi-character strings, longest first (§22.2.2.7).
        const multi = try collectMultiStringsDesc(a, set.strings);
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
        if (set.ranges.len != 0) {
            const cn = try a.create(Node);
            cn.* = .{ .class = .{ .negated = false, .ranges = set.ranges } };
            try alts.append(a, cn);
        }

        // The empty string, last, if the set contains it (§22.2.2.7).
        if (containsEmptySeq(set.strings)) {
            const en = try a.create(Node);
            en.* = .empty;
            try alts.append(a, en);
        }

        // `set.strings` is non-empty, so `alts` has at least one element.
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
                // a declined property defers the whole pattern. The B1
                // resolver yields only ranges (no properties of strings).
                const resolve = self.resolver orelse return error.Unsupported;
                const rr = (try resolve(a, p.key, p.value)) orelse return error.Unsupported;
                const ranges = if (p.negated) try charset.complement(a, rr) else rr;
                break :blk .{ .ranges = ranges, .strings = &.{} };
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

/// A lookbehind body the v1 backward matcher handles: no capturing
/// groups (which would need reversed capture saves), no
/// backreferences, and no nested assertions. Richer bodies defer to
/// the fallback.
fn lookbehindBodyOk(node: *const Node) bool {
    return switch (node.*) {
        .capture, .backref_name, .backref_index, .lookahead => false,
        .empty, .char, .class, .dot, .prop, .class_set, .anchor_start, .anchor_end, .word_boundary => true,
        .noncapture => |b| lookbehindBodyOk(b),
        .repeat => |r| lookbehindBodyOk(r.body),
        .concat => |parts| {
            for (parts) |p| {
                if (!lookbehindBodyOk(p)) return false;
            }
            return true;
        },
        .alternate => |alts| {
            for (alts) |a| {
                if (!lookbehindBodyOk(a)) return false;
            }
            return true;
        },
    };
}

/// Whether a subtree can match the empty string. A quantifier over a
/// nullable body needs the §22.2.2.3 zero-width progress guard, which
/// isn't built yet — such bodies are declined to the fallback.
fn nullable(node: *const Node) bool {
    return switch (node.*) {
        .empty, .anchor_start, .anchor_end, .word_boundary, .backref_name, .backref_index, .lookahead => true,
        .char, .class, .dot, .prop => false,
        // A `/v` class is nullable only when its membership includes the
        // empty string (a `\q{}` empty alternative); a quantifier over
        // such a body would otherwise spin a zero-width loop.
        .class_set => |cs| classSetMayMatchEmpty(cs),
        .noncapture => |b| nullable(b),
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
