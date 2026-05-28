//! Unicode property lookups backing RegExp `\p{…}` / `\P{…}` escapes
//! (ECMA-262 §22.2.1.1, UnicodePropertyValueExpression).
//!
//! The matcher (Perlex) stays free of Unicode data: its compiler asks an
//! injected resolver for the code-point ranges of a property and bakes them
//! into an ordinary character-class instruction. This module is that data —
//! a thin, typed wrapper over the generated `property_tables.zig`, which is
//! produced by `zig build gen-unicode` from the vendored UCD files. The
//! shape mirrors `idents.zig` over `ident_tables.zig`: generated sorted
//! ranges, binary-searched here.
//!
//! Cynic tracks the Unicode "latest" version per §3 (currently 17.0). A
//! version bump re-vendors the UCD inputs and re-runs the generator.

const std = @import("std");
const tables = @import("property_tables.zig");

pub const Range = tables.Range;

/// Resolve a `General_Category` value — by abbreviation (`Lu`), long name
/// (`Uppercase_Letter`), or spec alias (`cntrl`, `digit`, `punct`,
/// `Combining_Mark`) — to its sorted, non-overlapping code-point ranges.
/// Returns `null` when `name` is not a General_Category value ECMA-262
/// recognises; matching is exact and case-sensitive (§22.2.1.1 performs no
/// loose UCD matching). Group values (`L`, `C`, `M`, `N`, `P`, `S`, `Z`,
/// `LC`) resolve to the union of their member categories.
pub fn generalCategory(name: []const u8) ?[]const Range {
    return tables.generalCategory(name);
}

/// Resolve a binary Unicode property — by canonical name (`White_Space`)
/// or alias (`WSpace`, `space`) — to its sorted, non-overlapping ranges.
/// Returns `null` when `name` is not a binary property ECMA-262 §22.2.1.1
/// recognises; exact, case-sensitive match. `ASCII`, `Any`, and `Assigned`
/// are synthesised (`Assigned` is the complement of General_Category `Cn`).
pub fn binaryProperty(name: []const u8) ?[]const Range {
    return tables.binaryProperty(name);
}

/// True iff `cp` lies within any range of `ranges`, which must be sorted by
/// `start` and non-overlapping (the generator guarantees this).
pub fn rangeContains(ranges: []const Range, cp: u21) bool {
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
// Tests — independent ground truth for the generated General_Category data.
// ---------------------------------------------------------------------------

const testing = std.testing;

fn has(name: []const u8, cp: u21) !bool {
    const ranges = generalCategory(name) orelse return error.UnknownProperty;
    return rangeContains(ranges, cp);
}

test "atomic categories classify ASCII letters" {
    try testing.expect(try has("Lu", 'A'));
    try testing.expect(!try has("Lu", 'a'));
    try testing.expect(try has("Ll", 'a'));
    try testing.expect(!try has("Ll", 'A'));
}

test "long names and aliases resolve to the same set as abbreviations" {
    try testing.expect(try has("Uppercase_Letter", 'A'));
    try testing.expect(try has("Lowercase_Letter", 'a'));
    try testing.expect(try has("Decimal_Number", '0'));
    try testing.expect(try has("digit", '0')); // Nd alias
    try testing.expect(try has("Control", 0x00));
    try testing.expect(try has("cntrl", 0x1F)); // Cc alias
    try testing.expect(try has("Combining_Mark", 0x0300)); // M alias (Mn)
    try testing.expect(try has("punct", '!')); // P alias (Po)
}

test "group categories union their members" {
    // L = Lu | Ll | Lt | Lm | Lo
    try testing.expect(try has("L", 'A'));
    try testing.expect(try has("L", 'a'));
    try testing.expect(try has("Letter", 0x4E2D)); // CJK (Lo)
    try testing.expect(!try has("L", '0'));
    // N = Nd | Nl | No
    try testing.expect(try has("N", '0'));
    // Cased_Letter (LC) = Lu | Lt | Ll — letters yes, digits no
    try testing.expect(try has("LC", 'A'));
    try testing.expect(try has("LC", 'a'));
    try testing.expect(!try has("LC", '0'));
}

test "symbols, punctuation, separators" {
    try testing.expect(try has("Sm", '+')); // Math_Symbol
    try testing.expect(try has("Po", '!')); // Other_Punctuation
    try testing.expect(try has("Zs", 0x20)); // Space_Separator
    try testing.expect(try has("Pe", ')')); // Close_Punctuation
}

test "supplementary-plane code points classify" {
    try testing.expect(try has("Lu", 0x10400)); // DESERET CAPITAL LETTER LONG I
    try testing.expect(try has("Ll", 0x10428)); // deseret small
}

test "unknown or wrongly-cased names return null" {
    try testing.expectEqual(@as(?[]const Range, null), generalCategory("NotAProperty"));
    try testing.expectEqual(@as(?[]const Range, null), generalCategory("lu")); // case-sensitive
    try testing.expectEqual(@as(?[]const Range, null), generalCategory(""));
    try testing.expectEqual(@as(?[]const Range, null), generalCategory("Letter_X"));
}

test "every generated category table is sorted and non-overlapping" {
    const names = [_][]const u8{
        "Lu", "Ll", "Lt", "Lm", "Lo", "Mn", "Mc", "Me", "Nd", "Nl", "No",
        "Pc", "Pd", "Ps", "Pe", "Pi", "Pf", "Po", "Sm", "Sc", "Sk", "So",
        "Zs", "Zl", "Zp", "Cc", "Cf", "Cs", "Co", "Cn",
        "L",  "LC", "M",  "N",  "P",  "S",  "Z",  "C",
    };
    for (names) |name| {
        const ranges = generalCategory(name) orelse return error.MissingCategory;
        var prev_end: i32 = -1;
        for (ranges) |r| {
            try testing.expect(r.start <= r.end);
            try testing.expect(@as(i32, r.start) > prev_end); // sorted + gap (merged)
            prev_end = r.end;
        }
    }
}

const Rep = struct { name: []const u8, cp: u21 };

/// One stable, well-known representative code point per atomic gc value.
const atomic_reps = [_]Rep{
    .{ .name = "Lu", .cp = 'A' },      .{ .name = "Ll", .cp = 'a' },      .{ .name = "Lt", .cp = 0x01C5 },
    .{ .name = "Lm", .cp = 0x02B0 },   .{ .name = "Lo", .cp = 0x4E2D },   .{ .name = "Mn", .cp = 0x0300 },
    .{ .name = "Mc", .cp = 0x0903 },   .{ .name = "Me", .cp = 0x0488 },   .{ .name = "Nd", .cp = '0' },
    .{ .name = "Nl", .cp = 0x2160 },   .{ .name = "No", .cp = 0x00B2 },   .{ .name = "Pc", .cp = '_' },
    .{ .name = "Pd", .cp = '-' },      .{ .name = "Ps", .cp = '(' },      .{ .name = "Pe", .cp = ')' },
    .{ .name = "Pi", .cp = 0x00AB },   .{ .name = "Pf", .cp = 0x00BB },   .{ .name = "Po", .cp = '!' },
    .{ .name = "Sm", .cp = '+' },      .{ .name = "Sc", .cp = '$' },      .{ .name = "Sk", .cp = '^' },
    .{ .name = "So", .cp = 0x00A6 },   .{ .name = "Zs", .cp = ' ' },      .{ .name = "Zl", .cp = 0x2028 },
    .{ .name = "Zp", .cp = 0x2029 },   .{ .name = "Cc", .cp = 0x00 },     .{ .name = "Cf", .cp = 0x00AD },
    .{ .name = "Cs", .cp = 0xD800 },   .{ .name = "Co", .cp = 0xE000 },   .{ .name = "Cn", .cp = 0x0378 },
};

test "all 30 atomic categories classify their representative code point" {
    for (atomic_reps) |r| {
        const ranges = generalCategory(r.name) orelse {
            std.debug.print("missing category {s}\n", .{r.name});
            return error.MissingCategory;
        };
        testing.expect(rangeContains(ranges, r.cp)) catch |e| {
            std.debug.print("category {s} should contain U+{X:0>4}\n", .{ r.name, r.cp });
            return e;
        };
    }
}

test "tricky category boundaries" {
    try testing.expect(try has("Cc", 0x7F)); // DELETE is Cc
    try testing.expect(try has("Cc", 0x80)); // C1 controls are Cc
    try testing.expect(try has("Zs", 0xA0)); // NO-BREAK SPACE is Zs, not Cc
    try testing.expect(!try has("Zs", 0x2029)); // PARAGRAPH SEPARATOR is Zp, not Zs
    try testing.expect(try has("Cs", 0xDFFF)); // top of surrogate block
    try testing.expect(!try has("Co", 0xDFFF)); // surrogates are Cs, not Co
    try testing.expect(try has("Co", 0x10FFFD)); // plane-16 private use
}

test "every code point belongs to exactly one atomic General_Category" {
    var ranges: [atomic_reps.len][]const Range = undefined;
    for (atomic_reps, 0..) |r, i| ranges[i] = generalCategory(r.name).?;

    const check = struct {
        fn one(rs: []const []const Range, cp: u21) !void {
            var count: usize = 0;
            for (rs) |r| {
                if (rangeContains(r, cp)) count += 1;
            }
            if (count != 1) {
                std.debug.print("U+{X:0>4} is in {d} atomic categories (want 1)\n", .{ cp, count });
                return error.NotPartitioned;
            }
        }
    }.one;

    var cp: u21 = 0;
    while (cp <= 0x2FFF) : (cp += 1) try check(&ranges, cp); // dense BMP sweep
    for ([_]u21{ 0xFFFF, 0x10000, 0x10428, 0x1F600, 0x20000, 0xE0000, 0x10FFFF }) |hi| {
        try check(&ranges, hi); // scattered supplementary checks (incl. noncharacters → Cn)
    }
}

test "grouped categories union and agree across spellings" {
    // Each group, by abbreviation, must contain every member representative.
    const groups = [_]struct { abbr: []const u8, long: []const u8, members: []const []const u8 }{
        .{ .abbr = "L", .long = "Letter", .members = &.{ "Lu", "Ll", "Lt", "Lm", "Lo" } },
        .{ .abbr = "LC", .long = "Cased_Letter", .members = &.{ "Lu", "Ll", "Lt" } },
        .{ .abbr = "M", .long = "Mark", .members = &.{ "Mn", "Mc", "Me" } },
        .{ .abbr = "N", .long = "Number", .members = &.{ "Nd", "Nl", "No" } },
        .{ .abbr = "P", .long = "Punctuation", .members = &.{ "Pc", "Pd", "Ps", "Pe", "Pi", "Pf", "Po" } },
        .{ .abbr = "S", .long = "Symbol", .members = &.{ "Sm", "Sc", "Sk", "So" } },
        .{ .abbr = "Z", .long = "Separator", .members = &.{ "Zs", "Zl", "Zp" } },
        .{ .abbr = "C", .long = "Other", .members = &.{ "Cc", "Cf", "Cs", "Co", "Cn" } },
    };
    for (groups) |g| {
        const by_abbr = generalCategory(g.abbr).?;
        const by_long = generalCategory(g.long).?;
        try testing.expectEqual(by_abbr.len, by_long.len); // same canonical set
        for (g.members) |m| {
            // find this member's representative
            for (atomic_reps) |r| {
                if (std.mem.eql(u8, r.name, m)) {
                    try testing.expect(rangeContains(by_abbr, r.cp));
                    try testing.expect(rangeContains(by_long, r.cp));
                }
            }
        }
    }
}

fn binIn(name: []const u8, cp: u21) !bool {
    const ranges = binaryProperty(name) orelse return error.UnknownProperty;
    return rangeContains(ranges, cp);
}

test "binary properties classify representatives and aliases" {
    try testing.expect(try binIn("White_Space", 0x20));
    try testing.expect(try binIn("White_Space", 0x09));
    try testing.expect(try binIn("White_Space", 0xA0)); // NBSP
    try testing.expect(try binIn("WSpace", 0x20)); // alias
    try testing.expect(try binIn("space", 0x20)); // alias
    try testing.expect(!try binIn("White_Space", 'A'));
    try testing.expect(try binIn("Alphabetic", 'A'));
    try testing.expect(try binIn("Alpha", 0x4E2D)); // alias, CJK
    try testing.expect(!try binIn("Alphabetic", '0'));
    try testing.expect(try binIn("ASCII_Hex_Digit", 'F'));
    try testing.expect(try binIn("AHex", 'f')); // alias
    try testing.expect(try binIn("Hex_Digit", '0'));
    try testing.expect(!try binIn("ASCII_Hex_Digit", 'g'));
    try testing.expect(try binIn("Lowercase", 'a'));
    try testing.expect(try binIn("Uppercase", 'A'));
    try testing.expect(!try binIn("Lowercase", 'A'));
}

test "synthesized binary properties: ASCII, Any, Assigned" {
    try testing.expect(try binIn("ASCII", 0x00));
    try testing.expect(try binIn("ASCII", 0x7F));
    try testing.expect(!try binIn("ASCII", 0x80));
    try testing.expect(try binIn("Any", 0x00));
    try testing.expect(try binIn("Any", 0x10FFFF));
    try testing.expect(try binIn("Assigned", 'A')); // assigned
    try testing.expect(!try binIn("Assigned", 0x0378)); // unassigned (Cn)
    try testing.expect(try binIn("Assigned", 0x10FFFD)); // plane-16 PUA (Co)
}

test "emoji binary properties" {
    try testing.expect(try binIn("Emoji", 0x1F600)); // grinning face
    try testing.expect(try binIn("Emoji_Presentation", 0x1F600));
    try testing.expect(try binIn("Extended_Pictographic", 0x1F600));
    try testing.expect(try binIn("Regional_Indicator", 0x1F1E6)); // 🇦
    try testing.expect(!try binIn("Emoji", 'A'));
}

test "binary and gc name spaces are disjoint; unknown returns null" {
    try testing.expectEqual(@as(?[]const Range, null), binaryProperty("NotABinaryProp"));
    try testing.expectEqual(@as(?[]const Range, null), binaryProperty("white_space")); // case-sensitive
    try testing.expectEqual(@as(?[]const Range, null), binaryProperty("Lu")); // gc value, not binary
    try testing.expectEqual(@as(?[]const Range, null), generalCategory("White_Space")); // binary, not gc
}

test "Assigned is exactly the complement of Cn over a sample" {
    const cn = generalCategory("Cn").?;
    const assigned = binaryProperty("Assigned").?;
    var cp: u21 = 0;
    while (cp <= 0x3000) : (cp += 1) {
        if (rangeContains(cn, cp) == rangeContains(assigned, cp)) {
            std.debug.print("U+{X:0>4}: Cn and Assigned agree (should be opposite)\n", .{cp});
            return error.NotComplement;
        }
    }
}
