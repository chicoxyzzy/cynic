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
    /// `\b` (negated == false) / `\B` (negated == true) word boundary.
    word_boundary: bool,
    /// `.` — resolved by the compiler to a class that excludes line
    /// terminators (default) or matches any code unit (dotall `s`).
    dot,
    /// A single-code-unit class: `[…]`, `\d`/`\w`/`\s` and their
    /// negated forms. Membership is "code unit lies in some range",
    /// XOR `negated`.
    class: Class,
    /// `\k<name>` — resolved to capture indices by the compiler.
    backref_name: []const u8,
    /// `\1`..`\99…` — a numeric backreference, resolved at compile.
    backref_index: usize,

    pub const Capture = struct { index: usize, name: ?[]const u8, body: *Node };
    pub const Repeat = struct { body: *Node, min: usize, max: usize, greedy: bool };
    pub const ClassRange = struct { lo: u21, hi: u21 };
    pub const Class = struct { negated: bool, ranges: []const ClassRange };
};

/// `Repeat.max` sentinel for an unbounded upper bound (`*`, `+`, `{n,}`).
pub const unbounded_max = std.math.maxInt(usize);

// Built-in class range sets (§22.2.1). Static lifetime — the compiler
// copies them into the program, so the AST may point at consts.
const digit_ranges = [_]Node.ClassRange{.{ .lo = '0', .hi = '9' }};
const word_ranges = [_]Node.ClassRange{
    .{ .lo = '0', .hi = '9' },
    .{ .lo = 'A', .hi = 'Z' },
    .{ .lo = '_', .hi = '_' },
    .{ .lo = 'a', .hi = 'z' },
};
// §22.2.1 CharacterClassEscape `\s` = WhiteSpace ∪ LineTerminator.
const space_ranges = [_]Node.ClassRange{
    .{ .lo = 0x09, .hi = 0x0D }, // \t \n \v \f \r
    .{ .lo = ' ', .hi = ' ' },
    .{ .lo = 0xA0, .hi = 0xA0 },
    .{ .lo = 0x1680, .hi = 0x1680 },
    .{ .lo = 0x2000, .hi = 0x200A },
    .{ .lo = 0x2028, .hi = 0x2029 },
    .{ .lo = 0x202F, .hi = 0x202F },
    .{ .lo = 0x205F, .hi = 0x205F },
    .{ .lo = 0x3000, .hi = 0x3000 },
    .{ .lo = 0xFEFF, .hi = 0xFEFF },
};
// `.` in non-dotall mode matches any code unit except LineTerminator.
pub const line_terminator_ranges = [_]Node.ClassRange{
    .{ .lo = 0x0A, .hi = 0x0A },
    .{ .lo = 0x0D, .hi = 0x0D },
    .{ .lo = 0x2028, .hi = 0x2029 },
};

pub const ParseResult = struct {
    root: *Node,
    /// Number of capturing groups, excluding the whole-match group 0.
    capture_count: usize,
    /// Group name per capture index; length `capture_count + 1`.
    /// Index 0 (the whole match) is always `null`.
    names: []const ?[]const u8,
    /// True if the pattern contains an explicit non-ASCII code unit
    /// (a `\u`/`\x` escape ≥ 0x80). Under the `i` flag such a unit can
    /// case-fold to another non-ASCII unit, which the ASCII-only fold
    /// doesn't model — the caller declines `i` patterns with this set.
    non_ascii: bool,
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
        .non_ascii = p.non_ascii,
    };
}

const Parser = struct {
    a: std.mem.Allocator,
    src: []const u8,
    pos: usize,
    names: std.ArrayListUnmanaged(?[]const u8),
    non_ascii: bool = false,

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
        return self.maybeQuantify(atom);
    }

    fn maybeQuantify(self: *Parser, atom: *Node) ParseError!*Node {
        const c = self.peek() orelse return atom;
        var min: usize = 0;
        var max: usize = 0;
        switch (c) {
            '*' => {
                self.pos += 1;
                min = 0;
                max = unbounded_max;
            },
            '+' => {
                self.pos += 1;
                min = 1;
                max = unbounded_max;
            },
            '?' => {
                self.pos += 1;
                min = 0;
                max = 1;
            },
            '{' => {
                const save = self.pos;
                const b = self.parseBraceQuantifier() catch |e| switch (e) {
                    // A `{` that isn't a well-formed quantifier is a
                    // literal `{` in Annex B; defer that judgement.
                    error.NotAQuantifier => {
                        self.pos = save;
                        return atom;
                    },
                    else => |err| return err,
                };
                min = b.min;
                max = b.max;
            },
            else => return atom,
        }
        // §22.2.1 lazy marker — a trailing `?` makes the quantifier
        // non-greedy (try the shorter match first).
        var greedy = true;
        if (self.peek() == '?') {
            greedy = false;
            self.pos += 1;
        }
        return self.applyQuantifier(atom, min, max, greedy);
    }

    fn applyQuantifier(self: *Parser, atom: *Node, min: usize, max: usize, greedy: bool) ParseError!*Node {
        switch (atom.*) {
            // §22.2.1 — a quantifier must follow a quantifiable Atom,
            // not an Assertion. Defer the edge case to the fallback.
            .anchor_start, .anchor_end, .empty, .word_boundary => return error.Unsupported,
            else => {},
        }
        return self.makeNode(.{ .repeat = .{ .body = atom, .min = min, .max = max, .greedy = greedy } });
    }

    const BraceError = error{NotAQuantifier} || ParseError;
    const Bounds = struct { min: usize, max: usize };

    /// `{n}`, `{n,}`, `{n,m}`. `NotAQuantifier` signals a `{` that is a
    /// literal (Annex B), so the caller can treat it as a normal atom.
    fn parseBraceQuantifier(self: *Parser) BraceError!Bounds {
        std.debug.assert(self.src[self.pos] == '{');
        var i = self.pos + 1;
        const lo_start = i;
        while (i < self.src.len and self.src[i] >= '0' and self.src[i] <= '9') i += 1;
        if (i == lo_start) return error.NotAQuantifier; // `{` then non-digit
        const min = std.fmt.parseInt(usize, self.src[lo_start..i], 10) catch return error.Unsupported;
        var max: usize = min;
        if (i < self.src.len and self.src[i] == ',') {
            i += 1;
            const hi_start = i;
            while (i < self.src.len and self.src[i] >= '0' and self.src[i] <= '9') i += 1;
            if (i == hi_start) {
                max = unbounded_max; // `{n,}`
            } else {
                max = std.fmt.parseInt(usize, self.src[hi_start..i], 10) catch return error.Unsupported;
                if (max < min) return error.SyntaxError; // `{3,1}` is invalid
            }
        }
        if (i >= self.src.len or self.src[i] != '}') return error.NotAQuantifier;
        i += 1;
        self.pos = i;
        return .{ .min = min, .max = max };
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
            '.' => {
                self.pos += 1;
                return self.makeNode(.dot);
            },
            '[' => return self.parseCharClass(),
            // Bare metacharacters in atom position aren't valid here;
            // defer the authoritative verdict to the fallback matcher.
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
        switch (k) {
            'k' => {
                if (self.at(2) != '<') return error.Unsupported;
                self.pos += 3;
                const name = try self.parseGroupName();
                return self.makeNode(.{ .backref_name = name });
            },
            'd' => return self.classAtom(false, &digit_ranges),
            'D' => return self.classAtom(true, &digit_ranges),
            'w' => return self.classAtom(false, &word_ranges),
            'W' => return self.classAtom(true, &word_ranges),
            's' => return self.classAtom(false, &space_ranges),
            'S' => return self.classAtom(true, &space_ranges),
            'b' => {
                self.pos += 2;
                return self.makeNode(.{ .word_boundary = false });
            },
            'B' => {
                self.pos += 2;
                return self.makeNode(.{ .word_boundary = true });
            },
            '1'...'9' => {
                // §22.2.1 DecimalEscape — a numeric backreference. Parse
                // all digits greedily; the compiler decides whether the
                // index is in range (else it's an Annex B octal escape,
                // deferred to the fallback).
                var i = self.pos + 1;
                while (i < self.src.len and self.src[i] >= '0' and self.src[i] <= '9') i += 1;
                const n = std.fmt.parseInt(usize, self.src[self.pos + 1 .. i], 10) catch return error.Unsupported;
                self.pos = i;
                return self.makeNode(.{ .backref_index = n });
            },
            else => return self.makeNode(.{ .char = try self.parseEscapedChar() }),
        }
    }

    fn classAtom(self: *Parser, negated: bool, ranges: []const Node.ClassRange) ParseError!*Node {
        self.pos += 2; // consume `\` and the class letter
        return self.makeNode(.{ .class = .{ .negated = negated, .ranges = ranges } });
    }

    /// Parse a single-character escape at `\` and return the code unit
    /// it denotes. Class escapes (`\d` …) and `\b`/`\B` are handled by
    /// the callers; this covers control, hex, unicode (BMP), and
    /// identity escapes. Forms outside that set fall back.
    fn parseEscapedChar(self: *Parser) ParseError!u16 {
        std.debug.assert(self.src[self.pos] == '\\');
        const k = self.at(1) orelse return error.SyntaxError;
        switch (k) {
            'n' => return self.takeEscaped(2, 0x0A),
            'r' => return self.takeEscaped(2, 0x0D),
            't' => return self.takeEscaped(2, 0x09),
            'f' => return self.takeEscaped(2, 0x0C),
            'v' => return self.takeEscaped(2, 0x0B),
            '0' => {
                // `\0` is NUL only when not the start of a legacy octal
                // / decimal escape; defer those to the fallback.
                if (self.at(2)) |d| {
                    if (d >= '0' and d <= '9') return error.Unsupported;
                }
                return self.takeEscaped(2, 0x00);
            },
            'x' => {
                const hi = hexVal(self.at(2) orelse return error.Unsupported) orelse return error.Unsupported;
                const lo = hexVal(self.at(3) orelse return error.Unsupported) orelse return error.Unsupported;
                const v = @as(u16, hi) * 16 + lo;
                if (v >= 0x80) self.non_ascii = true;
                return self.takeEscaped(4, v);
            },
            'u' => {
                // `\u{…}` is UnicodeMode-only; Perlex declines `u`/`v`.
                if (self.at(2) == '{') return error.Unsupported;
                var v: u16 = 0;
                var i: usize = 2;
                while (i < 6) : (i += 1) {
                    const d = hexVal(self.at(i) orelse return error.Unsupported) orelse return error.Unsupported;
                    v = v *% 16 +% @as(u16, d);
                }
                if (v >= 0x80) self.non_ascii = true;
                return self.takeEscaped(6, v);
            },
            else => {
                // IdentityEscape: `\` before a syntax character (or `/`)
                // is that literal. Other escapes (`\c…`, `\p{…}`, numeric
                // backrefs, arbitrary-letter Annex B identity escapes)
                // fall back.
                if (isSyntaxChar(k)) return self.takeEscaped(2, k);
                return error.Unsupported;
            },
        }
    }

    fn takeEscaped(self: *Parser, advance: usize, value: u16) u16 {
        self.pos += advance;
        return value;
    }

    /// `[ClassRanges]` / `[^ClassRanges]` → a single class node.
    fn parseCharClass(self: *Parser) ParseError!*Node {
        std.debug.assert(self.src[self.pos] == '[');
        self.pos += 1;
        var negated = false;
        if (self.peek() == '^') {
            negated = true;
            self.pos += 1;
        }
        var ranges: std.ArrayListUnmanaged(Node.ClassRange) = .empty;
        while (true) {
            const c = self.peek() orelse return error.SyntaxError; // unterminated
            if (c == ']') {
                self.pos += 1;
                break;
            }
            switch (try self.parseClassMember(&ranges)) {
                .class_added => {},
                .ch => |lo| {
                    if (self.peek() == '-' and self.at(1) != null and self.at(1).? != ']') {
                        self.pos += 1; // consume `-`
                        switch (try self.parseClassMember(&ranges)) {
                            .ch => |hi| {
                                if (hi < lo) return error.SyntaxError; // reversed range
                                try ranges.append(self.a, .{ .lo = lo, .hi = hi });
                            },
                            // `a-\d`: the `-` is a literal, not a range.
                            .class_added => {
                                try ranges.append(self.a, .{ .lo = lo, .hi = lo });
                                try ranges.append(self.a, .{ .lo = '-', .hi = '-' });
                            },
                        }
                    } else {
                        try ranges.append(self.a, .{ .lo = lo, .hi = lo });
                    }
                },
            }
        }
        return self.makeNode(.{ .class = .{ .negated = negated, .ranges = ranges.items } });
    }

    const ClassMember = union(enum) { ch: u21, class_added };

    fn parseClassMember(self: *Parser, ranges: *std.ArrayListUnmanaged(Node.ClassRange)) ParseError!ClassMember {
        const c = self.peek() orelse return error.SyntaxError;
        if (c == '\\') {
            const k = self.at(1) orelse return error.SyntaxError;
            switch (k) {
                'd' => {
                    self.pos += 2;
                    try appendRanges(self.a, ranges, &digit_ranges);
                    return .class_added;
                },
                'w' => {
                    self.pos += 2;
                    try appendRanges(self.a, ranges, &word_ranges);
                    return .class_added;
                },
                's' => {
                    self.pos += 2;
                    try appendRanges(self.a, ranges, &space_ranges);
                    return .class_added;
                },
                // Negated escapes inside a class need set complement;
                // defer to the fallback for now.
                'D', 'W', 'S' => return error.Unsupported,
                // `\b` inside a class is backspace, not a word boundary.
                'b' => {
                    self.pos += 2;
                    return .{ .ch = 0x08 };
                },
                else => return .{ .ch = try self.parseEscapedChar() },
            }
        }
        if (c >= 0x80) return error.Unsupported;
        self.pos += 1;
        return .{ .ch = c };
    }

    fn expect(self: *Parser, c: u8) ParseError!void {
        if (self.peek() != c) return error.SyntaxError;
        self.pos += 1;
    }
};

fn hexVal(c: u8) ?u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => null,
    };
}

fn isSyntaxChar(c: u8) bool {
    return switch (c) {
        '^', '$', '\\', '.', '*', '+', '?', '(', ')', '[', ']', '{', '}', '|', '/' => true,
        else => false,
    };
}

fn appendRanges(a: std.mem.Allocator, dst: *std.ArrayListUnmanaged(Node.ClassRange), src: []const Node.ClassRange) error{OutOfMemory}!void {
    for (src) |r| try dst.append(a, r);
}

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
        .empty, .char, .anchor_start, .anchor_end, .word_boundary, .dot, .class, .backref_name, .backref_index => {},
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
