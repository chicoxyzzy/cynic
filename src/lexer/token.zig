//! Token representation for Cynic.
//!
//! References ECMA-262 §11 (Lexical Grammar) and §12.7 (Punctuators / Reserved
//! Words). The `keywordKind` lookup encodes the strict-mode reserved-word set:
//! all unconditional reserved words plus the strict-only future reserved words
//! (`implements`, `interface`, `let`, `package`, `private`, `protected`,
//! `public`, `static`).

const std = @import("std");
const Span = @import("../source.zig").Span;

pub const TokenKind = enum {
    // ── End of input ───────────────────────────────────────────────────
    eof,

    // ── Literals (raw bytes preserved on Token via span) ───────────────
    /// IdentifierName whose StringValue is not a reserved word.
    identifier,
    /// PrivateIdentifier (`#name`) — §13.1.
    private_identifier,
    /// NumericLiteral — §12.8.3.
    numeric_literal,
    /// NumericLiteral with the BigIntLiteralSuffix (`n`) — §12.8.3.
    bigint_literal,
    /// StringLiteral — §12.8.4.
    string_literal,
    /// `` `...` `` template with no substitutions — §12.8.6.
    no_substitution_template,
    /// `` `...${ `` template head before a substitution.
    template_head,
    /// `` }...${ `` template middle between substitutions.
    template_middle,
    /// `` }...` `` template tail.
    template_tail,
    /// RegularExpressionLiteral — §12.8.5.
    regular_expression_literal,

    // ── Punctuators — §12.7 ────────────────────────────────────────────
    lbrace, // {
    rbrace, // }
    lparen, // (
    rparen, // )
    lbracket, // [
    rbracket, // ]
    dot, //.
    ellipsis, //...
    semicolon, // ;
    comma, //,
    lt, // <
    gt, // >
    le, // <=
    ge, // >=
    eq_eq, // ==
    bang_eq, // !=
    eq_eq_eq, // ===
    bang_eq_eq, // !==
    plus, // +
    minus, // -
    star, // *
    percent, // %
    star_star, // **
    plus_plus, // ++
    minus_minus, // --
    lt_lt, // <<
    gt_gt, // >>
    gt_gt_gt, // >>>
    amp, // &
    pipe, // |
    caret, // ^
    bang, // !
    tilde, // ~
    amp_amp, // &&
    pipe_pipe, // ||
    question_question, // ??
    question, // ?
    colon, // :
    eq, // =
    plus_eq, // +=
    minus_eq, // -=
    star_eq, // *=
    slash_eq, // /=
    percent_eq, // %=
    star_star_eq, // **=
    lt_lt_eq, // <<=
    gt_gt_eq, // >>=
    gt_gt_gt_eq, // >>>=
    amp_eq, // &=
    pipe_eq, // |=
    caret_eq, // ^=
    amp_amp_eq, // &&=
    pipe_pipe_eq, // ||=
    question_question_eq, // ??=
    arrow, // =>
    slash, // /
    optional_chain, // ?.

    // ── Reserved words — §12.7.2 ───────────────────────────────────────
    // ReservedWord (always reserved):
    kw_await,
    kw_break,
    kw_case,
    kw_catch,
    kw_class,
    kw_const,
    kw_continue,
    kw_debugger,
    kw_default,
    kw_delete,
    kw_do,
    kw_else,
    kw_enum,
    kw_export,
    kw_extends,
    kw_false,
    kw_finally,
    kw_for,
    kw_function,
    kw_if,
    kw_import,
    kw_in,
    kw_instanceof,
    kw_new,
    kw_null,
    kw_return,
    kw_super,
    kw_switch,
    kw_this,
    kw_throw,
    kw_true,
    kw_try,
    kw_typeof,
    kw_var,
    kw_void,
    kw_while,
    kw_with,
    kw_yield,

    // FutureReservedWord under strict mode — Cynic is strict-only, so always reserved:
    kw_implements,
    kw_interface,
    kw_let,
    kw_package,
    kw_private,
    kw_protected,
    kw_public,
    kw_static,
};

pub const Token = struct {
    kind: TokenKind,
    span: Span,
    /// True if a LineTerminator was scanned in the trivia immediately before
    /// this token. The parser reads this for ASI per §12.10 and for restricted
    /// productions (e.g. `return [no LineTerminator here] Expression`).
    line_terminator_before: bool = false,
    /// True if this Identifier token's source text contains one or more
    /// `\u…` escape sequences AND its decoded StringValue matches a
    /// ReservedWord (§12.7.1). Such a token is *always* lexed as
    /// `.identifier` (never as the keyword kind) — `had_escape` lets
    /// the parser decide:
    /// • PropertyName / member-access positions accept it freely.
    /// • IdentifierReference / BindingIdentifier positions reject it
    /// as `escape_in_reserved_word`.
    /// Non-reserved escaped names (e.g. `foo`) lex as plain
    /// identifiers with `had_escape = false` — there's no rule to
    /// enforce against them.
    had_escape: bool = false,
    /// When `had_escape` is true, this is the keyword token kind the
    /// decoded StringValue resolves to (e.g. `.kw_await` for
    /// `await`). Lets the parser apply context-sensitive rules:
    /// `await` is only a ReservedWord in `[+Await]`, so a script-mode
    /// `class await {}` should accept the name. `.identifier`
    /// otherwise (never matters when `had_escape == false`).
    escaped_keyword: TokenKind = .identifier,
    /// Template-literal-only: true if the scanned body contained an
    /// invalid EscapeSequence (`\01`, `\xg`, `\u{10FFFFF}`, …).
    /// Tagged templates relax the rules — their cooked value is
    /// `undefined`, raw value preserves the source — so the parser
    /// only errors when the template is consumed standalone (i.e.
    /// not as a tagged-template argument).
    had_invalid_template_escape: bool = false,

    pub fn slice(self: Token, source: []const u8) []const u8 {
        return source[self.span.start..self.span.end];
    }
};

/// True iff `k` is a reserved-word token kind. Reserved words
/// are valid IdentifierName tokens per §13.1 — useful for places
/// where the grammar accepts an IdentifierName (object property
/// names, import-attribute keys, etc.) but the lexer surfaces
/// reserved words as their `kw_*` discriminant.
pub fn isReservedWord(k: TokenKind) bool {
    return switch (k) {
        .kw_await, .kw_break, .kw_case, .kw_catch, .kw_class, .kw_const, .kw_continue, .kw_debugger, .kw_default, .kw_delete, .kw_do, .kw_else, .kw_enum, .kw_export, .kw_extends, .kw_false, .kw_finally, .kw_for, .kw_function, .kw_if, .kw_import, .kw_in, .kw_instanceof, .kw_new, .kw_null, .kw_return, .kw_super, .kw_switch, .kw_this, .kw_throw, .kw_true, .kw_try, .kw_typeof, .kw_var, .kw_void, .kw_while, .kw_with, .kw_yield, .kw_implements, .kw_interface, .kw_let, .kw_package, .kw_private, .kw_protected, .kw_public, .kw_static => true,
        else => false,
    };
}

/// Map an IdentifierName slice to its keyword TokenKind, if it is a reserved
/// word in the strict-mode grammar Cynic targets. Returns null for ordinary
/// identifiers.
pub fn keywordKind(name: []const u8) ?TokenKind {
    return keyword_map.get(name);
}

const keyword_map = std.StaticStringMap(TokenKind).initComptime(.{
    .{ "await", TokenKind.kw_await },
    .{ "break", TokenKind.kw_break },
    .{ "case", TokenKind.kw_case },
    .{ "catch", TokenKind.kw_catch },
    .{ "class", TokenKind.kw_class },
    .{ "const", TokenKind.kw_const },
    .{ "continue", TokenKind.kw_continue },
    .{ "debugger", TokenKind.kw_debugger },
    .{ "default", TokenKind.kw_default },
    .{ "delete", TokenKind.kw_delete },
    .{ "do", TokenKind.kw_do },
    .{ "else", TokenKind.kw_else },
    .{ "enum", TokenKind.kw_enum },
    .{ "export", TokenKind.kw_export },
    .{ "extends", TokenKind.kw_extends },
    .{ "false", TokenKind.kw_false },
    .{ "finally", TokenKind.kw_finally },
    .{ "for", TokenKind.kw_for },
    .{ "function", TokenKind.kw_function },
    .{ "if", TokenKind.kw_if },
    .{ "import", TokenKind.kw_import },
    .{ "in", TokenKind.kw_in },
    .{ "instanceof", TokenKind.kw_instanceof },
    .{ "new", TokenKind.kw_new },
    .{ "null", TokenKind.kw_null },
    .{ "return", TokenKind.kw_return },
    .{ "super", TokenKind.kw_super },
    .{ "switch", TokenKind.kw_switch },
    .{ "this", TokenKind.kw_this },
    .{ "throw", TokenKind.kw_throw },
    .{ "true", TokenKind.kw_true },
    .{ "try", TokenKind.kw_try },
    .{ "typeof", TokenKind.kw_typeof },
    .{ "var", TokenKind.kw_var },
    .{ "void", TokenKind.kw_void },
    .{ "while", TokenKind.kw_while },
    .{ "with", TokenKind.kw_with },
    .{ "yield", TokenKind.kw_yield },
    // Strict-mode-only future reserved words (always reserved in Cynic):
    .{ "implements", TokenKind.kw_implements },
    .{ "interface", TokenKind.kw_interface },
    .{ "let", TokenKind.kw_let },
    .{ "package", TokenKind.kw_package },
    .{ "private", TokenKind.kw_private },
    .{ "protected", TokenKind.kw_protected },
    .{ "public", TokenKind.kw_public },
    .{ "static", TokenKind.kw_static },
});

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "keywordKind: strict-only future reserved words are reserved" {
    try testing.expectEqual(TokenKind.kw_let, keywordKind("let").?);
    try testing.expectEqual(TokenKind.kw_static, keywordKind("static").?);
    try testing.expectEqual(TokenKind.kw_interface, keywordKind("interface").?);
    try testing.expectEqual(TokenKind.kw_package, keywordKind("package").?);
}

test "keywordKind: unconditional reserved words" {
    try testing.expectEqual(TokenKind.kw_await, keywordKind("await").?);
    try testing.expectEqual(TokenKind.kw_class, keywordKind("class").?);
    try testing.expectEqual(TokenKind.kw_yield, keywordKind("yield").?);
}

test "keywordKind: non-keywords return null" {
    try testing.expectEqual(@as(?TokenKind, null), keywordKind("foo"));
    // `eval` and `arguments` are restricted in strict mode but are not
    // keywords — they remain identifiers, with restrictions enforced by
    // the parser.
    try testing.expectEqual(@as(?TokenKind, null), keywordKind("eval"));
    try testing.expectEqual(@as(?TokenKind, null), keywordKind("arguments"));
}
