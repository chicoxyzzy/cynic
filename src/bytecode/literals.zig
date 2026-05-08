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

/// Parse a BigInt literal's digit text (sans the trailing `n`)
/// into an i128. Supports decimal / hex / octal / binary
/// prefixes plus `_` separators. Overflow throws — true
/// arbitrary precision is later.
pub fn parseBigIntLiteral(text: []const u8) !i128 {
    var base: u8 = 10;
    var rest = text;
    if (text.len >= 2 and text[0] == '0') {
        switch (text[1]) {
            'x', 'X' => {
                base = 16;
                rest = text[2..];
            },
            'o', 'O' => {
                base = 8;
                rest = text[2..];
            },
            'b', 'B' => {
                base = 2;
                rest = text[2..];
            },
            else => {},
        }
    }
    var acc: i128 = 0;
    for (rest) |c| {
        if (c == '_') continue;
        const digit: u8 = switch (c) {
            '0'...'9' => c - '0',
            'a'...'f' => c - 'a' + 10,
            'A'...'F' => c - 'A' + 10,
            else => return error.BadLiteral,
        };
        if (digit >= base) return error.BadLiteral;
        const product = std.math.mul(i128, acc, @intCast(base)) catch return error.BadLiteral;
        acc = std.math.add(i128, product, @intCast(digit)) catch return error.BadLiteral;
    }
    return acc;
}

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

/// Decode the inner content of a string literal — handles the
/// minimal escape set later needs. Caller-allocated; caller frees.
/// Parser already accepted the escapes' shape, so unrecognised
/// escapes are an internal-error case (returned as
/// `UnsupportedExpression` upstream).
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
        const decoded: u8 = switch (esc) {
            'n' => '\n',
            't' => '\t',
            'r' => '\r',
            '\'' => '\'',
            '"' => '"',
            '\\' => '\\',
            '0' => 0,
            'b' => 0x08,
            'f' => 0x0C,
            'v' => 0x0B,
            else => return error.BadLiteral, // \xNN / \uXXXX deferred — see file header
        };
        try out.append(allocator, decoded);
        i += 2;
    }
    return out.toOwnedSlice(allocator);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------
