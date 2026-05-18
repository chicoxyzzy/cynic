//! Lexical scanner for Cynic. Implements a strict-only subset of ECMA-262 §11.
//!
//! Coverage in this slice:
//! • §11.2 White Space
//! • §11.3 Line Terminators
//! • §11.4 Comments (single-line, multi-line)
//! • §12.5 HashbangComment (`#!` at the start of source)
//! • §12.7 IdentifierName, including Unicode `IdentifierStart` /
//! `IdentifierPart` and `\uXXXX` / `\u{...}` escapes. Reserved-word
//! escapes (e.g. `\u{6c}et`) are diagnosed per §12.7.1.
//! • §12.7 Punctuators (full set)
//! • §12.7.2 Reserved Words (strict-mode set, via token.zig)
//! • §12.8.3 NumericLiteral: DecimalLiteral, HexIntegerLiteral,
//! OctalIntegerLiteral, BinaryIntegerLiteral, BigInt suffix
//! • §12.8.4 StringLiteral: single/double-quoted with the common
//! EscapeSequences, including LineContinuation
//! • §12.8.6 Template Literals: `NoSubstitutionTemplate`, `TemplateHead`,
//! `TemplateMiddle`, `TemplateTail`. Continuation after a `${...}`
//! substitution is parser-driven via `nextTemplateContinuation`.
//!
//! Stubs (return diagnostics, will be implemented next):
//! • §12.8.5 RegularExpressionLiteral — requires parser-driven goal
//! selection between InputElementDiv and InputElementRegExp.
//! • LegacyOctalEscapeSequence (forbidden in strict mode — already rejected).

const std = @import("std");

const token_mod = @import("token.zig");
const Token = token_mod.Token;
const TokenKind = token_mod.TokenKind;
const keywordKind = token_mod.keywordKind;

const source_mod = @import("../source.zig");
const Span = source_mod.Span;

const diag_mod = @import("../diagnostic.zig");
const Diagnostic = diag_mod.Diagnostic;
const Diagnostics = diag_mod.Diagnostics;
const Code = diag_mod.Code;

const idents = @import("../unicode/idents.zig");

pub const LexError = error{
    UnterminatedString,
    UnterminatedComment,
    UnterminatedTemplate,
    InvalidNumericLiteral,
    InvalidEscapeSequence,
    InvalidIdentifierEscape,
    EscapeInReservedWord,
    UnexpectedCharacter,
    RegexLiteralUnsupported,
    OutOfMemory,
};

pub const Lexer = struct {
    source: []const u8,
    pos: u32 = 0,
    /// True if the trivia just consumed contained a LineTerminator. Read by
    /// the parser for ASI (§12.10) and restricted productions.
    saw_line_terminator: bool = false,
    /// Optional diagnostic sink. When null, errors still propagate via
    /// `LexError`. The lexer never frees diagnostics — the caller owns them.
    diagnostics: ?*Diagnostics = null,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, source: []const u8) Lexer {
        return .{ .source = source, .allocator = allocator };
    }

    /// Current byte offset into `source`. Used by the parser to compute
    /// statement-end spans when ASI fires (the relevant position is where
    /// the previous token ended, not where the following one starts).
    pub fn currentPos(self: *const Lexer) u32 {
        return self.pos;
    }

    /// Scan and return the next token. Returns `.eof` repeatedly past the end
    /// of input.
    pub fn next(self: *Lexer) LexError!Token {
        self.saw_line_terminator = false;
        // §12.5 HashbangComment: `#!` followed by SingleLineCommentChars, only
        // at the very start of the source. Treated like a single-line comment
        // so the parser never sees a token for it.
        if (self.pos == 0 and self.source.len >= 2 and
            self.source[0] == '#' and self.source[1] == '!')
        {
            self.pos = 2;
            while (self.pos < self.source.len) {
                const c = self.source[self.pos];
                if (c == '\n' or c == '\r') break;
                self.pos += 1;
            }
        }
        try self.skipTrivia();
        const start = self.pos;
        if (self.pos >= self.source.len) return self.makeToken(.eof, start);

        const c = self.source[self.pos];
        return switch (c) {
            'a'...'z', 'A'...'Z', '_', '$' => self.scanIdentifier(start),
            '0'...'9' => self.scanNumericLiteral(start),
            '"', '\'' => self.scanStringLiteral(start, c),
            '`' => self.scanTemplate(start, false),
            // §12.7: an IdentifierName may begin with a UnicodeEscapeSequence.
            '\\' => self.scanIdentifier(start),
            else => {
                // Non-ASCII lead byte: decode and route to identifier scanning
                // if the codepoint is `IdentifierStart`. Anything else falls
                // through to punctuator scanning, which reports
                // `unexpected_character`.
                if (c >= 0x80) {
                    if (self.peekUtf8()) |dec| {
                        if (idents.isIdentifierStart(dec.cp)) return self.scanIdentifier(start);
                    } else |_| {}
                }
                return self.scanPunctuator(start);
            },
        };
    }

    // ── Trivia ──────────────────────────────────────────────────────────

    fn skipTrivia(self: *Lexer) LexError!void {
        while (self.pos < self.source.len) {
            const c = self.source[self.pos];
            switch (c) {
                // §11.2 White Space (ASCII)
                ' ', '\t', 0x0B, 0x0C => self.pos += 1,
                // §11.3 Line Terminators — ASCII LF / CR (CRLF as a unit).
                '\n' => {
                    self.pos += 1;
                    self.saw_line_terminator = true;
                },
                '\r' => {
                    self.pos += 1;
                    if (self.pos < self.source.len and self.source[self.pos] == '\n') self.pos += 1;
                    self.saw_line_terminator = true;
                },
                '/' => {
                    if (self.pos + 1 >= self.source.len) return;
                    const n = self.source[self.pos + 1];
                    if (n == '/') {
                        self.skipSingleLineComment();
                    } else if (n == '*') {
                        try self.skipMultiLineComment();
                    } else {
                        return;
                    }
                },
                else => {
                    // §11.2 / §11.3 — Unicode-class whitespace and line
                    // terminators (NBSP, Space_Separator, ZWNBSP, LS, PS).
                    // Decode one UTF-8 codepoint and check; bail out on
                    // anything else so the next token can start here.
                    if (c < 0x80) return;
                    const decoded = self.peekUtf8() catch return;
                    if (isUnicodeLineTerminator(decoded.cp)) {
                        self.saw_line_terminator = true;
                        self.pos += decoded.len;
                    } else if (isUnicodeWhitespace(decoded.cp)) {
                        self.pos += decoded.len;
                    } else {
                        return;
                    }
                },
            }
        }
    }

    /// True for ECMA-262 §11.2 WhiteSpace code points beyond ASCII.
    /// Covers U+00A0 (NBSP), U+1680 (Ogham Space Mark), U+2000–U+200A,
    /// U+202F, U+205F, U+3000 (the Space_Separator general category)
    /// and U+FEFF (ZWNBSP). The ASCII forms (TAB/VT/FF/SP) are
    /// recognised earlier in the dispatcher.
    fn isUnicodeWhitespace(cp: u21) bool {
        return switch (cp) {
            0x00A0,
            0x1680,
            0x2000...0x200A,
            0x202F,
            0x205F,
            0x3000,
            0xFEFF,
            => true,
            else => false,
        };
    }

    /// True for §11.3 LineTerminator code points beyond ASCII LF/CR:
    /// U+2028 LINE SEPARATOR, U+2029 PARAGRAPH SEPARATOR.
    fn isUnicodeLineTerminator(cp: u21) bool {
        return cp == 0x2028 or cp == 0x2029;
    }

    fn skipSingleLineComment(self: *Lexer) void {
        // §11.4: SingleLineComment :: // SingleLineCommentChars?
        // SingleLineCommentChars excludes LineTerminator code points,
        // which per §11.3 are LF, CR, U+2028, and U+2029.
        std.debug.assert(self.source[self.pos] == '/' and self.source[self.pos + 1] == '/');
        self.pos += 2;
        while (self.pos < self.source.len) {
            const c = self.source[self.pos];
            if (c == '\n' or c == '\r') break;
            if (c >= 0x80) {
                const decoded = self.peekUtf8() catch {
                    self.pos += 1;
                    continue;
                };
                if (isUnicodeLineTerminator(decoded.cp)) break;
                self.pos += decoded.len;
                continue;
            }
            self.pos += 1;
        }
    }

    fn skipMultiLineComment(self: *Lexer) LexError!void {
        // §11.4: MultiLineComment :: /* MultiLineCommentChars? */
        // A multi-line comment that contains a LineTerminator code point
        // (LF, CR, U+2028, or U+2029) is itself treated as a
        // LineTerminator for syntactic purposes — that's what enables
        // ASI across `/* … LF … */` between two tokens.
        const start = self.pos;
        std.debug.assert(self.source[self.pos] == '/' and self.source[self.pos + 1] == '*');
        self.pos += 2;
        while (self.pos + 1 < self.source.len) {
            if (self.source[self.pos] == '*' and self.source[self.pos + 1] == '/') {
                self.pos += 2;
                return;
            }
            const c = self.source[self.pos];
            if (c == '\n') {
                self.saw_line_terminator = true;
                self.pos += 1;
            } else if (c == '\r') {
                self.saw_line_terminator = true;
                self.pos += 1;
                if (self.pos < self.source.len and self.source[self.pos] == '\n') self.pos += 1;
            } else if (c >= 0x80) {
                // Could be U+2028 / U+2029. Decode and advance by the
                // codepoint length; non-LT multibyte chars are kept as
                // ordinary comment content.
                const decoded = self.peekUtf8() catch {
                    self.pos += 1;
                    continue;
                };
                if (isUnicodeLineTerminator(decoded.cp)) {
                    self.saw_line_terminator = true;
                }
                self.pos += decoded.len;
            } else {
                self.pos += 1;
            }
        }
        try self.report(.unterminated_multi_line_comment, .{ .start = start, .end = @intCast(self.source.len) });
        self.pos = @intCast(self.source.len);
        return error.UnterminatedComment;
    }

    // ── Identifiers / Keywords ──────────────────────────────────────────

    /// Identifier scanner — handles ASCII, multi-byte UTF-8, and `\uXXXX` /
    /// `\u{...}` escapes per §12.7. The first character has already been
    /// validated by `next()` (or by `scanPrivateIdentifier` after consuming
    /// `#`), but we re-dispatch here so the start codepoint is consumed and
    /// validated uniformly with the continuation logic.
    fn scanIdentifier(self: *Lexer, start: u32) LexError!Token {
        var saw_escape = false;
        try self.scanIdentifierStart(start, &saw_escape);
        try self.scanIdentifierTail(&saw_escape);

        if (saw_escape) {
            // §12.7.1: an IdentifierName whose source contains a `\u`
            // escape and whose StringValue is a ReservedWord must NOT
            // be used as an Identifier (BindingIdentifier /
            // IdentifierReference / LabelIdentifier). It IS, however,
            // valid as an IdentifierName in PropertyName / member-
            // access positions. The lexer always emits such a token as
            // `.identifier` with `had_escape = true`; the parser
            // enforces the rule contextually by inspecting that flag.
            var sv_buf: [256]u8 = undefined;
            var sv_heap: ?[]u8 = null;
            defer if (sv_heap) |h| self.allocator.free(h);
            const sv = try self.identifierStringValue(start, &sv_buf, &sv_heap);
            const kw = keywordKind(sv);
            var tok = self.makeToken(.identifier, start);
            tok.had_escape = kw != null;
            if (kw) |k| tok.escaped_keyword = k;
            return tok;
        }

        const slice = self.source[start..self.pos];
        const kind = keywordKind(slice) orelse TokenKind.identifier;
        return self.makeToken(kind, start);
    }

    /// Consume the first codepoint of an IdentifierName. The pos is at the
    /// (already-validated) start character; this routine just commits the
    /// advance and, if the start is a `\u` escape or a UTF-8 lead byte,
    /// validates that the decoded codepoint is `IdentifierStart`.
    fn scanIdentifierStart(self: *Lexer, start: u32, saw_escape: *bool) LexError!void {
        const c = self.source[self.pos];
        if (c == '\\') {
            const cp = try self.parseIdentifierEscape();
            if (!idents.isIdentifierStart(cp)) {
                try self.report(.invalid_identifier_escape, .{ .start = start, .end = self.pos });
                return error.InvalidIdentifierEscape;
            }
            saw_escape.* = true;
            return;
        }
        if (c < 0x80) {
            if (!idents.isAsciiIdentifierStart(c)) {
                try self.report(.unexpected_character, .{ .start = self.pos, .end = self.pos + 1 });
                return error.UnexpectedCharacter;
            }
            self.pos += 1;
            return;
        }
        const dec = self.peekUtf8() catch {
            try self.report(.unexpected_character, .{ .start = self.pos, .end = self.pos + 1 });
            return error.UnexpectedCharacter;
        };
        if (!idents.isIdentifierStart(dec.cp)) {
            try self.report(.unexpected_character, .{ .start = self.pos, .end = self.pos + dec.len });
            return error.UnexpectedCharacter;
        }
        self.pos += dec.len;
    }

    fn scanIdentifierTail(self: *Lexer, saw_escape: *bool) LexError!void {
        while (self.pos < self.source.len) {
            const c = self.source[self.pos];
            if (c == '\\') {
                const escape_start = self.pos;
                const cp = try self.parseIdentifierEscape();
                if (!idents.isIdentifierPart(cp)) {
                    try self.report(.invalid_identifier_escape, .{ .start = escape_start, .end = self.pos });
                    return error.InvalidIdentifierEscape;
                }
                saw_escape.* = true;
                continue;
            }
            if (c < 0x80) {
                if (!idents.isAsciiIdentifierPart(c)) return;
                self.pos += 1;
                continue;
            }
            const dec = self.peekUtf8() catch return;
            if (!idents.isIdentifierPart(dec.cp)) return;
            self.pos += dec.len;
        }
    }

    /// Parse a `\u`-prefixed identifier escape and return the decoded
    /// codepoint. Caller is positioned at the leading `\`.
    fn parseIdentifierEscape(self: *Lexer) LexError!u21 {
        const escape_start = self.pos;
        if (self.pos + 1 >= self.source.len or self.source[self.pos + 1] != 'u') {
            try self.report(.invalid_escape_sequence, .{ .start = escape_start, .end = @min(self.pos + 2, @as(u32, @intCast(self.source.len))) });
            return error.InvalidEscapeSequence;
        }
        self.pos += 2; // consume `\u`
        return self.scanUnicodeEscape();
    }

    /// Decode the IdentifierName starting at `start` and ending at `self.pos`
    /// into its `StringValue` (UTF-8 encoded). Uses the caller-provided stack
    /// buffer when the result fits; otherwise allocates and stores the
    /// pointer in `heap_out` for the caller to free.
    fn identifierStringValue(
        self: *Lexer,
        start: u32,
        stack_buf: *[256]u8,
        heap_out: *?[]u8,
    ) LexError![]const u8 {
        const slice = self.source[start..self.pos];
        // Fast path: no escapes means the slice is already the StringValue.
        if (std.mem.indexOfScalar(u8, slice, '\\') == null) return slice;

        var len: usize = 0;
        var buf: []u8 = stack_buf[0..];
        var on_heap = false;

        var i: usize = 0;
        while (i < slice.len) {
            // A single source byte expands to at most 4 UTF-8 bytes (when the
            // byte is part of a `\u{...}` escape decoding to a non-BMP cp).
            if (len + 4 > buf.len) {
                const new_cap = buf.len * 2;
                const new_buf = try self.allocator.alloc(u8, new_cap);
                @memcpy(new_buf[0..len], buf[0..len]);
                if (on_heap) self.allocator.free(buf);
                buf = new_buf;
                on_heap = true;
                heap_out.* = buf;
            }
            if (slice[i] == '\\') {
                // Escape — the lexer already validated it; decode again.
                std.debug.assert(i + 1 < slice.len and slice[i + 1] == 'u');
                i += 2;
                var cp: u21 = 0;
                if (slice[i] == '{') {
                    i += 1;
                    while (slice[i] != '}') : (i += 1) cp = (cp << 4) | @as(u21, hexDigitValue(slice[i]));
                    i += 1; // consume '}'
                } else {
                    var n: usize = 0;
                    while (n < 4) : (n += 1) {
                        cp = (cp << 4) | @as(u21, hexDigitValue(slice[i + n]));
                    }
                    i += 4;
                }
                // The escape was already validated as IdentifierStart /
                // IdentifierPart, which excludes surrogates and codepoints
                // above 0x10FFFF — so utf8Encode cannot fail here.
                len += std.unicode.utf8Encode(cp, buf[len..]) catch unreachable;
            } else {
                buf[len] = slice[i];
                len += 1;
                i += 1;
            }
        }
        return buf[0..len];
    }

    // ── Template Literals (§12.8.6) ─────────────────────────────────────

    /// Scan a template literal opening at `` ` `` (when `is_continuation` is
    /// false) or `}` (when scanning a TemplateMiddle / TemplateTail after a
    /// substitution closes). Returns one of:
    /// • `.no_substitution_template` — `` `…` ``
    /// • `.template_head` — `` `…${ ``
    /// • `.template_middle` — `}…${`
    /// • `.template_tail` — `` }…` ``
    fn scanTemplate(self: *Lexer, start: u32, is_continuation: bool) LexError!Token {
        // Consume the opening delimiter — `` ` `` or `}`.
        self.pos += 1;
        return self.scanTemplateBody(start, is_continuation);
    }

    fn scanTemplateBody(self: *Lexer, start: u32, is_continuation: bool) LexError!Token {
        var had_invalid = false;
        while (self.pos < self.source.len) {
            const c = self.source[self.pos];
            switch (c) {
                '`' => {
                    self.pos += 1;
                    const kind: TokenKind = if (is_continuation) .template_tail else .no_substitution_template;
                    var tok = self.makeToken(kind, start);
                    tok.had_invalid_template_escape = had_invalid;
                    return tok;
                },
                '$' => {
                    if (self.pos + 1 < self.source.len and self.source[self.pos + 1] == '{') {
                        self.pos += 2;
                        const kind: TokenKind = if (is_continuation) .template_middle else .template_head;
                        var tok = self.makeToken(kind, start);
                        tok.had_invalid_template_escape = had_invalid;
                        return tok;
                    }
                    self.pos += 1;
                },
                '\\' => {
                    self.pos += 1;
                    // §12.8.6 — relaxed template escape consume. The
                    // lexer accepts the byte run; cook-time
                    // validation (or the standalone-template check
                    // in `parseTemplateLiteral`) flags invalid forms.
                    if (!self.consumeTemplateEscapeSequence()) had_invalid = true;
                },
                '\n' => {
                    self.pos += 1;
                    self.saw_line_terminator = true;
                },
                '\r' => {
                    self.pos += 1;
                    if (self.pos < self.source.len and self.source[self.pos] == '\n') self.pos += 1;
                    self.saw_line_terminator = true;
                },
                else => self.pos += 1,
            }
        }
        try self.report(.unterminated_template_literal, .{ .start = start, .end = self.pos });
        return error.UnterminatedTemplate;
    }

    /// §12.8.6 — non-reporting template escape consumer. Advances
    /// past one EscapeSequence-shaped run of source bytes and
    /// returns `true` if the escape is well-formed, `false`
    /// otherwise. Differs from `consumeEscapeSequence` in two ways:
    /// it never emits a diagnostic, and it never returns
    /// `error.InvalidEscapeSequence` (callers always need to keep
    /// scanning the template body). Tagged-template cook-time
    /// validation surfaces the SyntaxError when the value is read.
    fn consumeTemplateEscapeSequence(self: *Lexer) bool {
        if (self.pos >= self.source.len) return true;
        const esc = self.source[self.pos];
        self.pos += 1;
        switch (esc) {
            // SingleEscapeCharacter + NonEscapeCharacter, plus the
            // CR / LF LineContinuation forms — always valid.
            '\'', '"', '\\', 'b', 'f', 'n', 'r', 't', 'v', '\n' => return true,
            '\r' => {
                if (self.pos < self.source.len and self.source[self.pos] == '\n') self.pos += 1;
                return true;
            },
            // §12.8.4.1 — `\0` is legal iff not followed by a decimal
            // digit. `\1` … `\9` are LegacyOctalEscapeSequence /
            // NonOctalDecimalEscapeSequence — invalid in templates.
            '0' => {
                if (self.pos < self.source.len and isDecimalDigit(self.source[self.pos])) {
                    return false;
                }
                return true;
            },
            '1'...'9' => return false,
            // HexEscapeSequence `\xHH`.
            'x' => {
                if (self.pos + 2 > self.source.len or
                    !isHexDigit(self.source[self.pos]) or
                    !isHexDigit(self.source[self.pos + 1]))
                {
                    // Consume whatever non-template-delimiter bytes
                    // are there so scanning continues.
                    var n: usize = 0;
                    while (n < 2 and self.pos < self.source.len and
                        self.source[self.pos] != '`' and
                        self.source[self.pos] != '\\' and
                        self.source[self.pos] != '$') : (n += 1)
                    {
                        self.pos += 1;
                    }
                    return false;
                }
                self.pos += 2;
                return true;
            },
            // UnicodeEscapeSequence `\uHHHH` and `\u{H…}`.
            'u' => {
                if (self.pos < self.source.len and self.source[self.pos] == '{') {
                    const open = self.pos;
                    self.pos += 1;
                    var cp: u32 = 0;
                    var any = false;
                    var ok = true;
                    while (self.pos < self.source.len and self.source[self.pos] != '}') : (self.pos += 1) {
                        if (!isHexDigit(self.source[self.pos])) {
                            ok = false;
                            // skip to `}` / `\\` / template
                            // terminator so scanning continues.
                            break;
                        }
                        cp = (cp << 4) | hexDigitValue(self.source[self.pos]);
                        any = true;
                    }
                    if (self.pos < self.source.len and self.source[self.pos] == '}') self.pos += 1;
                    _ = open;
                    if (!ok or !any or cp > 0x10FFFF) return false;
                    return true;
                }
                if (self.pos + 4 > self.source.len) return false;
                var n: usize = 0;
                while (n < 4 and self.pos < self.source.len) : (n += 1) {
                    if (!isHexDigit(self.source[self.pos])) return false;
                    self.pos += 1;
                }
                return true;
            },
            // NonEscapeCharacter — any SourceCharacter that isn't a
            // reserved EscapeCharacter / LineTerminator. Stands for
            // itself.
            else => return true,
        }
    }

    /// Re-enter template-literal scanning after the parser has *already*
    /// consumed the closing `}` of a substitution as a regular `.rbrace`
    /// token. The caller passes the `}` token's span start so the resulting
    /// `template_middle` / `template_tail` covers `} … ${` or `} … `` ` ``.
    /// `lex.pos` is expected to be just past `}`.
    pub fn nextTemplateContinuationAfterBrace(self: *Lexer, brace_start: u32) LexError!Token {
        self.saw_line_terminator = false;
        return self.scanTemplateBody(brace_start, true);
    }

    /// §12.9.5 RegularExpressionLiteral — parser-driven goal selection
    /// (§12.8 InputElementRegExp). The parser calls this when it sees a
    /// `/` or `/=` token in PrimaryExpression position. We rewind the
    /// lexer to the slash and rescan as a regex.
    pub fn rescanAsRegex(self: *Lexer, slash_start: u32) LexError!Token {
        self.pos = slash_start;
        self.saw_line_terminator = false;
        std.debug.assert(self.pos < self.source.len and self.source[self.pos] == '/');
        self.pos += 1; // consume opening `/`
        var in_class = false;
        while (self.pos < self.source.len) {
            const c = self.source[self.pos];
            if (c == '\\') {
                self.pos += 1;
                // §12.9.5 — `\` may not be followed by a
                // LineTerminator (no LineContinuation in regex
                // literals). LF, CR, and the 3-byte UTF-8 forms of
                // <LS> / <PS> are all SyntaxErrors.
                const followed_by_lt = self.pos >= self.source.len or
                    self.source[self.pos] == '\n' or
                    self.source[self.pos] == '\r' or
                    (self.source[self.pos] == 0xE2 and self.pos + 2 < self.source.len and
                        self.source[self.pos + 1] == 0x80 and
                        (self.source[self.pos + 2] == 0xA8 or self.source[self.pos + 2] == 0xA9));
                if (!followed_by_lt) {
                    self.pos += 1;
                    continue;
                }
                try self.report(.unterminated_regex_literal, .{ .start = slash_start, .end = self.pos });
                return error.UnterminatedString;
            } else if (c == '[' and !in_class) {
                in_class = true;
                self.pos += 1;
                continue;
            } else if (c == ']' and in_class) {
                in_class = false;
                self.pos += 1;
                continue;
            } else if (c == '/' and !in_class) {
                self.pos += 1;
                // §12.9.5 RegularExpressionFlags — IdentifierPartChar*.
                while (self.pos < self.source.len) {
                    const f = self.source[self.pos];
                    if (f < 0x80 and idents.isAsciiIdentifierPart(f)) {
                        self.pos += 1;
                    } else break;
                }
                return self.makeToken(.regular_expression_literal, slash_start);
            } else if (c == '\n' or c == '\r') {
                try self.report(.unterminated_regex_literal, .{ .start = slash_start, .end = self.pos });
                return error.UnterminatedString;
            } else if (c == 0xE2 and self.pos + 2 < self.source.len and
                self.source[self.pos + 1] == 0x80 and
                (self.source[self.pos + 2] == 0xA8 or self.source[self.pos + 2] == 0xA9))
            {
                // §12.9.5 — U+2028 (<LS>) and U+2029 (<PS>) are
                // LineTerminators; their presence inside a regex
                // literal body terminates the literal unterminated.
                try self.report(.unterminated_regex_literal, .{ .start = slash_start, .end = self.pos });
                return error.UnterminatedString;
            }
            self.pos += 1;
        }
        try self.report(.unterminated_regex_literal, .{ .start = slash_start, .end = self.pos });
        return error.UnterminatedString;
    }

    /// Consume an escape sequence body after the leading `\`. Pos is at the
    /// character following `\`. Validates against strict-mode escape rules:
    /// rejects LegacyOctalEscapeSequence and NonOctalDecimalEscapeSequence.
    /// Shared between string-literal and template scanners.
    fn consumeEscapeSequence(self: *Lexer) LexError!void {
        if (self.pos >= self.source.len) return;
        const esc = self.source[self.pos];
        self.pos += 1;
        switch (esc) {
            // SingleEscapeCharacter (§12.8.4) plus NonEscapeCharacter that
            // stand for themselves — handled implicitly by `else`.
            '\'', '"', '\\', 'b', 'f', 'n', 'r', 't', 'v' => {},
            // LineContinuation (§12.8.4): backslash + LineTerminatorSequence.
            '\n' => {},
            '\r' => {
                if (self.pos < self.source.len and self.source[self.pos] == '\n') self.pos += 1;
            },
            // NullEscape — legal only when not followed by a DecimalDigit.
            '0' => {
                if (self.pos < self.source.len and isDecimalDigit(self.source[self.pos])) {
                    try self.report(.invalid_escape_sequence, .{ .start = self.pos - 2, .end = self.pos });
                    return error.InvalidEscapeSequence;
                }
            },
            // HexEscapeSequence: \xHH
            'x' => {
                if (self.pos + 2 > self.source.len or
                    !isHexDigit(self.source[self.pos]) or
                    !isHexDigit(self.source[self.pos + 1]))
                {
                    const end_off: u32 = @min(self.pos + 2, @as(u32, @intCast(self.source.len)));
                    try self.report(.invalid_escape_sequence, .{ .start = self.pos - 2, .end = end_off });
                    return error.InvalidEscapeSequence;
                }
                self.pos += 2;
            },
            // UnicodeEscapeSequence: \uHHHH or \u{H...}
            'u' => _ = try self.scanUnicodeEscape(),
            // LegacyOctalEscapeSequence and NonOctalDecimalEscapeSequence are
            // forbidden in strict mode (§B.1.2 + §12.8.4.1, §12.8.6).
            '1'...'9' => {
                try self.report(.invalid_escape_sequence, .{ .start = self.pos - 2, .end = self.pos });
                return error.InvalidEscapeSequence;
            },
            // NonEscapeCharacter — any SourceCharacter that isn't an
            // EscapeCharacter / LineTerminator. Stands for itself.
            else => {},
        }
    }

    /// Re-enter template-literal scanning after the parser has consumed the
    /// substitution expression and the closing `}` is the next byte. Returns
    /// either `.template_middle` or `.template_tail`.
    pub fn nextTemplateContinuation(self: *Lexer) LexError!Token {
        self.saw_line_terminator = false;
        const start = self.pos;
        std.debug.assert(self.pos < self.source.len and self.source[self.pos] == '}');
        return self.scanTemplate(start, true);
    }

    // ── UTF-8 helpers ───────────────────────────────────────────────────

    /// Decode a UTF-8 codepoint at `self.pos` without advancing. Returns the
    /// codepoint and the number of source bytes it consumed.
    fn peekUtf8(self: *const Lexer) !struct { cp: u21, len: u3 } {
        const b0 = self.source[self.pos];
        const len = try std.unicode.utf8ByteSequenceLength(b0);
        if (self.pos + len > self.source.len) return error.Utf8ExpectedContinuation;
        const cp = try std.unicode.utf8Decode(self.source[self.pos..][0..len]);
        return .{ .cp = cp, .len = len };
    }

    // ── Numeric Literals ────────────────────────────────────────────────

    fn scanNumericLiteral(self: *Lexer, start: u32) LexError!Token {
        const c = self.source[self.pos];
        if (c == '0' and self.pos + 1 < self.source.len) {
            const n = self.source[self.pos + 1];
            switch (n) {
                'x', 'X' => return self.scanRadixLiteral(start, isHexDigit),
                'o', 'O' => return self.scanRadixLiteral(start, isOctalDigit),
                'b', 'B' => return self.scanRadixLiteral(start, isBinaryDigit),
                '0'...'9' => {
                    // §B.1.1 LegacyOctalIntegerLiteral / NonOctalDecimalIntegerLiteral
                    // are forbidden in strict mode. Consume the run for recovery,
                    // then report.
                    while (self.pos < self.source.len and isDecimalDigit(self.source[self.pos])) {
                        self.pos += 1;
                    }
                    try self.report(.legacy_octal_in_strict, .{ .start = start, .end = self.pos });
                    return error.InvalidNumericLiteral;
                },
                else => {},
            }
        }
        return self.scanDecimalLiteral(start);
    }

    fn scanRadixLiteral(
        self: *Lexer,
        start: u32,
        comptime isDigit: fn (u8) bool,
    ) LexError!Token {
        self.pos += 2; // 0x / 0o / 0b
        // §12.8.3 — `0x`/`0o`/`0b` may not be immediately followed by
        // `_`, and the digit run rejects doubled / trailing separators.
        try self.scanDigitRun(start, true, isDigit);
        // BigInt suffix (§12.8.3): 0xFFn / 0o7n / 0b1n. The digit run
        // already rejects trailing `_`, so `0x1_n` is caught above.
        if (self.pos < self.source.len and self.source[self.pos] == 'n') {
            self.pos += 1;
            try self.checkNumericTrailingIdent(start);
            return self.makeToken(.bigint_literal, start);
        }
        try self.checkNumericTrailingIdent(start);
        return self.makeToken(.numeric_literal, start);
    }

    fn scanDecimalLiteral(self: *Lexer, start: u32) LexError!Token {
        // §12.8.3 DecimalLiteral / DecimalIntegerLiteral / DecimalBigIntegerLiteral
        // Integer part:
        if (self.pos < self.source.len and self.source[self.pos] == '0') {
            // `0` is a DecimalIntegerLiteral on its own; the grammar
            // never extends it with separators or more digits, so the
            // trailing-ident check below catches `0_…` and `0n` (BigInt
            // continues separately).
            self.pos += 1;
        } else if (self.pos < self.source.len and self.source[self.pos] == '.') {
            // `.5` — leading-dot DecimalLiteral with no integer part.
            // Fraction scan handles the rest below; nothing to do here.
        } else {
            try self.scanDigitRun(start, true, isDecimalDigit);
        }
        var saw_dot = false;
        var saw_exp = false;
        // Fraction:
        if (self.pos < self.source.len and self.source[self.pos] == '.') {
            saw_dot = true;
            self.pos += 1;
            // §12.8.3 — `.` may be followed by a (possibly-empty) digit
            // run; `_` immediately after `.` is disallowed.
            try self.scanDigitRun(start, false, isDecimalDigit);
        }
        // Exponent:
        if (self.pos < self.source.len and (self.source[self.pos] == 'e' or self.source[self.pos] == 'E')) {
            saw_exp = true;
            self.pos += 1;
            if (self.pos < self.source.len and (self.source[self.pos] == '+' or self.source[self.pos] == '-')) {
                self.pos += 1;
            }
            // SignedInteger expands to DecimalDigits which permits
            // NumericLiteralSeparator. `_` immediately after `e`/`E`/
            // sign is rejected by the digit run.
            try self.scanDigitRun(start, true, isDecimalDigit);
        }
        // BigInt suffix is only valid on integer literals (no dot, no exponent).
        if (self.pos < self.source.len and self.source[self.pos] == 'n') {
            if (saw_dot or saw_exp) {
                try self.report(.invalid_numeric_literal, .{ .start = start, .end = self.pos + 1 });
                self.pos += 1;
                return error.InvalidNumericLiteral;
            }
            self.pos += 1;
            try self.checkNumericTrailingIdent(start);
            return self.makeToken(.bigint_literal, start);
        }
        try self.checkNumericTrailingIdent(start);
        return self.makeToken(.numeric_literal, start);
    }

    /// §12.8.3 NumericLiteralSeparator — consume one digit run, with
    /// optional `_` between digits. Rejects leading `_`, doubled `__`,
    /// and trailing `_`. With `require_one == true` the run must
    /// contain at least one digit.
    fn scanDigitRun(
        self: *Lexer,
        start: u32,
        require_one: bool,
        comptime isDigit: fn (u8) bool,
    ) LexError!void {
        // `_` may not appear as the first character of a digit run.
        if (self.pos < self.source.len and self.source[self.pos] == '_') {
            try self.report(.invalid_numeric_literal, .{ .start = self.pos, .end = self.pos + 1 });
            return error.InvalidNumericLiteral;
        }
        if (require_one and
            (self.pos >= self.source.len or !isDigit(self.source[self.pos])))
        {
            try self.report(.invalid_numeric_literal, .{ .start = start, .end = self.pos });
            return error.InvalidNumericLiteral;
        }
        var prev_sep = false;
        var any_digit = false;
        while (self.pos < self.source.len) {
            const c = self.source[self.pos];
            if (isDigit(c)) {
                any_digit = true;
                prev_sep = false;
                self.pos += 1;
            } else if (c == '_') {
                // Doubled separator (`__`) is rejected, as is `_`
                // appearing before any digit has been seen.
                if (prev_sep or !any_digit) {
                    try self.report(.invalid_numeric_literal, .{ .start = self.pos, .end = self.pos + 1 });
                    return error.InvalidNumericLiteral;
                }
                prev_sep = true;
                self.pos += 1;
            } else break;
        }
        if (prev_sep) {
            // Trailing separator — `1_`, `1_n`, `1.0e1_`, etc.
            try self.report(.invalid_numeric_literal, .{ .start = self.pos - 1, .end = self.pos });
            return error.InvalidNumericLiteral;
        }
    }

    /// Per §12.8.3, a NumericLiteral cannot be immediately followed by an
    /// IdentifierStart or DecimalDigit (e.g. `3in` is a SyntaxError).
    fn checkNumericTrailingIdent(self: *Lexer, start: u32) LexError!void {
        if (self.pos >= self.source.len) return;
        const c = self.source[self.pos];
        const bad = switch (c) {
            'a'...'z', 'A'...'Z', '_', '$', '0'...'9' => true,
            else => false,
        };
        if (bad) {
            try self.report(.invalid_numeric_literal, .{ .start = start, .end = self.pos + 1 });
            return error.InvalidNumericLiteral;
        }
    }

    fn isDecimalDigit(c: u8) bool {
        return c >= '0' and c <= '9';
    }
    fn isHexDigit(c: u8) bool {
        return (c >= '0' and c <= '9') or (c >= 'a' and c <= 'f') or (c >= 'A' and c <= 'F');
    }
    fn isOctalDigit(c: u8) bool {
        return c >= '0' and c <= '7';
    }
    fn isBinaryDigit(c: u8) bool {
        return c == '0' or c == '1';
    }

    // ── String Literals ─────────────────────────────────────────────────

    fn scanStringLiteral(self: *Lexer, start: u32, quote: u8) LexError!Token {
        // §12.8.4. We validate escape sequences but keep the raw bytes; the
        // parser/runtime materializes the StringValue lazily.
        self.pos += 1; // opening quote
        while (self.pos < self.source.len) {
            const c = self.source[self.pos];
            if (c == quote) {
                self.pos += 1;
                return self.makeToken(.string_literal, start);
            }
            if (c == '\n' or c == '\r') break; // unterminated
            if (c == '\\') {
                self.pos += 1;
                if (self.pos >= self.source.len) break;
                try self.consumeEscapeSequence();
            } else {
                self.pos += 1;
            }
        }
        try self.report(.unterminated_string_literal, .{ .start = start, .end = self.pos });
        return error.UnterminatedString;
    }

    /// Scan a `\uHHHH` or `\u{H...}` escape and return the decoded codepoint.
    /// Caller has consumed `\u`; the diagnostic span includes that prefix at
    /// `self.pos - 2`. Returns the codepoint as u21 — the maximum legal value
    /// is 0x10FFFF.
    fn scanUnicodeEscape(self: *Lexer) LexError!u21 {
        if (self.pos < self.source.len and self.source[self.pos] == '{') {
            self.pos += 1;
            const start_digits = self.pos;
            var cp: u32 = 0;
            while (self.pos < self.source.len and isHexDigit(self.source[self.pos])) {
                cp = (cp << 4) | hexDigitValue(self.source[self.pos]);
                if (cp > 0x10FFFF) {
                    try self.report(.invalid_escape_sequence, .{ .start = self.pos - 2, .end = self.pos + 1 });
                    return error.InvalidEscapeSequence;
                }
                self.pos += 1;
            }
            if (self.pos == start_digits or self.pos >= self.source.len or self.source[self.pos] != '}') {
                try self.report(.invalid_escape_sequence, .{ .start = self.pos - 2, .end = self.pos });
                return error.InvalidEscapeSequence;
            }
            self.pos += 1;
            return @intCast(cp);
        }
        if (self.pos + 4 > self.source.len) {
            try self.report(.invalid_escape_sequence, .{ .start = self.pos - 2, .end = @intCast(self.source.len) });
            return error.InvalidEscapeSequence;
        }
        var cp: u21 = 0;
        var i: u32 = 0;
        while (i < 4) : (i += 1) {
            const c = self.source[self.pos + i];
            if (!isHexDigit(c)) {
                try self.report(.invalid_escape_sequence, .{ .start = self.pos - 2, .end = self.pos + i });
                return error.InvalidEscapeSequence;
            }
            cp = (cp << 4) | @as(u21, hexDigitValue(c));
        }
        self.pos += 4;
        return cp;
    }

    fn hexDigitValue(c: u8) u8 {
        return switch (c) {
            '0'...'9' => c - '0',
            'a'...'f' => c - 'a' + 10,
            'A'...'F' => c - 'A' + 10,
            else => unreachable,
        };
    }

    // ── Punctuators ─────────────────────────────────────────────────────

    /// Look at `self.source[self.pos + off]`, returning 0 past EOF. Useful
    /// for one-shot lookahead inside punctuator dispatch.
    fn peekByte(self: *const Lexer, off: u32) u8 {
        return if (self.pos + off < self.source.len) self.source[self.pos + off] else 0;
    }

    fn scanPunctuator(self: *Lexer, start: u32) LexError!Token {
        const c = self.source[self.pos];
        switch (c) {
            '{' => {
                self.pos += 1;
                return self.makeToken(.lbrace, start);
            },
            '}' => {
                self.pos += 1;
                return self.makeToken(.rbrace, start);
            },
            '(' => {
                self.pos += 1;
                return self.makeToken(.lparen, start);
            },
            ')' => {
                self.pos += 1;
                return self.makeToken(.rparen, start);
            },
            '[' => {
                self.pos += 1;
                return self.makeToken(.lbracket, start);
            },
            ']' => {
                self.pos += 1;
                return self.makeToken(.rbracket, start);
            },
            ';' => {
                self.pos += 1;
                return self.makeToken(.semicolon, start);
            },
            ',' => {
                self.pos += 1;
                return self.makeToken(.comma, start);
            },
            '~' => {
                self.pos += 1;
                return self.makeToken(.tilde, start);
            },
            ':' => {
                self.pos += 1;
                return self.makeToken(.colon, start);
            },

            '.' => {
                // `.` `...` or DecimalLiteral starting with `.`
                const a = self.peekByte(1);
                if (a >= '0' and a <= '9') return self.scanDecimalLiteral(start);
                if (a == '.' and self.peekByte(2) == '.') {
                    self.pos += 3;
                    return self.makeToken(.ellipsis, start);
                }
                self.pos += 1;
                return self.makeToken(.dot, start);
            },

            '?' => {
                if (self.peekByte(1) == '?') {
                    if (self.peekByte(2) == '=') {
                        self.pos += 3;
                        return self.makeToken(.question_question_eq, start);
                    }
                    self.pos += 2;
                    return self.makeToken(.question_question, start);
                }
                if (self.peekByte(1) == '.') {
                    // OptionalChainPunctuator only when not followed by a DecimalDigit
                    // (§12.7.1 — `1?.2:3` keeps `?` as conditional).
                    const after = self.peekByte(2);
                    if (!(after >= '0' and after <= '9')) {
                        self.pos += 2;
                        return self.makeToken(.optional_chain, start);
                    }
                }
                self.pos += 1;
                return self.makeToken(.question, start);
            },

            '<' => {
                if (self.peekByte(1) == '=') {
                    self.pos += 2;
                    return self.makeToken(.le, start);
                }
                if (self.peekByte(1) == '<') {
                    if (self.peekByte(2) == '=') {
                        self.pos += 3;
                        return self.makeToken(.lt_lt_eq, start);
                    }
                    self.pos += 2;
                    return self.makeToken(.lt_lt, start);
                }
                self.pos += 1;
                return self.makeToken(.lt, start);
            },
            '>' => {
                if (self.peekByte(1) == '=') {
                    self.pos += 2;
                    return self.makeToken(.ge, start);
                }
                if (self.peekByte(1) == '>') {
                    if (self.peekByte(2) == '>') {
                        if (self.peekByte(3) == '=') {
                            self.pos += 4;
                            return self.makeToken(.gt_gt_gt_eq, start);
                        }
                        self.pos += 3;
                        return self.makeToken(.gt_gt_gt, start);
                    }
                    if (self.peekByte(2) == '=') {
                        self.pos += 3;
                        return self.makeToken(.gt_gt_eq, start);
                    }
                    self.pos += 2;
                    return self.makeToken(.gt_gt, start);
                }
                self.pos += 1;
                return self.makeToken(.gt, start);
            },

            '=' => {
                if (self.peekByte(1) == '=') {
                    if (self.peekByte(2) == '=') {
                        self.pos += 3;
                        return self.makeToken(.eq_eq_eq, start);
                    }
                    self.pos += 2;
                    return self.makeToken(.eq_eq, start);
                }
                if (self.peekByte(1) == '>') {
                    self.pos += 2;
                    return self.makeToken(.arrow, start);
                }
                self.pos += 1;
                return self.makeToken(.eq, start);
            },
            '!' => {
                if (self.peekByte(1) == '=') {
                    if (self.peekByte(2) == '=') {
                        self.pos += 3;
                        return self.makeToken(.bang_eq_eq, start);
                    }
                    self.pos += 2;
                    return self.makeToken(.bang_eq, start);
                }
                self.pos += 1;
                return self.makeToken(.bang, start);
            },

            '+' => {
                if (self.peekByte(1) == '+') {
                    self.pos += 2;
                    return self.makeToken(.plus_plus, start);
                }
                if (self.peekByte(1) == '=') {
                    self.pos += 2;
                    return self.makeToken(.plus_eq, start);
                }
                self.pos += 1;
                return self.makeToken(.plus, start);
            },
            '-' => {
                if (self.peekByte(1) == '-') {
                    self.pos += 2;
                    return self.makeToken(.minus_minus, start);
                }
                if (self.peekByte(1) == '=') {
                    self.pos += 2;
                    return self.makeToken(.minus_eq, start);
                }
                self.pos += 1;
                return self.makeToken(.minus, start);
            },
            '*' => {
                if (self.peekByte(1) == '*') {
                    if (self.peekByte(2) == '=') {
                        self.pos += 3;
                        return self.makeToken(.star_star_eq, start);
                    }
                    self.pos += 2;
                    return self.makeToken(.star_star, start);
                }
                if (self.peekByte(1) == '=') {
                    self.pos += 2;
                    return self.makeToken(.star_eq, start);
                }
                self.pos += 1;
                return self.makeToken(.star, start);
            },
            '%' => {
                if (self.peekByte(1) == '=') {
                    self.pos += 2;
                    return self.makeToken(.percent_eq, start);
                }
                self.pos += 1;
                return self.makeToken(.percent, start);
            },
            '/' => {
                // `/` may begin a RegularExpressionLiteral or a DivPunctuator.
                // The parser disambiguates per §12.8 (InputElementDiv vs
                // InputElementRegExp). The lexer emits Div here; goal-driven
                // retokenization is on the roadmap.
                if (self.peekByte(1) == '=') {
                    self.pos += 2;
                    return self.makeToken(.slash_eq, start);
                }
                self.pos += 1;
                return self.makeToken(.slash, start);
            },
            '&' => {
                if (self.peekByte(1) == '&') {
                    if (self.peekByte(2) == '=') {
                        self.pos += 3;
                        return self.makeToken(.amp_amp_eq, start);
                    }
                    self.pos += 2;
                    return self.makeToken(.amp_amp, start);
                }
                if (self.peekByte(1) == '=') {
                    self.pos += 2;
                    return self.makeToken(.amp_eq, start);
                }
                self.pos += 1;
                return self.makeToken(.amp, start);
            },
            '|' => {
                if (self.peekByte(1) == '|') {
                    if (self.peekByte(2) == '=') {
                        self.pos += 3;
                        return self.makeToken(.pipe_pipe_eq, start);
                    }
                    self.pos += 2;
                    return self.makeToken(.pipe_pipe, start);
                }
                if (self.peekByte(1) == '=') {
                    self.pos += 2;
                    return self.makeToken(.pipe_eq, start);
                }
                self.pos += 1;
                return self.makeToken(.pipe, start);
            },
            '^' => {
                if (self.peekByte(1) == '=') {
                    self.pos += 2;
                    return self.makeToken(.caret_eq, start);
                }
                self.pos += 1;
                return self.makeToken(.caret, start);
            },

            '#' => return self.scanPrivateIdentifier(start),

            else => {
                self.pos += 1;
                try self.report(.unexpected_character, .{ .start = start, .end = self.pos });
                return error.UnexpectedCharacter;
            },
        }
    }

    fn scanPrivateIdentifier(self: *Lexer, start: u32) LexError!Token {
        // §13.1 PrivateIdentifier :: # IdentifierName
        std.debug.assert(self.source[self.pos] == '#');
        self.pos += 1;
        if (self.pos >= self.source.len) {
            try self.report(.unexpected_character, .{ .start = start, .end = self.pos });
            return error.UnexpectedCharacter;
        }
        var saw_escape = false;
        try self.scanIdentifierStart(self.pos, &saw_escape);
        try self.scanIdentifierTail(&saw_escape);
        // PrivateIdentifier never matches a ReservedWord (the leading `#`
        // makes it a distinct production), so escape-in-reserved-word does
        // not apply here.
        return self.makeToken(.private_identifier, start);
    }

    // ── Helpers ─────────────────────────────────────────────────────────

    fn makeToken(self: *Lexer, kind: TokenKind, start: u32) Token {
        return .{
            .kind = kind,
            .span = .{ .start = start, .end = self.pos },
            .line_terminator_before = self.saw_line_terminator,
        };
    }

    fn report(self: *Lexer, code: Code, span: Span) LexError!void {
        if (self.diagnostics) |list| {
            try list.append(self.allocator, .{
                .severity = .err,
                .code = code,
                .span = span,
            });
        }
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

fn expectKinds(source: []const u8, expected: []const TokenKind) !void {
    var lex = Lexer.init(testing.allocator, source);
    for (expected) |kind| {
        const tok = try lex.next();
        try testing.expectEqual(kind, tok.kind);
    }
    const eof = try lex.next();
    try testing.expectEqual(TokenKind.eof, eof.kind);
}

test "Lexer: empty source -> eof" {
    try expectKinds("", &.{});
}

test "Lexer: simple punctuators" {
    try expectKinds("(){}[];,:?", &.{
        .lparen,   .rparen,    .lbrace, .rbrace, .lbracket,
        .rbracket, .semicolon, .comma,  .colon,  .question,
    });
}

test "Lexer: long-form punctuators" {
    try expectKinds("=== !== >>> >>>= **= ??= ?. ...", &.{
        .eq_eq_eq,     .bang_eq_eq,           .gt_gt_gt,       .gt_gt_gt_eq,
        .star_star_eq, .question_question_eq, .optional_chain, .ellipsis,
    });
}

test "Lexer: identifiers and keywords" {
    try expectKinds("let x = 1; const y = 2;", &.{
        .kw_let,   .identifier, .eq, .numeric_literal, .semicolon,
        .kw_const, .identifier, .eq, .numeric_literal, .semicolon,
    });
}

test "Lexer: strict-only future reserved words are reserved" {
    try expectKinds("interface package private public protected implements static yield", &.{
        .kw_interface, .kw_package,    .kw_private, .kw_public,
        .kw_protected, .kw_implements, .kw_static,  .kw_yield,
    });
}

test "Lexer: numeric literals (decimal / hex / octal / binary / BigInt)" {
    try expectKinds("0 1 1.5 .5 1e10 1.5E-3 0xFF 0o17 0b1010 42n 0xFFn", &.{
        .numeric_literal, .numeric_literal, .numeric_literal, .numeric_literal,
        .numeric_literal, .numeric_literal, .numeric_literal, .numeric_literal,
        .numeric_literal, .bigint_literal,  .bigint_literal,
    });
}

test "Lexer: legacy octal integer literal is rejected in strict mode" {
    var lex = Lexer.init(testing.allocator, "0755");
    try testing.expectError(error.InvalidNumericLiteral, lex.next());
}

test "Lexer: trailing identifier on numeric literal is rejected" {
    var lex = Lexer.init(testing.allocator, "3in");
    try testing.expectError(error.InvalidNumericLiteral, lex.next());
}

test "Lexer: BigInt with fraction is rejected" {
    var lex = Lexer.init(testing.allocator, "1.5n");
    try testing.expectError(error.InvalidNumericLiteral, lex.next());
}

test "Lexer: string literals (simple, escapes, line continuation)" {
    try expectKinds("\"hello\" 'world' \"a\\nb\" '\\u0041' '\\x4A'", &.{
        .string_literal, .string_literal, .string_literal,
        .string_literal, .string_literal,
    });
}

test "Lexer: unterminated string is reported" {
    var lex = Lexer.init(testing.allocator, "\"oops");
    try testing.expectError(error.UnterminatedString, lex.next());
}

test "Lexer: legacy octal escape `\\17` is rejected in strict mode" {
    var lex = Lexer.init(testing.allocator, "'\\17'");
    try testing.expectError(error.InvalidEscapeSequence, lex.next());
}

test "Lexer: comments are skipped, line terminator tracked" {
    var lex = Lexer.init(testing.allocator, "a // line\nb /* block\nblock */ c");
    const a = try lex.next();
    try testing.expectEqual(TokenKind.identifier, a.kind);
    try testing.expect(!a.line_terminator_before);

    const b = try lex.next();
    try testing.expectEqual(TokenKind.identifier, b.kind);
    try testing.expect(b.line_terminator_before);

    const c = try lex.next();
    try testing.expectEqual(TokenKind.identifier, c.kind);
    try testing.expect(c.line_terminator_before);
}

test "Lexer: unterminated multi-line comment is reported" {
    var lex = Lexer.init(testing.allocator, "/* never closes");
    try testing.expectError(error.UnterminatedComment, lex.next());
}

test "Lexer: NBSP (U+00A0) is whitespace" {
    // §11.2: <USP> includes Space_Separator code points; U+00A0 is one.
    // UTF-8: 0xC2 0xA0.
    try expectKinds("a\xC2\xA0b", &.{ .identifier, .identifier });
}

test "Lexer: ZWNBSP (U+FEFF) is whitespace" {
    // §11.2: <ZWNBSP> is whitespace at any position (not only the BOM).
    // UTF-8: 0xEF 0xBB 0xBF.
    try expectKinds("a\xEF\xBB\xBFb", &.{ .identifier, .identifier });
}

test "Lexer: ideographic space (U+3000) is whitespace" {
    // §11.2: U+3000 is Space_Separator.
    // UTF-8: 0xE3 0x80 0x80.
    try expectKinds("a\xE3\x80\x80b", &.{ .identifier, .identifier });
}

test "Lexer: U+2028 line separator is a LineTerminator" {
    // §11.3: <LS> is a LineTerminator. UTF-8: 0xE2 0x80 0xA8.
    var lex = Lexer.init(testing.allocator, "a\xE2\x80\xA8b");
    const a = try lex.next();
    try testing.expectEqual(TokenKind.identifier, a.kind);
    const b = try lex.next();
    try testing.expectEqual(TokenKind.identifier, b.kind);
    try testing.expect(b.line_terminator_before);
}

test "Lexer: U+2029 paragraph separator is a LineTerminator" {
    // §11.3: <PS> is a LineTerminator. UTF-8: 0xE2 0x80 0xA9.
    var lex = Lexer.init(testing.allocator, "a\xE2\x80\xA9b");
    const a = try lex.next();
    try testing.expectEqual(TokenKind.identifier, a.kind);
    const b = try lex.next();
    try testing.expectEqual(TokenKind.identifier, b.kind);
    try testing.expect(b.line_terminator_before);
}

test "Lexer: multi-line comment containing U+2028 acts as LineTerminator" {
    // §11.4: a multi-line comment containing a LineTerminator code
    // point is itself a LineTerminator for syntactic purposes (this
    // is what ASI relies on).
    var lex = Lexer.init(testing.allocator, "a /* \xE2\x80\xA8 */ b");
    const a = try lex.next();
    try testing.expectEqual(TokenKind.identifier, a.kind);
    const b = try lex.next();
    try testing.expectEqual(TokenKind.identifier, b.kind);
    try testing.expect(b.line_terminator_before);
}

test "Lexer: private identifiers" {
    try expectKinds("#foo #bar123", &.{ .private_identifier, .private_identifier });
}

test "Lexer: optional chain vs ternary on numeric" {
    // `?.` is a punctuator unless followed by a digit.
    try expectKinds("a?.b", &.{ .identifier, .optional_chain, .identifier });
    // `1?.5` is `1`, `?`, `.5`
    try expectKinds("1?.5:0", &.{
        .numeric_literal, .question, .numeric_literal, .colon, .numeric_literal,
    });
}

test "Lexer: arrow function token" {
    try expectKinds("() => 1", &.{ .lparen, .rparen, .arrow, .numeric_literal });
}

test "Lexer: diagnostics are recorded into the sink when provided" {
    var diags: Diagnostics = .empty;
    defer diags.deinit(testing.allocator);

    var lex = Lexer.init(testing.allocator, "0755");
    lex.diagnostics = &diags;
    try testing.expectError(error.InvalidNumericLiteral, lex.next());
    try testing.expectEqual(@as(usize, 1), diags.items.len);
    try testing.expectEqual(Code.legacy_octal_in_strict, diags.items[0].code);
}

// ── Unicode identifiers + `\u` escapes (§12.7) ──────────────────────────

fn expectFirstIdentSlice(src: []const u8, expected_slice: []const u8) !void {
    var lex = Lexer.init(testing.allocator, src);
    const tok = try lex.next();
    try testing.expectEqual(TokenKind.identifier, tok.kind);
    try testing.expectEqualSlices(u8, expected_slice, tok.slice(src));
}

test "Lexer: Greek identifier (BMP non-ASCII)" {
    // const πι = 3;
    try expectKinds("const πι = 3;", &.{
        .kw_const, .identifier, .eq, .numeric_literal, .semicolon,
    });
    try expectFirstIdentSlice("πι;", "πι");
}

test "Lexer: CJK identifier (BMP)" {
    try expectKinds("let 名前 = 1;", &.{
        .kw_let, .identifier, .eq, .numeric_literal, .semicolon,
    });
}

test "Lexer: non-BMP identifier (Old Italic)" {
    // U+10300 (𐌀) — encoded as 4 UTF-8 bytes.
    try expectFirstIdentSlice("𐌀foo;", "𐌀foo");
}

test "Lexer: ZWJ inside identifier" {
    // foo<ZWJ>bar — ZWJ is U+200D.
    const src = "foo\u{200D}bar;";
    try expectFirstIdentSlice(src, "foo\u{200D}bar");
}

test "Lexer: ZWJ at identifier start is rejected" {
    var diags: Diagnostics = .empty;
    defer diags.deinit(testing.allocator);
    var lex = Lexer.init(testing.allocator, "\u{200D}foo");
    lex.diagnostics = &diags;
    try testing.expectError(error.UnexpectedCharacter, lex.next());
    try testing.expectEqual(@as(usize, 1), diags.items.len);
    try testing.expectEqual(Code.unexpected_character, diags.items[0].code);
}

test "Lexer: \\u{...} escape at identifier start" {
    // \u{66}oo === "foo"
    try expectFirstIdentSlice("\\u{66}oo;", "\\u{66}oo");
}

test "Lexer: \\uHHHH escape at identifier start" {
    try expectFirstIdentSlice("\\u0066oo;", "\\u0066oo");
}

test "Lexer: \\u escape mid-identifier" {
    try expectFirstIdentSlice("f\\u006Fo;", "f\\u006Fo");
}

test "Lexer: \\u escape decoding to non-IdentifierStart at start" {
    // \u{30} === '0' (ID_Continue but not ID_Start).
    var diags: Diagnostics = .empty;
    defer diags.deinit(testing.allocator);
    var lex = Lexer.init(testing.allocator, "\\u{30}abc");
    lex.diagnostics = &diags;
    try testing.expectError(error.InvalidIdentifierEscape, lex.next());
    try testing.expectEqual(@as(usize, 1), diags.items.len);
    try testing.expectEqual(Code.invalid_identifier_escape, diags.items[0].code);
}

test "Lexer: \\u escape decoding to non-IdentifierPart mid-identifier" {
    // \u{20} === ' ' — not in IdentifierPart.
    var diags: Diagnostics = .empty;
    defer diags.deinit(testing.allocator);
    var lex = Lexer.init(testing.allocator, "foo\\u{20}bar");
    lex.diagnostics = &diags;
    try testing.expectError(error.InvalidIdentifierEscape, lex.next());
    try testing.expectEqual(@as(usize, 1), diags.items.len);
    try testing.expectEqual(Code.invalid_identifier_escape, diags.items[0].code);
}

test "Lexer: escaped reserved word `let` flagged via had_escape" {
    // §12.7.1: `\u{6c}et` decodes to "let" — a ReservedWord. The lexer
    // always lexes it as `.identifier` with `had_escape = true`; the
    // parser is responsible for enforcing the early error contextually.
    var diags: Diagnostics = .empty;
    defer diags.deinit(testing.allocator);
    var lex = Lexer.init(testing.allocator, "\\u{6c}et");
    lex.diagnostics = &diags;
    const tok = try lex.next();
    try testing.expectEqual(TokenKind.identifier, tok.kind);
    try testing.expect(tok.had_escape);
    try testing.expectEqual(@as(usize, 0), diags.items.len);
}

test "Lexer: escaped reserved word `if` mid-token also flagged" {
    var diags: Diagnostics = .empty;
    defer diags.deinit(testing.allocator);
    var lex = Lexer.init(testing.allocator, "i\\u0066");
    lex.diagnostics = &diags;
    const tok = try lex.next();
    try testing.expectEqual(TokenKind.identifier, tok.kind);
    try testing.expect(tok.had_escape);
}

test "Lexer: escaped non-reserved identifier has had_escape = false" {
    // §12.7.1's rule applies only to ReservedWord matches. `fooo`
    // decodes to "foo" (not reserved) — plain identifier, no flag.
    var diags: Diagnostics = .empty;
    defer diags.deinit(testing.allocator);
    var lex = Lexer.init(testing.allocator, "f\\u006Foo");
    lex.diagnostics = &diags;
    const tok = try lex.next();
    try testing.expectEqual(TokenKind.identifier, tok.kind);
    try testing.expect(!tok.had_escape);
}

test "Lexer: unescaped reserved word still tokenizes as a keyword" {
    try expectKinds("let static interface", &.{ .kw_let, .kw_static, .kw_interface });
}

test "Lexer: malformed \\u in identifier" {
    var diags: Diagnostics = .empty;
    defer diags.deinit(testing.allocator);
    var lex = Lexer.init(testing.allocator, "f\\u{}oo");
    lex.diagnostics = &diags;
    try testing.expectError(error.InvalidEscapeSequence, lex.next());
    try testing.expectEqual(@as(usize, 1), diags.items.len);
    try testing.expectEqual(Code.invalid_escape_sequence, diags.items[0].code);
}

test "Lexer: private identifier with non-ASCII tail" {
    var lex = Lexer.init(testing.allocator, "#πι");
    const tok = try lex.next();
    try testing.expectEqual(TokenKind.private_identifier, tok.kind);
    try testing.expectEqualSlices(u8, "#πι", tok.slice("#πι"));
}

test "Lexer: private identifier with \\u escape" {
    var lex = Lexer.init(testing.allocator, "#\\u{66}oo");
    const tok = try lex.next();
    try testing.expectEqual(TokenKind.private_identifier, tok.kind);
}

// ── §12.5 HashbangComment ───────────────────────────────────────────────

test "Lexer: hashbang at start is skipped" {
    try expectKinds("#!/usr/bin/env node\nconst x = 1;", &.{
        .kw_const, .identifier, .eq, .numeric_literal, .semicolon,
    });
}

test "Lexer: hashbang followed by CRLF" {
    try expectKinds("#!cynic\r\nlet y = 2;", &.{
        .kw_let, .identifier, .eq, .numeric_literal, .semicolon,
    });
}

test "Lexer: hashbang as the entire source" {
    try expectKinds("#!cynic", &.{});
}

test "Lexer: `#!` not at start is not a hashbang" {
    // A leading space disqualifies it; the `#` then opens a private identifier
    // scan, which fails because `!` is not an IdentifierStart.
    var lex = Lexer.init(testing.allocator, " #!foo");
    try testing.expectError(error.UnexpectedCharacter, lex.next());
}

// ── §12.8.6 Template literals ───────────────────────────────────────────

test "Lexer: empty NoSubstitutionTemplate" {
    try expectKinds("``", &.{.no_substitution_template});
}

test "Lexer: simple NoSubstitutionTemplate" {
    try expectKinds("`hello`", &.{.no_substitution_template});
}

test "Lexer: NoSubstitutionTemplate slice covers backticks" {
    const src = "`hello`";
    var lex = Lexer.init(testing.allocator, src);
    const tok = try lex.next();
    try testing.expectEqual(TokenKind.no_substitution_template, tok.kind);
    try testing.expectEqualSlices(u8, "`hello`", tok.slice(src));
}

test "Lexer: NoSubstitutionTemplate with common escapes" {
    try expectKinds("`a\\nb\\t\\\"c`", &.{.no_substitution_template});
}

test "Lexer: NoSubstitutionTemplate with $ not followed by {" {
    try expectKinds("`$10 USD`", &.{.no_substitution_template});
}

test "Lexer: NoSubstitutionTemplate is multi-line" {
    try expectKinds("`line1\nline2`", &.{.no_substitution_template});
}

test "Lexer: NoSubstitutionTemplate with escaped backtick" {
    try expectKinds("`a\\`b`", &.{.no_substitution_template});
}

test "Lexer: NoSubstitutionTemplate with escaped $ {" {
    try expectKinds("`a\\${b}`", &.{.no_substitution_template});
}

test "Lexer: TemplateHead followed by substitution and tail" {
    const src = "`hi${x}!`";
    var lex = Lexer.init(testing.allocator, src);
    const head = try lex.next();
    try testing.expectEqual(TokenKind.template_head, head.kind);
    try testing.expectEqualSlices(u8, "`hi${", head.slice(src));
    try testing.expectEqual(TokenKind.identifier, (try lex.next()).kind);
    const tail = try lex.nextTemplateContinuation();
    try testing.expectEqual(TokenKind.template_tail, tail.kind);
    try testing.expectEqualSlices(u8, "}!`", tail.slice(src));
}

test "Lexer: TemplateMiddle between two substitutions" {
    const src = "`a${x}b${y}c`";
    var lex = Lexer.init(testing.allocator, src);
    try testing.expectEqual(TokenKind.template_head, (try lex.next()).kind);
    try testing.expectEqual(TokenKind.identifier, (try lex.next()).kind);
    const mid = try lex.nextTemplateContinuation();
    try testing.expectEqual(TokenKind.template_middle, mid.kind);
    try testing.expectEqualSlices(u8, "}b${", mid.slice(src));
    try testing.expectEqual(TokenKind.identifier, (try lex.next()).kind);
    const tail = try lex.nextTemplateContinuation();
    try testing.expectEqual(TokenKind.template_tail, tail.kind);
    try testing.expectEqualSlices(u8, "}c`", tail.slice(src));
}

test "Lexer: empty substitution produces head + tail" {
    const src = "`${x}`";
    var lex = Lexer.init(testing.allocator, src);
    const head = try lex.next();
    try testing.expectEqual(TokenKind.template_head, head.kind);
    try testing.expectEqualSlices(u8, "`${", head.slice(src));
    try testing.expectEqual(TokenKind.identifier, (try lex.next()).kind);
    const tail = try lex.nextTemplateContinuation();
    try testing.expectEqual(TokenKind.template_tail, tail.kind);
    try testing.expectEqualSlices(u8, "}`", tail.slice(src));
}

test "Lexer: unterminated NoSubstitutionTemplate" {
    var diags: Diagnostics = .empty;
    defer diags.deinit(testing.allocator);
    var lex = Lexer.init(testing.allocator, "`hello");
    lex.diagnostics = &diags;
    try testing.expectError(error.UnterminatedTemplate, lex.next());
    try testing.expectEqual(@as(usize, 1), diags.items.len);
    try testing.expectEqual(Code.unterminated_template_literal, diags.items[0].code);
}

test "Lexer: unterminated template continuation after substitution" {
    // `hi${` alone is a valid TemplateHead (terminates at `${`); the
    // "unterminated" condition shows up in the continuation after the
    // substitution closes with no following backtick or `${`.
    var diags: Diagnostics = .empty;
    defer diags.deinit(testing.allocator);
    var lex = Lexer.init(testing.allocator, "`a${1}");
    lex.diagnostics = &diags;
    try testing.expectEqual(TokenKind.template_head, (try lex.next()).kind);
    try testing.expectEqual(TokenKind.numeric_literal, (try lex.next()).kind);
    try testing.expectError(error.UnterminatedTemplate, lex.nextTemplateContinuation());
    try testing.expectEqual(Code.unterminated_template_literal, diags.items[0].code);
}

test "Lexer: legacy octal escape `\\17` in template marks invalid-escape but parses" {
    // §12.8.6 — template-literal escapes are scanned permissively so
    // tagged templates can still tag invalid forms (cooked value
    // becomes undefined). The lexer flags `had_invalid_template_escape`
    // on the token; the parser decides whether to surface a
    // SyntaxError (standalone template) or accept (tagged template).
    var lex = Lexer.init(testing.allocator, "`a\\17b`");
    const tok = try lex.next();
    try testing.expectEqual(TokenKind.no_substitution_template, tok.kind);
    try testing.expect(tok.had_invalid_template_escape);
}

test "Lexer: \\u escape in template" {
    try expectKinds("`a\\u0066b`", &.{.no_substitution_template});
}

test "Lexer: invalid UTF-8 byte produces unexpected_character" {
    // 0xFF is never a valid UTF-8 lead byte.
    var diags: Diagnostics = .empty;
    defer diags.deinit(testing.allocator);
    const src = [_]u8{ 0xFF, 'a', 'b' };
    var lex = Lexer.init(testing.allocator, src[0..]);
    lex.diagnostics = &diags;
    try testing.expectError(error.UnexpectedCharacter, lex.next());
    try testing.expectEqual(Code.unexpected_character, diags.items[0].code);
}
