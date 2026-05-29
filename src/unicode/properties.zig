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
const cf_tables = @import("case_fold_tables.zig");

pub const Range = tables.Range;

/// A §22.2.1.1 *property of strings* (the `/v`-mode emoji-sequence sets):
/// single-code-point members folded into `ranges`, plus the multi-code-point
/// emoji `sequences`. These match strings, so they are valid only under the
/// `/v` flag and only in positive (non-complemented) form.
pub const StringProp = tables.StringProp;

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

/// Resolve a Script value — by long name (`Greek`), short code (`Grek`),
/// or alias — to the code points whose General Script is that script.
/// `null` if `name` is not a script ECMA-262 §22.2.1.1 recognises.
pub fn script(name: []const u8) ?[]const Range {
    return tables.script(name);
}

/// Resolve a Script_Extensions value to the code points whose script set
/// includes that script (with the UCD default-to-Script rule for code
/// points absent from ScriptExtensions.txt). `null` if unrecognised.
pub fn scriptExtensions(name: []const u8) ?[]const Range {
    return tables.scriptExtensions(name);
}

/// Resolve a §22.2.1.1 *property of strings* — one of the seven UTS #51
/// emoji-sequence sets (`Basic_Emoji`, `Emoji_Keycap_Sequence`,
/// `RGI_Emoji_Modifier_Sequence`, `RGI_Emoji_Flag_Sequence`,
/// `RGI_Emoji_Tag_Sequence`, `RGI_Emoji_ZWJ_Sequence`, and their union
/// `RGI_Emoji`) — to its single-code-point ranges plus multi-code-point
/// sequence members. `null` if `name` is not such a property; exact match
/// (each property's short name equals its long name).
pub fn stringProperty(name: []const u8) ?StringProp {
    return tables.stringProperty(name);
}

/// The other members of `cp`'s simple case-folding orbit (§22.2.2.9
/// Canonicalize), or an empty slice when `cp` folds only to itself.
/// Backs RegExp `/iu` and `/iv` matching: a pattern code point matches any
/// code point sharing its fold equivalence class. The orbit is built from
/// CaseFolding.txt statuses C and S only (simple/common folding) — full (F)
/// and Turkic (T) mappings are excluded, so ß (U+00DF) folds only to itself
/// while capital ẞ (U+1E9E) shares ß's orbit. The returned slice points
/// into static table data and must not be freed or mutated.
pub fn caseFoldPartners(cp: u21) []const u21 {
    return cf_tables.caseFoldPartners(cp);
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
        "Zs", "Zl", "Zp", "Cc", "Cf", "Cs", "Co", "Cn", "L",  "LC", "M",
        "N",  "P",  "S",  "Z",  "C",
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
    .{ .name = "Lu", .cp = 'A' },    .{ .name = "Ll", .cp = 'a' },    .{ .name = "Lt", .cp = 0x01C5 },
    .{ .name = "Lm", .cp = 0x02B0 }, .{ .name = "Lo", .cp = 0x4E2D }, .{ .name = "Mn", .cp = 0x0300 },
    .{ .name = "Mc", .cp = 0x0903 }, .{ .name = "Me", .cp = 0x0488 }, .{ .name = "Nd", .cp = '0' },
    .{ .name = "Nl", .cp = 0x2160 }, .{ .name = "No", .cp = 0x00B2 }, .{ .name = "Pc", .cp = '_' },
    .{ .name = "Pd", .cp = '-' },    .{ .name = "Ps", .cp = '(' },    .{ .name = "Pe", .cp = ')' },
    .{ .name = "Pi", .cp = 0x00AB }, .{ .name = "Pf", .cp = 0x00BB }, .{ .name = "Po", .cp = '!' },
    .{ .name = "Sm", .cp = '+' },    .{ .name = "Sc", .cp = '$' },    .{ .name = "Sk", .cp = '^' },
    .{ .name = "So", .cp = 0x00A6 }, .{ .name = "Zs", .cp = ' ' },    .{ .name = "Zl", .cp = 0x2028 },
    .{ .name = "Zp", .cp = 0x2029 }, .{ .name = "Cc", .cp = 0x00 },   .{ .name = "Cf", .cp = 0x00AD },
    .{ .name = "Cs", .cp = 0xD800 }, .{ .name = "Co", .cp = 0xE000 }, .{ .name = "Cn", .cp = 0x0378 },
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

fn scIn(name: []const u8, cp: u21) !bool {
    return rangeContains(script(name) orelse return error.UnknownScript, cp);
}

fn scxIn(name: []const u8, cp: u21) !bool {
    return rangeContains(scriptExtensions(name) orelse return error.UnknownScript, cp);
}

test "Script values by long name and short code" {
    try testing.expect(try scIn("Latin", 'A'));
    try testing.expect(try scIn("Latn", 'A')); // short code
    try testing.expect(!try scIn("Latin", 0x03B1)); // Greek alpha
    try testing.expect(try scIn("Greek", 0x03B1));
    try testing.expect(try scIn("Han", 0x4E2D));
    try testing.expect(try scIn("Hani", 0x4E2D)); // short code
    try testing.expect(try scIn("Common", '0')); // digits are Common
    try testing.expect(try scIn("Common", 0x00B7)); // MIDDLE DOT base script
    try testing.expect(!try scIn("Latin", 0x00B7));
}

test "Script Unknown is the @missing complement" {
    try testing.expect(try scIn("Unknown", 0x0378)); // unassigned
    try testing.expect(try scIn("Zzzz", 0x0378)); // short code
    try testing.expect(!try scIn("Unknown", 'A')); // assigned (Latin)
}

test "Script_Extensions: explicit overrides and default-to-Script" {
    // U+00B7 is Common by Script, but its scx set lists Latin, Greek, …
    try testing.expect(try scxIn("Latin", 0x00B7));
    try testing.expect(try scxIn("Greek", 0x00B7));
    try testing.expect(!try scxIn("Common", 0x00B7)); // overridden away from Common
    // 'A' is absent from ScriptExtensions → defaults to its Script (Latin).
    try testing.expect(try scxIn("Latin", 'A'));
    try testing.expect(try scxIn("Greek", 0x03B1)); // default for a plain Greek letter
}

test "script and scx names are disjoint from gc and binary" {
    try testing.expectEqual(@as(?[]const Range, null), script("Lu")); // gc value
    try testing.expectEqual(@as(?[]const Range, null), script("White_Space")); // binary
    try testing.expectEqual(@as(?[]const Range, null), generalCategory("Latin"));
    try testing.expectEqual(@as(?[]const Range, null), binaryProperty("Latin"));
    try testing.expectEqual(@as(?[]const Range, null), script("NotAScript"));
}

fn seqIn(sp: StringProp, s: []const u21) bool {
    for (sp.sequences) |seq| if (std.mem.eql(u21, seq, s)) return true;
    return false;
}

test "Basic_Emoji: single code points fold into ranges, pairs into sequences" {
    const be = stringProperty("Basic_Emoji").?;
    try testing.expect(rangeContains(be.ranges, 0x231A)); // ⌚ WATCH (single cp)
    try testing.expect(rangeContains(be.ranges, 0x1F600)); // 😀 (single cp)
    try testing.expect(!rangeContains(be.ranges, 'A'));
    try testing.expect(seqIn(be, &.{ 0xA9, 0xFE0F })); // ©️ (text-style + VS16)
    try testing.expect(!seqIn(be, &.{ 0xA9, 0x41 }));
}

test "flag / keycap / zwj sequences are multi-code-point members" {
    const flag = stringProperty("RGI_Emoji_Flag_Sequence").?;
    try testing.expectEqual(@as(usize, 0), flag.ranges.len); // all sequences, no singles
    try testing.expect(seqIn(flag, &.{ 0x1F1E6, 0x1F1E8 })); // 🇦🇨

    const keycap = stringProperty("Emoji_Keycap_Sequence").?;
    try testing.expect(seqIn(keycap, &.{ 0x23, 0xFE0F, 0x20E3 })); // #️⃣

    const zwj = stringProperty("RGI_Emoji_ZWJ_Sequence").?;
    try testing.expect(seqIn(zwj, &.{ 0x1F468, 0x200D, 0x1F466 })); // 👨‍👦 family
}

test "RGI_Emoji is the union of the six sub-properties" {
    const rgi = stringProperty("RGI_Emoji").?;
    // single-cp Basic_Emoji member survives in the union's ranges
    try testing.expect(rangeContains(rgi.ranges, 0x231A));
    // a member drawn from each multi-cp sub-property
    try testing.expect(seqIn(rgi, &.{ 0xA9, 0xFE0F })); // Basic_Emoji pair
    try testing.expect(seqIn(rgi, &.{ 0x1F1E6, 0x1F1E8 })); // Flag
    try testing.expect(seqIn(rgi, &.{ 0x23, 0xFE0F, 0x20E3 })); // Keycap
    try testing.expect(seqIn(rgi, &.{ 0x1F468, 0x200D, 0x1F466 })); // ZWJ
}

test "string-property names are disjoint from gc/binary/script; unknown is null" {
    try testing.expectEqual(@as(?StringProp, null), stringProperty("NotAStringProp"));
    try testing.expectEqual(@as(?StringProp, null), stringProperty("basic_emoji")); // case-sensitive
    try testing.expectEqual(@as(?StringProp, null), stringProperty("Lu")); // gc value
    try testing.expectEqual(@as(?StringProp, null), stringProperty("Emoji")); // binary, not a string prop
    // and the reverse: a string-prop name is not a gc/binary/script value
    try testing.expectEqual(@as(?[]const Range, null), generalCategory("RGI_Emoji"));
    try testing.expectEqual(@as(?[]const Range, null), binaryProperty("RGI_Emoji"));
    try testing.expectEqual(@as(?[]const Range, null), script("Basic_Emoji"));
}

// ---------------------------------------------------------------------------
// Tests — independent ground truth for the §22.2.2.9 case-folding orbits.
// ---------------------------------------------------------------------------

fn foldsTo(a: u21, b: u21) bool {
    for (caseFoldPartners(a)) |p| {
        if (p == b) return true;
    }
    return false;
}

test "case-fold orbit: ASCII letters pair up" {
    try testing.expectEqual(@as(usize, 1), caseFoldPartners('a').len);
    try testing.expect(foldsTo('a', 'A'));
    try testing.expect(foldsTo('A', 'a'));
    try testing.expect(!foldsTo('a', 'b'));
}

test "case-fold orbit: K, k, and KELVIN SIGN share one class" {
    // U+004B K, U+006B k, and U+212A KELVIN SIGN all simple-fold to U+006B
    // (CaseFolding.txt statuses C/C/C), so the orbit has three members.
    for ([_]u21{ 0x004B, 0x006B, 0x212A }) |m|
        try testing.expectEqual(@as(usize, 2), caseFoldPartners(m).len);
    try testing.expect(foldsTo(0x004B, 0x006B));
    try testing.expect(foldsTo(0x004B, 0x212A));
    try testing.expect(foldsTo(0x006B, 0x212A));
    try testing.expect(foldsTo(0x212A, 0x004B));
    try testing.expect(foldsTo(0x212A, 0x006B));
}

test "case-fold orbit: capital sharp S joins small sharp S, never the full fold" {
    // ß (U+00DF) has only a full (F) fold to "ss", excluded from simple
    // folding, so its sole simple-fold partner is capital ẞ (U+1E9E,
    // status S → 00DF). §22.2.2.9 thus makes /ß/iu match ẞ but never "ss".
    try testing.expectEqual(@as(usize, 1), caseFoldPartners(0x00DF).len);
    try testing.expect(foldsTo(0x00DF, 0x1E9E));
    try testing.expect(foldsTo(0x1E9E, 0x00DF));
}

test "case-fold orbit: Greek sigma has three members" {
    // Σ (U+03A3) and final ς (U+03C2) both fold to σ (U+03C3).
    for ([_]u21{ 0x03A3, 0x03C2, 0x03C3 }) |m|
        try testing.expectEqual(@as(usize, 2), caseFoldPartners(m).len);
    try testing.expect(foldsTo(0x03A3, 0x03C3));
    try testing.expect(foldsTo(0x03C2, 0x03C3));
    try testing.expect(foldsTo(0x03C3, 0x03A3));
    try testing.expect(foldsTo(0x03C3, 0x03C2));
}

test "case-fold orbit: supplementary-plane Deseret pairs in plane" {
    // Simple folding is length-preserving: U+10400 ↔ U+10428 (Deseret),
    // both supplementary, no cross-plane fold.
    try testing.expectEqual(@as(usize, 1), caseFoldPartners(0x10400).len);
    try testing.expect(foldsTo(0x10400, 0x10428));
    try testing.expect(foldsTo(0x10428, 0x10400));
}

test "case-fold orbit: caseless and uncased code points fold to themselves" {
    try testing.expectEqual(@as(usize, 0), caseFoldPartners('5').len);
    try testing.expectEqual(@as(usize, 0), caseFoldPartners(0x4E2D).len); // CJK 中
    try testing.expectEqual(@as(usize, 0), caseFoldPartners(' ').len);
}

test "every case-fold orbit is symmetric and excludes its own member" {
    // Whole-table self-consistency: if b ∈ partners(a) then a ∈ partners(b),
    // and a ∉ partners(a) (a member never lists itself).
    for (cf_tables.entries) |e| {
        for (caseFoldPartners(e.cp)) |b| {
            try testing.expect(b != e.cp); // never self
            try testing.expect(foldsTo(b, e.cp)); // symmetric
        }
    }
}
