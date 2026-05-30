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
const charset = @import("charset.zig");
const idents = @import("../unicode/idents.zig");

pub const Node = union(enum) {
    /// Matches the empty string (an empty alternative, e.g. `a|`).
    empty,
    /// A single literal: a UTF-16 code unit, or (under `/u`) a code
    /// point up to U+10FFFF.
    char: u21,
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
    /// Lookaround assertion: `(?=…)`/`(?!…)` (lookahead) and
    /// `(?<=…)`/`(?<!…)` (lookbehind, `behind == true`).
    lookahead: Lookahead,
    /// `\p{…}` / `\P{…}` Unicode property escape (only under `/u`). The
    /// compiler resolves `(key, value)` to code-point ranges via an
    /// injected resolver and lowers to a `class`; properties the resolver
    /// declines defer the whole pattern to the fallback. `negated` is `\P`.
    prop: Property,
    /// `/v` (UnicodeSets) extended character class — §22.2.1
    /// ClassSetExpression: nested `[…]` classes, set operators
    /// (union / intersection `&&` / difference `--`) and `^` negation.
    /// The compiler evaluates the operands (resolving `\p{}` via the
    /// injected resolver), applies the set algebra, and lowers a
    /// char-only result to a `class`.
    class_set: *ClassSet,
    /// `(?ims-ims:…)` inline modifier group (§22.2.1, ES2024). Turns the
    /// `i`/`m`/`s` flags on (`add`) and/or off (`remove`) for the scoped
    /// `body` only — never the surrounding pattern or the RegExp object's
    /// own flag properties. The compiler bakes the effective flags into the
    /// body's instructions.
    modifier_group: ModifierGroup,

    pub const Capture = struct { index: usize, name: ?[]const u8, body: *Node };
    pub const Lookahead = struct { negative: bool, behind: bool, body: *Node };

    /// The `i`/`m`/`s` flags an inline modifier group toggles. Only these
    /// three are modifiable (§22.2.1); `g`/`y`/`u`/`v`/`d` are fixed for
    /// the whole pattern and may not appear in a modifier.
    pub const Modifiers = struct {
        ignore_case: bool = false,
        multiline: bool = false,
        dot_all: bool = false,
    };

    /// `(?add-remove:body)` — an inline modifier group. `add` and `remove`
    /// are disjoint (a §22.2.1.1 early error otherwise).
    pub const ModifierGroup = struct { add: Modifiers, remove: Modifiers, body: *Node };
    pub const Property = struct { negated: bool, key: ?[]const u8, value: []const u8 };
    pub const Repeat = struct { body: *Node, min: usize, max: usize, greedy: bool };
    pub const ClassRange = struct { lo: u21, hi: u21 };
    pub const Class = struct { negated: bool, ranges: []const ClassRange };

    /// A `/v` ClassSetExpression. `operands` are combined by `op`; a
    /// ClassSetExpression is exactly one of union / intersection /
    /// difference (mixing operators at one level is a SyntaxError).
    /// `negated` records a leading `^`.
    pub const ClassSet = struct {
        negated: bool,
        op: SetOp,
        operands: []const Operand,

        pub const SetOp = enum { union_, intersection, difference };

        pub const Operand = union(enum) {
            /// Bare characters, `a-z` ranges, and `\d`/`\w`/`\s` and
            /// their complemented `\D`/`\W`/`\S` forms — all already
            /// reduced to code-point ranges at parse time.
            ranges: []const ClassRange,
            /// `\p{…}` / `\P{…}`, resolved to ranges (and, for a
            /// property of strings, to string members) at compile time.
            prop: Property,
            /// A nested `[…]` ClassSetExpression.
            nested: *ClassSet,
            /// `\q{…}` ClassStringDisjunction — each inner slice is one
            /// ClassString's code points (length 0 for the empty
            /// alternative, ≥1 otherwise). Single-character strings fold
            /// into the character set at compile time; the rest make the
            /// set "may contain strings" (§22.2.1.8).
            strings: []const []const u21,
        };
    };
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
    /// True if any inline modifier group *adds* the `i` flag (§22.2.1).
    /// Such a pattern needs case folding even when the program-level `i`
    /// flag is off, so the caller applies the same `/iu` folder gate and
    /// non-ASCII deferral it applies to a program-level `i`.
    has_ignore_case_modifier: bool,
};

pub const ParseError = error{ Unsupported, SyntaxError, OutOfMemory };

/// Parse `src` into an AST. `a` should be an arena — the AST and the
/// transient name list are allocated from it and freed wholesale by
/// the caller once compilation has copied out what it needs.
pub fn parse(a: std.mem.Allocator, src: []const u8, unicode: bool, unicode_sets: bool) ParseError!ParseResult {
    var p: Parser = .{
        .a = a,
        .src = src,
        .pos = 0,
        .names = .empty,
        .unicode = unicode,
        .unicode_sets = unicode_sets,
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
        .has_ignore_case_modifier = p.modifier_adds_i,
    };
}

const Parser = struct {
    a: std.mem.Allocator,
    src: []const u8,
    pos: usize,
    names: std.ArrayListUnmanaged(?[]const u8),
    unicode: bool = false,
    /// `/v` — UnicodeSets mode. Implies code-point (`/u`) matching and
    /// switches `[…]` parsing to the ClassSetExpression grammar.
    unicode_sets: bool = false,
    non_ascii: bool = false,
    /// Set when an inline modifier group adds the `i` flag (§22.2.1) —
    /// surfaced on `ParseResult.has_ignore_case_modifier`.
    modifier_adds_i: bool = false,

    fn peek(self: *Parser) ?u8 {
        return if (self.pos < self.src.len) self.src[self.pos] else null;
    }

    fn at(self: *Parser, off: usize) ?u8 {
        const i = self.pos + off;
        return if (i < self.src.len) self.src[i] else null;
    }

    fn peekIs(self: *Parser, ch: u8) bool {
        return (self.peek() orelse 0) == ch;
    }

    fn atIs(self: *Parser, off: usize, ch: u8) bool {
        return (self.at(off) orelse 0) == ch;
    }

    /// True when the next two bytes are both `ch` (e.g. the `&&` / `--`
    /// ClassSetExpression operators).
    fn peekDouble(self: *Parser, ch: u8) bool {
        return self.peekIs(ch) and self.atIs(1, ch);
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
        if (i == lo_start) {
            // §22.2.1: `{` is a SyntaxCharacter and every Quantifier brace
            // form requires DecimalDigits as the lower bound, so a `{,`
            // (the lower-bound-elided `{,n}` / `{,}` form) cannot be a
            // literal and is a Syntax Error. Annex B §B.1.2 would read the
            // `{` as a literal ExtendedPatternCharacter, but Cynic drops
            // Annex B regex leniency in every mode. Any other non-digit
            // after `{` (e.g. `{b}`, `{}`) makes this not a quantifier; the
            // `{` is re-parsed as an atom, where parseAtom rejects a stray
            // `{` under the same §22.2.1 rule.
            if (i < self.src.len and self.src[i] == ',') return error.SyntaxError;
            return error.NotAQuantifier; // `{` then non-digit, non-comma
        }
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
            '[' => return if (self.unicode_sets) self.parseClassSet() else self.parseCharClass(),
            // §22.2.1: `]`, `{`, `}` are SyntaxCharacters. Outside a
            // CharacterClass (`]`) or a well-formed Quantifier (`{`/`}`)
            // they have no literal interpretation in the main grammar —
            // they are exactly the three chars Annex B §B.1.2's
            // ExtendedPatternCharacter (SourceCharacter but not one of
            // ^ $ \ . * + ? ( ) [ |) would reinterpret as literals. Cynic
            // drops Annex B regex leniency in every mode, so a stray one
            // is a Syntax Error (`/{/`, `/}/`, `/]/`, `/a{b}/`, `/{foo}/`).
            // A real quantifier brace is consumed by parseBraceQuantifier
            // and a class-closing `]` by parseCharClass before reaching here.
            ']', '{', '}' => return error.SyntaxError,
            // Other bare metacharacters in atom position aren't valid here
            // either, but their authoritative verdict (e.g. `)` balance,
            // empty `|` alternatives) is left to the fallback matcher.
            ')', '*', '+', '?', '|' => return error.Unsupported,
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
                    const k3 = self.at(3) orelse return error.Unsupported;
                    if (k3 == '=') return self.parseLookaround(false, true);
                    if (k3 == '!') return self.parseLookaround(true, true);
                    return self.parseNamedCapture();
                },
                '=' => return self.parseLookaround(false, false),
                '!' => return self.parseLookaround(true, false),
                // The only remaining `(?…` constructs are inline modifier
                // groups (§22.2.1 `(?ims-ims:…)`); a non-modifier shape is
                // either a Syntax Error or deferred there.
                else => return self.parseModifierGroup(),
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

    /// Lookaround: `(?=…)`/`(?!…)` (behind == false) or
    /// `(?<=…)`/`(?<!…)` (behind == true).
    fn parseLookaround(self: *Parser, negative: bool, behind: bool) ParseError!*Node {
        self.pos += if (behind) 4 else 3; // `(?<=`/`(?<!` vs `(?=`/`(?!`
        const body = try self.parseDisjunction();
        try self.expect(')');
        return self.makeNode(.{ .lookahead = .{ .negative = negative, .behind = behind, .body = body } });
    }

    /// §22.2.1 inline modifier group (ES2024 regexp-modifiers):
    ///   Atom :: `( ? RegularExpressionFlags : Disjunction )`
    ///   Atom :: `( ? RegularExpressionFlags - RegularExpressionFlags : Disjunction )`
    /// Entered from `parseGroup` at `(?` once the byte after `?` is none of
    /// `:`/`<`/`=`/`!`. Recognises the shape `(? add (- remove)? :`, where
    /// `add`/`remove` are runs of IdentifierPart bytes, and confirms it only
    /// at the closing `:`. A shape that never reaches that `:` is not a
    /// modifier group, so it defers to the fallback for the authoritative
    /// verdict (every other `(?…` form is already handled by `parseGroup`,
    /// so in practice the fallback reports a Syntax Error). Once confirmed,
    /// the four §22.2.1.1 early errors apply.
    fn parseModifierGroup(self: *Parser) ParseError!*Node {
        // `self.pos` is at `(`; the flags begin at `pos + 2` (after `(?`).
        var i = self.pos + 2;
        const add_start = i;
        i = self.scanIdentRun(i);
        const add_text = self.src[add_start..i];

        var remove_text: []const u8 = "";
        var had_dash = false;
        if (i < self.src.len and self.src[i] == '-') {
            had_dash = true;
            i += 1;
            const rem_start = i;
            i = self.scanIdentRun(i);
            remove_text = self.src[rem_start..i];
        }

        // The modifier shape is only confirmed by the closing `:`.
        if (i >= self.src.len or self.src[i] != ':') return error.Unsupported;

        // §22.2.1.1 — each RegularExpressionFlags may contain only `i`/`m`/
        // `s`, with no repeats; `add` and `remove` may not overlap; and the
        // add-remove form may not have both halves empty.
        const add = try parseModifierFlags(add_text);
        const remove = try parseModifierFlags(remove_text);
        if (modifiersOverlap(add, remove)) return error.SyntaxError;
        if (had_dash and modifiersEmpty(add) and modifiersEmpty(remove)) return error.SyntaxError;

        if (add.ignore_case) self.modifier_adds_i = true;
        self.pos = i + 1; // consume the `:`
        const body = try self.parseDisjunction();
        try self.expect(')');
        return self.makeNode(.{ .modifier_group = .{ .add = add, .remove = remove, .body = body } });
    }

    /// Advance past a maximal run of ASCII IdentifierPart bytes
    /// (`[A-Za-z0-9_$]`) from `start`, returning the index of the first
    /// byte that is not one (or `src.len`). A non-ASCII IdentifierPart
    /// would never be a valid modifier flag, so restricting to ASCII here
    /// only affects where an already-invalid modifier shape terminates.
    fn scanIdentRun(self: *Parser, start: usize) usize {
        var i = start;
        while (i < self.src.len) : (i += 1) {
            const ch = self.src[i];
            if (!(std.ascii.isAlphanumeric(ch) or ch == '_' or ch == '$')) break;
        }
        return i;
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

    /// Parse a §22.2.1 GroupName body — a RegExpIdentifierName terminated
    /// by `>` — returning its StringValue as freshly-allocated UTF-8.
    /// Escapes decode to their canonical code points, so `\u{03C0}` and a
    /// literal `π` yield byte-identical names; that makes `\k<…>`
    /// resolution and the §22.2.1.1 duplicate-name early error fall out of
    /// a plain byte comparison. The first code point must be a
    /// RegExpIdentifierStart (UnicodeIDStart ∪ {$, _}); the rest
    /// RegExpIdentifierPart (UnicodeIDContinue ∪ {$, _, <ZWNJ>, <ZWJ>}).
    /// A `\u`/`\u{}` escape is read in +UnicodeMode regardless of the
    /// pattern's `u` flag (the grammar fixes the escape sequence to
    /// [+UnicodeMode]), and a `\uHHHH\uHHHH` lead/trail pair combines into
    /// one supplementary code point. A code point that fails the
    /// identifier test — or a stray non-`\u` escape, or a lone-surrogate
    /// value — defers to the fallback, which is authoritative for the
    /// SyntaxError verdict; an empty or unterminated name is itself an
    /// unambiguous SyntaxError.
    fn parseGroupName(self: *Parser) ParseError![]const u8 {
        var buf: std.ArrayListUnmanaged(u8) = .empty;
        var first = true;
        while (true) {
            const c = self.peek() orelse return error.SyntaxError; // unterminated
            if (c == '>') break;
            const cp = try self.nextIdentifierCodePoint();
            const is_ident = if (first)
                idents.isIdentifierStart(cp)
            else
                idents.isIdentifierPart(cp);
            if (!is_ident) return error.Unsupported;
            var utf8: [4]u8 = undefined;
            const n = std.unicode.utf8Encode(cp, &utf8) catch return error.Unsupported;
            try buf.appendSlice(self.a, utf8[0..n]);
            first = false;
        }
        if (first) return error.SyntaxError; // empty name
        self.pos += 1; // consume `>`
        return try buf.toOwnedSlice(self.a);
    }

    /// Read one code point of a RegExpIdentifierName, advancing past it. A
    /// `\u`/`\u{}` escape decodes in +UnicodeMode (§22.2.1); any other `\`
    /// escape, or invalid UTF-8 (e.g. a WTF-8 lone surrogate in the
    /// source), defers to the fallback.
    fn nextIdentifierCodePoint(self: *Parser) ParseError!u21 {
        const c = self.peek() orelse return error.SyntaxError;
        if (c == '\\') {
            if (self.at(1) != 'u') return error.Unsupported;
            return self.readGroupNameUnicodeEscape();
        }
        if (c < 0x80) {
            self.pos += 1;
            return c;
        }
        const len = std.unicode.utf8ByteSequenceLength(c) catch return error.Unsupported;
        if (self.pos + len > self.src.len) return error.Unsupported;
        const cp = std.unicode.utf8Decode(self.src[self.pos .. self.pos + len]) catch return error.Unsupported;
        self.pos += len;
        return cp;
    }

    /// Read a RegExpUnicodeEscapeSequence[+UnicodeMode] beginning at `\u`
    /// (`self.pos` on the `\`): `\u{CodePoint}` or `\uHHHH`, combining a
    /// `\uHHHH\uHHHH` lead+trail surrogate pair into one supplementary
    /// code point. A bare value is returned as-is — a lone surrogate fails
    /// to UTF-8-encode in `parseGroupName` and defers.
    fn readGroupNameUnicodeEscape(self: *Parser) ParseError!u21 {
        std.debug.assert(self.src[self.pos] == '\\' and self.at(1) == 'u');
        if (self.at(2) == '{') {
            var i = self.pos + 3;
            const start = i;
            // u32 accumulator so an over-long run can't wrap a too-large
            // value back under the 0x10FFFF cap (a u21 `*%` would).
            var v: u32 = 0;
            while (i < self.src.len) : (i += 1) {
                const d = hexVal(self.src[i]) orelse break;
                v = v * 16 + d;
                if (v > 0x10FFFF) return error.Unsupported;
            }
            if (i == start or i >= self.src.len or self.src[i] != '}') return error.Unsupported;
            self.pos = i + 1; // consume through `}`
            return @intCast(v);
        }
        const lead = self.hex4At(self.pos + 2) orelse return error.Unsupported;
        // [+UnicodeMode] HexLeadSurrogate \u HexTrailSurrogate → one code point.
        if (lead >= 0xD800 and lead <= 0xDBFF and self.at(6) == '\\' and self.at(7) == 'u') {
            if (self.hex4At(self.pos + 8)) |trail| {
                if (trail >= 0xDC00 and trail <= 0xDFFF) {
                    self.pos += 12; // two `\uHHHH` escapes
                    return 0x10000 +
                        (@as(u21, lead - 0xD800) << 10) +
                        @as(u21, trail - 0xDC00);
                }
            }
        }
        self.pos += 6;
        return lead;
    }

    /// Read exactly four hex digits at absolute index `idx`, or null if
    /// fewer than four remain or a non-hex byte intervenes.
    fn hex4At(self: *Parser, idx: usize) ?u16 {
        if (idx + 4 > self.src.len) return null;
        var v: u16 = 0;
        for (self.src[idx .. idx + 4]) |ch| {
            const d = hexVal(ch) orelse return null;
            v = v * 16 + d;
        }
        return v;
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
            'p', 'P' => {
                // §22.2.1 CharacterClassEscape — Unicode property escape.
                // Valid under `/u` or `/v`; without either `\p` is Annex B
                // identity-escape territory, deferred to the fallback.
                if (!self.unicode and !self.unicode_sets) return error.Unsupported;
                return self.parsePropertyEscape(k == 'P');
            },
            else => return self.makeNode(.{ .char = try self.parseEscapedChar() }),
        }
    }

    /// `\p{Name}` / `\p{Name=Value}` / `\P{…}` at `\p`/`\P` with `/u`
    /// set. Extracts `(key, value)` syntactically; the compiler's resolver
    /// decides validity, except for the §22.2.1.1 properties of strings,
    /// whose misuse `scanProperty` rejects directly. Other malformed forms
    /// defer to the fallback, which is authoritative for the SyntaxError
    /// verdict.
    fn parsePropertyEscape(self: *Parser, negated: bool) ParseError!*Node {
        return self.makeNode(.{ .prop = try self.scanProperty(negated) });
    }

    /// The syntactic core of a `\p{…}` / `\P{…}` escape, returning the
    /// `(negated, key, value)` triple. Shared by the atom path
    /// (`parsePropertyEscape`) and `/v` class-set operands.
    fn scanProperty(self: *Parser, negated: bool) ParseError!Node.Property {
        if (self.at(2) != '{') return error.Unsupported;
        var i = self.pos + 3;
        const name_start = i;
        var eq: ?usize = null;
        while (i < self.src.len) : (i += 1) {
            const ch = self.src[i];
            if (ch == '}') break;
            if (ch == '=' and eq == null) {
                eq = i;
                continue;
            }
            // UnicodePropertyName / UnicodePropertyValue chars: [A-Za-z0-9_].
            if (!(std.ascii.isAlphanumeric(ch) or ch == '_')) return error.Unsupported;
        }
        if (i >= self.src.len or self.src[i] != '}') return error.Unsupported; // unterminated
        const close = i;
        var key: ?[]const u8 = null;
        const value = blk: {
            if (eq) |e| {
                key = self.src[name_start..e];
                break :blk self.src[e + 1 .. close];
            }
            break :blk self.src[name_start..close];
        };
        if (value.len == 0 or (key != null and key.?.len == 0)) return error.Unsupported;
        // §22.2.1.1 properties of strings: valid only as a positive, lone
        // `\p{…}` under `/v`. `\P{…}` of one and any non-`/v` form are early
        // errors (they would match — or complement — strings where the
        // grammar forbids it). Perlex owns the verdict because its resolver
        // recognises these names; without this gate they would silently
        // lower (a false accept) instead of raising SyntaxError.
        if (isStringProp(key, value)) {
            if (negated) return error.SyntaxError;
            if (!self.unicode_sets) return error.SyntaxError;
        }
        self.pos = close + 1; // consume through `}`
        return .{ .negated = negated, .key = key, .value = value };
    }

    fn classAtom(self: *Parser, negated: bool, ranges: []const Node.ClassRange) ParseError!*Node {
        self.pos += 2; // consume `\` and the class letter
        return self.makeNode(.{ .class = .{ .negated = negated, .ranges = ranges } });
    }

    /// Parse a single-character escape at `\` and return the code unit
    /// it denotes. Class escapes (`\d` …) and `\b`/`\B` are handled by
    /// the callers; this covers control, hex, unicode (BMP), and
    /// identity escapes. Forms outside that set fall back.
    fn parseEscapedChar(self: *Parser) ParseError!u21 {
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
                const hi = hexVal(self.at(2) orelse return self.malformedEscape()) orelse return self.malformedEscape();
                const lo = hexVal(self.at(3) orelse return self.malformedEscape()) orelse return self.malformedEscape();
                const v: u21 = @as(u21, hi) * 16 + lo;
                if (v >= 0x80) self.non_ascii = true;
                return self.takeEscaped(4, v);
            },
            'u' => {
                if (self.at(2) == '{') {
                    // `\u{CodePoint}` — valid only under `/u` or `/v`;
                    // non-Unicode defers (Annex B identity-escape territory).
                    if (!self.unicode and !self.unicode_sets) return error.Unsupported;
                    var i = self.pos + 3;
                    const start = i;
                    // u32 accumulator so an over-long run can't wrap a
                    // too-large value back under the 0x10FFFF cap (a u21 `*%`
                    // would: `\u{200000}` → 0, `\u{300000}` → U+100000). Past
                    // the non-Unicode gate above, CodePoint > 0x10FFFF is a
                    // §22.2.1.1 early error Perlex owns directly — like the
                    // out-of-range numeric backreference — rather than deferring.
                    var v: u32 = 0;
                    while (i < self.src.len) : (i += 1) {
                        const d = hexVal(self.src[i]) orelse break;
                        v = v * 16 + d;
                        if (v > 0x10FFFF) return error.SyntaxError;
                    }
                    // Past the non-Unicode gate above, so an empty or
                    // unterminated `\u{…}` is a §22.2.1.1 early error.
                    if (i == start or i >= self.src.len or self.src[i] != '}') return error.SyntaxError;
                    if (v >= 0x80) self.non_ascii = true;
                    self.pos = i + 1; // consume through `}`
                    return @intCast(v);
                }
                var v: u21 = 0;
                var i: usize = 2;
                while (i < 6) : (i += 1) {
                    const d = hexVal(self.at(i) orelse return self.malformedEscape()) orelse return self.malformedEscape();
                    v = v *% 16 +% @as(u21, d);
                }
                // Under `/u` or `/v`, a surrogate-valued `\uHHHH` (lone,
                // or the first half of a `\uHHHH\uHHHH` pair) needs
                // code-point combining the v1 engine doesn't do — defer.
                if ((self.unicode or self.unicode_sets) and v >= 0xD800 and v <= 0xDFFF) return error.Unsupported;
                if (v >= 0x80) self.non_ascii = true;
                return self.takeEscaped(6, v);
            },
            'c' => {
                // §22.2.1 CharacterEscape :: `c` ControlLetter — the value
                // is the letter's code point mod 32 (`\cA` → U+0001 …).
                if (self.at(2)) |cc| {
                    if ((cc >= 'A' and cc <= 'Z') or (cc >= 'a' and cc <= 'z')) {
                        return self.takeEscaped(3, cc % 32);
                    }
                }
                // `\c` not followed by [A-Za-z]: a §22.2.1.1 early error
                // under /u or /v; otherwise Annex B leniency (`\c0` → U+0010,
                // bare `\c` → literal) the fallback still owns — defer.
                if (self.unicode or self.unicode_sets) return error.SyntaxError;
                return error.Unsupported;
            },
            else => {
                // IdentityEscape: `\` before a syntax character (or `/`)
                // is that literal. Other escapes (`\p{…}`, numeric
                // backrefs, arbitrary-letter Annex B identity escapes)
                // fall back.
                if (isSyntaxChar(k)) return self.takeEscaped(2, k);
                return error.Unsupported;
            },
        }
    }

    fn takeEscaped(self: *Parser, advance: usize, value: u21) u21 {
        self.pos += advance;
        return value;
    }

    /// §22.2.1.1 — under `/u` or `/v` an incomplete `\x`/`\u` escape is an
    /// early error; without it the libregexp fallback still applies the
    /// Annex B identity-escape leniency (`\x` → literal 'x', …), so defer.
    fn malformedEscape(self: *Parser) ParseError {
        return if (self.unicode or self.unicode_sets) error.SyntaxError else error.Unsupported;
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
                .class_added => {
                    // A `-` right after a class escape would form a range
                    // with a class-escape endpoint (`[\d-a]`): a
                    // SyntaxError under /u, an Annex B leniency
                    // otherwise. Implement neither — defer to the
                    // fallback, which renders the mode-correct verdict.
                    if (self.peek() == '-' and self.at(1) != null and self.at(1).? != ']') {
                        return error.Unsupported;
                    }
                },
                .ch => |lo| {
                    if (self.peek() == '-' and self.at(1) != null and self.at(1).? != ']') {
                        self.pos += 1; // consume `-`
                        switch (try self.parseClassMember(&ranges)) {
                            .ch => |hi| {
                                if (hi < lo) return error.SyntaxError; // reversed range
                                try ranges.append(self.a, .{ .lo = lo, .hi = hi });
                            },
                            // Range with a class-escape endpoint (`[a-\d]`)
                            // — same as above, defer.
                            .class_added => return error.Unsupported,
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

    // ---- §22.2.1 ClassSetExpression — the `/v` extended class grammar ----

    /// A single ClassSetOperand / ClassSetCharacter, before any range or
    /// operator context is applied.
    const SetAtom = union(enum) {
        char: u21,
        ranges: []const Node.ClassRange,
        prop: Node.Property,
        nested: *Node.ClassSet,
        /// `\q{…}` ClassStringDisjunction — one slice per ClassString.
        strings: []const []const u21,
    };

    fn makeClassSet(self: *Parser, value: Node.ClassSet) ParseError!*Node.ClassSet {
        const n = try self.a.create(Node.ClassSet);
        n.* = value;
        return n;
    }

    /// Build a ClassSet node and enforce the §22.2.1.1 early error:
    /// `[^ ClassContents ]` is a SyntaxError if MayContainStrings of the
    /// contents is true (a negated set may not contain strings).
    fn finishClassSet(self: *Parser, value: Node.ClassSet) ParseError!*Node.ClassSet {
        const n = try self.makeClassSet(value);
        if (n.negated and mayContainStrings(n)) return error.SyntaxError;
        return n;
    }

    /// `[ … ]` under `/v`. Wraps the ClassSetExpression in a node.
    fn parseClassSet(self: *Parser) ParseError!*Node {
        return self.makeNode(.{ .class_set = try self.parseClassSetInner() });
    }

    /// Parse one `[ (^)? ClassSetExpression ]`. The operator (union by
    /// juxtaposition, `&&`, or `--`) is chosen by what follows the first
    /// operand; mixing operators at one level is rejected.
    fn parseClassSetInner(self: *Parser) ParseError!*Node.ClassSet {
        std.debug.assert(self.src[self.pos] == '[');
        self.pos += 1;
        var negated = false;
        if (self.peekIs('^')) {
            negated = true;
            self.pos += 1;
        }

        var operands: std.ArrayListUnmanaged(Node.ClassSet.Operand) = .empty;

        // Empty class `[]` / `[^]`.
        if (self.peekIs(']')) {
            self.pos += 1;
            return self.finishClassSet(.{ .negated = negated, .op = .union_, .operands = operands.items });
        }

        const first = try self.parseSetAtom();

        if (self.peekDouble('&')) {
            try operands.append(self.a, try self.atomToOperand(first));
            while (self.peekDouble('&')) {
                self.pos += 2;
                // §22.2.1 — a third `&` (`&&&`) is a SyntaxError.
                if (self.peekIs('&')) return error.Unsupported;
                try operands.append(self.a, try self.atomToOperand(try self.parseSetAtom()));
            }
            try self.expect(']');
            return self.finishClassSet(.{ .negated = negated, .op = .intersection, .operands = operands.items });
        }

        if (self.peekDouble('-')) {
            try operands.append(self.a, try self.atomToOperand(first));
            while (self.peekDouble('-')) {
                self.pos += 2;
                try operands.append(self.a, try self.atomToOperand(try self.parseSetAtom()));
            }
            try self.expect(']');
            return self.finishClassSet(.{ .negated = negated, .op = .difference, .operands = operands.items });
        }

        // Union (ClassUnion): juxtaposed operands and `a-z` ranges.
        try self.collectUnion(first, &operands);
        try self.expect(']');
        return self.finishClassSet(.{ .negated = negated, .op = .union_, .operands = operands.items });
    }

    /// Collect the operands of a ClassUnion, starting with the
    /// already-parsed `first`. A ClassSetCharacter followed by `-` and
    /// another character forms a ClassSetRange.
    fn collectUnion(
        self: *Parser,
        first: SetAtom,
        operands: *std.ArrayListUnmanaged(Node.ClassSet.Operand),
    ) ParseError!void {
        var cur = first;
        while (true) {
            const lo: ?u21 = switch (cur) {
                .char => |c| c,
                else => null,
            };
            if (lo != null and self.peekIs('-') and self.at(1) != null and !self.atIs(1, '-') and !self.atIs(1, ']')) {
                self.pos += 1; // consume `-`
                const hi: u21 = switch (try self.parseSetAtom()) {
                    .char => |c| c,
                    // A range endpoint must be a single character.
                    else => return error.Unsupported,
                };
                if (hi < lo.?) return error.SyntaxError; // reversed range
                try operands.append(self.a, .{ .ranges = try self.dupeRange(lo.?, hi) });
            } else {
                try operands.append(self.a, try self.atomToOperand(cur));
            }

            const c = self.peek() orelse return error.SyntaxError; // unterminated
            if (c == ']') return;
            // A union may not contain `&&` / `--` operators (mixed forms
            // are SyntaxErrors); defer the verdict to the fallback.
            if (self.peekDouble('&') or self.peekDouble('-')) return error.Unsupported;
            cur = try self.parseSetAtom();
        }
    }

    fn atomToOperand(self: *Parser, atom: SetAtom) ParseError!Node.ClassSet.Operand {
        return switch (atom) {
            .char => |c| .{ .ranges = try self.dupeRange(c, c) },
            .ranges => |r| .{ .ranges = r },
            .prop => |p| .{ .prop = p },
            .nested => |n| .{ .nested = n },
            .strings => |s| .{ .strings = s },
        };
    }

    fn dupeRange(self: *Parser, lo: u21, hi: u21) ParseError![]const Node.ClassRange {
        const r = try self.a.alloc(Node.ClassRange, 1);
        r[0] = .{ .lo = lo, .hi = hi };
        return r;
    }

    /// Parse a single ClassSetOperand / ClassSetCharacter.
    fn parseSetAtom(self: *Parser) ParseError!SetAtom {
        const c = self.peek() orelse return error.SyntaxError;
        if (c == '[') return .{ .nested = try self.parseClassSetInner() };
        if (c == '\\') return self.parseSetEscape();
        switch (c) {
            ']' => return error.SyntaxError, // empty operand
            // ClassSetSyntaxCharacter / operator lead-ins must be escaped;
            // an unescaped one here is a SyntaxError — defer the verdict.
            '(', ')', '{', '}', '/', '|', '-' => return error.Unsupported,
            else => {},
        }
        // §22.2.1 ClassSetCharacter has `[lookahead ∉
        // ClassSetReservedDoublePunctuator]`: a doubled punctuator
        // (`~~`, `!!`, `::`, …) is reserved and must not be read as two
        // literals. `&&`/`--` are the set operators (handled by the
        // operand dispatch); the rest are early errors — defer so the
        // fallback's double-punctuator table renders the SyntaxError.
        if (isReservedDoublePunct(c) and self.atIs(1, c)) return error.Unsupported;
        return .{ .char = try self.nextCodePoint() };
    }

    /// Class-set escapes: `\d`/`\w`/`\s` and the complemented
    /// `\D`/`\W`/`\S` (as ranges), `\p{}`/`\P{}` (a property operand),
    /// `\q{…}` (a ClassStringDisjunction), `\b` (backspace inside a
    /// class), and single-character escapes.
    fn parseSetEscape(self: *Parser) ParseError!SetAtom {
        const k = self.at(1) orelse return error.SyntaxError;
        switch (k) {
            'd' => return self.setRanges(false, &digit_ranges),
            'D' => return self.setRanges(true, &digit_ranges),
            'w' => return self.setRanges(false, &word_ranges),
            'W' => return self.setRanges(true, &word_ranges),
            's' => return self.setRanges(false, &space_ranges),
            'S' => return self.setRanges(true, &space_ranges),
            'p', 'P' => return .{ .prop = try self.scanProperty(k == 'P') },
            'q' => return self.parseStringDisjunction(),
            'b' => {
                self.pos += 2;
                return .{ .char = 0x08 };
            },
            else => return .{ .char = try self.parseEscapedChar() },
        }
    }

    /// §22.2.1 ClassStringDisjunction — `\q{ ClassString (| ClassString)* }`.
    /// Each ClassString is a (possibly empty) run of ClassSetCharacters.
    /// Every string is retained, including the length-1 case; the
    /// compiler folds single-character strings into the character set and
    /// uses the remaining lengths (0 or ≥2) to decide MayContainStrings
    /// (§22.2.1.8). The vendored matcher cannot parse `\q{…}`, so Perlex
    /// owns the verdict for any pattern containing one.
    fn parseStringDisjunction(self: *Parser) ParseError!SetAtom {
        std.debug.assert(self.src[self.pos] == '\\' and self.at(1) == 'q');
        self.pos += 2; // consume `\q`
        if (!self.peekIs('{')) return error.SyntaxError;
        self.pos += 1; // consume `{`

        var strings: std.ArrayListUnmanaged([]const u21) = .empty;
        while (true) {
            // One ClassString: a run of ClassSetCharacters (possibly empty).
            var cps: std.ArrayListUnmanaged(u21) = .empty;
            while (true) {
                const c = self.peek() orelse return error.SyntaxError; // unterminated `\q{`
                if (c == '}' or c == '|') break;
                try cps.append(self.a, try self.parseStringChar());
            }
            try strings.append(self.a, cps.items);

            const sep = self.peek() orelse return error.SyntaxError;
            if (sep == '}') {
                self.pos += 1; // consume `}`
                break;
            }
            self.pos += 1; // consume `|`, parse the next ClassString
        }
        return .{ .strings = strings.items };
    }

    /// One ClassSetCharacter inside a `\q{…}` ClassString (§22.2.1).
    /// `\b` is backspace; `\` before a ClassSetReservedPunctuator yields
    /// that punctuator; other `\` forms are CharacterEscapes. A bare
    /// ClassSetSyntaxCharacter or a doubled ClassSetReservedDoublePunctuator
    /// is a SyntaxError.
    fn parseStringChar(self: *Parser) ParseError!u21 {
        const c = self.peek() orelse return error.SyntaxError;
        if (c == '\\') {
            const k = self.at(1) orelse return error.SyntaxError;
            // `\b` is backspace inside a class (§22.2.1 ClassSetCharacter).
            if (k == 'b') {
                self.pos += 2;
                return 0x08;
            }
            // `\` + ClassSetReservedPunctuator — the literal punctuator.
            if (isReservedPunct(k)) {
                self.pos += 2;
                return k;
            }
            // Otherwise a CharacterEscape (`\n`, `\x41`, `\u{1F600}`, `\|`…).
            // parseEscapedChar declines forms Perlex can't model (e.g. a
            // surrogate-pair escape) with error.Unsupported, which is
            // surfaced as a SyntaxError because the fallback can't parse
            // `\q{…}` to render the authoritative verdict.
            return self.parseEscapedChar() catch |e| {
                if (e == error.Unsupported) return error.SyntaxError;
                return e;
            };
        }
        // A bare ClassSetSyntaxCharacter is not a ClassSetCharacter; `}`
        // and `|` are consumed by the caller, the rest are SyntaxErrors.
        if (isClassSetSyntaxChar(c)) return error.SyntaxError;
        // `[lookahead ∉ ClassSetReservedDoublePunctuator]` — a doubled
        // reserved punctuator must not be read as two SourceCharacters.
        // `&&` counts here too (it is the intersection operator at the
        // class level but is still a reserved double punctuator).
        if ((isReservedDoublePunct(c) or c == '&') and self.atIs(1, c)) return error.SyntaxError;
        return self.nextCodePoint();
    }

    /// `\d`/`\w`/`\s` → their ranges; the `\D`/`\W`/`\S` complement is
    /// taken over the full code-point universe (§22.2.2.9.1).
    fn setRanges(self: *Parser, negate: bool, base: []const Node.ClassRange) ParseError!SetAtom {
        self.pos += 2;
        if (!negate) return .{ .ranges = base };
        return .{ .ranges = charset.complement(self.a, base) catch return error.OutOfMemory };
    }

    /// Decode the next code point: an ASCII byte or a UTF-8 sequence, so
    /// `/v` classes may contain literal non-ASCII characters.
    fn nextCodePoint(self: *Parser) ParseError!u21 {
        const c = self.peek() orelse return error.SyntaxError;
        if (c < 0x80) {
            self.pos += 1;
            return c;
        }
        const len = std.unicode.utf8ByteSequenceLength(c) catch return error.Unsupported;
        if (self.pos + len > self.src.len) return error.Unsupported;
        const cp = std.unicode.utf8Decode(self.src[self.pos .. self.pos + len]) catch return error.Unsupported;
        if (cp >= 0x80) self.non_ascii = true;
        self.pos += len;
        return cp;
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

/// Parse one RegularExpressionFlags run (§22.2.1) into a `Modifiers`. Each
/// byte must be `i`/`m`/`s` (case-sensitive) and may not repeat — both are
/// §22.2.1.1 early errors. An empty run yields all-false.
fn parseModifierFlags(text: []const u8) ParseError!Node.Modifiers {
    var m: Node.Modifiers = .{};
    for (text) |ch| switch (ch) {
        'i' => {
            if (m.ignore_case) return error.SyntaxError;
            m.ignore_case = true;
        },
        'm' => {
            if (m.multiline) return error.SyntaxError;
            m.multiline = true;
        },
        's' => {
            if (m.dot_all) return error.SyntaxError;
            m.dot_all = true;
        },
        else => return error.SyntaxError, // only i/m/s are modifiable
    };
    return m;
}

/// Whether `a` and `b` share any flag — the §22.2.1.1 early error for the
/// add-remove modifier form (a flag may not be both added and removed).
fn modifiersOverlap(a: Node.Modifiers, b: Node.Modifiers) bool {
    return (a.ignore_case and b.ignore_case) or
        (a.multiline and b.multiline) or
        (a.dot_all and b.dot_all);
}

fn modifiersEmpty(m: Node.Modifiers) bool {
    return !m.ignore_case and !m.multiline and !m.dot_all;
}

fn isSyntaxChar(c: u8) bool {
    return switch (c) {
        '^', '$', '\\', '.', '*', '+', '?', '(', ')', '[', ']', '{', '}', '|', '/' => true,
        else => false,
    };
}

/// §22.2.1 — the lead character of a ClassSetReservedDoublePunctuator
/// (`!! ## $$ %% ** ++ ,, .. :: ;; << == >> ?? @@ ^^ `` ~~`). The two
/// set operators `&&`/`--` are recognised by the operand dispatch and
/// are not listed here.
fn isReservedDoublePunct(c: u8) bool {
    return switch (c) {
        '!', '#', '$', '%', '*', '+', ',', '.', ':', ';', '<', '=', '>', '?', '@', '^', '`', '~' => true,
        else => false,
    };
}

/// §22.2.1 ClassSetReservedPunctuator — `& - ! # % , : ; < = > @ ` ~`.
/// A `\` escape may quote any of these to denote the literal punctuator
/// inside a `/v` class or `\q{…}` string.
fn isReservedPunct(c: u8) bool {
    return switch (c) {
        '&', '-', '!', '#', '%', ',', ':', ';', '<', '=', '>', '@', '`', '~' => true,
        else => false,
    };
}

/// §22.2.1 ClassSetSyntaxCharacter — `( ) [ ] { } / - \ |`. These must be
/// escaped to appear literally inside a `/v` class.
fn isClassSetSyntaxChar(c: u8) bool {
    return switch (c) {
        '(', ')', '[', ']', '{', '}', '/', '-', '\\', '|' => true,
        else => false,
    };
}

/// §22.2.1.8 MayContainStrings, computed structurally on a parsed
/// ClassSet. The §22.2.1.1 early error forbids negating a class whose
/// contents may contain strings, so the predicate is evaluated at parse
/// time on the AST shape — not on the resolved membership. For example
/// `[^[\q{ab}]&&[\q{cd}]]` is a SyntaxError even though the intersection
/// resolves to no strings.
fn mayContainStrings(cs: *const Node.ClassSet) bool {
    switch (cs.op) {
        // Union: true if any operand may contain strings.
        .union_ => {
            for (cs.operands) |op| {
                if (operandMayContainStrings(op)) return true;
            }
            return false;
        },
        // Intersection: true only if every operand may contain strings.
        .intersection => {
            if (cs.operands.len == 0) return false;
            for (cs.operands) |op| {
                if (!operandMayContainStrings(op)) return false;
            }
            return true;
        },
        // Subtraction: true if the left (first) operand may contain strings.
        .difference => {
            if (cs.operands.len == 0) return false;
            return operandMayContainStrings(cs.operands[0]);
        },
    }
}

fn operandMayContainStrings(op: Node.ClassSet.Operand) bool {
    return switch (op) {
        .ranges => false,
        // A positive property of strings contributes string members
        // (§22.2.1.1); a negated one (`\P{…}`) or a non-string property
        // never does. `scanProperty` already rejected a negated property
        // of strings, so any `.prop` reaching here that names one is
        // positive — `isStringProp` is the whole test.
        .prop => |p| isStringProp(p.key, p.value),
        .nested => |n| mayContainStrings(n),
        // §22.2.1.8 — a ClassString of length ≠ 1 makes the set may
        // contain strings (the length-1 case folds into the char set).
        .strings => |ss| blk: {
            for (ss) |s| {
                if (s.len != 1) break :blk true;
            }
            break :blk false;
        },
    };
}

/// The seven §22.2.1.1 *properties of strings* (the UTS #51 emoji-sequence
/// sets). Their members are strings, so the grammar admits them only as a
/// positive, lone `\p{…}` under `/v`. The list is the grammar's — the
/// resolver's data is keyed by the same names — so a non-`/v` use, a `\P{…}`
/// negation, or appearance in a negated set is an early error regardless of
/// whether Cynic's tables happen to carry the name.
const string_property_names = [_][]const u8{
    "Basic_Emoji",
    "Emoji_Keycap_Sequence",
    "RGI_Emoji_Modifier_Sequence",
    "RGI_Emoji_Flag_Sequence",
    "RGI_Emoji_Tag_Sequence",
    "RGI_Emoji_ZWJ_Sequence",
    "RGI_Emoji",
};

/// True iff `\p{value}` (a lone name — no `key=`) names a property of
/// strings. A keyed escape (`\p{gc=…}`, `\p{Script=…}`) never is.
fn isStringProp(key: ?[]const u8, value: []const u8) bool {
    if (key != null) return false;
    for (string_property_names) |n| if (std.mem.eql(u8, n, value)) return true;
    return false;
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
        .empty, .char, .anchor_start, .anchor_end, .word_boundary, .dot, .class, .prop, .class_set, .backref_name, .backref_index => {},
        .noncapture => |body| {
            set.deinit(a);
            return try collectNames(a, body);
        },
        .modifier_group => |mg| {
            // An inline modifier group adds no capture of its own; its
            // body's named groups participate in the enclosing alternative.
            set.deinit(a);
            return try collectNames(a, mg.body);
        },
        .lookahead => |la| {
            // A lookahead's groups participate alongside the rest of
            // the enclosing alternative, so they count for the
            // duplicate-name early error.
            set.deinit(a);
            return try collectNames(a, la.body);
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
