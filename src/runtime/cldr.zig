//! Embedded Unicode CLDR data for `-Dintl=full` builds.
//!
//! The blob is `vendor/cldr/cynic_cldr.bin` (CYCL v1 — see `tools/pack_cldr.zig`):
//! a directory of typed sections. Today it carries the CLDR plural-rule
//! conditions (UTS #35 Part 3); number / date / display-name sections land in
//! later phases. At non-`full` tiers this module compiles to no-ops so off/stub
//! binaries never embed the data.
//!
//! The plural engine here implements ECMA-402 §16 (`Intl.PluralRules`): operand
//! computation (`GetOperands`, UTS #35 Part 3) and rule evaluation
//! (`PluralRuleSelect`). The CLDR rule grammar is tiny — a disjunction of
//! conjunctions of `operand (% value)? (=|!=) range_list` relations — so it is
//! parsed and evaluated in a single pass with no allocation.

const std = @import("std");
const intl_config = @import("intl_config.zig");

/// True when this binary was built with `-Dintl=full` and the CLDR blob is linked.
pub const available: bool = intl_config.has_locale_data;

/// ECMA-402 §16.5.6 plural categories, in canonical evaluation order.
pub const PluralCategory = enum(u8) {
    zero = 0,
    one = 1,
    two = 2,
    few = 3,
    many = 4,
    other = 5,

    pub fn name(self: PluralCategory) []const u8 {
        return switch (self) {
            .zero => "zero",
            .one => "one",
            .two => "two",
            .few => "few",
            .many => "many",
            .other => "other",
        };
    }
};

/// UTS #35 Part 3 plural operands derived from a formatted number.
pub const Operands = struct {
    n: f64 = 0, // absolute value of the (rounded) source number
    i: u64 = 0, // integer digits
    v: u32 = 0, // visible fraction digit count, with trailing zeros
    w: u32 = 0, // visible fraction digit count, without trailing zeros
    f: u64 = 0, // visible fraction digits as integer, with trailing zeros
    t: u64 = 0, // visible fraction digits as integer, without trailing zeros
    e: u32 = 0, // exponent (compact/scientific notation); 0 for standard
};

const SectionKind = enum(u8) {
    plural_cardinal = 1,
    plural_ordinal = 2,
};

// ── container parse (lazy, single-threaded init is fine: idempotent) ──────────

var init_done: bool = false;
var init_ok: bool = false;
var card_payload: []const u8 = &.{};
var ord_payload: []const u8 = &.{};

fn embedBlob() []const u8 {
    if (!available) return &.{};
    return @embedFile("cynic_cldr.bin");
}

fn ensureInit() bool {
    if (init_done) return init_ok;
    init_done = true;
    if (!available) return false;
    const blob = embedBlob();
    if (blob.len < 12) return false;
    if (!std.mem.eql(u8, blob[0..4], "CYCL")) return false;
    if (blob[4] != 1) return false;
    const count = std.mem.readInt(u32, blob[8..12], .little);
    var off: usize = 12;
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        if (off + 12 > blob.len) return false;
        const kind = blob[off];
        const sec_off = std.mem.readInt(u32, blob[off + 4 ..][0..4], .little);
        const sec_len = std.mem.readInt(u32, blob[off + 8 ..][0..4], .little);
        off += 12;
        const end = @as(usize, sec_off) + @as(usize, sec_len);
        if (end > blob.len) return false;
        const payload = blob[sec_off..end];
        switch (kind) {
            @intFromEnum(SectionKind.plural_cardinal) => card_payload = payload,
            @intFromEnum(SectionKind.plural_ordinal) => ord_payload = payload,
            else => {}, // unknown/future section — ignore
        }
    }
    init_ok = true;
    return true;
}

// ── plural rule lookup + evaluation ─────────────────────────────────────────

/// Evaluate the plural rules for `locale` against `ops`, returning the matched
/// category. Falls back to `.other` when the locale is absent or no rule
/// matches (CLDR's root behaviour). `locale` is a BCP 47 tag; CLDR keys most
/// rules by language alone, with a few region/script exceptions (`pt-PT`,
/// `kok-Latn`), so candidates are tried most- to least-specific.
pub fn selectPlural(locale: []const u8, ordinal: bool, ops: Operands) PluralCategory {
    if (!ensureInit()) return .other;
    const payload = if (ordinal) ord_payload else card_payload;
    const rules = findLocale(payload, locale) orelse return .other;
    return evalRules(rules, ops);
}

/// Bitmask of the non-`other` categories the locale defines (bit n =
/// @intFromEnum(category)). `.other` is always present and is not in the mask.
/// Returns 0 when the locale is absent (only `.other`).
pub fn pluralCategoriesMask(locale: []const u8, ordinal: bool) u8 {
    if (!ensureInit()) return 0;
    const payload = if (ordinal) ord_payload else card_payload;
    const rules = findLocale(payload, locale) orelse return 0;
    var mask: u8 = 0;
    var cur: usize = 0;
    while (cur < rules.len) {
        const cat = rules[cur];
        const len = std.mem.readInt(u16, rules[cur + 1 ..][0..2], .little);
        mask |= @as(u8, 1) << @intCast(cat);
        cur += 3 + len;
    }
    return mask;
}

/// True when the CLDR plural data is available and contains `locale` (any
/// candidate). Used by SupportedLocalesOf-style checks.
pub fn hasPluralLocale(locale: []const u8, ordinal: bool) bool {
    if (!ensureInit()) return false;
    const payload = if (ordinal) ord_payload else card_payload;
    return findLocale(payload, locale) != null;
}

/// Returns the slice of a locale's rule entries (each: u8 category, u16 len,
/// len bytes condition), or null when no candidate key is present.
fn findLocale(payload: []const u8, locale: []const u8) ?[]const u8 {
    if (payload.len < 4) return null;

    // Build candidate keys, most specific first, into a stack buffer.
    var lang_buf: [16]u8 = undefined;
    var script_buf: [8]u8 = undefined;
    var region_buf: [8]u8 = undefined;
    const parts = splitTag(locale, &lang_buf, &script_buf, &region_buf);
    if (parts.lang.len == 0) return null;

    var cand_buf: [32]u8 = undefined;
    // lang-Script-Region
    if (parts.script.len > 0 and parts.region.len > 0) {
        if (joinTag(&cand_buf, parts.lang, parts.script, parts.region)) |k|
            if (lookupKey(payload, k)) |r| return r;
    }
    // lang-Region
    if (parts.region.len > 0) {
        if (joinTag(&cand_buf, parts.lang, "", parts.region)) |k|
            if (lookupKey(payload, k)) |r| return r;
    }
    // lang-Script
    if (parts.script.len > 0) {
        if (joinTag(&cand_buf, parts.lang, parts.script, "")) |k|
            if (lookupKey(payload, k)) |r| return r;
    }
    // lang
    return lookupKey(payload, parts.lang);
}

/// Linear scan of a plural payload for an exact key match (case-insensitive).
/// Returns the locale's rule-entry slice (after key + rule_count).
fn lookupKey(payload: []const u8, key: []const u8) ?[]const u8 {
    const count = std.mem.readInt(u32, payload[0..4], .little);
    var off: usize = 4;
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        if (off + 1 > payload.len) return null;
        const klen = payload[off];
        off += 1;
        if (off + klen + 1 > payload.len) return null;
        const k = payload[off .. off + klen];
        off += klen;
        const rule_count = payload[off];
        off += 1;
        const rules_start = off;
        // Advance past this locale's rule entries to find the boundary.
        var r: u8 = 0;
        while (r < rule_count) : (r += 1) {
            if (off + 3 > payload.len) return null;
            const len = std.mem.readInt(u16, payload[off + 1 ..][0..2], .little);
            off += 3 + len;
        }
        if (off > payload.len) return null;
        if (asciiEqlIgnoreCase(k, key)) return payload[rules_start..off];
    }
    return null;
}

/// Evaluate rule entries in stored (canonical) order; first match wins.
fn evalRules(rules: []const u8, ops: Operands) PluralCategory {
    var cur: usize = 0;
    while (cur + 3 <= rules.len) {
        const cat: u8 = rules[cur];
        const len = std.mem.readInt(u16, rules[cur + 1 ..][0..2], .little);
        const cond = rules[cur + 3 .. cur + 3 + len];
        if (evalCondition(cond, ops)) {
            // Stored categories are 0..4 (zero..many); guard defensively.
            return if (cat <= @intFromEnum(PluralCategory.many)) @enumFromInt(cat) else .other;
        }
        cur += 3 + len;
    }
    return .other;
}

// ── CLDR plural-rule condition parser + evaluator (single pass) ──────────────

const Scanner = struct {
    s: []const u8,
    pos: usize = 0,

    fn skipWs(self: *Scanner) void {
        while (self.pos < self.s.len and (self.s[self.pos] == ' ' or self.s[self.pos] == '\t')) self.pos += 1;
    }
    fn eof(self: *Scanner) bool {
        self.skipWs();
        return self.pos >= self.s.len;
    }
    fn peek(self: *Scanner) ?u8 {
        self.skipWs();
        return if (self.pos < self.s.len) self.s[self.pos] else null;
    }
    /// Consume a lowercase keyword ("and"/"or") if it is next. Keywords are
    /// whole words delimited by whitespace, so a bare "n"/"e" operand is safe.
    fn matchKeyword(self: *Scanner, kw: []const u8) bool {
        self.skipWs();
        if (self.pos + kw.len > self.s.len) return false;
        if (!std.mem.eql(u8, self.s[self.pos .. self.pos + kw.len], kw)) return false;
        const after = self.pos + kw.len;
        if (after < self.s.len and self.s[after] != ' ' and self.s[after] != '\t') return false;
        self.pos = after;
        return true;
    }
    fn readInt(self: *Scanner) ?u64 {
        self.skipWs();
        const start = self.pos;
        while (self.pos < self.s.len and self.s[self.pos] >= '0' and self.s[self.pos] <= '9') self.pos += 1;
        if (self.pos == start) return null;
        return std.fmt.parseInt(u64, self.s[start..self.pos], 10) catch null;
    }
};

fn operandValue(op: u8, ops: Operands) f64 {
    return switch (op) {
        'n' => ops.n,
        'i' => @floatFromInt(ops.i),
        'v' => @floatFromInt(ops.v),
        'w' => @floatFromInt(ops.w),
        'f' => @floatFromInt(ops.f),
        't' => @floatFromInt(ops.t),
        'e', 'c' => @floatFromInt(ops.e),
        else => 0,
    };
}

/// `condition = and_condition ('or' and_condition)*`
fn evalCondition(cond: []const u8, ops: Operands) bool {
    var sc = Scanner{ .s = cond };
    if (sc.eof()) return true; // empty condition (defensive; "other" isn't stored)
    var result = evalAnd(&sc, ops);
    while (sc.matchKeyword("or")) {
        const r = evalAnd(&sc, ops);
        result = result or r;
    }
    return result;
}

/// `and_condition = relation ('and' relation)*`
fn evalAnd(sc: *Scanner, ops: Operands) bool {
    var result = evalRelation(sc, ops);
    while (sc.matchKeyword("and")) {
        const r = evalRelation(sc, ops);
        result = result and r;
    }
    return result;
}

/// `relation = operand ('%' value)? ('=' | '!=') range_list`
fn evalRelation(sc: *Scanner, ops: Operands) bool {
    const op = sc.peek() orelse return false;
    sc.pos += 1; // consume operand letter
    var val = operandValue(op, ops);

    if (sc.peek() == '%') {
        sc.pos += 1;
        const m = sc.readInt() orelse return false;
        if (m != 0) {
            const mf: f64 = @floatFromInt(m);
            val = val - mf * @floor(val / mf);
        }
    }

    // '=' or '!='
    var negate = false;
    const c = sc.peek() orelse return false;
    if (c == '!') {
        sc.pos += 1;
        if (sc.peek() != '=') return false;
        sc.pos += 1;
        negate = true;
    } else if (c == '=') {
        sc.pos += 1;
    } else return false;

    // range_list = (value ('..' value)?) (',' ...)*
    var matched = false;
    while (true) {
        const lo = sc.readInt() orelse break;
        var hi = lo;
        if (sc.peek() == '.') {
            sc.pos += 1;
            if (sc.peek() == '.') {
                sc.pos += 1;
                hi = sc.readInt() orelse lo;
            }
        }
        if (inIntRange(val, lo, hi)) matched = true;
        if (sc.peek() == ',') {
            sc.pos += 1;
            continue;
        }
        break;
    }
    return if (negate) !matched else matched;
}

/// A value is in an integer range only when it is itself integral. A fractional
/// operand (only `n` can be) never matches an integer range — per UTS #35.
fn inIntRange(val: f64, lo: u64, hi: u64) bool {
    if (val != @floor(val)) return false;
    if (val < 0) return false;
    const iv: u64 = std.math.lossyCast(u64, val);
    return iv >= lo and iv <= hi;
}

// ── operand computation (GetOperands over FormatNumericToString) ─────────────

/// Compute plural operands for `value` formatted with [min_frac, max_frac]
/// fraction digits (ECMA-402 ToRawFixed with the default rounding: ties away
/// from zero). Non-finite inputs yield zeroed operands; the caller maps those
/// to `.other` before reaching here.
pub fn computeOperands(value: f64, min_frac: u32, max_frac: u32) Operands {
    if (!std.math.isFinite(value)) return .{};
    const a = @abs(value);

    var ip = @floor(a);
    const pow = std.math.pow(f64, 10, @floatFromInt(max_frac));
    var frac_scaled = @round((a - ip) * pow);
    if (frac_scaled >= pow) { // rounding carried into the integer part
        ip += 1;
        frac_scaled -= pow;
    }

    var ops: Operands = .{};
    ops.i = std.math.lossyCast(u64, ip);
    ops.n = ip + (if (pow > 0) frac_scaled / pow else 0);

    if (max_frac == 0) return ops;

    // Render the fraction as max_frac zero-padded digits.
    var digits: [20]u8 = undefined;
    const nd = @min(max_frac, 19);
    var fs: u64 = std.math.lossyCast(u64, frac_scaled);
    var d: usize = nd;
    while (d > 0) {
        d -= 1;
        digits[d] = @intCast('0' + (fs % 10));
        fs /= 10;
    }
    const frac = digits[0..nd];

    // v: trim trailing zeros down to min_frac.
    var v: usize = nd;
    while (v > min_frac and frac[v - 1] == '0') v -= 1;
    ops.v = @intCast(v);
    ops.f = std.fmt.parseInt(u64, frac[0..v], 10) catch 0;

    // w/t: trim all trailing zeros.
    var w: usize = v;
    while (w > 0 and frac[w - 1] == '0') w -= 1;
    ops.w = @intCast(w);
    ops.t = if (w > 0) (std.fmt.parseInt(u64, frac[0..w], 10) catch 0) else 0;

    return ops;
}

// ── small helpers ────────────────────────────────────────────────────────────

const TagParts = struct { lang: []const u8, script: []const u8, region: []const u8 };

/// Split a BCP 47 tag into language / script / region subtags, lowercasing the
/// language and uppercasing the region (script title-case) so candidate keys
/// match CLDR's canonical form. Extensions and variants are ignored.
fn splitTag(tag: []const u8, lang_buf: []u8, script_buf: []u8, region_buf: []u8) TagParts {
    var lang: []const u8 = "";
    var script: []const u8 = "";
    var region: []const u8 = "";
    var it = std.mem.splitAny(u8, tag, "-_");
    if (it.next()) |first| {
        const n = @min(first.len, lang_buf.len);
        for (first[0..n], 0..) |ch, idx| lang_buf[idx] = std.ascii.toLower(ch);
        lang = lang_buf[0..n];
    }
    while (it.next()) |sub| {
        if (sub.len == 4 and isAllAlpha(sub) and script.len == 0) {
            script_buf[0] = std.ascii.toUpper(sub[0]);
            for (sub[1..], 1..) |ch, idx| script_buf[idx] = std.ascii.toLower(ch);
            script = script_buf[0..4];
        } else if ((sub.len == 2 and isAllAlpha(sub)) or (sub.len == 3 and isAllDigit(sub))) {
            const n = @min(sub.len, region_buf.len);
            for (sub[0..n], 0..) |ch, idx| region_buf[idx] = std.ascii.toUpper(ch);
            region = region_buf[0..n];
            break; // region terminates the part of the tag we care about
        }
    }
    return .{ .lang = lang, .script = script, .region = region };
}

fn joinTag(buf: []u8, lang: []const u8, script: []const u8, region: []const u8) ?[]const u8 {
    var len: usize = 0;
    const append = struct {
        fn f(b: []u8, l: *usize, part: []const u8) bool {
            if (l.* + part.len > b.len) return false;
            @memcpy(b[l.* .. l.* + part.len], part);
            l.* += part.len;
            return true;
        }
    }.f;
    if (!append(buf, &len, lang)) return null;
    if (script.len > 0) {
        if (len + 1 > buf.len) return null;
        buf[len] = '-';
        len += 1;
        if (!append(buf, &len, script)) return null;
    }
    if (region.len > 0) {
        if (len + 1 > buf.len) return null;
        buf[len] = '-';
        len += 1;
        if (!append(buf, &len, region)) return null;
    }
    return buf[0..len];
}

fn isAllAlpha(s: []const u8) bool {
    for (s) |c| if (!std.ascii.isAlphabetic(c)) return false;
    return true;
}
fn isAllDigit(s: []const u8) bool {
    for (s) |c| if (!std.ascii.isDigit(c)) return false;
    return true;
}
fn asciiEqlIgnoreCase(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| if (std.ascii.toLower(x) != std.ascii.toLower(y)) return false;
    return true;
}
