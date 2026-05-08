//! Unicode identifier predicates per ECMA-262 §12.7.
//!
//! `IdentifierStartChar` is `UnicodeIDStart`, plus `$` and `_`.
//! `IdentifierPartChar` is `UnicodeIDContinue`, plus `$`, ZWNJ (U+200C),
//! and ZWJ (U+200D).
//!
//! Lookups are inline ASCII fast path → binary search of the sorted ranges
//! generated from `vendor/unicode/DerivedCoreProperties.txt`.

const std = @import("std");
const tables = @import("ident_tables.zig");

const ZWNJ: u21 = 0x200C;
const ZWJ: u21 = 0x200D;

/// True iff `cp` may begin an `IdentifierName` (§12.7).
pub fn isIdentifierStart(cp: u21) bool {
    if (cp < 0x80) return isAsciiIdentifierStart(@intCast(cp));
    return rangeContains(tables.id_start_ranges[0..], cp);
}

/// True iff `cp` may continue an `IdentifierName` (§12.7).
pub fn isIdentifierPart(cp: u21) bool {
    if (cp < 0x80) return isAsciiIdentifierPart(@intCast(cp));
    if (cp == ZWNJ or cp == ZWJ) return true;
    return rangeContains(tables.id_continue_ranges[0..], cp);
}

/// ASCII fast path for IdentifierStart.
pub fn isAsciiIdentifierStart(b: u8) bool {
    return switch (b) {
        'a'...'z', 'A'...'Z', '_', '$' => true,
        else => false,
    };
}

/// ASCII fast path for IdentifierPart.
pub fn isAsciiIdentifierPart(b: u8) bool {
    return switch (b) {
        'a'...'z', 'A'...'Z', '0'...'9', '_', '$' => true,
        else => false,
    };
}

fn rangeContains(ranges: []const tables.Range, cp: u21) bool {
    var lo: usize = 0;
    var hi: usize = ranges.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        const r = ranges[mid];
        if (cp < r.start) {
            hi = mid;
        } else if (cp > r.end) {
            lo = mid + 1;
        } else {
            return true;
        }
    }
    return false;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

test "ASCII letters are IdentifierStart and IdentifierPart" {
    try testing.expect(isIdentifierStart('a'));
    try testing.expect(isIdentifierStart('Z'));
    try testing.expect(isIdentifierPart('a'));
    try testing.expect(isIdentifierPart('Z'));
}

test "$ and _ are IdentifierStart and IdentifierPart" {
    try testing.expect(isIdentifierStart('$'));
    try testing.expect(isIdentifierStart('_'));
    try testing.expect(isIdentifierPart('$'));
    try testing.expect(isIdentifierPart('_'));
}

test "ASCII digits are IdentifierPart but not IdentifierStart" {
    try testing.expect(!isIdentifierStart('0'));
    try testing.expect(!isIdentifierStart('9'));
    try testing.expect(isIdentifierPart('0'));
    try testing.expect(isIdentifierPart('9'));
}

test "Greek small alpha (U+03B1) is IdentifierStart and IdentifierPart" {
    try testing.expect(isIdentifierStart(0x03B1));
    try testing.expect(isIdentifierPart(0x03B1));
}

test "CJK ideograph (U+4E2D) is IdentifierStart and IdentifierPart" {
    try testing.expect(isIdentifierStart(0x4E2D));
    try testing.expect(isIdentifierPart(0x4E2D));
}

test "Non-BMP letter (Old Italic A, U+10300) is IdentifierStart" {
    try testing.expect(isIdentifierStart(0x10300));
    try testing.expect(isIdentifierPart(0x10300));
}

test "ZWJ and ZWNJ are IdentifierPart but not IdentifierStart" {
    try testing.expect(!isIdentifierStart(ZWNJ));
    try testing.expect(!isIdentifierStart(ZWJ));
    try testing.expect(isIdentifierPart(ZWNJ));
    try testing.expect(isIdentifierPart(ZWJ));
}

test "ASCII space and punctuation are neither" {
    try testing.expect(!isIdentifierStart(' '));
    try testing.expect(!isIdentifierStart('.'));
    try testing.expect(!isIdentifierPart(' '));
    try testing.expect(!isIdentifierPart('.'));
}

test "surrogate range is rejected" {
    try testing.expect(!isIdentifierStart(0xD800));
    try testing.expect(!isIdentifierStart(0xDFFF));
    try testing.expect(!isIdentifierPart(0xD800));
    try testing.expect(!isIdentifierPart(0xDFFF));
}

test "tables are sorted and non-overlapping" {
    inline for (.{ tables.id_start_ranges[0..], tables.id_continue_ranges[0..] }) |ranges| {
        var prev_end: i32 = -1;
        for (ranges) |r| {
            try testing.expect(r.start <= r.end);
            try testing.expect(@as(i32, r.start) > prev_end);
            prev_end = r.end;
        }
    }
}
