//! §12.9.5 RegularExpressionLiteral early-error validation.
//!
//! The lexer recognises the textual shape `/ … / flags*` and emits a
//! `regular_expression_literal` token spanning the whole thing; the
//! parser stores a `regex_literal` AST node carrying only the span.
//! Per §22.2.3.4 RegExpInitialize the pattern and flags must be
//! syntactically valid — invalid patterns are SyntaxErrors at parse
//! phase, not at construction time.
//!
//! We delegate the heavy lifting to the vendored QuickJS-NG libregexp
//! (`vendor/quickjs/libregexp.c`). `lre_compile` returns NULL on a
//! syntax error and writes a message into the caller's buffer. The
//! `opaque` user pointer is only consulted by `lre_realloc`, which
//! ignores it — so we can validate at parse time without a Realm.
//!
//! Flag validation is done in Zig: §22.2.3.4 requires each
//! RegExpFlag to be unique and drawn from `dgimsuvy`; additionally
//! `u` and `v` are mutually exclusive.

const std = @import("std");

const c = @import("c");

const source_mod = @import("../source.zig");
const Span = source_mod.Span;

const diag_mod = @import("../diagnostic.zig");
const Diagnostics = diag_mod.Diagnostics;
const Code = diag_mod.Code;

// Match the bitfield definitions used by libregexp; duplicated here
// (rather than imported from `runtime/builtins/regexp.zig`) so this
// validator has no runtime dependency.
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

    var re_flags: c_int = 0;
    if (!validateFlags(flags_text, &re_flags)) {
        try report(allocator, diagnostics, .invalid_regex_literal, span);
        return;
    }
    if (!validatePattern(allocator, pattern, re_flags)) {
        try report(allocator, diagnostics, .invalid_regex_literal, span);
        return;
    }
}

/// §22.2.3.4 step 6: each flag must be drawn from `dgimsuvy`, must
/// appear at most once, and `u` / `v` are mutually exclusive.
fn validateFlags(flags: []const u8, out: *c_int) bool {
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
    out.* = bits;
    return true;
}

/// Hand the pattern to `lre_compile`. Returns false on syntax error.
/// libregexp's parser requires a NUL-terminated buffer (it scans past
/// the disjunction looking for a trailing NUL). Copy into an
/// allocator-owned slice and append the NUL.
fn validatePattern(allocator: std.mem.Allocator, pattern: []const u8, re_flags: c_int) bool {
    const buf = allocator.alloc(u8, pattern.len + 1) catch return true; // OOM — let runtime handle
    defer allocator.free(buf);
    @memcpy(buf[0..pattern.len], pattern);
    buf[pattern.len] = 0;

    var err_buf: [128]u8 = undefined;
    @memset(&err_buf, 0);
    var bc_len: c_int = 0;
    const bc_ptr = c.lre_compile(
        &bc_len,
        &err_buf[0],
        @intCast(err_buf.len),
        @ptrCast(buf.ptr),
        pattern.len,
        re_flags,
        null,
    );
    if (bc_ptr == null) return false;
    // libregexp allocates the bytecode via the host `lre_realloc`
    // hook (which calls `malloc` / `free`). Free it here — the
    // parser has no interest in the bytecode.
    std.c.free(bc_ptr);
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
