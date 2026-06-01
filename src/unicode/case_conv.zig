//! Default Case Conversion (Unicode §3.13) plus the `Cased` and
//! `Case_Ignorable` derived properties. Backs §22.1.3.{26,27,28,29}
//! String.prototype.to{Lower,Upper}Case (and the toLocale* variants for
//! the default / `en` locale) and the non-`/u` RegExp Canonicalize
//! (§22.2.2.7.3 toUppercase).
//!
//! Thin, stable wrapper over the generated `case_conv_tables.zig` — the
//! generated file is rewritten wholesale by `zig build gen-unicode`, so
//! the public API and the hand-verified regression tests live here where
//! they survive regeneration.
//!
//! Case CONVERSION (this file) is distinct from case FOLDING
//! (`case_fold_tables.zig`, used by RegExp `/iu`/`/iv`): conversion is the
//! language-independent Default Case Conversion, folding is the canonical
//! caseless-match relation. The conditional SpecialCasing entries are not
//! baked in — Final_Sigma is resolved by `string.zig`'s context lookahead
//! over `isCased` / `isCaseIgnorable`, and the locale-specific `lt`/`tr`/
//! `az` mappings are out of scope (Intl).

const std = @import("std");
const tables = @import("case_conv_tables.zig");

/// Write the unconditional Default Case Conversion of `cp` into `res`
/// (1-3 code points) and return the count. `to_upper` selects uppercase,
/// else lowercase; an uncased code point maps to itself (count 1).
pub fn convert(res: *[3]u21, cp: u21, to_upper: bool) usize {
    return tables.convert(res, cp, to_upper);
}

/// §22.1.3.26 step 4.a — the Unicode `Cased` derived property.
pub fn isCased(cp: u21) bool {
    return tables.isCased(cp);
}

/// §22.1.3.26 step 4.a — the Unicode `Case_Ignorable` derived property.
pub fn isCaseIgnorable(cp: u21) bool {
    return tables.isCaseIgnorable(cp);
}

// ---------------------------------------------------------------------------
// Tests — hand-verified against vendor/unicode/{UnicodeData,SpecialCasing,
// DerivedCoreProperties}.txt (Unicode 17.0.0). The generator's full-corpus
// equivalence was cross-checked against an independent implementation; these
// anchor the spec-cited edge cases against regeneration drift.
// ---------------------------------------------------------------------------

const testing = std.testing;

fn expectUpper(cp: u21, want: []const u21) !void {
    var res: [3]u21 = undefined;
    const n = convert(&res, cp, true);
    try testing.expectEqualSlices(u21, want, res[0..n]);
}

fn expectLower(cp: u21, want: []const u21) !void {
    var res: [3]u21 = undefined;
    const n = convert(&res, cp, false);
    try testing.expectEqualSlices(u21, want, res[0..n]);
}

test "ASCII letters convert 1:1" {
    try expectUpper('a', &.{'A'});
    try expectUpper('z', &.{'Z'});
    try expectLower('A', &.{'a'});
    try expectLower('Z', &.{'z'});
}

test "uncased code points map to themselves" {
    try expectUpper('5', &.{'5'});
    try expectLower('5', &.{'5'});
    try expectUpper(' ', &.{' '});
    // Astral non-cased (U+1F600 GRINNING FACE) round-trips identity.
    try expectUpper(0x1F600, &.{0x1F600});
    try expectLower(0x1F600, &.{0x1F600});
    // 'A' uppercases to itself.
    try expectUpper('A', &.{'A'});
}

test "ß and ligatures expand on uppercase (SpecialCasing)" {
    // 00DF; …; 0053 0053; → "SS"; lowercase is identity.
    try expectUpper(0x00DF, &.{ 'S', 'S' });
    try expectLower(0x00DF, &.{0x00DF});
    // FB00 LATIN SMALL LIGATURE FF → "FF".
    try expectUpper(0xFB00, &.{ 'F', 'F' });
}

test "İ lowercases to i + combining dot above (SpecialCasing)" {
    // 0130; 0069 0307; → unconditional full lowercase; tr/az dropped.
    try expectLower(0x0130, &.{ 0x0069, 0x0307 });
}

test "simple non-ASCII mappings" {
    // 00B5 MICRO SIGN uppercases to 039C GREEK CAPITAL LETTER MU.
    try expectUpper(0x00B5, &.{0x039C});
    // 0131 LATIN SMALL LETTER DOTLESS I uppercases to 'I'.
    try expectUpper(0x0131, &.{'I'});
    // U+03A3 GREEK CAPITAL LETTER SIGMA lowercases to U+03C3 (the
    // Final_Sigma override to U+03C2 lives in string.zig, not the table).
    try expectLower(0x03A3, &.{0x03C3});
    // Cherokee round-trip (added in Unicode 8.0).
    try expectLower(0x13A0, &.{0xAB70});
    try expectUpper(0xAB70, &.{0x13A0});
}

test "astral (supplementary) cased letters round-trip" {
    // Deseret U+10400 ↔ U+10428.
    try expectLower(0x10400, &.{0x10428});
    try expectUpper(0x10428, &.{0x10400});
    // Adlam U+1E900 ↔ U+1E922.
    try expectLower(0x1E900, &.{0x1E922});
    try expectUpper(0x1E922, &.{0x1E900});
}

test "title-case letter (Lt) maps to its upper and lower variants" {
    // 01C5 ǅ (Lt): uppercase 01C4 Ǆ, lowercase 01C6 ǆ.
    try expectUpper(0x01C5, &.{0x01C4});
    try expectLower(0x01C5, &.{0x01C6});
    // The all-caps form 01C4 lowercases to 01C6 (not the title form).
    try expectLower(0x01C4, &.{0x01C6});
}

test "multi-code-point uppercase expansions (SpecialCasing)" {
    // FB01 ﬁ → "FI", FB06 ﬆ → "ST" (length 2);
    try expectUpper(0xFB01, &.{ 'F', 'I' });
    try expectUpper(0xFB06, &.{ 'S', 'T' });
    // FB03 ﬃ → "FFI" exercises the length-3 result path.
    try expectUpper(0xFB03, &.{ 'F', 'F', 'I' });
    // 0149 ŉ → "ʼN" (U+02BC MODIFIER LETTER APOSTROPHE + 'N'); lowercase
    // is identity.
    try expectUpper(0x0149, &.{ 0x02BC, 'N' });
    try expectLower(0x0149, &.{0x0149});
}

test "isCased" {
    try testing.expect(isCased('a'));
    try testing.expect(isCased('A'));
    try testing.expect(isCased(0x03A3)); // Σ
    try testing.expect(isCased(0x10400)); // astral Deseret capital
    try testing.expect(isCased(0x01C5)); // Lt title-case letter
    try testing.expect(isCased(0x0345)); // COMBINING GREEK YPOGEGRAMMENI (Mn, Cased)
    try testing.expect(!isCased('5'));
    try testing.expect(!isCased(' '));
    try testing.expect(!isCased(0x1F600));
}

test "isCaseIgnorable" {
    try testing.expect(isCaseIgnorable(0x0027)); // APOSTROPHE
    try testing.expect(isCaseIgnorable(0x002E)); // FULL STOP
    try testing.expect(isCaseIgnorable(0x0300)); // COMBINING GRAVE ACCENT
    try testing.expect(!isCaseIgnorable('a'));
    try testing.expect(!isCaseIgnorable(' '));
}

test "generated tables are sorted (binary-search invariant)" {
    inline for (.{ tables.upper_entries[0..], tables.lower_entries[0..] }) |entries| {
        var prev: i64 = -1;
        for (entries) |e| {
            try testing.expect(@as(i64, e.cp) > prev);
            prev = e.cp;
        }
    }
    inline for (.{ tables.cased_ranges[0..], tables.case_ignorable_ranges[0..] }) |ranges| {
        var prev_hi: i64 = -1;
        for (ranges) |r| {
            try testing.expect(r.lo <= r.hi);
            try testing.expect(@as(i64, r.lo) > prev_hi);
            prev_hi = r.hi;
        }
    }
}
