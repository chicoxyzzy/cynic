//! Unicode Normalization Forms (§3.11 / UAX #15): NFC, NFD, NFKC, NFKD.
//! Backs §22.1.3.16 String.prototype.normalize and the localeCompare NFD
//! canonical-equivalence path.
//!
//! The pipeline is the textbook three-step:
//!   1. Decompose — replace each code point with its full canonical
//!      (NFD/NFC) or compatibility (NFKD/NFKC) decomposition. Hangul
//!      syllables decompose algorithmically (§3.12); everything else
//!      reads `normalization_tables.zig`.
//!   2. Canonical ordering — stably sort each maximal run of non-starters
//!      by Canonical_Combining_Class.
//!   3. Compose (NFC/NFKC only) — recombine starter/back pairs that have a
//!      primary composite and are not blocked (§3.11 D115), Hangul again
//!      algorithmically.
//!
//! Operates on code points (u32, so unpaired surrogate values pass
//! through unchanged — §3.11 treats them as themselves).

const std = @import("std");
const tables = @import("normalization_tables.zig");

pub const Form = enum { nfc, nfd, nfkc, nfkd };

// §3.12 Hangul syllable composition constants.
const s_base: u21 = 0xAC00;
const l_base: u21 = 0x1100;
const v_base: u21 = 0x1161;
const t_base: u21 = 0x11A7;
const l_count: u21 = 19;
const v_count: u21 = 21;
const t_count: u21 = 28;
const n_count: u21 = v_count * t_count; // 588
const s_count: u21 = l_count * n_count; // 11172

/// Normalize `src` (a code-point list) into `form`. The returned slice is
/// owned by the caller (free with `allocator.free`).
pub fn normalize(allocator: std.mem.Allocator, src: []const u32, form: Form) std.mem.Allocator.Error![]u32 {
    const use_compat = form == .nfkc or form == .nfkd;
    const do_compose = form == .nfc or form == .nfkc;

    var buf: std.ArrayListUnmanaged(u32) = .empty;
    errdefer buf.deinit(allocator);

    // 1. decompose
    for (src) |cp| try decomposeInto(allocator, &buf, @intCast(cp), use_compat);
    // 2. canonical ordering
    canonicalOrder(buf.items);
    // 3. compose
    if (do_compose) composeInPlace(&buf);

    return buf.toOwnedSlice(allocator);
}

/// Append the full decomposition of `cp` to `out`. Hangul is algorithmic;
/// the tables already hold fully-recursive sequences, so no per-call
/// recursion is needed.
fn decomposeInto(
    allocator: std.mem.Allocator,
    out: *std.ArrayListUnmanaged(u32),
    cp: u21,
    use_compat: bool,
) std.mem.Allocator.Error!void {
    // §3.12 Hangul Syllable Decomposition (canonical; subsumed by compat).
    if (cp >= s_base and cp < s_base + s_count) {
        const s_index = cp - s_base;
        const l = l_base + s_index / n_count;
        const v = v_base + (s_index % n_count) / t_count;
        const t = t_base + s_index % t_count;
        try out.append(allocator, l);
        try out.append(allocator, v);
        if (t != t_base) try out.append(allocator, t);
        return;
    }
    // The compatibility table is a superset of the canonical one (it holds
    // a fully-expanded entry for every code point with any decomposition),
    // so a single lookup suffices per form.
    const seq = if (use_compat)
        tables.compatibilityDecomposition(cp)
    else
        tables.canonicalDecomposition(cp);
    if (seq) |s| {
        for (s) |c| try out.append(allocator, c);
        return;
    }
    try out.append(allocator, cp);
}

/// §3.11 Canonical Ordering — within each maximal run of non-starters
/// (Canonical_Combining_Class ≠ 0), stably sort by combining class.
fn canonicalOrder(cps: []u32) void {
    var i: usize = 0;
    while (i < cps.len) {
        if (tables.combiningClass(@intCast(cps[i])) == 0) {
            i += 1;
            continue;
        }
        var j = i;
        while (j < cps.len and tables.combiningClass(@intCast(cps[j])) != 0) j += 1;
        stableSortByClass(cps[i..j]);
        i = j;
    }
}

/// Stable insertion sort keyed on combining class.
fn stableSortByClass(run: []u32) void {
    var i: usize = 1;
    while (i < run.len) : (i += 1) {
        const cur = run[i];
        const cur_class = tables.combiningClass(@intCast(cur));
        var j = i;
        while (j > 0 and tables.combiningClass(@intCast(run[j - 1])) > cur_class) : (j -= 1) {
            run[j] = run[j - 1];
        }
        run[j] = cur;
    }
}

/// §3.11 Canonical Composition — recombine in place over an already
/// decomposed + canonically-ordered buffer. `D115`: a code point is
/// *blocked* from the current starter when the immediately preceding
/// output character is a non-starter whose class ≥ its own (canonical
/// ordering makes that predecessor the maximum-class blocker).
fn composeInPlace(buf: *std.ArrayListUnmanaged(u32)) void {
    const a = buf.items;
    const n = a.len;
    if (n == 0) return;

    var write: usize = 1; // a[0] is always kept
    var starter: usize = 0; // output index of the latest starter
    var have_starter = tables.combiningClass(@intCast(a[0])) == 0;
    var prev_class: u8 = tables.combiningClass(@intCast(a[0]));

    var i: usize = 1;
    while (i < n) : (i += 1) {
        const ch: u21 = @intCast(a[i]);
        const cc = tables.combiningClass(ch);

        var composed = false;
        if (have_starter) {
            const blocked = prev_class != 0 and prev_class >= cc;
            if (!blocked) {
                if (tryCompose(@intCast(a[starter]), ch)) |comp| {
                    a[starter] = comp;
                    composed = true; // ch consumed; prev_class unchanged
                }
            }
        }
        if (!composed) {
            a[write] = a[i];
            if (cc == 0) {
                starter = write;
                have_starter = true;
            }
            prev_class = cc;
            write += 1;
        }
    }
    buf.items.len = write;
}

/// Primary composite of the ordered pair (l, ch): Hangul L+V / LV+T
/// algorithmically (§3.12), otherwise the generated table.
fn tryCompose(l: u21, ch: u21) ?u21 {
    // L jamo + V jamo → LV syllable.
    if (l >= l_base and l < l_base + l_count and ch >= v_base and ch < v_base + v_count) {
        const li = l - l_base;
        const vi = ch - v_base;
        return s_base + (li * v_count + vi) * t_count;
    }
    // LV syllable + T jamo → LVT syllable.
    if (l >= s_base and l < s_base + s_count and (l - s_base) % t_count == 0 and
        ch > t_base and ch < t_base + t_count)
    {
        return l + (ch - t_base);
    }
    return tables.compose(l, ch);
}

// ---------------------------------------------------------------------------
// Tests — hand-verified against the Unicode spec examples. The exhaustive
// NormalizationTest.txt conformance pass runs as a dev-time cross-check.
// ---------------------------------------------------------------------------

const testing = std.testing;

fn expectNorm(form: Form, src: []const u32, want: []const u32) !void {
    const got = try normalize(testing.allocator, src, form);
    defer testing.allocator.free(got);
    try testing.expectEqualSlices(u32, want, got);
}

test "NFD/NFC canonical decomposition + recomposition" {
    // Å U+00C5 → U+0041 U+030A (A + combining ring above); NFC recomposes.
    try expectNorm(.nfd, &.{0x00C5}, &.{ 0x0041, 0x030A });
    try expectNorm(.nfc, &.{ 0x0041, 0x030A }, &.{0x00C5});
    try expectNorm(.nfc, &.{0x00C5}, &.{0x00C5});
    // Recursive: Å U+212B ANGSTROM SIGN → U+0041 U+030A; NFC → U+00C5.
    try expectNorm(.nfd, &.{0x212B}, &.{ 0x0041, 0x030A });
    try expectNorm(.nfc, &.{0x212B}, &.{0x00C5});
}

test "singleton decomposition (Ω OHM → Ω OMEGA under NFC)" {
    // U+2126 OHM SIGN has a singleton canonical decomposition to U+03A9.
    try expectNorm(.nfd, &.{0x2126}, &.{0x03A9});
    try expectNorm(.nfc, &.{0x2126}, &.{0x03A9});
}

test "canonical ordering of combining marks" {
    // e + acute(ccc 230) + dot-below(ccc 220): NFD reorders the lower
    // class first → e, dot-below, acute.
    try expectNorm(.nfd, &.{ 0x0065, 0x0301, 0x0323 }, &.{ 0x0065, 0x0323, 0x0301 });
    // NFC composes e+dot-below → U+1EB9, then +acute(230) is not blocked
    // by dot-below(220) → U+1EC7 (e with circumflex? no: e-dot-below+acute
    // has no precomposed form, so acute stays) — verify via the table:
    // 1EB9 + 0301 has no composite, so result is U+1EB9 U+0301.
    try expectNorm(.nfc, &.{ 0x0065, 0x0301, 0x0323 }, &.{ 0x1EB9, 0x0301 });
}

test "Hangul algorithmic decomposition + composition" {
    // 가 U+AC00 = L U+1100 + V U+1161 (no trailing T).
    try expectNorm(.nfd, &.{0xAC00}, &.{ 0x1100, 0x1161 });
    try expectNorm(.nfc, &.{ 0x1100, 0x1161 }, &.{0xAC00});
    // 각 U+AC01 = L U+1100 + V U+1161 + T U+11A8.
    try expectNorm(.nfd, &.{0xAC01}, &.{ 0x1100, 0x1161, 0x11A8 });
    try expectNorm(.nfc, &.{ 0x1100, 0x1161, 0x11A8 }, &.{0xAC01});
    // Two-step compose: L+V→LV, then LV+T→LVT.
    try expectNorm(.nfc, &.{ 0x1100, 0x1161, 0x11A8 }, &.{0xAC01});
}

test "compatibility decomposition (NFKC/NFKD)" {
    // ﬁ U+FB01 LATIN SMALL LIGATURE FI → "fi"; NFD/NFC leave it alone.
    try expectNorm(.nfkd, &.{0xFB01}, &.{ 0x0066, 0x0069 });
    try expectNorm(.nfkc, &.{0xFB01}, &.{ 0x0066, 0x0069 });
    try expectNorm(.nfd, &.{0xFB01}, &.{0xFB01});
    try expectNorm(.nfc, &.{0xFB01}, &.{0xFB01});
    // ① U+2460 CIRCLED DIGIT ONE → "1" under NFKC only.
    try expectNorm(.nfkc, &.{0x2460}, &.{0x0031});
    try expectNorm(.nfc, &.{0x2460}, &.{0x2460});
}

test "composition exclusion (Devanagari QA)" {
    // U+0958 → U+0915 U+093C, but U+0958 is a Full_Composition_Exclusion,
    // so NFC does NOT recompose the pair.
    try expectNorm(.nfd, &.{0x0958}, &.{ 0x0915, 0x093C });
    try expectNorm(.nfc, &.{0x0958}, &.{ 0x0915, 0x093C });
    try expectNorm(.nfc, &.{ 0x0915, 0x093C }, &.{ 0x0915, 0x093C });
}

test "uncomposable / identity inputs pass through" {
    try expectNorm(.nfc, &.{ 0x0041, 0x0042, 0x0043 }, &.{ 0x0041, 0x0042, 0x0043 });
    try expectNorm(.nfd, &.{}, &.{});
    // Lone surrogate (U+D800) is treated as itself.
    try expectNorm(.nfc, &.{0xD800}, &.{0xD800});
    // Astral non-decomposable (U+1F600) round-trips.
    try expectNorm(.nfkc, &.{0x1F600}, &.{0x1F600});
}

fn expectNormEq(allocator: std.mem.Allocator, form: Form, src: []const u32, want: []const u32) !void {
    const got = try normalize(allocator, src, form);
    defer allocator.free(got);
    try testing.expectEqualSlices(u32, want, got);
}

fn parseHexCps(allocator: std.mem.Allocator, s: []const u8) ![]u32 {
    var list: std.ArrayListUnmanaged(u32) = .empty;
    errdefer list.deinit(allocator);
    var it = std.mem.tokenizeAny(u8, s, " \t");
    while (it.next()) |tok| {
        const v = std.fmt.parseInt(u32, tok, 16) catch continue;
        try list.append(allocator, v);
    }
    return list.toOwnedSlice(allocator);
}

// The official Unicode conformance suite. For each `source; NFC; NFD; NFKC;
// NFKD` row, the UAX #15 invariants must hold for every form (e.g. column 2
// == toNFC of columns 1/2/3; column 5 == toNFKD of all five). ~20k rows
// spanning every script, Hangul, ligatures, ordering, and exclusions.
//
// ~320k normalize calls through `testing.allocator`; gated behind
// `-Dexhaustive-tests=true` so the default `zig build test` stays fast
// (CI runs this on Linux only).
test "NormalizationTest.txt conformance (UAX #15 invariants)" {
    if (!@import("build_options").exhaustive_tests) return error.SkipZigTest;
    const data = @embedFile("NormalizationTest.txt");
    const a = testing.allocator;
    var lines: usize = 0;
    var it = std.mem.splitScalar(u8, data, '\n');
    while (it.next()) |line_raw| {
        const line = std.mem.trimEnd(u8, line_raw, "\r");
        if (line.len == 0 or line[0] == '#' or line[0] == '@') continue;
        var cols: [5][]u32 = undefined;
        var got_cols: usize = 0;
        var fi = std.mem.splitScalar(u8, line, ';');
        while (got_cols < 5) {
            const tok = fi.next() orelse break;
            cols[got_cols] = try parseHexCps(a, tok);
            got_cols += 1;
        }
        if (got_cols < 5) {
            for (cols[0..got_cols]) |col| a.free(col);
            continue;
        }
        defer for (cols) |col| a.free(col);
        lines += 1;
        const c1 = cols[0];
        const c2 = cols[1]; // NFC
        const c3 = cols[2]; // NFD
        const c4 = cols[3]; // NFKC
        const c5 = cols[4]; // NFKD

        // NFC: c2 == toNFC(c1) == toNFC(c2) == toNFC(c3); c4 == toNFC(c4) == toNFC(c5)
        for ([_][]const u32{ c1, c2, c3 }) |x| try expectNormEq(a, .nfc, x, c2);
        for ([_][]const u32{ c4, c5 }) |x| try expectNormEq(a, .nfc, x, c4);
        // NFD: c3 == toNFD(c1) == toNFD(c2) == toNFD(c3); c5 == toNFD(c4) == toNFD(c5)
        for ([_][]const u32{ c1, c2, c3 }) |x| try expectNormEq(a, .nfd, x, c3);
        for ([_][]const u32{ c4, c5 }) |x| try expectNormEq(a, .nfd, x, c5);
        // NFKC: c4 == toNFKC(c1..c5)
        for ([_][]const u32{ c1, c2, c3, c4, c5 }) |x| try expectNormEq(a, .nfkc, x, c4);
        // NFKD: c5 == toNFKD(c1..c5)
        for ([_][]const u32{ c1, c2, c3, c4, c5 }) |x| try expectNormEq(a, .nfkd, x, c5);
    }
    try testing.expect(lines > 18000);
}
