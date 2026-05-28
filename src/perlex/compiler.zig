//! Perlex compiler — lowers the §22.2.1 AST to a flat instruction
//! program for the backtracking VM. The instruction set follows the
//! NFA-program style (Thompson/Pike, as adapted for backtracking by
//! Cox, "Regular Expression Matching: the Virtual Machine Approach"),
//! extended with capture, capture-clear, anchor, and backreference
//! ops so it can express the backtracking semantics ECMA-262 §22.2.2
//! requires (which a pure NFA can't, because of backreferences).

const std = @import("std");
const parser = @import("parser.zig");
const Node = parser.Node;

/// Upper bound on capturing groups (including the whole match) the v1
/// VM handles, set by the fixed per-`split` snapshot buffer. Patterns
/// with more groups fall back to the vendored matcher.
pub const max_groups = 64;

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

pub const Inst = union(enum) {
    /// Match one UTF-16 code unit equal to the operand, then advance.
    char: u16,
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

    pub const Split = struct { a: usize, b: usize };
    pub const Range = struct { from: usize, to: usize };
};

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
        for (self.insts) |inst| {
            if (inst == .backref_dup) self.gpa.free(inst.backref_dup);
        }
        self.gpa.free(self.insts);
        for (self.names) |maybe| {
            if (maybe) |name| self.gpa.free(name);
        }
        self.gpa.free(self.names);
    }
};

pub const CompileError = error{ Unsupported, SyntaxError, OutOfMemory };

pub fn compile(gpa: std.mem.Allocator, result: parser.ParseResult, flags: Flags) CompileError!Program {
    if (result.capture_count + 1 > max_groups) return error.Unsupported;
    var c: Compiler = .{
        .gpa = gpa,
        .names = result.names,
        .insts = .empty,
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
    /// Cleared to false the moment a backreference is emitted — the
    /// pattern is then no longer in the regular subset.
    regular: bool = true,

    fn deinitPartial(self: *Compiler) void {
        for (self.insts.items) |inst| {
            if (inst == .backref_dup) self.gpa.free(inst.backref_dup);
        }
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
            .concat => |parts| for (parts) |part| try self.compileNode(part),
            .noncapture => |body| try self.compileNode(body),
            .capture => |g| {
                try self.emit(.{ .save = 2 * g.index });
                try self.compileNode(g.body);
                try self.emit(.{ .save = 2 * g.index + 1 });
            },
            .alternate => |alts| try self.compileAlternation(alts),
            .repeat => |r| try self.compileRepeat(r),
            .backref_name => |name| try self.compileBackref(name),
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
        // v1 lowers only the exact `{n}` form (min == max), as `n`
        // inline copies. Each copy clears the body's capture slots
        // first so a later iteration that doesn't re-capture a group
        // leaves it undefined (§22.2.2.3 step 4) — the behaviour the
        // duplicate-named-group "last iteration wins" fixtures probe.
        std.debug.assert(r.min == r.max);
        const range = groupSlotRange(r.body);
        var i: usize = 0;
        while (i < r.min) : (i += 1) {
            if (range) |rng| try self.emit(.{ .clear = rng });
            try self.compileNode(r.body);
        }
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
};

/// Inclusive capture-slot range covered by a subtree, or null if it
/// contains no capturing groups. Used to clear a quantified body's
/// captures between iterations.
fn groupSlotRange(node: *const Node) ?Inst.Range {
    return switch (node.*) {
        .empty, .char, .anchor_start, .anchor_end, .backref_name => null,
        .noncapture => |body| groupSlotRange(body),
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
