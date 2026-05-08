//! Diagnostic representation. Lexer, parser, and runtime accumulate
//! `Diagnostic` records rather than aborting on first error so the
//! test262 harness can compare expected SyntaxError sets to produced ones.

const std = @import("std");
const Span = @import("source.zig").Span;

pub const Severity = enum { err, warning, note };

/// JavaScript-level error class associated with a diagnostic code.
///
/// test262 negative tests carry a `negative.type` of `SyntaxError`,
/// `ReferenceError`, `TypeError`, or `RangeError` (rarely `URIError` or
/// the legacy `EvalError`). The harness compares the class returned by
/// `Code.errorClass()` against that string to score parse-negatives.
///
/// Every parser- or lexer-time error in Cynic is mechanically a
/// `SyntaxError` per the spec — `Code.errorClass()` reflects that.
/// Runtime codes that surface later (later+) will return the appropriate
/// runtime class.
pub const ErrorClass = enum {
    syntax_error,
    reference_error,
    type_error,
    range_error,

    pub fn name(self: ErrorClass) []const u8 {
        return switch (self) {
            .syntax_error => "SyntaxError",
            .reference_error => "ReferenceError",
            .type_error => "TypeError",
            .range_error => "RangeError",
        };
    }
};

pub const Code = enum {
    // ── Lexer ───────────────────────────────────────────────────────────
    unterminated_string_literal,
    unterminated_multi_line_comment,
    invalid_numeric_literal,
    /// `0755` and friends — strict mode rejects LegacyOctalIntegerLiteral.
    legacy_octal_in_strict,
    invalid_escape_sequence,
    unexpected_character,
    regex_literal_unsupported,
    unterminated_template_literal,
    /// `/regex/` literal not closed before EOF or LineTerminator (§12.9.5).
    unterminated_regex_literal,
    /// `\u` escape in an identifier decoded to a codepoint that is not a
    /// valid `IdentifierStart` (in starting position) or `IdentifierPart`
    /// (otherwise) per §12.7.
    invalid_identifier_escape,
    /// IdentifierName whose StringValue is a ReservedWord and whose source
    /// text contains any `\u` escape sequence — §12.7.1.
    escape_in_reserved_word,

    // ── Parser ─────────────────────────────────────────────────────────
    unexpected_token,
    /// `a && b ?? c` without parens — §13.13 forbids mixing logical
    /// operators of different kinds without grouping.
    mixed_logical_operators,
    /// `delete x` where `x` is a bare IdentifierReference — §13.5.1.1.
    delete_of_unqualified_identifier,
    /// `let eval = …` / `let arguments = …` / similar — §13.1.1 makes
    /// `eval` and `arguments` restricted in BindingIdentifier position.
    restricted_identifier_in_strict,
    /// `const x;` without an Initializer — §14.3.1.
    const_without_initializer,
    /// LHS of `=` is not a SimpleAssignmentTarget — §13.15.
    assignment_target_invalid,

    // ── Runtime (later+) ───────────────────────────────────────────────────
    /// `let` or `const` binding read before its initialiser ran —
    /// §13.3.1 Temporal Dead Zone.
    let_in_tdz,
    /// Assignment target resolves to a `const` binding — §13.3.1.
    assignment_to_const,

    /// JavaScript error class for this code, used by test262 negative
    /// scoring. Lexer / parser codes map to `SyntaxError`; runtime
    /// codes map to whatever the spec says they should throw
    /// (`ReferenceError`, `TypeError`, etc.).
    pub fn errorClass(self: Code) ErrorClass {
        return switch (self) {
            .unterminated_string_literal,
            .unterminated_multi_line_comment,
            .invalid_numeric_literal,
            .legacy_octal_in_strict,
            .invalid_escape_sequence,
            .unexpected_character,
            .regex_literal_unsupported,
            .unterminated_template_literal,
            .unterminated_regex_literal,
            .invalid_identifier_escape,
            .escape_in_reserved_word,
            .unexpected_token,
            .mixed_logical_operators,
            .delete_of_unqualified_identifier,
            .restricted_identifier_in_strict,
            .const_without_initializer,
            .assignment_target_invalid,
            => .syntax_error,
            .let_in_tdz => .reference_error,
            .assignment_to_const => .type_error,
        };
    }
};

pub const Diagnostic = struct {
    severity: Severity,
    code: Code,
    span: Span,
    /// Optional explanatory message. Lifetime is the caller's responsibility
    /// (typically a parser arena).
    message: []const u8 = "",
};

pub const Diagnostics = std.ArrayListUnmanaged(Diagnostic);

const testing = std.testing;

test "Code.errorClass: parser/lexer codes are SyntaxError" {
    // Lexer + parser codes — every variant in this list must map to
    // `.syntax_error`. The list is explicit (not `inline for` over
    // every variant) because runtime codes (later+) deliberately map
    // to other classes; the test pins the *parser/lexer* slice.
    const parser_codes = [_]Code{
        .unterminated_string_literal,
        .unterminated_multi_line_comment,
        .invalid_numeric_literal,
        .legacy_octal_in_strict,
        .invalid_escape_sequence,
        .unexpected_character,
        .regex_literal_unsupported,
        .unterminated_template_literal,
        .unterminated_regex_literal,
        .invalid_identifier_escape,
        .escape_in_reserved_word,
        .unexpected_token,
        .mixed_logical_operators,
        .delete_of_unqualified_identifier,
        .restricted_identifier_in_strict,
        .const_without_initializer,
        .assignment_target_invalid,
    };
    for (parser_codes) |c| {
        try testing.expectEqual(ErrorClass.syntax_error, c.errorClass());
    }
}

test "Code.errorClass: runtime codes map to their JS class" {
    try testing.expectEqual(ErrorClass.reference_error, Code.let_in_tdz.errorClass());
    try testing.expectEqual(ErrorClass.type_error, Code.assignment_to_const.errorClass());
}

test "ErrorClass.name: matches test262 type strings" {
    try testing.expectEqualStrings("SyntaxError", ErrorClass.syntax_error.name());
    try testing.expectEqualStrings("ReferenceError", ErrorClass.reference_error.name());
    try testing.expectEqualStrings("TypeError", ErrorClass.type_error.name());
    try testing.expectEqualStrings("RangeError", ErrorClass.range_error.name());
}
