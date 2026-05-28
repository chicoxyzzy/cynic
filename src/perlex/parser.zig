//! Perlex pattern parser — ECMA-262 §22.2.1 Pattern grammar.
//!
//! Produces an AST from a regex source string. The v1 grammar is a
//! deliberately small slice of §22.2.1: literal characters, `^`/`$`
//! assertions, `|` Disjunction, `(…)` / `(?:…)` / `(?<name>…)`
//! groups, `\k<name>` backreferences, and the exact `{n}` quantifier.
//! Anything outside that slice returns `error.Unsupported` so the
//! caller can fall back to the vendored matcher; the engine widens
//! its grammar over time and the fallback shrinks.
//!
//! Duplicate group names are accepted at parse time; §22.2.1.1's
//! early error (the same name may not repeat inside one Alternative)
//! is enforced separately by `checkDuplicateNames`, which is the one
//! piece the vendored matcher can't express.

const std = @import("std");

pub const Node = union(enum) {
    /// Matches the empty string (an empty alternative, e.g. `a|`).
    empty,
    /// A single UTF-16 code unit literal.
    char: u16,
    /// Concatenation of terms (an Alternative).
    concat: []*Node,
    /// `a | b | …` — ordered alternatives of a Disjunction.
    alternate: []*Node,
    /// A capturing group. `index` is the 1-based capture slot.
    capture: Capture,
    /// `(?:…)` — groups without a capture slot.
    noncapture: *Node,
    /// `{min,max}` repetition. v1 emits only exact counts (min==max).
    repeat: Repeat,
    /// `^` Assertion (input start in non-multiline mode).
    anchor_start,
    /// `$` Assertion (input end in non-multiline mode).
    anchor_end,
    /// `\k<name>` — resolved to capture indices by the compiler.
    backref_name: []const u8,

    pub const Capture = struct { index: usize, name: ?[]const u8, body: *Node };
    pub const Repeat = struct { body: *Node, min: usize, max: usize };
};

pub const ParseResult = struct {
    root: *Node,
    /// Number of capturing groups, excluding the whole-match group 0.
    capture_count: usize,
    /// Group name per capture index; length `capture_count + 1`.
    /// Index 0 (the whole match) is always `null`.
    names: []const ?[]const u8,
};

pub const ParseError = error{ Unsupported, SyntaxError, OutOfMemory };

/// Parse `src` into an AST. `a` should be an arena — the AST and the
/// transient name list are allocated from it and freed wholesale by
/// the caller once compilation has copied out what it needs.
pub fn parse(a: std.mem.Allocator, src: []const u8) ParseError!ParseResult {
    var p: Parser = .{
        .a = a,
        .src = src,
        .pos = 0,
        .names = .empty,
    };
    // Index 0 is the implicit whole-match group; it has no name.
    try p.names.append(a, null);

    const root = try p.parseDisjunction();
    if (p.pos != src.len) {
        // A stray `)` or other leftover. Let the vendored matcher
        // render the authoritative verdict rather than guess.
        return error.Unsupported;
    }
    return .{
        .root = root,
        .capture_count = p.names.items.len - 1,
        .names = p.names.items,
    };
}

const Parser = struct {
    a: std.mem.Allocator,
    src: []const u8,
    pos: usize,
    names: std.ArrayListUnmanaged(?[]const u8),

    fn peek(self: *Parser) ?u8 {
        return if (self.pos < self.src.len) self.src[self.pos] else null;
    }

    fn at(self: *Parser, off: usize) ?u8 {
        const i = self.pos + off;
        return if (i < self.src.len) self.src[i] else null;
    }

    fn makeNode(self: *Parser, value: Node) ParseError!*Node {
        const n = try self.a.create(Node);
        n.* = value;
        return n;
    }

    /// Disjunction :: Alternative ( `|` Alternative )*
    fn parseDisjunction(self: *Parser) ParseError!*Node {
        var alts: std.ArrayListUnmanaged(*Node) = .empty;
        try alts.append(self.a, try self.parseAlternative());
        while (self.peek() == '|') {
            self.pos += 1;
            try alts.append(self.a, try self.parseAlternative());
        }
        if (alts.items.len == 1) return alts.items[0];
        return self.makeNode(.{ .alternate = alts.items });
    }

    /// Alternative :: Term*
    fn parseAlternative(self: *Parser) ParseError!*Node {
        var terms: std.ArrayListUnmanaged(*Node) = .empty;
        while (self.peek()) |c| {
            if (c == '|' or c == ')') break;
            try terms.append(self.a, try self.parseTerm());
        }
        if (terms.items.len == 0) return self.makeNode(.empty);
        if (terms.items.len == 1) return terms.items[0];
        return self.makeNode(.{ .concat = terms.items });
    }

    /// Term :: Atom Quantifier?  (Assertions are not quantifiable.)
    fn parseTerm(self: *Parser) ParseError!*Node {
        const atom = try self.parseAtom();
        const c = self.peek() orelse return atom;
        switch (c) {
            '{' => {
                const save = self.pos;
                const rep = self.tryParseBraceQuantifier() catch |e| switch (e) {
                    // A `{` that isn't a well-formed quantifier is a
                    // literal `{` in Annex B; defer that judgement.
                    error.NotAQuantifier => {
                        self.pos = save;
                        return atom;
                    },
                    else => |err| return err,
                };
                return self.applyQuantifier(atom, rep.min, rep.max);
            },
            // Greedy/lazy `* + ?` and the lazy suffix aren't in the v1
            // grammar yet — hand the whole pattern back to the fallback.
            '*', '+', '?' => return error.Unsupported,
            else => return atom,
        }
    }

    fn applyQuantifier(self: *Parser, atom: *Node, min: usize, max: usize) ParseError!*Node {
        switch (atom.*) {
            // §22.2.1 — a quantifier must follow a quantifiable Atom,
            // not an Assertion. Defer the edge case to the fallback.
            .anchor_start, .anchor_end, .empty => return error.Unsupported,
            else => {},
        }
        return self.makeNode(.{ .repeat = .{ .body = atom, .min = min, .max = max } });
    }

    const BraceError = error{NotAQuantifier} || ParseError;
    const Bounds = struct { min: usize, max: usize };

    /// `{n}` only, for now. `{n,}` / `{n,m}` widen the grammar later;
    /// until then they fall back to the vendored matcher.
    fn tryParseBraceQuantifier(self: *Parser) BraceError!Bounds {
        std.debug.assert(self.src[self.pos] == '{');
        var i = self.pos + 1;
        const start = i;
        while (i < self.src.len and self.src[i] >= '0' and self.src[i] <= '9') i += 1;
        if (i == start) return error.NotAQuantifier; // `{` with no digits
        const n = std.fmt.parseInt(usize, self.src[start..i], 10) catch return error.Unsupported;
        if (i < self.src.len and self.src[i] == ',') return error.Unsupported; // `{n,…}` later
        if (i >= self.src.len or self.src[i] != '}') return error.NotAQuantifier;
        i += 1;
        if (i < self.src.len and self.src[i] == '?') return error.Unsupported; // lazy `{n}?`
        self.pos = i;
        return .{ .min = n, .max = n };
    }

    fn parseAtom(self: *Parser) ParseError!*Node {
        const c = self.peek() orelse return error.Unsupported;
        switch (c) {
            '^' => {
                self.pos += 1;
                return self.makeNode(.anchor_start);
            },
            '$' => {
                self.pos += 1;
                return self.makeNode(.anchor_end);
            },
            '(' => return self.parseGroup(),
            '\\' => return self.parseEscape(),
            // Class, dot, and the assorted metacharacters aren't in the
            // v1 grammar — let the fallback own those patterns.
            '[', '.' => return error.Unsupported,
            ')', '*', '+', '?', '{', '}', ']', '|' => return error.Unsupported,
            else => {
                // A plain ASCII literal. Non-ASCII bytes need code-point
                // decoding the v1 engine doesn't do yet → fall back.
                if (c >= 0x80) return error.Unsupported;
                self.pos += 1;
                return self.makeNode(.{ .char = c });
            },
        }
    }

    fn parseGroup(self: *Parser) ParseError!*Node {
        std.debug.assert(self.src[self.pos] == '(');
        if (self.at(1) == '?') {
            const k = self.at(2) orelse return error.Unsupported;
            switch (k) {
                ':' => {
                    self.pos += 3;
                    const body = try self.parseDisjunction();
                    try self.expect(')');
                    return self.makeNode(.{ .noncapture = body });
                },
                '<' => {
                    // `(?<=` / `(?<!` are lookbehind — not yet supported.
                    const k3 = self.at(3) orelse return error.Unsupported;
                    if (k3 == '=' or k3 == '!') return error.Unsupported;
                    return self.parseNamedCapture();
                },
                // `(?=` / `(?!` lookahead and `(?flags:…)` modifiers
                // are future grammar.
                else => return error.Unsupported,
            }
        }
        // Plain capturing group.
        self.pos += 1;
        const index = self.names.items.len;
        try self.names.append(self.a, null);
        const body = try self.parseDisjunction();
        try self.expect(')');
        return self.makeNode(.{ .capture = .{ .index = index, .name = null, .body = body } });
    }

    fn parseNamedCapture(self: *Parser) ParseError!*Node {
        // At `(?<`. Capture index is assigned before the body so nested
        // groups receive higher indices, matching source order.
        self.pos += 3;
        const name = try self.parseGroupName();
        const index = self.names.items.len;
        try self.names.append(self.a, name);
        const body = try self.parseDisjunction();
        try self.expect(')');
        return self.makeNode(.{ .capture = .{ .index = index, .name = name, .body = body } });
    }

    /// A v1 group name is a run of ASCII identifier characters ended by
    /// `>`. `\u` escapes and non-ASCII identifier code points exist in
    /// the full grammar; patterns using them fall back so name equality
    /// stays byte-exact here.
    fn parseGroupName(self: *Parser) ParseError![]const u8 {
        const start = self.pos;
        while (self.peek()) |c| {
            if (c == '>') break;
            if (c >= 0x80 or c == '\\') return error.Unsupported;
            if (!(std.ascii.isAlphanumeric(c) or c == '_' or c == '$')) return error.Unsupported;
            self.pos += 1;
        }
        if (self.peek() != '>') return error.SyntaxError;
        if (self.pos == start) return error.SyntaxError; // empty name
        const name = self.src[start..self.pos];
        self.pos += 1; // consume `>`
        return name;
    }

    fn parseEscape(self: *Parser) ParseError!*Node {
        std.debug.assert(self.src[self.pos] == '\\');
        const k = self.at(1) orelse return error.SyntaxError; // trailing `\`
        if (k == 'k') {
            if (self.at(2) != '<') return error.Unsupported;
            self.pos += 3;
            const name = try self.parseGroupName();
            return self.makeNode(.{ .backref_name = name });
        }
        // Character-class escapes (`\d` `\w` `\b` …), numeric
        // backreferences, and escaped literals are future grammar.
        return error.Unsupported;
    }

    fn expect(self: *Parser, c: u8) ParseError!void {
        if (self.peek() != c) return error.SyntaxError;
        self.pos += 1;
    }
};

/// §22.2.1.1 early error: a GroupName may appear more than once only
/// in mutually exclusive alternatives of a Disjunction. Reused within
/// a single Alternative (a concatenation) it is a SyntaxError.
///
/// The walk returns the set of names declared in a subtree. A
/// concatenation takes the *disjoint* union of its parts (a collision
/// is the error); a disjunction takes the plain union (collisions
/// across alternatives are allowed); a capturing group's own name is
/// disjoint with the names in its body.
pub fn checkDuplicateNames(a: std.mem.Allocator, root: *const Node) error{ SyntaxError, OutOfMemory }!void {
    var names = try collectNames(a, root);
    names.deinit(a);
}

const NameSet = std.ArrayListUnmanaged([]const u8);

fn setContains(set: *const NameSet, name: []const u8) bool {
    for (set.items) |n| {
        if (std.mem.eql(u8, n, name)) return true;
    }
    return false;
}

/// Add `name`, erroring if already present (a same-Alternative dup).
fn addDisjoint(a: std.mem.Allocator, set: *NameSet, name: []const u8) error{ SyntaxError, OutOfMemory }!void {
    if (setContains(set, name)) return error.SyntaxError;
    try set.append(a, name);
}

fn collectNames(a: std.mem.Allocator, node: *const Node) error{ SyntaxError, OutOfMemory }!NameSet {
    var set: NameSet = .empty;
    errdefer set.deinit(a);
    switch (node.*) {
        .empty, .char, .anchor_start, .anchor_end, .backref_name => {},
        .noncapture => |body| {
            set.deinit(a);
            return try collectNames(a, body);
        },
        .repeat => |r| {
            set.deinit(a);
            return try collectNames(a, r.body);
        },
        .capture => |g| {
            var body_names = try collectNames(a, g.body);
            defer body_names.deinit(a);
            for (body_names.items) |n| try set.append(a, n);
            if (g.name) |name| {
                // `(?<x>(?<x>…))` — the group's name is in sequence
                // with its body, so a collision there is an error.
                try addDisjoint(a, &set, name);
            }
        },
        .concat => |parts| {
            for (parts) |part| {
                var part_names = try collectNames(a, part);
                defer part_names.deinit(a);
                for (part_names.items) |n| try addDisjoint(a, &set, n);
            }
        },
        .alternate => |alts| {
            for (alts) |alt| {
                var alt_names = try collectNames(a, alt);
                defer alt_names.deinit(a);
                // Plain union — duplicates across alternatives are fine.
                for (alt_names.items) |n| {
                    if (!setContains(&set, n)) try set.append(a, n);
                }
            }
        },
    }
    return set;
}
