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
        // §22.2.1 — parseAlternative consumes every character except `|`
        // (handled by parseDisjunction) and `)`, and a balanced group
        // consumes its own `)`. So any leftover here is an unmatched `)`,
        // for which the Pattern grammar has no production: a Syntax Error
        // in every mode (`)` is always a SyntaxCharacter, never an Annex B
        // ExtendedPatternCharacter). Perlex owns the verdict directly.
        return error.SyntaxError;
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
    /// A trailing UTF-16 code unit left pending by a non-`/u` astral
    /// literal. Without code-point semantics the source is a code-unit
    /// sequence, so an astral PatternCharacter is two units: `parseAtom`
    /// emits the lead (high) surrogate and stashes the trail (low)
    /// surrogate here. `parseTerm`/`parseAlternative` drain it as the
    /// next term — and it is the *quantifiable* one, so `𠮷+` binds the
    /// trailing unit (`\uD842(\uDFB7)+`), matching every browser engine.
    pending_cu: ?u21 = null,

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
        while (true) {
            // A non-`/u` astral literal leaves its trailing code unit
            // pending; drain it as its own term before reading more
            // source, so the loop never breaks (on `|`/`)`/EOF) with a
            // half-emitted surrogate pair.
            if (self.pending_cu != null) {
                try terms.append(self.a, try self.parseTerm());
                continue;
            }
            const c = self.peek() orelse break;
            if (c == '|' or c == ')') break;
            try terms.append(self.a, try self.parseTerm());
        }
        if (terms.items.len == 0) return self.makeNode(.empty);
        if (terms.items.len == 1) return terms.items[0];
        return self.makeNode(.{ .concat = terms.items });
    }

    /// Term :: Atom Quantifier?  (Assertions are not quantifiable.)
    fn parseTerm(self: *Parser) ParseError!*Node {
        if (self.pending_cu) |cu| {
            // The trailing (low) surrogate of a non-`/u` astral literal.
            // It *is* quantifiable — a quantifier after the astral source
            // char binds this rightmost code unit.
            self.pending_cu = null;
            return self.maybeQuantify(try self.makeNode(.{ .char = cu }));
        }
        const atom = try self.parseAtom();
        // If `parseAtom` decoded a non-`/u` astral literal it emitted the
        // lead (high) surrogate as `atom` and stashed the trail. The lead
        // is not itself quantifiable, so return it raw; the next
        // `parseTerm` drains the pending trail and quantifies *that*.
        if (self.pending_cu != null) return atom;
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
            // §22.2.1 Term — a Quantifier must follow a quantifiable Atom.
            // An anchor (`^` `$`) or word-boundary (`\b` `\B`) is an
            // Assertion, and (unlike a lookahead, the lone Annex B §B.1.2
            // QuantifiableAssertion) is never quantifiable: there is no
            // `Assertion Quantifier` production in any mode. So a quantifier
            // on one is a Syntax Error with or without /u, for every shape —
            // including a brace form like `^{2}` (the `{` is not re-read as a
            // literal; all production engines reject it). `.empty` never
            // reaches here (parseAtom does not produce it), so it is not
            // listed — an empty atom would be a valid nullable repeat anyway.
            .anchor_start, .anchor_end, .word_boundary => return error.SyntaxError,
            // §22.2.1 Term: under +UnicodeMode there is no
            // `Assertion Quantifier` production, so quantifying a lookaround
            // is a SyntaxError. Under ~UnicodeMode only a *lookahead* is a
            // QuantifiableAssertion (Annex B §B.1.2) — a quantified
            // lookbehind is a SyntaxError in every mode. Perlex owns the
            // SyntaxError directly; the Annex-B-valid non-Unicode lookahead
            // falls through to the `.repeat` wrap below and is then dropped
            // by the compiler's nullable-repeat guard (deferred to the
            // fallback, which still matches it).
            .lookahead => |la| if (self.unicode or self.unicode_sets or la.behind) return error.SyntaxError,
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
            // §22.2.1 Term :: Atom Quantifier — a Quantifier metacharacter
            // in atom position has no Atom to its left to repeat, so it is a
            // Syntax Error. Annex B §B.1.2's ExtendedPatternCharacter
            // excludes `* + ?`, so these are never literals in any mode;
            // Perlex owns the verdict directly. (A `{`-quantifier is consumed
            // by parseBraceQuantifier before reaching here; a stray `{` is
            // the SyntaxCharacter rejected just above.)
            '*', '+', '?' => return error.SyntaxError,
            // A bare `)` (group-balance) or `|` (empty alternative) is also
            // invalid here, but parseAlternative breaks on both before they
            // reach parseAtom; if one does arrive its authoritative verdict
            // is left to the fallback matcher.
            ')', '|' => return error.Unsupported,
            else => {
                // A non-ASCII byte begins a multi-unit source character;
                // decode it as a literal PatternCharacter (§22.2.1).
                if (c >= 0x80) return self.parseLiteralCodePoint();
                self.pos += 1;
                return self.makeNode(.{ .char = c });
            },
        }
    }

    /// Decode the non-ASCII source character at `self.pos` as a literal
    /// PatternCharacter (§22.2.1) and emit its node. A BMP code point is
    /// one UTF-16 code unit — identical under code-unit and code-point
    /// semantics. Under `/u`/`/v` an astral code point matches whole. But
    /// without a flag the source is a code-unit sequence, so an astral
    /// character is the two units of its surrogate pair: the lead (high)
    /// surrogate is returned here and the trail (low) surrogate is stashed
    /// in `pending_cu`, so a following quantifier binds only the trailing
    /// unit (`𠮷+` is `\uD842(\uDFB7)+`). A WTF-8 lone surrogate or
    /// malformed sequence (`utf8Decode` rejects either) defers.
    fn parseLiteralCodePoint(self: *Parser) ParseError!*Node {
        const lead = self.src[self.pos];
        const len = std.unicode.utf8ByteSequenceLength(lead) catch return error.Unsupported;
        if (self.pos + len > self.src.len) return error.Unsupported;
        const cp = std.unicode.utf8Decode(self.src[self.pos .. self.pos + len]) catch return error.Unsupported;
        self.pos += len;
        // A non-ASCII unit can case-fold to another non-ASCII unit, which
        // the ASCII-only fold can't model — mirror the `\u`/`\x` decoders
        // so the non-Unicode `i` gate defers such patterns to the fallback.
        self.non_ascii = true;
        if (cp <= 0xFFFF or self.unicode or self.unicode_sets) {
            return self.makeNode(.{ .char = cp });
        }
        // Astral without a flag: split into a UTF-16 surrogate pair.
        const v = cp - 0x10000;
        self.pending_cu = 0xDC00 + @as(u21, @intCast(v & 0x3FF));
        return self.makeNode(.{ .char = 0xD800 + @as(u21, @intCast(v >> 10)) });
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

        // A modifier run may be followed only by `-` (the add/remove
        // separator, handled above) or the `:` that opens the body. Any
        // other byte here — a non-`ims` letter, a combining mark, a space,
        // EOF — means no `(?…` Atom production matches, since `parseGroup`
        // has already routed `(?:`/`(?=`/`(?!`/`(?<…` away. So this is a
        // §22.2.1 SyntaxError in every mode, and Perlex is authoritative:
        // a valid modifier group's run is all-ASCII `ims`, which
        // `scanIdentRun` always consumes whole, stopping exactly at `-`/`:`.
        if (i >= self.src.len or self.src[i] != ':') return error.SyntaxError;

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
    /// one supplementary code point.
    ///
    /// Perlex implements that grammar in full, and under ES2025
    /// NamedCaptureGroups is always enabled, so a name it cannot form is a
    /// §22.2.1.1 SyntaxError in every mode — never a deferrable construct.
    /// `(?<` has no Annex B reinterpretation (the only other `(?<…` Atoms,
    /// the `(?<=` / `(?<!` lookbehinds, are routed away before we get
    /// here), and a `\k` followed by `<` is always a backreference, so both
    /// call sites are authoritative. The body signals every malformed-name
    /// case — a code point that fails the identifier test, a stray non-`\u`
    /// escape, a malformed `\u`, a lone-surrogate value — as
    /// `error.Unsupported`; this wrapper promotes those to the
    /// authoritative `error.SyntaxError`. An empty or unterminated name is
    /// raised as a SyntaxError directly and passes through unchanged.
    fn parseGroupName(self: *Parser) ParseError![]const u8 {
        return self.parseGroupNameBody() catch |e| switch (e) {
            error.Unsupported => error.SyntaxError,
            else => e,
        };
    }

    fn parseGroupNameBody(self: *Parser) ParseError![]const u8 {
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
                // §22.2.1 AtomEscape :: \k GroupName. Under /u or /v a `\k`
                // not followed by `<GroupName>` is an early error; without
                // either flag the fallback applies Annex B identity-escape
                // leniency (`\k` → literal 'k'), so defer.
                if (self.at(2) != '<') return self.malformedEscape();
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
            '-' => {
                // §22.2.1 IdentityEscape — `\-` as an *atom*. `-` (U+002D)
                // is not UnicodeIDContinue, so without /u it is a valid
                // IdentityEscape[~UnicodeMode] matching '-' (main grammar,
                // not an Annex B widening). Under /u or /v the atom grammar
                // shrinks to SyntaxCharacter or `/`, and `-` is neither, so
                // it is a §22.2.1.1 early error. The shared class-member
                // decoder (parseEscapedChar) still owns `[\-]`, where `\-`
                // is the escaped literal '-' in every mode — this atom-only
                // switch never reaches it.
                if (self.unicode or self.unicode_sets) return error.SyntaxError;
                self.pos += 2;
                return self.makeNode(.{ .char = '-' });
            },
            else => return self.makeNode(.{ .char = try self.parseEscapedChar() }),
        }
    }

    /// `\p{Name}` / `\p{Name=Value}` / `\P{…}` at `\p`/`\P` with `/u` or
    /// `/v` set. Extracts `(key, value)` syntactically; a well-formed name
    /// the resolver can't place defers to the fallback, but every ill-formed
    /// shape — and a §22.2.1.1 misuse of a property of strings — is an early
    /// error `scanProperty` raises directly.
    fn parsePropertyEscape(self: *Parser, negated: bool) ParseError!*Node {
        return self.makeNode(.{ .prop = try self.scanProperty(negated) });
    }

    /// The syntactic core of a `\p{…}` / `\P{…}` escape, returning the
    /// `(negated, key, value)` triple. Shared by the atom path
    /// (`parsePropertyEscape`) and `/v` class-set operands — both gate on
    /// `/u` or `/v`, so a malformed shape reached here is a §22.2.1.1 early
    /// error (SyntaxError), never an Annex B deferral.
    fn scanProperty(self: *Parser, negated: bool) ParseError!Node.Property {
        if (self.at(2) != '{') return error.SyntaxError; // `\p`/`\P` with no `{`
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
            if (!(std.ascii.isAlphanumeric(ch) or ch == '_')) return error.SyntaxError;
        }
        if (i >= self.src.len or self.src[i] != '}') return error.SyntaxError; // unterminated
        const close = i;
        var key: ?[]const u8 = null;
        const value = blk: {
            if (eq) |e| {
                key = self.src[name_start..e];
                break :blk self.src[e + 1 .. close];
            }
            break :blk self.src[name_start..close];
        };
        if (value.len == 0 or (key != null and key.?.len == 0)) return error.SyntaxError; // empty key/value
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
                // §22.2.1.1 `\0` is U+0000 only with [lookahead ∉
                // DecimalDigit]. `\0` before a digit under /u or /v is an
                // early error (Unicode mode has no LegacyOctalEscapeSequence);
                // without a flag it is an Annex B legacy octal / decimal
                // escape the fallback matches, so defer.
                if (self.at(2)) |d| {
                    if (d >= '0' and d <= '9') return self.malformedEscape();
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
                // Under `/u` or `/v` (§22.2.1.1 RegExpUnicodeEscapeSequence):
                // a lead surrogate (`\uD800`–`\uDBFF`) followed by a `\uHHHH`
                // trail (low) surrogate combines into one supplementary code
                // point; any other surrogate-valued `\uHHHH` (lone lead or
                // lone trail) denotes that surrogate code point itself. The
                // VM decodes the input the same way, matching both.
                if (self.unicode or self.unicode_sets) {
                    if (v >= 0xD800 and v <= 0xDBFF) {
                        if (self.trailSurrogateAt(self.pos + 6)) |lo| {
                            self.pos += 12; // consume both `\uHHHH` escapes
                            self.non_ascii = true;
                            return 0x10000 + ((v - 0xD800) << 10) + (lo - 0xDC00);
                        }
                    }
                    self.non_ascii = true;
                    return self.takeEscaped(6, v);
                }
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
                // §22.2.1 IdentityEscape:
                //   [+UnicodeMode] SyntaxCharacter
                //   [+UnicodeMode] /
                //   [~UnicodeMode] SourceCharacter but not UnicodeIDContinue
                // A `\` before a SyntaxCharacter or `/` is that literal in
                // every mode — and under /u or /v that two-form set is the
                // *entire* IdentityEscape grammar (§22.2.1.1). So every
                // other escaped character under /u or /v — a digit (a
                // DecimalEscape, which a class has no production for), an
                // arbitrary letter like `\X` — is an early error Perlex owns.
                if (isSyntaxChar(k) or k == '/') return self.takeEscaped(2, k);
                // Three escapes stay deferred in every mode because they
                // are valid under /u in a context this single-code-point
                // decoder can't see: `\p` / `\P` are CharacterClassEscapes
                // (a set, reached here only from the class path, which has
                // no `\p` case), and `\-` is a ClassEscape under
                // +UnicodeMode but an invalid atom IdentityEscape. The
                // fallback renders their (possibly SyntaxError) verdict —
                // converting them risks a false reject of `[\p{…}]/u` /
                // `[\-]/u`.
                if (k == 'p' or k == 'P' or k == '-') return error.Unsupported;
                // Without /u the main grammar's IdentityEscape also covers
                // any SourceCharacter that is not UnicodeIDContinue — e.g.
                // ASCII punctuation like `\!` `\@` `` \` `` `\~`. For ASCII,
                // not-UnicodeIDContinue ⇔ not `[A-Za-z0-9_]`; `$` never
                // reaches here (a SyntaxCharacter, handled above). Perlex
                // owns these directly. The residual cases — an IDContinue
                // letter (`\X`), a digit (a DecimalEscape), a non-ASCII
                // escape — defer: under /u each is a §22.2.1.1 early error,
                // without /u the fallback applies Annex B identity/octal
                // leniency (`\X` → literal 'X', `\1` → legacy octal).
                if (!self.unicode and !self.unicode_sets and
                    k < 0x80 and !(std.ascii.isAlphanumeric(k) or k == '_'))
                {
                    return self.takeEscaped(2, k);
                }
                return self.malformedEscape();
            },
        }
    }

    fn takeEscaped(self: *Parser, advance: usize, value: u21) u21 {
        self.pos += advance;
        return value;
    }

    /// §22.2.1.1: if the six source chars at `at` are a `\uHHHH` escape
    /// whose value is a trailing (low) surrogate, return that value; else
    /// null. Lets a `\uHHHH\uHHHH` lead+trail pair combine into one code
    /// point under `/u`/`/v`. Only the 4-digit form combines — a `\u{…}`
    /// trail does not (it is its own RegExpUnicodeEscapeSequence production).
    fn trailSurrogateAt(self: *Parser, off: usize) ?u21 {
        if (off + 6 > self.src.len) return null;
        if (self.src[off] != '\\' or self.src[off + 1] != 'u') return null;
        var v: u21 = 0;
        var i: usize = 0;
        while (i < 4) : (i += 1) {
            const d = hexVal(self.src[off + 2 + i]) orelse return null;
            v = v * 16 + @as(u21, d);
        }
        if (v >= 0xDC00 and v <= 0xDFFF) return v;
        return null;
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
        // `\p{…}` / `\P{…}` ClassAtoms; the parser can't expand them (the
        // resolver runs at compile time), so a class that has any lowers to
        // a union ClassSet rather than a flat `.class`.
        var props: std.ArrayListUnmanaged(Node.Property) = .empty;
        while (true) {
            const c = self.peek() orelse return error.SyntaxError; // unterminated
            if (c == ']') {
                self.pos += 1;
                break;
            }
            const member = try self.parseClassMember(&ranges);
            // A following `- X` (where X is not the closing `]`) makes the
            // member the low bound of a range.
            const dash_range = self.peek() == '-' and self.at(1) != null and self.at(1).? != ']';
            switch (member) {
                .class_added => {
                    // `\d \s \w` — already appended. As a range low bound
                    // (`[\d-a]`) it is a §22.2.1.1 /u early error.
                    if (dash_range) return self.classEscapeRangeBound();
                },
                .class_escape_unsupported => {
                    // `\D \S \W` under /u (off /u they were complemented in
                    // place and returned `.class_added`). As a range low
                    // bound (`[\D-a]`) it is a §22.2.1.1 /u early error;
                    // standalone, defer to the fallback to match it.
                    if (dash_range) return self.classEscapeRangeBound();
                    return error.Unsupported;
                },
                .prop => |p| {
                    // `\p{…}` / `\P{…}` — as a range bound (`[\p{L}-a]`) it is
                    // the same §22.2.1.1 /u early error a shorthand would be;
                    // standalone it joins the class's union of operands.
                    if (dash_range) return self.classEscapeRangeBound();
                    try props.append(self.a, p);
                },
                .ch => |lo| {
                    if (dash_range) {
                        self.pos += 1; // consume `-`
                        switch (try self.parseClassMember(&ranges)) {
                            .ch => |hi| {
                                if (hi < lo) return error.SyntaxError; // reversed range
                                try ranges.append(self.a, .{ .lo = lo, .hi = hi });
                            },
                            // Range with a CharacterClassEscape high bound
                            // (`[a-\d]` / `[a-\D]` / `[a-\p{L}]`): §22.2.1.1
                            // /u early error.
                            .class_added, .class_escape_unsupported, .prop => return self.classEscapeRangeBound(),
                        }
                    } else {
                        try ranges.append(self.a, .{ .lo = lo, .hi = lo });
                    }
                },
            }
        }
        if (props.items.len == 0) {
            return self.makeNode(.{ .class = .{ .negated = negated, .ranges = ranges.items } });
        }
        // §22.2.1 ClassRanges is the union of its ClassAtoms. With `\p{…}`
        // members present, lower the class to a union ClassSetExpression so
        // the compiler resolves each property and unions it with the literal
        // ranges (and complements the whole set for `[^ … ]`). The /v-only
        // operators (`&&`, `--`, nested `[…]`, `\q{…}`) never reach here, so
        // this is a pure union — and scanProperty already rejected the only
        // string-valued properties, so a negated set can't contain strings.
        var operands: std.ArrayListUnmanaged(Node.ClassSet.Operand) = .empty;
        if (ranges.items.len != 0) try operands.append(self.a, .{ .ranges = ranges.items });
        for (props.items) |p| try operands.append(self.a, .{ .prop = p });
        const cs = try self.makeClassSet(.{ .negated = negated, .op = .union_, .operands = operands.items });
        return self.makeNode(.{ .class_set = cs });
    }

    const ClassMember = union(enum) {
        ch: u21,
        /// A CharacterClassEscape Perlex represents as ranges and has
        /// already appended (`\d \s \w`); valid as a standalone member.
        class_added,
        /// A `\D \S \W` set complement under /u, where Perlex can't
        /// complement at parse time (the parser isn't told `i`, so it can't
        /// rule out the /iu non-ASCII fold orbits). Standalone it defers to
        /// the fallback to match; as a `-` range bound it is a §22.2.1.1
        /// early error — the caller decides which. Off /u these are
        /// complemented in place and returned as `.class_added` instead.
        class_escape_unsupported,
        /// A `\p{…}` / `\P{…}` Unicode property escape (§22.2.1, +UnicodeMode).
        /// The parser can't expand it to ranges (the resolver runs at
        /// compile time), so the class lowers to a union ClassSet whose
        /// operands carry this property; as a `-` range bound it is the
        /// same §22.2.1.1 early error a class shorthand would be.
        prop: Node.Property,
    };

    /// §22.2.1.1 NonemptyClassRanges (+UnicodeMode): it is a Syntax Error
    /// for either bound of a `-` range to be a CharacterClassEscape
    /// (`\d \D \s \S \w \W`), e.g. `[\d-a]` / `[a-\d]` / `[\D-\D]`. Without
    /// /u the `-` and the shorthand are matched literally (Annex B), which
    /// the libregexp fallback owns — so defer there.
    fn classEscapeRangeBound(self: *Parser) ParseError {
        return if (self.unicode or self.unicode_sets) error.SyntaxError else error.Unsupported;
    }

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
                // `\D \S \W` inside a class is the set complement of the
                // positive shorthand. Off /u we complement the range set at
                // parse time and append it as ordinary ranges, so the class
                // is owned. The complement of `\d`/`\s`/`\w` contains each
                // ASCII letter together with its case-swap (or neither), so
                // it is closed under the VM's inline ASCII fold — non-Unicode
                // `i` matches exactly. Under /u we can't: the parser isn't
                // told `i`, so it can't distinguish /u from /iu, and /iu
                // pulls non-ASCII fold orbits (the Kelvin sign U+212A folds
                // with `k`, joining `\W`'s complement) that a parse-time
                // ASCII complement can't represent. So under /u keep deferring
                // — `.class_escape_unsupported` lets the caller still raise
                // the §22.2.1.1 range-bound early error.
                'D', 'W', 'S' => {
                    self.pos += 2;
                    if (self.unicode) return .class_escape_unsupported;
                    const base: []const Node.ClassRange = switch (k) {
                        'D' => &digit_ranges,
                        'S' => &space_ranges,
                        'W' => &word_ranges,
                        else => unreachable,
                    };
                    const comp = try charset.complement(self.a, base);
                    try appendRanges(self.a, ranges, comp);
                    return .class_added;
                },
                // §22.2.1 ClassEscape :: CharacterClassEscape :: `\p{…}` /
                // `\P{…}` — a Unicode property escape, valid only under /u
                // (this simple-class path) or /v. Without a flag `\p` is
                // Annex B identity-escape territory the fallback owns, so
                // defer. scanProperty owns every malformed shape — a bare
                // `\p`/`\P` with no `{…}`, an empty/unterminated `{…}`, a
                // non-/v property of strings — as a §22.2.1.1 early error.
                'p', 'P' => {
                    if (!self.unicode and !self.unicode_sets) return error.Unsupported;
                    return .{ .prop = try self.scanProperty(k == 'P') };
                },
                // `\b` inside a class is backspace, not a word boundary.
                'b' => {
                    self.pos += 2;
                    return .{ .ch = 0x08 };
                },
                else => return .{ .ch = try self.parseEscapedChar() },
            }
        }
        // A non-ASCII byte begins a multi-unit source character; decode it
        // as a literal ClassAtom (§22.2.1).
        if (c >= 0x80) return self.classLiteralCodePoint(ranges);
        self.pos += 1;
        return .{ .ch = c };
    }

    /// Decode the non-ASCII source character at `self.pos` as a literal
    /// ClassAtom (§22.2.1). A BMP code point is one UTF-16 code unit, so it
    /// is one class member in every mode. Under `/u`/`/v` an astral code
    /// point is one member too — a valid (range-capable) endpoint, since
    /// `ClassRange` bounds are `u21` — returned as `.ch`. Without a flag the
    /// source is a code-unit sequence, so an astral ClassAtom is two
    /// single-unit members — the alternatives of its surrogate pair. A class
    /// is the union of its members, so append both halves as single-unit
    /// ranges directly and return `.class_added`; the class then matches a
    /// code unit equal to either half (it does NOT match the pair as one
    /// code point — that needs /u). A WTF-8 lone surrogate or malformed
    /// sequence (`utf8Decode` rejects either) defers to the fallback.
    fn classLiteralCodePoint(self: *Parser, ranges: *std.ArrayListUnmanaged(Node.ClassRange)) ParseError!ClassMember {
        const lead = self.src[self.pos];
        const len = std.unicode.utf8ByteSequenceLength(lead) catch return error.Unsupported;
        if (self.pos + len > self.src.len) return error.Unsupported;
        const cp = std.unicode.utf8Decode(self.src[self.pos .. self.pos + len]) catch return error.Unsupported;
        self.pos += len;
        // A non-ASCII unit can case-fold to another non-ASCII unit, which
        // the ASCII-only fold can't model — mirror the atom decoder so the
        // non-Unicode `i` gate (see perlex.zig) defers such patterns to the
        // fallback. (The surrogate halves below never fold, but a following
        // BMP member of the same class might, so set it uniformly.)
        self.non_ascii = true;
        if (cp > 0xFFFF and !self.unicode and !self.unicode_sets) {
            // §22.2.1 ClassAtom over a non-UnicodeMode SourceCharacter: the
            // astral code point is its UTF-16 surrogate pair, two single-unit
            // members of the union.
            const v: u21 = cp - 0x10000;
            const high: u21 = 0xD800 + (v >> 10);
            const low: u21 = 0xDC00 + (v & 0x3FF);
            try ranges.append(self.a, .{ .lo = high, .hi = high });
            try ranges.append(self.a, .{ .lo = low, .hi = low });
            return .class_added;
        }
        return .{ .ch = cp };
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
