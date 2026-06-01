//! §12.9.5 RegularExpressionLiteral early-error validation.
//!
//! The lexer recognises the textual shape `/ … / flags*` and emits a
//! `regular_expression_literal` token spanning the whole thing; the
//! parser stores a `regex_literal` AST node carrying only the span.
//! Per §22.2.3.4 RegExpInitialize the pattern and flags must be
//! syntactically valid — invalid patterns are SyntaxErrors at parse
//! phase, not at construction time.
//!
//! The pattern is validated by compiling it with Perlex (the native
//! regex engine) — the same compile the runtime bridge runs, with the
//! same `\p{…}` resolver and case folders injected, so parse-time and
//! run-time agree. A pattern Perlex rejects (`.syntax_error`) is an
//! early SyntaxError; one it accepts is a valid literal. (The vendored
//! libregexp validator it used to fall through to has been retired.)
//!
//! Flag validation is done in Zig: §22.2.3.4 requires each
//! RegExpFlag to be unique and drawn from `dgimsuvy`; additionally
//! `u` and `v` are mutually exclusive.

const std = @import("std");

const perlex = @import("../perlex/perlex.zig");
const perlex_props = @import("../unicode/perlex_props.zig");

/// Map a flag string to Perlex's flag set for the parse-time check.
fn perlexFlagsFromText(flags: []const u8) perlex.Flags {
    var f: perlex.Flags = .{};
    for (flags) |ch| switch (ch) {
        'g' => f.global = true,
        'i' => f.ignore_case = true,
        'm' => f.multiline = true,
        's' => f.dot_all = true,
        'u' => f.unicode = true,
        'y' => f.sticky = true,
        'd' => f.has_indices = true,
        'v' => f.unicode_sets = true,
        else => {},
    };
    return f;
}

const source_mod = @import("../source.zig");
const Span = source_mod.Span;

const diag_mod = @import("../diagnostic.zig");
const Diagnostics = diag_mod.Diagnostics;
const Code = diag_mod.Code;

// A compact `c_int` flag bitmask used by `validateFlags` to detect a
// `u`+`v` conflict. The `LRE_FLAG_` names are a historical holdover
// from the retired libregexp validator.
const LRE_FLAG_GLOBAL: c_int = 1 << 0;
const LRE_FLAG_IGNORECASE: c_int = 1 << 1;
const LRE_FLAG_MULTILINE: c_int = 1 << 2;
const LRE_FLAG_DOTALL: c_int = 1 << 3;
const LRE_FLAG_UNICODE: c_int = 1 << 4;
const LRE_FLAG_STICKY: c_int = 1 << 5;
const LRE_FLAG_INDICES: c_int = 1 << 6;
const LRE_FLAG_UNICODE_SETS: c_int = 1 << 8;

/// `token_text` is the raw lexer token bytes, including the opening
/// `/`, the pattern, the closing `/`, and any flag characters. Splits
/// the pattern from the flags, validates each, and reports
/// `invalid_regex_literal` for the first failure encountered.
pub fn validateRegexLiteralToken(
    allocator: std.mem.Allocator,
    text: []const u8,
    span: Span,
    diagnostics: ?*Diagnostics,
) std.mem.Allocator.Error!void {
    if (text.len < 2 or text[0] != '/') return; // malformed; lexer already errored
    // Locate the closing `/`. Scan with the same class-aware logic as
    // the lexer — `/` inside `[...]` does not close the pattern, and
    // a backslash escapes the next byte.
    var i: usize = 1;
    var in_class = false;
    var closing: ?usize = null;
    while (i < text.len) : (i += 1) {
        const ch = text[i];
        if (ch == '\\') {
            i += 1;
            continue;
        }
        if (ch == '[' and !in_class) {
            in_class = true;
        } else if (ch == ']' and in_class) {
            in_class = false;
        } else if (ch == '/' and !in_class) {
            closing = i;
            break;
        }
    }
    const close_idx = closing orelse return; // unterminated; lexer already errored
    const pattern = text[1..close_idx];
    const flags_text = text[close_idx + 1 ..];

    if (!validateFlags(flags_text)) {
        try report(allocator, diagnostics, .invalid_regex_literal, span);
        return;
    }
    // Perlex is the sole regex engine (the vendored libregexp validator
    // has been retired). A pattern it accepts is a valid literal; one it
    // rejects — a same-Alternative duplicate group name, a negated set
    // that may contain strings, a `\P{…}` property of strings (§22.2.1.5),
    // a malformed `\q{…}`, etc. — is an early SyntaxError. An OOM during
    // the parse-time check leaves the literal accepted (the runtime bridge
    // re-validates at construction); an `.unsupported` result is reported
    // as invalid (the corpus reaches it for no pattern). Inject the same
    // `\p{…}` resolver + `/iu`·`/iv` and non-/u case folders the runtime
    // bridge uses, so parse-time and run-time agree on which patterns are
    // valid.
    var perlex_result = perlex.compileWithHooks(allocator, pattern, perlexFlagsFromText(flags_text), .{
        .resolver = perlex_props.resolve,
        .case_folder = perlex_props.caseFold,
        .nonunicode_fold = perlex_props.nonUnicodeCanonFold,
    }) catch return;
    switch (perlex_result) {
        .ok => |*program| program.deinit(),
        .syntax_error, .unsupported => try report(allocator, diagnostics, .invalid_regex_literal, span),
    }
}

/// §22.2.3.4 step 6: each flag must be drawn from `dgimsuvy`, must
/// appear at most once, and `u` / `v` are mutually exclusive.
fn validateFlags(flags: []const u8) bool {
    var seen: [128]bool = @splat(false);
    var bits: c_int = 0;
    for (flags) |ch| {
        if (ch >= 128) return false;
        if (seen[ch]) return false;
        seen[ch] = true;
        switch (ch) {
            'g' => bits |= LRE_FLAG_GLOBAL,
            'i' => bits |= LRE_FLAG_IGNORECASE,
            'm' => bits |= LRE_FLAG_MULTILINE,
            's' => bits |= LRE_FLAG_DOTALL,
            'u' => bits |= LRE_FLAG_UNICODE,
            'y' => bits |= LRE_FLAG_STICKY,
            'd' => bits |= LRE_FLAG_INDICES,
            'v' => bits |= LRE_FLAG_UNICODE_SETS,
            else => return false,
        }
    }
    if ((bits & LRE_FLAG_UNICODE) != 0 and (bits & LRE_FLAG_UNICODE_SETS) != 0) return false;
    return true;
}

fn report(
    allocator: std.mem.Allocator,
    diagnostics: ?*Diagnostics,
    code: Code,
    span: Span,
) std.mem.Allocator.Error!void {
    if (diagnostics) |list| {
        try list.append(allocator, .{
            .severity = .err,
            .code = code,
            .span = span,
        });
    }
}
