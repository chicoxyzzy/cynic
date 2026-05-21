//! Numeric, BigInt, and string literal parsing — extracted
//! from `compiler.zig`. These are pure functions with no
//! `Compiler` state dependency: they convert lexer-provided
//! source slices into the `f64` / `i128` / `[]u8` values that
//! get baked into the bytecode constant pool.
//!
//! Spec anchors:
//! • §12.9 Numeric Literals (legacy octal / hex / binary).
//! • §12.9.5 BigInt Literals (`0n` suffix).
//! • §12.9.4 String Literal escape sequences.

const std = @import("std");

pub fn asExactSmi(d: f64) ?i32 {
    // i32 fast-path: only emit LdaSmi when the double is a whole
    // number representable as i32. Negative literals come via
    // unary `negate` so the lexer never produces a negative sign
    // inside a numeric span.
    if (std.math.isNan(d)) return null;
    if (d != @trunc(d)) return null;
    if (d < std.math.minInt(i32) or d > std.math.maxInt(i32)) return null;
    return @intFromFloat(d);
}

/// Parse the source text of a NumericLiteral (§12.8.3) into an
/// f64. Handles decimal (with optional fraction and exponent),
/// `0x` hex, `0o` octal, `0b` binary. Underscores between digits
/// per §12.8.3 — the parser/lexer already validated placement.
pub fn parseNumericLiteral(text: []const u8) !f64 {
    if (text.len >= 2 and text[0] == '0') {
        switch (text[1]) {
            'x', 'X' => return parseRadix(text[2..], 16),
            'o', 'O' => return parseRadix(text[2..], 8),
            'b', 'B' => return parseRadix(text[2..], 2),
            else => {},
        }
    }
    // Decimal — optionally with `.` and/or exponent. std.fmt.parseFloat
    // tolerates everything we want.
    var buf: [128]u8 = undefined;
    if (text.len > buf.len) return error.BadLiteral;
    var n: usize = 0;
    for (text) |c| {
        if (c == '_') continue; // numeric separator
        buf[n] = c;
        n += 1;
    }
    return std.fmt.parseFloat(f64, buf[0..n]) catch error.BadLiteral;
}

// BigInt literal parsing now lives in `runtime/bigint.zig`
// (`parseLiteralToValue`) — it produces an arbitrary-precision
// magnitude rather than a fixed-width i128.

pub fn parseRadix(text: []const u8, comptime base: u8) !f64 {
    var acc: f64 = 0.0;
    for (text) |c| {
        if (c == '_') continue;
        const digit: ?u8 = switch (c) {
            '0'...'9' => c - '0',
            'a'...'f' => c - 'a' + 10,
            'A'...'F' => c - 'A' + 10,
            else => null,
        };
        const d = digit orelse return error.BadLiteral;
        if (d >= base) return error.BadLiteral;
        acc = acc * @as(f64, base) + @as(f64, @floatFromInt(d));
    }
    return acc;
}

/// §12.8.6.1 TV / TRV — normalize raw LineTerminatorSequences in
/// a template-literal quasi. The grammar says:
///   • TRV of LineTerminatorSequence :: <LF>       is 0x000A
///   • TRV of LineTerminatorSequence :: <CR>       is 0x000A
///   • TRV of LineTerminatorSequence :: <CR><LF>   is 0x000A
///   • TRV of LineTerminatorSequence :: <LS>       is 0x2028
///   • TRV of LineTerminatorSequence :: <PS>       is 0x2029
/// (TV agrees with TRV on these productions — see §12.8.6.1.) So
/// every raw `<CR>` and `<CR><LF>` in a template body collapses to
/// a single `<LF>` in both the cooked and raw views, while `<LS>`
/// / `<PS>` pass through unchanged. String literals don't reach
/// this path — they go straight to `decodeStringContent`, whose
/// LineContinuation arm already handles `\<CR>` / `\<CR><LF>`.
/// Callers must run this before any escape decoding so the
/// LineContinuation arm of `decodeStringContent` sees the
/// already-normalised `\<LF>` form.
/// Caller-allocated; caller frees.
pub fn normalizeTemplateLineTerminators(allocator: std.mem.Allocator, raw: []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.ensureTotalCapacity(allocator, raw.len);
    var i: usize = 0;
    while (i < raw.len) : (i += 1) {
        const c = raw[i];
        if (c == '\r') {
            try out.append(allocator, '\n');
            if (i + 1 < raw.len and raw[i + 1] == '\n') i += 1; // skip the LF of CRLF
        } else {
            try out.append(allocator, c);
        }
    }
    return try out.toOwnedSlice(allocator);
}

/// Decode the inner content of a string literal per §12.8.4. The
/// lexer already validated escape shape so anything unexpected
/// here is an internal error.
///
/// Handles:
/// - SingleEscapeCharacter (`\n`, `\t`, etc.).
/// - LineContinuation: `\<LF>`, `\<CR>`, `\<CR><LF>`, `\<LS>`,
///   `\<PS>` → empty (the source-text newline drops out of the
///   value, §12.8.4.2 SV).
/// - HexEscapeSequence `\xNN` → codepoint `NN`, UTF-8 encoded.
/// - UnicodeEscapeSequence `\uNNNN` and `\u{N…}` → codepoint,
///   UTF-8 encoded.
/// - `\0` (NullEscape) → NUL.
/// - NonEscapeCharacter — any single byte that isn't one of the
///   above stands for itself (`\a` → `a`).
///
/// Caller-allocated; caller frees.
pub fn decodeStringContent(allocator: std.mem.Allocator, inner: []const u8) ![]u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    var i: usize = 0;
    while (i < inner.len) {
        const c = inner[i];
        if (c != '\\') {
            try out.append(allocator, c);
            i += 1;
            continue;
        }
        if (i + 1 >= inner.len) return error.BadLiteral;
        const esc = inner[i + 1];
        switch (esc) {
            // SingleEscapeCharacter (§12.8.4.1).
            'n' => {
                try out.append(allocator, '\n');
                i += 2;
            },
            't' => {
                try out.append(allocator, '\t');
                i += 2;
            },
            'r' => {
                try out.append(allocator, '\r');
                i += 2;
            },
            '\'' => {
                try out.append(allocator, '\'');
                i += 2;
            },
            '"' => {
                try out.append(allocator, '"');
                i += 2;
            },
            '\\' => {
                try out.append(allocator, '\\');
                i += 2;
            },
            'b' => {
                try out.append(allocator, 0x08);
                i += 2;
            },
            'f' => {
                try out.append(allocator, 0x0C);
                i += 2;
            },
            'v' => {
                try out.append(allocator, 0x0B);
                i += 2;
            },
            // NullEscape — `\0` not followed by a decimal digit
            // (the lexer already rejects the digit-followed form
            // as a LegacyOctalEscapeSequence in strict mode).
            '0' => {
                try out.append(allocator, 0);
                i += 2;
            },
            // LineContinuation: `\<LF>` / `\<CR>` / `\<CR><LF>`.
            // §12.8.4.2 SV(LineContinuation) is empty.
            '\n' => {
                i += 2;
            },
            '\r' => {
                i += if (i + 2 < inner.len and inner[i + 2] == '\n') 3 else 2;
            },
            // LineContinuation: `\<LS>` / `\<PS>` — three-byte
            // UTF-8 0xE2 0x80 0xA8 / 0xE2 0x80 0xA9.
            0xE2 => {
                if (i + 3 < inner.len and inner[i + 2] == 0x80 and
                    (inner[i + 3] == 0xA8 or inner[i + 3] == 0xA9))
                {
                    i += 4;
                } else {
                    // NonEscapeCharacter fallback — emit the
                    // bytes verbatim (the parser already accepted
                    // the surrounding shape).
                    try out.append(allocator, esc);
                    i += 2;
                }
            },
            // HexEscapeSequence: `\xNN` — value is a code unit
            // 0..255, encoded as UTF-8.
            'x' => {
                if (i + 4 > inner.len) return error.BadLiteral;
                const hi = hexDigit(inner[i + 2]) orelse return error.BadLiteral;
                const lo = hexDigit(inner[i + 3]) orelse return error.BadLiteral;
                try appendCodepointUtf8(allocator, &out, @intCast((hi << 4) | lo));
                i += 4;
            },
            // UnicodeEscapeSequence: `\uNNNN` or `\u{N…}`.
            'u' => {
                if (i + 2 >= inner.len) return error.BadLiteral;
                if (inner[i + 2] == '{') {
                    var j = i + 3;
                    var cp: u32 = 0;
                    while (j < inner.len and inner[j] != '}') : (j += 1) {
                        const d = hexDigit(inner[j]) orelse return error.BadLiteral;
                        cp = (cp << 4) | d;
                        if (cp > 0x10FFFF) return error.BadLiteral;
                    }
                    if (j >= inner.len or inner[j] != '}') return error.BadLiteral;
                    try appendCodepointWtf8(allocator, &out, @intCast(cp));
                    i = j + 1;
                } else {
                    if (i + 6 > inner.len) return error.BadLiteral;
                    var cp: u32 = 0;
                    for (0..4) |k| {
                        const d = hexDigit(inner[i + 2 + k]) orelse return error.BadLiteral;
                        cp = (cp << 4) | d;
                    }
                    // §12.8.4.3 SV — a `\uHIGH` immediately followed
                    // by `\uLOW` (HIGH in 0xD800..0xDBFF, LOW in
                    // 0xDC00..0xDFFF) decodes to the combined astral
                    // codepoint per UTF16Decode. Without this we'd
                    // emit two lone-surrogate WTF-8 sequences for
                    // what JS treats as a single character.
                    if (cp >= 0xD800 and cp <= 0xDBFF and
                        i + 12 <= inner.len and
                        inner[i + 6] == '\\' and inner[i + 7] == 'u' and inner[i + 8] != '{')
                    {
                        var lo: u32 = 0;
                        var ok = true;
                        for (0..4) |k| {
                            const d = hexDigit(inner[i + 8 + k]) orelse {
                                ok = false;
                                break;
                            };
                            lo = (lo << 4) | d;
                        }
                        if (ok and lo >= 0xDC00 and lo <= 0xDFFF) {
                            const combined: u32 = 0x10000 + ((cp - 0xD800) << 10) + (lo - 0xDC00);
                            try appendCodepointWtf8(allocator, &out, @intCast(combined));
                            i += 12;
                            continue;
                        }
                    }
                    try appendCodepointWtf8(allocator, &out, @intCast(cp));
                    i += 6;
                }
            },
            // NonEscapeCharacter — bytes that aren't one of the
            // recognised escapes stand for themselves (§12.8.4).
            else => {
                try out.append(allocator, esc);
                i += 2;
            },
        }
    }
    return out.toOwnedSlice(allocator);
}

fn hexDigit(c: u8) ?u32 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => 10 + (c - 'a'),
        'A'...'F' => 10 + (c - 'A'),
        else => null,
    };
}

fn appendCodepointUtf8(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), cp: u21) !void {
    var buf: [4]u8 = undefined;
    const n = std.unicode.utf8Encode(cp, &buf) catch return error.BadLiteral;
    try out.appendSlice(allocator, buf[0..n]);
}

/// WTF-8 encode (Unicode TR-26) — same as UTF-8 but surrogate
/// halves (U+D800..U+DFFF) are emitted as their natural 3-byte
/// sequences. This lets Cynic round-trip lone surrogates in
/// JS string literals (§6.1.4 — Strings are sequences of code
/// units, not codepoints). Standard UTF-8 readers reject the
/// resulting bytes; Cynic's string-iteration / printing paths
/// must be surrogate-aware.
fn appendCodepointWtf8(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), cp: u21) !void {
    if (cp < 0x80) {
        try out.append(allocator, @intCast(cp));
    } else if (cp < 0x800) {
        try out.append(allocator, @intCast(0xC0 | (cp >> 6)));
        try out.append(allocator, @intCast(0x80 | (cp & 0x3F)));
    } else if (cp < 0x10000) {
        try out.append(allocator, @intCast(0xE0 | (cp >> 12)));
        try out.append(allocator, @intCast(0x80 | ((cp >> 6) & 0x3F)));
        try out.append(allocator, @intCast(0x80 | (cp & 0x3F)));
    } else if (cp <= 0x10FFFF) {
        try out.append(allocator, @intCast(0xF0 | (cp >> 18)));
        try out.append(allocator, @intCast(0x80 | ((cp >> 12) & 0x3F)));
        try out.append(allocator, @intCast(0x80 | ((cp >> 6) & 0x3F)));
        try out.append(allocator, @intCast(0x80 | (cp & 0x3F)));
    } else return error.BadLiteral;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------
